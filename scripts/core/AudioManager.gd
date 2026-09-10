extends Node
## AudioManager —— 音频骨架（autoload 单例，P0 · **DEC-046**）
##
## **一句话**：所有声音的唯一出口。业务代码只喊「放哪个音、哪一面被打」，
## 音量 / 总线 / 限流 / 音高映射全在这里，且全部来自 `data/audio.json`。
##
## **职责**（docs/MODULES.md §一 autoload 层）：
##   ① 建总线 Master → Music / SFX / UI（**4 条**，见 DEC-046 决定 1）
##   ② 播 SFX（含**高频防爆**：时间窗限流 + 同帧去重 + 播放器池丢最旧）
##   ③ 播 BGM（含**交叉淡化**状态机）
##   ④ **听觉 HUD**：按受击扇区改音高 / 切 2D·3D，让玩家「听得懂是哪一面」
##
## **两条接入口，边界写死**（DEC-046 决定 2）：
##   · **低频**（炮毁 / 失守 / 终局 / 敌人被击杀 / 波次）→ 本类自己订阅 `EventBus`，
##     接线表在 audio.json 的 `events` 段 —— 加一个警报音不用碰任何业务脚本。
##   · **高频**（开火 / 命中 / 受创，每帧级）→ 业务代码直接调 `play_sfx()`。
##     **不走 EventBus**：每帧 emit 会把总线刷爆，而 EventBus 的语义是「状态翻转」不是「连续量」。
##     这是对 MODULES.md §一 原则 1 的**明确例外**：调的是 autoload 服务，不是跨模块调业务逻辑。
##
## **零素材可用**：`assets/audio/` 为空时，本类按 audio.json 的 `tone` 参数**现场合成一段占位音**
## （`AudioStreamWAV`，全内存、不落盘、不需导入）。正式素材放进 `path` 后自动接管，
## 配置一个字都不用改。所以白盒阶段 F5 就能听见，不需要等美术。
##
## **不许 preload**（知识库第 10 课）：路径不存在时 preload 会让工程直接起不来。
## 这里一律 `ResourceLoader.exists()` 探一下再 `load()`，缺文件只 warn 不崩。

## 【日志纪律 2026-09-05】新模块默认打开；⑩ 验收后改 false。
## ⚠ 本类**绝不逐次播报音效**——高频音一秒几十次，打日志会瞬间淹没 Output。
## 只打「状态变化」：初始化 / 总线建立 / 配置缺失 / BGM 换轨。
const DEBUG_LOG := true

## 音频参数的唯一读源（同目录约定见 docs/MODULES.md §五）。
const CONFIG_PATH := "res://data/audio.json"

## 缺省 tone（条目没写 tone 段时兜底），避免「配置漏了就没声」这种沉默失败。
const TONE_FALLBACK := {
	"freq": 440.0, "dur": 0.12, "decay": 16.0, "noise": 0.0, "shape": "sine", "amp": 0.6, "loop": false,
}

## BGM 交叉淡化阶段。
const PHASE_IDLE := &"IDLE"
const PHASE_OUT := &"FADE_OUT"
const PHASE_GAP := &"GAP"
const PHASE_IN := &"FADE_IN"

var _cfg: Dictionary = {}
var _ok := false

## 总线：key（master/music/sfx/ui）→ AudioServer 里的总线索引。-1 = 没建成。
var _bus: Dictionary = {}
## 2D 播放器池（SFX + UI 共用，每次播放现设 bus）。
var _pool: Array[AudioStreamPlayer] = []
var _pool_started_ms: Array[int] = []
## 前扇区专用 3D 播放器（bible 04 §六：只有舷窗那一面该有方向感）。
var _spatial: AudioStreamPlayer3D = null
## BGM 双轨交叉淡化（A 现役 / B 待命，交替使用）。
var _music_a: AudioStreamPlayer = null
var _music_b: AudioStreamPlayer = null
var _music_a_is_current := true

## id → AudioStream。**含 null**（null = 已尝试且失败，别再重试刷屏）。
var _stream_cache: Dictionary = {}
## 已 warn 过的 id，避免缺文件时每帧刷屏。
var _warned: Dictionary = {}

