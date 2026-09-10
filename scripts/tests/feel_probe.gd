extends Node3D

## ⑪ Game Feel 第一层（**相机反馈 + 命中闪白**）的独立验证探针 · 2026-09-10 · DEC-047
##
## 跑法：`godot_console --headless --path <proj> res://scenes/tests/feel_test.tscn`
##
## 覆盖目标：
##   ① 配置：presentation.json 的 feel 段读得到，且**不是**走了代码兜底值
##   ② 接线表：GameFeel 订阅的 5 个事件键在 feel.events 里都存在（防"键名写错 → 静默无反馈"）
##   ③ 未知事件：返回零反馈，不崩（把静默失败变成可观测）
##   ④ 推镜：触发 → 收窄 → 两段走完**精确归位**、不再活跃
##   ⑤ 震屏：触发 → 有位移 → 全程不超上限 → **精确归零**
##   ⑥ 总闸：master_scale=0 时全部静默
##   ⑦ 让位：L3 锁定期 GameFeel 不接手
##   ⑧ 敌人闪白：受击闪 → 到期还原（⑪ ⑤ 起还原到「按血量染过色的静止色」）；连续受击变闪烁而非常白；致死转红且不被还原
##   ⑨ 炮塔闪白：闪 → 还原成**型号色**（不是写死的灰）；被毁后颜色不被冷却擦回；restore 清冷却
##
## ⚠ 本探针**手动步进**（直接调 advance）而不是等真实帧：
## 手感是一套时序，靠"跑几帧看看"断言不准（帧率一变期望值就变）。
## 手动喂 delta 才能算出确定的期望值 —— 也才验得出"有没有精确归位"这个真正的坑。

var _pass := 0
var _fail := 0
var _cam: Camera3D
var _feel: GameFeel


func _ready() -> void:
	_cam = Camera3D.new()
	_cam.name = "TestCam"
	_cam.position = Vector3(0, 1.6, 0)
	_cam.fov = 70.0
	add_child(_cam)

	_feel = GameFeel.new()
	_feel.name = "GameFeel"
	add_child(_feel)
	_feel.setup(_cam, self)

	await _run()


func _run() -> void:
	_test_config()
	_test_unknown_event()
	_test_zoom()
	_test_shake()
	_test_master_mute()
	_test_lock_yield()
	_test_enemy_flash()
	_test_enemy_flash_cooldown()
	await _test_enemy_death()
	_test_turret_flash()
	_test_turret_destroyed_keeps_color()
	_report()


# ------------------------------------------------- ① 配置 / ② 接线表

func _test_config() -> void:
	# 兜底值的 events 是空字典 —— 所以"有 player_fire 键"就证明真的读了 JSON。
	_check("FeelKit 读到 presentation.json 的 feel 段（不是兜底值）", FeelKit.has_event("player_fire"))
	_check("震屏时长 > 0（%.3f s）" % FeelKit.shake_time(), FeelKit.shake_time() > 0.0)
	_check("震屏偏移上限 > 0（%.3f m）" % FeelKit.shake_max(), FeelKit.shake_max() > 0.0)
	_check("推镜两段时长都 > 0（%.2f / %.2f s）" % [FeelKit.zoom_in(), FeelKit.zoom_out()],
		FeelKit.zoom_in() > 0.0 and FeelKit.zoom_out() > 0.0)
	_check("闪白时长 > 0（%.3f s）" % FeelKit.flash_time(), FeelKit.flash_time() > 0.0)
	# 提亮必须靠"分量 > 1"（StandardMaterial3D 的 albedo > 1 会一并抬高自发光）。
	_check("闪白颜色分量 > 1（实测 %s）" % str(FeelKit.flash_color()), FeelKit.flash_color().r > 1.0)
	_check("总闸默认 1.0（实测 %.2f）" % FeelKit.master(), absf(FeelKit.master() - 1.0) < 0.001)
	# 震屏频率必须远低于帧率一半，否则正弦采样混叠成慢晃（JSON 里有注释说明）。
	_check("震屏频率在安全区（%.1f Hz < 20）" % FeelKit.shake_freq(), FeelKit.shake_freq() < 20.0)

	# GameFeel 订阅的每一个键都必须在接线表里 —— 这是"静默无反馈"的第一道防线。
	for k in ["player_fire", "enemy_killed", "turret_damaged", "turret_destroyed", "sector_breached"]:
		_check("feel.events 有键 '%s'" % k, FeelKit.has_event(k))

	# 每个键都得给出至少一种反馈，否则订阅了也等于没接。
	for k in ["player_fire", "turret_destroyed", "sector_breached"]:
		var fb := FeelKit.feedback(k)
		_check("'%s' 至少给一种反馈（shake=%.3f zoom=%.2f）" % [k, float(fb["shake"]), float(fb["zoom"])],
			float(fb["shake"]) > 0.0 or float(fb["zoom"]) > 0.0)


# ------------------------------------------------- ③ 未知事件

