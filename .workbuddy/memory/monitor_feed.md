# 监控 feed 子系统（冷区 · 按需读）
> 触发时机：动监控 / 相机挂载 / 屏幕材质 / 4 路 feed 出图时读。
> 主脚本 `scripts/bridge/bridge_whitebox.gd`；**所有旋钮在 `data/presentation.json` 的 `monitor` 段**，禁止 hardcode。
> 通用 Godot 坑见 `godot_pitfalls.md`，本册只放监控特有的。

## 几何（调 mount 必看，`.tscn` 实测值）
白盒目前只建了**舰桥房间**（不是整艘 22m 船）。房间净尺寸 5.4 宽 × 6.4 高 × 6.4 深，z 中心 ≈ -1.3。

| 方向 | 节点 | 中心 | 尺寸 | 外表面 |
|------|------|------|------|--------|
| 左 | WallLeft | x=-2.6, y=1.5, z=-1.3 | 0.2×6.4×6.4 | **x=-2.7** |
| 右 | WallRight | x=+2.6 | 0.2×6.4×6.4 | **x=+2.7** |
| 上 | Ceiling | y=+3.1, z=-1.3 | 5.4×0.2×6.4 | **y=+3.2** |
| 下 | Floor | y=-0.1, z=-1.3 | 5.4×0.2×6.4 | **y=-0.2** |

**当前 4 路 mount**（`monitor.feed_cams[i].mount`，与 `axis`/`up` 平级）：
`SVPort [-2.8,1.5,0]` / `SVStarboard [2.8,1.5,0]` / `SVDorsal [0,3.3,0]` / `SVVentral [0,-0.3,0]`
→ 4 路 `[aim]` 日志全为 `显式`，距中心 3.2 / 3.2 / 3.3 / 0.3m。

⚠ **余量警告**：左墙外表面 -2.7，mount 取 -2.8 只剩 **0.1m**，与 `camera.near=0.1` 相等——能跑但不安全。
建议 **±3.0~3.2**（留 0.3~0.5m），将来补舰体网格也不会陷进去。

## 材质旋钮
`monitor.screen_material`：`albedo_color` / `emission` / `emission_enabled`。
**键存在 → JSON 覆盖（运行时强制）；键不存在 → 保留 `.tscn`/编辑器里的值。**
当前默认 `albedo=[1,1,1]`、`emission=[0,0,0]`、`emission_enabled=false`（= 用户要的"摄像机原始画面"）。
调亮两旋钮：`render.ambient_energy` 调大，或 `emission` 给小非黑值（如 `[0.4,0.4,0.4]`）做填充光。

**⚠ ALBEDO 公式坑**：`StandardMaterial3D` 是 `ALBEDO = albedo_color × albedo_texture`。
`.tscn` 里 albedo_color 曾是深色兜底 (0.05,0.06,0.08) —— **关掉 emission 后画面只剩 5% 亮度 = 黑屏**。
→ 关 emission 必须同时把 albedo 提到白，二者成对改。

## feed 出图四件套（缺一就白板 · 原 `godot_pitfalls` §1-3）
**现象**：监控屏幕全白 / 粉黑棋盘 / 拍空世界。**根因**：纹理绑定失败 → 材质退化成纯白 emission（相机其实一直摆位正确，白板与相机无关）。
1. **纹理绑定**：`var vt := sv.get_texture()`。
   - ❌ `ViewportTexture.new()` + `vt.viewport_path = ...` → 运行时解析不到节点。
   - ❌ `.tscn` sub_resource 里写 `viewport_path` → 以「材质使用节点」为基准解析，深层节点必报 `Path to node is invalid`。
   - ❌ `SubViewport.texture` → Godot 4 已移除（3.x 才有）。
2. `render_target_update_mode = 3`（UPDATE_ALWAYS）—— 默认 UPDATE_WHEN_VISIBLE **不渲染**，因为 SubViewport 自身不在屏幕上、只靠纹理显示。
3. FeedCam `current = true`。
4. 主相机 `Player/Camera3D` 也须 `current = true`（根视口必须有 active camera，否则主画面被某个 feed 相机抢走）。
**兜底**：屏幕材质留深色 albedo、emission 关或压到 0.28 灰（过亮 = 白板复发）。

