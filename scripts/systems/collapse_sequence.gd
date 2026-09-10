class_name CollapseSequence
extends Node
## 陷落演出编排器（DEC-043 决定 2「三级分层」的落地；范围见 DEC-045）。
##
## 职责 = **编排**，不是**特效**：
##   L1 单炮被毁（turret_destroyed）→ 该路 feed 打【计数】标记（黄，含脉冲）
##   L2 该面失守（sector_breached） → 该路 feed 打【红叉 + 整屏红】
##   L3 全部被毁（all_turrets_destroyed）→ 夺操控 + 拉远环绕镜头 + 宣告 → RESULT
##   爆炸粒子归 ⑪VFX、警报音归 ⑩音频 —— 三者订阅同一批事件，互不重叠。
##
## 表现层对场景节点【缺失容错】：headless / 无屏幕 / 无相机时只跑状态层，
## 不崩。这既是测试需要（headless 可测纯逻辑），也是 ⑥ 冻结的防御 ——
## 监控屏幕 / 相机未来重构时，编排器不该因为找不到节点而报错。
##
## 挂载：主场景 bridge 的子节点（像 DamageLog 挂 TurretSystem 那样），
## 这样能用相对路径拿到监控屏（MonitorPanel/...）与相机（Player）。

const TURRET_SYSTEM_GROUP := &"turret_system"
const DATA_PATH := "res://data/presentation.json"

## 扇区 → 屏幕节点路径（相对 bridge）。**结构映射**，不是数值。
## 与 bridge_whitebox.gd 的 SCREEN_FEED 一一对应 —— 改了那边记得同步这里。
## fore（主炮）没有 feed（DEC-026 单面舷窗是正面的），不参与标记。
const SCREEN_PATHS := {
	&"port": "MonitorPanel/ScreenPort",
	&"starboard": "MonitorPanel/ScreenStarboard",
	&"dorsal": "MonitorPanel/ScreenDorsal",
	&"ventral": "MonitorPanel/ScreenVentral",
}

enum SectorState { OK, DEGRADED, BREACHED }

var _cfg: Dictionary = {}
var _ts: TurretSystem

# 表现层（延迟绑定，找得到才有）
var _screens: Dictionary = {}   # StringName -> MeshInstance3D
var _tints: Dictionary = {}     # StringName -> MeshInstance3D
var _texts: Dictionary = {}     # StringName -> Label3D

# 状态层（纯数据，headless 可测）
var _state: Dictionary = {}     # StringName -> int (SectorState)
var _alive: Dictionary = {}     # StringName -> int 存活门数
var _mounted: Dictionary = {}   # StringName -> int 已装门数
var _flash_t: Dictionary = {}   # StringName -> float 脉冲计时
var _tint_mats: Dictionary = {} # StringName -> StandardMaterial3D（避免反复 cast material_override）

# L3 终局镜头
var _l3 := false
var _l3_t := 0.0
var _l3_from := Vector3.ZERO
var _l3_player: Node3D
var _l3_center := Vector3.ZERO


func _ready() -> void:
	_cfg = _load_json(DATA_PATH)
	EventBus.turret_destroyed.connect(_on_turret_destroyed)
	EventBus.sector_breached.connect(_on_sector_breached)
	EventBus.all_turrets_destroyed.connect(_on_all_turrets_destroyed)
	EventBus.game_state_changed.connect(_on_game_state_changed)


func _process(delta: float) -> void:
	if _l3:
		_advance_l3(delta)
	_update_flashes(delta)


# ── 公开查询（bridge 的 HUD / 输入锁用）────────────────────────

## L3 终局演出进行中 = 应夺玩家操控。
func is_locked() -> bool:
	return _l3


## 该扇区当前陷落等级（SectorState）。测试与 HUD 用。
func sector_state(sector: StringName) -> int:
	return int(_state.get(sector, SectorState.OK))


## L3 宣告文案（L3 激活时返回，否则空串）。HUD 在 RESULT 前显示它。
func announce_text() -> String:
	if not _l3:
		return ""
	var l3: Dictionary = _cfg.get("l3", {}) as Dictionary
	return str(l3.get("announce", ""))


# ── 事件处理 ──────────────────────────────────────────────

func _on_turret_destroyed(_turret_id: StringName, sector: StringName) -> void:
	_ensure_bind()
	_refresh_sector(sector)
	_trigger_flash(sector)


func _on_sector_breached(sector: StringName) -> void:
	_ensure_bind()
	_set_sector_state(sector, SectorState.BREACHED)
	_trigger_flash(sector)


func _on_all_turrets_destroyed() -> void:
	start_l3()


func _on_game_state_changed(state_name: StringName) -> void:
	# 开战（进 BATTLE）清空上一局的标记与陷落状态。用 game_state_changed 而不是
	# 危机清空：整条 REFIT 链期间都要保留标记给玩家看（同 ⑨a 战损的开战清空口径）。
	if state_name == &"BATTLE":
		_reset()


