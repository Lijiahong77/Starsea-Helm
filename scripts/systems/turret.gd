extends Node3D
class_name Turret

## 炮塔基类（主炮 + 副炮共用，bible 02 §二）
##
## **职责边界**：第④步打通「自动开火 + 手动接管开火 + 扣敌血」；第⑤步打通
## 「挨打扣血 → 耐久归零 → 被毁 → 不再开火 / 不可接管 → 每波回满」。
## 本类负责状态机（自动 / 手动）、瞄准、开火、发射 Projectile、**耐久与被毁**；
## 不管：① 切相机（TurretSystem 负责）② VFX / 音效 ③ 谁在打我（Enemy 主动调用 take_damage）。
##
## **耐久的伤害来源在 Enemy 侧**：敌人悬停后每帧调 `take_damage(dps * delta)`。
## 为什么不让 TurretSystem 反过来扫敌人：bible 02 §四写的是「敌人持续伤害**最近**存活炮塔」，
## 「最近」是相对**敌人**算的，只有敌人自己知道；反过来扫会多一次 O(敌×炮) 遍历且语义绕。
##
## **不靠 _physics_process 自动跑**：由 TurretSystem 在 _physics_process 中对所有
## turret 统一调 advance(delta)，理由同 enemy_system / projectile —— 减少 N 次回调。
## 但**本类自带 _physics_process 兜底**：万一被独立 add_child 也能正常动（测试场景）。
##
## **数值外置**：所有配置从 data/turrets.json 读取，setup() 时由 TurretSystem 注入；
## 本类不读 JSON 文件 —— 单一 JSON 读源在 TurretSystem，符合「架构地基不让业务散开读」原则。
##
## **手动模式不发弹**：本类收到 EventBus.turret_fired(turret_id) 且匹配 self.turret_id 才发；
## 也就是 Turret 是「响应者」不是「轮询者」，手动的频率由玩家按扳机节奏决定（bible §一行 22）。

enum Mode { AUTO, MANUAL }

## 【日志纪律 2026-09-05 · 用户要求】新模块默认打开 print，验完改 false。
## 本类发射日志只在状态变化时打（开火 / 切模式），不每帧刷。
const DEBUG_LOG := false

## 所有炮塔所在的 group 名。敌人用它找「最近存活炮塔」，
## 与 Projectile.ENEMY_GROUP 同一套路：group 与场景结构解耦，
## 主场景改名 / 跑在独立测试场景里都不会失效（硬编码路径会）。
const TURRET_GROUP := &"turrets"

## 该炮塔身份（玩家按 1-5 接管时按这个 id 路由）。子类构造时设。
var turret_id: StringName = &""
## 所属扇区（fore/port/starboard/dorsal/ventral；aft 按 DEC-036 不设炮塔，
## ventral 按 DEC-052 也不设 —— 扇区定义仍在，只是这两面永远没有炮塔）。
var sector: StringName = &""

## 当前模式：AUTO 默认（battle 开始时进入）；MANUAL 由 TurretSystem 接管时切。
var mode: int = Mode.AUTO
## 自动开火累计计时（到 fire_interval 时发弹）。
var _auto_fire_timer := 0.0
## 自动模式下是否允许开火（false = 暂停 / 不可开火，如不在 BATTLE 状态）
var _auto_enabled := false