## SubViewport 默认不共享主世界（→ 拍到"空世界"）
**现象**：feed 里没有标记物 / 灯光 / 环境。
**根因**：Godot 4 `SubViewport` 默认 `own_world_3d = true`，自建独立 `World3D`。
**修法**：`_ready()` 里、摆相机之前 —— `for sv in _feeds: sv.world_3d = get_viewport().world_3d`。

## BoxMesh 的 UV 是 3×2 图集 —— 显示屏一律用 QuadMesh
**现象**：编辑器 Camera Preview 里目标在正中心，监控屏上却偏离中心。
**根因**（headless 逐顶点 dump 证明）：`BoxMesh` 把 6 个面各分到 UV 空间的 1/3 × 1/2。`BoxMesh(0.5,0.375,0.02)` 的正面（法线 +Z）UV 区间只有 **(0,0)..(0.3333,0.5)** —— 只采样整幅画面左上角 1/3 宽 × 1/2 高再拉满整屏。
**修法**：要「一张贴图完整铺满一个面」用 **`QuadMesh`** —— 朝向、法线(+Z)、uv(0,0) 在左上角与 BoxMesh 正面完全一致，UV 完整 (0,0)..(1,1)，**可直接替换、不用改 transform**。（`PlaneMesh` 在 XZ 平面、法线 +Y，需另转 90°。）
**配套三条，缺一仍偏**：① 网格长宽比 **== 渲染目标长宽比**（`quad.size = Vector2(w, w/(feed_w/feed_h))`）→ 等比铺满不裁不拉；② 材质显式归位 `uv1_scale=(1,1,1)` / `uv1_offset=(0,0,0)`，防御 `.tscn` 残留；③ **运行时重建**网格并赋给 MeshInstance3D，双保险免疫编辑器回退。

## 出图链路与坑（全实测）
1. **`ImageTexture.new()` 是 0×0**，首帧 `update(320×240)` 报 `new image dimensions must match`
   且**不抛异常、只是静默不更新** → 表现"代码全对、屏幕永远全黑"。
   修：尺寸不符时走 `it.set_image(img)`（首帧一次），之后 `update()`。
2. **`ViewportTexture.get_format()` 返回 GPU 内部格式（47）**，不能拿来 `Image.create()`
   （报 `format (47) is out of range`）。
3. **`Image.create_black/create_blank` 在 Godot 4 不存在** → 别想"预填黑图防 0×0 闪白"，
   靠首帧 `set_image()` 兜底即可（emission 关掉后 0×0 只短暂黑一下，不会白板）。
4. **SubViewport 直接 `get_image()` 静态推不出类型**（Variant → 触发本项目"警告即错误"→ Parse Error）。
   走 `sv.get_texture().get_image()` 再显式 `var img: Image`。
5. **`emission_enabled=true + emission=[1,1,1]` 会把 95% 黑的暗 feed 洗成白板**。
   想让屏自己发光就用小值；要"原始画面"必须关。诊断第④项会显示 `无自发光覆盖OK`。

**诊断**：`_diag_feeds()` 四项（UV 区间 / 长宽比 / 内容重心 / 材质状态），正常时重心 ≈(0.5,0.5)。
**抓帧**：`Godot/app_userdata/Starsea Helm/shots/`（main.png + 4 路 feed_*.png）。

## ❄️ DEC-038：冻结到模型落地（2026-09-07 用户拍板）

**状态：等模型做完、尺寸比例定下来再重启**。理由：用户原话「真实副炮位等我们到时候模型做出来再搬过去吧，现在尺寸比例还没有找到模型后最终确认出来」。

**冻结前快照**（恢复时用）：
- DEC-038 字面 = 副炮在舰体外表面 → 推导值 ±11 / ±8（按 `_hull_radius`）
- 当前实测 mount = 贴舰桥房间墙 ±2.8 / ±3.3
- 待决：① 删掉显式 mount 走回 ship 外壁（需整船网格 + 副炮网格）；② 把 DEC-038 的"外表面"改指舰桥舱壁（无需新网格，但语义缩窄）
- 同期待办：去掉装饰 Marker、炮塔被毁时该路 feed 变红/黑

**冻结期不要做的事**：
- ❌ 改 mount 数字或加新 mount
- ❌ 改 DEC-038 字面（搬模型那天才需要重写）
- ❌ 把"等待模型"挪进 BACKLOG 当 P0/P1——它是**外部依赖**，不是内部任务
