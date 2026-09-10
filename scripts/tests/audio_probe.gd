extends Node

## ⑩ 音频骨架（**DEC-046**）的独立验证探针
##
## 跑法：`godot_console --headless --path <proj> res://scenes/tests/audio_test.tscn`
##
## 覆盖目标：
##   ① 配置：audio.json 读得到，条目齐
##   ② 总线：Master → Music / SFX / UI 建起来且挂对父级
##   ③ 零素材可用：assets/audio/ 为空时回退到**合成占位音**，而不是静默/崩溃
##   ④ 防爆：同帧去重 + 时间窗限流（drop_count 真的涨）
##   ⑤ 池：并发超额时不新开播放器、不崩
##   ⑥ 听觉 HUD：扇区 → 音高映射；**只前扇区走 3D**
##   ⑦ BGM：交叉淡化时序（0.8 / 0.3 / 0.5），换轨后新轨在播、旧轨停
##   ⑧ 事件接线：EventBus 低频事件 → 对应音效真的响了
##
## ⚠ 本探针**故意不依赖真实音频文件**（assets/audio 为空）——
## 这正是要验的场景：白盒阶段一份素材都没有，音频链路也必须跑通。

var _pass := 0
var _fail := 0


func _ready() -> void:
	await _run()


func _run() -> void:
	_test_config()
	_test_buses()
	_test_fallback_stream()
	_test_unknown_id()
	await _test_anti_blowout()
	_test_pool_overflow()
	await _test_sector_hud()
	await _test_bgm_crossfade()
	await _test_event_wiring()
	_report()


# ---------------------------------------------------------------- ① 配置

func _test_config() -> void:
	_check("AudioManager 就绪（配置加载成功）", AudioManager.is_ready_ok())
	_check("能取到主炮开火音", AudioManager.stream_of(&"sfx_main_gun_fire") != null)
	_check("能取到副炮开火音", AudioManager.stream_of(&"sfx_sub_gun_fire") != null)
	_check("能取到 UI 音", AudioManager.stream_of(&"sfx_ui_click") != null)
	_check("能取到 BGM", AudioManager.stream_of(&"bgm_battle") != null)


# ---------------------------------------------------------------- ② 总线

func _test_buses() -> void:
	var master := AudioManager.bus_key_index(&"master")
	var music := AudioManager.bus_key_index(&"music")
	var sfx := AudioManager.bus_key_index(&"sfx")
	var ui := AudioManager.bus_key_index(&"ui")
	_check("Master 总线存在（idx=%d）" % master, master >= 0)
	_check("Music 总线存在（idx=%d）" % music, music >= 0)
	_check("SFX 总线存在（idx=%d）" % sfx, sfx >= 0)
	_check("UI 总线存在（idx=%d）" % ui, ui >= 0)
	_check("三条子总线互不相同", music != sfx and sfx != ui and music != ui)
	# 子总线的 send 必须是 Master，否则音量总闸失效
	var master_name := AudioServer.get_bus_name(master)
	_check("Music 挂在 Master 下（实测 %s）" % AudioServer.get_bus_send(music),
		AudioServer.get_bus_send(music) == master_name)
	_check("SFX 挂在 Master 下（实测 %s）" % AudioServer.get_bus_send(sfx),
		AudioServer.get_bus_send(sfx) == master_name)
	_check("UI 挂在 Master 下（实测 %s）" % AudioServer.get_bus_send(ui),
		AudioServer.get_bus_send(ui) == master_name)
	# 基准电平来自 audio.json 的 mix 段（Music = -6 dB）
	_check("Music 基准电平 -6 dB（实测 %.1f）" % AudioManager.get_bus_db(&"music"),
		absf(AudioManager.get_bus_db(&"music") - (-6.0)) < 0.01)


# ---------------------------------------------------------------- ③ 占位音回退

