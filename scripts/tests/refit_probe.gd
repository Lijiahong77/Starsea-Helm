extends Node

## ⑦ 维修站过场 / 改装功能的独立验证探针（2026-09-08）
##
## 跑法：`godot_console --headless --path <proj> res://scenes/tests/refit_test.tscn`
##
## **手动推进而非等真帧**：过场全程约 8 秒（淡入 0.4 + 飞行 2.4 + 三句台词 + 改装 + 淡出），
## 等真帧既慢又不确定。这里用 tick(1/60) 循环喂时间，与 wave_probe / turret_hp_probe 同套路。
##
## 覆盖目标：
##   ① 时序机走位正确（FADE_IN → TRAVEL → MECHANIC → GARAGE → 告别 → FADE_OUT → IDLE）
##   ② **换装真的生效**（数值 + 外观 + 槽位记录），不只是 UI 上变了
##   ③ 隐形跳过只快进当前阶段，不吞掉后续阶段
##   ④ 主炮不可换（DEC-030）
##   ⑤ 过场开始 / 结束各广播一次 cutscene 信号

var _pass := 0
var _fail := 0
var _started := 0
var _ended := 0


func _ready() -> void:
	EventBus.cutscene_started.connect(func() -> void: _started += 1)
	EventBus.cutscene_ended.connect(func() -> void: _ended += 1)
	var ts := $TurretSystem as TurretSystem
	var seq := $RefitSequence as RefitSequence
	await run(ts, seq)


func run(ts: TurretSystem, seq: RefitSequence) -> void:
	_test_config(ts, seq)
	_test_timeline(ts, seq)
	await _test_swap(ts, seq)
	_test_skip(ts, seq)
	_report()


# ---------------------------------------------------------------- ① 配置

func _test_config(ts: TurretSystem, seq: RefitSequence) -> void:
	_check("类型库读出 3 种炮塔（实测 %d）" % ts.variant_ids().size(),
		ts.variant_ids().size() == 3)
	_check("可改装槽位 = 4 门副炮（实测 %d）" % ts.swappable_ids().size(),
		ts.swappable_ids().size() == 4)
	_check("主炮不在可改装列表（DEC-030 固定正面）",
		not ts.swappable_ids().has(&"main"))
	_check("开局默认装的是 flak（实测 %s）" % ts.equipped_variant(&"port"),
		ts.equipped_variant(&"port") == &"flak")
	var info := ts.variant_info(&"lance")
	_check("类型信息带名称与数值（%s / %.0f 伤害）" % [
			str(info.get("name", "?")), float(info.get("damage", 0.0))],
		not str(info.get("name", "")).is_empty() and float(info.get("damage", 0.0)) > 0.0)
	_check("过场未开始时 is_playing = false", not seq.is_playing())


# ---------------------------------------------------------------- ② 时序

func _test_timeline(ts: TurretSystem, seq: RefitSequence) -> void:
	# ⑧ 走**真实事件链**而不是手动 start：清空第 1 次危机 → TurretSystem 解锁 gatling
	# + RefitSequence 自动开过场。之前这里手动 seq.start(1)，解锁数永远停在 0，
	# 后面「换装成 2 号型号 gatling」会被未解锁规则挡下 —— 是测试在骗自己，不是代码错了。
	EventBus.crisis_cleared.emit(1)
	_check("start 后进入 FADE_IN（实测 %s）" % seq.phase_name(),
		seq.phase() == RefitSequence.Phase.FADE_IN)
	_check("cutscene_started 广播 1 次（实测 %d）" % _started, _started == 1)

	_advance(seq, 0.5)
	_check("淡入结束 → TRAVEL（实测 %s）" % seq.phase_name(),
		seq.phase() == RefitSequence.Phase.TRAVEL)

	# TRAVEL 2.4s + 三句台词（每句打字 ~0.5s + dwell 1.5s）→ 进 GARAGE
	_advance(seq, 2.5)
	_check("飞行结束 → MECHANIC（实测 %s）" % seq.phase_name(),
		seq.phase() == RefitSequence.Phase.MECHANIC)
	_advance(seq, 8.0)
	_check("三句台词播完 → GARAGE（实测 %s）" % seq.phase_name(),
		seq.phase() == RefitSequence.Phase.GARAGE)
	_check("GARAGE 不会自动推进（等输入）", seq.phase() == RefitSequence.Phase.GARAGE)
	_advance(seq, 6.0)
	_check("GARAGE 等 6 秒仍停在 GARAGE（实测 %s）" % seq.phase_name(),
		seq.phase() == RefitSequence.Phase.GARAGE)


