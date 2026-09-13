extends Node3D
class_name Enemy

## 单个敌人实体：按 `flight` 字段选一种飞行方式飞向飞船，进入攻击距离后
## **持续伤害最近存活炮塔**。
##
## 行为模型见 `docs/bible/02_entities.md §四`（Prototype 简化版）：
##   生成于扇区外缘 → 飞向飞船 → 进入攻击距离 → 攻击最近炮塔
##
## **DEC-049 · 飞行方式数据驱动分发**：本类不再把「直线飞进来停住」写死，
## 而是 `_step_flight()` 按 `_flight` 分发到 `_fly_<mode>()`。Phase 0 只有
## `hold`（= 原行为，逐帧等价）；`orbit` / `strike_retreat` 等后续加法是
## 「加一个函数 + JSON 加一个值」，不动任何现有型号。
##
## 第⑤步补齐了最后一环「攻击炮塔」：`advance()` 在 engaged 状态下每帧调 `_attack_tick`，
## 按 `dps × delta` 扣最近存活炮塔的耐久；该炮塔被毁则下一帧自动改打次近的
## （因为每次都重新找，无需保存目标引用 —— 天然满足 bible「改打下一个最近的」）。
##
## 数值全部由 EnemySystem 从 `data/enemies.json` 注入，本文件不 hardcode 任何数值。

## 类型 id，对应 enemies.json 里的 `<字段>_interceptor` / `<字段>_bomber` 后缀。
var type_id: StringName = &"interceptor"

## 本型号的飞行方式（DEC-049），取值来自 `enemies.json` 的 `flight_<type>`，
## 由 EnemySystem 在数据边界校验过（未知值会被退回 `hold`）。
## 本类只负责分发，不负责合法性判断。
var _flight: StringName = &"hold"

## 【日志纪律 2026-09-05】第⑤步「攻击炮塔」是本类的新行为 → 打印**打开**，
## 好在 Output 里直接确认敌人真的在啃炮塔；验完手玩后改 false。
## 日志只在「攻击目标变化」时打一条，绝不每帧打（敌人多时会瞬间淹没 Output）。
const DEBUG_LOG := false

## 生命值。③ 阶段没有任何来源能造成伤害（双方都不开火），字段先按
## `docs/bible/02_entities.md §四` 存着，第④步接入火力后才会被读写。
var hp: float = 0.0
## **本波的满血上限**（⑪ ⑤ 敌人血量反馈，2026-09-10）。
## 与 `Turret.hp_max` 同语义：难度缩放（`waves.json` 的 hp_scale）会改 hp，
## 若不同步记一份「缩放后的满血」，血条就算不出「还剩几成」——
## 表现是比例 > 1（血条爆表）。所以缩放只能走 `scale_hp()`，不许直接改 hp。
var hp_max: float = 0.0
var speed: float = 0.0
## 视觉边长（米），BoxMesh 用；第④步起给 Projectile 命中检测当 hitbox。
## 来自 stats["size"]，与 bible §一的「进场可见度」指标同源。
var size: float = 0.0
## 对炮塔的伤害速率（HP/秒）。悬停后按 `dps × delta` 连续扣血，
## 来自 enemies.json 的 `dps_<type>`（第⑤步新增，之前本类只能悬停干看着）。
var dps: float = 0.0
## 当前所属扇区（动态 —— 飞行中位置在变，归属也会变）。
var sector: StringName = &""

