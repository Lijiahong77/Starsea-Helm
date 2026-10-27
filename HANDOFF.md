# 星海舵手 · Starsea Helm — 开发交接文档

> **本文档用途**：供 Hermes Agent（或其他 AI / 开发者）接替本项目后续开发时，用最短时间理解现状、定位关键文件、安全地继续推进。
> **最后更新**：2026-10-27（基于工程实况 + `docs/` / `.workbuddy/memory/` 一手材料整理；并清理了旧的 `.workbuddy/HANDOFF.md` 会话短卡，后续交接统一以本文档为准）。

---

## 0. 一页速览（TL;DR）

| 项 | 内容 |
|---|---|
| **项目** | Starsea Helm（星海舵手）—— 第一人称太空舰桥据点防守 + 波次生存 |
| **引擎** | Godot 4.7（标准版，非 .NET）· Forward+ 渲染器（Vulkan） |
| **一句话** | 你坐在舰桥当舰长，只有艏部**一面舷窗**能直接看到外面；其余方向靠控制台上 4 路副炮实时画面判断；波次间改装炮塔应对下一波 |
| **核心循环** | 装配(REFIT) → 战斗(BATTLE) → 调整装配 → 战斗，单位 = **危机**（不是"一局"） |
| **玩家动词** | 只有 3 个：**装配 / 接管 / 扫视**（没出现的一律砍） |
| **进度** | P0 阶段收尾中：BACKLOG ①-⑧ + ⑨a/⑨b/⑩ ✅；余 ⑪ 的 ⑥VFX + ①hitstop；⑥ 监控接真副炮冻结（等美术模型） |
| **代码量** | 35 个 `.gd`（约 10,400 行）+ 14 个 `.tscn` + 6 份 `data/*.json` |
| **测试** | 11 套 headless 测试场景，最近全量记录 **439 条断言全绿**（断言数随每次改动浮动，勿背定值） |
| **仓库** | 公开 `github.com/Lijiahong77/Starsea-Helm`，main 分支，License = All Rights Reserved + 禁 AI 训练 |
| **头号待办** | **美术资产方案**（李主导，替换顺序：舱室 → 控制台 → 敌人 → 炮塔 → VFX） |
| **工程路径** | `D:\GameProject\Starsea Helm`（⚠ 含空格） |

---

## 1. 项目背景与总体目标

### 1.1 这是什么游戏

一款 Godot 4 的 3D 第一人称太空舰桥游戏。你**不开船、不跑图**，坐在舰桥里当舰长，用一个核心循环打完一整局。

- **品类**：舰桥据点防守 + 波次生存（**不是塔防、不是 FPS**）。
- **循环单位**：危机（一波来袭 + 一次休整）；失败或想重来时**退回装配界面重打同一艘船，不换船**。
- **没有货币、没有商店**：新炮型和新槽位随危机进度**自动解锁**（DEC-033）。
- **资源 = 战损**：上一波哪一面被打烂了，决定了这一波怎么装配。

### 1.2 三件让这个项目不一样的事

1. **微创新：只有艏部一面舷窗。** 信息不对称不是靠 UI 限制做出来的，是**物理保证**的 —— 转头只能看到墙。控制台常驻 4 路副炮实时画面（低清低帧），放在下视野余光里。
2. **失败模式不是"玩家不动手"，是"决策无意义"。** 战斗刻意低 APM，挂机感是**设计目标**。硬判据：认真装配 vs 随机装配，存活危机数差 **≥ 3**，差不到就是设计坏了（DEC-021）。
3. **无货币 / 自动解锁。** 成长不是攒钱，是解锁 + 扩展槽位。

### 1.3 三条最高宪法（全项目不可违反）

1. **70% 乐趣在装配阶段，30% 在战斗阶段。** 战斗刻意低 APM，"挂机感"是目标不是缺陷。真正的失败模式是「决策无意义」，不是「玩家不动手」。
2. **知识库（`docs/开发指导/`）只给流程不给答案。** 三问法、Bible、P0-P3、一次只改一件事必须照做；其中的弹珠肉鸽 / Vampire Survivors / Brotato 等**只是教学示例，不照抄**（DEC-023）。
3. **数值只给旋钮不给终值。** 一律外置 `data/*.json`，禁止 hardcode 到脚本。

### 1.4 里程碑口径（见 `docs/MVP_SCOPE.md`）

