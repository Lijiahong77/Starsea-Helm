# GDScript 语言层踩坑（类型系统 / 节点挂载 / API）
> 触发时机：**写或改 `.gd` 之前**（与 `godot_pitfalls.md` 一起扫，那个管渲染 / UV / 引擎行为）。
> 本册只收**语言层**报错。§1–3 为 2026-09-08 ⑦ 改装阶段实测；§4 于 2026-09-10 从 `godot_pitfalls §6` 合并过来。格式「现象 → 根因 → 修法」。预算 6000 字符。

## 1. `var v := dict.get(k)` → “从 Variant 推断类型”被**当错误**拦下

**现象**：Parse Error: `The variable type is being inferred from a Variant value`（Warning treated as error），
脚本直接加载失败，表现为「整个系统节点不可用」，报错行却只是一行平平无奇的取值。
**根因**：本工程把 GDScript warning 当 error（project.godot 里 warnings/... = error），
而 `Dictionary.get()` 返回 `Variant`，`:=` 推断不出具体类型。
**修法**：显式写类型 `var v: Variant = _variants.get(id, null)`，再用 `if v is Dictionary` 收窄。
**范式**：**凡是 `:=` 右边是 Dictionary/Array 的 `.get()` / JSON 解析结果，一律显式标注 `Variant`**。
同类：`var a := json["x"]`、`var n := cfg.get("hp")` 都中招。

## 2. 三元表达式无法统一 `Array[StringName]` 与 `[]`

**现象**：运行时 `Trying to assign an array of type "Array" to a variable of type "Array[StringName]"`。
写法是 `_slots = ts.swappable_ids() if ts != null else []`。
**根因**：两个分支类型不同（typed array vs untyped literal），GDScript 推不出公共类型 → 退化成 `Array`，
赋给 typed 变量时炸。**编译期不报**，跑到那一行才炸。
**修法**：改显式 if/else，两个分支各自赋值，让类型各自明确。
**范式**：**typed array 变量不要用三元赋默认值**，要么 if/else，要么 `Array[StringName]()` 显式构造。

## 3. 临时特效节点挂 `get_tree().get_root()` → `add_child()` 失败

**现象**：`Parent node is busy setting up children, add_child() failed. Consider add_child.call_deferred()`，
还附赠一串 RID / ObjectDB 泄漏（headless 下尤其显眼）。
**根因**：往 root 挂节点的时机可能正好卡在 root 遍历子节点做 setup 的过程中（典型：换装发生在 `_ready` 链里）。
**修法**：**常驻一个专用父节点**，在系统自己的 `_ready` 里建好（`_fx_root = Node3D.new(); add_child(_fx_root)`），
临时特效一律挂它。不要挂即将 `queue_free` 的对象（特效会跟着没）。
**顺序坑**：`global_position` 必须在 `add_child` **之后**设置，进树前设不准。
**范式**：一次性视觉节点 = 「常驻容器 + 自删 Tween」，容器是系统的私有财产，别往 root 上堆。

## 4. 类型 / API 零散坑（原 `godot_pitfalls §6`，2026-09-10 合并过来）

- `max()` / `min()` / `abs()` 返回 **`Variant`** → 显式声明：`var x: float = max(a, b)`。
- 整数除法 `int/int` 被折叠并告警 → 写 `2.0`（`floori(i/2.0)`）。
- `float(数组)` 不存在 → JSON 颜色数组逐项 `float(a[0])`。
- 字典/数组取值一律 `Variant` → 赋 `Color` / `String` 要 `as` 或显式声明（与本节 §1 同源）。
- 欧拉角有歧义 → 用 `Basis(x, y, z)` 构造基向量，别拼 `rotation_degrees`。
- `SubViewport` 没有 `default_clear_color`（Godot 4 删了）→ 用 `WorldEnvironment` + `Environment`。
- **未开 Physical Light Units 时设 `emission_intensity` 报错** → 用 `emission_enabled = true` + `emission = 颜色`，别设 intensity。
- `Camera3D.look_at` 与 up 共线会告警 / 滚转不确定 → 上下看时传 `up`，或运行时检查 `abs(axis.dot(up)) > 0.99` 自动换正交轴。
- 天空球 `SphereMesh` 内部观看：`render_mode cull_front` + `unshaded`。
- **`MeshInstance3D`（3D）没有 `modulate`** —— `modulate` 只属 **CanvasItem / 2D**。给 3D 节点写 `body.modulate = Color(...)` → SCRIPT ERROR。
  3D 改色用 `material_override.albedo_color`；注意 `material_override` 静态类型是基类 `Material`，取 `.albedo_color` 前要 cast 成 `StandardMaterial3D`。
- **`Font.has_char()` 不反映系统字体兜底** —— 兜底只在 **shaping 阶段**发生，Font 对象的 cmap 查不到它 →
  会得出「中文渲染不出来」的**假阴性**。判定"字能不能显示"必须走 shaped text，见 `fonts.md §1`。
- `Font.get_glyph_index()` 在 4.7 要 **3 个参数**（只给 2 个 → `Invalid call ... Expected 3 argument(s)`）。
  只验字形存在用 `has_char()`，或走 TextServer 的 `font_get_glyph_index(font_rid, size, char, variation_selector)`。