var _target := Vector3.ZERO
var _attack_range := 0.0
## 是否**已进入攻击距离**（= 可被炮塔锁定 / 正在交战）。
##
## ⚠ 2026-09-11 由 `_stopped` 改名并在语义上「瘦身」（DEC-049）。旧名字把两件事
## 挤在一起：「到了攻击距离」和「停下不动」。自动开火的目标筛选吃的是前者，
## 但名字表达的是后者 —— 于是「让敌人绕飞」会连带打断自动开火
## （绕飞 = 永不静止 → `acquire_target` 一架都锁不上，全船哑火）。
## 现在 `_engaged` 只表达「能不能打」，怎么飞由 `_step_flight()` 管。
var _engaged := false
## 本帧的真实速度向量（米/秒），`advance()` 用位置差采样。给 LeadPrediction 用。
var _velocity := Vector3.ZERO
## 船心。`_target` 是「**当前**正飞向的点」（绕飞 / 巡航时会变），`_center` 永远是真船心 ——
## 「离船多远」一律相对它算（交战判定 / 绕飞半径 / 掉头距离都吃它）。
var _center := Vector3.ZERO
## 是否**曾经**进入过交战。只用于让 `_flight_time` 只在首次进场前累计
## —— 巡航型会反复进出攻击圈，不区分的话「威胁窗口」这个诊断值会越累越长。
var _ever_engaged := false

## ── 飞行方式的旋钮（全部来自 enemies.json，本文件不 hardcode 数值）────
## 绕飞（orbit）切向速度相对 `speed` 的倍率。**命中率主旋钮**，见 JSON 的 `_doc_orbit`。
var orbit_speed_factor := 1.0
## 巡航（strike_retreat）掠过时与船心的最近距离。
var pass_distance := 30.0
## 巡航（strike_retreat）飞离到多远才掉头。
var retreat_range := 120.0

## 绕飞轴向：**进入绕飞那一刻定下，之后不再变** —— 轨迹因此可预测、可断言。
var _orbit_axis := Vector3.UP
## 巡航：本趟要掠过的点 / 出射方向 / 本趟的进近起点 / 是否处于「飞离段」/ 本趟的侧别。
var _pass_point := Vector3.ZERO
var _exit_dir := Vector3.FORWARD
var _run_entry := Vector3.ZERO
var _run_out := false
var _side := 1.0
## 当前正在打的炮塔 id。只用于**目标变化时打一条日志**（每帧打会淹没 Output），
## 不参与任何判定 —— 目标每帧重算，本字段对不上也不会打错人。
var _attack_target_id: StringName = &""
## 累计飞行时间（秒）。不参与任何玩法判定，纯粹是为了在悬停日志里打印
## 「从生成到进入攻击距离用了多久」—— 这个值就是 bible 里的**威胁窗口**，
## 改 spawn_radius / attack_range / speed 后能从日志直接读出新值，不用手算。
var _flight_time := 0.0

## ── ⑪ 命中闪白（知识库第 09 课反馈层 ②）────────────────────
## 与「死亡闪红」是两件事：闪白 = "我打中了"的即时反馈，闪红 = "打死了"的状态色。
## 只在存活时闪白；死亡路径仍走 `_flash_and_free` 的红。
var _dmg_mat: StandardMaterial3D
## 满血时的本色（随型号定，建网格时定死、之后不再变）。
## **为什么和 `_base_color` 分开**：⑤ 的 C 层让本色随血量变暗，
## `_base_color` 于是成了「当前血量对应的静止色」；要知道「原本长什么样」
## 才能按比例插值（拿变暗后的色再插值会越插越黑，回不到本色）。
var _full_color := Color(1, 1, 1)
## 当前静止色（= 按血量染过色的 `_full_color`）。闪白结束就还原到它。
var _base_color := Color(1, 1, 1)
var _flash_on := false
## 本次闪白剩余时长。
var _flash_left := 0.0
## 闪白之间的冷却。**为什么需要它**：白盒阶段敌人只挨弹丸（离散），
## 但一旦将来出现持续伤害来源，没有冷却就会"每帧重触发 → 一直白"，
## 从"闪了一下"退化成"变成一个白盒子"。有冷却则自动变成等间隔闪烁。
var _flash_cd := 0.0


