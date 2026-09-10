extends Node3D
class_name EnemySystem

## 敌人生成、移动、扇区归属与威胁压力计算。
## 职责边界见 `docs/MODULES.md §二`（EnemySystem：生成 / 移动 / 扇区归属 / 攻击炮塔）。
##
## **本步范围**（BACKLOG 第③步：「六扇区 + 敌人生成与移动，**不做开火**」）：
##   按权重选面 → 球壳外缘生成 → 直线飞向船 → 进攻击距离后悬停 → 持续贡献该面 pressure
## **本步不做**：波次调度与难度曲线（BACKLOG 里是独立 P0 项）。
##
## 第⑤步已补上「扣炮塔血」，但**实现在 Enemy 侧**（`Enemy._attack_tick`，悬停后
## 每帧扣最近存活炮塔 dps×delta）。本系统只负责把 `dps_<type>` 从 JSON 注入
## 给敌人 —— 找目标 / 判定死亡都不归本系统，避免「谁打谁」的职责散在两处。
##
## 所有数值来自 `data/enemies.json`，本文件不 hardcode 数值（只写 JSON 缺项时的兜底）。
## 扇区定义与压力公式在 `scripts/utils/sectors.gd`。

## 本系统所在的 group。**系统节点之间不硬编码节点路径**（同 projectile.gd /
## turret.gd 的修法）：WaveSystem 靠这个 group 找到本系统来生成波次敌人，
## 于是测试场景可以自由换节点结构，不用保证 "Bridge/EnemySystem" 这种固定路径。
const SYSTEM_GROUP := &"enemy_system"

const DATA_PATH := "res://data/enemies.json"

# 【日志纪律 2026-09-05 · 用户要求】新写的模块打开打印，用来在 Output 里直接
# 判断功能是否正常；等本模块验证通过、开始写下一个模块时，把它改成 false，
# 避免刷屏盖住新模块的日志。
# 日志设计：每条只在**状态发生变化**的那一刻打印一次（生成 / 悬停 / 压力变化 /
# 移除），飞行的每一帧都不打 —— 否则 20 个敌人 × 60fps 会瞬间淹没 Output。
const DEBUG_LOG := false

## 压力重算间隔（秒）。移动每帧都算，但「扇区统计 + 发事件」没必要每帧 ——
## 事件是广播给所有订阅方的，刷太勤会拖垮后面的 UI/VFX。
const PRESSURE_INTERVAL := 0.25

## 生成锥半角的硬上限（度）。= 立方体面的内切半角；超过就会跨到邻面，
## 让「生成时判定的扇区」和「运行时 sector_of 的归属」打架。见 _random_direction。
const MAX_CONE_HALF_DEG := 45.0

var _cfg: Dictionary = {}
var _enemies: Array[Enemy] = []
var _counts: Dictionary = {}
var _pressures: Dictionary = {}
var _dist: Dictionary = {}

var _ship_center := Vector3.ZERO
var _spawn_radius := 190.0
var _spawn_cone_deg := 30.0
var _attack_range := 52.0
var _pressure_ref := 6.0
var _pressure_timer := 0.0


func _ready() -> void:
	add_to_group(SYSTEM_GROUP)
	_load_config()
	if DEBUG_LOG:
		print("[enemy] 配置就绪 center=%s spawn_r=%.0f 锥半角=%.0f° atk_r=%.0f pressure_ref=%.0f" % [
			str(_ship_center), _spawn_radius, _spawn_cone_deg, _attack_range, _pressure_ref])
		print("[enemy] 六面权重 %s（aft=0 即永不来敌，DEC-036）" % str(_dist))


func _physics_process(delta: float) -> void:
	if _enemies.is_empty():
		return
	for e in _enemies:
		# advance() 返回 true = 本帧刚好跨进攻击距离并停住。每个敌人只会发生一次，
		# 所以这里打印是安全的（不会每帧刷屏）。
		if e.advance(delta) and DEBUG_LOG:
			print("[enemy] 悬停 %s 扇区=%s 距船=%.1fm 飞行用时=%.1fs%s" % [
				e.name, e.sector, e.global_position.distance_to(_ship_center),
				e.flight_time(), _visibility_hint(e.sector)])
	_pressure_timer += delta
	if _pressure_timer >= PRESSURE_INTERVAL:
		_pressure_timer = 0.0
		_recount_and_publish()


