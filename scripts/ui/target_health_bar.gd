extends CanvasLayer
class_name TargetHealthBar

## ⑪ ⑤ 敌人血量反馈 · **B 层**（2026-09-10）
##
## **一句话**：玩家接管某门炮时，屏幕上方中央出现一条「当前目标」血条；
## 不接管时完全不显示（零噪音）。C 层（敌人本体随血量变暗）在 `enemy.gd` 里，不在本类。
##
## **为什么只在接管时显示**（而不是给每个敌人头顶挂血条）：
##   · DEC-021 要「低 APM、允许发呆」—— 不操作的时段就不该往屏幕上堆信息；
##   · 不接管时敌人由自动炮塔处理，玩家插不上手，血条给了也无从决策；
##   · 接管时玩家在瞄，这时才需要「还差几发」的信息来配合开火节奏。
## 这与 `Turret.acquire_target()`（就绪的「当前目标」定义）天然契合，不必另写一套锁定逻辑。
##
## **目标从哪来**：由 `bridge_whitebox` 注入 `target_provider` ——
## 一个返回「接管中的炮 → `acquire_target()`」的 Callable。
## 用 Callable 而不是直接持有 TurretSystem，好处有二：
##   ① 与 `GameFeel.lock_check` 同一套路，测试能注入假实现，免建整套炮塔 + 波次；
##   ② 本类不依赖任何系统节点 —— 少一条"节点没挂上 → 血条静默不显示"的排查成本。
##
## **数值全部来自 `HealthKit`（`presentation.json` 的 `healthbar.target_bar`）**，
## 本类不 hardcode 尺寸 / 颜色 / 字号。
##
## 【层号】layer = 5。RefitOverlay（过场）在层 10 —— 过场在黑幕上盖 UI，
## 血条必须留在它**下面**，否则过场时会在黑幕之上穿帮。

## 本层所在 CanvasLayer 层号。**别和 RefitOverlay 的 10 撞**。
const LAYER := 5

const ENEMY_DATA_PATH := "res://data/enemies.json"

## 目标提供者：返回玩家当前瞄准的敌人（Enemy 或 null）。**由 bridge_whitebox 注入。**
var target_provider := Callable()
## 外部锁（L3 夺镜期间让位）。优先于任何内部判断 —— 测试用它能免建 CollapseSequence。
## 与 `GameFeel.lock_check` 同一套路。
var lock_check := Callable()

var _box: Control
var _title: Label
var _bar_bg: ColorRect
var _bar_fill: ColorRect
var _hp: Label

## 当前显示的目标。**随时可能被 queue_free**，所有读取前都要 is_instance_valid。
var _target: Enemy = null
## 当前血量比例 0..1（由 `_apply_hp` 维护，供自省 / 测试读）。
var _ratio := 1.0
## 淡入淡出进度 0..1。
var _alpha := 0.0

## 血条几何 / 配色（来自 HealthKit，_build 时读一次）。
var _w := 440.0
var _h := 16.0
var _gap := 6.0
var _label_h := 22.0
var _fade := 0.22
var _low_ratio := 0.3
var _fill_color := Color(0.86, 0.26, 0.20)
var _low_color := Color(0.98, 0.72, 0.16)
var _title_text := "当前目标"

## 敌人 type_id → 中文名（读 enemies.json 的 `display_name`，与 ⑨a 战损报告同一份文案）。
var _names: Dictionary = {}


func _ready() -> void:
	layer = LAYER
	_load_names()
	_build()
	# 空闲不跑 _process：只在接管期间工作（同 GameFeel / AudioManager 的做法）。
	set_process(false)
	# 接管进出 = 开关本层；伤害 / 击杀 / 状态机 = 目标内容与可见性的即时修正。
	EventBus.turret_takeover_started.connect(_on_takeover_started)
	EventBus.turret_takeover_ended.connect(_on_takeover_ended)
	EventBus.enemy_damaged.connect(_on_enemy_damaged)
	EventBus.enemy_killed.connect(_on_enemy_killed)
	EventBus.game_state_changed.connect(_on_game_state_changed)