## 由 EnemySystem 在 `add_child()` **之后**调用。
## 顺序很重要：global_position 要在节点进树后才能正常读写
## （详见 `enemy_system.gd` 的 spawn_one 注释）。
## 拆成 setup() 而不是塞进 _init，有两个原因：
## ① 数值的来源是 EnemySystem 手里已解析好的 JSON，不该每个敌人各读一次文件；
## ② 建 MeshInstance 子节点不要求父节点已在树上，但集中在这里做更好找。
func setup(p_type_id: StringName, spawn_pos: Vector3, target: Vector3, stats: Dictionary) -> void:
	type_id = p_type_id
	global_position = spawn_pos
	_target = target
	speed = float(stats.get("speed", 10.0))
	hp = float(stats.get("hp", 1.0))
	# hp_max 必须在 hp 之后赋值：它是「本波满血」的快照（同 Turret.configure 的顺序纪律）。
	hp_max = hp
	size = float(stats.get("size", 6.0))
	dps = float(stats.get("dps", 0.0))
	_attack_range = float(stats.get("attack_range", 50.0))
	# DEC-049：飞行方式。合法性由 EnemySystem._flight_for() 在数据边界保证
	# （未知值会被拦成 hold），这里只防御性取默认值 —— 直接 new() 出来做测试
	# 的敌人不经过 EnemySystem，也得能正常飞。
	_flight = StringName(String(stats.get("flight", "hold")))
	orbit_speed_factor = float(stats.get("orbit_speed_factor", 1.0))
	pass_distance = float(stats.get("pass_distance", 30.0))
	retreat_range = float(stats.get("retreat_range", 120.0))
	# 飞行/交战状态复位。setup() 现阶段只被调一次，但状态字段在这里归零成本为零，
	# 且将来若出现「对象池复用敌人」（避免频繁 allocate）这就是必须的一步。
	_center = target
	_engaged = false
	_ever_engaged = false
	_velocity = Vector3.ZERO
	_run_out = false
	_side = 1.0
	_flight_time = 0.0
	# 巡航型起飞前要先规划第一趟航线（通过点 / 进近起点都从当前位置算）。
	# 放在 sector 判定之前：_plan_run 会写 `_target`，而 sector 只吃 global_position，
	# 顺序其实无关 —— 但保持在"状态初始化"这一段里更好读。
	if _flight == &"strike_retreat":
		_plan_run(1.0)
	sector = Sectors.sector_of(global_position, _target)
	_build_mesh(size)
	# 进 group 供 Projectile 命中检测查找。
	# 原先 Projectile 用硬编码路径 "Bridge/EnemySystem" 找敌人，只要主场景改名或
	# 弹丸跑在独立测试场景里就会静默失效（表现为「打不中任何东西」且无报错）。
	# group 与场景结构解耦；常量引自 Projectile，避免两边字符串各写一份走样。
	add_to_group(Projectile.ENEMY_GROUP)


## 推进一帧。**由 EnemySystem 调用**，不是走 `_physics_process` ——
## 这样「移动」和「扇区统计」能在同一次遍历里完成，满编 20 个敌人时少 20 次回调。
## 返回 true 表示本帧**刚好进入攻击距离**（调用方可据此发一次事件）。
##
## **本函数不再自己算位移**（DEC-049）：位移整个交给 `_step_flight()` 分发出去的
## `_fly_<mode>()`，这里只做三件事 —— 采样真实速度、判「刚交战」、输出伤害。
## 这样「加一种飞行方式」永远不需要碰本函数。
##
## ⚠ 与 Phase 0 的差别：`_engaged` 现在**由各 `_fly_*()` 自行维护**，不再由本函数
## 一次性 latch。因为巡航型（strike_retreat）会**反复进出**攻击圈，
## 「进来了却不开火」或「飞走了还掉血」都源于这里没每帧重算。
func advance(delta: float) -> bool:
	_tick_flash(delta)
	# 「威胁窗口」只在**首次进场之前**累计。巡航型会反复进出攻击圈，
	# 不区分的话这个诊断值会越累越长、失去意义。
	if not _ever_engaged:
		_flight_time += delta
	var before := global_position
	var was_engaged := _engaged
	_step_flight(delta)
	# 真实速度 = 位置差 / delta。**用飞行前的位置**，且 delta 为 0 时不做除法
	# （固定步长测试传 0 会得到 inf，污染 LeadPrediction）。
	_velocity = (global_position - before) / delta if delta > 0.0 else Vector3.ZERO
	var just_engaged := (not was_engaged) and _engaged
	if _engaged:
		_ever_engaged = true
	if just_engaged:
		# 交战那一帧只标记、不输出伤害（与拆分前一致，少一次 dps×delta，无感）。
		return true
	if _engaged:
		_attack_tick(delta)
	return false


