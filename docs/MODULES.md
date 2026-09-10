# 太空舰桥 · MODULES
> 状态：WIP / 最后更新：2026-09-01（**第三轮重定位 + 监控修正**：删除 Hull / 经济 / 悬赏 / 主炮指派 / 过热，新增固定主炮 + 可接管副炮 / 监控=常驻副炮实时画面（SubViewport）+ 接管切主视角 / 自动解锁）
> 模块数已超 8 个 → 按知识库第 02 课使用分片式 Bible，见 `docs/bible/`

> ⚠️ 本文件只定义**模块边界与通信契约**，不写实现细节。
> 实现细节属于代码，按知识库第 02 课「Bible 是声明式的」原则不应写进 Bible。

---

## 架构原则（三条，不可违反）

1. **事件解耦**：模块之间**不直接调用**，一律通过 `EventBus` 发信号。
2. **全局状态中枢**：`ShipSystem` 是飞船状态（炮塔清单 / 槽位 / 装配方案 / 解锁进度 / 危机进度）的唯一真相源，其他模块只读它、只发事件。
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

---

## 一、autoload 层（Godot 项目设置里注册为自动加载）

| 模块 | 职责 | 优先级 | 说明 |
|------|------|--------|------|
| **EventBus** | 全局事件总线，所有跨模块通信的唯一通道 | P0 | 纯信号声明，无业务逻辑 |
| **GameStateManager** | 阶段状态机：`REFIT` / `BATTLE` / `RESULT` / `MENU` | P0 | 改装开关、波次切换、全部炮塔被毁的死亡结算都归它管 |
| **AudioManager** | 四条总线（`Master` → `Music` / `SFX` / `UI`）+ 音效播放 + **听觉 HUD**（按扇区改音高 / 决定 2D·3D）+ 高频防爆（同帧去重 + 时间窗限流 + 播放器池）+ BGM 交叉淡化 | P0（骨架 ✅ ⑩） | **DEC-046**。参数单一真源 `data/audio.json`；缺素材时按 `tone` 现场合成占位音（零素材可用）。接入口边界见 §三 末 |

---

## 二、业务系统层

| 模块 | 职责 | 输入 | 输出 | 优先级 |
|------|------|------|------|--------|
| **ShipSystem** | 飞船全局状态：炮塔引用与状态、槽位、已解锁炮塔类型池、当前装配方案、累计危机进度 | 模块配置、伤害事件 | 飞船状态、结算事件 | P0 |
| **TurretSystem** | **所有炮塔**的开火与接管，统一**双模**：自动 = 间歇发射弹丸（副炮约 3 s 一枪）+ 系统自动锁敌 + **系统自动算提前量**；手动 = 玩家自己瞄、按扳机发射。主炮固定正面（弹丸慢 150–250 m/s，玩家接管时**自己**算提前量）；副炮×4 向（自动锁敌，系统代算提前量）。炮塔耐久、被毁、每波满血复位 | 接管指令、开火输入、敌人数据、模块属性 | 伤害事件、炮塔状态、陷落事件 | P0 |
| **DamageLog** | ⑨a 战损记录（**挂 TurretSystem 下的子节点**）：按「本波」累计每门炮承伤、**伤害来源按敌人类型分解**、被毁标记、扇区汇总。**四个出口（HUD / 维修站 / 维修师台词 / 改装台）共用这一份数据**（DEC-043） | `turret_damaged` / `turret_destroyed` | 战损查询 | P1 |
| **CollapseSequence** | ⑨b 陷落演出编排器（**挂 bridge 下的子节点**）：L1 单炮计数标记 / L2 整路红叉 / L3 夺操控 + 拉远环绕镜头 + 宣告 → RESULT。**只做编排**，爆炸归 ⑪、警报归 ⑩；表现层对节点缺失容错（headless 可测纯逻辑） | `turret_destroyed` / `sector_breached` / `all_turrets_destroyed` | 屏幕标记、终局镜头、RESULT 转移 | P1 |
| **GameFeel** | ⑪ 相机手感编排器（**挂 bridge 下的子节点**）：震屏（③）+ 推镜（④），按 `feel.events` 的**事件→强度表**分发。**只写 `Camera3D.position`（局部偏移）与 `fov`** —— `Player.position` 归 bridge、材质归实体，三方零重叠。L3 期间靠兄弟节点 `is_locked()` 自我静音。**空转不跑 `_process`** | `turret_fired` / `enemy_killed` / `turret_damaged` / `turret_destroyed` / `sector_breached` / `game_state_changed` | 相机偏移、视场角 | P1 ✅ 第一层（DEC-047） |
| **FeelKit** | ⑪ 手感参数的**只读访问器**（非模块，`utils/` 静态类）：从 `presentation.json` 的 `feel` 段取值并缓存，供系统层与实体层共读。**刻意不做成 autoload**（少一个就少一个顺序坑） | —— | 旋钮值 | P1 ✅（DEC-047） |
| **EnemySystem** | 敌人生成、移动、扇区归属、攻击**最近炮塔**耐久 | 波次配置 | 敌人实体、攻击伤害事件、死亡事件 | P0 |
| **WaveSystem** | 波次调度、难度曲线、六扇区来袭分布（`aft` 基本不含） | 波次数、配置表 | 波次事件、危机清空事件 | P0 |
| **MonitorSystem** | **主控室常驻 4 路副炮实时画面（SubViewport feed，低清低帧）+ 接管时主相机切到该副炮**；可选 2D 雷达总览。feed 平面**可点击**发起接管 | 玩家操作、敌人数据、炮塔状态 | 4 路 feed 画面、扇区压力呈现、feed 点击事件 | P0 |
| **PlayerController** | 第一人称视角；**接管**某炮塔切手动（**双输入**：点控制台 feed 平面，**或**按数字键 1–5；**ESC 回主控室**）；手动模式下按鼠标左键开火。**同时只接管一门** | 鼠标键盘输入 | 视角切换事件、接管指令、开火输入（不直接操作武器） | P0 |
| **RefitSystem** | 改装流程：换炮塔类型 / 扩展槽位 / 预判下一波；自动解锁由危机进度驱动 | 已解锁类型池、玩家操作 | 飞船配置变更、进入战斗 | P0 |
| **UISystem** | HUD、监控 UI、改装界面、结算界面 | 玩家操作、飞船状态 | 界面交互、配置变更 | P0 |
| **VFXSystem** | 射击、爆炸、命中反馈、屏幕特效 | 射击 / 伤害事件 | 视觉特效 | P1 🟡（**DEC-043 归入 ⑪**）：**命中闪白已落地**（②，见 `game_feel.gd` + 实体自己；DEC-047），炮口火光 / 命中火花 / 爆炸粒子待做 |

