extends CanvasLayer
class_name RefitOverlay

## ⑦ 维修站过场的**纯 UI 哑层**（2026-09-08）
##
## **职责边界**：只管「怎么画」，不管「什么时候画 / 画什么内容」——
## 时序与台词编排全在 `scripts/systems/refit_sequence.gd`，本类一行决策都不做。
## 这样拆是为了可测：过场逻辑能在 headless 下跑断言，UI 只是个不会思考的显示器。
##
## **为什么用代码建 UI 而不是 .tscn**：
##   本层节点全是程序化容器（锚点 / 最小尺寸 / 可见字符数），
##   编辑器手搭出来的 .tscn 在与脚本双向绑定时容易被 Reload 覆盖（记忆 tooling.md 有约定）。
##   且本层没有任何美术资源依赖，代码建没有维护成本。
##
## **阶段 B 注意**：等维修站模型和维修师角色到位，本类的对话框 / 改装台要搬到 3D 呈现，
## 但**台词文本层与打字机逻辑可以原样复用** —— 所以这里不写死任何 3D 假设。

const DEBUG_LOG := false

## 台词区
var _speaker: Label
var _text: RichTextLabel
var _portrait: ColorRect
var _hint: Label
var _dialog: PanelContainer

## 过场「正在前往维修站」大字
var _travel: Label

## 改装台
var _garage: PanelContainer
var _g_title: Label
var _g_sub: Label
var _g_slots: RichTextLabel
var _g_variants: RichTextLabel
var _g_hint: Label

## ⑨a 战损面板（DEC-043 出口 ② · 维修站）：与维修师对话框**同屏**，负责列数字。
var _damage: PanelContainer
var _d_title: Label
var _d_body: RichTextLabel

## 黑幕（所有过场的地基）
var _fade: ColorRect

## 打字机状态
var _full_text := ""
var _shown := 0
var _cps := 42.0
var _acc := 0.0

## 维修师头像占位色（无美术阶段的一抹颜色，比纯灰好认）
var _portrait_color := Color(0.24, 0.32, 0.40)


func _ready() -> void:
	layer = 10
	_build_fade()
	_build_travel()
	_build_dialog()
	_build_damage()
	_build_garage()
	hide_all()


## 注入 refit.json 的演出参数。由 RefitSequence 在 start 前调一次。
func setup(cfg: Dictionary) -> void:
	var cut: Dictionary = cfg.get("cutscene", {}) as Dictionary
	_cps = float(cut.get("typewriter_cps", 42.0))
	var mech: Dictionary = cfg.get("mechanic", {}) as Dictionary
	var pc: Array = mech.get("portrait_color", [0.24, 0.32, 0.40]) as Array
	if pc.size() >= 3:
		_portrait_color = Color(float(pc[0]), float(pc[1]), float(pc[2]))
	if _portrait != null:
		_portrait.color = _portrait_color


## 黑幕透明度 0..1。过场进出都靠它，是所有阶段的公共背景。
func set_fade(a: float) -> void:
	if _fade == null:
		return
	_fade.color = Color(0.0, 0.0, 0.0, clampf(a, 0.0, 1.0))


## 阶段一：黑屏 + 一行字（白盒降级，阶段 B 换成 3D 飞行镜头）。
func show_travel(line: String, sub: String = "") -> void:
	hide_all()
	if _travel == null:
		return
	_travel.text = line if sub.is_empty() else "%s\n%s" % [line, sub]
	_travel.visible = true


## 阶段二：维修师对话框（头像占位 + 名字 + 打字机正文）。
func show_mechanic(speaker: String, text: String) -> void:
	hide_all()
	if _dialog == null:
		return
	_speaker.text = speaker
	_dialog.visible = true
	_text.text = text
	_text.visible_characters = 0
	_full_text = text
	_shown = 0
	_acc = 0.0


## ⑨a 战损面板（**DEC-043 出口 ②**）：与对话框**同屏**列出本波损伤数值。
## 台词只点名一门（出口 ③），具体数字在这里 —— 情绪归台词、数据归面板，互不抢戏。
## 传空标题 = 不显示：过场没有战损数据时别白占一块地方。
func set_damage_panel(title: String, body_bb: String) -> void:
	if _damage == null:
		return
	_damage.visible = not title.is_empty()
	if _damage.visible:
		_d_title.text = title
		_d_body.text = body_bb


## 打字机推进。返回 true = 这句话已经打完（调用方据此决定「按任意键」是翻页还是补全）。
func type_step(delta: float) -> bool:
	if _shown >= _full_text.length():
		_text.visible_characters = -1
		return true
	_acc += delta * _cps
	var n := int(_acc)
	if n > _shown:
		_shown = n
		_text.visible_characters = _shown
	if _shown >= _full_text.length():
		_text.visible_characters = -1
		return true
	return false


## 跳过打字动画：直接补完全文（隐形跳过的落点）。
func finish_typing() -> void:
	_shown = _full_text.length()
	if _text != null:
		_text.visible_characters = -1


## 打字是否已完成。GARAGE 阶段不关心这个。
func typing_done() -> bool:
	return _shown >= _full_text.length()


