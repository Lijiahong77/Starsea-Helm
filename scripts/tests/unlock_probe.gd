extends Node

## ⑧ 自动解锁 / 扩展槽位的独立验证探针（2026-09-09 · DEC-042）
##
## 跑法：`godot_console --headless --path <proj> res://scenes/tests/unlock_test.tscn`
##
## **手动推进而非等真帧**：解锁由危机数驱动，这里直接 emit `crisis_cleared`
## 模拟"撑过一波"，比真打完一波快几个数量级，且断言的是规则而不是战斗结果。
##
## 覆盖目标：
##   ① 开局状态：只有 flak + 4 个起始槽位可用，其余全锁
##   ② 锁定项**装不上去**（规则在 TurretSystem，不在 UI）
##   ③ 各危机节点的解锁：1→gatling / 2→port2 / 3→lance / 5→starboard2
##   ④ 槽位解锁后是**空的**，能装第一门炮，且位置/扇区正确
##   ⑤ 信号广播：型号逐个发、槽位数变化才发（不每解锁一个发一次）
##   ⑥ 过场能跑完，且解锁播报 consume 后不重复

var _pass := 0
var _fail := 0
var _variant_sig := 0
var _slot_sig := 0
var _last_slot_count := 0
var _cutscene_ended := 0


func _ready() -> void:
	EventBus.turret_type_unlocked.connect(func(_id: StringName) -> void: _variant_sig += 1)
	EventBus.slot_count_changed.connect(func(n: int) -> void:
		_slot_sig += 1
		_last_slot_count = n)
	EventBus.cutscene_ended.connect(func() -> void: _cutscene_ended += 1)
	await run($TurretSystem as TurretSystem, $RefitSequence as RefitSequence)


func run(ts: TurretSystem, seq: RefitSequence) -> void:
	_test_initial(ts)
	_test_locked_reject(ts)
	_test_crisis_1(ts)
	_test_crisis_2(ts)
	_test_crisis_3(ts)
	await _test_empty_slot(ts)
	_test_crisis_5(ts)
	_test_crisis_6(ts)
	await _test_sector_cycle(ts)
	await _test_cutscene(ts, seq)
	_report()


# ---------------------------------------------------------------- ① 开局

func _test_initial(ts: TurretSystem) -> void:
	_check("开局撑过 0 次危机（实测 %d）" % ts.cleared_count(), ts.cleared_count() == 0)
	_check("型号库共 3 种（实测 %d）" % ts.variant_ids().size(),
		ts.variant_ids().size() == 3)
	_check("开局只解锁 flak（实测 %d 种）" % ts.unlocked_variant_ids().size(),
		ts.unlocked_variant_ids().size() == 1)
	_check("flak 已解锁", ts.is_variant_unlocked(&"flak"))
	_check("gatling 开局锁定", not ts.is_variant_unlocked(&"gatling"))
	_check("lance 开局锁定", not ts.is_variant_unlocked(&"lance"))
	_check("gatling 门槛 = 危机 1（实测 %d）" % ts.variant_unlock_at(&"gatling"),
		ts.variant_unlock_at(&"gatling") == 1)
	_check("lance 门槛 = 危机 3（实测 %d）" % ts.variant_unlock_at(&"lance"),
		ts.variant_unlock_at(&"lance") == 3)

	# ⑧ 每路 feed 两个炮位：4 起始 + 4 个第二炮位 = 8
	_check("槽位总数 8（4 起始 + 4 路第二炮位，实测 %d）" % ts.all_slot_ids().size(),
		ts.all_slot_ids().size() == 8)
	_check("已解锁槽位 4（实测 %d）" % ts.swappable_ids().size(),
		ts.swappable_ids().size() == 4)
	_check("port2 开局锁定", not ts.is_slot_unlocked(&"port2"))
	_check("port2 门槛 = 危机 2（实测 %d）" % ts.slot_unlock_at(&"port2"),
		ts.slot_unlock_at(&"port2") == 2)
	_check("starboard2 门槛 = 危机 3（实测 %d）" % ts.slot_unlock_at(&"starboard2"),
		ts.slot_unlock_at(&"starboard2") == 3)
	_check("dorsal2 门槛 = 危机 5（实测 %d）" % ts.slot_unlock_at(&"dorsal2"),
		ts.slot_unlock_at(&"dorsal2") == 5)
	_check("ventral2 门槛 = 危机 6（实测 %d）" % ts.slot_unlock_at(&"ventral2"),
		ts.slot_unlock_at(&"ventral2") == 6)
	# 第二炮位与所在那一路同扇区：同路两门都死才算这面失守
	_check("port2 属 port 扇区（实测 %s）" % ts.slot_sector(&"port2"),
		ts.slot_sector(&"port2") == &"port")
	_check("ventral2 属 ventral 扇区（实测 %s）" % ts.slot_sector(&"ventral2"),
		ts.slot_sector(&"ventral2") == &"ventral")
	var m := ts.slot_mount(&"port2")
	_check("port2 位置在左舷外表面并向船尾错开（%s）" % str(m),
		is_equal_approx(m.x, -11.5) and is_equal_approx(m.z, -3.5))
	# 开局静默：不 emit（否则订阅方在自己的 _ready 里就收到信号）
	_check("开局不广播解锁信号（型号 %d / 槽位 %d）" % [_variant_sig, _slot_sig],
		_variant_sig == 0 and _slot_sig == 0)