## 防爆：id → 时间窗起点(ms) / 窗内计数 / 上次播放的物理帧号。
var _win_start_ms: Dictionary = {}
var _win_count: Dictionary = {}
var _last_frame: Dictionary = {}

## 统计（audio_test 断言用，也可给将来的调试面板）。
var _play_count: Dictionary = {}
var _drop_count: Dictionary = {}
## 最近一次被丢弃的原因（same_frame / window）—— 调音时「为什么没响」的第一手线索。
var _last_drop: Dictionary = {}
var _last_pitch: Dictionary = {}
var _last_was_spatial := false

## BGM 状态机。
var _bgm_current: StringName = &""
var _bgm_pending: StringName = &""
var _bgm_phase: StringName = PHASE_IDLE
var _phase_t := 0.0


func _ready() -> void:
	# autoload 顺序：EventBus → GameStateManager → AudioManager。
	# 本类 _ready 里要 connect 信号，所以必须排在 EventBus 之后（project.godot 里已保证）。
	load_config()
	if not _ok:
		push_warning("[audio] 配置加载失败，音频全程静默（游戏其余部分不受影响）")
		return
	_ensure_buses()
	_build_players()
	_connect_events()
	# BGM 状态机按需启动，平时不占 _process。
	set_process(false)
	# ⚠ autoload 的 _ready 早于主场景（.workbuddy/memory/godot_pitfalls.md #13）：
	# GameStateManager 在它自己的 _ready 里广播的初始状态，本类**订阅之前就发完了**，
	# 永远收不到。所以这里主动补读一次当前状态，否则开局没有 BGM。
	_on_game_state_changed(GameStateManager.state_name())
	if DEBUG_LOG:
		print("[audio] 就绪：总线 %s｜音效 %d 条｜BGM %d 条" % [
			str(_bus.keys()), _sfx_table().size(), _bgm_table().size()])


# ════════════════════════════════════════════════ 公开 API

## 播一个音效。sector 传受击/开火所在扇区 → 听觉 HUD 据此改音高、决定 2D/3D。
## 不需要方位的音（UI）留空即可。
func play_sfx(id: StringName, sector: StringName = &"") -> void:
	_play(id, sector, 1.0)


## 变调播放（命中音随伤害高低变调之类）。pitch_mul 是**相对于听觉 HUD 基准音高**的倍率。
func play_sfx_pitched(id: StringName, pitch_mul: float) -> void:
	_play(id, &"", pitch_mul)


## 切 BGM（带交叉淡化）。传 &"" 或未知 id 只告警不动当前曲。
func play_bgm(id: StringName) -> void:
	if not _ok:
		return
	if id == _bgm_current and _bgm_phase != PHASE_IDLE:
		return
	var entry: Variant = _entry_of(_bgm_table(), id)
	if not (entry is Dictionary):
		_warn_once(id, "BGM id 不在 audio.json 的 bgm 段，忽略")
		return
	_bgm_pending = id
	if _bgm_current == &"":
		# 首次播放：没有旧轨可淡出，直接进淡入。
		_start_fade_in()
		return
	_bgm_phase = PHASE_OUT
	_phase_t = 0.0
	set_process(true)
	if DEBUG_LOG:
		print("[audio] BGM 切换 %s → %s" % [str(_bgm_current), str(id)])


## 立刻停止 BGM（结算后回菜单之类）。
func stop_bgm() -> void:
	_bgm_current = &""
	_bgm_pending = &""
	_bgm_phase = PHASE_IDLE
	_music_a.stop()
	_music_b.stop()
	set_process(false)


# ── 总线控制（音量 / 静音，留给将来的设置界面）──

func bus_key_index(key: StringName) -> int:
	return int(_bus.get(key, -1))


func set_bus_db(key: StringName, db: float) -> void:
	var idx := bus_key_index(key)
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, db)


func get_bus_db(key: StringName) -> float:
	var idx := bus_key_index(key)
	return AudioServer.get_bus_volume_db(idx) if idx >= 0 else -80.0


func set_master_mute(muted: bool) -> void:
	var idx := bus_key_index(&"master")
	if idx >= 0:
		AudioServer.set_bus_mute(idx, muted)


# ── 自检 / 测试入口 ──

func is_ready_ok() -> bool:
	return _ok


