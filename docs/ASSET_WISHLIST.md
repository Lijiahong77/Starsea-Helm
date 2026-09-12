# 美术资产需求清单（ASSET WISHLIST）

> 最后更新：2026-09-12
> 用途：对照去 Sketchfab 找 / 用 Hunyuan3D 生成的模型清单。按 `04_presentation.md §七` 的替换顺序分组。
> 尺度基准：**1 Godot 单位 = 1 米**，所有物理（威胁窗口 / 进场可见度）都建立在此，导入后必须锚定真实米。

## ⚠️ 授权红线（先读）

- 本项目 LICENSE = **保留所有权利**，这约束的是**你自己的代码与原创资产**。用外部素材的授权另算。
- **Sketchfab 只下这三种授权**：`CC0`（最省，无署名）、`CC-BY`（需在本仓库 `docs/ATTRIBUTION.md` 记来源+作者）、**已购买**（Store 付费）。
- ❌ **绝对不要下 `Standard` 授权的模型** —— 那种只能个人学习/预览，**不能进游戏**，上架或公开演示会侵权。
- Hunyuan3D 生成的模型：商用前查腾讯混元 3D 的生成条款；实验阶段直接生成单物体用即可。
- 任何 CC-BY 素材落地后，在 `docs/ATTRIBUTION.md` 登记一条：`素材名 | 作者 | 授权 | 来源URL`。

## 工程落地通则（每条都适用）

1. 导出格式统一 **`.glb`**（比 `.gltf` 单文件好管，Git 友好，Godot 4 原生导入）。
2. 导入 Godot 后**先调 scale 使最长边 = 表里标注的米数**，再摆位。别让模型"看着差不多"。
3. 舱室类（墙/地/顶/舷窗框）是**内壁** → 模型法线必须朝内，或材质开 `cull_mode = disabled`，否则从内部看是透明的。
4. 敌人 / 炮塔不在白盒 `.tscn` 里，是 `EnemySystem` / `TurretSystem` 运行时生成 → 模型挂到各自的 spawn 逻辑，替换当前的占位 Mesh（敌人现在是 6 m 彩色方块 Marker）。
5. 监控屏的**屏面仍是代码控制的 `ViewportTexture`**（4 路 feed），外部模型只提供屏幕外框，不要把屏面做成死贴图。

---

## ① 舱室结构（白盒 BoxMesh → 真实模型）· 优先级 ★★★

> 不直接阻塞战斗，但决定第一印象与「单面舷窗」的压迫感。一次换一类（第 09 课）。

| [ ] | 子项 | 白盒对应节点 | 尺度约束 | Sketchfab 关键词 | Hunyuan3D 提示词 |
|-----|------|-------------|---------|----------------|-----------------|
| ☐ | 舱壁套件（6 面实心，仅前开窗）| WallBack / WallLeft / WallRight / WallFrontFill×4 | 净空 **6.0(进深)×5.0(宽)×3.0(高)** m | `sci-fi spaceship interior wall modular panel` | `sci-fi spaceship interior wall panel, industrial metallic, with pipes and ribs` |
| ☐ | 地板 | Floor | 6.0×5.0 m | `sci-fi floor grating panel metal` | `spaceship metal floor panel with grid, industrial` |
| ☐ | 天花板（带横梁+顶灯）| Ceiling | 6.0×5.0 m | `spaceship ceiling beam light strip` | `spaceship ceiling with beams and recessed lights` |
| ☐ | 舷窗框 + 玻璃 | FrameBottom/Top/Left/Right | 窗 **宽4.4×高1.3** m，窗台高 **0.95** m | `sci-fi spaceship viewport window frame porthole` | `large rectangular spaceship viewport frame, thick metal, transparent glass` |

> 注：玻璃用半透明材质，窗外是 shader 程序生成的星空（bible §一，不替换）。舷窗框是「只有一面窗」的物理证据，建模时别手滑做成整圈玻璃。

## ② 控制台与监控屏 · 优先级 ★★★

| [ ] | 子项 | 白盒对应 | 尺度约束 | Sketchfab 关键词 | Hunyuan3D 提示词 |
|-----|------|---------|---------|----------------|-----------------|
| ☐ | 弧形舰长控制台主体 | Console（2.6×0.6×0.5 box）| 台面高约 **0.95** m，玩家眼高 1.60 | `sci-fi captain command console curved` | `spaceship cockpit command console, curved, control panels` |
| ☐ | 监控屏外框（4 块屏的嵌入式边框）| MonitorPanel | 单块屏 **0.5×0.375** m，共 4 块，距眼 0.9–1.2 m，下倾 25–35° | `sci-fi multi monitor bezel array` | `four-panel sci-fi screen frame, embedded, bezel` |
| ☐ | 舰长座椅 | 白盒无（新增）| 坐高 ~0.5 m | `sci-fi pilot captain chair` | `spaceship captain seat, sci-fi, bucket chair` |