## 生成一个敌人。
## sector_id 为空 → 按 `enemy.sector_distribution` 权重随机选面（aft 权重为 0 即永不被选中，
## 依据 DEC-036 推进器高温区）。显式传 sector_id 用于测试定向生成。
## 返回生成出来的实例，方便测试脚本断言。
func spawn_one(type_id: StringName, sector_id: StringName = &"") -> Enemy:
	var dir := _random_direction(sector_id)
	var e := Enemy.new()
	e.name = "Enemy_%s_%d" % [type_id, _enemies.size()]
	# **必须先 add_child 再 setup**：Node3D.global_position 在节点没进树时是坏的 ——
	# 写入能进内部 transform，但读取走 get_global_transform()，不在树会直接
	# ERR_FAIL 返回单位矩阵，于是读回来永远是 (0,0,0)（扇区就会全判成同一个面）。
	add_child(e)
	e.setup(type_id, _ship_center + dir * _spawn_radius, _ship_center, _stats_for(type_id))
	_enemies.append(e)
	# 敌人被销毁/移除时自动出列，否则 _physics_process 会调到已释放实例而崩溃。
	e.tree_exited.connect(_on_enemy_exited.bind(e))
	EventBus.enemy_spawned.emit(e, e.sector)
	if DEBUG_LOG:
		print("[enemy] 生成 #%d %s 扇区=%s 距船=%.1fm 速度=%.0f hp=%.0f%s" % [
			_enemies.size(), type_id, e.sector,
			e.global_position.distance_to(_ship_center), e.speed, e.hp,
			_visibility_hint(e.sector)])
	return e


## 该扇区的敌人，玩家从**艏部舷窗**能不能直接看到？
## DEC-026：舰桥只有艏部一面舷窗，其余五个方向只能靠 4 路监控 / 雷达。
## 所以生成在非 fore 扇区的敌人，在主视角里就是"看不见" —— 这不是 bug。
## 排查「按了 E 却看不到敌人」时，先看这条提示，别误判成生成失败。
func _visibility_hint(sector: StringName) -> String:
	return "（主视角舷窗可见）" if sector == &"fore" else "（舷窗外，看监控/雷达）"


## 敌人离开场景树（queue_free / remove_child）时出列。
func _on_enemy_exited(e: Enemy) -> void:
	_enemies.erase(e)
	if DEBUG_LOG:
		print("[enemy] 移除 %s（%s）剩余=%d" % [e.name, e.sector, _enemies.size()])


## 当前各扇区敌人数（键为扇区 id，没有敌人时该键不存在）。
## 给需要读数的系统用；要订阅变化请用 `EventBus.sector_pressure_changed`。
func threat_counts() -> Dictionary:
	return _counts.duplicate()


## 当前各扇区压力 0..1。
func pressures() -> Dictionary:
	return _pressures.duplicate()


## 存活敌人数。
func enemy_count() -> int:
	return _enemies.size()


# ── 内部 ────────────────────────────────────────────

## 随机一个生成方向：先按权重选面，再在「该面轴向 ± 半角」的**锥内**采样。
##
## **为什么从「全球面 + 拒绝采样」改成「锥内采样」**：六扇区是立方体的六个面，
## 一个扇区对应 90°×90° 的方形锥，球面均匀采样能落到离轴线 54.7° 远的对角方向 ——
## 实测出过 fore 扇区的敌人生成在 (x=-48, y=-114, z=142)，也就是「从船的斜下方
## 114 米处来袭」：既不符合玩家对"前方来敌"的直觉，也必然被艏部墙挡住看不见
## （见 bridge_whitebox.gd 的 _probe_dump 诊断）。
## 锥内采样让敌人"大致从该方向来"，偏角上限由 `spawn_cone_deg` 外置控制。
##
## **半角硬上限 45°**：立方体面的内切半角是 45°，超过就有方向的最大分量落到邻面
## 轴上，于是「生成时说是 fore、跑起来 sector_of 判成 ventral」—— 两者打架。
## 所以这里 clamp，保证**生成判定与运行时归属永远一致**。
func _random_direction(want_sector: StringName) -> Vector3:
	var sid := want_sector
	if sid == &"" or not Sectors.AXES.has(sid):
		sid = _pick_sector()
	return _random_in_cone(Sectors.AXES[sid])


## 按 `sector_distribution` 权重选一个面。权重全为 0 时回退 fore 并告警。
func _pick_sector() -> StringName:
	var total := 0.0
	for id in Sectors.IDS:
		total += float(_dist.get(id, 0.0))
	if total <= 0.0:
		push_warning("六面权重全为 0（enemies.json sector_distribution），回退 fore")
		return &"fore"
	var r := randf() * total
	for id in Sectors.IDS:
		r -= float(_dist.get(id, 0.0))
		if r <= 0.0:
			return id
	return Sectors.IDS[-1]


