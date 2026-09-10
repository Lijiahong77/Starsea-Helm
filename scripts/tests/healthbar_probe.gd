extends Node3D

## ⑪ ⑤ 敌人血量反馈（**B 血条 + C 本体染色**）的独立验证探针 · 2026-09-10
##
## 跑法：`godot_console --headless --path <proj> res://scenes/tests/healthbar_test.tscn`
##
## 覆盖目标：
##   ① 配置：HealthKit 真的读到 presentation.json 的 healthbar 段（不是走了兜底值）
##   ② 层号：TargetHealthBar 在 CanvasLayer 层 5（避开 RefitOverlay 的 10）
##   ③ 满血上限：setup 后 hp_max 是 hp 的快照，hp_ratio() 从 1 起算
##   ④ 难度缩放：scale_hp 同乘 hp 与 hp_max（否则血条比例会 > 1）
##   ⑤ 事件：enemy_damaged 带出正确的 hp / hp_max（含致死那一下）
##   ⑥ C 层：掉血 → 本色按比例变暗；满血不变色；**闪白不被染色吃掉**（⑪ 第一层的回归）
##   ⑦ B 层：接管 → 显示；受击 → 比例跟随；结束接管 → 淡出；目标被击杀 → 淡出 / 换目标
##
## ⚠ 与 feel_probe 同一套纪律：**手动步进**（直接调 advance），不等真实帧 ——
## 淡入淡出是时序，靠"跑几帧看看"断言不准；且 headless 下 `create_timer` 只在
## 让出主循环时才推进，同步 for 循环里根本不会触发（本探针刻意不依赖它）。

var _pass := 0
var _fail := 0
var _bar: TargetHealthBar

## 假的目标提供者返回什么。**模拟 bridge 的闭包**：接管结束 / 目标已死时返回 null。
var _provider_returns: Enemy = null
## 事件收集。
var _dmg_count := 0
var _last_dmg_hp := -1.0
var _last_dmg_max := -1.0


func _ready() -> void:
	_bar = TargetHealthBar.new()
	add_child(_bar)
	_bar.set_process(false)          # 全程手动步进
	_bar.target_provider = _provider
	EventBus.enemy_damaged.connect(_on_dmg)
	await _run()


func _run() -> void:
	_test_config()
	_test_layer()
	_test_hp_max()
	_test_scale_hp()
	_test_damage_event()
	_test_tint()
	_test_bar_visible_and_ratio()
	_test_bar_hides_on_release()
	_test_bar_switch_target()
	_report()


# ------------------------------------------------- ① 配置 / ② 层号

func _test_config() -> void:
	_check("HealthKit 真的读了 presentation.json（不是兜底值）", HealthKit.loaded_from_json())
	_check("总开关为开", HealthKit.enabled())
	var b := HealthKit.bar()
	_check("血条宽 > 0（%.0f px）" % float(b.get("width", 0.0)), float(b.get("width", 0.0)) > 0.0)
	_check("血条高 > 0（%.0f px）" % float(b.get("height", 0.0)), float(b.get("height", 0.0)) > 0.0)
	_check("淡入淡出时长 > 0（%.2f s）" % float(b.get("fade_time", 0.0)), float(b.get("fade_time", 0.0)) > 0.0)
	_check("低血阈值在 (0,1) 内（%.2f）" % float(b.get("low_ratio", -1.0)),
		float(b.get("low_ratio", -1.0)) > 0.0 and float(b.get("low_ratio", -1.0)) < 1.0)
	# C 层：满血必须是本色（否则"一进场就发暗"），空血必须落到暗色（否则染色没意义）
	var base := Color(1.0, 1.0, 1.0)
	_check("tint_color(满血) == 本色", HealthKit.tint_color(base, 1.0).is_equal_approx(base))
	_check("tint_color(空血) != 本色（%s）" % str(HealthKit.tint_color(base, 0.0)),
		not HealthKit.tint_color(base, 0.0).is_equal_approx(base))


func _test_layer() -> void:
	_check("TargetHealthBar 在 CanvasLayer 层 5（实测 %d，避开 RefitOverlay 的 10）" % _bar.layer,
		_bar.layer == 5)


# ------------------------------------------------- ③ 满血上限 / ④ 缩放

func _test_hp_max() -> void:
	var e := _make_enemy(Vector3(0, 0, 120), 100.0)
	_check("setup 后 hp_max 是 hp 的快照（hp=%.0f hp_max=%.0f）" % [e.hp, e.hp_max],
		is_equal_approx(e.hp, 100.0) and is_equal_approx(e.hp_max, 100.0))
	_check("满血时 hp_ratio() == 1（%.3f）" % e.hp_ratio(), is_equal_approx(e.hp_ratio(), 1.0))
	e.take_damage(25.0, &"main")
	_check("掉 25%% 后 hp_ratio() == 0.75（%.3f）" % e.hp_ratio(), absf(e.hp_ratio() - 0.75) < 0.001)
	e.queue_free()


