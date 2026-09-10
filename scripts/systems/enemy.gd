extends Node3D
class_name Enemy

## 单个敌人实体：直线飞向飞船，进入攻击距离后停住并**持续伤害最近存活炮塔**。
##
## 行为模型见 `docs/bible/02_entities.md §四`（Prototype 简化版）：
##   生成于扇区外缘 → 直线飞向飞船 → 进入攻击距离 → 攻击最近炮塔
##
## 第⑤步补齐了最后一环「攻击炮塔」：`advance()` 在悬停状态下每帧调 `_attack_tick`，
## 按 `dps × delta` 扣最近存活炮塔的耐久；该炮塔被毁则下一帧自动改打次近的
## （因为每次都重新找，无需保存目标引用 —— 天然满足 bible「改打下一个最近的」）。
##
## 数值全部由 EnemySystem 从 `data/enemies.json` 注入，本文件不 hardcode 任何数值。

## 类型 id，对应 enemies.json 里的 `<字段>_interceptor` / `<字段>_bomber` 后缀。
var type_id: StringName = &"interceptor"

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
var _stopped := false
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
	sector = Sectors.sector_of(global_position, _target)
	_build_mesh(size)
	# 进 group 供 Projectile 命中检测查找。
	# 原先 Projectile 用硬编码路径 "Bridge/EnemySystem" 找敌人，只要主场景改名或
	# 弹丸跑在独立测试场景里就会静默失效（表现为「打不中任何东西」且无报错）。
	# group 与场景结构解耦；常量引自 Projectile，避免两边字符串各写一份走样。
	add_to_group(Projectile.ENEMY_GROUP)


## 推进一帧。**由 EnemySystem 调用**，不是走 `_physics_process` ——
## 这样「移动」和「扇区统计」能在同一次遍历里完成，满编 20 个敌人时少 20 次回调。
## 返回 true 表示本帧刚好进入攻击距离并停住（调用方可据此发一次事件）。
##
## 悬停后不再移动，改为每帧 `_attack_tick` 输出伤害（第⑤步）。
func advance(delta: float) -> bool:
	_tick_flash(delta)
	if _stopped:
		_attack_tick(delta)
		return false
	_flight_time += delta
	var to_target: Vector3 = _target - global_position
	var dist := to_target.length()
	if dist <= _attack_range:
		_stopped = true
		return true
	var step := speed * delta
	if step >= dist:
		global_position = _target
		_stopped = true
		return true
	global_position += to_target.normalized() * step
	return false


## 悬停状态下的攻击：按 `dps × delta` 扣最近存活炮塔的耐久。
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
## **为什么要暴露**：LeadPrediction 需要目标速度，而敌人是直线匀速飞行，
## 速度方向 = (飞行目标 - 当前位置).normalized()。调用方（Turret._target_velocity）
## 原本**自己 hardcode 了一份 ship_center**，等于船心坐标在代码里存了两份 ——
## 改 JSON 里的 ship_center 时这里不会跟着变，弹道预测就会系统性偏。
## 违反「数值只给旋钮不给终值」，故改为从敌人身上读真值。
func flight_target() -> Vector3:
	return _target


## 是否已进入攻击距离并悬停。
func is_hovering() -> bool:
	return _stopped


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