| 里程碑 | 回答的问题 | 本项目验收标准 |
|---|---|---|
| **Prototype** | 技术做得出来吗 | 白盒主控室 + 单舷窗 + 六扇区敌人 + 主炮/副炮开火 + 炮塔耐久 + 全毁失败 + 监控能用 + 帧率 ≥55 |
| **MVP** | 核心循环好玩吗 | 完整闭环 + "朋友玩 3 分钟还想再玩" + 五条验证指标达标 |
| **Vertical Slice** | 玩家买账吗 | 前 N 危机达到最终美术音效品质 |

---

## 2. 当前开发进度与已完成功能

### 2.1 BACKLOG 12 步进度

> 编号以 `docs/BACKLOG.md` 的"开发顺序表"为准；代码侧测试场景命名沿旧序号，别混淆。

| 步 | 内容 | 状态 |
|---|---|---|
| ① | 工程 + 白盒舰桥（单面舷窗）+ 第一人称转头 | ✅ |
| ② | EventBus / GameStateManager 骨架 | ✅ |
| ③ | 六扇区 + 敌人生成与移动 | ✅ |
| ④ | 炮塔开火（主炮固定 + 副炮 + 接管切视角） | ✅ |
| ⑤ | 炮塔耐久 + 被毁 + 全毁 = 失败 + 结算 | ✅ |
| ⑥ | 监控接真副炮视角 | ⏸ **冻结**（等美术模型定尺寸，DEC-038） |
| — | 波次调度（原缺编号） | ✅ |
| ⑦ | 改装阶段（换炮塔 / 扩展槽位） | ✅ |
| ⑧ | 自动解锁（随危机进度） | ✅ |
| ⑨a | 战损报告（一套数据、四个出口） | ✅ |
| ⑨b | 陷落演出三级分层 | ✅ |
| ⑩ | 音频骨架 | ✅ |
| ⑪ | Game Feel 五层 + VFX | 🟡 **②③④⑤ 完成，余 ⑥VFX + ①hitstop** |

### 2.2 已完成功能清单（P0 全貌）

- **白盒舰桥 + 单面舷窗**（DEC-026 物理保证信息不对称）
- **六扇区与威胁计算**（fore/aft/port/starboard/dorsal/ventral；aft、ventral 无炮无威胁，DEC-036/052）
- **主炮固定正面 + 三向副炮**（port/starboard/dorsal，底部无炮 DEC-052）
- **炮塔双模**：自动（间歇发射 + 系统锁敌 + 系统算提前量）/ 手动（接管，玩家自瞄）
- **炮塔耐久 + 每波满血复位 + 全毁 = 本局失败**（DEC-037，无 Hull）
- **波次调度与难度曲线**（无时间限制，`waves.json`）
- **监控 feed**（4 路 SubViewport 低清低帧实时画面）
- **改造阶段**（维修站过场 + 真换装，DEC-041）
- **自动解锁**（随危机进度，DEC-042）
- **战损报告**（一套数据四出口，DEC-043/044）
- **陷落演出三级分层**（L1 计数 / L2 红叉 / L3 终局夺镜，DEC-045）
- **音频骨架**（4 总线 + 16 音效 + 3 BGM + 听觉 HUD + 零素材合成占位音，DEC-046）
- **Game Feel 第一层**（②闪白 ③震屏 ④推镜 ⑤血量反馈 B+C，DEC-047/048）
- **敌人飞行数据驱动**（hold / orbit / strike_retreat，DEC-049）

### 2.3 已登记但**未实现**的设计（等真船体）

- **DEC-050** 副炮接管 = 关节骨架（MountPoint → YawPivot → PitchPivot）+ 射界半球 + 后上越肩相机
- **DEC-051** 主炮接管 = 可转 + 舷窗视角内开火 + 准星即炮口（**修订了 DEC-030 的"主炮固定永不移动"**）

> 这俩是"**只登记不实现**"：真船体一改，法线和炮位可能全变，白盒搭的骨架会返工。落地顺序见 §7。

---

## 3. 技术架构与目录结构

### 3.1 架构原则（三条，不可违反）

1. **事件解耦**：模块之间不直接调用，一律通过 `EventBus` 发信号（**音频高频音是唯一明确例外，见 §8.4**）。
2. **全局状态中枢**：`ShipSystem`（实际由 `TurretSystem` 承担飞船炮塔/槽位/装配/解锁状态）是唯一真相源，其他模块只读它、只发事件。
3. **无循环依赖**：依赖方向只允许「autoload → 业务系统 → 事件」，业务系统之间不互相依赖。