func _test_scale_hp() -> void:
	var e := _make_enemy(Vector3(0, 0, 120), 100.0)
	e.scale_hp(1.5)
	_check("scale_hp 同乘 hp（%.0f）与 hp_max（%.0f）" % [e.hp, e.hp_max],
		is_equal_approx(e.hp, 150.0) and is_equal_approx(e.hp_max, 150.0))
	_check("缩放后 hp_ratio() 仍为 1（血条不会爆表，%.3f）" % e.hp_ratio(), is_equal_approx(e.hp_ratio(), 1.0))
	e.scale_hp(1.0)
	_check("scale = 1 不动数值（%.0f）" % e.hp, is_equal_approx(e.hp, 150.0))
	e.scale_hp(0.0)
	_check("scale <= 0 被忽略（防清零 / 除零，%.0f）" % e.hp, is_equal_approx(e.hp, 150.0))
	e.queue_free()


# ------------------------------------------------- ⑤ 受伤事件

func _test_damage_event() -> void:
	_dmg_count = 0
	_last_dmg_hp = -1.0
	_last_dmg_max = -1.0
	var e := _make_enemy(Vector3(0, 0, 120), 52.0)
	e.take_damage(12.0, &"main")
	_check("enemy_damaged 触发一次（实测 %d）" % _dmg_count, _dmg_count == 1)
	_check("事件带出 hp=40 / hp_max=52（实测 %.0f / %.0f）" % [_last_dmg_hp, _last_dmg_max],
		is_equal_approx(_last_dmg_hp, 40.0) and is_equal_approx(_last_dmg_max, 52.0))
	_check("事件里的 hp 与实体一致", is_equal_approx(_last_dmg_hp, e.hp))
	# 致死那一下也要发：血条要能看到它走到 0，再交给 enemy_killed 淡出
	e.take_damage(9999.0, &"main")
	_check("致死同样发 enemy_damaged（实测 %d 次）" % _dmg_count, _dmg_count == 2)
	_check("致死时事件里的 hp 归零（%.1f）" % _last_dmg_hp, is_equal_approx(_last_dmg_hp, 0.0))


# ------------------------------------------------- ⑥ C 层：本体随血量变暗

func _test_tint() -> void:
	var e := _make_enemy(Vector3(0, 0, 120), 100.0)
	var full := e.body_color()
	_check("满血时本色是型号原色（%s）" % str(full), full.r > 0.8 and full.g < 0.5)

	e.take_damage(50.0, &"main")
	# 必须等闪白结束才看得到染色 —— 闪白此刻正占着材质（这正是"顺序很重要"的地方）。
	e.advance(FeelKit.flash_time() * 2.0)
	var expect := HealthKit.tint_color(full, 0.5)
	_check("半血时本色 = tint_color(原色, 0.5)（实测 %s / 期望 %s）" % [str(e.body_color()), str(expect)],
		e.body_color().is_equal_approx(expect))
	_check("半血确实比满血暗（v %.3f < %.3f）" % [e.body_color().v, full.v], e.body_color().v < full.v)

	e.take_damage(45.0, &"main")     # 剩 5%
	e.advance(FeelKit.flash_time() * 2.0)
	var dim_expect := HealthKit.tint_color(full, 0.05)
	_check("濒死（5%% 血）本色 ≈ tint_color(原色, 0.05)（实测 %s）" % str(e.body_color()),
		e.body_color().is_equal_approx(dim_expect))
	_check("濒死比半血更暗（v %.3f < %.3f）" % [e.body_color().v, expect.v], e.body_color().v < expect.v)

	# 回归：C 层不能把 ⑪ 第一层的闪白吃掉
	e.advance(FeelKit.flash_time() * 2.0)    # 先清掉闪白冷却
	e.take_damage(1.0, &"main")
	_check("染色后闪白仍正常（实测 %s）" % str(e.body_color()),
		e.body_color().is_equal_approx(FeelKit.flash_color()))
	e.queue_free()


# ------------------------------------------------- ⑦ B 层：屏幕上方目标血条