# ---------------------------------------------------------------- ③ 换装

func _test_swap(ts: TurretSystem, seq: RefitSequence) -> void:
	# 选 1 号槽位（port）
	seq.handle_key(KEY_1)
	_check("选槽位后焦点 = port（实测 %s）" % seq.focused_slot(),
		seq.focused_slot() == &"port")
	var before_hp := (ts.get_turret(&"port") as Turret).hp
	var before_dmg := (ts.get_turret(&"port") as Turret).projectile_damage

	# 选 2 号型号（gatling：60 hp / 12 伤害 / 1.5s）
	seq.handle_key(KEY_2)
	await get_tree().physics_frame
	_check("换装记录更新为 gatling（实测 %s）" % ts.equipped_variant(&"port"),
		ts.equipped_variant(&"port") == &"gatling")
	var t := ts.get_turret(&"port") as Turret
	_check("换装后槽位仍可索引到炮塔（不是 null）", t != null)
	if t != null:
		_check("耐久 %.0f → %.0f（gatling 60）" % [before_hp, t.hp], is_equal_approx(t.hp, 60.0))
		_check("单发伤害 %.0f → %.0f（gatling 12）" % [before_dmg, t.projectile_damage],
			is_equal_approx(t.projectile_damage, 12.0))
		_check("炮塔 id 未变（换的是炮不是炮座）", t.turret_id == &"port")
		_check("炮位未变（muzzle_pos 仍在外表面）", t.muzzle_pos.length() > 5.0)
		_check("新炮可被接管（未被标记 destroyed）", not t.destroyed)
	_check("本次已换装 1 次（实测 %d）" % seq.swapped_count(), seq.swapped_count() == 1)

	# Esc 在「选型号」层 = 退回选槽位，不是直接出发
	seq.handle_key(KEY_2)   # 再次进入选型号
	seq.handle_key(KEY_ESCAPE)
	_check("选型号层按 Esc 退回选槽位（仍 %s）" % seq.phase_name(),
		seq.phase() == RefitSequence.Phase.GARAGE)

	# 主炮不可换
	var ok := ts.swap_turret(&"main", &"lance")
	_check("主炮换装被拒（DEC-030，实测 %s）" % str(ok), not ok)
	ok = ts.swap_turret(&"port", &"不存在的型号")
	_check("未知型号换装被拒（实测 %s）" % str(ok), not ok)

	# 出发 → 告别语 → 淡出 → IDLE
	seq.handle_key(KEY_ENTER)
	_check("出发后进入告别语（MECHANIC，实测 %s）" % seq.phase_name(),
		seq.phase() == RefitSequence.Phase.MECHANIC)
	_advance(seq, 6.0)
	_check("告别语后淡出结束 → IDLE（实测 %s）" % seq.phase_name(),
		not seq.is_playing())
	_check("cutscene_ended 广播 1 次（实测 %d）" % _ended, _ended == 1)


# ---------------------------------------------------------------- ④ 跳过

func _test_skip(ts: TurretSystem, seq: RefitSequence) -> void:
	seq.start(2)
	_advance(seq, 0.5)     # → TRAVEL
	_check("二次过场进入 TRAVEL（实测 %s）" % seq.phase_name(),
		seq.phase() == RefitSequence.Phase.TRAVEL)
	seq.handle_key(KEY_SPACE)   # 任意键
	_advance(seq, 1.0 / 60.0)
	_check("任意键把 TRAVEL 补完 → MECHANIC（实测 %s）" % seq.phase_name(),
		seq.phase() == RefitSequence.Phase.MECHANIC)
	_check("跳过只快进当前段，不跳过整段过场", seq.is_playing())
	seq.abort()
	_check("abort 后立即 IDLE", not seq.is_playing())
	_check("abort 也发 cutscene_ended（实测 %d）" % _ended, _ended == 2)


# ---------------------------------------------------------------- 工具

## 以 1/60 步长把过场推进 seconds 秒（模拟真帧，但快且确定）。
func _advance(seq: RefitSequence, seconds: float) -> void:
	var dt := 1.0 / 60.0
	var n := int(seconds / dt)
	for _i in range(n):
		seq.tick(dt)


func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  [OK]   " + label)
	else:
		_fail += 1
		print("  [FAIL] " + label)


func _report() -> void:
	print("=== ⑦ 维修站/改装 断言: %d/%d 通过 ===" % [_pass, _pass + _fail])
	if _fail == 0:
		print("全部通过")
	get_tree().quit()
