extends Node3D

## 第④步 Round 2「4 副炮接入」的独立验证场景。
## 依据协作约定第 4 条：复杂功能先建独立测试场景跑通，再搬进主场景。
##
## 验证四件事：
## ① 5 门炮塔全部注册（1 主炮 + 4 副炮），扇区归属正确
## ② 副炮炮位 = sub_gun_instances 的 axis × hull_radius（不再写死坐标）
## ③ BATTLE 下四门副炮**各自独立**自动开火（DEC-040：不合并 DPS / 不共享 cooldown）
## ④ 弹丸命中 → 敌人扣血 → 击杀（端到端链路）
##
## ⚠ 依赖 EventBus autoload，只能在**完整主场景运行路径**下跑（`--script` 模式
##   不实例化 autoload）。
##
## 注：本场景根节点叫 `Bridge` 只是沿用主场景命名，不再是硬约束 ——
## Projectile 的命中检测已从「硬编码路径 Bridge/EnemySystem」改为 group 查找
## （2026-09-06 修复），任何结构下都能找到敌人。
##
## 推进方式：手动 advance 而非等真实帧 —— 副炮 fire_interval = 3s，等一轮要真等 3 秒，
## 手动推 240 次即 4 秒，且结果确定（不受帧率波动影响）。

const TURRET_DATA_PATH := "res://data/turrets.json"

## 四门副炮的扇区（顺序与 data/turrets.json 的 sub_gun_instances 一致）。
const SUB_SECTORS: Array[StringName] = [&"port", &"starboard", &"dorsal", &"ventral"]

## 敌人从 spawn_radius(190) 飞到 attack_range(52) 需要约 8.1s，推 600 帧（10s）留余量。
const APPROACH_FRAMES := 600
## 副炮 fire_interval = 3s，推 4s 保证每门至少打出 1 发。
const FIRE_FRAMES := 240

var _pass := 0
var _fail := 0


func _ready() -> void:
	await get_tree().process_frame
	var ts := $TurretSystem as TurretSystem
	var es := $EnemySystem as EnemySystem
	print("=== ④ Round 2 · 4 副炮接入 · 独立验证 ===")
	if ts == null or es == null:
		push_error("测试场景缺少 TurretSystem / EnemySystem 节点")
		return
	_test_registered(ts)
	_test_mount(ts)
	await _test_independent_fire(ts, es)
	print("=== 结果：通过 %d / 失败 %d ===" % [_pass, _fail])
	if _fail > 0:
		push_error("存在 %d 条失败断言，见上方 NG 行" % _fail)
	get_tree().quit()


## ① 炮塔注册与扇区归属。
func _test_registered(ts: TurretSystem) -> void:
	var ids := ts.registered_ids()
	_check("已建 5 门炮塔（1 主 + 4 副），实测 %d" % ids.size(), ids.size() == 5)
	for s in SUB_SECTORS:
		_check("已注册 %s" % s, ids.has(s))
		var t := ts.get_turret(s)
		_check("%s 的 sector == 自身（id 与扇区同名）" % s, t != null and t.sector == s)
	var main := ts.get_turret(&"main")
	_check("main 的 sector == fore（DEC-030 主炮固定正面）",
		main != null and main.sector == &"fore")


## ② 炮位推导：mount = normalize(axis) × hull_radius。
## 期望值**独立从 turrets.json 重算**（不复用 TurretSystem 已解析的结果），
## 这样被测代码自己算错才会失败。
func _test_mount(ts: TurretSystem) -> void:
	var cfg := _read_turrets()
	var inst: Variant = cfg.get("sub_gun_instances", {})
	if not (inst is Dictionary):
		_check("turrets.json 含 sub_gun_instances", false)
		return
	var inst_dict := inst as Dictionary
	for key in inst_dict:
		if str(key).begins_with("_"):
			continue   # _doc 之类的注释键
		var one := inst_dict[key] as Dictionary
		var a: Array = one.get("axis", [0, 0, 1]) as Array
		var radius := float(one.get("hull_radius", 0.0))
		var expect := Vector3(float(a[0]), float(a[1]), float(a[2])).normalized() * radius
		var t := ts.get_turret(StringName(str(key)))
		if t == null:
			_check("%s 炮塔存在" % key, false)
			continue
		_check("%s 炮位 = axis×hull_radius → %s（实测 %s）" % [
			str(key), str(expect), str(t.muzzle_pos)],
			t.muzzle_pos.distance_to(expect) < 0.001)


## ③④ 四门副炮各自独立开火 + 端到端击杀。
func _test_independent_fire(ts: TurretSystem, es: EnemySystem) -> void:
	# 关掉两个系统自带的 _physics_process，改由本测试手动推进（结果确定）
	ts.set_physics_process(false)
	es.set_physics_process(false)

	var enemies: Array[Enemy] = []
	for s in SUB_SECTORS:
		enemies.append(es.spawn_one(&"interceptor", s))

	# 推进到悬停（acquire_target 只锁**悬停**中的敌人）
	for _i in APPROACH_FRAMES:
		for e in enemies:
			e.advance(1.0 / 60.0)
	var hovering := 0
	for e in enemies:
		if e.is_hovering():
			hovering += 1
	_check("4 个敌人全部进入悬停（实测 %d/4）" % hovering, hovering == 4)

	# 开战 → 副炮自动开火
	ts.set_battle_active(true)

	# 边推边统计发射过的弹丸。
	# Projectile 命中后 call_deferred(queue_free)，所以必须**每帧**扫一次新出现的
	# 节点 —— 等推进完再统计，命中的弹丸早就没了，会误判成"没开火"。
	var fired := {}
	var seen := {}
	for s in SUB_SECTORS:
		fired[s] = 0
	for _i in FIRE_FRAMES:
		ts.advance_all(1.0 / 60.0)
		for e in enemies:
			if not e.is_dead():
				e.advance(1.0 / 60.0)
		for child in get_tree().get_root().get_children():
			var nm := str(child.name)
			if not nm.begins_with("Bullet_") or seen.has(nm):
				continue
			seen[nm] = true
			for s in SUB_SECTORS:
				if nm.begins_with("Bullet_%s_" % s):
					fired[s] = int(fired[s]) + 1
					break

	# ③ DEC-040：每门各自独立开火（若共享 cooldown 或被合并成一门，这里会有 0 发的项）
	for s in SUB_SECTORS:
		_check("%s 副炮自动开火 ≥1 发（实测 %d）" % [s, int(fired[s])], int(fired[s]) >= 1)

	# ④ 端到端：弹丸命中 → 扣血 → 击杀
	var dead := 0
	for e in enemies:
		if e.is_dead():
			dead += 1
	_check("敌人被击杀（实测 %d/4）" % dead, dead >= 1)

	# 顺带确认主炮也没闲着（同一套 advance 循环，验证没被 Round 2 改坏）
	var main_fired := 0
	for nm in seen:
		if str(nm).begins_with("Bullet_main_"):
			main_fired += 1
	_check("主炮仍在自动开火（实测 %d 发）" % main_fired, main_fired >= 1)


# ── 工具 ────────────────────────────────────────────

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("   OK  %s" % label)
	else:
		_fail += 1
		print("   NG  %s" % label)


## 独立读一次 turrets.json。刻意不复用 TurretSystem 已解析的值，
## 这样断言的是「配置文件里写的数」。
func _read_turrets() -> Dictionary:
	if not FileAccess.file_exists(TURRET_DATA_PATH):
		push_warning("测试读不到 %s" % TURRET_DATA_PATH)
		return {}
	var f := FileAccess.open(TURRET_DATA_PATH, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		return parsed as Dictionary
	return {}
