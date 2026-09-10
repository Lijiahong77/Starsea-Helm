extends SceneTree

## 字体验证探针 L1（⑪ ⑤ 浮动伤害数字的**前置可行性验证**）· 2026-09-10
##
## 跑法（headless，秒级）：
##   godot_console --headless --path <proj> --script res://scripts/tests/font_probe.gd
##
## 背景：本工程未配置任何字体资源 —— project.godot 无 [gui] theme，仓库里也没有
##   FontFile / SystemFont。所有 Label / Label3D / RichTextLabel 都吃 Godot 内嵌默认字体
##   （实测 = FontFile「Open Sans SemiBold」，不含 CJK）。
##   ⑪ ⑤ 要拿数字做浮动伤害，必须先回答两件事：
##     ① 数字字形渲染得出来吗？宽度稳不稳（位数变化会不会左右跳）？
##     ② 命中是靠**内嵌字体**还是靠**系统 fallback**？—— 决定"能不能把关键反馈押在字上"
##
## ⚠ 关键方法论（第一版探针踩过，记在这里别重犯）：
##   **`Font.has_char()` 不反映系统 fallback。** Godot 的系统字体兜底发生在
##   **shaping（排版）阶段**，由 TextServer 在 shaped text 里插入"替身 font_rid"，
##   而 Font 对象自己的 cmap 查询永远只有内嵌那点字形。
##   → 只信 Font.has_char() 会得到「中文渲染不出来」的**假阴性**结论
##     （而本项目过场台词全是中文，实机明明看得见）。
##   → **唯一可信的验法：走 TextServer.create_shaped_text + add_string + shape**，
##     再看每个 glyph 的 `index`（0 = 豆腐）和 `font_rid`（≠ 主 rid = 系统 fallback 顶上）。

const DIGITS := "0123456789"
const CJK := "伤"
const SAMPLES := ["0123456789", "-128", "+7", "★", "×"]
const SIZE := 24

var _pass := 0
var _fail := 0


func _initialize() -> void:
	print("===== FONT PROBE L1 (headless) =====")
	var f: Font = ThemeDB.fallback_font
	_probe_text_server()
	_probe_identity(f)
	_probe_notice_autoload()
	var rid_ok := _probe_rids(f)
	if rid_ok:
		_probe_shaping(f)
		_probe_digits_advance(f)
	_report()
	print("===== END =====")
	quit()


# ------------------------------------------------ [A] 引擎侧：谁在提供字形

func _probe_text_server() -> void:
	var ts := TextServerManager.get_primary_interface()
	var ts_name := "?"
	if ts != null:
		ts_name = ts.get_name()
	print("[A] TextServer 主接口 = %s" % ts_name)
	_check("TextServer 不是 Dummy（headless 下仍能排版 / 光栅化字形）", ts_name != "Dummy")


# ------------------------------------------------ [B] 默认字体到底是什么

func _probe_identity(f: Font) -> void:
	_check("ThemeDB.fallback_font 非 null", f != null)
	if f == null:
		return
	print("[B] 字体资源类 = %s" % f.get_class())
	print("    字体名 = %s   样式 = %s" % [f.get_font_name(), f.get_font_style_name()])
	print("    fallback_font_size = %d      allow_system_fallback = %s"
		% [ThemeDB.fallback_font_size, str(f.allow_system_fallback)])
	print("    ascent = %.2f  descent = %.2f  (size %d)" % [f.get_ascent(SIZE), f.get_descent(SIZE), SIZE])


# 说明「--script 模式下 autoload 何时可用」——顺手证一下，免得下次又踩
func _probe_notice_autoload() -> void:
	var has_bus := root.has_node("EventBus")
	print("[B2] _initialize() 期间 root 上是否有 autoload/EventBus = %s" % str(has_bus))
	print("     （注：--script 模式下引擎仍会实例化 autoload，但时点在 _initialize() 之后 ——")
	print("      所以探针代码里用不了 EventBus，不是'没实例化'，是'还没挂上'。）")


# ------------------------------------------------ [C] 取字体 RID

func _probe_rids(f: Font) -> bool:
	if f == null or not f.has_method("get_rids"):
		_check("Font.get_rids() 可用", false)
		return false
	var raw: Variant = f.call("get_rids")
	if not (raw is Array):
		_check("Font.get_rids() 返回数组", false)
		return false
	var arr: Array = raw as Array
	print("[C] Font.get_rids() = %d 个 RID" % arr.size())
	_check("拿到字体 RID（后续 shaping 要用）", arr.size() > 0)
	return arr.size() > 0


# ------------------------------------------------ [D] 排版层实测（唯一可信的那条路）