## 以 axis 为中心轴、半角 `_spawn_cone_deg` 的锥内均匀采样一个单位向量。
## 对 cosθ 均匀取而不是对 θ 均匀取 —— 后者会在轴心方向堆积（立体角不均匀）。
func _random_in_cone(axis: Vector3) -> Vector3:
	var half := deg_to_rad(clampf(_spawn_cone_deg, 1.0, MAX_CONE_HALF_DEG))
	var cos_half := cos(half)
	var cos_t := randf_range(cos_half, 1.0)
	var sin_t := sqrt(maxf(0.0, 1.0 - cos_t * cos_t))
	var phi := randf() * TAU
	var u := _orthogonal(axis)
	var v := axis.cross(u).normalized()
	return axis * cos_t + u * (sin_t * cos(phi)) + v * (sin_t * sin(phi))


## 任取一个与 axis 正交的单位向量（构造锥的正交基用）。
func _orthogonal(axis: Vector3) -> Vector3:
	# 挑一个跟 axis 不平行的参考轴做叉乘，否则退化成零向量。
	var ref := Vector3(1, 0, 0)
	if absf(axis.x) > 0.9:
		ref = Vector3(0, 1, 0)
	return ref.cross(axis).normalized()


## 重新统计各面敌人数并重算压力，只在变化时广播。
func _recount_and_publish() -> void:
	_counts.clear()
	for e in _enemies:
		var s := e.refresh_sector(_ship_center)
		_counts[s] = int(_counts.get(s, 0)) + 1
	var changed := false
	for id in Sectors.IDS:
		var count: int = int(_counts.get(id, 0))
		var p := Sectors.pressure_from_count(count, _pressure_ref)
		if absf(p - float(_pressures.get(id, 0.0))) > 0.001:
			_pressures[id] = p
			changed = true
			EventBus.sector_pressure_changed.emit(id, p)
	# 只在「有扇区压力变了」时打一条汇总 —— 敌人平飞时压力不变，不会刷屏。
	if changed and DEBUG_LOG:
		print("[enemy] 压力更新 %s 存活=%d" % [str(_pressures), _enemies.size()])


## 按类型组装数值包，交给 Enemy.setup()。
## 后缀规则与 `data/enemies.json` 的字段命名一致：`<字段>_<type>`。
func _stats_for(type_id: StringName) -> Dictionary:
	var suffix := "bomber" if type_id == &"bomber" else "interceptor"
	return {
		"speed": _num("speed_" + suffix, 10.0),
		"hp": _num("hp_" + suffix, 20.0),
		"size": _num("size_" + suffix, 6.0),
		# 第⑤步：对炮塔的伤害速率。键名与 enemies.json 的 dps_<type> 一致；
		# 兜底 3.0 与 JSON 的 dps_interceptor 同值（改数值请改 JSON）。
		"dps": _num("dps_" + suffix, 3.0),
		"attack_range": _attack_range,
	}


func _load_config() -> void:
	_cfg = _load_json_section(DATA_PATH, "enemy")
	_ship_center = _vec3("ship_center", Vector3.ZERO)
	_spawn_radius = _num("spawn_radius", 190.0)
	_spawn_cone_deg = _num("spawn_cone_deg", 30.0)
	_attack_range = _num("attack_range", 52.0)
	_pressure_ref = _num("pressure_reference_count", 6.0)
	var d: Variant = _cfg.get("sector_distribution", {})
	if d is Dictionary:
		_dist = d as Dictionary
	else:
		push_warning("enemies.json 的 sector_distribution 不是对象，六面权重按 1.0 处理")


## 读 enemies.json 的指定段。文件缺失 / 解析失败 → 空字典，所有取值走兜底值。
## 返回空字典而不是 null，让调用方能统一用 `has()` 判断。
func _load_json_section(path: String, section: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("找不到 %s，敌人配置回退默认值" % path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("无法打开 %s，敌人配置回退默认值" % path)
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		push_warning("%s 解析失败，敌人配置回退默认值" % path)
		return {}
	var root := parsed as Dictionary
	if not root.has(section) or not (root[section] is Dictionary):
		push_warning("%s 里没有 %s 段，敌人配置回退默认值" % [path, section])
		return {}
	return root[section] as Dictionary


func _num(key: String, fallback: float) -> float:
	if not _cfg.has(key):
		return fallback
	return float(_cfg[key])


func _vec3(key: String, fallback: Vector3) -> Vector3:
	if not _cfg.has(key) or not (_cfg[key] is Array):
		return fallback
	var a: Array = _cfg[key]
	if a.size() < 3:
		return fallback
	return Vector3(float(a[0]), float(a[1]), float(a[2]))
