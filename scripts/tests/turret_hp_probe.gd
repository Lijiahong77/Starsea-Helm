extends Node3D

## 第⑤步「炮塔耐久 + 被毁 + 全毁失败 + 每波回满」的独立验证场景。
## 依据协作约定第 4 条：复杂功能先建独立测试场景跑通，再搬进主场景。
##
## 验证七件事：
## ① 5 门炮的初始耐久**来自 turrets.json**，且 hp_max 已快照（回满要用）
## ② 敌人悬停后**只打最近的那门**，扣血量 == dps × 时间（伤害路由 + 数值正确）
## ③ 耐久归零 → 被毁（destroyed / 事件 / 面失守），且不会掉成负数
## ④ 被毁的炮塔**不再开火**（否则会出现"炮已毁、子弹还在飞"的假象）
## ⑤ 全毁 → all_turrets_destroyed **恰好一次**（DEC-037 失败条件的源头）
## ⑥ 被毁的炮塔**不可接管**（接管死炮 = 按扳机毫无反应）
## ⑦ 开战即回满：set_battle_active(true) 让所有炮塔复活并满耐久
##
## ⚠ 依赖 EventBus autoload，只能在**完整主场景运行路径**下跑（`--script` 模式
##   不实例化 autoload）。
##
## 推进方式：手动 advance 而非等真实帧 —— 结果确定，且不用真等 30 秒让副炮掉血。
##
## **刻意不开自动开火**（除了④⑤那一小段）：否则炮塔会把敌人打掉，
## 「耐久归零 / 全毁」根本推不出来 —— 先测伤害链路，再测火力，互不干扰。

const ENEMY_DATA_PATH := "res://data/enemies.json"
const TURRET_DATA_PATH := "res://data/turrets.json"

## 5 门炮塔的 id（顺序与 TurretSystem 的注册顺序一致）。
const ALL_IDS: Array[StringName] = [&"main", &"port", &"starboard", &"dorsal", &"ventral"]
## 4 门副炮（主炮扇区是 fore，不在此列）。
const SUB_SECTORS: Array[StringName] = [&"port", &"starboard", &"dorsal", &"ventral"]
## 5 个来袭扇区（生成敌人用：fore + 4 面）。
const SECTOR_IDS: Array[StringName] = [&"fore", &"port", &"starboard", &"dorsal", &"ventral"]

const DT := 1.0 / 60.0
## 拦截机 17m/s，从 190m 飞到 52m 需 8.1s；推 10s 留余量。
const APPROACH_FRAMES := 600
## 扣血观测窗口：2 秒。
const ATTACK_FRAMES := 120
## 副炮 fire_interval = 3s，推 4s 保证每门至少打出 1 发。
const FIRE_FRAMES := 240
## 轰炸机 11m/s（进场 12.5s）+ 打光 5 门炮（≈440 HP / 7dps×5）≈ 30s。留足余量。
const ALL_DEAD_FRAMES := 12000

var _pass := 0
var _fail := 0
var _destroyed_ids: Array[StringName] = []
var _breached: Array[StringName] = []
var _all_dead := 0


func _ready() -> void:
	# 事件记账必须在推进**之前**挂上：turret_destroyed 是在 take_damage 里同步 emit 的，
	# 晚挂一帧就永远记不到。
	EventBus.turret_destroyed.connect(
		func(id: StringName, _sector: StringName) -> void: _destroyed_ids.append(id))
	EventBus.sector_breached.connect(func(s: StringName) -> void: _breached.append(s))
	EventBus.all_turrets_destroyed.connect(func() -> void: _all_dead += 1)

	await get_tree().process_frame
	var ts := $TurretSystem as TurretSystem
	var es := $EnemySystem as EnemySystem
	print("=== ⑤ 炮塔耐久 · 独立验证 ===")
	if ts == null or es == null:
		push_error("测试场景缺少 TurretSystem / EnemySystem 节点")
		return
	# 关掉两个系统自带的 _physics_process，改由本测试手动推进（结果确定）
	ts.set_physics_process(false)
	es.set_physics_process(false)

	_test_initial_hp(ts)
	var e := _test_damage_routing(ts, es)
	_test_destroy(ts, e)
	_test_dead_turret_no_fire(ts, e)
	_test_all_destroyed(ts, es)
	_test_takeover_and_restore(ts)

	print("=== 结果：通过 %d / 失败 %d ===" % [_pass, _fail])
	if _fail > 0:
		push_error("存在 %d 条失败断言，见上方 NG 行" % _fail)
	get_tree().quit()


