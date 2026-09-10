# 手感专册（Game Feel · 冷区 · 按需读）
> 触发时机：**动 `GameFeel` / 调手感 / 给某个玩法事件加反馈之前**扫一遍。
> 全部为 2026-09-10 ⑪ 第一层实测，非二手知识。格式「现象 → 根因 → 修法」。预算 6000 字符。

---

## 0. 哪里有真源（改任何一处前先认清）

| 要改什么 | 去哪 | 别碰 |
|----------|------|------|
| 震屏时长 / 偏移上限 / 抖动频率 | `data/presentation.json` 的 `feel.shake_*` | 代码 |
| 推镜两段时长 | `feel.zoom_in_time` / `zoom_out_time` | 代码 |
| 闪白时长 / 颜色 | `feel.flash_time` / `flash_color` | 代码 |
| **哪个事件给多强的反馈** | `feel.events`（`shake` 单位 m、`zoom` 单位度） | 代码 |
| 全局静音总闸 | `feel.master_scale`（0 = 全静默，排查用） | 代码 |
| 震屏/推镜算法与状态机 | `scripts/systems/game_feel.gd` | JSON |
| 闪白状态机 | `enemy.gd` / `turret.gd` 的 `_hit_flash` / `_tick_flash` | JSON |
| **⑤ 血量反馈旋钮** | `presentation.json` 的 **`healthbar` 段**，经 `HealthKit` | 代码；细则见 **`healthbar.md`** |

手感旋钮全在 `presentation.json` 的 `feel` 段；⑤ 另开同文件的 `healthbar` 段
（消费者不同，混一段会让「调手感」和「调 HUD」互相干扰）。
**不要新开 `feel.json` / `healthbar.json`** —— 同类参数存两处，⑩ 刚为这毛病迁过一次 audio 段。
读取一律经静态访问器 `feel_kit.gd`（`FeelKit`）/ `health_kit.gd`（`HealthKit`），懒加载 + 缓存 + 缺键 warn。

---

## 1. 三层归属：谁写哪个属性（**零重叠**是设计，不是巧合）

| 谁 | 写 | 不碰 |
|----|----|------|
| `GameFeel`（挂 bridge 子节点） | `Camera3D.position`（局部偏移）、`Camera3D.fov` | `Player.position` / `rotation` |
| `Enemy` / `Turret` | 自己 `material_override.albedo_color` | 相机 |
| `bridge_whitebox` | `Player.position` / `rotation`（接管搬移、feed 布局） | 相机局部偏移与 fov |

**收益**：接管搬的是 `Player`、震屏抖的是子节点 `Camera3D` —— 父子不同属性、同时存在不打架，
所以**「接管时要不要禁震屏」这个特殊分支根本不需要写**。

**⚠ 挂载顺序有依赖**：`bridge_whitebox._ready` 里 `CollapseSequence` 必须**先** `add_child`，
`GameFeel` 后加 —— 后者靠兄弟节点名找前者判断「L3 期间是否让位」。反过来表现为「终局环绕镜头一边转一边抖」。

---

## 2. ⚠ 抖动频率会被帧率混叠（最容易忽略的一条）

**现象**：旋钮写 26 Hz，实机是**慢悠悠的晃动**，且调得越高越像慢晃。
**根因**：正弦被逐帧采样，频率超过帧率一半（Nyquist，60fps → 30Hz）后混叠成**假频率**。
三轴再乘不同系数就有人超线。
**修法**：`shake_freq` 定在 **10–18 Hz**（本项目 14），三轴系数 1.00 / 0.83 / 1.31 → 最高轴 ≈ 18 Hz。
JSON 里写了这条注释。**通用**：任何「按 sin 生成、逐帧采样」的视觉参数都要问一句「它低于帧率一半吗」。

---

## 3. ⚠ 闪白必须有冷却，否则退化成"白盒子"

**现象（若写错）**：炮塔一挨打就**一直白着**，不再闪。
**根因**：`Turret.take_damage` 是**每物理帧**被调的（敌人持续 dps，见 `Enemy._attack_tick`），
没冷却就每帧重触发、永远停在闪白态。
**修法**：状态机三段 —— 闪白中（`_flash_on`，倒计时 `_flash_left`）→ 冷却中（`_flash_cd`，
长度 = 一个 `flash_time`）→ 空闲。连续受击自动变成**等间隔闪烁**。
敌人虽只挨离散弹丸，也用同一套机制（将来出现持续伤害来源时不会翻车）。

---

## 4. ⚠ 被毁后闪白冷却会把颜色擦回型号色

**现象**：炮被打没了（耐久归零、状态已变），颜色却变回"好的那门炮"的颜色。
**根因**：冷却到点时 `_tick_flash` 去"还原"，把被毁的暗红擦掉。
**修法**：① 被毁分支先 `_flash_on = false` / `_flash_cd = 0`；② `_tick_flash` 的还原分支加 `if not destroyed` 守卫。
**通用**：任何「临时改外观 + 定时还原」的机制，都要问「这期间对象状态翻转了怎么办」。

---

## 5. ⚠ 每波 `restore()` 要一起清闪白冷却；`restore` 里也别重设颜色

