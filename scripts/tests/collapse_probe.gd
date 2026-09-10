extends Node

## ⑨b 陷落演出（**DEC-043** 三级分层）的独立验证探针（2026-09-10）
##
## 跑法：`godot_console --headless --path <proj> res://scenes/tests/collapse_test.tscn`
##
## 覆盖目标：
##   ① **L1 单炮**：一路两门、死一门 → DEGRADED（计数，非红叉）
##   ② **L2 该面失守**：一路全灭 → BREACHED（红叉）
##   ③ **L3 终局**：全部被毁 → 夺操控(is_locked) → 镜头推进 → 切 RESULT
##   ④ **开战重置**：game_state_changed(BATTLE) → 标记清空
##   ⑤ 表现层缺失容错：本场景无监控屏 / 无相机，只跑状态层、不崩
##
## ⚠ 触发一律走真实路径（take_damage → turret_destroyed → CollapseSequence），
## 不直接 emit 陷落事件 —— 直接 emit 会跳过 TurretSystem 的聚合判定，
## 哪天 sector_breached 判定又改了，测试照样是绿的。

var _pass := 0
var _fail := 0


func _ready() -> void:
	await run($TurretSystem as TurretSystem, $CollapseSequence as CollapseSequence)


func run(ts: TurretSystem, col: CollapseSequence) -> void:
	_test_initial(col)
	_test_l1_degraded(ts, col)
	_test_l2_breached(ts, col)
	_test_l3(ts, col)
	_test_reset(col)
	_report()


# ---------------------------------------------------------------- ① 初始态

func _test_initial(col: CollapseSequence) -> void:
	_check("开局四路全 OK", col.sector_state(&"port") == CollapseSequence.SectorState.OK
		and col.sector_state(&"starboard") == CollapseSequence.SectorState.OK
		and col.sector_state(&"dorsal") == CollapseSequence.SectorState.OK
		and col.sector_state(&"ventral") == CollapseSequence.SectorState.OK)
	_check("开局未锁输入（无 L3）", not col.is_locked())
	_check("开局无宣告文案（实测 «%s»）" % col.announce_text(), col.announce_text() == "")


# ---------------------------------------------------------------- ② L1 单炮

func _test_l1_degraded(ts: TurretSystem, col: CollapseSequence) -> void:
	# 先让 port 扩成两门：危机 2 解锁 port2，再手动装一门 flak。
	# ⚠ crisis_cleared 的参数值被忽略（TurretSystem._on_crisis_cleared 里是 _cleared += 1），
	# 靠 emit **次数**累加 —— 所以这里要 emit 两次才到危机 2（第一次顺带解锁 gatling）。
	EventBus.crisis_cleared.emit(1)
	EventBus.crisis_cleared.emit(2)
	_check("危机 2 解锁 port2", ts.is_slot_unlocked(&"port2"))
	var ok: bool = ts.swap_turret(&"port2", &"flak")
	_check("port2 装上 flak（实测 %s）" % ok, ok)
	_check("port2 与 port 同扇区（实测 %s）" % ts.slot_sector(&"port2"),
		ts.slot_sector(&"port2") == &"port")

	# 打掉 port 一门（port 扇区两门还剩一门 → DEGRADED）
	var p := ts.get_turret(&"port")
	_check("能取到 port 炮塔", p != null)
	if p == null:
		return
	p.take_damage(9999.0, &"bomber")
	_check("死一门 → port 是 DEGRADED（实测 %d）" % col.sector_state(&"port"),
		col.sector_state(&"port") == CollapseSequence.SectorState.DEGRADED)
	_check("死一门 ≠ 整路失守（port 不是 BREACHED）",
		col.sector_state(&"port") != CollapseSequence.SectorState.BREACHED)
	_check("别的路不受牵连（starboard 仍 OK）",
		col.sector_state(&"starboard") == CollapseSequence.SectorState.OK)


# ---------------------------------------------------------------- ③ L2 该面失守

func _test_l2_breached(ts: TurretSystem, col: CollapseSequence) -> void:
	var p2 := ts.get_turret(&"port2")
	_check("能取到 port2 炮塔", p2 != null)
	if p2 == null:
		return
	p2.take_damage(9999.0, &"bomber")
	_check("两门全灭 → port 是 BREACHED（实测 %d）" % col.sector_state(&"port"),
		col.sector_state(&"port") == CollapseSequence.SectorState.BREACHED)


# ---------------------------------------------------------------- ④ L3 终局

func _test_l3(ts: TurretSystem, col: CollapseSequence) -> void:
	# 打掉剩余炮塔（含主炮 main）→ 全部炮塔被毁 → all_turrets_destroyed → 启动 L3。
	# ⚠ main 主炮也计入 alive_count()（DEC-037 失败条件 = **所有**炮塔被毁），
	# 漏掉 main 就不会触发终局。
	for sid in [&"main", &"starboard", &"dorsal", &"ventral"]:
		var t := ts.get_turret(sid)
		if t != null and not t.destroyed:
			t.take_damage(9999.0, &"interceptor")
	_check("全部被毁后进入 L3（is_locked）", col.is_locked())
	_check("L3 期间有宣告文案（实测 «%s»）" % col.announce_text(),
		col.announce_text() != "")
	_check("L3 尚未切 RESULT（演出还没演完）", not GameStateManager.is_result())

	# 强制推进镜头（本场景无相机，_advance_l3 只累计时间不搬相机）
	col._advance_l3(10.0)
	_check("镜头演完解除锁（is_locked=false）", not col.is_locked())
	_check("演完切到 RESULT（实测 %s）" % GameStateManager.state_name(),
		GameStateManager.is_result())


# ---------------------------------------------------------------- ⑤ 开战重置

func _test_reset(col: CollapseSequence) -> void:
	# 直接 emit 信号模拟开战（不走 GameStateManager，绕开 RESULT→BATTLE 的非法转换）
	EventBus.game_state_changed.emit(&"BATTLE")
	_check("开战后 port 标记清空回 OK（实测 %d）" % col.sector_state(&"port"),
		col.sector_state(&"port") == CollapseSequence.SectorState.OK)


# ---------------------------------------------------------------- 收尾

func _check(desc: String, ok: bool) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		print("  ✗ FAIL: " + desc)


func _report() -> void:
	print("=== ⑨b 陷落演出 断言: %d/%d 通过 ===" % [_pass, _pass + _fail])
	if _fail == 0:
		print("全部通过")
	else:
		print("有 %d 条失败" % _fail)
	get_tree().quit()
