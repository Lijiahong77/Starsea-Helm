# 战损 / 陷落专册（⑨a + ⑨b · 冷区 · 按需读）
> 触发时机：**动战损统计 / 战损四出口 / 陷落演出（L1/L2/L3）之前**扫一遍。
> 设计口径的权威是 `docs/bible/99_decisions.md` 的 **DEC-044 / DEC-045**（DEC-043 定的形态）；
> 本册只放工程实现 + 踩坑 + 测试。全部为 2026-09-10 实测。预算 6000 字符。

---

## 0. 一句话

- **⑨a 战损报告** = 「一份数据、四个出口」的代码落地（DEC-043 决定 1）→ `damage_log.gd`。
- **⑨b 陷落演出** = 只做**编排**，不是特效（DEC-045）：爆炸粒子归 ⑪VFX、警报音归 ⑩音频。
  三者订阅**同一批事件**（`turret_destroyed` / `sector_breached` / `all_turrets_destroyed`）
  → ⑩⑪ 接进来时是「往里填特效」，不是推翻重写。

## 1. 哪里有真源

| 要改什么 | 去哪 | 别碰 |
|----------|------|------|
| 战损统计口径 / 清空时机 | `scripts/systems/damage_log.gd`（`DamageLog`，**挂成 TurretSystem 的子节点**） | — |
| 四出口形态 | ① HUD `bridge_whitebox._refresh_hud` · ② `RefitOverlay.set_damage_panel` · ③ `refit.json` 的 `lines_damage` · ④ `refit_sequence._damage_suffix` | — |
| 敌人中文名（文案外置） | `data/enemies.json` 的 `display_name` | 代码字面量 |
| L1/L2 标记 + L3 镜头（全旋钮化） | `data/presentation.json` 的 `collapse` 段 | 代码 |
| 编排状态机 | `scripts/systems/collapse_sequence.gd`（`CollapseSequence`，挂 bridge 子节点） | JSON |

## 2. 战损数据口径（三条决策，不是实现细节）

1. **记「本波」不记「累计」** —— 跨波累计会让「这波刚挨的打」被历史淹没，玩家看不出该改哪门，决策价值归零。
2. **清空挂在开战**（`TurretSystem.set_battle_active(true)` → `DamageLog.reset()`），**不是危机清空** ——
   一清空就再也读不到，而整条 REFIT 链都要读它；下一个「肯定不再需要上一波数据」的时机就是下一波开战前。
   和「开战回满耐久」挨在一起，心智上也说得通。
3. **被毁单独一个文案**，不显示 -999 —— 大数字会盖住「这门没了」这个事实，而它才是该触发换装的信号。
   同理**没战损就不播报、不显示**（同 DEC-042 解锁播报）；但面板给一句「本波无战损」而**不留空**
   （空面板会让人以为没加载出来）。

## 3. ⚠ 三个实现坑（照抄）

1. **来源早就传了，只是被吞了**：`enemy.gd` 一直把 `type_id` 当第二参传给 `take_damage`，
   而 `Turret.take_damage` 把它写成 `_source_id`（9/6 为压未使用告警加的下划线）。
   解禁 + 给 `turret_damaged` 加第三参即可 —— 当时该事件**零订阅方**，改签名零成本。
   → **为压告警加 `_` 前缀时，注释必须写明「将来给谁用」，否则这个伏笔会烂在代码里。**
2. **列战损不能用 `slots_of_sector()`** —— 它只返回「可接管」的槽位，**被毁的会被过滤掉**，
   而「这门被打没了」恰恰是战损报告最该显示的东西。改成遍历 `all_slot_ids()` 自己按扇区分组。
3. **`show_mechanic` 内部会先 `hide_all()`** → 战损面板**每句台词都要重设一次**；
   只在进阶段时设一次的话，第二句起面板就消失了。

## 4. 陷落三级演出（落地形态）