## 数值（来自 turrets.json）
## hp = 当前耐久；hp_max = 满耐久（configure 时快照，供每波回满与 HUD 百分比用）。
var hp := 0.0
var hp_max := 0.0
var auto_dps := 0.0
var auto_fire_interval := 0.25
var projectile_speed := 200.0
var projectile_damage := 1.0
## 最大射程（米）。命名避开 built-in `range()`；调用方读 `t.fire_range`。
var fire_range := 130.0
var projectile_max_lifetime := 4.0
var visual_size := Vector3(0.5, 0.5, 1.2)
## 白盒炮管颜色。⑦ 起由 variants 提供 —— 换装时**外观真的变**（颜色 + 尺寸），
## 这是无模型阶段唯一能让玩家「看出换家伙了」的信号（李 2026-09-08 提的痛点）。
var visual_color := Color(0.4, 0.45, 0.5)
## 炮位（世界坐标），从 turrets.json 读；手动模式时用来算 LeadPrediction。
var muzzle_pos := Vector3.ZERO
## 开火音效 id（⑩ 音频，来自 turrets.json 的 fire_sfx）。
## 一门一型：速射 / 标准 / 重炮的射速差 3 倍，共用一个音会让玩家听不出换的是哪门。
## **只存 id，不存路径** —— 音效的路径/音量/防爆阈值全在 data/audio.json。
var fire_sfx: StringName = &"sfx_sub_gun_fire"

## 状态：是否已销毁（耐久归零）。被毁后不再开火、不可接管、不再挨打。
var destroyed := false

## 白盒视觉的炮管节点，被毁时改材质（变暗红）用。由 _build_visual 赋值。
var _barrel: MeshInstance3D

## ── ⑪ 命中闪白（知识库第 09 课反馈层 ②）────────────────────
## 炮塔是被啃的一方，闪白让玩家在余光里也能看出"这一面正在挨打"。
## 与敌人那边同机制、同旋钮（都走 FeelKit）；差别是恢复要调 `_apply_alive_visual()`
## 而不是写死一个颜色 —— 炮塔本色随型号变（visual_color），写死就会把型号色擦掉。
var _flash_on := false
var _flash_left := 0.0
var _flash_cd := 0.0

## ── ⑪ ③ 临界警报（2026-09-11 · DEC-048）────────────────────
## 敌人是**持续 dps**（每物理帧调 take_damage），所以受击反馈不能按帧给。
## 改为「跨阈值才响一次」：耐久首次跌破 `FeelKit.critical_ratio()` 时，
## emit 一条**低频**的 `turret_critical` → GameFeel 重震一次 + AudioManager 响警报。
## 每波由 `restore()` 复位，所以「这一波已经报过警」不会跨波残留。
var _critical_fired := false


func _ready() -> void:
	# 监听手动发射信号。本类自己 connect 不合适（多个 turret 会重复 connect 同一个 signal），
	# 但实际 EventBus 是 Node，每个信号只 connect 一次没问题 —— Turret 自己 connect 是正确的
	# 写法（subsystem 依赖最小化），TurretSystem 不需要重新分发。
	EventBus.turret_fired.connect(_on_turret_fired)
	# 进 group 供 Enemy 找「最近存活炮塔」。与 Enemy 进 Projectile.ENEMY_GROUP 对称。
	add_to_group(TURRET_GROUP)


## 由 TurretSystem 调用：注入 turrets.json 读出的配置。
## 调用顺序：t = turret_class.new(); add_child(t); t.configure({dict}); t.snap_to(muzzle_pos)。
func configure(cfg: Dictionary) -> void:
	turret_id = StringName(cfg.get("id", &""))
	sector = StringName(cfg.get("sector", &""))
	hp = float(cfg.get("hp", 100.0))
	# hp_max 必须在 hp 之后赋值：它是「这一波开局时的满耐久」快照。
	# 顺序写反会让 restore() 把耐久回满成 0，且**不报错** —— 表现为"一开战炮塔就全没了"。
	hp_max = hp
	auto_dps = float(cfg.get("auto_dps", 10.0))
	auto_fire_interval = float(cfg.get("auto_fire_interval", 0.25))
	projectile_speed = float(cfg.get("projectile_speed", 200.0))
	projectile_damage = float(cfg.get("projectile_damage", 3.0))
	# 注：字段名是 fire_range（避开 built-in range()），JSON 里的键仍叫 "range"。
	fire_range = float(cfg.get("range", 130.0))
	projectile_max_lifetime = float(cfg.get("projectile_max_lifetime", 4.0))
	var sz: Array = cfg.get("visual_size", [0.5, 0.5, 1.2])
	visual_size = Vector3(float(sz[0]), float(sz[1]), float(sz[2]))
	var col: Array = cfg.get("visual_color", [0.4, 0.45, 0.5])
	visual_color = Color(float(col[0]), float(col[1]), float(col[2]))
	# ⑩ 开火音：缺省值让「配置漏写 fire_sfx」退化成能听见，而不是静默。
	fire_sfx = StringName(cfg.get("fire_sfx", &"sfx_sub_gun_fire"))
	muzzle_pos = Vector3(float(cfg.get("mount", [0, 1.5, -0.6])[0]),
		float(cfg.get("mount", [0, 1.5, -0.6])[1]),
		float(cfg.get("mount", [0, 1.5, -0.6])[2]))