## ① 初始耐久 = turrets.json 的数值，且 hp_max 已快照。
## hp_max 是"每波回满"的唯一依据 —— 它若没被正确赋值，restore() 会把耐久回满成 0，
## 表现为"一开战炮塔全没"，且**不报任何错**。所以这条必须单独立断言。
func _test_initial_hp(ts: TurretSystem) -> void:
	var cfg := _read_json(TURRET_DATA_PATH)
	var mg: Dictionary = cfg.get("main_gun", {}) as Dictionary
	var tpl: Dictionary = cfg.get("sub_gun_template", {}) as Dictionary
	var main_hp := float(mg.get("hp", 0.0))
	var sub_hp := float(tpl.get("hp_per_gun", 0.0))

	var m := ts.get_turret(&"main")
	_check("主炮耐久 = main_gun.hp = %.0f（实测 %.0f）" % [main_hp, m.hp], m.hp == main_hp)
	_check("主炮 hp_max 已快照 = %.0f（实测 %.0f）" % [main_hp, m.hp_max], m.hp_max == main_hp)
	for s in SUB_SECTORS:
		var t := ts.get_turret(s)
		_check("%s 耐久 = hp_per_gun = %.0f（实测 %.0f）" % [s, sub_hp, t.hp], t.hp == sub_hp)
		_check("%s hp_max 已快照（实测 %.0f）" % [s, t.hp_max], t.hp_max == sub_hp)
	_check("开局 5 门全部存活（实测 %d）" % ts.alive_count(), ts.alive_count() == 5)


## ② 伤害路由 + 数值：只有一门在掉血，且掉的是**距敌人最近**的那门，掉血量 = dps × 秒数。
## 「最近」由本测试**独立重算**（不复用 Enemy._nearest_alive_turret），被测代码算错才会失败。
func _test_damage_routing(ts: TurretSystem, es: EnemySystem) -> Enemy:
	var dps := _enemy_num("dps_interceptor")
	_check("enemies.json 的 dps_interceptor > 0（实测 %.1f）" % dps, dps > 0.0)

	var e := es.spawn_one(&"interceptor", &"port")
	for _i in APPROACH_FRAMES:
		e.advance(DT)
	_check("拦截机已进入攻击距离并悬停", e.is_hovering())

	var before := {}
	for id in ALL_IDS:
		before[id] = ts.get_turret(id).hp
	for _i in ATTACK_FRAMES:
		e.advance(DT)

	var expect := _nearest_turret(ts, e.global_position)
	var dropped: Array[StringName] = []
	for id in ALL_IDS:
		if ts.get_turret(id).hp < float(before[id]) - 1e-6:
			dropped.append(id)
	_check("只有 1 门炮在挨打（实测 %d 门：%s）" % [dropped.size(), str(dropped)],
		dropped.size() == 1)
	if dropped.is_empty():
		return e
	_check("挨打的是距敌人最近的 %s（实测 %s）" % [expect.turret_id, str(dropped[0])],
		dropped[0] == expect.turret_id)
	var delta := float(before[dropped[0]]) - ts.get_turret(dropped[0]).hp
	var want := dps * (float(ATTACK_FRAMES) * DT)
	_check("2 秒扣血 = dps×时间 = %.2f（实测 %.2f）" % [want, delta], absf(delta - want) < 0.3)
	return e


## ③ 持续挨打 → 耐久归零 → 被毁 + 事件 + 面失守。
func _test_destroy(ts: TurretSystem, e: Enemy) -> void:
	var port := ts.get_turret(&"port")
	var frames := 0
	while not port.destroyed and frames < 4000:
		e.advance(DT)
		frames += 1
	_check("port 被持续攻击后耐久归零（用了 %.1fs）" % [float(frames) * DT], port.destroyed)
	_check("turret_destroyed 已发出（port）", _destroyed_ids.has(&"port"))
	_check("sector_breached 已发出（port 面失守）", _breached.has(&"port"))
	_check("耐久不会掉成负数（实测 %.2f）" % port.hp, port.hp == 0.0)
	_check("被毁后 is_alive() == false", not port.is_alive())
	_check("其余 4 门仍存活（实测 %d）" % ts.alive_count(), ts.alive_count() == 4)


