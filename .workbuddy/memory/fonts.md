# 字体 / 文本渲染（冷区 · 按需读）
> 触发时机：**任何要显示文字的活**（浮动伤害数字 / HUD / Label3D 标记 / 过场字幕）之前扫一遍。
> 全部为 2026-09-10 ⑪ ⑤ 前置实测（探针 `scripts/tests/font_probe.gd`，headless **7/7**）。预算 6000 字符。

---

## 0. 现状：本工程**一个字体都没配**（事实表）

| 项 | 实测值 |
|----|--------|
| `project.godot` 字体 / 主题配置 | **无**（没有 `[gui]` 段、没设 `theme`） |
| 仓库里的字体资源 | **无**（0 个 `FontFile` / `SystemFont`） |
| `ThemeDB.fallback_font` | `FontFile`，字体名 **"Open Sans SemiBold"**（引擎内嵌） |
| `ThemeDB.fallback_font_size` | 16 |
| `Font.allow_system_fallback` | `true` |
| TextServer 主接口 | ICU / HarfBuzz / Graphite (Built-in) —— **headless 下也是它**，能排版能光栅化 |

⇒ 所有 `Label` / `RichTextLabel` / `Label3D` 吃的都是「**内嵌 Open Sans + 系统兜底**」。

---

## 1. ⚠ 验"字能不能显示"必须走 **shaping**，`Font.has_char()` 会骗你

**现象**：`fallback_font.has_char("伤")` 返回 **false**，`get_char_size("伤")` 返回 **0 × 0**。
看起来「中文根本渲染不出来」——但这和事实矛盾：过场台词全是中文（`"这波刚挨的打"` / `"危机清空"`），实机看得见。

**根因**：Godot 的系统字体兜底发生在 **shaping（排版）阶段** —— TextServer 在 shaped text 里
给缺字形**插入一个替身 `font_rid`**。`Font` 对象自己的 cmap 查询只反映内嵌那点字形，**看不见兜底**。

**唯一可信的验法**（探针里的写法）：
```
TextServer.create_shaped_text()
  → shaped_text_add_string(sh, text, fonts, size)   # fonts = Font.get_rids()
  → shaped_text_shape(sh)
  → shaped_text_get_glyphs(sh)                      # 逐 glyph 看两个字段
        index == 0            → 豆腐（真渲染不出来）
        font_rid != fonts[0]  → 系统字体顶上（兜底在工作）
  → shaped_text_get_size(sh) → 排版尺寸
```
**通用**：判断"这段字能不能显示"，只信**排版结果**，别信字体对象。

---

## 2. 实测结论：⑪ ⑤ 浮动伤害数字**不依赖系统字体**，可以放心用

样本 `size = 24`，主字体 = 内嵌 Open Sans SemiBold。**"外来供字"= 有几个 glyph 由系统字体顶替**：

| 样本 | glyph 数 | 排版尺寸 | 豆腐 | 外来供字 | 判读 |
|------|---------|---------|------|---------|------|
| `0123456789` | 10 | 137 × 34 | 0 | **0** | 全部内嵌自带 |
| `-128` | 4 | 49 × 34 | 0 | **0** | 带负号也安全 |
| `+7` | 2 | 27 × 34 | 0 | **0** | |
| `×` (U+00D7) | 1 | 14 × 34 | 0 | **0** | 内嵌自带 |
| `★` (U+2605) | 1 | 20 × 34 | 0 | 1（系统） | 需兜底 |
| `伤` | 1 | 24 × 34 | 0 | 1（系统） | 需兜底 |

**两条关键结论**：
1. **`0-9` 与 `-` `+` `×` 全是内嵌字形** → 玩家机器装没装字体，都不影响伤害数字显示。
   （bible 04 §八 那句"不能把关键反馈押在字能不能渲染上"，对**数字**不成立；只对中文标注成立。）
2. **数字是等宽的**：`0-9` 单字推进宽**全为 14.00**（size 24）→ 位数从 9 变 10 时横排**不左右抖**。
   ⑤ 用默认居中对齐即可，不需要逐字符手动对齐。

**代价提示**：若给数字配中文标注（"伤害 128"）或星标 `★`，那条会走系统兜底 ——
**能显示，但不同机器换字体 → 字宽 / 字形不可控**。⇒ 浮字优先「纯数字 + 符号」，少用中文。

---

## 3. 兜底失效时怎么判（防"我机器上看不见＝代码坏了"）

- headless 与 GUI 的 TextServer 都是 Built-in Advanced，**排版结论两边一致**（本册结论即 headless 测得）。
- 兜底取不到字时，`shaped_text_get_glyphs()` 给 `index == 0`，**不报错、不告警** → 静默豆腐，
  只能靠探针这类主动检查发现。
- 想看"画到屏幕上的像素"，headless 是 dummy 渲染驱动（`get_image()` 拿不到）→ 必须走 GUI，见 §4。

---

## 4. 尚未验证的（写给下次接手）

- **像素级证据**：shaping 只证明「字形排进去了、尺寸非零」，没证明「画到屏上是实心而不是空白」。
  要硬证据就 GUI 下跑：`SubViewport` + `Label` + `render_target_update_mode = ALWAYS`
  → `await RenderingServer.frame_post_draw` → `get_texture().get_image()` 数非透明像素。
- **`Label3D` 的实测**：⑨b 已在用（`scripts/systems/collapse_sequence.gd`，不显式设字体）。
  浮字若走 3D 世界空间（贴在命中点），要另验 `pixel_size` / `billboard` / `no_depth_test` 的实际观感。
- **系统兜底在 GUI 下是否同样成立**（headless 已过，GUI 待补）。