**现象**：下一波开局，这门炮挨打却不闪（别的炮在闪）—— 最难复现的那类小 bug。
**根因**：上一波残留的 `_flash_cd` 没走完，开局窗口内所有 `_hit_flash()` 被冷却挡掉。
**修法**：`Turret.restore()` 把 `_flash_on` / `_flash_left` / `_flash_cd` 一起清零，
并**只调 `_apply_alive_visual()` 恢复本色** —— 不要在 `restore()` 里再写一遍颜色常量
（本色随型号变，两处各写一份必然改一处漏一处）。

---

## 6. ⚠ 三轴叠加必须按**模长**夹上限，否则旋钮是谎言

**现象**：旋钮写"最大偏移 0.05 m"，实测峰值 0.087 m（= 0.05 × √3）。
**根因**：三轴各一正弦，`Vector3(sin, sin, sin) * amp` 的模长最大可达 `amp × √3`。
**修法**：`if off.length() > cap: off = off.normalized() * cap`。
**为什么重要**：旋钮语义是"上限"，做不到就是欺骗读者 → 旧名 `shake_amplitude`（听起来是振幅）
改成 `shake_max_offset`（明确是模长上限），见 DEC-047 决定 5。

---

## 7. ⚠ 精确归位要被断言，测试要**手动步进**

**现象（若写错）**：震完画面微微歪着回不去；或只在"某一档帧率下"看起来正常。
**修法**：`advance()` 在无活跃反馈时显式 `_restore()`（偏移与 fov 都还原到基准），
且 `is_active()` 为假时 `set_process(false)` 不空转。
**测试范式（重要）**：手感是**时序**，靠"跑几帧看看"断言不准 —— 帧率一变期望值就漂。
所以 `GameFeel.advance(delta)` 是**公开**的（同 `Enemy.advance` / `TurretSystem.advance_all` 的约定），
测试直接喂 `1.0/60.0` 手动步进，断言精度拉到 `1e-7`（"精确归零"这个坑只有这么验才现形）。
**配套**：每次 `EventBus.xxx.emit(...)` 后立刻 `feel.set_process(false)` ——
否则 Godot 自己的 `_process` 会额外推进一帧，手动步进的确定性就没了。

---

## 8. `albedo_color` 的分量 > 1 **不会被钳制**（实测确认）

闪白 = 把 albedo 设成 `(2.4, 2.0, 1.8)`，**分量 > 1 会一并抬高自发光**，这才是暗舱里"亮了一下"的来源。
`feel_test` 直接断言颜色等于 `flash_color()` 并通过 → 确认 Godot 4.7 不钳制该属性。
（3D 节点没有 `modulate`，只能改材质 —— 见 `gdscript_snags.md §4`。）

---

## 9. 调试入口（自省 API）

- `FeelKit`：`cfg()` / `reload()`（改完 JSON 不重启就重读）· `feedback(key)`（实际强度，已乘总闸，**缺键主动 warn**）·
  `has_event(key)`（探测存在性、不告警，测试用）。
- `GameFeel`：`is_active()` / `shake_amp()` / `zoom_deg()` · `offset_now()` / `cam_base()` / `fov_base()`（验精确归零）·
  `is_locked_out()` / `master_is_muted()`（让位与总闸）。
- `Enemy.body_color()` / `Turret.body_color()` —— 验闪白与还原（**比颜色值，不比字符串**）。

验证场景：`scenes/tests/feel_test.tscn` + `feel_probe.gd`（**49/49**）· `healthbar_test.tscn` + `healthbar_probe.gd`（**43/43**）。

---

## 10. 给玩法事件加一层新反馈的 checklist

1. `presentation.json` 的 `feel.events` 加/改键（`shake` / `zoom`；后续还有 hitstop / 数字的字段）。
   **键名必须与代码里订阅的事件名逐字一致** —— 写错不报错、只静默无反馈（⑩ 踩过同一个坑）。
2. 定路线：**低频事件** → `GameFeel._ready` 里 `connect` + 一个 `_on_xxx` → `_apply("键名")`；
   **实体自身外观** → 就地写在实体里，不经总线。
3. 跑 `feel_test`；跑主场景 headless 看 Output 有无 `WARNING: FeelKit`。
4. 数值一律进 JSON，代码里不出现秒数/米数/角度常量。

---

## 11. ⑪ 剩余两层（写给下次接手）

| 层 | 方案要点 |
|----|---------|
| ⑤ 敌人血量反馈 | **已落地（B+C）→ 详 `healthbar.md`**（弃用浮动伤害数字，理由见该册 §1） |
| ⑥ VFX（程序化占位） | 同 ⑩ 的合成音思路：代码生成 `GPUParticles3D`，不依赖美术。**受 bible 03 §六 预算约束**：单次 ≤8 粒子 / 同屏 ≤60。炮口火光 / 曳光 / 命中火花 / 爆炸 |
| ① hitstop | **不要用 `Engine.time_scale = 0`**（连带停音频 / Timer / AnimationPlayer）。本作世界推进集中式 → 直接 `EnemySystem.set_physics_process(false)` + `TurretSystem.set_physics_process(false)` N 毫秒，**现有系统代码一行不用改**；`AudioManager` / HUD / 相机 / 粒子照常跑，命中音不被掐断。作用域只给玩家动作 + L1/L2 |