## ④ 被毁的炮塔不再开火，其余副炮照常自动开火。
## 只给**副炮**开自动（不开主炮）：主炮 0.25s 一发、3 伤害，会在 2 秒内把
## 20 HP 的拦截机打死，副炮（3s 一发）就永远轮不到开火 —— 那就测不到东西了。
func _test_dead_turret_no_fire(ts: TurretSystem, e: Enemy) -> void:
	for s in SUB_SECTORS:
		ts.get_turret(s).set_auto_enabled(true)
	var fired := {}
	var seen := {}
	for id in ALL_IDS:
		fired[id] = 0
	for _i in FIRE_FRAMES:
		ts.advance_all(DT)
		if not e.is_dead():
			e.advance(DT)
		for child in get_tree().get_root().get_children():
			var nm := str(child.name)
			if not nm.begins_with("Bullet_") or seen.has(nm):
				continue
			seen[nm] = true
			for id in ALL_IDS:
				if nm.begins_with("Bullet_%s_" % id):
					fired[id] = int(fired[id]) + 1
					break
	_check("被毁的 port 一发未发（实测 %d）" % int(fired[&"port"]), int(fired[&"port"]) == 0)
	for s in SUB_SECTORS:
		if s == &"port":
			continue
		_check("%s 仍在自动开火（实测 %d 发）" % [s, int(fired[s])], int(fired[s]) >= 1)


## ⑤ 全毁 → all_turrets_destroyed 恰好一次。
func _test_all_destroyed(ts: TurretSystem, es: EnemySystem) -> void:
	# 关掉自动开火：让轰炸机安心拆炮塔，否则它们会先被炮塔打死。
	for id in ALL_IDS:
		ts.get_turret(id).set_auto_enabled(false)
	var enemies: Array[Enemy] = []
	for s in SECTOR_IDS:
		enemies.append(es.spawn_one(&"bomber", s))
	var frames := 0
	while ts.alive_count() > 0 and frames < ALL_DEAD_FRAMES:
		for en in enemies:
			if not en.is_dead():
				en.advance(DT)
		frames += 1
	_check("全部炮塔被摧毁（用了 %.1fs，存活 %d）" % [float(frames) * DT, ts.alive_count()],
		ts.alive_count() == 0)
	_check("all_turrets_destroyed 恰好发 1 次（实测 %d）" % _all_dead, _all_dead == 1)


## ⑥⑦ 死炮不可接管；开战即回满。
func _test_takeover_and_restore(ts: TurretSystem) -> void:
	ts.takeover(&"port")
	_check("被毁的炮塔不可接管（current_manual_id=%s）" % ts.current_manual_id,
		ts.current_manual_id == &"")
	ts.set_battle_active(true)
	var all_full := true
	for t in ts.all_turrets():
		if t.destroyed or t.hp != t.hp_max:
			all_full = false
	_check("开战即回满：5 门全部复活且满耐久（存活 %d）" % ts.alive_count(),
		all_full and ts.alive_count() == 5)


# ── 工具 ────────────────────────────────────────────

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("   OK  %s" % label)
	else:
		_fail += 1
		print("   NG  %s" % label)


## 独立算「距 from 最近的存活炮塔」，用于验证 Enemy 的选目标逻辑。
func _nearest_turret(ts: TurretSystem, from: Vector3) -> Turret:
	var best: Turret = null
	var best_d: float = INF
	for t in ts.all_turrets():
		if not t.is_alive():
			continue
		var d: float = from.distance_to(t.muzzle_pos)
		if d < best_d:
			best_d = d
			best = t
	return best


## 独立读一次 JSON，断言的是「配置文件里写的数」而不是被测代码解析出来的值。
func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("测试读不到 %s" % path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		return parsed as Dictionary
	return {}


func _enemy_num(key: String) -> float:
	var root := _read_json(ENEMY_DATA_PATH)
	var sec: Variant = root.get("enemy", {})
	if not (sec is Dictionary):
		return 0.0
	return float((sec as Dictionary).get(key, 0.0))
