extends Node3D

## 第⑨步「波次调度与难度曲线」的独立验证场景。
## 依据协作约定第 4 条：复杂功能先建独立测试场景跑通，再搬进主场景。
##
## 验证七件事：
## ① `compose()` 难度曲线：首波 = base_count 且全是 interceptor；每波 +count_growth；
##    bomber 从 bomber_start_crisis 起才出现；数量封顶在 max_count
## ② 进 BATTLE → 自动开波，生成数 == compose 的总数（波次真的驱动了生成）
## ③ 清空 → crisis_cleared +1 → 状态自动回 REFIT（bible 01 状态图）
## ④ 危机递增：连打两波，wave_index / 总数 / 危机数都对得上
## ⑤ E/R 调试生成的敌人**不计入波次**（否则按几下 E 本波永远清不空）
## ⑥ 离开 BATTLE 会清掉残留敌人（否则反复按 B = 无限续命）
## ⑦ RESULT 后波次编号归零（bible：重打同一艘船，从第 1 危机重新数）
##
## ⚠ 依赖 EventBus / GameStateManager autoload，只能在**完整场景运行路径**下跑
##   （`--script` 模式不实例化 autoload）。
##
## **推进方式**：敌人不需要真飞过来 —— 本测试只关心「生成 / 清空 / 计数」，
## 直接把敌人打死即可，所以 EnemySystem 的 _physics_process 关掉、不移动。
## WaveSystem 的 _physics_process **保持开启**，让清空判定走真实路径
## （关掉它再手动调就没有验证意义了）。

const WAVE_DATA_PATH := "res://data/waves.json"

var _pass := 0
var _fail := 0
var _wave_started: Array[int] = []
var _crisis_cleared: Array[int] = []


func _ready() -> void:
	EventBus.wave_started.connect(func(i: int) -> void: _wave_started.append(i))
	EventBus.crisis_cleared.connect(func(i: int) -> void: _crisis_cleared.append(i))

	await get_tree().process_frame
	var ws := $WaveSystem as WaveSystem
	var es := $EnemySystem as EnemySystem
	print("=== ⑨ 波次调度 · 独立验证 ===")
	if ws == null or es == null:
		push_error("测试场景缺少 WaveSystem / EnemySystem 节点")
		return
	# 敌人不移动：本测试只测调度，不测飞行。WaveSystem 的推进保持开启。
	es.set_physics_process(false)

	var cfg := _wave_cfg()
	_test_compose_curve(ws, cfg)
	_test_wave_start(ws, es, cfg)
	await _test_clear_to_refit(ws)
	# 阶段之间必须清场：敌人是被 call_deferred queue_free 的，不等等的话
	# 上一波的**尸体**还挂在 EnemySystem 的计数里，下一波的「场上有几只」断言
	# 会凭空多出一整个波次（实测过：6+1 断言成 12）。
	await _clear_field()
	await _test_second_crisis(ws, cfg)
	await _clear_field()
	await _test_debug_spawn_not_counted(ws, es)
	await _clear_field()
	await _test_abort_clears_field(ws, es)
	await _test_result_resets_index(ws)

	print("=== 结果：通过 %d / 失败 %d ===" % [_pass, _fail])
	if _fail > 0:
		push_error("存在 %d 条失败断言，见上方 NG 行" % _fail)
	get_tree().quit()