```
        ┌─────────────────────────────────┐
        │  autoload 层（全局单例）          │
        │  EventBus / GameStateManager /   │
        │  AudioManager                    │
        └────────────┬────────────────────┘
                     │ 信号广播
   ┌─────────────────┼─────────────────────────┐
   ▼                 ▼                         ▼
ShipSystem      TurretSystem           EnemySystem
(状态中枢)      (所有炮塔开火/接管)     (生成/移动/攻击炮塔)
   ▲           WaveSystem                MonitorSystem
   │           RefitSystem              PlayerController
   └──────── 只发事件，不互相调用 ──────────┘
                UISystem / VFXSystem
```

> 注：`ShipSystem`/`MonitorSystem`/`UISystem`/`VFXSystem` 目前**没有独立脚本**——职责分别由 `TurretSystem`、`bridge_whitebox.gd`、`refit_overlay.gd`+`target_health_bar.gd`、`game_feel.gd`（部分）承担。白盒阶段未做完整器物化。

### 3.2 目录结构（实际）

```
Starsea Helm/
├── project.godot               ← 主场景 + 3 个 autoload + 5 个物理层命名
├── HANDOFF.md                  ← 本文件
├── README.md                   ← 面向外部的"这个项目是怎么做的"
├── LICENSE                     ← All Rights Reserved + 禁 AI 训练
├── .gitignore / .gitattributes
├── docs/                       ← Bible（设计唯一权威）
│   ├── SPEC.md  MODULES.md  EXPERIENCE.md  EVALUATION.md
│   ├── MVP_SCOPE.md  BACKLOG.md  PROCESS.md  BRIDGE_BLOCKOUT_BRIEF.md
│   ├── ASSET_WISHLIST.md  prototype_prompt.md
│   ├── bible/                  ← 分片式详情：01_core_loop / 02_entities / 03_rules /
│   │                           ←   04_presentation / 99_decisions / _index
│   ├── 开发指导/                ← 13 课方法论知识库（只学流程，不抄案例）
│   ├── art/                    ← 美术提示词 + 3D 导入导出规范
│   ├── tools/                  ← Blender 顶点合并工具 + glb 探针
│   └── media/                  ← hero.png 概念图
├── scenes/
│   ├── bridge/bridge_whitebox.tscn   ← 主场景
│   └── tests/                        ← 12 个测试场景 + Main.tscn
├── scripts/
│   ├── core/        ← autoload：EventBus / GameStateManager / AudioManager
│   ├── bridge/      ← bridge_whitebox.gd（主场景，职责最重）
│   ├── systems/     ← 业务系统（10 个）
│   ├── ui/          ← 2 个（refit_overlay / target_health_bar）
│   ├── utils/       ← 静态工具类（4 个，非 autoload）
│   └── tests/       ← 15 个 headless 探针脚本
├── data/                       ← 6 份外置 JSON（数值唯一真源）
├── assets/                     ← 美术资源（当前基本空；models/ 有未入库的 115MB 模型）
└── .workbuddy/                 ← AI 协作记忆（逐日日志 / 分册 / 决策链）
    └── memory/                 ← 热区索引 + 冷区分册 + 逐日日志
```

### 3.3 `data/` 六份 JSON（各管一层，勿跨层写）

| 文件 | 职责 | 关键内容 |
|---|---|---|
| `presentation.json` | 呈现与手感 | 渲染 / 相机 / 舰桥 / 监控形态 / **feel 段** / healthbar / collapse |
| `enemies.json` | 敌人 | 速度 / 血量 / dps / **飞行方式 `flight_<type>`** / 扇区权重 |
| `turrets.json` | 炮塔 | 主炮 + 副炮模板 + **variants（3 种改装型号）** + 槽位 + 开火音 id |
| `waves.json` | 波次 | 首波数量 / 成长 / bomber 掺入节奏 |
| `refit.json` | 改装过场 | 维修师台词 / 时序 / 解锁播报 / 战损文案 |
| `audio.json` | 音频 | 4 总线 / 音效 / BGM / 听觉 HUD / 防爆阈值 / 3D 参数 |

> **宪法第 3 条**：这些 JSON 是数值唯一真源。改手感、改难度、改音效**不碰代码**。每个 JSON 顶部都有 `_doc*` 注释解释字段，读文件先看注释。

---

## 4. 核心模块与关键文件说明

### 4.1 autoload 层（`scripts/core/`）

> 注册顺序（project.godot）：`EventBus` → `GameStateManager` → `AudioManager`（**顺序不能乱**，后者 `_ready` 里 connect 前者的信号）。