| 级 | 触发 | 演出 | 夺操控 |
|----|------|------|--------|
| L1 单炮被毁 | `turret_destroyed` | 该路 feed **计数标记**「存活/已装」+ 黄染色 + 脉冲 | 否 |
| L2 该面失守 | `sector_breached` | 该路 feed **整屏红 + 红叉 ✕** | 否 |
| L3 全局终局 | `all_turrets_destroyed` | 夺操控 → 相机拉远环绕回望船体 → 宣告 → RESULT | **是** |

**三条关键决策**：

1. **主信号是「整屏染色」，文字只是补充** —— 项目**没配字体**（靠系统 fallback），
   不能把关键反馈押在「字能不能渲染出来」上。色块（UNSHADED + 自发光，不受舱内光照）在主，
   `Label3D` 文字（「1/2」/「✕」）是补充，字体 fallback 失败也不影响演出成立。
2. **标记打在「屏幕 mesh 前」，不是 feed 画面里** —— DEC-038 的 4 路 feed 是**副炮相机画面**，
   往里塞会跟着相机转、也难对齐；而「该面失守」是**玩家的认知状态**，不是副炮看到的场景内容
   → 作为屏幕 mesh 的子节点沿 +Z 偏一点点（屏幕法线 +Z 朝玩家，零 transform 计算）。
   **⑥ 解冻结后这个区别依然成立。**
3. **表现层对节点缺失容错** —— headless / 无监控屏 / 无相机时 `CollapseSequence` 只跑状态层、不崩。
   既是 headless 可测纯逻辑的需要，也是 ⑥ 冻结的防御：屏幕/相机未来重构时，编排器不该因找不到节点报错。

**L3 镜头**（白盒占位）：相机从当前位 lerp 到「距船心 `pullback`(95m) + 绕 UP 轴 `orbit_deg`(55°) + 抬高 `rise`(16m)」，
全程 `look_at` 船心。**`pullback` 必须大于敌人悬停距离**（`enemies` 的 `attack_range` 默认 50），
否则相机穿过敌群、看不到「被包围」。环绕（不是单调后退）是为「四面都是敌人」的扫视感。
白盒阶段船心 = 世界原点，整船 mesh 落地后改读 ship 中心（旋钮化）。

## 5. 测试里踩的两个坑

1. **`crisis_cleared` 的参数值被忽略** —— `TurretSystem._on_crisis_cleared` 里是 `_cleared += 1`，
   靠 emit **次数**累加。想解锁门槛 N 的槽位得 emit N 次，`emit(N)` 没用
   （collapse_probe 起初 `emit(2)` 只累到 1，port2 没解锁）。
2. **`all_turrets_destroyed` 把主炮 main 也算在内**（DEC-037 失败条件 = 所有炮塔被毁）。
   打掉 5 门副炮后 alive_count 仍 = 1（main），终局不触发 —— 漏掉 main 会假失败。

## 6. 层号占用（别撞）

| 层 | 谁 |
|----|----|
| CanvasLayer **10** | ⑦ `RefitOverlay`（⑨a 战损面板是它的子节点） |
| 3D mesh（不走 CanvasLayer） | ⑨b 陷落标记（打在 feed 的屏幕 mesh 上） |

（CanvasLayer 5 = ⑤ `TargetHealthBar`，见 `healthbar.md §6`。）

## 7. 验证

- ⑨a：`scenes/tests/damage_test.tscn` **37/37**。⚠ 测试**一律走真实路径**
  （`Turret.take_damage` → 事件 → DamageLog），不许直接 emit —— 直接 emit 会跳过 `source_id` 传递，
  哪天又没传出去，测试照样是绿的。
- ⑨b：`scenes/tests/collapse_test.tscn` **18/18**。回归 damage 37 / unlock 77 / refit 33 / wave 25 / hp 30 / round2 21 全绿。
- ⚠ 新增 `class_name` 脚本要先跑一次 `--headless --import` 才进全局类缓存，否则 headless 跑测试报
  「Could not find type」（详见 `tooling.md`）。