func _process(delta: float) -> void:
	advance(delta)


## 推进一帧。**公开**，与 Enemy.advance / GameFeel.advance 同一套约定：
## 测试直接喂 delta，淡入淡出时序才断言得准。
func advance(delta: float) -> void:
	if _locked_out():
		_alpha = 0.0
		_target = null
	else:
		_refresh_target()
		var want := 1.0 if _has_live_target() else 0.0
		var step := 1.0 if _fade <= 0.0 else delta / _fade
		_alpha = move_toward(_alpha, want, step)
	_box.modulate = Color(1, 1, 1, _alpha)
	_box.visible = _alpha > 0.001
	# 淡出到底且没目标 → 收工（下一次接管会再打开）。
	if _alpha <= 0.001 and not _has_live_target():
		_target = null
		set_process(false)


# ── 接管 / 状态机接线 ──────────────────────────────────────

func _on_takeover_started(_turret_id: StringName) -> void:
	set_process(true)


## 结束接管：**不在这里立刻清目标**，而是让 `advance` 走完淡出。
## provider 在接管结束后自然返回 null（bridge 的闭包会查 current_manual_id），
## 所以这里只需保证 `_process` 还开着，动画就能跑完并自动停。
func _on_takeover_ended(_turret_id: StringName) -> void:
	set_process(true)


## 离开 BATTLE（收战 / 失败）→ 立刻丢目标。血条是战斗信息，REFIT / RESULT 不该有。
func _on_game_state_changed(new_state: StringName) -> void:
	if new_state != &"BATTLE":
		_target = null
		set_process(true)


# ── 目标内容即时修正 ────────────────────────────────────────

## 受击 → 立刻更新（不等下一帧的轮询）。离散事件，不会刷爆。
func _on_enemy_damaged(enemy: Node, _amount: float, hp: float, hp_max: float) -> void:
	if enemy == null or enemy != _target:
		return
	_apply_hp(hp, hp_max)


## 目标被击杀 → 丢引用。下一帧 `advance` 会自动改锁「次近的敌人」，
## 于是"打完一个自动接下一个目标"是自然发生的，不需要特判。
func _on_enemy_killed(enemy: Node) -> void:
	if enemy == _target:
		_target = null


## 查 provider → 目标变了就换标题与血量。**每帧调一次**，但只在接管期间跑。
func _refresh_target() -> void:
	var e: Enemy = null
	if target_provider.is_valid():
		e = target_provider.call() as Enemy
	if not is_instance_valid(e):
		e = null
	if e == _target:
		return
	_target = e
	if e == null:
		return
	_title.text = "%s · %s" % [_title_text, _display_name(e.type_id)]
	_apply_hp(e.hp, e.hp_max)


## 把血量写进血条：填充分宽 + 低血变色 + 数字。**唯一写血条的地方**。
func _apply_hp(hp: float, hp_max: float) -> void:
	_ratio = 1.0 if hp_max <= 0.0 else clampf(hp / hp_max, 0.0, 1.0)
	_bar_fill.size = Vector2(_w * _ratio, _h)
	_bar_fill.color = _low_color if _ratio <= _low_ratio else _fill_color
	_hp.text = "%d / %d" % [roundi(hp), roundi(hp_max)]


# ── 自省 API（测试 / 排障用）────────────────────────────────

func is_showing() -> bool:
	return _box != null and _box.visible


func bar_ratio() -> float:
	return _ratio


func alpha() -> float:
	return _alpha


func target() -> Enemy:
	return _target


func hp_text() -> String:
	return _hp.text if _hp != null else ""


func title_text() -> String:
	return _title.text if _title != null else ""


## 填充条当前像素宽（测试直接断言"比例对不对"，比读浮点比例更贴近肉眼所见）。
func fill_width() -> float:
	return _bar_fill.size.x if _bar_fill != null else 0.0


func bar_width() -> float:
	return _w


# ── 内部 ────────────────────────────────────────────────────

func _has_live_target() -> bool:
	return _target != null and is_instance_valid(_target)