| 模块 | 文件 | 职责 |
|---|---|---|
| **EventBus** | `EventBus.gd` | 全局事件总线，纯信号声明、零业务逻辑。事件命名 `domain:past_tense_event`（全小写下划线）。**逐 signal 有 `@warning_ignore("unused_signal")`，一旦有订阅方即可删掉那行**。 |
| **GameStateManager** | `GameStateManager.gd` | 阶段状态机 `MENU / REFIT / BATTLE / RESULT`。非法转移只 `warn` 不崩。提供 `state_name()` 公开读法，别让外部碰私有 `_STATE_NAMES`。 |
| **AudioManager** | `AudioManager.gd` | 4 总线（Master→Music/SFX/UI）+ 音效播放 + 听觉 HUD + 高频防爆（同帧去重 + 时间窗限流 + 播放器池）+ BGM 交叉淡化。缺素材时按 `tone` 段现场合成占位音。 |

### 4.2 业务系统层（`scripts/systems/`）

| 模块 | 文件 | 职责（关键点） |
|---|---|---|
| **Turret** | `turret.gd` | 单门炮实体：自动/手动双模、开火、耐久、`take_damage`、命中闪白、`turret_critical` 阈值判断 |
| **TurretSystem** | `turret_system.gd` | 所有炮塔的开火/接管/耐久/换装/解锁；`DamageLog` 挂在它下面；**`focus`（看）与 `takeover`（打）双状态分离**（DEC-048） |
| **Enemy** | `enemy.gd` | 单敌实体：`_step_flight` 分发飞行方式（hold/orbit/strike_retreat）、`is_engaged()`（可锁定）vs `is_hovering()`（是否静止）、`velocity()`（采样真速度） |
| **EnemySystem** | `enemy_system.gd` | 生成、`_flight_for` 校验（未知值 warn+退回 hold）、扇区归属、攻击最近炮塔 |
| **Projectile** | `projectile.gd` | 弹丸：线段（上一帧→当前帧）与敌人球最短距离判定（防隧道效应） |
| **WaveSystem** | `wave_system.gd` | 波次调度、难度曲线、六扇区来袭分布 |
| **DamageLog** | `damage_log.gd` | ⑨a 战损：按"本波"累计每门炮承伤、伤害来源按敌类分解、扇区汇总 |
| **CollapseSequence** | `collapse_sequence.gd` | ⑨b 陷落编排：L1/L2/L3，只做编排不做特效 |
| **GameFeel** | `game_feel.gd` | 相机震屏 + 推镜，按 `feel.events` 事件→强度表分发，只写 `Camera3D.position` 局部偏移 + `fov` |
| **RefitSequence** | `refit_sequence.gd` | 维修站过场的阶段机（黑屏→对话→改装台→出发） |

### 4.3 UI / 工具 / 桥接层

| 模块 | 文件 | 职责 |
|---|---|---|
| **bridge_whitebox** | `scripts/bridge/bridge_whitebox.gd` | **主场景脚本，职责最重**：第一人称相机、输入（数字键 1-5 切视角 / 右键接管 / ESC 三级）、监控 feed 构建与绑定、HUD、L3 终局、调试键 |
| **RefitOverlay** | `scripts/ui/refit_overlay.gd` | 改装界面 UI 哑层 |
| **TargetHealthBar** | `scripts/ui/target_health_bar.gd` | ⑪⑤ B 层：接管时屏幕上方"当前目标"血条 |
| **Sectors** | `scripts/utils/sectors.gd` | 扇区定义 + `sector_of()`；**`AXES` 是坐标系统权威（fore=+Z）** |
| **LeadPrediction** | `scripts/utils/lead_prediction.gd` | 提前量计算（主炮手动瞄准 / 副炮自动开火共用） |
| **FeelKit** | `scripts/utils/feel_kit.gd` | 手感参数只读访问器（静态类，刻意不做 autoload） |
| **HealthKit** | `scripts/utils/health_kit.gd` | ⑪⑤ 血条参数只读访问器 + `reload()` 免重启 |

### 4.4 关键文件入口速查（README「文档导航」扩展）

| 想知道 | 读这个 |
|---|---|
| 游戏是什么/不是什么 | `docs/SPEC.md` → `docs/bible/01_core_loop.md` |
| 为什么这么设计（决策链） | `docs/bible/99_decisions.md`（DEC 编号，含"被推翻的条件"） |
| 模块与事件契约 | `docs/MODULES.md` §一/§三 |
| 可调数值旋钮 | `docs/bible/03_rules.md` + 对应 `data/*.json` |
| 呈现/尺度/相机/监控 | `docs/bible/04_presentation.md` |
| 下一步该做什么 | `docs/PROCESS.md` §一/§七 |
| AI 逐日记录 | `.workbuddy/memory/history.md` |

---