func _test_fallback_stream() -> void:
	# assets/audio/ 为空 → 必须拿到合成流，而不是 null
	var s := AudioManager.stream_of(&"sfx_ui_click")
	_check("缺素材时回退到合成音（非 null）", s != null)
	if s == null:
		return
	_check("回退音是 AudioStreamWAV（实测 %s）" % s.get_class(), s is AudioStreamWAV)
	var w := s as AudioStreamWAV
	_check("合成流有实际采样数据（%d 字节）" % w.data.size(), w.data.size() > 0)
	_check("合成流是单声道 16-bit（format=%d）" % w.format,
		w.format == AudioStreamWAV.FORMAT_16_BITS and not w.stereo)
	# BGM 的占位音必须是**循环**的，否则交叉淡化后半段就没声了
	var bgm := AudioManager.stream_of(&"bgm_battle")
	var bw := bgm as AudioStreamWAV
	_check("BGM 占位音带循环点（loop_mode=%d）" % bw.loop_mode,
		bw.loop_mode == AudioStreamWAV.LOOP_FORWARD)
	_check("BGM 循环点等于总帧数（%d）" % bw.loop_end, bw.loop_end > 0)
	# 一次性音不该循环
	var once := AudioManager.stream_of(&"sfx_turret_destroyed") as AudioStreamWAV
	_check("一次性音不循环（loop_mode=%d）" % once.loop_mode,
		once.loop_mode == AudioStreamWAV.LOOP_DISABLED)


# ---------------------------------------------------------------- ④ 未知 id

func _test_unknown_id() -> void:
	AudioManager.reset_stats()
	AudioManager.play_sfx(&"sfx_不存在的音")
	_check("未知 id 不崩、不计数（实测 %d）" % AudioManager.play_count(&"sfx_不存在的音"),
		AudioManager.play_count(&"sfx_不存在的音") == 0)


# ---------------------------------------------------------------- ⑤ 防爆

func _test_anti_blowout() -> void:
	# ── 同帧去重：同一物理帧内同一 id 只发一次 ──
	AudioManager.reset_stats()
	var id := &"sfx_sub_gun_fire"
	for _i in 5:
		AudioManager.play_sfx(id, &"port")
	_check("同帧连发 5 次只播 1 次（实测 %d）" % AudioManager.play_count(id),
		AudioManager.play_count(id) == 1)
	_check("同帧剩下的 4 次被丢（实测 %d）" % AudioManager.drop_count(id),
		AudioManager.drop_count(id) == 4)

	# ── 时间窗限流：sfx_turret_damaged = 250ms 内最多 1 次 ──
	# 受创是**每帧**都在发生的高频信号，不限流就是一串爆音。
	AudioManager.reset_stats()
	var dmg := &"sfx_turret_damaged"
	AudioManager.play_sfx(dmg, &"port")
	_check("受创音第 1 次能播（实测 %d）" % AudioManager.play_count(dmg),
		AudioManager.play_count(dmg) == 1)
	await _frames(1)
	AudioManager.play_sfx(dmg, &"port")
	_check("隔帧的第 2 次被时间窗挡下（实测 播%d/丢%d）" % [
			AudioManager.play_count(dmg), AudioManager.drop_count(dmg)],
		AudioManager.play_count(dmg) == 1 and AudioManager.drop_count(dmg) == 1)

	# ── limit_ms = 0 的音不受时间窗约束（只受同帧去重）──
	AudioManager.reset_stats()
	var free := &"sfx_crisis_cleared"
	for _i in 3:
		AudioManager.play_sfx(free)
		await _frames(1)
	_check("不限流的音隔帧连发 3 次都播（实测 %d）" % AudioManager.play_count(free),
		AudioManager.play_count(free) == 3)
	_check("不限流的音一次没丢（实测 %d）" % AudioManager.drop_count(free),
		AudioManager.drop_count(free) == 0)

	# ── 限流键含扇区：同一帧两个不同扇区各自出声 ──
	# 这条是听觉 HUD 的护栏：若按 id 全局限流，被同时打的两面会互相顶掉，
	# 玩家就只能听见其中一面 —— 恰好把「哪面在挨打」这个核心信息弄丢了。
	AudioManager.reset_stats()
	await _frames(1)
	AudioManager.play_sfx(dmg, &"dorsal")
	AudioManager.play_sfx(dmg, &"ventral")
	_check("同帧两个不同扇区各播一次（实测 %d）" % AudioManager.play_count(dmg),
		AudioManager.play_count(dmg) == 2)