## 2D 播放器池容量（断言「不靠无限开播放器」）。
func pool_size() -> int:
	return _pool.size()


## 真实播放次数 / 被限流丢弃次数（断言防爆策略是否生效）。
func play_count(id: StringName) -> int:
	return int(_play_count.get(id, 0))


func drop_count(id: StringName) -> int:
	return int(_drop_count.get(id, 0))


## 最近一次被丢弃的原因：&"same_frame" / &"window" / &""（没被丢过）。
func drop_reason(id: StringName) -> StringName:
	return StringName(str(_last_drop.get(id, "")))


## 最近一次播放用的 pitch_scale（断言听觉 HUD 映射）。
func last_pitch(id: StringName) -> float:
	return float(_last_pitch.get(id, 0.0))


## 最近一次播放是否走的 3D 播放器（断言「仅前扇区有方向感」）。
func last_was_spatial() -> bool:
	return _last_was_spatial


## 取某 id 实际会播的流（断言缺文件时真的回退到合成音）。
func stream_of(id: StringName) -> AudioStream:
	var entry: Variant = _entry_of(_sfx_table(), id)
	if not (entry is Dictionary):
		entry = _entry_of(_bgm_table(), id)
	if not (entry is Dictionary):
		return null
	return _stream_for(id, entry as Dictionary)


func current_bgm() -> StringName:
	return _bgm_current


func bgm_phase() -> StringName:
	return _bgm_phase


## 现役 BGM 播放器（测试读它的 volume_db 验证淡化曲线）。
func active_music_player() -> AudioStreamPlayer:
	return _music_a if _music_a_is_current else _music_b


func reset_stats() -> void:
	_play_count.clear()
	_drop_count.clear()
	_last_drop.clear()
	_last_pitch.clear()


# ════════════════════════════════════════════════ 配置

func load_config() -> void:
	if not FileAccess.file_exists(CONFIG_PATH):
		push_warning("[audio] 找不到 %s" % CONFIG_PATH)
		return
	var f := FileAccess.open(CONFIG_PATH, FileAccess.READ)
	if f == null:
		push_warning("[audio] 打不开 %s" % CONFIG_PATH)
		return
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if not (parsed is Dictionary):
		push_warning("[audio] %s 不是合法 JSON 对象" % CONFIG_PATH)
		return
	_cfg = parsed as Dictionary
	_ok = true


func _sfx_table() -> Dictionary:
	var v: Variant = _cfg.get("sfx", {})
	return v as Dictionary if v is Dictionary else {}


func _bgm_table() -> Dictionary:
	var v: Variant = _cfg.get("bgm", {})
	return v as Dictionary if v is Dictionary else {}


## 从一张表里取某 id 的条目；`_doc` 等下划线前缀键不算条目。
func _entry_of(table: Dictionary, id: StringName) -> Variant:
	if str(id).begins_with("_"):
		return null
	var v: Variant = table.get(String(id), null)
	if v is Dictionary:
		return v
	return null


# ════════════════════════════════════════════════ 总线 / 播放器

## 建 Master → Music / SFX / UI。**运行时建而不是 .tscn 总线布局文件**：
## 幂等（已存在就跳过）、headless 可验、不依赖二进制资源格式。
func _ensure_buses() -> void:
	var names: Dictionary = _names()
	_bus[&"master"] = AudioServer.get_bus_index(str(names.get("master", "Master")))
	var mix: Dictionary = _dict(_cfg.get("mix", {}))
	for key in [&"music", &"sfx", &"ui"]:
		var bus_name := str(names.get(str(key), str(key).capitalize()))
		var idx := AudioServer.get_bus_index(bus_name)
		if idx < 0:
			AudioServer.add_bus()
			idx = AudioServer.get_bus_count() - 1
			AudioServer.set_bus_name(idx, bus_name)
			AudioServer.set_bus_send(idx, str(names.get("master", "Master")))
		_bus[key] = idx
		var db_key := "%s_db" % str(key)
		if mix.has(db_key):
			AudioServer.set_bus_volume_db(idx, float(mix.get(db_key, 0.0)))
	if DEBUG_LOG:
		print("[audio] 总线建立：%s" % str(_bus))