## ① 难度曲线（纯函数，不用真生成）。
func _test_compose_curve(ws: WaveSystem, cfg: Dictionary) -> void:
	var base := float(cfg.get("base_count", 4.0))
	var growth := float(cfg.get("count_growth", 1.0))
	var max_c := float(cfg.get("max_count", 20.0))
	var b_start := float(cfg.get("bomber_start_crisis", 4.0))

	var c1 := ws.compose(1)
	_check("第 1 波总数 = base_count = %.0f（实测 %d）" % [base, int(c1["total"])],
		int(c1["total"]) == int(base))
	_check("第 1 波全是 interceptor（bomber 实测 %d）" % int(c1["bomber"]),
		int(c1["bomber"]) == 0)

	var c2 := ws.compose(2)
	_check("第 2 波总数 = base + growth = %.0f（实测 %d）" % [base + growth, int(c2["total"])],
		int(c2["total"]) == int(base + growth))

	var c_before := ws.compose(int(b_start) - 1)
	_check("第 %.0f 波（bomber 起始前一波）仍无 bomber（实测 %d）" % [
		b_start - 1.0, int(c_before["bomber"])], int(c_before["bomber"]) == 0)
	var c_at := ws.compose(int(b_start))
	_check("第 %.0f 波起出现 bomber（实测 %d）" % [b_start, int(c_at["bomber"])],
		int(c_at["bomber"]) >= 1)

	var c_far := ws.compose(50)
	_check("数量封顶在 max_count = %.0f（实测 %d）" % [max_c, int(c_far["total"])],
		int(c_far["total"]) == int(max_c))

	var sum_ok := true
	for i in range(1, 31):
		var c := ws.compose(i)
		if int(c["interceptor"]) + int(c["bomber"]) != int(c["total"]):
			sum_ok = false
	_check("1–30 波：interceptor + bomber 恒等于总数", sum_ok)


## ② 进 BATTLE → 自动开波并生成整波。
func _test_wave_start(ws: WaveSystem, es: EnemySystem, cfg: Dictionary) -> void:
	var base := int(float(cfg.get("base_count", 4.0)))
	GameStateManager.change_state(GameStateManager.State.BATTLE)
	_check("wave_started 已发出（第 %s 波）" % str(_wave_started), _wave_started.size() >= 1)
	_check("wave_index == 1（实测 %d）" % ws.wave_index, ws.wave_index == 1)
	_check("本波总数 == %d（实测 %d）" % [base, ws.total()], ws.total() == base)
	_check("剩余 == 总数 == %d（实测 %d）" % [base, ws.remaining()], ws.remaining() == base)
	_check("EnemySystem 真的生成了 %d 只（实测 %d）" % [base, es.enemy_count()],
		es.enemy_count() == base)


## ③ 杀光 → crisis_cleared +1 → 自动回 REFIT。
func _test_clear_to_refit(ws: WaveSystem) -> void:
	_kill_all()
	# WaveSystem 的清空判定在 _physics_process 里 —— 等一个物理帧走真实路径，
	# 而不是手动调私有方法（那样测的就不是真实链路了）。
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check("清空后回到 REFIT（实测 %s）" % GameStateManager.state_name(),
		GameStateManager.is_refit())
	_check("crisis_cleared == 1（实测 %d）" % ws.crisis_cleared, ws.crisis_cleared == 1)
	_check("crisis_cleared 信号带了正确的波号（实测 %s）" % str(_crisis_cleared),
		_crisis_cleared.size() == 1 and _crisis_cleared[0] == 1)


## ④ 第二波：编号与数量都递增。
func _test_second_crisis(ws: WaveSystem, cfg: Dictionary) -> void:
	var base := int(float(cfg.get("base_count", 4.0)))
	var growth := int(float(cfg.get("count_growth", 1.0)))
	GameStateManager.change_state(GameStateManager.State.BATTLE)
	_check("第 2 波 wave_index == 2（实测 %d）" % ws.wave_index, ws.wave_index == 2)
	_check("第 2 波总数 == %d（实测 %d）" % [base + growth, ws.total()],
		ws.total() == base + growth)
	_kill_all()
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check("连清两波后 crisis_cleared == 2（实测 %d）" % ws.crisis_cleared,
		ws.crisis_cleared == 2)