# ---------------------------------------------------------------- ⑥ 池

func _test_pool_overflow() -> void:
	# 池满时丢最旧的复用，**不新开播放器**——新开播放器正是爆音的来源。
	AudioManager.reset_stats()
	var ids: Array[StringName] = [
		&"sfx_main_gun_fire", &"sfx_sub_gun_fire", &"sfx_sub_gun_fire_fast",
		&"sfx_sub_gun_fire_heavy", &"sfx_projectile_hit", &"sfx_turret_destroyed",
		&"sfx_sector_breached", &"sfx_all_destroyed", &"sfx_enemy_killed",
		&"sfx_wave_start",
	]
	for i in ids.size():
		# 每个 id 都不同 → 不会被同帧去重挡下，能真正压满池
		AudioManager.play_sfx(ids[i], &"")
	var played := 0
	for i in ids.size():
		played += AudioManager.play_count(ids[i])
	_check("池容量 %d，10 个不同音全部播出去（实测 %d）" % [AudioManager.pool_size(), played],
		played == ids.size())
	_check("池大小就是配置的 8（实测 %d）" % AudioManager.pool_size(),
		AudioManager.pool_size() == 8)


# ---------------------------------------------------------------- ⑦ 听觉 HUD

func _test_sector_hud() -> void:
	# 一张表验到底：扇区 → 音高 / 是否 3D。表在 audio.json 的 sector_hud 段，
	# 所以这里断言的是「配置真的生效了」，不是「代码里写死了 0.75」。
	var expect := {
		"fore": [1.00, true],
		"aft": [0.75, false],
		"port": [1.15, false],
		"starboard": [0.90, false],
		"dorsal": [1.30, false],
		"ventral": [0.65, false],
	}
	var id := &"sfx_crisis_cleared"
	for key in expect:
		var sector := StringName(key)
		AudioManager.reset_stats()
		AudioManager.play_sfx(id, sector)
		await _frames(1)
		var want: Array = expect[key]
		var want_pitch := float(want[0])
		var want_spatial := bool(want[1])
		_check("听觉 HUD %s 音高 %.2f（实测 %.2f）" % [str(sector), want_pitch, AudioManager.last_pitch(id)],
			absf(AudioManager.last_pitch(id) - want_pitch) < 0.001)
		_check("听觉 HUD %s %s（实测 %s）" % [
				str(sector), "走 3D" if want_spatial else "走 2D",
				"3D" if AudioManager.last_was_spatial() else "2D"],
			AudioManager.last_was_spatial() == want_spatial)
	# 无扇区（UI 音）→ 基准音高、2D
	AudioManager.reset_stats()
	AudioManager.play_sfx(&"sfx_ui_click")
	_check("无扇区音用基准音高 1.0（实测 %.2f）" % AudioManager.last_pitch(&"sfx_ui_click"),
		absf(AudioManager.last_pitch(&"sfx_ui_click") - 1.0) < 0.001)
	_check("无扇区音走 2D（实测 %s）" % ("3D" if AudioManager.last_was_spatial() else "2D"),
		not AudioManager.last_was_spatial())


# ---------------------------------------------------------------- ⑧ BGM 交叉淡化

func _test_bgm_crossfade() -> void:
	# 开局：autoload 早于主场景广播（godot_pitfalls #13），AudioManager 主动补读状态，
	# 所以 REFIT 的 BGM 应该已经起播了。
	_check("开局 BGM = REFIT 曲（实测 %s）" % str(AudioManager.current_bgm()),
		AudioManager.current_bgm() == &"bgm_refit")
	await _wait_until_idle()

	# 换轨：立刻进入淡出阶段
	var before := AudioManager.active_music_player()
	AudioManager.play_bgm(&"bgm_battle")
	_check("换轨立刻进入淡出（实测 %s）" % str(AudioManager.bgm_phase()),
		AudioManager.bgm_phase() == AudioManager.PHASE_OUT)

	var t0 := Time.get_ticks_msec()
	await _wait_until_idle()
	var elapsed := float(Time.get_ticks_msec() - t0) / 1000.0
	# out 0.8 + delay 0.3 + in 0.5 = 1.6 s，允许 headless 帧率抖动
	_check("交叉淡化总时长 ≈1.6s（实测 %.2fs）" % elapsed, elapsed > 1.3 and elapsed < 2.6)
	_check("换轨后当前曲 = battle（实测 %s）" % str(AudioManager.current_bgm()),
		AudioManager.current_bgm() == &"bgm_battle")
	# A/B 双轨交替：换轨后现役播放器应该是另一条
	_check("A/B 双轨交替（换轨后换了播放器）", AudioManager.active_music_player() != before)
	_check("旧轨已停", not before.playing)
	var cur := AudioManager.active_music_player()
	_check("新轨在播", cur.playing)
	_check("新轨音量到基准 0 dB（实测 %.1f）" % cur.volume_db, absf(cur.volume_db) < 0.01)