func _names() -> Dictionary:
	return _dict(_cfg.get("buses", {}))


func _dict(v: Variant) -> Dictionary:
	return v as Dictionary if v is Dictionary else {}


func _build_players() -> void:
	# 2D 池：SFX 与 UI 共用，每次播放现设 bus（省一半播放器）。
	var pool_cfg: Dictionary = _dict(_cfg.get("pool", {}))
	var pool_size := int(pool_cfg.get("size", 8))
	for i in pool_size:
		var p := AudioStreamPlayer.new()
		p.name = "Pool%d" % i
		add_child(p)
		_pool.append(p)
		_pool_started_ms.append(0)
	_music_a = _make_player("MusicA")
	_music_b = _make_player("MusicB")
	# 3D：只给前扇区用。位置取配置里的舷窗外挂点。
	var sp: Dictionary = _dict(_cfg.get("spatial", {}))
	_spatial = AudioStreamPlayer3D.new()
	_spatial.name = "Spatial"
	_spatial.bus = str(_names().get("sfx", "SFX"))
	_spatial.max_distance = float(sp.get("max_distance", 320.0))
	_spatial.unit_size = float(sp.get("unit_size", 12.0))
	_spatial.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	add_child(_spatial)
	_spatial.position = _vec3(sp.get("fore_source_offset", [0.0, 1.6, -30.0]))