# ── 状态层 ────────────────────────────────────────────────

## 重算某扇区的存活/已装门数并据此定级。
## 由 turret_destroyed 触发时：死一门但不全灭 → DEGRADED（L1）；全灭 → 交给
## sector_breached 事件（TurretSystem 会单独 emit），本函数不抢着定 BREACHED，
## 避免「顺序颠倒」导致 L1/L2 判定打架。
func _refresh_sector(sector: StringName) -> void:
	var ts := _turret_system()
	if ts == null:
		return
	var alive := 0
	var mounted := 0
	for sid in ts.all_slot_ids():
		if ts.slot_sector(sid) != sector:
			continue
		var t: Turret = ts.get_turret(sid)
		if t != null:
			mounted += 1
			if not t.destroyed:
				alive += 1
	_alive[sector] = alive
	_mounted[sector] = mounted
	if mounted > 0 and alive == 0:
		_set_sector_state(sector, SectorState.BREACHED)
	elif mounted > 0 and alive < mounted:
		_set_sector_state(sector, SectorState.DEGRADED)
	else:
		_set_sector_state(sector, SectorState.OK)


func _set_sector_state(sector: StringName, st: int) -> void:
	_state[sector] = st
	_apply_marker(sector)


func _reset() -> void:
	for sector in _state.keys():
		_set_sector_state(sector as StringName, SectorState.OK)
	_flash_t.clear()


# ── L3 终局镜头 ────────────────────────────────────────────

## 启动 L3 终局演出（bridge 的 _on_all_turrets_destroyed 调它；也可由事件直达）。
func start_l3() -> void:
	if _l3:
		return
	_l3 = true
	_l3_t = 0.0
	_l3_from = Vector3.ZERO
	_l3_player = _find_player()
	if _l3_player != null:
		_l3_from = _l3_player.global_position
	# 白盒阶段船心 = 世界原点；等整船网格落地后改读 ship 中心（旋钮化）。
	_l3_center = Vector3.ZERO


func _advance_l3(delta: float) -> void:
	_l3_t += delta
	var l3: Dictionary = _cfg.get("l3", {}) as Dictionary
	var move_t: float = float(l3.get("move_time", 2.4))
	var hold_t: float = float(l3.get("hold_time", 2.2))
	var total: float = move_t + hold_t

	if _l3_player != null:
		var k: float = clampf(_l3_t / move_t, 0.0, 1.0)
		var e: float = smoothstep(0.0, 1.0, k)
		var dir: Vector3 = (_l3_from - _l3_center).normalized()
		if dir.length() < 0.01:
			dir = Vector3(0, 0, 1)
		# 环绕：绕世界 UP 轴转 orbit_deg，让镜头不是单调后退，有「被包围」的扫视感。
		var orbit: float = deg_to_rad(float(l3.get("orbit_deg", 55.0))) * e
		var rot := Basis(Vector3.UP, orbit)
		var target_pos: Vector3 = _l3_center + (rot * dir) * float(l3.get("pullback", 95.0))
		target_pos.y += float(l3.get("rise", 16.0)) * e
		_l3_player.global_position = _l3_from.lerp(target_pos, e)
		_look_at_safe(_l3_player, _l3_center)

	if _l3_t >= total:
		_finish_l3()


func _finish_l3() -> void:
	_l3 = false
	GameStateManager.change_state(GameStateManager.State.RESULT)


## Camera3D.look_at 的 up 与视线共线会滚转告警（godot_pitfalls #6），这里防御。
func _look_at_safe(node: Node3D, target: Vector3) -> void:
	var dir: Vector3 = (target - node.global_position).normalized()
	var up := Vector3.UP
	if absf(dir.dot(up)) > 0.99:
		up = Vector3.FORWARD
	node.look_at(target, up)


func _find_player() -> Node3D:
	var parent := get_parent()
	if parent == null:
		return null
	return parent.get_node_or_null("Player") as Node3D


# ── 表现层（屏幕标记）───────────────────────────────────────

## 惰性绑定：第一次需要时（首个事件 / 显式调用）才找屏幕节点并建标记层。
## 找不到就跳过 —— 状态层照常工作，只是没有可视反馈（headless / 无监控屏时）。
func _ensure_bind() -> void:
	if not _screens.is_empty() or not _tints.is_empty():
		return
	var parent := get_parent()
	if parent == null:
		return
	for sector in SCREEN_PATHS:
		var screen := parent.get_node_or_null(str(SCREEN_PATHS[sector])) as MeshInstance3D
		if screen == null:
			continue
		_screens[sector] = screen
		var sz := Vector2(0.5, 0.375)
		if screen.mesh is QuadMesh:
			sz = (screen.mesh as QuadMesh).size
		# ① 染色层：半透明色块覆盖屏幕，主信号（不依赖字体）。
		var tint := MeshInstance3D.new()
		tint.name = "CollapseTint"
		var q := QuadMesh.new()
		q.size = sz
		tint.mesh = q
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.emission_enabled = true
		m.emission = Color(1, 1, 1)
		m.albedo_color = Color(1, 1, 1, 0.0)
		tint.material_override = m
		tint.position.z = float(_cfg.get("tint_offset_z", 0.006))
		tint.visible = false
		screen.add_child(tint)
		_tints[sector] = tint
		_tint_mats[sector] = m
		# ② 文字层：计数 / 红叉。只作补充，主信号是染色。
		var lab := Label3D.new()
		lab.name = "CollapseText"
		lab.pixel_size = float(_cfg.get("text_pixel_size", 0.0016))
		lab.no_depth_test = true
		lab.position.z = float(_cfg.get("text_offset_z", 0.014))
		lab.visible = false
		screen.add_child(lab)
		_texts[sector] = lab