## 把炮塔挪到 muzzle_pos（mount 来自 turrets.json）；同时建白盒视觉。
## 由 TurretSystem 在 configure 后调用。
func snap_to() -> void:
	global_position = muzzle_pos
	_build_visual()


## 由 TurretSystem 调用：每物理帧推进一次。
## ① 自动模式：累计时间到 fire_interval 时打一炮
## ② 手动模式：玩家按扳机（已通过 EventBus 触发 _on_turret_fired），不在这里打
## 自动模式下若找不到目标（视野里没敌），静默 skip，不刷屏。
func advance(delta: float) -> void:
	_tick_flash(delta)
	if destroyed:
		return
	if mode == Mode.MANUAL:
		return   # 手动模式由玩家扳机触发，不在自动循环里发
	if not _auto_enabled:
		return
	_auto_fire_timer += delta
	if _auto_fire_timer < auto_fire_interval:
		return
	_auto_fire_timer = 0.0
	var target := acquire_target()
	if target == null:
		return
	_fire(_aim_dir(target), target)


## 自动模式的开火方向（DEC-049 Phase 1）。
##
## 旧实现是「直接指向目标当前位置」，注释还写着「敌人悬停时不需要 LeadPrediction」
## —— 那是 **hold 是唯一飞行方式时的结论**，不是一条普遍规律。
## 一旦敌人会绕飞 / 巡航，按当前位置开火会**系统性打空**：
## 弹丸飞 52m 要 ≈0.26 s，这段时间目标已横移好几米，而敌人 hitbox 只有 6~14 m。
## 表现是「自动炮明明在响，敌人血不掉」——最容易被误判成命中检测坏了。
##
## 现在：有速度就算提前量，没速度（悬停）就等价于旧行为。
## **不动 = 提前点为它本身**，所以这个改动对 hold 敌人逐帧等价。
func _aim_dir(target: Enemy) -> Vector3:
	var v: Vector3 = target.velocity()
	var aim_at: Vector3 = target.global_position
	if v.length_squared() > 1e-4:
		var intercept := LeadPrediction.intercept_point(
			muzzle_pos, target.global_position, v, projectile_speed)
		if intercept.length_squared() > 1e-6:
			aim_at = intercept
	var to_aim := aim_at - muzzle_pos
	if to_aim.length_squared() < 1e-6:
		return Vector3.ZERO
	return to_aim.normalized()


## 接管/退接管由 TurretSystem 调。Turret 自己仅切 mode 标志，不动相机。
func set_mode(m: int) -> void:
	if m != Mode.AUTO and m != Mode.MANUAL:
		push_warning("[turret] %s set_mode(%d) 非法 enum" % [turret_id, m])
		return
	mode = m


## 战斗状态开关：BATTLE 进入时 enable，BATTLE 退出时 disable（避免 REFIT 阶段乱开火）。
func set_auto_enabled(b: bool) -> void:
	_auto_enabled = b
	if not b:
		_auto_fire_timer = 0.0   # 重置计时器，下次 enable 时从头计


## ⑦ 当前是否允许自动开火。TurretSystem.swap_turret 用它把状态**继承给新炮**，
## 否则在 BATTLE 中途换装会得到一门「装上去但不开火」的炮，看起来像换装失败。
func is_auto_enabled() -> bool:
	return _auto_enabled