## 设置对话框底部提示（「任意键继续」之类）。
func set_hint(s: String) -> void:
	if _hint != null:
		_hint.text = s


## 阶段三：改装台。slots / variants 已由 RefitSequence 排好序，
## 各自带 `highlight` 标记表示当前光标所在，本类只负责上色。
func show_garage(title: String, subtitle: String,
		slots_bb: String, variants_bb: String, hint: String) -> void:
	hide_all()
	if _garage == null:
		return
	_g_title.text = title
	_g_sub.text = subtitle
	_g_slots.text = slots_bb
	_g_variants.text = variants_bb
	_g_hint.text = hint
	_garage.visible = true


## 全部隐藏（阶段切换时调用，避免上一阶段的残影）。
func hide_all() -> void:
	if _travel != null:
		_travel.visible = false
	if _dialog != null:
		_dialog.visible = false
	if _damage != null:
		_damage.visible = false
	if _garage != null:
		_garage.visible = false


# ---------------------------------------------------------------- 构建

func _build_fade() -> void:
	_fade = ColorRect.new()
	_fade.name = "Fade"
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.color = Color(0.0, 0.0, 0.0, 0.0)
	# 必须 IGNORE：黑幕盖住全屏，若吃掉鼠标，过场结束后玩家点不动监控屏。
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fade)


func _build_travel() -> void:
	_travel = Label.new()
	_travel.name = "TravelLine"
	_travel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_travel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_travel.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_travel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_travel)


func _build_dialog() -> void:
	_dialog = PanelContainer.new()
	_dialog.name = "MechanicDialog"
	_dialog.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_dialog.offset_left = 90.0
	_dialog.offset_right = -90.0
	_dialog.offset_top = -190.0
	_dialog.offset_bottom = -40.0
	add_child(_dialog)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 18)
	_dialog.add_child(hbox)

	_portrait = ColorRect.new()
	_portrait.name = "Portrait"
	_portrait.color = _portrait_color
	_portrait.custom_minimum_size = Vector2(96, 96)
	hbox.add_child(_portrait)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 8)
	hbox.add_child(vbox)

	_speaker = Label.new()
	_speaker.name = "Speaker"
	vbox.add_child(_speaker)

	_text = RichTextLabel.new()
	_text.name = "Line"
	# 关 bbcode：visible_characters 是按**解析后**的字符数算的，
	# 开着 bbcode 时标签本身会被算进去，打字机速度会肉眼可见地飘。
	_text.bbcode_enabled = false
	_text.scroll_active = false
	_text.custom_minimum_size = Vector2(0, 78)
	_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_text)

	_hint = Label.new()
	_hint.name = "Hint"
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	vbox.add_child(_hint)


## ⑨a 战损面板（DEC-043 出口 ②）。贴在**对话框上方**而不是塞进对话框里：
## 台词要占满宽度跑打字机，挤在一起两边都难受；分开也好读 —— 下边情绪、上边数据。
func _build_damage() -> void:
	_damage = PanelContainer.new()
	_damage.name = "DamagePanel"
	_damage.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_damage.offset_left = 90.0
	_damage.offset_right = -90.0
	_damage.offset_top = 110.0
	_damage.offset_bottom = 300.0
	add_child(_damage)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	_damage.add_child(vbox)

	_d_title = Label.new()
	_d_title.name = "DamageTitle"
	vbox.add_child(_d_title)

	_d_body = RichTextLabel.new()
	_d_body.name = "DamageBody"
	_d_body.bbcode_enabled = true
	_d_body.scroll_active = false
	_d_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_d_body)


func _build_garage() -> void:
	# **刻意贴底而不是居中**：改装时镜头正对舰体外的炮位，换装特效（旧炮缩小消失 /
	# 新炮弹出）发生在画面上半部分。若面板居中 760×430，等于把唯一的正反馈挡死。
	_garage = PanelContainer.new()
	_garage.name = "Garage"
	_garage.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_garage.offset_left = 90.0
	_garage.offset_right = -90.0
	_garage.offset_top = -330.0
	_garage.offset_bottom = -40.0
	add_child(_garage)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	_garage.add_child(vbox)

	_g_title = Label.new()
	_g_title.name = "Title"
	vbox.add_child(_g_title)

	_g_sub = Label.new()
	_g_sub.name = "Subtitle"
	vbox.add_child(_g_sub)

	vbox.add_child(HSeparator.new())

	_g_slots = RichTextLabel.new()
	_g_slots.name = "Slots"
	_g_slots.bbcode_enabled = true
	_g_slots.scroll_active = false
	_g_slots.custom_minimum_size = Vector2(0, 110)
	_g_slots.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_g_slots)

	_g_variants = RichTextLabel.new()
	_g_variants.name = "Variants"
	_g_variants.bbcode_enabled = true
	_g_variants.scroll_active = false
	_g_variants.custom_minimum_size = Vector2(0, 130)
	_g_variants.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_g_variants)

	vbox.add_child(HSeparator.new())

	_g_hint = Label.new()
	_g_hint.name = "Hint"
	vbox.add_child(_g_hint)
