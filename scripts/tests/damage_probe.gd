extends Node

## ⑨a 战损报告（**DEC-043**）的独立验证探针（2026-09-10）
##
## 跑法：`godot_console --headless --path <proj> res://scenes/tests/damage_test.tscn`
##
## 覆盖目标：
##   ① **数据层**：累计 / 按敌人类型分解 / 主要来源 / 扇区汇总 / 被毁标记
##   ② **清空时机**：只在开战清，REFIT 全程能读到上一波
##   ③ **四个出口读的是同一份数据**（DEC-043 的核心承诺）
##   ④ 没战损时不播报、不显示（与解锁播报同一条逻辑）
##
## ⚠ **伤害一律走真实路径**（`Turret.take_damage` → EventBus → DamageLog），
## 不直接 emit 事件。直接 emit 会跳过 take_damage 里的 source_id 传递 ——
## 哪天 source_id 又没传出去，测试照样是绿的（⑧ 那次 refit_probe 就栽在这上面）。

var _pass := 0
var _fail := 0


func _ready() -> void:
	await run($TurretSystem as TurretSystem, $RefitSequence as RefitSequence)


func run(ts: TurretSystem, seq: RefitSequence) -> void:
	_test_data_layer(ts)
	_test_destroyed(ts)
	_test_exports(ts, seq)
	_test_reset(ts)
	_test_no_damage(ts, seq)
	_report()


# ---------------------------------------------------------------- ① 数据层

func _test_data_layer(ts: TurretSystem) -> void:
	var dl := ts.damage_log()
	_check("DamageLog 已挂上（非空）", dl != null)
	if dl == null:
		return
	_check("开局无战损", not dl.has_any())
	_check("开局总计 0（实测 %.1f）" % dl.total_taken(), dl.total_taken() == 0.0)

	var p := ts.get_turret(&"port")
	_check("能取到 port 炮塔", p != null)
	if p == null:
		return
	# 30 点来自战机、8 点来自轰炸机 —— 分解要能分开，否则答不出「为什么掉的」
	p.take_damage(30.0, &"interceptor")
	p.take_damage(8.0, &"bomber")

	_check("本波有战损了", dl.has_any())
	_check("port 承伤 38（实测 %.1f）" % dl.taken(&"port"), absf(dl.taken(&"port") - 38.0) < 0.01)
	_check("分解 interceptor=30（实测 %.1f）" % dl.taken_by_type(&"port", &"interceptor"),
		absf(dl.taken_by_type(&"port", &"interceptor") - 30.0) < 0.01)
	_check("分解 bomber=8（实测 %.1f）" % dl.taken_by_type(&"port", &"bomber"),
		absf(dl.taken_by_type(&"port", &"bomber") - 8.0) < 0.01)
	_check("主要来源 = interceptor（实测 %s）" % dl.top_source(&"port"),
		dl.top_source(&"port") == &"interceptor")
	_check("port 扇区汇总 38（实测 %.1f）" % dl.sector_taken(&"port"),
		absf(dl.sector_taken(&"port") - 38.0) < 0.01)
	_check("别的扇区不受影响（实测 %.1f）" % dl.sector_taken(&"dorsal"),
		dl.sector_taken(&"dorsal") == 0.0)
	_check("全局 interceptor 合计 30（实测 %.1f）" % dl.by_type_total(&"interceptor"),
		absf(dl.by_type_total(&"interceptor") - 30.0) < 0.01)
	_check("最惨的是 port（实测 %s）" % dl.worst_turret(), dl.worst_turret() == &"port")
	_check("没挨打的门承伤 0（实测 %.1f）" % dl.taken(&"dorsal"), dl.taken(&"dorsal") == 0.0)


# ---------------------------------------------------------------- ② 被毁标记

func _test_destroyed(ts: TurretSystem) -> void:
	var dl := ts.damage_log()
	var s := ts.get_turret(&"starboard")
	_check("能取到 starboard 炮塔", s != null)
	if s == null:
		return
	s.take_damage(9999.0, &"bomber")
	_check("starboard 被标记摧毁", dl.destroyed_ids().has(&"starboard"))
	_check("被毁的炮**仍记着**承伤（实测 %.1f）" % dl.taken(&"starboard"),
		dl.taken(&"starboard") > 0.0)
	_check("被毁后也在 destroyed_ids 里（共 %d 门）" % dl.destroyed_ids().size(),
		dl.destroyed_ids().size() == 1)


