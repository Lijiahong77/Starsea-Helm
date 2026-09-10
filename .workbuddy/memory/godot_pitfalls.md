# Godot 4 引擎 / 渲染 / UV 踩坑速查（冷区 · 按需读）
> 触发时机：**写或改任何 `.gd` / `.tscn` 之前扫一遍小标题**；只在报相关错误时读对应小节全文。
> 全部为本工程实测，非二手知识。格式统一为「现象 → 根因 → 修法」。**语言层（类型系统）坑见 `gdscript_snags.md`。**

---

## 1–3. SubViewport feed 三件套 → 已移入 `monitor_feed.md`
> **2026-09-10 蒸馏**：这三节是**监控 feed 专属**的坑，已搬到 `monitor_feed.md`（本册保持「通用引擎坑」定位，
> 原来已到 99% 预算）。监控相关一律读 `monitor_feed.md`。
> 速记：① 纹理绑定必须 `sv.get_texture()`（❌ `ViewportTexture.new()`+`viewport_path`、❌ `.tscn` sub_resource）；
> ② `render_target_update_mode = 3`（UPDATE_ALWAYS）；③ FeedCam **和**主相机都须 `current = true`；
> ④ `SubViewport` 默认 `own_world_3d = true` → 需 `sv.world_3d = get_viewport().world_3d`；
> ⑤ 显示屏用 **`QuadMesh`**（`BoxMesh` 的 UV 是 3×2 图集，只采样左上角 1/3×1/2）。

## 4. 编辑器会覆盖外部改动（本项目已复发 3 次）

**现象**："改了又没改"，同一个报错反复出现。
**根因**：用户开着 Godot 编辑器、场景在内存里时，编辑器一保存就把内存旧版写回磁盘。
**对策**：
- 改 `.tscn` 前让用户**先关编辑器**（或改完一定提醒 Reload / 重开工程）；
- 我这边改完**必须 re-read 确认真的落地**，再接着改；
- 不依赖磁盘保持干净，用"运行时重建 / 运行时绑定"做唯一可靠防线；
- `.tscn` 的 `[sub_resource]` 与节点块内**不能放 `#` 注释**（含中文/方括号会被当属性解析 → Failed loading scene）。

## 5. 验证纪律（连错多轮后的铁律）

> 测试 / 验证的**通用**纪律（清场、走真实调用路径、环境坑）已拆到 `testing.md` —— 本节只留**渲染 / 编辑器相关**的三条专用检查。

- 改完文件 → **re-read 确认落地** → 用 MCP `run_project` + `get_debug_output` **实跑确认 `errors:[]`**。不许凭"我以为改了"报成功。
- feed / 渲染类问题用 **`sv.get_texture().get_image()` 采样像素**实测证明，不靠"看起来对"。
- **Scene 面板显示的是 `.tscn` 保存值，不反映运行时修改**。要看运行时位姿看 **Remote 树**，否则会误判"相机在原点"。

## 6. GDScript / 类型层坑 → 已移入 `gdscript_snags.md`
> **2026-09-10 蒸馏**：9/8 建了 `gdscript_snags.md`（定位「只收语言层报错」）后，本节成了重复清单 →
> 已合并过去（`gdscript_snags.md §4`），含 `max()/min()` 返 Variant、`int/int` 折叠、欧拉角歧义、
> `emission_intensity` 报错、`look_at` 与 up 共线、天空球 `cull_front` 等条目。

## 7. headless 几何探针（查 UV / 位姿的第一手段，别猜）

写 `extends SceneTree` 的脚本，在 `_initialize()` 里构造 Mesh、dump `surface_get_arrays(0)` 的 VERTEX/TEX_UV/NORMAL、按法线分组统计每面 UV 区间，最后 `quit()`。
运行：`godot_console --headless --path <proj> --script res://scripts/tests/xxx.gd`（工程须已导入，即有 `.godot/`）。
现成脚本：`scripts/tests/uv_probe.gd`（dump 任意 Mesh 的 UV）、`scripts/tests/cam_probe.gd`（按 pos/target/up 算 Transform3D 并打印成 `.tscn` 可粘贴格式）。
**坑**：节点不在树上时 `Node3D.look_at()` 报 "Node not inside tree" 且**静默不生效**（保持单位矩阵）→ 用 `look_at_from_position()`。

## 8. 数值外置的正确姿势（范式，新增代码照抄）