# ---------------------------------------------------------------- ② 锁定项装不上

func _test_locked_reject(ts: TurretSystem) -> void:
	_check("未解锁型号装不上 gatling", not ts.swap_turret(&"port", &"gatling"))
	_check("未解锁型号装不上 lance", not ts.swap_turret(&"port", &"lance"))
	_check("未解锁槽位装不上 port2", not ts.swap_turret(&"port2", &"flak"))
	_check("被拒后 port 仍是 flak（实测 %s）" % ts.equipped_variant(&"port"),
		ts.equipped_variant(&"port") == &"flak")
	_check("未知型号装不上", not ts.swap_turret(&"port", &"不存在的炮"))
	_check("主炮不可换（DEC-030）", not ts.swap_turret(&"main", &"flak"))


# ---------------------------------------------------------------- ③ 危机 1

func _test_crisis_1(ts: TurretSystem) -> void:
	EventBus.crisis_cleared.emit(1)
	_check("撑过 1 次危机（实测 %d）" % ts.cleared_count(), ts.cleared_count() == 1)
	_check("危机 1 解锁 gatling", ts.is_variant_unlocked(&"gatling"))
	_check("危机 1 时 lance 仍锁定", not ts.is_variant_unlocked(&"lance"))
	_check("型号解锁信号广播 1 次（实测 %d）" % _variant_sig, _variant_sig == 1)
	_check("槽位未变化 → 不发 slot_count_changed（实测 %d）" % _slot_sig, _slot_sig == 0)
	# 解锁后真的能装
	_check("解锁后装 gatling 成功", ts.swap_turret(&"port", &"gatling"))
	_check("换装记录 = gatling（实测 %s）" % ts.equipped_variant(&"port"),
		ts.equipped_variant(&"port") == &"gatling")
	var t := ts.get_turret(&"port") as Turret
	_check("port 耐久 80 → 60（gatling，实测 %.0f）" % (t.hp if t != null else -1.0),
		t != null and is_equal_approx(t.hp, 60.0))


# ---------------------------------------------------------------- ③ 危机 2

func _test_crisis_2(ts: TurretSystem) -> void:
	EventBus.crisis_cleared.emit(2)
	_check("撑过 2 次危机（实测 %d）" % ts.cleared_count(), ts.cleared_count() == 2)
	_check("危机 2 解锁 port2 槽位", ts.is_slot_unlocked(&"port2"))
	_check("已解锁槽位 5（实测 %d）" % ts.swappable_ids().size(),
		ts.swappable_ids().size() == 5)
	_check("slot_count_changed 广播 1 次（实测 %d）" % _slot_sig, _slot_sig == 1)
	_check("广播的槽位数 = 5（实测 %d）" % _last_slot_count, _last_slot_count == 5)
	# 槽位解锁时是空的：有位置但没炮
	_check("port2 槽位已解锁但**没有炮**（实测 %s）" % str(ts.get_turret(&"port2")),
		ts.get_turret(&"port2") == null)
	_check("空槽位的装配记录为空（实测 %s）" % ts.equipped_variant(&"port2"),
		ts.equipped_variant(&"port2") == &"")