## L3 夺镜期间让位。优先用注入的 lock_check —— 没有就当作未锁。
func _locked_out() -> bool:
	if lock_check.is_valid():
		return bool(lock_check.call())
	return false


func _display_name(type_id: StringName) -> String:
	return str(_names.get(String(type_id), String(type_id)))


## 敌人中文名（文案外置，宪法第 3 条）。读一次就够 —— 它在进程内不变。
func _load_names() -> void:
	if not FileAccess.file_exists(ENEMY_DATA_PATH):
		return
	var f := FileAccess.open(ENEMY_DATA_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return
	var en: Variant = (parsed as Dictionary).get("enemy", null)
	if en is Dictionary and (en as Dictionary).get("display_name") is Dictionary:
		_names = (en as Dictionary)["display_name"] as Dictionary


# ── 构建 ────────────────────────────────────────────────────

## 代码建 UI 而非 .tscn，理由同 RefitOverlay：本层全是程序化容器，
## 编辑器手搭的 .tscn 与脚本双向绑定容易被 Reload 覆盖（记忆 tooling.md 有约定），
## 且本层零美术资源依赖，代码建没有维护成本。
func _build() -> void:
	var b := HealthKit.bar()
	_w = float(b.get("width", 440.0))
	_h = float(b.get("height", 16.0))
	_gap = float(b.get("gap", 6.0))
	_label_h = float(b.get("label_height", 22.0))
	_fade = maxf(0.0, float(b.get("fade_time", 0.22)))
	_low_ratio = float(b.get("low_ratio", 0.3))
	_fill_color = HealthKit.parse_color(b.get("fill_color", null), Color(0.86, 0.26, 0.20))
	_low_color = HealthKit.parse_color(b.get("low_color", null), Color(0.98, 0.72, 0.16))
	var bg := HealthKit.parse_color(b.get("bg_color", null), Color(0.02, 0.02, 0.03, 0.72))
	_title_text = str(b.get("title", "当前目标"))
	var font_size := int(b.get("font_size", 15))
	var top := float(b.get("offset_top", 84.0))

	_box = Control.new()
	_box.name = "TargetBarBox"
	_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.visible = false
	_box.modulate = Color(1, 1, 1, 0.0)
	add_child(_box)

	_title = _make_label(font_size)
	_title.name = "TargetName"
	_anchor_center_top(_title, top, _label_h)
	_box.add_child(_title)

	_bar_bg = ColorRect.new()
	_bar_bg.name = "BarBG"
	_bar_bg.color = bg
	_bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor_center_top(_bar_bg, top + _label_h + _gap, _h)
	_box.add_child(_bar_bg)

	# 填充条是背景条的**子节点**：宽度直接用像素设（不靠锚点百分比），
	# 于是"还剩几成"= `_w * ratio`，测试能一眼对上肉眼所见。
	_bar_fill = ColorRect.new()
	_bar_fill.name = "BarFill"
	_bar_fill.color = _fill_color
	_bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar_fill.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_bar_fill.position = Vector2.ZERO
	_bar_fill.size = Vector2(_w, _h)
	_bar_bg.add_child(_bar_fill)

	# 数字贴在条上（不满铺，只占条高），不占额外纵向空间。
	_hp = _make_label(font_size)
	_hp.name = "TargetHP"
	_hp.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar_bg.add_child(_hp)


## 统一造 Label：居中 + 黑描边（宇宙背景明暗不定，没有描边的字在亮星区会糊）。
func _make_label(font_size: int) -> Label:
	var l := Label.new()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 4)
	return l


## 水平居中、从屏幕顶往下 top 处、高 h 的锚点。
## 不用 PRESET_CENTER_TOP 是因为它不带固定宽度 —— 直接用 offset 定死更可控。
func _anchor_center_top(c: Control, top: float, h: float) -> void:
	c.anchor_left = 0.5
	c.anchor_right = 0.5
	c.anchor_top = 0.0
	c.anchor_bottom = 0.0
	c.offset_left = -_w * 0.5
	c.offset_right = _w * 0.5
	c.offset_top = top
	c.offset_bottom = top + h