> **已删除模块**：`ShieldSystem`（护盾随无 Hull 自然消解，Q1）、`EconomySystem`（残骸/悬赏经济已删 DEC-033）、`UnlockSystem`（自动解锁并入 ShipSystem + RefitSystem，DEC-033）、`ItemSystem`（战术指令原型期不做，DEC-035）。
> **已更名**：`DefenseSystem` → `TurretSystem`（职责从「六扇区+五防御点」收敛为「所有炮塔的开火/耐久/接管」，失败条件已改为「全部炮塔被毁」，见 DEC-031/037）。
> **搁置**：`TacticalOrderSystem`（战术指令 / 主动技能整体 Prototype 不做，DEC-035，MVP 验证后视情况加）。

---

## 三、事件命名规范（让 EventBus 真正落地）

格式：**`domain:past_tense_event`**，全小写下划线。

```gdscript
# EventBus.gd —— 只声明信号，不写逻辑

# ── 飞船 / 炮塔 ──────────────────────────
signal turret_damaged(turret_id: StringName, amount: float, source_id: StringName)   # ⑨a 加 source_id（2026-09-10）
signal turret_destroyed(turret_id: StringName, sector: StringName)
signal all_turrets_destroyed()                 # → GameStateManager 进入 RESULT
signal turret_takeover_started(turret_id: StringName)
signal turret_takeover_ended(turret_id: StringName)
signal sector_pressure_changed(sector: StringName, pressure: float)
signal sector_breached(sector: StringName)     # 该扇区所有炮塔被毁

# ── 敌人 / 波次 ──────────────────────────
signal enemy_spawned(enemy: Node, sector: StringName)
signal enemy_killed(enemy: Node)
signal wave_started(wave_index: int)
signal crisis_cleared(wave_index: int)        # 一波敌人清空，进入下一危机

# ── 改装 / 解锁 ──────────────────────────
signal refit_opened()
signal refit_confirmed()
signal turret_type_unlocked(type_id: StringName)   # 随危机进度自动解锁
signal turret_equipped(turret_id: StringName, slot: int)
signal turret_unequipped(turret_id: StringName, slot: int)
signal slot_count_changed(new_count: int)

# ── 监控 / 接管输入 ──────────────────────
signal monitor_feed_clicked(sector: StringName)    # 玩家点了控制台上某路 feed（原始输入）
signal monitor_view_changed(target: StringName)    # 主相机切到某副炮视角 / 回主控室
signal turret_fired(turret_id: StringName)         # 手动模式下玩家按扳机发射

# ── 流程 ────────────────────────────────
signal game_state_changed(new_state: StringName)
```

