class_name GameFeel
extends Node

## ⑪ 相机手感的编排器（2026-09-10 · DEC-047）
##
## **职责边界**：只做「事件 → 相机反馈」这一件事 ——
##   · 震屏（③）：给 `Camera3D.position` 叠一层局部偏移，衰减回零
##   · 推镜（④）：短促收窄 `Camera3D.fov` 再缓回基准
## 闪白在实体自己身上（`Enemy` / `Turret`，它们才拥有自己的材质）；
## 伤害数字 / VFX / hitstop 是后续独立层（同一批事件，互不重叠）。
##
## **为什么单独一个节点而不是塞进 bridge_whitebox**：
## 主控室脚本已经 1493 行且管着输入、feed、相机搬移、HUD，再塞手感进去会变成第二种 CollapseSequence。
## 挂成兄弟节点后，「谁订阅哪个事件、写相机的哪一部分」一眼可查。
##
## **与 bridge_whitebox 的分工（关键，避免抢同一个属性）**：
##   · bridge_whitebox 写 `Player.position`（接管搬移 / L3 演出）与 `rotation`
##   · 本类只写 `Camera3D.position`（局部偏移）与 `Camera3D.fov`
## 两边零重叠 —— 所以震屏不需要在接管时特别避让，接管的搬移也不会把抖动带跑偏。
##
## **与 CollapseSequence 的关系**：L3 终局夺镜期间本类必须**让位**
## （那段由 CollapseSequence 独占镜头与操控），靠 `lock_check` 或兄弟节点 `is_locked()` 判定。
##
## 数值全部来自 `data/presentation.json` 的 `feel` 段，经 `FeelKit` 读取 —— 本类不 hardcode 任何数值。

## 兄弟节点里陷落编排器的名字（和 bridge_whitebox 里 `add_child` 用的名字一致）。
const COLLAPSE_NAME := "CollapseSequence"

var _cam: Camera3D
var _player: Node3D
## 相机局部静止位与基准视场角。**在 setup 时抓一次**——
## 本类上线前 `Camera3D.position` / `fov` 全工程无人写（已 grep 确认），
## 所以抓一次就能当恒定基准；将来若别处开始改这两个属性，这里要改成每帧重取。
var _cam_base := Vector3.ZERO
var _fov_base := 70.0

var _shake_left := 0.0
var _shake_dur := 0.0
var _shake_amp := 0.0
var _shake_phase := 0.0

## 推镜计时：< 0 = 空闲。0 起算，走完 in+out 两段后回到 -1。
var _zoom_t := -1.0
var _zoom_deg := 0.0

## 外部锁。**优先于**兄弟节点查找 —— 测试用它能免建一个假的 CollapseSequence。
var lock_check := Callable()

var _collapse: Node
var _collapse_looked_up := false


func _ready() -> void:
	# 空闲不跑 _process（同 AudioManager 的做法）：手感是极低频事件，
	# 常驻 _process 等于每帧白跑一次 sin() 三连。
	set_process(false)
	EventBus.turret_fired.connect(_on_turret_fired)
	EventBus.enemy_killed.connect(_on_enemy_killed)
	EventBus.turret_damaged.connect(_on_turret_damaged)
	EventBus.turret_destroyed.connect(_on_turret_destroyed)
	EventBus.sector_breached.connect(_on_sector_breached)
	# 阶段切换时清干净：进 REFIT（改名/换装）时镜头不该还带着上一波残留的抖。
	EventBus.game_state_changed.connect(_on_game_state_changed)


## 注入相机与玩家。由 bridge_whitebox 在 add_child 之后调一次。
func setup(camera: Camera3D, player: Node3D) -> void:
	_cam = camera
	_player = player
	if _cam != null:
		_cam_base = _cam.position
		_fov_base = _cam.fov


func _process(delta: float) -> void:
	advance(delta)


## 推进一帧。**公开**，与 Enemy.advance / TurretSystem.advance_all 同一套约定：
## 测试可以直接按固定步长喂 delta，不必等真实帧 —— 手感时序才断言得准。
func advance(delta: float) -> void:
	if _locked_out():
		_reset()
		return
	var live := false

	# ── ③ 震屏 ────────────────────────────────────────────────
	# 包络 = 剩余/总时长（线性衰减），振动 = 三轴各自频率的正弦。
	# 为什么不用每帧随机：正弦是**确定性**的 —— headless 断言能算得出期望值，
	# 随机偏移只能断言"不为零"，那验不出「有没有衰减到零」这个真正的坑。
	if _shake_left > 0.0:
		_shake_left = maxf(0.0, _shake_left - delta)
		_shake_phase += delta * FeelKit.shake_freq() * TAU
		var ratio: float = 0.0
		if _shake_dur > 0.0:
			ratio = _shake_left / _shake_dur
		var amp := _shake_amp * ratio
		var off := Vector3(
			sin(_shake_phase),
			sin(_shake_phase * 0.83 + 0.9),
			sin(_shake_phase * 1.31 + 2.1)) * amp
		# 三轴叠加后的模长最大可达 amp×√3，会突破旋钮语义里的"最大偏移"，
		# 所以按模长夹一次（旋钮值必须真的是上限，否则它就是谎言）。
		var cap := FeelKit.shake_max()
		if off.length() > cap:
			off = off.normalized() * cap
		if _cam != null:
			_cam.position = _cam_base + off
		live = true
		if _shake_left <= 0.0:
			_shake_amp = 0.0
			_shake_phase = 0.0

	# ── ④ 推镜 ────────────────────────────────────────────────
	# 先快速凑近（fov 收窄 = 画面拉近），再缓回基准。两段时间分开，是为了让"进"干脆、
	# "出"柔和 —— 合成一段的话回弹会显得敷衍。
	if _zoom_t >= 0.0:
		_zoom_t += delta
		var in_t := maxf(0.001, FeelKit.zoom_in())
		var out_t := maxf(0.001, FeelKit.zoom_out())
		var curve: float = 0.0
		if _zoom_t < in_t:
			curve = _zoom_t / in_t
		elif _zoom_t < in_t + out_t:
			curve = 1.0 - (_zoom_t - in_t) / out_t
		else:
			_zoom_t = -1.0
			_zoom_deg = 0.0
		if _cam != null:
			_cam.fov = _fov_base - _zoom_deg * curve
		live = true

	if not live:
		_restore()
		set_process(false)