## 飞行方式分发（DEC-049）。
##
## **加一种飞行方式 = 这里加一个分支 + `_fly_xxx()` + enemies.json 加一个值**，
## 不改任何现有型号。取值合法性已由 `EnemySystem._flight_for()` 在数据边界校验过
## （未知值会被退回 hold），所以 `_` 分支只是防御性兜底，不是主路径。
##
## 各 `_fly_*()` 的职责：**改位置 + 维护 `_engaged`**。不要在这里判伤害/闪白。
func _step_flight(delta: float) -> void:
	match _flight:
		&"orbit":
			_fly_orbit(delta)
		&"strike_retreat":
			_fly_strike_retreat(delta)
		_:
			_fly_hold(delta)


## hold：直线飞向目标点，进入 `attack_range` 后**停住不动**并持续输出。
##
## bible 02 §四 的 Prototype 初版行为。**与拆分前逐帧等价**（Phase 0 的回归全绿
## 就是靠这个等价关系证明「语义拆分没改变表现」）。
## `_engaged` 在这里是**一次性 latch**：停下来就不再离开，符合"悬停"的定义。
func _fly_hold(delta: float) -> void:
	if _engaged:
		return
	var to_target: Vector3 = _target - global_position
	var dist := to_target.length()
	if dist <= _attack_range:
		_engaged = true
		return
	var step := speed * delta
	if step >= dist:
		global_position = _target
		_engaged = true
		return
	global_position += to_target.normalized() * step


## orbit：进场照旧走直线，**进入攻击距离后沿「以船心为圆心、attack_range 为半径」的圆飞行**。
##
## 半径恒等于 `attack_range` → 绕飞不改变「离船多远」，威胁窗口与 hold 相同；
## 变的只是**它在动**。李 2026-09-11 拍板「贴着 attack_range 绕」即此。
##
## ⚠ 两个必须知道的设计后果（不是 bug）：
##   ① 绕整船一圈会**跨扇区** —— 扇区压力会随时间转移（系统本来就支持"扇区动态"）；
##   ② `_attack_tick` 每帧找最近炮塔 → 伤害会**摊到沿途各门炮**，而不是集中打爆一门。
##      若这削弱了「战损驱动改装」的决策感，调小 `orbit_speed_factor` 或改回 hold。
func _fly_orbit(delta: float) -> void:
	if not _engaged:
		_fly_hold(delta)
		if _engaged:
			# 用**进入攻击距离那一刻的径向**定轴：之后整条轨迹就确定了。
			_orbit_axis = _orbit_axis_for(global_position - _center)
		return
	var radial := global_position - _center
	if radial.length_squared() < 1e-6:
		radial = Vector3.FORWARD   # 退化保护：恰好与船心重合时不该发生，兜一下不崩
	var angular := speed * orbit_speed_factor / maxf(_attack_range, 0.01) * delta
	global_position = _center + radial.rotated(_orbit_axis, angular)


## 绕飞轴：径向与 UP 近乎平行时（正上 / 正下方来袭）绕 UP 转等于**原地不动**，
## 换一根不平行的轴，保证「一定看得见它在动」。
func _orbit_axis_for(radial: Vector3) -> Vector3:
	var r := radial.normalized()
	return Vector3.BACK if absf(r.dot(Vector3.UP)) > 0.9 else Vector3.UP


