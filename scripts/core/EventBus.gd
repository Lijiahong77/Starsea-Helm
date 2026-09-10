extends Node
## EventBus —— 全局事件总线（架构地基，P0）
##
## 职责（MODULES.md §1 / §3）：所有跨模块通信的**唯一通道**，纯信号声明，零业务逻辑。
## 模块之间禁止直接互调，一律 `EventBus.<signal>.emit(...)`；订阅方 `EventBus.<signal>.connect(...)`。
##
## 命名规范：`domain:past_tense_event`，全小写下划线。
## 事件只描述「发生了什么」，不描述「该做什么」。
## 一个事件可被多个系统订阅；禁止在 EventBus 里写任何业务判断。
##
## autoload 顺序：EventBus 必须排在最前（其他 autoload 可能在 _ready 里引用它）。
## ⚠ 本文件是「信号清单 + 契约」，改事件名/签名前先回填 MODULES.md §3，保持单一真源。
##
## ⚠ 每个 signal 上方的 `@warning_ignore("unused_signal")` 是有意保留：
## 本工程「先铺满信号清单，后续模块（敌人/炮塔/波次/改装）再 connect」，
## 接入前这些信号确实无订阅方，会触发 GDScript unused_signal 警告刷屏。
## 一旦某 signal 真正被 connect，即可删掉它上方的 ignore 行。

# ── 飞船 / 炮塔 ──────────────────────────
## 某炮塔受到伤害。amount = 本次扣减量（**连续 dps**：每帧调一次，不是一发一发）。
## source_id = 打它的敌人类型 id（interceptor / bomber）—— ⑨a 战损报告靠它
## 回答「为什么掉的」（DEC-043）。
## 2026-09-10 签名从 2 参改 3 参：当时**零订阅方**，改签名零成本，已回填 MODULES.md §3。
signal turret_damaged(turret_id: StringName, amount: float, source_id: StringName)
## 某炮塔被摧毁。sector = 所属扇区（fore/port/starboard/dorsal/ventral/aft）。
signal turret_destroyed(turret_id: StringName, sector: StringName)
## 全部炮塔被摧毁 → GameStateManager 进入 RESULT。
signal all_turrets_destroyed()
## 玩家开始接管某炮塔（切手动）。
signal turret_takeover_started(turret_id: StringName)
## 玩家结束接管某炮塔（回主控室）。
signal turret_takeover_ended(turret_id: StringName)
## 某扇区压力变化（0..1）。压力可视化订阅它。
@warning_ignore("unused_signal")
signal sector_pressure_changed(sector: StringName, pressure: float)
## 某扇区所有炮塔被毁 = 该面失守。
signal sector_breached(sector: StringName)

# ── 敌人 / 波次 ──────────────────────────
## 敌人生成。enemy = 敌人节点，sector = 来袭扇区。
@warning_ignore("unused_signal")
signal enemy_spawned(enemy: Node, sector: StringName)
## 敌人被击杀（⑩ 起 AudioManager 订阅，用于击杀音）。
signal enemy_killed(enemy: Node)
## 敌人受到伤害（⑪ ⑤ 敌人血量反馈，2026-09-10）。
## **与 turret_damaged 的关键差别**：敌人挨打是**离散**事件（一发弹丸一次），
## 不像炮塔那样被持续 dps 每物理帧调 —— 所以走总线不会被刷爆，不需要限流。
## hp / hp_max 一起带上：订阅方（目标血条）要算「还剩几成」，
## 只有 hp 没有上限就画不出比例（同 Turret.hp_max 的语义）。
signal enemy_damaged(enemy: Node, amount: float, hp: float, hp_max: float)
## 一波战斗开始。wave_index 从 1 起。发方 WaveSystem；订阅方 bridge_whitebox（HUD）。
signal wave_started(wave_index: int)
## 本波敌人清空 → 进入下一危机（REFIT）。发方 WaveSystem；订阅方 bridge_whitebox（HUD）。
signal crisis_cleared(wave_index: int)

# ── 改装 / 解锁 ──────────────────────────
## 进入改装阶段。
@warning_ignore("unused_signal")
signal refit_opened()
## 玩家确认装配完成 → 进入战斗。
@warning_ignore("unused_signal")
signal refit_confirmed()
## 随危机进度自动解锁新炮塔类型（DEC-033，无货币）。
@warning_ignore("unused_signal")
signal turret_type_unlocked(type_id: StringName)
## 玩家把某炮塔装进槽位。
signal turret_equipped(turret_id: StringName, slot: int)
## 玩家把某炮塔从槽位拆下。
@warning_ignore("unused_signal")
signal turret_unequipped(turret_id: StringName, slot: int)
## 槽位总数变化（扩展槽位）。
@warning_ignore("unused_signal")
signal slot_count_changed(new_count: int)

# ── 监控 / 接管输入 ──────────────────────
## 玩家点了控制台上某路 feed（原始输入）。sector = 该路 feed 的扇区。
signal monitor_feed_clicked(sector: StringName)
## 主相机切到某副炮视角 / 回主控室。target = "main" 表示回主控室，否则为炮塔/扇区。
@warning_ignore("unused_signal")
signal monitor_view_changed(target: StringName)
## 手动模式下玩家按扳机发射（PlayerController 只发指令，不直接操作武器）。
signal turret_fired(turret_id: StringName)

## ⑦ 维修站过场开始 / 结束（2026-09-08）。
## **不进状态机**：过场是 REFIT 的入场演出，`MENU/REFIT/BATTLE/RESULT` 四态不变。
## 订阅方据此屏蔽输入（bridge_whitebox 的 B / 1-5 / E / R 在过场期间一律不响应）。
signal cutscene_started()
signal cutscene_ended()

## ⑦ 改装台把镜头对准某个炮位（发射时机：玩家在改装台选中槽位 / 退出改装台）。
## 参数 == &"" 表示「镜头回主控室」。复用接管那套相机搬移，但**不改炮塔模式** ——
## 改装时炮塔仍是 AUTO，只是让玩家**看得见自己换的那门炮**（无模型阶段特效若被黑幕
## 盖住，换装就等于没反馈，这是李 2026-09-08 提的「没有换了武器的感觉」的直接解药）。
signal refit_focus_slot(turret_id: StringName)

# ── 流程 ────────────────────────────────
## 全局状态机转移。new_state ∈ {MENU, REFIT, BATTLE, RESULT}。
signal game_state_changed(new_state: StringName)