func _make_player(s_name: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.name = s_name
	p.bus = str(_names().get("music", "Music"))
	add_child(p)
	return p


func _vec3(v: Variant) -> Vector3:
	if v is Array:
		var a := v as Array
		if a.size() >= 3:
			return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO


# ════════════════════════════════════════════════ 事件接线（低频）

## 低频警报一律走 EventBus（DEC-046 决定 2）。接线目标是 audio.json 的 events 段，
## 所以「换个警报音」= 改 JSON，不用碰这里的代码。
func _connect_events() -> void:
	EventBus.turret_destroyed.connect(_on_turret_destroyed)
	EventBus.sector_breached.connect(_on_sector_breached)
	EventBus.all_turrets_destroyed.connect(_on_all_turrets_destroyed)
	EventBus.enemy_killed.connect(_on_enemy_killed)
	EventBus.wave_started.connect(_on_wave_started)
	EventBus.crisis_cleared.connect(_on_crisis_cleared)
	# 改装落位（换装 / 空槽装炮都会 emit）——「咔达一声」是装配手感的一部分。
	# 开局建炮**不** emit 这个信号，所以不会一进游戏就连响几声。
	EventBus.turret_equipped.connect(_on_turret_equipped)
	EventBus.game_state_changed.connect(_on_game_state_changed)


## 事件名 → 音效 id（查 events 段）。
## **缺键要吵**：接线键名写错如果不报，表现是「这个警报永远不响」而 Output 一片安静 ——
## 比报错难查得多（本次开发实测栽过一次：代码写 wave_start、配置写 wave_started）。
func _event_sfx(event_key: String) -> StringName:
	var ev: Dictionary = _dict(_cfg.get("events", {}))
	if not ev.has(event_key):
		_warn_once(StringName("events:" + event_key),
			"audio.json 的 events 段缺这个键，对应警报静音（检查键名拼写）")
		return &""
	return StringName(str(ev.get(event_key, "")))


func _on_turret_destroyed(_turret_id: StringName, sector: StringName) -> void:
	_play(_event_sfx("turret_destroyed"), sector, 1.0)


func _on_sector_breached(sector: StringName) -> void:
	_play(_event_sfx("sector_breached"), sector, 1.0)


func _on_all_turrets_destroyed() -> void:
	_play(_event_sfx("all_turrets_destroyed"), &"", 1.0)


func _on_enemy_killed(_enemy: Node) -> void:
	_play(_event_sfx("enemy_killed"), &"", 1.0)


func _on_wave_started(_wave_index: int) -> void:
	_play(_event_sfx("wave_started"), &"", 1.0)


func _on_crisis_cleared(_wave_index: int) -> void:
	_play(_event_sfx("crisis_cleared"), &"", 1.0)


func _on_turret_equipped(_turret_id: StringName, _slot: int) -> void:
	_play(_event_sfx("turret_equipped"), &"", 1.0)


## 阶段 → BGM。空串表示「该阶段不切歌」。
func _on_game_state_changed(new_state: StringName) -> void:
	var map: Dictionary = _dict(_cfg.get("bgm_by_state", {}))
	var want := StringName(str(map.get(String(new_state), "")))
	if want == &"":
		return
	play_bgm(want)


# ════════════════════════════════════════════════ 播放主路径

func _play(id: StringName, sector: StringName, pitch_mul: float) -> void:
	if not _ok or id == &"":
		return
	var entry: Variant = _entry_of(_sfx_table(), id)
	if not (entry is Dictionary):
		_warn_once(id, "音效 id 不在 audio.json 的 sfx 段，忽略")
		return
	var e := entry as Dictionary
	if _rate_limited(id, sector, e):
		_bump(_drop_count, id)
		return
	var stream := _stream_for(id, e)
	if stream == null:
		return
	var hud: Dictionary = _sector_hud(sector)
	var pitch := float(hud.get("pitch", 1.0)) * pitch_mul
	var use_3d := bool(hud.get("spatial", false))
	# 显式 if/else 而不是三元：两个分支是兄弟类型（2D / 3D 播放器），
	# 三元会推不出公共类型（见 .workbuddy/memory/gdscript_snags.md #2 的同类坑）。
	var player: Node = null
	if use_3d:
		player = _spatial
	else:
		player = _pool_pick()
	if player == null:
		return
	if player is AudioStreamPlayer:
		var p2 := player as AudioStreamPlayer
		p2.bus = _bus_name_for(e)
		p2.stream = stream
		p2.volume_db = float(e.get("volume_db", 0.0))
		p2.pitch_scale = pitch
		p2.play()
	else:
		var p3 := player as AudioStreamPlayer3D
		p3.bus = _bus_name_for(e)
		p3.stream = stream
		p3.volume_db = float(e.get("volume_db", 0.0))
		p3.pitch_scale = pitch
		p3.play()
	_bump(_play_count, id)
	_last_pitch[id] = pitch
	_last_was_spatial = use_3d


## 条目 bus 键 → AudioServer 上的真实总线名。查不到就回退 SFX。
func _bus_name_for(e: Dictionary) -> String:
	var key := str(e.get("bus", "sfx"))
	var names: Dictionary = _names()
	var nm := str(names.get(key, ""))
	return nm if nm != "" else str(names.get("sfx", "SFX"))


## 听觉 HUD：扇区 → {pitch, spatial}。无扇区 / 未配置扇区 → 基准音高 + 2D。
func _sector_hud(sector: StringName) -> Dictionary:
	if sector == &"":
		return {}
	var hud: Dictionary = _dict(_cfg.get("sector_hud", {}))
	var v: Variant = hud.get(String(sector), null)
	return v as Dictionary if v is Dictionary else {}


## 防爆。两道闸门：**同帧去重**（同一物理帧内同一 id 只发一次）→ **时间窗限流**
## （limit_ms 内最多 max_per_window 次）。limit_ms = 0 表示不限流，但同帧去重仍然生效。
##
## ⚠ **限流键是「id + 扇区」而不是 id 本身**。理由：听觉 HUD 的全部价值就是
## 「同时被两面打时，两面都听得见」。若按 id 全局限流，先到的那个扇区会吃掉窗口，
## 另外几面直接静音 —— 恰好把最关键的信息盖住了。
## 对外暴露的 play_count / drop_count 仍按 id 汇总，API 不受影响。
func _rate_limited(id: StringName, sector: StringName, e: Dictionary) -> bool:
	var key: StringName = id if sector == &"" else StringName("%s|%s" % [str(id), str(sector)])
	if bool(_cfg.get("dedup_same_frame", true)):
		var frame := Engine.get_physics_frames()
		if int(_last_frame.get(key, -1)) == frame:
			_last_drop[id] = &"same_frame"
			return true
		_last_frame[key] = frame
	var limit_ms := int(e.get("limit_ms", 0))
	if limit_ms <= 0:
		return false
	var max_in := maxi(1, int(e.get("max_per_window", 1)))
	var now := Time.get_ticks_msec()
	var start := int(_win_start_ms.get(key, -1))
	if start < 0 or now - start >= limit_ms:
		_win_start_ms[key] = now
		_win_count[key] = 1
		return false
	var n := int(_win_count.get(key, 0)) + 1
	_win_count[key] = n
	if n > max_in:
		_last_drop[id] = &"window"
		return true
	return false


## 取流：真实素材优先，缺文件则合成占位音，都拿不到才失效（只 warn 一次）。
## **绝不用 preload**（知识库第 10 课）——缺文件会让工程起不来。
func _stream_for(id: StringName, e: Dictionary) -> AudioStream:
	if _stream_cache.has(id):
		return _stream_cache[id] as AudioStream
	# loop 写在**条目**层（因为它对真实素材和占位音都成立），进 _synth 前并进 tone。
	var want_loop := bool(e.get("loop", false))
	var path := str(e.get("path", ""))
	if path != "" and ResourceLoader.exists(path):
		var res: Resource = load(path)
		if res is AudioStream:
			_apply_loop(res as AudioStream, want_loop)
			_stream_cache[id] = res
			return res as AudioStream
	var tone: Variant = e.get("tone", null)
	var tone_d: Dictionary = TONE_FALLBACK.duplicate()
	if tone is Dictionary:
		tone_d = (tone as Dictionary).duplicate()
	if not tone_d.has("loop"):
		tone_d["loop"] = want_loop
	var s := _synth(id, tone_d)
	if s == null:
		_warn_once(id, "既没有素材文件也没有可用的 tone 参数，该音效静默")
		_stream_cache[id] = null
		return null
	_stream_cache[id] = s
	return s


## 让配置里的 loop 对**真实素材**同样生效 —— 否则放进一个 .ogg 却不循环，
## 表现为「BGM 播 30 秒就静了」，而且配置上明明写着 loop: true，极难查。
func _apply_loop(s: AudioStream, want_loop: bool) -> void:
	if not want_loop:
		return
	if s is AudioStreamWAV:
		var w := s as AudioStreamWAV
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		if w.loop_end <= 0:
			w.loop_end = w.data.size() / 2
	elif s is AudioStreamOggVorbis:
		(s as AudioStreamOggVorbis).loop = true
	elif s is AudioStreamMP3:
		(s as AudioStreamMP3).loop = true


# ════════════════════════════════════════════════ 占位音合成

## 按 tone 参数现场合成一段 16-bit 单声道 PCM。
## **每个 id 固定随机种子**：噪声部分可复现，两次运行听感一致（否则调试时"这次又是另一个声"）。
func _synth(id: StringName, tone: Dictionary) -> AudioStreamWAV:
	var synth: Dictionary = _dict(_cfg.get("synth", {}))
	var rate := int(synth.get("mix_rate", 22050))
	if rate <= 0:
		rate = 22050
	var freq := float(tone.get("freq", 440.0))
	var dur := maxf(0.01, float(tone.get("dur", 0.12)))
	var decay := float(tone.get("decay", 16.0))
	var noise := clampf(float(tone.get("noise", 0.0)), 0.0, 1.0)
	var shape := str(tone.get("shape", "sine"))
	var amp := clampf(float(tone.get("amp", 0.6)), 0.0, 1.0)
	var loop := bool(tone.get("loop", false))
	var n := int(round(dur * float(rate)))
	if n <= 0:
		return null
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(id))
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / float(rate)
		var env := 1.0 if loop else exp(-decay * t)
		var phase := TAU * freq * t
		var v := 0.0
		match shape:
			"square":
				v = 1.0 if sin(phase) >= 0.0 else -1.0
			"noise":
				v = 0.0
			_:
				v = sin(phase)
		if noise > 0.0:
			v = v * (1.0 - noise) + rng.randf_range(-1.0, 1.0) * noise
		data.encode_s16(i * 2, int(clampf(v * env * amp, -1.0, 1.0) * 32767.0))
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = rate
	s.stereo = false
	s.data = data
	if loop:
		s.loop_mode = AudioStreamWAV.LOOP_FORWARD
		s.loop_begin = 0
		s.loop_end = n
	else:
		s.loop_mode = AudioStreamWAV.LOOP_DISABLED
	return s