## strike_retreat：**反复来回的进攻航线**（中型 / 重甲）。
##
## **⚠ 不是「打完就逃」** —— 李 2026-09-11 明确纠正：
## 「它们都是会来回进攻的，飞来飞去的进攻，不是说逃跑了」。
## 所以这是一个**循环**：冲进来打一趟 → 顺着飞出去 → 掉头从另一侧再冲一趟，如此往复。
## **玩家不能靠"等它飞走"来过波**，必须把它打掉。
##
## 与 hold 的两点本质差别：
##   ① `_engaged` **每帧由几何重算**（离船心 ≤ attack_range 才算交战），
##      于是「穿过攻击圈的那一段」在打、「回旋段」不打 —— 伤害自然变成脉冲式；
##   ② 掠过时**不会穿过船体**：通过点偏离船心 `pass_distance`，是"擦着过去"的航线。
func _fly_strike_retreat(delta: float) -> void:
	if _run_out:
		global_position += _exit_dir * speed * delta
		if global_position.distance_to(_center) >= retreat_range:
			# 飞够远了 → 掉头，**从另一侧**规划下一趟。
			# 「换侧」是这条航线的灵魂：原路来回 = 忽进忽退（李明确不要）。
			_plan_run(-_side)
	else:
		var to_pass := _pass_point - global_position
		var dist := to_pass.length()
		var step := speed * delta
		if dist <= step:
			global_position = _pass_point
			# 到通过点 → 顺着**本趟的进近航向**飞出去（不是原地掉头，所以"顺着飞走"）。
			var heading := _pass_point - _run_entry
			if heading.length_squared() > 1e-6:
				_exit_dir = heading.normalized()
			_run_out = true
		else:
			global_position += to_pass.normalized() * step
	# 交战状态每帧重算（理由见类注释 ①）。它同时决定「能不能被锁定」与「打不打炮塔」。
	_engaged = global_position.distance_to(_center) <= _attack_range


## 规划一趟攻击航线：算好本趟的通过点，并记下进近起点（用于推出射方向）。
##
## `side` = ±1 决定从船心的哪一侧掠过；每次掉头都翻号，于是来回两趟走不同侧。
func _plan_run(side: float) -> void:
	_side = side
	var dir := _center - global_position
	if dir.length_squared() < 1e-6:
		dir = Vector3.FORWARD
	dir = dir.normalized()
	var perp := dir.cross(Vector3.UP)
	if perp.length_squared() < 1e-6:
		# 正上 / 正下方向进近时 cross(UP) 退化为零向量 → 换一根参考轴。
		perp = dir.cross(Vector3.BACK)
	if perp.length_squared() < 1e-6:
		perp = Vector3.RIGHT
	_pass_point = _center + perp.normalized() * pass_distance * side
	# `_target` 要跟着走：flight_target() 报告的是「我正朝哪飞」，
	# 提前量诊断 / 未来调试都吃它，停在船心上就是假值。
	_target = _pass_point
	_run_entry = global_position
	_run_out = false


## 交战状态（engaged）下的攻击：按 `dps × delta` 扣最近存活炮塔的耐久。
##
## **为什么每帧重找目标而不缓存**：bible 02 §四要求「该炮塔死则改打下一个最近的」。
## 缓存引用要自己订阅 turret_destroyed 并清理，还会遇到「悬空引用」；
## 每帧重找天然满足该规则，5 门炮的遍历开销可以忽略。
##
## ⚠ 一个已知的几何事实（不是 bug，但会影响手感）：bible 写的是「最近」，
## 没限定扇区。而 fore 来袭的敌人停在中轴线外 52m 处，到主炮（舰桥内 z=-0.6）
## 与到 dorsal/ventral 炮（±8.5m）的距离只差约 0.1m —— 它可能先啃上/下副炮。
## 现阶段按 bible 字面实现，若实测「主炮不是最后沦陷」，改这里加扇区限定即可。
func _attack_tick(delta: float) -> void:
	if dps <= 0.0:
		return
	var t := _nearest_alive_turret()
	if t == null:
		if _attack_target_id != &"" and DEBUG_LOG:
			print("[enemy] %s 无炮塔可打（全部被毁）" % name)
		_attack_target_id = &""
		return
	if t.turret_id != _attack_target_id:
		_attack_target_id = t.turret_id
		if DEBUG_LOG:
			print("[enemy] %s 开始攻击 %s（距 %.1fm dps=%.1f）" % [
				name, t.turret_id, global_position.distance_to(t.muzzle_pos), dps])
	t.take_damage(dps * delta, type_id)