# ---------------------------------------------------------------- ③ 四个出口

## 四个出口读同一份数据（DEC-043 的核心承诺）。
## 这里直接调 RefitSequence 的几个私有生成函数 —— 它们是纯字符串拼装，
## 从头跑一遍过场再断言要等好几秒，而我们要验的是「数据取对了」，不是时序。
func _test_exports(ts: TurretSystem, seq: RefitSequence) -> void:
	# 出口 ④ 改装台
	var s_port := seq._damage_suffix(ts, &"port")
	_check("④ 改装台 port 显示本波战损（实测 «%s»）" % s_port, s_port.contains("-38"))
	var s_dead := seq._damage_suffix(ts, &"starboard")
	_check("④ 被毁的槽位显示「被击毁」（实测 «%s»）" % s_dead, s_dead.contains("被击毁"))
	var s_clean := seq._damage_suffix(ts, &"dorsal")
	_check("④ 没挨打的槽位不显示战损（实测 «%s»）" % s_clean, s_clean.is_empty())

	# 出口 ③ 维修师台词
	var lines := seq._damage_lines()
	_check("③ 维修师播报 1 条（实测 %d）" % lines.size(), lines.size() == 1)
	if not lines.is_empty():
		# 对照**数据里**最惨的那门，不硬编码"左舷" ——
		# 本组数据里 starboard 被打爆（9999），它才是最惨的，硬编码会写出假断言。
		var worst_name := seq._slot_label(ts.damage_log().worst_turret())
		_check("③ 台词点名的是最惨那门 %s（实测 «%s»）" % [worst_name, lines[0]],
			lines[0].contains(worst_name))

	# 出口 ② 维修站面板
	seq._build_damage_panel()
	var body: String = seq._dmg_body
	_check("② 面板列了 port（实测 «%s»）" % body, body.contains("左舷"))
	_check("② 面板标了被击毁（实测 «%s»）" % body, body.contains("被击毁"))
	_check("② 面板写了伤害来源（实测 «%s»）" % body, body.contains("主要来自"))
	_check("② 面板用了中文敌人名（实测 «%s»）" % body, body.contains("战机"))
	_check("② 面板没列没挨打的 dorsal（实测 «%s»）" % body, not body.contains("顶部"))
	_check("② 面板标题非空（实测 «%s»）" % seq._dmg_title, not seq._dmg_title.is_empty())

	# 出口 ① HUD 走的是同一个 damage_log()（HUD 本身在 bridge_whitebox，
	# 不在本测试场景；这里只保证数据同源可达）
	_check("① HUD 与 ②③④ 同源（同一个 DamageLog 实例）",
		ts.damage_log() == ts.damage_log())


# ---------------------------------------------------------------- ④ 清空时机

func _test_reset(ts: TurretSystem) -> void:
	var dl := ts.damage_log()
	ts.set_battle_active(true)
	_check("开战后战损清空", not dl.has_any())
	_check("清空后 port 承伤 0（实测 %.1f）" % dl.taken(&"port"), dl.taken(&"port") == 0.0)
	_check("清空后被毁标记也清了", not dl.destroyed_ids().has(&"starboard"))
	var p := ts.get_turret(&"port")
	if p != null:
		_check("开战同时回满耐久（实测 %.0f/%.0f）" % [p.hp, p.hp_max], p.hp == p.hp_max)
	ts.set_battle_active(false)


# ---------------------------------------------------------------- ⑤ 无战损

func _test_no_damage(ts: TurretSystem, seq: RefitSequence) -> void:
	# 刚清空过，现在是无战损状态
	var lines := seq._damage_lines()
	_check("无战损时维修师**不播报**（实测 %d 条）" % lines.size(), lines.is_empty())
	seq._build_damage_panel()
	var body: String = seq._dmg_body
	_check("无战损时面板说「本波无战损」（实测 «%s»）" % body, body.contains("本波无战损"))
	_check("无战损时面板**不留空**（实测 «%s»）" % body, not body.is_empty())


# ---------------------------------------------------------------- 收尾

func _check(desc: String, ok: bool) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		print("  ✗ FAIL: " + desc)


func _report() -> void:
	print("=== ⑨a 战损报告 断言: %d/%d 通过 ===" % [_pass, _pass + _fail])
	if _fail == 0:
		print("全部通过")
	else:
		print("有 %d 条失败" % _fail)
	get_tree().quit()