**规则**：
- 事件只描述「发生了什么」，不描述「该做什么」
- 一个事件可被多个系统订阅（**DEC-043 扇出蓝图**，陷落三级分层；⑨b/⑩/⑪ 已分别由 `CollapseSequence` / `AudioManager` / `GameFeel` 落地）：
  - `turret_damaged` → **DamageLog** 累计（战损数据汇总，**供 ①/②/③/④ 四出口消费**）/ **GameFeel** 轻震 + 实体自身闪白
  - `turret_destroyed`（L1）→ **CollapseSequence** 屏幕「存活/已装」计数标记 + 黄染色脉冲 / **AudioManager** 单炮被毁音（按扇区变调）/ **GameFeel** 重震 / VFXSystem 爆炸（⑪ 待做）/ DamageLog 记毁
  - `sector_breached`（L2）→ **CollapseSequence** 屏幕整路红 + 红叉 / **AudioManager** 失守警报 / **GameFeel** 重震 / DamageLog 标该面失守
  - `all_turrets_destroyed`（L3）→ **CollapseSequence** 夺操控 + 拉远环绕镜头 + 宣告 → RESULT / **AudioManager** 终局音（**GameFeel 此时让位**）
  - `turret_fired`（玩家按键）→ **GameFeel** 推镜 + 轻震 / **AudioManager** 开火音
  - `wave_started` / `crisis_cleared` / `enemy_killed` / `turret_equipped` → **AudioManager** 对应警报与装配音（`enemy_killed` 同时给 GameFeel 轻震）
- **禁止**在 EventBus 里写任何业务判断

**手感的接入口**（**DEC-047**）：`GameFeel` 订阅上表里的 5 个**低频**事件；
闪白**不走事件总线** —— 材质属于实体自己，`Enemy.take_damage` / `Turret.take_damage` 直接就地改自己的材质，
两者共用 `FeelKit` 读同一组旋钮。强度按 `presentation.json` 的 `feel.events` 事件→强度表分发，
**改手感只改 JSON、不碰业务脚本**。

**音频的接入口边界**（**DEC-046 决定 2**，是对上面第 1 条原则的明确例外，别当成违规）：
- **低频事件**（`turret_destroyed` / `sector_breached` / `all_turrets_destroyed` / `enemy_killed` /
  `wave_started` / `crisis_cleared` / `turret_equipped`）→ `AudioManager` 自行订阅。
  **接线目标是 `data/audio.json` 的 `events` 段**，换警报音只改 JSON、不碰业务脚本。
- **高频音**（开火 / 弹丸命中 / 炮塔持续受创，每帧级）→ 业务代码**直接调** `AudioManager.play_sfx()`。
  理由：每帧 emit 会刷爆总线，而 EventBus 的语义是「状态翻转」不是「连续量」；
  且调的是 **autoload 服务**，不是跨模块调业务逻辑。

> ⚠ `EventBus.gd` 里逐 signal 的 `@warning_ignore("unused_signal")`：**该 signal 一旦有了订阅方即可删掉那行**（⑩ 已实测确认，删掉不产生告警）。⑩ 清理了 9 行陈旧的 ignore。

---

## 四、VR 预留（只保留一条）

| 做法 | 状态 | 理由 |
|------|------|------|
| 输入层与逻辑层分离（`take_over_turret()`、`switch_monitor_view()` 等接口封装，不直接绑鼠标键） | ✅ **保留** | 成本近零，且真的有用 |
| 主控室按钮做成 3D 物理可交互物体 | ❌ **砍掉** | 非 VR 下鼠标点 3D 物体精度低、hover 难做 |
| UI 渲染在 3D 平面而非 Overlay | ❌ **砍掉** | 同上。真做 VR 时再重构，成本远低于现在预支 |

Non-goals 已明确「不做 VR 实装」，为一个不做的目标预支成本是过早优化。

---

## 五、目录结构约定

```
Starsea Helm/
├── project.godot
├── .gitignore
├── docs/                    ← Bible，AI 会话的唯一入口
│   ├── SPEC.md  MODULES.md  EXPERIENCE.md  EVALUATION.md
│   ├── MVP_SCOPE.md  BACKLOG.md  PROCESS.md
│   ├── bible/               ← 分片式详情（见 _index.md）
│   └── 开发指导/             ← 13 课方法论知识库（**只学流程，不抄案例**）
├── scenes/
│   ├── bridge/              ← 主控室、监控视角锚点、舷窗
│   ├── enemies/
│   ├── weapons/             ← 主炮 + 四向副炮
│   └── ui/
├── scripts/
│   ├── core/                ← autoload：EventBus / GameStateManager / AudioManager
│   ├── systems/             ← 业务系统
│   ├── ui/
│   └── utils/              ← LeadPrediction / Sectors / FeelKit 等共享工具（静态类，非 autoload）
├── assets/
│   ├── models/  textures/  audio/  ui/     ← audio/ 目前为空：缺素材时代码合成占位音（DEC-046）
└── data/                    ← JSON 配置。知识库铁律：不 hardcode，数值全部外置
    ├── enemies.json
    ├── waves.json
    ├── turrets.json         ← 炮塔类型 / 耐久 / 自动&手动 DPS / 弹丸 / 开火音 id
    ├── presentation.json    ← 渲染 / 尺度 / 相机 / 监控形态 / **手感旋钮（feel 段，DEC-047）**（**不含音频**，见下）
    ├── audio.json           ← 总线 / 音效 / BGM / 听觉 HUD / 防爆阈值 / 3D 音频参数（DEC-046）
    └── balance.json         ← 波次成长 / 解锁节奏 / 性能预算
```
