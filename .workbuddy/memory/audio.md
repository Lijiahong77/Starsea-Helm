# 音频专册（热区 · 按需读）
> 触发时机：**动 AudioManager / 改音效 / 调混音 / 接新警报音之前**扫一遍。
> 全部为 2026-09-10 ⑩ 实测，非二手知识。格式「现象 → 根因 → 修法」。预算 6000 字符。

---

## 0. 三处真源（改任何一处前先认清）

| 要改什么 | 去哪 | 别碰 |
|----------|------|------|
| 某个音的音量 / 限流阈值 / 占位音 / 路径 | `data/audio.json` 的 `sfx`/`bgm` 条目 | 代码 |
| 扇区→音高映射、哪些音走 3D | `data/audio.json` 的 `sector_hud` | 代码 |
| 事件 → 音效的接线（警报类） | `data/audio.json` 的 `events` | 代码 |
| 哪门炮用什么开火音 | `data/turrets.json` 的 `fire_sfx` | 路径/音量（在 audio.json） |
| 总线建法 / 防爆算法 / 淡化状态机 | `scripts/core/AudioManager.gd` | JSON |

**已移出**：`presentation.json` 的 `audio` 段（3D 音效 max_distance / unit_size）→ 迁到 `audio.json` 的 `spatial`。
呈现类旋钮归 presentation、听觉类归 audio，同一类参数**不许存两处**。

---

## 1. 缺素材时**别静默**，要合成占位音

**现象**：`assets/audio/` 为空时按「缺文件只 warn 然后静默」处理 → 白盒阶段**听不见任何东西**，
连"按键有没有反应"都验不了，而「每步做完 F5 自测」是本项目硬纪律。

**根因**：音频天生是"素材驱动"的，没素材就没声；但骨架阶段素材必然没有。

**修法**：每个条目带 `tone` 段（freq/dur/decay/noise/shape/amp），路径不存在时现场合成
`AudioStreamWAV`（16-bit 单声道 PCM）——**全内存、不落盘、不需 `--import`**。
正式素材放进 `path` 后自动接管，配置一个字不用改。

**要点**：
- 合成数据写 `PackedByteArray.encode_s16(i*2, v)`，小端 16 位。
- 噪声用 `rng.seed = hash(id)` **固定种子** → 两次运行听感一致（否则调试时"怎么又是另一个声"）。
- **循环音的有效长度必须正好是整数个周期**（freq × dur 取整），否则循环接缝会"啪"一下。
  本项目取 freq=55/73/44 × dur=4.0/4.0/3.0，都是整数周期。
- `loop` 写在**条目层**而不是 `tone` 里（因为它对真实素材同样成立）；
  `_stream_for` 把它**并进** tone 交给 `_synth`，同时对真实 `.wav`/`.ogg`/`.mp3` 也设上循环点。
  漏了这条的表现是「BGM 播半分钟就静了，而配置上明明写着 `loop: true`」，极难查。

---

## 2. 必须 `ResourceLoader.exists()` 探一下，**不许 preload**

**现象/根因**：知识库第 10 课——`preload()` 在启动时解析路径，文件不存在**工程直接起不来**。
`load()` 虽不会崩，但会对缺文件打 ERROR 刷屏（本工程缺文件是**常态**）。

**修法**：`if path != "" and ResourceLoader.exists(path): load(path)`。
`ResourceLoader.exists()` 是静默的，不会打错误。取不到就走占位音分支。

---

## 3. 防爆限流：**键必须含扇区**，不能只用 id

**现象（若写错）**：同时被两面打时，先到的那个扇区吃掉限流窗口，另一面**直接静音** ——
恰好把「听觉 HUD」最核心的信息（哪面在挨打）盖掉。

**修法**：限流键 = `"id|sector"`，每个扇区各自一个时间窗。对外 `play_count`/`drop_count` 仍按 id 汇总。

**两道闸门顺序**：先**同帧去重**（`Engine.get_physics_frames()` 比较），再**时间窗限流**
（`Time.get_ticks_msec()`，`limit_ms` 内最多 `max_per_window` 次）。`limit_ms = 0` = 不设窗口，但同帧去重仍生效。

**注意**：同帧去重会让"同一帧内连发"永远只有 1 次，所以**测时间窗必须跨帧**
（`await get_tree().physics_frame` 之间调）。但 headless 下帧间隔就是真实毫秒，
所以**别用 limit_ms 很小的音去测窗口**（60fps 下 3 帧≈50ms，可能刚好过期）；
选 `limit_ms` 明显大于几帧间隔的音（本项目用 `sfx_turret_damaged` 的 250ms）才稳。

---

## 4. 播放器池：超容量**丢最旧**，不是新开

**根因**：加播放器正是爆音的来源。知识库第 10 课的"2~3 个 player 轮转"就是这个意思。