## 5. 现有依赖与运行 / 构建 / 测试方式

### 5.1 依赖

- **Godot 4.7 stable**（标准版，**非 .NET**）。控制台版路径：`C:/Users/lijia/Desktop/Godot_v4.7-stable_win64.exe/Godot_v4.7-stable_win64_console.exe`
- **Godot MCP**（本地 `D:\GameProject\godot-mcp-server`，Coding-Solo/godot-mcp，HEAD 2026-04-16，**含 RCE 修复、比 npm 版新 → 勿改成 npx**）。配置在 `~/.workbuddy/mcp.json`，entry 名 `godot`。能力：launch_editor / run_project / get_debug_output 等 14 个工具。
- **Git + gh**（本机 gh 2.97.0）；Git LFS 3.7.1 已装但**尚未给仓库开启**。
- **Blender 5.2**（美术管线）+ **Python**（文件操作 / 探针 / 记忆自检）。
- 无第三方 Godot 插件、无 .NET 运行时依赖。**美术素材目前基本为空**（`assets/` 空，音频靠代码合成占位音）。

### 5.2 运行方式

```bash
# 直接打开工程（编辑器）
# 双击 project.godot，用 Godot 4.7 打开

# 命令行跑主场景（控制台版）
"$G" --path "D:/GameProject/Starsea Helm"
```

主场景 = `res://scenes/bridge/bridge_whitebox.tscn`（在 project.godot 里已配 `run/main_scene`）。

**白盒调试键**（当前可用）：`1`-`5` 切视角 · `Space`/鼠标左键 开火 · `B` 进 BATTLE · `E` 随机扇区刷敌 · `R` 全刷 fore · `F` 敌可见性诊断 · `ESC` 退接管/释放鼠标。改装台：`ESC` 跳过 · `Enter` 确认 · `0`-`9` 选型号。

### 5.3 测试方式（headless，无需美术资源）

> 完整环境坑见 `.workbuddy/memory/testing.md`，下面是必须知道的几个。

```bash
export PATH="$PATH:/usr/bin:/bin"   # ⚠ bash 缺 dirname/tail/grep/timeout，先补 PATH
G="C:/Users/lijia/Desktop/Godot_v4.7-stable_win64.exe/Godot_v4.7-stable_win64_console.exe"

# 单跑一套
/usr/bin/timeout 150 "$G" --headless --path . res://scenes/tests/feel_test.tscn 2>&1 | grep -E "断言:|结果：" | head -1

# 全套（11 套）
for s in feel_test audio_test healthbar_test turret_round2 turret_hp_test \
         enemy_test wave_test refit_test unlock_test damage_test collapse_test; do
  printf "%-16s " "$s"
  /usr/bin/timeout 150 "$G" --headless --path . res://scenes/tests/$s.tscn 2>&1 | grep -E "断言:|结果：" | head -1
done
```

**⚠ 测试环境四个已知坑（都实测过，别重踩）**：

1. `timeout` 要写全路径 `/usr/bin/timeout`（直接写会撞上 Windows 的 `TIMEOUT.EXE`，静默吞命令）。
2. 断言行格式**不统一**：`feel/audio/healthbar/refit/unlock/damage/collapse` 打 `断言: n/m 通过`；`turret_round2/turret_hp/enemy/wave` 打 `结果：通过 n / 失败 m` → grep 模式要**同时含两种**。
3. headless 主场景必刷 `texture_2d_get: Parameter "t" is null` —— dummy 渲染驱动下 `SubViewport.get_texture()` 后端 RID 为 null 的**固有限制，不是你的改动引起的**。判读输出先滤掉它，否则淹没新错误。
4. `quit()` 早于清理时 exit 报 `N ObjectDB instances were leaked` 是常态，不是内存泄漏 bug。

**新增 `class_name` 后**，headless 跑测试会报 `Could not find type`——先跑一次 `"$G" --headless --import --path .` 刷新全局类缓存，再跑测试。**别手编 `.gd.uid`**（报 invalid UID，删掉让 `--import` 生成）。

### 5.4 Git / GitHub

- 远程：`https://github.com/Lijiahong77/Starsea-Helm`（**公开**），默认分支 `main`。
- 提交身份配在 `--local`（`Li Jiahong <Lijiahong77@users.noreply.github.com>`），换机器要重配 `git config --local user.name/email`。
- `.gitignore` 是 **Godot 4.1+ 官方写法**：只忽略 `.godot/` + `*.translation`。⚠ `*.import` 与 `*.uid` **不能忽略**。
- **push 节奏**（李亲授）：本地 commit 必做（防丢），push 攒批推（素材告一段落 / 一天收工 / 里程碑时推一次）。**AI 不自动每轮 push**。
- ⚠ 本机 bash 里 `git fetch/push` 写不进 `.git/refs/remotes/origin/`（沙箱不允许建子目录）→ 症状 `## main...origin/main [gone]`。**走 Write 工具把 40 位 SHA 写进 `.git/refs/remotes/origin/main` 绕过**，只影响状态显示，push/pull 本身正常。