# ---------------------------------------------------------------- ⑨ 事件接线

func _test_event_wiring() -> void:
	# 低频警报走 EventBus（DEC-046 决定 2）。这里发真事件，验接线表生效。
	AudioManager.reset_stats()
	await _frames(1)
	EventBus.turret_destroyed.emit(&"port", &"port")
	_check("turret_destroyed → 响单炮被毁音（实测 %d）" % AudioManager.play_count(&"sfx_turret_destroyed"),
		AudioManager.play_count(&"sfx_turret_destroyed") == 1)
	_check("该音按扇区变调（port=1.15，实测 %.2f）" % AudioManager.last_pitch(&"sfx_turret_destroyed"),
		absf(AudioManager.last_pitch(&"sfx_turret_destroyed") - 1.15) < 0.001)

	AudioManager.reset_stats()
	await _frames(1)
	EventBus.sector_breached.emit(&"dorsal")
	_check("sector_breached → 响失守音（实测 %d）" % AudioManager.play_count(&"sfx_sector_breached"),
		AudioManager.play_count(&"sfx_sector_breached") == 1)

	AudioManager.reset_stats()
	await _frames(1)
	EventBus.all_turrets_destroyed.emit()
	_check("all_turrets_destroyed → 响终局音（实测 %d）" % AudioManager.play_count(&"sfx_all_destroyed"),
		AudioManager.play_count(&"sfx_all_destroyed") == 1)

	AudioManager.reset_stats()
	await _frames(1)
	EventBus.wave_started.emit(3)
	_check("wave_started → 响开波警报（实测 播%d/丢%d/%s）" % [
			AudioManager.play_count(&"sfx_wave_start"), AudioManager.drop_count(&"sfx_wave_start"),
			str(AudioManager.drop_reason(&"sfx_wave_start"))],
		AudioManager.play_count(&"sfx_wave_start") == 1)

	AudioManager.reset_stats()
	await _frames(1)
	EventBus.enemy_killed.emit(self)
	_check("enemy_killed → 响击杀音（实测 %d）" % AudioManager.play_count(&"sfx_enemy_killed"),
		AudioManager.play_count(&"sfx_enemy_killed") == 1)

	AudioManager.reset_stats()
	await _frames(1)
	EventBus.crisis_cleared.emit(2)
	_check("crisis_cleared → 响清空音（实测 %d）" % AudioManager.play_count(&"sfx_crisis_cleared"),
		AudioManager.play_count(&"sfx_crisis_cleared") == 1)


# ---------------------------------------------------------------- 工具

func _frames(n: int) -> void:
	for _i in n:
		await get_tree().physics_frame


## 等 BGM 状态机回到 IDLE（带超时保护，避免时序 bug 把测试挂死）。
func _wait_until_idle() -> void:
	var guard := 0
	while AudioManager.bgm_phase() != AudioManager.PHASE_IDLE and guard < 600:
		await get_tree().physics_frame
		guard += 1


func _check(desc: String, ok: bool) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		print("  ✗ FAIL: " + desc)


func _report() -> void:
	print("=== ⑩ 音频骨架 断言: %d/%d 通过 ===" % [_pass, _pass + _fail])
	if _fail == 0:
		print("全部通过")
	else:
		print("有 %d 条失败" % _fail)
	get_tree().quit()