## 是否还能战斗（耐久 > 0 且未被毁）。敌人挑目标、HUD 显血都看它。
func is_alive() -> bool:
	return not destroyed


## 剩余耐久比例 0..1。与 `Enemy.hp_ratio()` 同语义（临界判定与将来的血条都用它）。
## hp_max 未初始化（= 0）时返回 1：避免除零，也让「还没 configure 的测试炮塔」显示满状态。
func hp_ratio() -> float:
	if hp_max <= 0.0:
		return 1.0
	return clampf(hp / hp_max, 0.0, 1.0)


## ⑪ ③ 临界警报：耐久**首次**跌破 `FeelKit.critical_ratio()` 时 emit 一次 turret_critical。
##
## **为什么实体只发事件、不自己放音效 / 震屏**：这两件事分别归 ⑩（音）与 ⑪（相机），
## 且都要靠接线表（audio.json 的 `events` / presentation.json 的 `feel.events`）分发强度 ——
## 实体只该负责「我进入危险状态了」这个**事实**。⑩ 的 `turret_destroyed` 是同一套写法。
##
## 阈值取 0 视为关闭该反馈（`FeelKit.critical_ratio()` 返回 0 直接 return）。
## `_critical_fired` 先置位再 emit：避免订阅方在回调里又把本函数拽起来造成重入。
func _check_critical() -> void:
	if _critical_fired:
		return
	var threshold := FeelKit.critical_ratio()
	if threshold <= 0.0:
		return
	if hp_ratio() > threshold:
		return
	_critical_fired = true
	EventBus.turret_critical.emit(turret_id, sector)


## 挨打（⑤ 炮塔耐久）。由 Enemy 在悬停时每帧调用，amount = dps × delta。
##
## **伤害是连续的，不是一发一发的**：bible 02 §四「进入攻击距离后**持续**伤害」，
## 所以这里不以「一次攻击事件」建模，敌人侧只管按 dps 摊到每帧。
##
## 归零即被毁，且**只在这一刻** emit turret_destroyed —— 事件语义是「状态翻转」，
## 重复 emit 会让订阅方（失守演出 / 全毁判定）反复触发。
## source_id = 打我的敌人类型 id。⑨a（2026-09-10）起**真的被用上了**：
## 随 turret_damaged 一起发出去，DamageLog 据此做「伤害来源按敌人类型分」的统计，
## 于是战损报告才能回答「为什么掉的」而不只是「掉了多少」。
##
## ⚠ **本函数每物理帧都会被调**，所以它产生的任何「反馈」都必须自带节流。
## 2026-09-11（DEC-048）之前这里每帧调一次 `AudioManager.play_sfx`、震屏则靠订阅
## `turret_damaged` —— 净效果是「只要还有敌人在啃炮塔，画面就一直抖、音就一直响」，
## 正是李实机反馈的「一被攻击就搞这么大动静」。
## 现在**本函数不再产生任何声音**；受创的离散反馈统一走 `_check_critical()`
## （耐久首次跌破阈值时发一次）。`turret_damaged` 仍每帧发，因为它是 DamageLog 的
## **记账流水**而不是给玩家看的反馈 —— 数据与反馈的节流需求正好相反。
func take_damage(amount: float, source_id: StringName = &"") -> void:
	if destroyed or amount <= 0.0:
		return
	hp -= amount
	EventBus.turret_damaged.emit(turret_id, amount, source_id)
	if hp > 0.0:
		# ⑪ 还活着 → 闪白。**每物理帧都会被调**（敌人持续 dps），
		# 所以闪白内部带冷却，否则炮塔会一直卡在白态（见 _hit_flash 的注释）。
		_hit_flash()
		# ⑪ ③ 临界警报：跨过阈值才响一次（自带「每波一次」守卫，见 _check_critical）。
		_check_critical()
		return
	hp = 0.0
	destroyed = true
	# 先清闪白状态再刷被毁外观：否则冷却到点时 _tick_flash 会去"还原"，
	# 把被毁的暗红擦回型号色 —— 表现就是"炮被打没了，但颜色还是好的"。
	_flash_on = false
	_flash_cd = 0.0
	_apply_destroyed_visual()
	if DEBUG_LOG:
		print("[turret] %s 被毁（扇区 %s）" % [turret_id, sector])
	EventBus.turret_destroyed.emit(turret_id, sector)