# ---------------------------------------------------------------- ③ 危机 3

func _test_crisis_3(ts: TurretSystem) -> void:
	EventBus.crisis_cleared.emit(3)
	_check("危机 3 解锁 lance（赶在 bomber 第 4 波之前）",
		ts.is_variant_unlocked(&"lance"))
	_check("危机 3 解锁 starboard2（右舷第二炮位）", ts.is_slot_unlocked(&"starboard2"))
	_check("已解锁槽位 6（实测 %d）" % ts.swappable_ids().size(),
		ts.swappable_ids().size() == 6)
	_check("型号解锁信号累计 2 次（实测 %d）" % _variant_sig, _variant_sig == 2)
	_check("已解锁型号 3 种（实测 %d）" % ts.unlocked_variant_ids().size(),
		ts.unlocked_variant_ids().size() == 3)


# ---------------------------------------------------------------- ④ 空槽装炮

func _test_empty_slot(ts: TurretSystem) -> void:
	var ok := ts.swap_turret(&"port2", &"lance")
	_check("往空槽位 port2 装 lance 成功", ok)
	await get_tree().physics_frame
	var t := ts.get_turret(&"port2") as Turret
	_check("空槽装炮后能索引到炮塔", t != null)
	if t != null:
		_check("新炮 id = port2（实测 %s）" % t.turret_id, t.turret_id == &"port2")
		_check("新炮扇区 = port（实测 %s）" % t.sector, t.sector == &"port")
		_check("新炮落在槽位定义的位置上",
			t.muzzle_pos.distance_to(ts.slot_mount(&"port2")) < 0.01)
		_check("新炮耐久 110（lance，实测 %.0f）" % t.hp, is_equal_approx(t.hp, 110.0))
		_check("新炮可被接管（未标记 destroyed）", not t.destroyed)
	_check("装配记录 = lance（实测 %s）" % ts.equipped_variant(&"port2"),
		ts.equipped_variant(&"port2") == &"lance")
	# 双联装：同扇区两门各自独立（DEC-040）
	_check("port 扇区现在有 2 门炮（双联装）",
		(ts.get_turret(&"port") != null) and (ts.get_turret(&"port2") != null))


# ---------------------------------------------------------------- ③ 危机 5

func _test_crisis_5(ts: TurretSystem) -> void:
	EventBus.crisis_cleared.emit(4)
	_check("危机 4 无新解锁（信号仍 %d / %d）" % [_variant_sig, _slot_sig],
		_variant_sig == 2 and _slot_sig == 2)
	EventBus.crisis_cleared.emit(5)
	_check("危机 5 解锁 dorsal2（顶部第二炮位）", ts.is_slot_unlocked(&"dorsal2"))
	_check("已解锁槽位 7（实测 %d）" % ts.swappable_ids().size(),
		ts.swappable_ids().size() == 7)
	_check("slot_count_changed 累计 3 次（实测 %d）" % _slot_sig, _slot_sig == 3)
	_check("广播的槽位数 = 7（实测 %d）" % _last_slot_count, _last_slot_count == 7)


func _test_crisis_6(ts: TurretSystem) -> void:
	EventBus.crisis_cleared.emit(6)
	_check("危机 6 解锁 ventral2（底部第二炮位）", ts.is_slot_unlocked(&"ventral2"))
	_check("已解锁槽位 8（实测 %d）" % ts.swappable_ids().size(),
		ts.swappable_ids().size() == 8)
	_check("slot_count_changed 累计 4 次（实测 %d）" % _slot_sig, _slot_sig == 4)
	_check("广播的槽位数 = 8（实测 %d）" % _last_slot_count, _last_slot_count == 8)


# ---------------------------------------------------------------- 按路循环接管