## 距本敌人最近的**存活**炮塔；全毁时返回 null。
## 与 Turret.acquire_target 找敌人的写法对称：都走 group，都不认场景结构。
func _nearest_alive_turret() -> Turret:
	var best: Turret = null
	var best_dist: float = INF
	for node in get_tree().get_nodes_in_group(Turret.TURRET_GROUP):
		var t := node as Turret
		if t == null or not t.is_alive():
			continue
		var d: float = global_position.distance_to(t.muzzle_pos)
		if d < best_dist:
			best_dist = d
			best = t
	return best


## 重算所属扇区，返回新值（EnemySystem 拿它判断有没有跨扇区）。
func refresh_sector(center: Vector3) -> StringName:
	sector = Sectors.sector_of(global_position, center)
	return sector


## 累计飞行时间（秒），给 EnemySystem 的悬停日志用。
func flight_time() -> float:
	return _flight_time


## 难度缩放：`hp` 与 `hp_max` **同乘**（⑪ ⑤）。
##
## **为什么必须是方法，而不是让 WaveSystem 写一行 `e.hp *= scale`**：
## hp_max 若不跟着乘，血条会把「已经放大的血量」当成超上限，算出的比例 > 1。
## 之前没有血条时直接改 hp 是安全的；现在不行了 —— 把不变量收进实体自己身上。
## scale <= 0 或 == 1 时不动（1.0 是默认，避免每波无谓地乘一遍）。
func scale_hp(scale: float) -> void:
	if scale <= 0.0 or is_equal_approx(scale, 1.0):
		return
	hp *= scale
	hp_max *= scale


## 剩余血量比例 0..1（血条 / 本色染色都吃它）。
## hp_max 尚未初始化（= 0）时返回 1 —— 避免除零，也让「还没设血量的测试敌人」显示满血。
func hp_ratio() -> float:
	if hp_max <= 0.0:
		return 1.0
	return clampf(hp / hp_max, 0.0, 1.0)


## 本敌人正飞向的那个点（通常是船心，由 EnemySystem 从 enemies.json 的
## ship_center 算出后注入 setup）。
##
## **为什么要暴露**：调用方原本**自己 hardcode 了一份 ship_center**，等于船心坐标
## 在代码里存了两份 —— 改 JSON 里的 ship_center 时那边不会跟着变，就会系统性偏。
## 违反「数值只给旋钮不给终值」，故改为从敌人身上读真值。
##
## ⚠ DEC-049 起它**不再是提前量的来源**：那是 `velocity()` 的活。本函数只回答
## 「我正朝哪飞」，飞行方式一变（绕飞 / 撤离）这个点仍然是真值，但由它推速度就不准了。
func flight_target() -> Vector3:
	return _target


## 本帧的真实速度向量（米/秒），由 `advance()` 用「位置差 / delta」采样。
##
## **为什么不再让调用方自己推方向**：旧写法是
## `(flight_target() - global_position).normalized() * speed` —— 它假设敌人
## **永远直线匀速飞向目标点**。直线飞行时这是对的，但绕飞的切向速度、
## 撤离时的反向速度都推不出来，弹道提前量会系统性偏（表现为「手动接管打
## 移动中的敌人总是打空，自动开火反而准 —— 因为自动开火只在 engaged 时打」）。
## 采样真值对任何飞行方式都成立，且直线飞行时与旧算法**逐帧等价**。
##
## 未推进过时返回 ZERO，语义与「静止」一致 —— 调用方不必特判 hover。
func velocity() -> Vector3:
	return _velocity


## 是否已进入攻击距离（= 可被炮塔锁定 / 正在交战）。
##
## ⚠ **这是「能不能锁」的唯一权威判据**，`Turret.acquire_target()` 吃它。
## 它与「是否静止」是两件事 —— 拆分前两者共用一个 `is_hovering()`，
## 于是「让敌人绕飞」会连带打断自动开火（绕飞 = 永不静止 → 一架都锁不上）。
## 见 DEC-049。
func is_engaged() -> bool:
	return _engaged