## 每波开始回满（bible 02 §二「每波开始所有炮塔自动回满耐久，无维修经济」）。
## 由 TurretSystem.set_battle_active(true) 统一调，保证「手动开战」与「正式波次」
## 走同一条路 —— 测试里手动 set_battle_active 也能验到回满。
func restore() -> void:
	hp = hp_max
	destroyed = false
	_auto_fire_timer = 0.0
	# ⑪ 闪白状态一起清：每波回满时如果冷却还挂着，下次挨打会有最多一个 flash_time 的"哑火"，
	# 表现为「明明在挨打，这门炮却不像别的炮那样闪」——极难复现的那类小 bug。
	_flash_on = false
	_flash_left = 0.0
	_flash_cd = 0.0
	# ⑪ ③ 临界警报也要复位：否则「上一波报过警」会被记住，新一波跌破阈值却一声不响 ——
	# 表现是「这门炮没被修好」的错觉。与闪白冷却同理，凡是"每波一次"的状态都在这里清。
	_critical_fired = false
	_apply_alive_visual()


## 找**最近、已进入攻击距离、且活着**的敌人（活 = hp>0）。
## 返回 Enemy 或 null。null 时调用方静默 skip 即可。
##
## ⚠ DEC-049：判据由 `is_hovering()` 改为 `is_engaged()`。两者在 hold 飞行下等价，
## 但语义不同 —— 本函数要的是「**能不能锁**」（进了攻击距离就算数），
## 不是「**是否静止**」。用错的那个会让「绕飞的敌人」永远锁不上，
## 表现为全船哑火却查不出原因。
##
## ⚠ 2026-09-06：查找方式从 `get_node("Bridge/EnemySystem")` 改为 **group**。
## 原写法有两个坑：① 主场景根节点一改名就静默返回 null → 所有炮塔永远找不到
## 目标、「炮不响」且无任何报错；② 跑在独立测试场景里同样失效。
## 与 Projectile._test_hit 用同一个 group（常量引自 Projectile，只此一份）。
func acquire_target() -> Enemy:
	var best: Enemy = null
	var best_dist: float = INF
	for node in get_tree().get_nodes_in_group(Projectile.ENEMY_GROUP):
		var e := node as Enemy
		if e == null:
			continue
		if e.is_dead():
			continue
		if not e.is_engaged():
			continue
		var d: float = muzzle_pos.distance_to(e.global_position)
		if d > fire_range:
			continue
		if d < best_dist:
			best_dist = d
			best = e
	return best