func _test_bar_visible_and_ratio() -> void:
	var e := _make_hover_enemy(Vector3(0, 0, 40), 100.0, &"interceptor")
	_provider_returns = e
	_check("接管前不显示（零噪音）", not _bar.is_showing())

	EventBus.turret_takeover_started.emit(&"main")
	_bar.set_process(false)         # 上面那句打开了 _process，立刻收回，保持手动步进
	_step(0.4)
	_check("接管 + 有目标 → 血条显示", _bar.is_showing())
	_check("初始比例 = 1.0（%.3f）" % _bar.bar_ratio(), absf(_bar.bar_ratio() - 1.0) < 0.001)
	_check("填充宽 = 条宽（%.1f / %.1f）" % [_bar.fill_width(), _bar.bar_width()],
		absf(_bar.fill_width() - _bar.bar_width()) < 0.01)
	_check("标题带敌人中文名（'%s'）" % _bar.title_text(), _bar.title_text().contains("战机"))
	_check("数字显示 100 / 100（'%s'）" % _bar.hp_text(), _bar.hp_text().contains("100"))

	e.take_damage(60.0, &"main")
	_check("受击后比例 0.4（%.3f）" % _bar.bar_ratio(), absf(_bar.bar_ratio() - 0.4) < 0.001)
	_check("填充宽 = 0.4 × 条宽（%.1f）" % _bar.fill_width(), absf(_bar.fill_width() - 0.4 * _bar.bar_width()) < 0.01)
	_check("数字更新为 40 / 100（'%s'）" % _bar.hp_text(), _bar.hp_text().contains("40"))


func _test_bar_hides_on_release() -> void:
	EventBus.turret_takeover_ended.emit(&"main")
	_bar.set_process(false)
	_provider_returns = null        # bridge 的闭包在接管结束后返回 null
	_step(0.4)
	_check("结束接管 → 血条淡出隐藏", not _bar.is_showing())
	_check("淡出后 alpha 归零（%.3f）" % _bar.alpha(), _bar.alpha() <= 0.001)


func _test_bar_switch_target() -> void:
	# 目标被击杀 → 丢引用 → 淡出（真实 provider 走 acquire_target()，已死的敌人不会被选中）
	var e := _make_hover_enemy(Vector3(0, 0, 40), 100.0, &"interceptor")
	_provider_returns = e
	EventBus.turret_takeover_started.emit(&"main")
	_bar.set_process(false)
	_step(0.4)
	_check("（换目标用例）血条回到显示", _bar.is_showing())

	e.take_damage(9999.0, &"main")
	_check("目标被击杀后立刻丢引用", _bar.target() == null)
	_provider_returns = null
	_step(0.4)
	_check("目标死后无其它敌人 → 血条淡出", not _bar.is_showing())

	# 立刻来了新敌人 → 血条改显示新目标（"打完一个接下一个"是自然发生的，无需特判）
	var e2 := _make_hover_enemy(Vector3(0, 0, 45), 52.0, &"bomber")
	_provider_returns = e2
	EventBus.turret_takeover_started.emit(&"main")
	_bar.set_process(false)
	_step(0.4)
	_check("新目标 → 血条显示轰炸机、数字 52 / 52（'%s' / '%s'）" % [_bar.title_text(), _bar.hp_text()],
		_bar.is_showing() and _bar.title_text().contains("轰炸机") and _bar.hp_text().contains("52"))
	_check("新目标比例 = 1.0（%.3f）" % _bar.bar_ratio(), absf(_bar.bar_ratio() - 1.0) < 0.001)


# ------------------------------------------------- 工厂 / 工具

## 假的目标提供者。**模拟 bridge_whitebox 注入的闭包**：
## 接管中 + 有目标才返回，否则 null。
func _provider() -> Enemy:
	return _provider_returns


func _on_dmg(_enemy: Node, _amount: float, hp: float, hp_max: float) -> void:
	_dmg_count += 1
	_last_dmg_hp = hp
	_last_dmg_max = hp_max


## 造一个敌人。attack_range = 50（与 enemies.json 同值），dps = 0
## —— 本探针只验血量反馈，不要让敌人反过来啃炮塔。
func _make_enemy(pos: Vector3, hp: float, type_id: StringName = &"interceptor") -> Enemy:
	var e := Enemy.new()
	add_child(e)
	e.setup(type_id, pos, Vector3.ZERO, {
		"hp": hp, "speed": 10.0, "size": 6.0, "dps": 0.0, "attack_range": 50.0,
	})
	return e


## 造一个**已悬停**的敌人（`acquire_target()` 要求 is_hovering()）。
## 直接喂一个极小 delta 让 advance 跨进攻击距离即可 —— 不依赖真实帧。
func _make_hover_enemy(pos: Vector3, hp: float, type_id: StringName) -> Enemy:
	var e := _make_enemy(pos, hp, type_id)
	e.advance(0.0001)
	return e


## 手动喂 time 秒（60fps 步长）。血条的淡入淡出与时序有关，必须确定性推进。
func _step(seconds: float) -> void:
	var step := 1.0 / 60.0
	var t := 0.0
	while t < seconds:
		_bar.advance(step)
		t += step


func _check(desc: String, ok: bool) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		print("  ✗ FAIL: " + desc)


func _report() -> void:
	print("=== ⑪ ⑤ 敌人血量反馈（B+C）断言: %d/%d 通过 ===" % [_pass, _pass + _fail])
	if _fail == 0:
		print("全部通过")
	else:
		print("有 %d 条失败" % _fail)
	get_tree().quit()