**⚠ 当前工作区状态（接手时先看）**：有**大量已改未提交**的文件（`git status` 里 `M` 清单很长，包括 4 个 JSON、8 个脚本、一摞 bible 文档）和未跟踪文件（`docs/art/*.md`、`docs/tools/`、`.workbuddy/memory/2026-09-1*.md`）。最近一次 commit 是 `08f7466`。**李的机器上 `git status` 是干净的，未提交改动是开发过程中累计的，接手时建议先本地 commit 一次再动工**（别裸奔在工作区）。

---

## 6. 已知问题与待办事项

### 6.1 未完成的 P0 项（优先级最高）

| 项 | 状态 | 备注 / 关键约束 |
|---|---|---|
| **⑪ ⑥ VFX** | ⬜ 未开工 | 程序化占位粒子，不依赖美术。⚠ 受预算约束：单次 ≤8 粒子 / 同屏 ≤60（`03_rules.md §六`） |
| **⑪ ① hitstop** | ⬜ 未开工 | ⚠ **禁用 `Engine.time_scale = 0`**（连带停音频/Timer/AnimationPlayer）。世界推进是集中式的 → 直接关 `EnemySystem` / `TurretSystem` 的 `_physics_process` N 毫秒 |
| **⑥ 监控接真副炮** | ⏸ 冻结 | DEC-038：等美术模型定尺寸。解冻后 feed 才拍真副炮视角（现在拍的是舷外标记） |

### 6.2 头号外部依赖：**美术资产方案**

P0 收尾后的头号重点，**李主导**（风格定稿/选型/商业谈判不在 AI 范围）。替换顺序：**舱室 → 控制台 → 敌人 → 炮塔 → VFX**。首要解锁 ⑥ 的冻结。

已查明的美术/模型隐患（2026-09-16 探针实测，接手时注意）：

- 已有 `assets/models/AISpaceship_3.glb`（未入库，~65MB）：**尺度差 57 倍**（包围盒最长边 1.12m，目标船长 64m）；**长宽比与规格冲突**（模型 64×45×20 vs 规格 64×22×16，牵动 `hull_radius=11` 这个所有炮塔挂载/扇区公式的根）；**50 万三角面**（注意舰外相机 + 4 路监控渲染预算）；材质 `doubleSided:True`（背靠背看船壳不是透明，需在 Godot Advanced Import 改 Cull Mode=Back）。
- **Git 体积**：`assets/models/` 合计 115MB，未上 LFS，每次改动翻倍进 Git 历史。

### 6.3 未决设计问题（Open Questions，来自 `99_decisions.md`）

| 编号 | 问题 | 影响 |
|---|---|---|
| **Q18** | 舷窗垂直尺寸 = 主炮上下瞄准范围（bible 现值 1.30 只给 ±20.9°，偏窄） | 与真船体外形一起定 |
| **Q9** | 是否加第 4 条 VO 音频总线 | 不阻塞 |
| **Q10** | 默认窗口 1080p 是否提到 1600×900 | Prototype 实测后 |
| **Q12** | 敌人类型化进攻（围攻/游击/集中主炮）何时加 | MVP 后 |
| **Q14** | 最后一座炮塔被毁后立即结算还是 1-2s 演出 | Prototype 实测后 |

### 6.4 已实现但待实机验证的副作用（不是 bug，是选择的代价）

1. **DEC-049 敌人飞行两个副作用**：① 绕整船一圈会**跨扇区** → 扇区压力随时间转移；② 绕飞时伤害被摊到沿途各门炮，削弱"某一门先废掉"的叙事。体感不好先调小 `orbit_speed_factor`，再考虑把 `flight_interceptor` 改回 `hold`。
2. **敌人"最近炮塔"未限扇区**：实测 fore 来袭的轰炸机可能先啃 dorsal（49.6m < 主炮 51.2m），与"主炮通常最后沦陷"预期冲突。待手感实测后裁决是否改"优先本扇区"。
3. **DEC-052 单面压力 +25%**：ventral 敌权归零后，敌人总数不变、可生成面 5→4。太挤先动 `dps_*` / `pressure_reference_count`，**别把权重改回去**。