func _probe_shaping(f: Font) -> void:
	var ts := TextServerManager.get_primary_interface()
	var fonts := _typed_fonts(f)
	var main_rid: RID = fonts[0]
	print("[D] shaping 实测（主字体 RID = %s）" % str(main_rid))

	# ---- 数字：是否全命中、是否同源（= 不依赖系统字体）
	var d: Dictionary = _shape(ts, fonts, DIGITS, SIZE)
	var d_glyphs: Array = d["glyphs"]
	var d_zero := 0
	var d_foreign := 0
	for i in d_glyphs.size():
		var g: Dictionary = d_glyphs[i]
		var gi: int = int(g.get("index", -1))
		var gr: RID = g.get("font_rid", RID())
		if gi == 0:
			d_zero += 1
		if gr != main_rid:
			d_foreign += 1
	print("    \"%s\" → glyph %d 个 / 尺寸 %s / index=0 的 %d 个 / 非主字体供字 %d 个"
		% [DIGITS, d_glyphs.size(), str(d["size"]), d_zero, d_foreign])
	_check("数字 0-9 全部命中字形（无豆腐，index=0 的 %d 个）" % d_zero, d_zero == 0)
	_check("数字字形全部来自**内嵌字体**（非主字体供字 %d 个 → 不依赖系统字体）" % d_foreign,
		d_foreign == 0)

	# ---- 中文：系统 fallback 到底有没有在排版层顶上
	var c: Dictionary = _shape(ts, fonts, CJK, SIZE)
	var c_glyphs: Array = c["glyphs"]
	var c_zero := 0
	var c_foreign := 0
	for i in c_glyphs.size():
		var g: Dictionary = c_glyphs[i]
		if int(g.get("index", -1)) == 0:
			c_zero += 1
		if (g.get("font_rid", RID()) as RID) != main_rid:
			c_foreign += 1
	print("    \"%s\" → glyph %d 个 / 尺寸 %s / index=0 的 %d 个 / 非主字体供字 %d 个"
		% [CJK, c_glyphs.size(), str(c["size"]), c_zero, c_foreign])
	_check("中文能排版出字形（≫ 与过场台词可显示的事实一致），尺寸 %s" % str(c["size"]),
		c_glyphs.size() > 0 and c_zero == 0)
	_check("中文由**系统字体**顶替（非主字体供字 %d 个 → 证明 fallback 链路通）" % c_foreign,
		c_foreign > 0)

	# ---- 其余样本：伤害数字周边会用到的符号
	for s in SAMPLES:
		var r: Dictionary = _shape(ts, fonts, s, SIZE)
		var gs: Array = r["glyphs"]
		var zeros := 0
		var foreign := 0
		for i in gs.size():
			var g: Dictionary = gs[i]
			if int(g.get("index", -1)) == 0:
				zeros += 1
			if (g.get("font_rid", RID()) as RID) != main_rid:
				foreign += 1
		print("    样本 \"%s\" → %d glyph / 尺寸 %s / 豆腐 %d / 外来 %d"
			% [s, gs.size(), str(r["size"]), zeros, foreign])


# ------------------------------------------------ [E] 数字推进宽度：位数变化会不会抖

func _probe_digits_advance(f: Font) -> void:
	var ts := TextServerManager.get_primary_interface()
	var fonts := _typed_fonts(f)
	print("[E] 单字推进宽度（size=%d，决定位数变化时横排会不会左右跳）" % SIZE)
	var wmin := 1e9
	var wmax := -1e9
	for i in DIGITS.length():
		var ch := DIGITS.substr(i, 1)
		var r: Dictionary = _shape(ts, fonts, ch, SIZE)
		var sz: Vector2 = r["size"]
		if sz.x < wmin:
			wmin = sz.x
		if sz.x > wmax:
			wmax = sz.x
		print("    '%s'  推进宽 = %.2f  高 = %.2f" % [ch, sz.x, sz.y])
	print("    min=%.2f  max=%.2f  → %s" % [wmin, wmax,
		"等宽（数字位数变化时横排不抖）" if absf(wmax - wmin) < 0.01
		else "比例宽度（'1' 比 '8' 窄，位数变化会左右轻微抖 → ⑤ 需注意锚点方式）"])


# ------------------------------------------------ 工具

## 把 Font 的 RID 收成 typed array —— shaped_text_add_string 要 Array[RID]
func _typed_fonts(f: Font) -> Array[RID]:
	var out: Array[RID] = []
	var raw: Variant = f.call("get_rids")
	if raw is Array:
		for x in (raw as Array):
			var r: RID = x
			out.append(r)
	return out


func _shape(ts: TextServer, fonts: Array[RID], text: String, size: int) -> Dictionary:
	var sh: RID = ts.create_shaped_text()
	ts.shaped_text_add_string(sh, text, fonts, size)
	ts.shaped_text_shape(sh)
	var glyphs: Array = ts.shaped_text_get_glyphs(sh)
	var sz: Vector2 = ts.shaped_text_get_size(sh)
	ts.free_rid(sh)
	return {"glyphs": glyphs, "size": sz}


func _report() -> void:
	print("----- 结果 -----")
	print("断言: %d/%d 通过" % [_pass, _pass + _fail])
	if _fail > 0:
		print("失败: %d" % _fail)


func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  [PASS] %s" % label)
	else:
		_fail += 1
		print("  [FAIL] %s" % label)