func _test_unknown_event() -> void:
	var fb := FeelKit.feedback("no_such_event_key")
	_check("未知事件返回零反馈而不是崩（shake=%.2f zoom=%.2f）" % [float(fb["shake"]), float(fb["zoom"])],
		float(fb["shake"]) == 0.0 and float(fb["zoom"]) == 0.0)


# ------------------------------------------------- ④ 推镜

func _test_zoom() -> void:
	_reset_feel()
	EventBus.turret_fired.emit(&"main")
	_feel.set_process(false)     # 之后全程手动步进，排除 Godot 自身 _process 的额外推进
	_check("player_fire 触发推镜（zoom=%.2f°）" % _feel.zoom_deg(), _feel.zoom_deg() > 0.0)
	_check("推镜进入活跃态", _feel.is_active())

	_feel.advance(FeelKit.zoom_in() * 0.5)
	var mid := _cam.fov
	_check("推镜中视场角确实收窄了（%.3f < 基准 %.3f）" % [mid, _feel.fov_base()], mid < _feel.fov_base())

	_feel.advance(FeelKit.zoom_in() + FeelKit.zoom_out() + 0.05)
	_check("推镜结束后视场角精确归位（实测 %.6f）" % _cam.fov, absf(_cam.fov - _feel.fov_base()) < 0.000001)
	_check("推镜结束后不再活跃（不空转 _process）", not _feel.is_active())


# ------------------------------------------------- ⑤ 震屏

func _test_shake() -> void:
	_reset_feel()
	EventBus.turret_destroyed.emit(&"port1", &"port")
	_feel.set_process(false)
	_check("turret_destroyed 触发震屏（amp=%.4f m）" % _feel.shake_amp(), _feel.shake_amp() > 0.0)

	var cap := FeelKit.shake_max()
	var peak := 0.0
	var over := false
	var step := 1.0 / 60.0
	var elapsed := 0.0
	while elapsed < FeelKit.shake_time() * 1.5:
		_feel.advance(step)
		elapsed += step
		var m := _feel.offset_now().length()
		peak = maxf(peak, m)
		if m > cap + 0.000001:
			over = true
	_check("震屏全程偏移不超旋钮上限 %.3f m（峰值实测 %.4f）" % [cap, peak], not over)
	_check("震屏确实产生了位移（峰值 %.4f > 0）" % peak, peak > 0.0)
	_check("震屏结束后偏移精确归零（实测 %.8f m）" % _feel.offset_now().length(),
		_feel.offset_now().length() < 0.0000001)
	_check("震屏结束后不再活跃", not _feel.is_active())
	# 二次触发要取 max 而不是累加 —— 否则"一路被啃"会在几帧内顶到上限并卡住。
	_reset_feel()
	EventBus.turret_damaged.emit(&"port1", 1.0, &"bomber")
	_feel.set_process(false)
	var a1 := _feel.shake_amp()
	for i in 10:
		EventBus.turret_damaged.emit(&"port1", 1.0, &"bomber")
		_feel.set_process(false)
		_feel.advance(step)
	var a2 := _feel.shake_amp()
	_check("连续受击时振幅取 max 不累加（%.4f -> %.4f，上限 %.3f）" % [a1, a2, FeelKit.shake_max()],
		a2 <= FeelKit.shake_max() + 0.000001)


# ------------------------------------------------- ⑥ 总闸

func _test_master_mute() -> void:
	_reset_feel()
	var cfg := FeelKit.cfg()
	var old := float(cfg.get("master_scale", 1.0))
	cfg["master_scale"] = 0.0
	EventBus.turret_destroyed.emit(&"port1", &"port")
	_feel.set_process(false)
	_check("总闸 = 0 时反馈完全静默", not _feel.is_active() and _feel.shake_amp() <= 0.0)
	_check("总闸 = 0 被识别为静音", _feel.master_is_muted())

	cfg["master_scale"] = old
	EventBus.turret_destroyed.emit(&"port1", &"port")
	_feel.set_process(false)
	_check("总闸恢复后反馈回来", _feel.is_active())
	_reset_feel()


# ------------------------------------------------- ⑦ 让位

func _test_lock_yield() -> void:
	_reset_feel()
	_feel.lock_check = func() -> bool: return true
	EventBus.turret_destroyed.emit(&"port1", &"port")
	_feel.set_process(false)
	_check("L3 锁定期 GameFeel 让位（不接手反馈）", not _feel.is_active())
	_check("锁定期 is_locked_out() 为真", _feel.is_locked_out())
	_feel.lock_check = Callable()
	_check("锁解除后 is_locked_out() 为假", not _feel.is_locked_out())


# ------------------------------------------------- ⑧ 敌人闪白