# ════════════════════════════════════════════════ 播放器池

## 取一个空闲播放器；全忙则丢**最旧**的那个（drop_oldest）。
## 池的意义就是「不加播放器」——加播放器正是爆音的起因（知识库第 10 课）。
func _pool_pick() -> AudioStreamPlayer:
	if _pool.is_empty():
		return null
	for p in _pool:
		if not p.playing:
			_pool_started_ms[_pool.find(p)] = Time.get_ticks_msec()
			return p
	var oldest := 0
	var oldest_ms := _pool_started_ms[0]
	for i in _pool.size():
		if _pool_started_ms[i] < oldest_ms:
			oldest_ms = _pool_started_ms[i]
			oldest = i
	_pool_started_ms[oldest] = Time.get_ticks_msec()
	return _pool[oldest]


# ════════════════════════════════════════════════ BGM 交叉淡化

## 旧轨淡出 out_s → 停 → 等 delay_s → 新轨淡入 in_s。
## 用**显式状态机**而不是 Tween：时序可断言（audio_test 直接读 phase 与 volume_db），
## 也不受 headless 下 Tween 行为差异影响。
func _process(delta: float) -> void:
	var cf: Dictionary = _dict(_cfg.get("crossfade", {}))
	var out_s := float(cf.get("out_s", 0.8))
	var delay_s := float(cf.get("delay_s", 0.3))
	var in_s := float(cf.get("in_s", 0.5))
	var cur := active_music_player()
	_phase_t += delta
	match _bgm_phase:
		PHASE_OUT:
			var k := clampf(_phase_t / maxf(0.01, out_s), 0.0, 1.0)
			cur.volume_db = lerpf(_bgm_from_db(), -60.0, k)
			if k >= 1.0:
				cur.stop()
				cur.volume_db = -60.0
				_bgm_phase = PHASE_GAP
				_phase_t = 0.0
		PHASE_GAP:
			if _phase_t >= delay_s:
				_start_fade_in()
		PHASE_IN:
			# 注意：淡入的是**现役**播放器。_start_fade_in 里已经翻过 A/B，
			# 所以此刻 active 才是刚起播的新轨（写 other 会去淡入那条已经停掉的旧轨）。
			var k2 := clampf(_phase_t / maxf(0.01, in_s), 0.0, 1.0)
			cur.volume_db = lerpf(-60.0, _bgm_target_db(), k2)
			if k2 >= 1.0:
				_bgm_current = _bgm_pending
				cur.volume_db = _bgm_target_db()
				_bgm_phase = PHASE_IDLE
				set_process(false)