func _apply_marker(sector: StringName) -> void:
	var tint := _tints.get(sector) as MeshInstance3D
	var text := _texts.get(sector) as Label3D
	if tint == null:
		return
	var mat := _tint_mats.get(sector) as StandardMaterial3D
	if mat == null:
		return
	var st: int = int(_state.get(sector, SectorState.OK))
	match st:
		SectorState.OK:
			tint.visible = false
			if text != null:
				text.visible = false
		SectorState.DEGRADED:
			var c1 := _color("l1", "color", Color(1.0, 0.72, 0.20))
			var a1 := float(_l1_cfg().get("tint_alpha", 0.30))
			tint.visible = true
			mat.albedo_color = Color(c1.r, c1.g, c1.b, a1)
			mat.emission = c1
			if text != null:
				text.visible = true
				text.modulate = c1
				text.text = str(_l1_cfg().get("text", "%d/%d")) % [
					int(_alive.get(sector, 0)), int(_mounted.get(sector, 0))]
		SectorState.BREACHED:
			var c2 := _color("l2", "color", Color(1.0, 0.18, 0.14))
			var a2 := float(_l2_cfg().get("tint_alpha", 0.55))
			tint.visible = true
			mat.albedo_color = Color(c2.r, c2.g, c2.b, a2)
			mat.emission = c2
			if text != null:
				text.visible = true
				text.modulate = c2
				text.text = str(_l2_cfg().get("text", "✕"))


func _trigger_flash(sector: StringName) -> void:
	_flash_t[sector] = 0.0


func _update_flashes(delta: float) -> void:
	for sector in _flash_t.keys():
		var t: float = float(_flash_t[sector]) + delta
		_flash_t[sector] = t
		var dur := _flash_duration(sector)
		var tint := _tints.get(sector) as MeshInstance3D
		if tint == null or not tint.visible:
			_flash_t.erase(sector)
			continue
		if t < dur:
			var pulses := float(_cfg.get("flash_pulses", 3.0))
			var wave := 0.5 + 0.5 * sin(t * TAU * pulses / dur)
			# 脉冲在「半亮 ~ 全亮」之间摆动，不会闪到全黑（丢失信息）。
			var mat := _tint_mats.get(sector) as StandardMaterial3D
			var base: float = mat.albedo_color.a if mat != null else 0.0
			if mat != null:
				mat.albedo_color.a = base * (0.4 + 0.6 * wave)
		else:
			# 脉冲结束，恢复 base alpha（常亮）。
			var base: float = _base_alpha(sector)
			var mat2 := _tint_mats.get(sector) as StandardMaterial3D
			if mat2 != null:
				mat2.albedo_color.a = base
			_flash_t.erase(sector)


func _flash_duration(sector: StringName) -> float:
	var st: int = int(_state.get(sector, SectorState.OK))
	if st == SectorState.BREACHED:
		return float(_l2_cfg().get("flash_duration", 0.35))
	return float(_l1_cfg().get("flash_duration", 0.5))


func _base_alpha(sector: StringName) -> float:
	var st: int = int(_state.get(sector, SectorState.OK))
	if st == SectorState.BREACHED:
		return float(_l2_cfg().get("tint_alpha", 0.55))
	return float(_l1_cfg().get("tint_alpha", 0.30))


# ── JSON 工具 ──────────────────────────────────────────────

func _l1_cfg() -> Dictionary:
	return _cfg.get("l1", {}) as Dictionary


func _l2_cfg() -> Dictionary:
	return _cfg.get("l2", {}) as Dictionary


func _color(section: String, key: String, fallback: Color) -> Color:
	var sec: Dictionary = _cfg.get(section, {}) as Dictionary
	var arr: Variant = sec.get(key, null)
	if arr is Array and (arr as Array).size() >= 3:
		var a := arr as Array
		return Color(float(a[0]), float(a[1]), float(a[2]))
	return fallback


func _turret_system() -> TurretSystem:
	if _ts == null:
		_ts = get_tree().get_first_node_in_group(TURRET_SYSTEM_GROUP) as TurretSystem
	return _ts


func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("[collapse] 读不到 %s" % path)
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if parsed is Dictionary:
		var top := parsed as Dictionary
		return top.get("collapse", {}) as Dictionary
	return {}