## ⑤ 调试生成的敌人不计入波次 —— 这是 WaveSystem 自存名单而非用 enemy_count() 的理由。
## **关键**：只杀波次内的敌人，**故意留着手动 spawn 那只**，本波仍须判定清空。
## （若改成杀光所有，那只调试敌人也死了，就测不出"不计入"这件事。）
func _test_debug_spawn_not_counted(ws: WaveSystem, es: EnemySystem) -> void:
	GameStateManager.change_state(GameStateManager.State.BATTLE)
	var wave_total := ws.total()
	var dbg := es.spawn_one(&"interceptor")   # 模拟主场景按 E
	_check("手动 spawn 后 remaining 不变（仍 %d，实测 %d）" % [wave_total, ws.remaining()],
		ws.remaining() == wave_total)
	for e in get_tree().get_nodes_in_group(Projectile.ENEMY_GROUP):
		if e is Enemy and e != dbg and not (e as Enemy).is_dead():
			(e as Enemy).take_damage(99999.0, &"test")
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check("残留调试敌人不影响清空（状态 %s）" % GameStateManager.state_name(),
		GameStateManager.is_refit())


## ⑥ 离开 BATTLE 清场：不清就会堆积 + 反复按 B 无限续命。
func _test_abort_clears_field(ws: WaveSystem, es: EnemySystem) -> void:
	var before := ws.crisis_cleared
	GameStateManager.change_state(GameStateManager.State.BATTLE)
	var n := ws.total()
	_check("开波后场上恰好 %d 只（实测 %d）" % [n, es.enemy_count()],
		es.enemy_count() == n)
	GameStateManager.change_state(GameStateManager.State.REFIT)
	# queue_free 是延迟的，等两帧让树更新。
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check("收战后场上清空（实测 %d 只）" % es.enemy_count(), es.enemy_count() == 0)
	_check("收战**不**计入危机数（实测 %d，收战前 %d）" % [ws.crisis_cleared, before],
		ws.crisis_cleared == before)


## ⑦ RESULT 后波次编号归零（重打从第 1 危机开始）。
func _test_result_resets_index(ws: WaveSystem) -> void:
	GameStateManager.change_state(GameStateManager.State.BATTLE)
	GameStateManager.change_state(GameStateManager.State.RESULT)
	_check("进入 RESULT 后 wave_index 归零（实测 %d）" % ws.wave_index, ws.wave_index == 0)
	GameStateManager.change_state(GameStateManager.State.REFIT)
	GameStateManager.change_state(GameStateManager.State.BATTLE)
	_check("重打时从第 1 危机开始（实测 %d）" % ws.wave_index, ws.wave_index == 1)


# ── 工具 ────────────────────────────────────────────

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("   OK  %s" % label)
	else:
		_fail += 1
		print("   NG  %s" % label)


## 打死场上**所有**敌人（含调试生成的）。
func _kill_all() -> void:
	for e in get_tree().get_nodes_in_group(Projectile.ENEMY_GROUP):
		if e is Enemy and not (e as Enemy).is_dead():
			(e as Enemy).take_damage(99999.0, &"test")


## 阶段间清场：强制删掉场上所有残留敌人并等树更新。
## **只能在 REFIT（波次未激活）时调** —— BATTLE 中调会让 WaveSystem 看到
## remaining()==0 而误判「本波已清空」，反而污染危机计数。
func _clear_field() -> void:
	for e in get_tree().get_nodes_in_group(Projectile.ENEMY_GROUP):
		if is_instance_valid(e):
			e.queue_free()
	await get_tree().physics_frame
	await get_tree().physics_frame


func _wave_cfg() -> Dictionary:
	if not FileAccess.file_exists(WAVE_DATA_PATH):
		push_warning("测试读不到 %s" % WAVE_DATA_PATH)
		return {}
	var f := FileAccess.open(WAVE_DATA_PATH, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return {}
	var sec: Variant = (parsed as Dictionary).get("wave", {})
	if sec is Dictionary:
		return sec as Dictionary
	return {}
