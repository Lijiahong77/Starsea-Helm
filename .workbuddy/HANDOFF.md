# HANDOFF · 会话交接卡

> 用途：开新会话时把本文件路径丢给 AI，即可无缝接上。
> 维护：**只在跨会话交接时更新**，日常进度仍写 `memory/` 与 `docs/BACKLOG.md`（本文件不参与记忆预算）。
> 最后更新：2026-09-10（⑪ ⑤ 敌人血量反馈 B+C 落地后）

---

## 一句话现状

《星海舵手》P0 阶段：①-⑧ 与 ⑨a/⑨b/⑩ **全 ✅**，只剩 **⑪ 手感**（🟡）。

## ⑪ 手感进度（DEC-047）

| 层 | 状态 | 证据 |
|----|------|------|
| ② 闪白 · ③ 震屏 · ④ 推镜（第一层） | ✅ 完成 | `feel_test` **49/49** |
| ⑤ 敌人血量反馈（B 血条 + C 本体变暗） | ✅ 完成 | `healthbar_test` **43/43** |
| ⑥ VFX（程序化占位粒子） | ⬜ 未开工 | — |
| ① hitstop | ⬜ 未开工 | — |

**全套回归 9 个测试全绿**：feel49 · audio60 · round2 21 · hp30 · wave25 · refit33 · unlock77 · damage37 · collapse18。

## 下一步（等李拍板）

1. **李先 F5 手玩验收 ⑤** —— 数值只能给基线，手感得真机判。重点看两处：
   - 血条位置 `offset_top: 84` 会不会挡视线；
   - 敌人变暗幅度 `dim_color: [0.22, 0.09, 0.07]` 是「快散了」还是「直接看不见了」。
   - 旋钮都在 `data/presentation.json` 的 `healthbar` 段，改完 `HealthKit.reload()` 免重启。
2. 验收通过后，**⑥ VFX 与 ① hitstop 二选一**：
   - **⑥ VFX**：走 ⑩ 的合成音思路，代码生成 `GPUParticles3D`，不依赖美术。**受 bible 03 §六 预算约束**：单次 ≤8 粒子 / 同屏 ≤60。覆盖炮口火光 / 曳光 / 命中火花 / 爆炸。
   - **① hitstop**：**禁用 `Engine.time_scale = 0`**（会连带停音频 / Timer / AnimationPlayer）。本作世界推进是集中式的 → 直接 `EnemySystem.set_physics_process(false)` + `TurretSystem.set_physics_process(false)` N 毫秒，现有系统代码一行不用改。作用域只给玩家动作 + L1/L2。

## 开工前必读（按顺序）

1. `.workbuddy/memory/MEMORY.md` —— 热区索引（三条最高宪法 + 状态 + 分册指针）。
2. `.workbuddy/memory/game_feel.md` —— 手感专册（feel 旋钮表 / 事件→强度表 / ⑪ 剩余三层要点）。
3. `.workbuddy/memory/healthbar.md` —— ⑤ 专册（B/C 两层真源与两条新坑）。
4. `.workbuddy/memory/testing.md` —— **验证纪律 + 环境坑**（`export PATH="$PATH:/usr/bin:/bin"`、用 `/usr/bin/timeout`、headless 探针清单）。
5. 动 `.gd` / `.tscn` 之前再扫 `gdscript_snags.md` 与 `godot_pitfalls.md`。

## ⚠ 记忆预算告警

`2026-09-10.md` 已 **99%**、`game_feel.md` **91%**、`MEMORY.md` **90%**。
**新会话第一次落记忆前，先按纪律蒸馏**（细节下沉分册，日志只留「结论 + 证据 + 指针」）。自检：`python .workbuddy/memory/_check.py`。

## 环境速记

- Godot：`C:/Users/lijia/Desktop/Godot_v4.7-stable_win64.exe/Godot_v4.7-stable_win64_console.exe`
- 跑探针：`/usr/bin/timeout 180 "$G" --headless --path "D:/GameProject/Starsea Helm" res://scenes/tests/<name>.tscn`
- 新 `class_name` 必须先 `--headless --import` 才进全局类缓存（别手编 `.gd.uid`）。
- headless 主场景会刷 `texture_2d_get "t" is null` —— **dummy 驱动固有**，与业务无关，别被它淹没真错误。