## 首次播放走这里（没有旧轨可淡出）。
func _start_fade_in() -> void:
	_bgm_current = _bgm_pending
	_bgm_phase = PHASE_IN
	_phase_t = 0.0
	var entry: Variant = _entry_of(_bgm_table(), _bgm_current)
	if not (entry is Dictionary):
		_bgm_phase = PHASE_IDLE
		set_process(false)
		return
	var stream := _stream_for(_bgm_current, entry as Dictionary)
	if stream == null:
		_bgm_phase = PHASE_IDLE
		set_process(false)
		return
	_music_a_is_current = not _music_a_is_current
	var tgt := active_music_player()
	tgt.stream = stream
	tgt.volume_db = -60.0
	tgt.play()
	set_process(true)


## 淡出起点电平（= 换轨前旧轨的实际音量，避免从 0 开始突跳）。
func _bgm_from_db() -> float:
	return _bgm_target_db()


func _bgm_target_db() -> float:
	var entry: Variant = _entry_of(_bgm_table(), _bgm_current)
	if entry is Dictionary:
		return float((entry as Dictionary).get("volume_db", 0.0))
	return 0.0


# ════════════════════════════════════════════════ 杂项

func _bump(counter: Dictionary, id: StringName) -> void:
	counter[id] = int(counter.get(id, 0)) + 1


## 每个 id 只提醒一次：缺文件 / 配置错是「一次性事实」，
## 每帧重复 warn 会把 Output 淹掉（与日志纪律一致）。
func _warn_once(id: StringName, msg: String) -> void:
	if _warned.has(id):
		return
	_warned[id] = true
	push_warning("[audio] %s：%s" % [str(id), msg])