# ── 触发入口 ────────────────────────────────────────────────

## 震屏。amp 单位 m（相机局部偏移量），与 presentation.json 的 shake_max_offset 同量纲。
## **取 max 而不是累加**：`turret_damaged` 每物理帧都在发（敌人持续 dps），
## 累加会让"一路被啃"在几帧内顶到上限并一直卡在那；取 max 则稳定在旋钮值上。
func shake(amp: float) -> void:
	if amp <= 0.0 or _cam == null:
		return
	_shake_dur = maxf(0.01, FeelKit.shake_time())
	_shake_amp = maxf(_shake_amp, amp)
	_shake_left = _shake_dur
	set_process(true)


## 推镜。deg = 视场角收窄量（度）。
func punch_zoom(deg: float) -> void:
	if deg <= 0.0 or _cam == null:
		return
	_zoom_deg = maxf(_zoom_deg, deg)
	_zoom_t = 0.0
	set_process(true)


# ── 事件接线 ────────────────────────────────────────────────

func _on_turret_fired(_turret_id: StringName) -> void:
	_apply("player_fire")


func _on_enemy_killed(_enemy: Node) -> void:
	_apply("enemy_killed")


func _on_turret_damaged(_turret_id: StringName, _amount: float, _source_id: StringName) -> void:
	_apply("turret_damaged")


func _on_turret_destroyed(_turret_id: StringName, _sector: StringName) -> void:
	_apply("turret_destroyed")


func _on_sector_breached(_sector: StringName) -> void:
	_apply("sector_breached")


func _on_game_state_changed(_new_state: StringName) -> void:
	_reset()


## 查接线表 → 分发。锁定期与总闸为零时静默跳过（不是错误，是设计）。
func _apply(event_key: String) -> void:
	if _cam == null or master_is_muted() or _locked_out():
		return
	var fb := FeelKit.feedback(event_key)
	var s := float(fb.get("shake", 0.0))
	var z := float(fb.get("zoom", 0.0))
	if s > 0.0:
		shake(s)
	if z > 0.0:
		punch_zoom(z)


# ── 自省 API（测试与排障用）────────────────────────────────

func is_active() -> bool:
	return _shake_left > 0.0 or _zoom_t >= 0.0


func shake_amp() -> float:
	return _shake_amp


func zoom_deg() -> float:
	return _zoom_deg


func cam_base() -> Vector3:
	return _cam_base


func fov_base() -> float:
	return _fov_base


func offset_now() -> Vector3:
	if _cam == null:
		return Vector3.ZERO
	return _cam.position - _cam_base


func camera() -> Camera3D:
	return _cam


## 当前是否被终局演出锁住（也供测试直接问）。
func is_locked_out() -> bool:
	return _locked_out()


## 总闸为零 = 全部反馈静默。独立成函数是为了让测试能只验这一条，不牵扯锁。
func master_is_muted() -> bool:
	return FeelKit.master() <= 0.0


# ── 内部 ────────────────────────────────────────────────────

## 是否让位（L3 夺镜期间）。优先用注入的 lock_check，否则找兄弟节点 CollapseSequence。
func _locked_out() -> bool:
	if lock_check.is_valid():
		return bool(lock_check.call())
	if not _collapse_looked_up:
		# 只查一次：找不到就记住找不到，不必每帧 get_node。
		# bridge_whitebox 里 CollapseSequence 先 add_child、GameFeel 后 add_child，
		# 所以主场景首次查询必定命中。
		var parent := get_parent()
		if parent != null:
			_collapse = parent.get_node_or_null(COLLAPSE_NAME)
		_collapse_looked_up = true
	if _collapse == null or not is_instance_valid(_collapse):
		return false
	if _collapse.has_method("is_locked"):
		return bool(_collapse.call("is_locked"))
	return false


## 精确归位：偏移与视场角都还原到基准，不留残差。
## 「震完画面微微歪着回不去」是这类系统最常见的静默 bug，所以归位要显式写、要被断言。
func _restore() -> void:
	if _cam == null:
		return
	_cam.position = _cam_base
	_cam.fov = _fov_base


func _reset() -> void:
	_shake_left = 0.0
	_shake_dur = 0.0
	_shake_amp = 0.0
	_shake_phase = 0.0
	_zoom_t = -1.0
	_zoom_deg = 0.0
	_restore()
	set_process(false)