## 发射一发子弹：新建 Projectile，setup 参数，add_child。
## direction 已是单位向量；target 参数保留但当前不读（子弹自带命中检测）——
## 参数名带 `_` 前缀抑制 unused_parameter；留着便于将来加「开火占位击回播 / 命中率统计」。
func _fire(direction: Vector3, _target: Enemy = null) -> void:
	if direction.length_squared() < 1e-6:
		return
	var p := Projectile.new()
	p.name = "Bullet_%s_%d" % [turret_id, Time.get_ticks_msec()]
	p.position = muzzle_pos   # Projectile 还没进树，position == global_position 在 add_child 后
	get_tree().get_root().add_child(p)   # Projectile 由 TurretSystem 统一调 advance，所以挂在 root
	p.setup(direction, projectile_speed, projectile_damage, turret_id,
		projectile_max_lifetime, fire_range)
	# 交给 TurretSystem 统一推进 —— 这是设计的意图（不在 _physics_process 里各自跑）。
	#
	# ⚠ 2026-09-06 修复：原先只 add_child 不注册，_projectiles 永远是空数组，
	#   于是 TurretSystem.advance_all() 一个弹丸都没推进过，全靠 Projectile 自带的
	#   _physics_process 兜底在飞。后果是：一旦进入「手动推进」场景
	#   （独立测试 / 固定步长模拟），弹丸原地不动 → 炮在响、敌人不掉血。
	#   注册成功后关掉弹丸自己的 _physics_process，否则同一帧被推两次 = 双倍弹速。
	var owner_sys := get_parent() as TurretSystem
	if owner_sys != null and owner_sys.register_projectile(p):
		p.set_physics_process(false)
	# ⑩ 开火音：**直接调 AudioManager，不走 EventBus**（DEC-046 决定 2）。
	# 开火是每帧级的高频事件，emit 会刷爆总线；而 EventBus 的语义是「状态翻转」。
	# sector 传进去 → AudioManager 按听觉 HUD 改音高 / 决定 2D·3D（前扇区才有方向感）。
	# 限流与池化在 AudioManager 内部统一处理，本类不做节流。
	AudioManager.play_sfx(fire_sfx, sector)
	if DEBUG_LOG:
		print("[turret] %s 发射 -> 方向=%s 速度=%.0f 伤害=%.1f" % [
			turret_id, str(direction), projectile_speed, projectile_damage])


## 手动模式响应：EventBus.turret_fired 携带 turret_id，匹配 self 才开火。
## 手动模式必走 LeadPrediction —— 这是 DEC-034 的核心：玩家瞄、弹丸慢、必须预测。
func _on_turret_fired(fired_id: StringName) -> void:
	if destroyed or mode != Mode.MANUAL:
		return
	if fired_id != turret_id:
		return
	# 取玩家相机正前方射线方向（手动瞄准 = 玩家准星 = 主相机 forward）。
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	# 在最近悬停敌人里挑一个作为「当前目标」（手动模式不绑目标，命中靠子弹自身检测）。
	var target := acquire_target()
	if target == null:
		# 兜底：按玩家射线方向发射（可能打不中，但至少子弹飞出去）
		var dir := (-cam.global_transform.basis.z).normalized()
		_fire(dir, null)
		return
	# 用 LeadPrediction 算拦截点
	var t_v: Vector3 = _target_velocity(target)
	var intercept := LeadPrediction.intercept_point(cam.global_position,
		target.global_position, t_v, projectile_speed)
	var aim_dir: Vector3
	if intercept.length_squared() > 1e-6:
		aim_dir = (intercept - muzzle_pos).normalized()
	else:
		# 弹速追不上 → 直接瞄当前位置（至少看得到弹道从哪来）
		aim_dir = (target.global_position - muzzle_pos).normalized()
	_fire(aim_dir, target)
	if DEBUG_LOG:
		print("[turret] %s 手动开火 -> 拦截点=%s（目标 v=%s）" % [
			turret_id, str(intercept), str(t_v)])


## 估计目标速度：白盒阶段敌人悬停速度为 0，飞行中按「直线飞向自己的目标点」推算。
##
## 敌人是直线匀速，所以 velocity = (目标点 - 当前位置).normalized() × speed，
## 不需要存 prev_pos 做差分（那要每帧写入，白盒阶段不值得）。
##
## ⚠ 2026-09-06 修 hardcode：目标点原本在本函数里写死成 `Vector3(0, 1.5, -1.3)`
## （注释还标着「enemies.json ship_center」），等于船心坐标在代码里存了第二份。
## 改 JSON 的 ship_center 时这里纹丝不动，LeadPrediction 的拦截点就会系统性偏，
## 表现为「自动开火打得准、手动接管打不准」（两者走的都是本函数）。
##
## ⚠ 2026-09-11（DEC-049）再升一级：从「按 flight_target 推方向」改成
## **直接采样敌人的逐帧位移 `Enemy.velocity()`**。旧写法
## `(flight_target() - global_position).normalized() * speed` 假设敌人永远
## 直线匀速飞向目标点 —— 一旦出现绕飞 / 突进撤离这类机动，推出的方向就是错的，
## 提前量系统性偏。采样真值对任何飞行方式都成立，且对直线飞行**逐帧等价**
## （直线时位移方向 == 目标点方向，速度模长 == speed）。
func _target_velocity(e: Enemy) -> Vector3:
	return e.velocity()