> 注：4 块屏的**画面**由代码渲染（SubViewport feed），模型只要外框 + 屏面凹槽，屏面材质仍接 `ViewportTexture`。

## ③ 敌人（三类）· 优先级 ★★★

> 当前占位 = 6 m 彩色发光方块（Markers）。导入后按真实尺寸锚定，否则破坏进场可见度（DEC-025 约束④）。

| [ ] | 型号 | ID | 真实尺寸 | 飞行方式 | Sketchfab 关键词 | Hunyuan3D 提示词 |
|-----|------|----|---------|---------|----------------|-----------------|
| ☐ | 小型战机 | `enemy_interceptor` | **6 m** | `orbit`（绕飞，难打）| `sci-fi fighter drone small sleek` | `small sleek sci-fi starfighter, agile, 6 meters` |
| ☐ | 中型轰炸机 | `enemy_bomber` | **14 m** | `strike_retreat`（来回冲）| `sci-fi bomber spacecraft bulky` | `bulky sci-fi bomber ship, menacing, 14 meters` |
| ☐ | 重甲单位 | `enemy_heavy` | **20 m** | `hold`（P1，停住磨）| `sci-fi heavy armored warship` | `massive armored sci-fi warship, 20 meters` |

> 注：三类共用同一条进场段（直线飞来），差别只在 `flight`。模型要把"绕飞/冲锋"的姿态感做出来——小型要流线、重型要厚重。

## ④ 炮塔 · 优先级 ★★

| [ ] | 子项 | 位置 | 尺度/行为 | Sketchfab 关键词 | Hunyuan3D 提示词 |
|-----|------|------|----------|----------------|-----------------|
| ☐ | 主炮（固定正面，多管可叠）| `fore` | **不转塔**，只打前；耐久 150–250 | `sci-fi capital ship cannon fixed` | `big fixed sci-fi naval cannon, multiple barrels` |
| ☐ | 副炮（四向可多门）| port/starboard/dorsal/ventral | 可转，耐久 60–100/门；间距 18–26 m | `sci-fi point defense turret rotatable` | `small rotatable sci-fi autocannon turret` |

> 注：**6 种炮塔类型**（速射/重炮/散射/对空/对重甲/范围，见 `02_entities.md §三`）建议**先不每种单独建模** —— 共用基础副炮模型，靠换色 / 换管数 / 换枪口区分（`TurretSystem.swap_turret()` 已支持换外观）。等资产量上来再补专属模型。

## ⑤ VFX（弹道/爆炸/命中/换装）· 优先级 ★★

> 多数 VFX **不需要外部模型**，用 Godot `GPUParticles3D` + 简单 mesh 即可（Hunyuan3D 不擅长生成"特效"）。

| [ ] | 子项 | 做法 | 备注 |
|-----|------|------|------|
| ☐ | 主炮/副炮弹丸 | 细长胶囊 mesh + 自发光，或粒子拖尾 | 弹速 150–400 m/s，肉眼可见弹道（DEC-034）|
| ☐ | 命中火花 | `GPUParticles3D` 火花 | 接 `feel.flash_*` 事件表 |
| ☐ | 爆炸 | `GPUParticles3D` 爆炸 | 敌人被摧毁时 |
| ☐ | 换装特效（改装阶段 B）| 冲击环 ring mesh + 缩放/淡出 | 旧炮消失 / 新炮弹出；阶段 B 才需要，不阻塞 |

---

## 不替换项（已在引擎内）

- 星空背景：shader 程序生成（bible §一，不找外部 HDRI）。
- 监控 4 路 feed 画面：SubViewport 实时渲染，不是贴图。
- 音频：占位音由 `AudioManager` 现场合成（`audio.json` 的 `tone`），不在此清单。

## 推荐素材源（CC0 优先）

| 源 | 授权 | 适合 |
|----|------|------|
| Kenney Sci-Fi Kit | CC0 | 舱室面板 / 控制台 / UI 件（套件化，最快上手）|
| Quaternius | CC0 | 低模太空船 / 角色 |
| Poly Haven | CC0 | 材质 / 纹理（贴在找来的模型上提质感）|
| Sketchfab（筛选 CC0/CC-BY）| 逐个确认 | 更精细的单物体（敌人/炮塔）|
| Hunyuan3D | 查条款 | 单物体文生 3D（舱室面板/控制台/敌人）|