## 是否正**静止**悬停在攻击距离上。只表达「不动」，不表达「能不能打」
## —— 需要后者请用 `is_engaged()`。
##
## 现在等价于「engaged 且 flight == hold」，因为 hold 是唯一的静止飞行方式；
## 将来加 orbit / strike_retreat 后它天然为 false，本函数无需再改。
func is_hovering() -> bool:
	return _engaged and _flight == &"hold"


## 当前飞行方式（自省 / 测试用；业务代码不该靠它做判定，该由 `_step_flight` 分发）。
func flight_mode() -> StringName:
	return _flight


## 是否已死亡（hp<=0）。第④步起用于过滤「已被打掉不应再挨命中检测」的敌人。
func is_dead() -> bool:
	return hp <= 0.0


## 受击扣血（由 Projectile._test_hit 调用）。source_id = 攻击炮塔 id，便于回放/统计。
## 死亡判定放在扣血后立刻做：hp<=0 → emit enemy_killed → queue_free。
## 死亡演出：白盒阶段做一个 0.15 s 的红色闪一帧的视觉提示，避免「死人突然消失」突兀。
## 真正的爆炸 / 碎片是 P1（BACKLOG §P1 炮塔陷落演出 + VFX）。
##
## ⚠️ 2026-09-06 预修复：参数加 `_` 前缀抑制 unused_parameter 警告，但保留参数名
##（⑤ 接入「敌打炮塔」时该参数会被读——用于伤害归属统计）。
func take_damage(amount: float, _source_id: StringName) -> void:
	if hp <= 0.0:
		return
	hp = maxf(0.0, hp - amount)
	# ⑪ ⑤ 广播受伤：**离散事件**（一发一发），与炮塔的每帧持续 dps 不同，
	# 所以走总线不会被刷爆。hp_max 一起带上，订阅方才知道「还剩几成」。
	EventBus.enemy_damaged.emit(self, amount, hp, hp_max)
	if hp <= 0.0:
		EventBus.enemy_killed.emit(self)
		_flash_and_free()
		return
	# ⑪ ⑤ C 层：血量掉了 → 本色跟着暗一档（越残越暗，"这台快散了"要能从余光看出来）。
	# **排在闪白之前**：闪白会覆盖材质色，顺序反了就会把染色顶掉。
	_apply_hp_tint()
	# ⑪ 挨了但没死 → 闪白一下。**不含任何数值**：时长与颜色取自 FeelKit
	# （presentation.json 的 feel 段），与炮塔闪白共用同一组旋钮。
	_hit_flash()


## ⑪ ⑤ C 层：按剩余血量给本体上色（越残越暗）。
##
## 数值（目标暗色 / 曲线）来自 `HealthKit`（`presentation.json` 的 `healthbar` 段），
## 实体层不 hardcode 颜色 —— 与闪白走 FeelKit 是同一条纪律。
##
## ⚠ **闪白进行中只更新 `_base_color`，不写材质**：闪白此刻正占着材质，
## 直接写会把它盖掉 —— 表现是「打中了却没闪」，把 ⑪ 第一层刚验过的闪白静默吃掉。
## 等闪白结束，`_tick_flash` 会还原到更新后的 `_base_color`（这就是它必须是
## 「按血量染过色的静止色」而不是「满血本色」的原因）。
func _apply_hp_tint() -> void:
	if _dmg_mat == null or not is_instance_valid(_dmg_mat):
		return
	_base_color = HealthKit.tint_color(_full_color, hp_ratio())
	if not _flash_on and hp > 0.0:
		_dmg_mat.albedo_color = _base_color