func _test_enemy_flash() -> void:
	var e := _make_enemy()
	var base := e.body_color()
	var fc := FeelKit.flash_color()
	_check("敌人有初始本色（%s）" % str(base), not base.is_equal_approx(fc))

	e.take_damage(1.0, &"main")
	_check("敌人受击闪白（实测 %s）" % str(e.body_color()), e.body_color().is_equal_approx(fc))

	e.advance(FeelKit.flash_time() * 0.5)
	_check("闪白未到期不还原", e.body_color().is_equal_approx(fc))

	e.advance(FeelKit.flash_time() * 0.6)
	# ⚠ 2026-09-10（⑪ ⑤ 上线后）：静止色不再是「满血本色」，而是**按血量染过色的本色**
	# —— 敌人掉血会让本体变暗（C 层）。这里只掉了 1/100 血，视觉上几乎等于本色，
	# 但断言必须按新语义写：测的是代码的行为，不是旧版本的记忆。
	var rest := HealthKit.tint_color(base, e.hp_ratio())
	_check("闪白到期还原成**当前血量对应的静止色**（实测 %s / 期望 %s）" % [str(e.body_color()), str(rest)],
		e.body_color().is_equal_approx(rest))
	e.queue_free()


func _test_enemy_flash_cooldown() -> void:
	var e := _make_enemy()
	var fc := FeelKit.flash_color()
	var on_frames := 0
	var saw_off := false
	var step := 1.0 / 60.0
	for i in 60:
		e.take_damage(0.01, &"main")     # 模拟"每帧都在挨打"
		e.advance(step)
		if e.body_color().is_equal_approx(fc):
			on_frames += 1
		else:
			saw_off = true
	_check("持续受击变成闪烁而非常白（白 %d/60 帧，出现过非白=%s）" % [on_frames, str(saw_off)],
		on_frames > 0 and on_frames < 55 and saw_off)
	e.queue_free()


func _test_enemy_death() -> void:
	var e := _make_enemy()
	var fc := FeelKit.flash_color()
	e.take_damage(9999.0, &"main")
	var c := e.body_color()
	_check("致死转死亡闪红而不是闪白（实测 %s）" % str(c),
		c.r > 0.9 and c.g < 0.6 and not c.is_equal_approx(fc))
	_check("致死 hp 归零（实测 %.1f）" % e.hp, e.hp <= 0.0)
	await get_tree().create_timer(0.4).timeout
	_check("死亡后节点被释放", not is_instance_valid(e) or e.is_queued_for_deletion())


# ------------------------------------------------- ⑨ 炮塔闪白

func _test_turret_flash() -> void:
	var t := _make_turret()
	var base := t.body_color()
	var fc := FeelKit.flash_color()

	t.take_damage(1.0, &"bomber")
	_check("炮塔受击闪白（实测 %s）" % str(t.body_color()), t.body_color().is_equal_approx(fc))

	t.advance(FeelKit.flash_time() * 1.1)
	_check("炮塔闪白到期还原成**型号色**（实测 %s，期望 %s）" % [str(t.body_color()), str(base)],
		t.body_color().is_equal_approx(base))

	# 每波回满必须清掉闪白冷却，否则下一波开局会出现"挨打却不闪"的哑火窗口。
	t.take_damage(1.0, &"bomber")
	t.restore()
	_check("restore() 清掉闪白状态（实测 %s）" % str(t.body_color()), t.body_color().is_equal_approx(base))
	t.take_damage(1.0, &"bomber")
	_check("restore() 之后能立刻再闪（不留冷却）", t.body_color().is_equal_approx(fc))
	t.queue_free()


func _test_turret_destroyed_keeps_color() -> void:
	var t := _make_turret()
	t.take_damage(1.0, &"bomber")       # 先进入闪白
	t.take_damage(9999.0, &"bomber")    # 再被打死
	_check("被毁标志为真", t.destroyed)
	var d := t.body_color()
	_check("被毁后是暗红（实测 %s）" % str(d), d.r < 0.35 and d.g < 0.2)
	t.advance(FeelKit.flash_time() * 5.0)
	_check("被毁后闪白冷却不会把颜色擦回型号色（实测 %s）" % str(t.body_color()),
		t.body_color().is_equal_approx(d))
	t.queue_free()


# ------------------------------------------------- 工厂 / 工具

func _make_enemy() -> Enemy:
	var e := Enemy.new()
	add_child(e)
	e.setup(&"interceptor", Vector3(0, 0, 120), Vector3.ZERO, {
		"hp": 100.0, "speed": 10.0, "size": 6.0, "dps": 0.0, "attack_range": 50.0,
	})
	return e


func _make_turret() -> Turret:
	var t := Turret.new()
	add_child(t)
	t.configure({
		"id": &"port1", "sector": &"port", "hp": 80.0,
		"visual_size": [0.4, 0.4, 0.8], "visual_color": [0.40, 0.45, 0.50],
		"mount": [0, 1.5, 0],
	})
	t.snap_to()
	return t


## 把 GameFeel 清干净：走完当前反馈 + 关掉自动 _process，让每段测试从同一状态起跑。
func _reset_feel() -> void:
	_feel.lock_check = Callable()
	_feel.set_process(false)
	# 推进远超任何反馈的时长，确保上一段完全结束
	for i in 80:
		_feel.advance(1.0 / 60.0)


func _check(desc: String, ok: bool) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		print("  ✗ FAIL: " + desc)


func _report() -> void:
	print("=== ⑪ Game Feel 断言: %d/%d 通过 ===" % [_pass, _pass + _fail])
	if _fail == 0:
		print("全部通过")
	else:
		print("有 %d 条失败" % _fail)
	get_tree().quit()