- 代码里只留**结构映射**（哪路 feed 对应哪个标记、朝哪个轴），坐标/距离一律进 JSON。
- **看向点优先用「目标节点的实际世界坐标」**，别写死坐标 → 改距离旋钮时相机自动跟随不脱焦。
- **兜底值必须推导，不能是坐标常量**：缺 standoff 时用 `目标距离 × 比例`，而不是再写一个 `Vector3(0,30,0)`。
- **顺序陷阱**：兜底若依赖"目标当前位置"，必须**先摆目标、再解析配置**（曾出现"先解析 → 按摆放前旧距离算"，dorsal 算出 33.75 而非 45 的静默错误）。
- 配置解析结果**缓存**起来，避免多阶段重复解析与重复告警。

## 9. 运行时脚本会覆盖编辑器里拖出来的属性（9/3 踩）
- 只要脚本在 `_ready()` 里写了 `cam.position = ...`，**编辑器拖这个节点就是无效的**，一运行就被覆盖回脚本算的值。
- 排查"改了怎么没效果"先问：这个属性是不是被脚本在启动时写死？
- 想让编辑器预览对得上：用探针算出 Transform3D 粘回 `.tscn`，并把"编辑器里改无效"写进该函数头注释。

## 10. `@warning_ignore` 对 signal 的生效范围（9/3 踩，高频）

**现象**：EventBus 全量预声明 signal，当前无 `.connect()` 订阅方 → 刷屏
`WARNING: signal "xxx" is declared but never explicitly used in the class.`
**试错结论（Godot 4.7 实测）**：
- ❌ 文件级 `@warning_ignore("unused_signal")` 放 `extends` 上方 → **无效**（只对脚本级 warning 生效，管不到 class 成员）。
- ❌ `project.godot [warnings] unused_signal=0` → 经 MCP `run_project` 起的 debug 进程**不采纳**（疑似 debug 模式强制全 warning 输出）。
- ✅ **逐 signal 行内 `@warning_ignore("unused_signal")`**（紧贴 signal 声明上方）→ 唯一可靠。
**范式**：EventBus 每个 signal 上方都加一行 ignore，并配注释说明"接入前确无订阅方，是预留"。
一旦某 signal 真正被 `connect`，即可删掉它上方那行 ignore（否则会掩盖真·未用）。
**顺带**：`Node` 基类有 `name` 属性，自定义变量别叫 `name`，否则 `shadowed_variable` 警告
（改名 `s_name` 之类即可）。


## 11. StandardMaterial3D：ALBEDO = albedo_color × albedo_texture（9/3 黑屏元凶）
- 关掉 emission、改用 albedo 显示纹理时，若 `albedo_color` 还停在深色兜底值（如 0.05），
  纹理被乘到 5% 亮度 = 黑屏。**关 emission 必须同时把 albedo_color 提到白。**
- 监视器"显示摄像机原始画面"的两条路：
  · **受光照**：albedo_color=白 + emission off → 画面随舱内光照变暗，观感真实（当前默认）；
  · **不受光照**：emission=白(1,1,1) + emission_texture=feed → 绝对原图。
  注意：emission=白历史上之所以变成"白板"，是因为**纹理没绑上**时 emission 就是纯白；
  纹理绑上后（运行时 `SubViewport.get_texture()`）它就是精确原图，不再是白板。

## 12. headless 模式 = dummy 渲染驱动（无 GPU 时打 ERROR，但代码无 bug）
- `--headless` 用 **dummy 渲染驱动**，无 GPU/无 viewport/无纹理。任何 `texture_2d_get` 内部先打
  `ERROR: Parameter "t" is null.` 再 return null。
- **判别**：堆栈是 `servers/rendering/...` + 上层已 null 检查（不抛 push_error）= headless 锅。
- **不要**为这条 ERROR 加 null 分支掩盖 —— 真机不会出。主场景走 GUI 验证；只有无
  SubViewport 回读的逻辑测试场景走 headless。

## 13. autoload 的 `_ready` 早于主场景 → 首次广播**收不到**（9/7 踩）

**现象**：autoload 在 `_ready` 里 emit 的初始状态广播，主场景 connect 后**永远收不到**。
**根因**：autoload 先实例化，它 `_ready` 跑完时主场景还没进树，没人连着信号。
**修法**：主场景 `_ready` 里主动读一次补上（`_state = GameStateManager.state_name()`）。
**范式**：状态机加公开读法；别让外部碰私有的 `_STATE_NAMES`（映射存两处改枚举必漏）。