## ⑪ 命中闪白：材质提亮一瞬再还原。
##
## 数值来自 `FeelKit`，本类不存常量（"数值只给旋钮不给终值"）。
## ⚠ `MeshInstance3D` 没有 `modulate`（那是 CanvasItem / 2D 的属性），
## 变色的唯一途径是改 `StandardMaterial3D.albedo_color` —— 分量允许 > 1，
## 会一并抬高自发光，这正是暗舱里"亮了一下"的来源。
func _hit_flash() -> void:
	if _flash_on or _flash_cd > 0.0 or _dmg_mat == null:
		return
	var ft := FeelKit.flash_time()
	if ft <= 0.0:
		return
	# 注意：这里**不再**从材质回抄 `_base_color`（旧写法这样做）。
	# 现在 `_base_color` 由 `_apply_hp_tint` 权威维护，是「按血量染过色的静止色」；
	# 从材质回抄会在闪白冷却期内抄到一个错的中间态。
	_dmg_mat.albedo_color = FeelKit.flash_color()
	_flash_on = true
	_flash_left = ft


## 每帧推进闪白。由 `advance()` 调（与移动/攻击同一次遍历，不额外开 _process）。
## 恢复前要确认**还活着**：死亡路径已经把颜色刷成红了，这里再还原会把它擦掉。
func _tick_flash(delta: float) -> void:
	if _flash_on:
		_flash_left -= delta
		if _flash_left > 0.0:
			return
		_flash_on = false
		_flash_cd = FeelKit.flash_time()      # 冷却 = 一个闪白时长 → 连续受击变等间隔闪烁
		if hp > 0.0 and _dmg_mat != null and is_instance_valid(_dmg_mat):
			_dmg_mat.albedo_color = _base_color
	elif _flash_cd > 0.0:
		_flash_cd -= delta


## 自省：当前身体材质颜色（测试断言"闪了 / 还原了"用，不比字符串，比颜色值）。
func body_color() -> Color:
	if _dmg_mat == null:
		return Color(0, 0, 0)
	return _dmg_mat.albedo_color


## 红色闪烁 + 释放。死亡演出不延迟（不等动画），用 call_deferred 在下一帧释放。
## 闪红：临时把 Body 材质改成红色，0.15s 后释放。
## 注意：MeshInstance3D 是 3D 节点，**没有 modulate 属性**（modulate 只属于
## CanvasItem / 2D）。要变色必须改 StandardMaterial3D.albedo_color。
func _flash_and_free() -> void:
	var body := get_node_or_null("Body") as MeshInstance3D
	if body != null:
		var mat := body.material_override as StandardMaterial3D
		if mat != null:
			mat.albedo_color = Color(2.0, 0.4, 0.3)   # >1 是有意为之，让 StandardMaterial 自发光一起变亮
	# 0.15 s 后释放（call_deferred 走当前帧结束，避免 advance 同帧访问已释放节点）
	get_tree().create_timer(0.15).timeout.connect(func() -> void:
		if is_inside_tree():
			queue_free())


## 白盒视觉：一个立方体，两型靠颜色 + 尺寸区分。
## 用简单几何而非正式素材，是因为 DEC-028「CC0 素材替换」在 BACKLOG 里是 P1，
## Prototype 阶段先让逻辑跑起来。（尺寸已按 1080p 下进场 ≥15px 验算过，见自检③）
##
## ⚠️ 2026-09-06 预修复：参数 `size` 原本与类成员 `var size` 同名，触发
## shadowing 警告；改名 `mesh_size`。与 `setup()` 内的 `size = stats.get("size")`
## 解耦——这里吃参数，不依赖类成员。
func _build_mesh(mesh_size: float) -> void:
	var mi := MeshInstance3D.new()
	mi.name = "Body"
	var box := BoxMesh.new()
	box.size = Vector3(mesh_size, mesh_size, mesh_size)
	mi.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.25, 0.2) if type_id == &"interceptor" else Color(0.95, 0.6, 0.15)
	mi.material_override = mat
	# ⑪ 存下来供闪白 / 血量染色用：它们是"真源"不是缓存副本——
	# `_full_color` = 满血本色（C 层按比例插值的起点），`_base_color` = 当前静止色。
	_dmg_mat = mat
	_full_color = mat.albedo_color
	_base_color = mat.albedo_color
	add_child(mi)