func _test_sector_cycle(ts: TurretSystem) -> void:
	# port 路此时装了两门（port=gatling / port2=lance），应能在两门之间循环
	var ids := ts.slots_of_sector(&"port")
	_check("port 路有 2 个可接管炮位（实测 %d）" % ids.size(), ids.size() == 2)
	_check("port 路的炮位顺序含 port 与 port2",
		ids.has(&"port") and ids.has(&"port2"))
	# 顶部第二炮位虽然解锁了，但**还没装炮** → 不占循环位
	var d_ids := ts.slots_of_sector(&"dorsal")
	_check("dorsal 路只有 1 个可接管炮位（空槽不参与循环，实测 %d）" % d_ids.size(),
		d_ids.size() == 1)

	ts.takeover_sector(&"port")
	_check("首按接管路内第一门 = port（实测 %s）" % ts.current_manual_id,
		ts.current_manual_id == &"port")
	ts.takeover_sector(&"port")
	_check("再按同键切到该路第二门 = port2（实测 %s）" % ts.current_manual_id,
		ts.current_manual_id == &"port2")
	ts.takeover_sector(&"port")
	_check("转完一圈 → 释放接管回主控室（实测 %s）" % ts.current_manual_id,
		ts.current_manual_id == &"")
	# 切到别路：从那一路的第一门重新开始
	ts.takeover_sector(&"port")
	ts.takeover_sector(&"dorsal")
	_check("从 port2 切到 dorsal 路 → 接管 dorsal（实测 %s）" % ts.current_manual_id,
		ts.current_manual_id == &"dorsal")
	ts.takeover(&"")   # 收尾：释放，别把接管状态带进过场
	_check("takeover(&\"\") 释放接管（实测 %s）" % ts.current_manual_id,
		ts.current_manual_id == &"")


# ---------------------------------------------------------------- ⑥ 过场集成

func _test_cutscene(ts: TurretSystem, seq: RefitSequence) -> void:
	# 危机 1 那次 emit 已经让 RefitSequence 自动开过场了（它订阅 crisis_cleared）。
	# 这里把它推完：目的不是测时序（那是 refit_probe 的活），而是确认
	# 「解锁播报插进台词」没把过场搞崩，且 consume 后不重复播报。
	if seq.is_playing():
		# 推进时长要留够：本测试一口气 emit 了 6 次危机，解锁播报累积了 6 条，
		# 台词总长远超真实流程（真实流程每危机最多 1-2 条）。
		_advance(seq, 40.0)     # 淡入 + 飞行 + 台词（含解锁播报）→ GARAGE
	_check("过场停在 GARAGE 等输入（实测 %s）" % seq.phase_name(),
		seq.phase() == RefitSequence.Phase.GARAGE)
	# GARAGE 不自动推进是**设计**（改装台是玩法不是演出，见 DEC-041），
	# 所以要自己按 Enter 出发，才会走告别语 → 淡出 → IDLE。
	seq.handle_key(KEY_ENTER)
	_advance(seq, 10.0)
	_check("出发后过场能跑完并回到 IDLE（实测 %s）" % seq.phase_name(),
		not seq.is_playing())
	_check("过场结束广播 1 次（实测 %d）" % _cutscene_ended, _cutscene_ended == 1)
	_check("解锁播报已被 consume（fresh 清空，实测 %d）" % ts.fresh_unlocks().size(),
		ts.fresh_unlocks().size() == 0)
	# 再撑一次也不该凭空冒出播报（危机 7 没有新解锁了）
	EventBus.crisis_cleared.emit(7)
	_check("危机 7 无新解锁 → fresh 仍为空", ts.fresh_unlocks().is_empty())
	_check("槽位与型号已全解锁（%d/%d）" % [
			ts.swappable_ids().size(), ts.unlocked_variant_ids().size()],
		ts.swappable_ids().size() == 8 and ts.unlocked_variant_ids().size() == 3)


# ---------------------------------------------------------------- 工具

func _advance(seq: RefitSequence, seconds: float) -> void:
	var dt := 1.0 / 60.0
	for _i in range(int(seconds / dt)):
		seq.tick(dt)


func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  [OK]   " + label)
	else:
		_fail += 1
		print("  [FAIL] " + label)


func _report() -> void:
	print("=== ⑧ 自动解锁 / 扩展槽位 断言: %d/%d 通过 ===" % [_pass, _pass + _fail])
	if _fail == 0:
		print("全部通过")
	get_tree().quit()