## 视觉：白盒 BoxMesh 按 visual_size（沿 +Z 拉长），对准 +Z（fore 方向）。
## 材质由 _apply_alive_visual / _apply_destroyed_visual 统一管理 ——
## 两处各写一份颜色常量属于「同一份数据存两处」，改一处漏一处必然静默错位。
func _build_visual() -> void:
	var mi := MeshInstance3D.new()
	mi.name = "Barrel"
	var box := BoxMesh.new()
	box.size = visual_size
	mi.mesh = box
	mi.material_override = StandardMaterial3D.new()
	add_child(mi)
	_barrel = mi
	_apply_alive_visual()


## 存活外观：variants 的 visual_color + 微弱自发光。
## ⑦ 前这里硬编码冷灰；换装后颜色不变的话玩家看不出换了什么，所以改为读 visual_color。
## 自发光取颜色的 40% —— 保住「暗背景下能看见」这条（李 2026-09-08 反馈过太黑）。
func _apply_alive_visual() -> void:
	if _barrel == null:
		return
	var mat := _barrel.material_override as StandardMaterial3D
	if mat == null:
		return
	mat.albedo_color = visual_color
	mat.emission_enabled = true
	mat.emission = visual_color * 0.4


## 被毁外观：暗红 + 无自发光（"这门炮没了"要在余光里也能看见）。
## 真正的爆炸 / 碎片是 P1（BACKLOG §P1 炮塔陷落演出），白盒阶段只做可读的状态色。
func _apply_destroyed_visual() -> void:
	if _barrel == null:
		return
	var mat := _barrel.material_override as StandardMaterial3D
	if mat == null:
		return
	mat.albedo_color = Color(0.18, 0.06, 0.05)
	mat.emission_enabled = false
	mat.emission = Color(0, 0, 0)


## ⑪ 命中闪白：材质提亮一瞬。数值来自 `FeelKit`，本类不存常量。
## 带冷却的原因见 enemy.gd 同名函数的注释 —— 这里是**必须**有冷却的场景
## （敌人持续 dps 会每帧调用本函数）。
func _hit_flash() -> void:
	if _flash_on or _flash_cd > 0.0 or _barrel == null or destroyed:
		return
	var ft := FeelKit.flash_time()
	if ft <= 0.0:
		return
	var mat := _barrel.material_override as StandardMaterial3D
	if mat == null:
		return
	var c := FeelKit.flash_color()
	mat.albedo_color = c
	mat.emission_enabled = true
	mat.emission = c * 0.5
	_flash_on = true
	_flash_left = ft


## 每帧推进闪白状态机。由 `advance()` 调（TurretSystem 每物理帧统一推进炮塔）。
## 恢复走 `_apply_alive_visual()` 而不是写死颜色 —— 炮塔本色随型号变
## （visual_color 在 ⑦ 换装后才落定），写死一个灰就会把型号色擦掉。
func _tick_flash(delta: float) -> void:
	if _flash_on:
		_flash_left -= delta
		if _flash_left > 0.0:
			return
		_flash_on = false
		_flash_cd = FeelKit.flash_time()
		if not destroyed:
			_apply_alive_visual()
	elif _flash_cd > 0.0:
		_flash_cd -= delta


## 自省：当前炮管颜色（测试断言"闪了 / 还原成型号色 / 被毁后不还原"用）。
func body_color() -> Color:
	if _barrel == null:
		return Color(0, 0, 0)
	var mat := _barrel.material_override as StandardMaterial3D
	if mat == null:
		return Color(0, 0, 0)
	return mat.albedo_color