### 6.5 已知显性 bug / 高风险点（照抄，别重犯）

- **`collapse_sequence` 改前必读 `2026-09-15.md`**：`BREACHED` 是终态，只能由 `_reset()`（开战）清。加过顺序敏感用例，别挪位置、别改成直接 emit 信号。
- **接管副炮时看不到监控面板**（相机切到舰外）→ 主炮接管不切相机，看得见（DEC-051 已复核）。
- **监控左墙 mount -2.8 离外墙 -2.7 只剩 0.1m**（与 `camera.near=0.1` 相等），建议改 ±3.0~3.2。
- **`main_gun.mount` 现值是假的** `[0,1.6,-0.6]`（z 为负 = 眼位后方的隐形占位炮），真船体到位时实体化到艏部上表面（DEC-051）。

---

## 7. 后续开发计划与优先级

> 排序依据（李定的方法论）：**「哪件事晚做代价最高」**，路线图是清单不是时刻表。

### 7.1 当前唯一动作：定美术资产方案

- **主导**：李。**AI 边界**：定方向、找候选、写对比表。
- **替换顺序**：舱室 → 控制台 → 敌人 → 炮塔 → VFX。
- **首要解锁**：⑥ 监控接真副炮（等模型定尺寸）。

### 7.2 P0 收尾（顺序可互换）

1. **⑪ ⑥ VFX**：程序化占位，不必等美术。
2. **⑪ ① hitstop**：关两个系统 `_physics_process`，禁 `time_scale=0`。

### 7.3 真船体到位后的落地顺序（一次只做一步）

**DEC-050 副炮接管**：① 骨架（节点层级）→ ② 射界夹取 → ③ 相机越肩+略宽 → ④ 自动锁敌射界过滤。
**DEC-051 主炮接管**：① 准星即相机中心（复用收敛算法）→ ② 射界夹取 → ③ 自动锁敌射界过滤 → ④ 实体化到艏部上表面。

### 7.4 阶段二（P0 全收尾后）

- 第 07 课 主视觉与短片 · 第 08 课 关卡与数值策划。

### 7.5 P1 / P2 / P3 全景（详见 `BACKLOG.md`，这里只列层级头）

- **P1**（核心乐趣才完整）：战损四出口表现优化、陷落三级演出打磨、六扇区压力可视化、免费素材替换、结算界面 + 最高危机记录、Game Feel 五层收尾。
- **P2**（更好玩）：战术指令、重甲单位、敌人护甲、进攻偏好、跨局永久解锁、存档、难度选项、波次预览、Boss 波。
- **P3**（删了不影响核心）：舰桥自由走动、剧情、多人、成就、VR、星空细节。

---

## 8. 代码规范、开发流程和交接注意事项

### 8.1 协作纪律（李亲授，务必遵守）

1. **用户审阅批准后才写代码**；未经"开工"不建 `.gd` / `.tscn`。
2. **三轮对话节奏**（李与 AI 协作的核心方法）：第一轮 AI 只复述理解 + 给方案（不写代码）；第二轮 只回答 AI 提问；第三轮 说"开始实现"→ 实现 + 自测。
3. **一次只改一件事**，改完验证通过再动下一个。
4. 复杂/高风险功能先建**独立测试场景**（`scenes/tests/` + `scripts/tests/`）跑通、性能达标，再搬进主场景。
5. 数值只给旋钮不给终值，一律外置 `data/*.json`。
6. **别替李做决定**：岔路口把候选摆好、数据摊开、代价写清，不给"我推荐哪个"。

### 8.2 代码规范

- **事件命名**：`domain:past_tense_event`，全小写下划线。事件只描述"发生了什么"，不描述"该做什么"。禁止在 EventBus 写业务判断。
- **数值外置范式**（`godot_pitfalls.md §8`）：代码里只留结构映射，坐标/距离进 JSON；看向点用"目标节点实际世界坐标"；兜底值必须推导（`目标距离×比例`）不能是坐标常量；**先摆目标、再解析配置**；结果缓存。
- **单一真源**：同一份数据只存一处。曾因参数存两处反复踩坑（呈现类归 `presentation.json`，听觉类归 `audio.json`）。
- **注释不许写易腐内容**（李亲自检查）：不写行数/日期/"重构后"这类会变假的话；文档引用补全路径+章节；改完代码回头审一遍注释。
- **为压告警加 `_` 前缀时，注释必须写明"将来给谁用"**——否则伏笔烂在代码里（已踩过：`_source_id` 挂 9 天才接上）。

### 8.3 日志纪律