**修法**：全局池（本项目 8 个 2D 播放器，SFX 与 UI 共用，每次播放现设 `bus`）+
一个专用 `AudioStreamPlayer3D`（只给前扇区）。池满时按 `_pool_started_ms` 找最旧的复用。
另配 `play_sfx_pitched(id, pitch_mul)` 供将来做"命中音随伤害变调"（⑪）。

---

## 5. BGM 交叉淡化用**显式状态机**，别用 Tween

**理由**：时序要可断言（测试直接读 `bgm_phase()` 与 `volume_db`），也不受 headless 下 Tween 行为差异影响。
四态：`IDLE → FADE_OUT → GAP → FADE_IN → IDLE`，参数在 `audio.json` 的 `crossfade`（0.8 / 0.3 / 0.5）。

**⚠ 踩过的坑（淡入对象写反）**：`_start_fade_in()` 里会**翻转 A/B 轨**，
所以进了 `FADE_IN` 阶段后，**现役**播放器才是新起的那条。
若照着 `FADE_OUT` 的写法去淡 `other`，就会去淡那条**已经 stop 的旧轨** ——
表现为旧轨无声、新轨永远停在 -60 dB（听感是"换歌之后就没声音了"）。
**判据**：`active_music_player().playing == true` 且 `volume_db ≈ 基准`。

**空闲不开 `_process`**：`set_process(false)` 常驻，只在交叉淡化期间打开，淡完立刻关。

---

## 6. autoload 顺序 + 开局补读状态

**现象**：AudioManager 在 `_ready` 里 connect `game_state_changed`，
但 `GameStateManager` 的初始广播在**它自己的 `_ready`** 里发，那时 AudioManager 还没订阅 → **永远收不到** → 开局没有 BGM。

**根因**：autoload 按 `project.godot` 的声明顺序**依次** `_ready`，早于主场景。
（同 `godot_pitfalls.md #13`。）

**修法**：AudioManager 排在 `EventBus` / `GameStateManager` **之后**注册，
并在 `_ready` 末尾主动补读一次：`_on_game_state_changed(GameStateManager.state_name())`。

---

## 7. 接线键名写错会**静默静音**（本次真栽过）

**现象**：`_on_wave_started` 里查 `_event_sfx("wave_start")`，而 `audio.json` 的键是 `"wave_started"`。
→ 查到空串 → `_play(&"")` 在最前面**静默 return** → 那个警报永远不响，
且 **Output 一片安静**（不报错、不 warn、`play_count` 为 0）—— 比报错难查得多。

**修法**：`_event_sfx()` 遇缺键**主动 warn**，把静默失败变成嘈杂失败。
**通用范式**：任何"查表 → 用结果"的接线，表里没有该键时要 warn，别把空值当合法输入往下传。

---

## 8. 层与零素材容错是**主路径**，不是兜底

`assets/audio/` 为空是**当前常态**。所以「缺文件 → 合成占位音」是主路径，
测试也按主路径验（断言 `stream_of(id) is AudioStreamWAV` 且 `data.size() > 0`），
而不是"兜底分支没报错就算过"。

---

## 9. 调试入口（自省 API，调音与排障用）

| API | 用途 |
|-----|------|
| `is_ready_ok()` | 配置是否加载成功 |
| `bus_key_index(key)` / `get_bus_db(key)` | 总线索引与电平（key = master/music/sfx/ui） |
| `play_count(id)` / `drop_count(id)` / `drop_reason(id)` | 播了几次 / 被丢几次 / **为什么被丢**（same_frame / window） |
| `last_pitch(id)` / `last_was_spatial()` | 听觉 HUD 是否按预期生效 |
| `stream_of(id)` | 实际会播的流（验"是否回退到合成音"） |
| `current_bgm()` / `bgm_phase()` / `active_music_player()` | BGM 状态机与现役轨 |
| `pool_size()` | 池容量（验"不靠无限开播放器"） |

验证场景：`scenes/tests/audio_test.tscn` + `scripts/tests/audio_probe.gd`（**60/60**）。

---

## 10. 接入新音的 checklist

1. `audio.json` 的 `sfx` 段加条目（`bus` / `path` / `volume_db` / `limit_ms` / `max_per_window` / `tone`）。
   **高频音必须设 `limit_ms`**，否则一帧多声会爆。
2. 决定走哪条路：**警报类低频** → 加进 `events` 段（零业务改动）；
   **高频** → 在业务代码里 `AudioManager.play_sfx(id, sector)`，且**能拿到扇区就要传**。
3. 若是炮塔开火音 → 在 `turrets.json` 对应型号加 `fire_sfx`。
4. 跑 `audio_test` + 主场景 headless 看 Output 有无 warning。
