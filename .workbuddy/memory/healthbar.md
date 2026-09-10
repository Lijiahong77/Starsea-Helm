# 敌人血量反馈专册（⑪ ⑤ · 冷区 · 按需读）
> 触发时机：**动血条 / 改敌人变暗 / 给「打中敌人」加反馈之前**扫一遍。
> 全部为 2026-09-10 实测（B+C 方案），非二手知识。预算 6000 字符。

---

## 0. 一句话

取代原定的「浮动伤害数字」：**B = 接管时屏幕上方中央的「当前目标」血条 · C = 敌人本体随血量变暗**。
不做浮动数字的理由见 §1。

## 1. 为什么不做浮动伤害数字（李 2026-09-10 拍板）

`turrets.json` 单发伤害 vs `enemies.json` 血量：

| 武器 | 单发 | 战机 20 HP | 轰炸机 52 HP |
|------|------|-----------|-------------|
| 主炮 | 3 | 7 发 | 18 发 |
| gatling | 12 | 2 发 | 5 发 |
| flak | 24 | **1 发** | 3 发 |
| lance | 54 | **1 发** | **1 发** |

flak / lance 一发就秒 → 对它们数字**永远只显示满血数**，信息量为零。
真正有决策价值的是「**还差几发**」→ 做血条。
也顺带避开「满屏飘字」踩 DEC-021（低 APM、允许发呆）：本作自动火力每帧在打，飘字会糊满屏幕。

## 2. 哪里有真源（改任何一处前先认清）

| 要改什么 | 去哪（`data/presentation.json`） | 别碰 |
|----------|------------------------------|------|
| 血条位置 / 尺寸 / 配色 / 淡入淡出 / 标题 | `healthbar.target_bar.*` | 代码 |
| 低血变色阈值 | `healthbar.target_bar.low_ratio` | 代码 |
| 敌人变暗的目标色 / 曲线 | `healthbar.enemy_tint.dim_color` / `.curve` | 代码 |
| ⑤ 的总开关（关掉整层排查用） | `healthbar.enabled` | 代码 |
| 血条的显隐 / 淡入淡出状态机 | `scripts/ui/target_health_bar.gd` | JSON |
| 敌人变暗的状态机（与闪白共用材质） | `scripts/systems/enemy.gd` 的 `_apply_hp_tint` | JSON |

读取一律经 `scripts/utils/health_kit.gd`（`class_name HealthKit`，静态懒加载 + 缓存 + 缺键 warn）。
**不要新开 `healthbar.json`** —— 同类参数存两处是 ⑩ 刚迁过一次的老毛病。

## 3. 两层怎么实现的

- **B 层（屏幕空间）**：`scripts/ui/target_health_bar.gd`（`TargetHealthBar`，**CanvasLayer 层 5**）。
  **只在玩家接管某门炮时**显示，屏幕上方中央「当前目标 · 战机」+ 血条 + `hp / hp_max`。
  不接管零噪音 —— 那时敌人由自动炮塔处理、玩家插不上手，血条给了也无从决策。
  目标由 `bridge_whitebox` 注入 **`target_provider` 闭包**：`接管中的炮 → Turret.acquire_target()`。
  复用工程里已有的「当前目标」定义，和**手动开火的 LeadPrediction 同源** → 血条与你实际瞄的那台必然一致。
  `lock_check` 是让位钩子（同 `GameFeel.lock_check`）。`advance(delta)` **公开**，测试手动步进。
- **C 层（空间化）**：`enemy.gd` 本体色 = `HealthKit.tint_color(_full_color, hp_ratio())`，越残越暗，满血 = 本色。
  符合 DEC-026「信息不对称由物理保证」，不叠 UI。

## 4. 前置三块（做血条绕不开，都已补）

1. **`Enemy.hp_max` 快照** —— 原来只有 `hp`；难度缩放后「本波满血」就丢了，算不出比例。
2. **`Enemy.scale_hp(scale)`** —— **hp 与 hp_max 必须同乘**。已把 `wave_system` 的
   `e.hp *= hp_scale` 改掉；只改 hp 会让血条比例 > 1（爆表）。
3. **`EventBus.enemy_damaged(enemy, amount, hp, hp_max)`** —— 敌人挨打是**离散**事件（一发弹丸一次），
   不像炮塔那样被持续 dps 每帧调 → 走总线不会刷爆，**不需要限流**（区别于 `turret_damaged`）。

## 5. ⚠ 两条新坑（改 ⑤ 之前必读）

1. **C 层与闪白抢同一个材质**。`_apply_hp_tint()` 必须排在 `_hit_flash()` **之前**，
   且**闪白进行中只更新 `_base_color`、不写材质** —— 否则「打中了却不闪」，
   把 ⑪ 第一层刚验过的成果静默吃掉。
2. **闪白的还原目标变了**：不再是「满血本色」，而是 `_base_color` = **按血量染过色的静止色**。
   → `_hit_flash` **不再**从材质回抄 `_base_color`（旧写法会抄到错的中间态）；
   `feel_test` 里那条「闪白到期还原本色」的旧断言已按新语义改写（**别改回去**）。

## 6. 层号占用（别撞）

| 层 | 谁 |
|----|----|
| CanvasLayer **5** | ⑤ `TargetHealthBar` |
| CanvasLayer **10** | ⑦ `RefitOverlay`（⑨a 战损面板是它的子节点） |
| 3D mesh（不走 CanvasLayer） | ⑨b 陷落标记（打在 feed 的屏幕 mesh 上） |

## 7. 自省 API

- `HealthKit`：`cfg()` · `reload()` · **`loaded_from_json()`**（自证读的是文件、不是兜底值）·
  `bar()` · `tint_color(base, ratio)` · `parse_color(v, fallback)`。
- `TargetHealthBar`：`is_showing()` · `bar_ratio()` · `fill_width()` · `bar_width()` ·
  `hp_text()` · `title_text()` · `alpha()` · `target()` · `advance(delta)`。

验证场景：`scenes/tests/healthbar_test.tscn` + `scripts/tests/healthbar_probe.gd`（**43/43**）。
覆盖：真源读取 / 层号 / `hp_max` 快照 / `scale_hp` 同乘 / 事件载荷（含致死那一下）/
C 层按比例变暗且**不吃闪白** / B 层显隐 · 比例 · 换目标。

## 8. 给「打中敌人」加新反馈的 checklist

1. 决定走哪条路：**低频事件** → 订阅 `EventBus.enemy_damaged`（载荷已含 hp/hp_max）；
   **实体自身外观** → 就地写在 `enemy.gd` 里，不经总线。
2. 数值一律进 `presentation.json` 的 `healthbar` 段（或 `feel` 段，看它属于「信息呈现」还是「手感」）。
3. 跑 `healthbar_test` + `feel_test`（两者共享 `enemy.gd` 的材质，**改一边必跑另一边**）。