- 新模块打印打开（`const DEBUG_LOG := true`），已验证的关闭（`false`），用常量开关 + `_log()` 包装，**不要逐行注释**。
- 日志只打"状态发生变化的那一刻"，**绝不每帧打**。
- 例外：调试入口（生成键）直接 `print`，不走开关。

### 8.4 事件接入口边界（两个关键例外，别当违规去纠正）

1. **低频事件走 EventBus**（炮毁/失守/终局/击杀/波次/改装落位/turret_critical）。
2. **高频音（开火/命中）业务代码直接调 `AudioManager.play_sfx()`**——每帧 emit 会刷爆总线，且调的是 autoload 服务不是跨模块调业务。
3. ⚠ **`turret_damaged` 每物理帧都在发，只能当"记账流水"（喂 DamageLog），绝不能接任何玩家反馈**（震屏/音效）——它就是"持续受击噪音"的根源。受击的离散反馈由低频 `turret_critical` 承担。

### 8.5 高频踩坑清单（改代码前扫一眼）

- **同一文件多处 Edit 必须串行发**（并发读改写，后写覆盖先写，都返回 success）。同文件串行、不同文件才并行、改完回读验证。
- **改 `.tscn` 前让李关 Godot 编辑器**，否则编辑器保存会覆盖外部改动（已复发 3 次）。
- **GDScript 语言坑**（`gdscript_snags.md`）：`dict.get()` 返回 Variant → `:=` 会报"warning treated as error"，显式写 `Variant`；typed array 别用三元赋默认值；`max()/min()/abs()` 返回 Variant 要显式声明；3D 节点没 `modulate`（用 `material_override.albedo_color`）。
- **autoload `_ready` 早于主场景**，首次广播收不到 → 主场景 `_ready` 里主动读一次补上。
- **相机朝向**：Godot 前向是 **-Z**，本项目 fore=**+Z**（`Sectors.AXES`）。给场景加相机先确认基底朝向（曾把 fore feed 相机写成回头看本舰）。
- **SubViewport 四件套**（缺一白板）：`sv.get_texture()` 绑定 + `render_target_update_mode=3` + FeedCam `current=true` + 主相机 `current=true`；另 `own_world_3d` 默认 true 要设回 `get_viewport().world_3d`；显示屏用 **QuadMesh**（BoxMesh 的 UV 是 3×2 图集）。

### 8.6 验证纪律（不许凭"我以为改了"）

1. 改完文件 → **re-read 确认落地** → **实跑确认 `errors:[]`**。
2. 测试**走真实调用路径**：伤害调 `Turret.take_damage` 而不是直接 `emit`（跳过 `source_id` 传递，坏了也是绿的）。
3. 跨阶段**必须清场**（敌人/子弹是 `call_deferred queue_free` 的，不等落地会数错尸体）。
4. **护栏有效性也要实测**：写完"输入非法→告警+兜底"后，故意把数据改错跑一次，确认告警真的打出来、断言真的变红，再恢复。
5. **被测行为一变，先问"用例前提还在不在"**：敌人会飞之后，"最近炮塔"会漂移，烧 hp 的用例要 `spawn_one(..., &"hold")` 把无关变量钉死（`flight_override` 只给测试用）。

### 8.7 交接注意事项（给 Hermes Agent 的开工清单）

1. **先读**：`docs/bible/_index.md`（入口 + Context Prelude）→ `.workbuddy/memory/MEMORY.md`（热区索引）→ `docs/PROCESS.md` §一/§七（当前位置）→ `docs/BACKLOG.md`。
2. **动代码前**：扫 `gdscript_snags.md` + `godot_pitfalls.md` + 相关分册（`game_feel` / `monitor_feed` / `testing` / `damage_collapse`）。
3. **先本地 commit 一次**当前未提交改动，避免在"裸奔"的工作区上再叠加改动。
4. **改设计必回填文档**（宪法：不写 Bible 就用不了 AI）：改了设计 → 同步 `docs/bible/` + 相关 DEC；完成一个 BACKLOG 步骤 → 只回来改 `PROCESS.md` 的 §一 与 §七 两处。
5. **改完实跑验证**：11 套 headless 测试全绿 + 主场景 0 脚本错误，才报完成。
6. **记忆落库**：完成实质工作后，往 `.workbuddy/memory/YYYY-MM-DD.md` 追加一条 3-5 行「结论+证据+指针」；新内容默认写分册、只给热区加指针；写前跑 `python .workbuddy/memory/_check.py` 看预算。
7. **遇到岔路（挑哪种/换不换/排期/范围）**：把候选与代价摆给李，**不替他做决定**。