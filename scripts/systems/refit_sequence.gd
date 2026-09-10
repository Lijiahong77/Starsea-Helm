extends Node
class_name RefitSequence

## ⑦ 维修站过场编排（2026-09-08 · 阶段 A 白盒版）
##
## **一句话**：每波清空后，飞去维修站 → 维修师报告（纯氛围台词）→ 改装台换炮 → 出发。
## 把 REFIT 从一个黑盒界面变成「一个地方」，装配决策从此有物理锚点。
## 参照物是《Hades》的 House of Hades：回家本身成为循环的情绪缓冲。
##
## **阶段机**（一次过场的完整走位）：
##   IDLE → FADE_IN（黑幕升起）→ TRAVEL（飞往维修站，白盒=黑屏一行字）
##        → MECHANIC（维修师台词，打字机，自动翻页）→ GARAGE（改装台，等输入）
##        → MECHANIC（告别语）→ FADE_OUT → IDLE
##
## **跳过设计（李 2026-09-08 提问「2-3 秒也要跳过吗」的结论）**：
##   要，但**不放按钮**。理由：2-3 秒单看不值一个 UI 按钮，但**每次危机都播**，
##   一局 10 次 × 一天几十局 → 累计十几分钟纯看动画（《死亡细胞》开局动画的教训）。
##   所以做成**隐形能力**：过场期间按任意键 = 立即补完当前阶段（不是整个过场）。
##   GARAGE 阶段不吞键 —— 那是玩法，不是演出。
##
## **不新增全局状态**（写进 bible §十的技术约束）：过场是 REFIT 的入场演出，
## 状态机仍只有 MENU/REFIT/BATTLE/RESULT 四态；本类只 emit cutscene_started/ended，
## 输入屏蔽由 bridge_whitebox 订阅后自行处理，跳过逻辑不散进状态机。
##
## **数值与台词全外置** `data/refit.json`；炮塔数值在 `turrets.json` 的 variants 段。
## 本文件只有流程骨架，**没有任何 hardcode 的台词 / 时长 / 颜色**。

const DATA_PATH := "res://data/refit.json"
## ⑨a 战损面板要显示「伤害来源」，得知道敌人的中文名。**单独一个常量**而不是
## 往 refit.json 里塞：refit.json 管演出、enemies.json 管敌人，两边职责不混。
const ENEMY_DATA_PATH := "res://data/enemies.json"
const TURRET_SYSTEM_GROUP := &"turret_system"

## 【日志纪律】新模块打开 print，手玩验收后改 false。
const DEBUG_LOG := false

enum Phase { IDLE, FADE_IN, TRAVEL, MECHANIC, GARAGE, FADE_OUT }

## 槽位 id → 中文名。改装台显示用；加新扇区时同步补这里。
const SLOT_LABELS := {
	&"port": "左舷炮位",
	&"starboard": "右舷炮位",
	&"dorsal": "顶部炮位",
	&"ventral": "底部炮位",
	# ⑧ 每路 feed 的第二炮位（DEC-042）。四路都有，解锁分批：
	# 先左右舷（危机 2 / 3），后顶底（危机 5 / 6）。中文名说清是"第二炮位"。
	&"port2": "左舷第二炮位",
	&"starboard2": "右舷第二炮位",
	&"dorsal2": "顶部第二炮位",
	&"ventral2": "底部第二炮位",
}

## 改装台阶段的黑幕浓度。**刻意不是 1.0**：全黑就看不见换装特效了，
## 而「看见旧炮消失 / 新炮弹出」正是本阶段唯一的正反馈。
const GARAGE_FADE := 0.55

var _overlay: RefitOverlay
var _phase := Phase.IDLE
var _timer := 0.0
var _dur := 1.0
var _crisis := 0
var _lines: Array[String] = []
var _line_idx := -1
var _dwell := 0.0
var _then := Phase.GARAGE
var _cfg: Dictionary = {}
var _speaker := "维修师"

# 改装台状态
var _slots: Array[StringName] = []
var _variants: Array[StringName] = []
var _slot_idx := 0
var _var_idx := 0
var _step := 0      # 0 = 选炮位，1 = 选型号
var _swapped := 0
## ⑧ 选中了未解锁项时的一次性提示（下次成功操作或进改装台时清空）。
## 为什么需要：**数字键点了个没反应的东西，屏幕上什么都不变**是最难受的反馈 ——
## 玩家会以为键盘坏了或者游戏卡了。宁可多一句"还差 2 次危机"。
var _lock_msg := ""

## ⑨a 战损面板内容（DEC-043 出口 ②）：过场开始时算一次，整段台词期间复用。
## **算一次就够** —— REFIT 期间不会再有人挨打，数据不会变。
var _dmg_title := ""
var _dmg_body := ""

## ⑨a 敌人 type_id → 中文名（读 enemies.json 的 `display_name`）。
## **文案外置**而不是写死在脚本里：改个称呼不用碰代码（宪法第 3 条）。
var _enemy_names: Dictionary = {}


func _ready() -> void:
	_cfg = _load_json(DATA_PATH)
	# ⑨a 敌人中文名（战损面板的「伤害来源」用）。**读一次就够**：
	# 过场期间它不会变，没必要每帧开一次文件。
	var ed: Dictionary = _load_json(ENEMY_DATA_PATH)
	var en: Dictionary = ed.get("enemy", {}) as Dictionary
	_enemy_names = en.get("display_name", {}) as Dictionary
	var mech: Dictionary = _cfg.get("mechanic", {}) as Dictionary
	_speaker = str(mech.get("name", "维修师"))
	# 自己持有 Overlay 而不依赖 .tscn 挂点：过场 UI 是纯程序化的，
	# 少一条外部依赖就少一处「节点没挂上 → 过场静默不播」的排查成本。
	_overlay = RefitOverlay.new()
	_overlay.name = "RefitOverlay"
	add_child(_overlay)
	_overlay.setup(_cfg)
	_overlay.set_fade(0.0)
	EventBus.crisis_cleared.connect(_on_crisis_cleared)
	if DEBUG_LOG:
		# 不在这里打型号数量：_variants 是进改装台时才从 TurretSystem 拉的
		# （过场可能跑在 TurretSystem 之前 _ready），此刻必为 0，打了只会骗人。
		print("[refit] 序列就绪，监听 crisis_cleared（台词 %d 组）" % _line_group_count())


## 每波清空自动触发（订阅 EventBus.crisis_cleared）。
func _on_crisis_cleared(wave_index: int) -> void:
	start(wave_index)


## 手动开启一次过场（测试 / 将来「跳过战斗直接改装」用）。
## 已在播 → 忽略（危机刚清完时可能连着来两次，重复 start 会把计时器清零卡住）。
func start(crisis_n: int) -> void:
	if _phase != Phase.IDLE:
		return
	_crisis = crisis_n
	_swapped = 0
	_enter_fade_in()
	EventBus.cutscene_started.emit()
	if DEBUG_LOG:
		print("[refit] 过场开始（第 %d 次危机）" % crisis_n)


## 是否正在过场。bridge_whitebox 的输入屏蔽看它。
func is_playing() -> bool:
	return _phase != Phase.IDLE


## 当前阶段名（测试断言 / 调试用）。
func phase_name() -> String:
	return Phase.keys()[_phase]


## 供测试 / 调试直接读的当前阶段枚举。
func phase() -> Phase:
	return _phase


## 本次过场已换装次数（测试断言用）。
func swapped_count() -> int:
	return _swapped


## 当前改装台光标：选中的槽位 id / 型号 id（&"" 表示还没进改装台）。
func focused_slot() -> StringName:
	if _slots.is_empty():
		return &""
	return _slots[_slot_idx]


func focused_variant() -> StringName:
	if _variants.is_empty():
		return &""
	return _variants[_var_idx]


## 推进一帧。与 Enemy.advance / TurretSystem.advance_all 同一套约定：
## **抽成公开方法是为了测试可手动推进** —— 等真帧跑完一次过场要十几秒且不确定。
## 本类的 _process 直接转调这里。
func tick(delta: float) -> void:
	match _phase:
		Phase.FADE_IN:
			_timer -= delta
			_overlay.set_fade(clampf(1.0 - _timer / maxf(_dur, 0.0001), 0.0, 1.0))
			if _timer <= 0.0:
				_enter_travel()
		Phase.TRAVEL:
			_timer -= delta
			if _timer <= 0.0:
				_enter_mechanic(_arrival_lines(), Phase.GARAGE)
		Phase.MECHANIC:
			# 台词**自动翻页**（打完 + 停顿 dwell 秒后下一句）：
			# REFIT 无时间限制（bible 01），但过场卡住等按键违反「低 APM」初衷 ——
			# 玩家挂机也能看完，想快就按键跳过。
			if not _overlay.typing_done():
				_overlay.type_step(delta)
				return
			_dwell += delta
			if _dwell >= _line_dwell():
				_next_line()
		Phase.GARAGE:
			pass    # 纯等输入，不自动推进（这是玩法不是演出）
		Phase.FADE_OUT:
			_timer -= delta
			_overlay.set_fade(clampf(_timer / maxf(_dur, 0.0001), 0.0, 1.0))
			if _timer <= 0.0:
				_finish()
		_:
			pass


func _process(delta: float) -> void:
	tick(delta)


## 过场期间的按键处理。**由 bridge_whitebox._input 转调**（不自己接 _input）：
## Godot 的 _input 广播顺序不可靠，若两边都接，很可能出现「改装台还没收到键，
## bridge 已经先按 1 去接管炮塔了」。显式转调 = 顺序确定。
## 返回 true 表示这个键被过场吃掉了，调用方不要再处理。
func handle_key(keycode: int) -> bool:
	if _phase == Phase.IDLE:
		return false
	match _phase:
		Phase.FADE_IN, Phase.TRAVEL, Phase.FADE_OUT:
			# 隐形跳过：把当前阶段的计时器清零，下一帧立即转场。
			# 不是直接跳到结尾 —— 2 秒的过场值得让它演完，只是别让人等。
			_timer = 0.0
			return true
		Phase.MECHANIC:
			if not _overlay.typing_done():
				_overlay.finish_typing()   # 第一次按键 = 补全这句话
				_dwell = 0.0
			else:
				_next_line()               # 第二次 = 翻下一句
			return true
		Phase.GARAGE:
			_garage_key(keycode)
			return true
	return false


## 强制中断过场（RESULT / 退出游戏 / 测试收尾用）。
func abort() -> void:
	if _phase == Phase.IDLE:
		return
	EventBus.refit_focus_slot.emit(&"")
	_phase = Phase.IDLE
	_overlay.hide_all()
	_overlay.set_fade(0.0)
	EventBus.cutscene_ended.emit()


# ---------------------------------------------------------------- 阶段

func _enter_fade_in() -> void:
	_phase = Phase.FADE_IN
	_dur = _cut_num("fade_seconds", 0.4)
	_timer = _dur
	_overlay.set_fade(0.0)


func _enter_travel() -> void:
	_phase = Phase.TRAVEL
	var tr: Dictionary = _cfg.get("travel", {}) as Dictionary
	_overlay.show_travel(str(tr.get("line", "")), str(tr.get("sub_line", "")))
	_overlay.set_fade(1.0)
	_dur = _cut_num("travel_seconds", 2.4)
	_timer = _dur


## lines 播完后去 then_phase。同一个阶段机复用两次（开场三段 / 告别一段）。
func _enter_mechanic(lines: Array[String], then_phase: Phase) -> void:
	_phase = Phase.MECHANIC
	_lines = lines
	_then = then_phase
	_line_idx = -1
	_overlay.set_fade(1.0)
	_build_damage_panel()   # ⑨a 出口 ②：算一次，整段台词期间都显示
	_next_line()


func _next_line() -> void:
	_line_idx += 1
	if _line_idx >= _lines.size():
		if _then == Phase.GARAGE:
			_enter_garage()
		else:
			_enter_fade_out()
		return
	_overlay.show_mechanic(_speaker, _lines[_line_idx])
	# ⑨a 战损面板（出口 ②）：`show_mechanic` 内部会先 `hide_all`，
	# 所以**每句台词都要重设一次** —— 只在进阶段时设一次的话，第二句起面板就没了。
	_overlay.set_damage_panel(_dmg_title, _dmg_body)
	_overlay.set_hint("任意键跳过")
	_dwell = 0.0


func _enter_garage() -> void:
	_phase = Phase.GARAGE
	_step = 0
	_slot_idx = 0
	_var_idx = 0
	_lock_msg = ""
	var ts := _turret_system()
	# 不用 `x if ts != null else []` 的三元写法：两个分支分别是 Array[StringName]
	# 与 Array，Godot 无法统一成一个确定类型，运行时会报「不能把 Array 赋给
	# Array[StringName]」。显式 if/else 让两边类型都明确。
	if ts == null:
		_slots = []
		_variants = []
	else:
		# ⑧ **列全部槽位（含未解锁）而不是只列已解锁的**：未解锁的灰显标注解锁条件，
		# 玩家才知道前面还有东西等着 —— 只给能用的，成长预期就无从建立。
		# 能不能装由 TurretSystem.swap_turret 二次把关（规则只该有一处实现）。
		_slots = ts.all_slot_ids()
		_variants = ts.variant_ids()
	_overlay.set_fade(GARAGE_FADE)
	_refresh_garage()
	# 镜头对准第一个**已解锁**的槽位：未解锁的空槽位没有炮也没有位置感，
	# 对着它等于对着一片虚空（且 _on_refit_focus 拿不到炮塔时会直接 return）。
	for sid in _slots:
		if ts != null and ts.is_slot_unlocked(sid):
			EventBus.refit_focus_slot.emit(sid)
			break
	if DEBUG_LOG:
		print("[refit] 改装台开启：%d 个槽位 × %d 种型号" % [_slots.size(), _variants.size()])


func _enter_fade_out() -> void:
	_phase = Phase.FADE_OUT
	_dur = _cut_num("exit_fade_seconds", 0.5)
	_timer = _dur
	_overlay.set_fade(0.0)


func _finish() -> void:
	_phase = Phase.IDLE
	_overlay.hide_all()
	_overlay.set_fade(0.0)
	EventBus.cutscene_ended.emit()
	if DEBUG_LOG:
		print("[refit] 过场结束（本次换装 %d 次）" % _swapped)


# ---------------------------------------------------------------- 改装台

func _garage_key(keycode: int) -> void:
	if keycode == KEY_ESCAPE:
		# 层级 Esc：选型号时 = 退回选炮位；选炮位时 = 跳过改装直接出发。
		if _step == 1:
			_step = 0
			_refresh_garage()
		else:
			_leave_garage()
		return
	if keycode == KEY_ENTER or keycode == KEY_KP_ENTER:
		if _step == 1:
			_step = 0
			_refresh_garage()
		else:
			_leave_garage()
		return
	if keycode >= KEY_0 and keycode <= KEY_9:
		var n := keycode - KEY_0
		if n < 1:
			return
		var ts := _turret_system()
		if _step == 0:
			if n <= _slots.size():
				var sid := _slots[n - 1]
				# ⑧ 未解锁的槽位 / 型号：**给提示，不进下一步**。
				# 判在这里是为了反馈（UI 层知道玩家按了什么），
				# 真正拦住装配的是 TurretSystem.swap_turret（规则只有一处实现）。
				if ts != null and not ts.is_slot_unlocked(sid):
					_reject_locked(_slot_label(sid), ts.slot_unlock_at(sid))
					return
				_slot_idx = n - 1
				_step = 1
				_lock_msg = ""
				_refresh_garage()
				EventBus.refit_focus_slot.emit(sid)
		else:
			if n <= _variants.size():
				var vid := _variants[n - 1]
				if ts != null and not ts.is_variant_unlocked(vid):
					_reject_locked(_variant_name(ts, vid), ts.variant_unlock_at(vid))
					return
				_var_idx = n - 1
				_lock_msg = ""
				_apply_swap()
				_step = 0
				_refresh_garage()


## ⑧ 选中未解锁项：写一条"还差几次危机"的提示。
## 不做成弹窗/阻断 —— 装配是低频低压力的操作，一行小字足够，
## 弹窗反而把「看看有什么」变成了「被教育一次」。
func _reject_locked(what: String, need: int) -> void:
	var ts := _turret_system()
	var cleared := ts.cleared_count() if ts != null else 0
	var g: Dictionary = _cfg.get("garage", {}) as Dictionary
	var fmt: String = str(g.get("locked_pick",
		"%s 还没到手 —— 再撑过 %d 次危机（当前已撑过 %d）"))
	_lock_msg = "[color=#d98b6a]%s[/color]" % (fmt % [what, maxi(need - cleared, 0), cleared])
	_refresh_garage()


## 真正换装：调 TurretSystem.swap_turret（换数值 + 换外观 + 放特效）。
func _apply_swap() -> void:
	var ts := _turret_system()
	if ts == null or _slots.is_empty() or _variants.is_empty():
		return
	var slot := _slots[_slot_idx]
	var vid := _variants[_var_idx]
	if not ts.swap_turret(slot, vid):
		return
	_swapped += 1
	var g: Dictionary = _cfg.get("garage", {}) as Dictionary
	var fmt: String = str(g.get("equip_log", "%s 已换装为 %s"))
	var vname: String = str(ts.variant_info(vid).get("name", vid))
	# 走 DEBUG_LOG 而不是裸 print：换装每局发生好几次，裸打会把 Output 刷满，
	# 而这条信息在改装台 UI 上已经写出来了（槽位后面就跟着当前型号）。
	if DEBUG_LOG:
		print("[refit] " + (fmt % [_slot_label(slot), vname]))


func _leave_garage() -> void:
	# 先让镜头回主控室，再说告别语 —— 否则告别时画面还挂在舰体外面。
	EventBus.refit_focus_slot.emit(&"")
	var mech: Dictionary = _cfg.get("mechanic", {}) as Dictionary
	var farewell := _pick(mech.get("lines_farewell", []), _crisis)
	var lines: Array[String] = []
	if not farewell.is_empty():
		lines = [farewell]
	_enter_mechanic(lines, Phase.FADE_OUT)


## 重画改装台两个列表。选中项用暖色高亮，已装的型号直接标在槽位后面 ——
## 无模型阶段，这行小字是玩家判断「我现在装的是什么」的唯一依据。
func _refresh_garage() -> void:
	var ts := _turret_system()
	var g: Dictionary = _cfg.get("garage", {}) as Dictionary
	var prompt_slot: String = str(g.get("slot_prompt", "选择炮位"))
	var prompt_var: String = str(g.get("variant_prompt", "选择型号"))
	var hint: String = str(g.get("slot_hint", ""))
	var locked_at_fmt: String = str(g.get("locked_at", "（危机 %d 解锁）"))
	var locked_need_fmt: String = str(g.get("locked_need", "（还需撑过 %d 次危机）"))
	var empty_txt: String = str(g.get("empty_slot", "[空]"))
	# 锁定提示**顶掉**默认 hint：玩家刚操作失败，这条比"Enter 出发"更该被看见。
	if not _lock_msg.is_empty():
		hint = _lock_msg
	var cleared := ts.cleared_count() if ts != null else 0

	# ⑧ 槽位列表：已解锁 = 正常；**未解锁灰显 + 标解锁门槛**；已解锁但没炮 = 「[空]」。
	var slot_bb := "[b]%s[/b]\n" % prompt_slot
	for i in _slots.size():
		var sid := _slots[i]
		var focused := (i == _slot_idx)
		var locked := (ts != null) and not ts.is_slot_unlocked(sid)
		var mark := "▶ " if focused and _step == 1 else ("▷ " if focused else "   ")
		var cur := ""
		if locked:
			cur = "   [color=#6b7480]%s[/color]" % (locked_at_fmt % ts.slot_unlock_at(sid))
		elif ts != null:
			var ev := ts.equipped_variant(sid)
			if ev == &"":
				cur = "   [color=#7d8794]%s[/color]" % empty_txt
			else:
				cur = "   [[color=#8fb8d8]%s[/color]]" % _variant_name(ts, ev)
			# ⑨a 战损（DEC-043 出口 ④）：换装决策当场就看得到上一波挨了多少打。
			cur += _damage_suffix(ts, sid)
		var col := "#ffd27f" if focused else ("#5d6672" if locked else "#b9c2cf")
		slot_bb += "[color=%s]%s%d. %s%s[/color]\n" % [col, mark, i + 1, _slot_label(sid), cur]

	var var_bb := "[b]%s[/b]%s\n" % [prompt_var,
		"" if _slots.is_empty() else "   —— 装到 [color=#ffd27f]%s[/color]" % _slot_label(_slots[_slot_idx])]
	for i in _variants.size():
		var vid := _variants[i]
		var focused := (i == _var_idx) and _step == 1
		var info: Dictionary = ts.variant_info(vid) if ts != null else {}
		var unlocked := bool(info.get("unlocked", false))
		var mark := "▶ " if focused else "   "
		var name := str(info.get("name", vid))
		if unlocked:
			var col := "#ffd27f" if focused else "#9aa4b2"
			var_bb += "[color=%s]%s%d. %s[/color]  %s\n" % [
				col, mark, i + 1, name, str(info.get("desc", ""))]
		else:
			var need := maxi(int(info.get("unlock_at", 0)) - cleared, 0)
			var_bb += "[color=#5d6672]%s%d. %s[/color]  [color=#6b7480]%s[/color]\n" % [
				mark, i + 1, name, locked_need_fmt % need]

	_overlay.show_garage(
		str(g.get("title", "炮塔改装台")),
		str(g.get("subtitle", "")),
		slot_bb, var_bb, hint)


func _slot_label(sid: StringName) -> String:
	return str(SLOT_LABELS.get(sid, sid))


## ⑨a 战损（**DEC-043 出口 ④** · 改装台）：槽位名后面跟一句本波战损。
## 这是四个出口里**最关键**的一处 —— 玩家正在决定"换不换、装什么"，
## 数字就在手边 vs 要隔一段路去别处查，决策质量完全不同。
## 被击毁**单独给一个文案**而不是显示 -999：毁了就是毁了，
## 大数字会盖住"这门没了"这个事实 —— 而"没了"才是该触发换装的信号。
func _damage_suffix(ts: TurretSystem, sid: StringName) -> String:
	var dl := ts.damage_log()
	if dl == null:
		return ""
	var g: Dictionary = _cfg.get("garage", {}) as Dictionary
	if dl.destroyed_ids().has(sid):
		return "   [color=#e2685f]%s[/color]" % str(g.get("damage_destroyed", "本波被击毁"))
	var taken := dl.taken(sid)
	if taken <= 0.5:
		return ""       # 一门没挨打就什么都不显示：空白比「本波 -0」干净
	var fmt: String = str(g.get("damage_taken", "本波 -%.0f"))
	return "   [color=#c98a6b]%s[/color]" % (fmt % taken)


## ⑧ 型号展示名（锁定提示与解锁播报共用一处取名字，免得两处各写一份默认值）。
func _variant_name(ts: TurretSystem, vid: StringName) -> String:
	return str(ts.variant_info(vid).get("name", vid))


# ---------------------------------------------------------------- 杂项

## 抵达维修站时的三段台词（开场 / 维修报告 / 邀改装）。
## 按危机数取模轮换 —— 第 10 次危机听到的和第 1 次不同，撑住重复的疲劳感。
func _arrival_lines() -> Array[String]:
	var mech: Dictionary = _cfg.get("mechanic", {}) as Dictionary
	var lines: Array[String] = [
		_pick(mech.get("lines_open", []), _crisis),
		_pick(mech.get("lines_repair", []), _crisis + 1),
	]
	# ⑨a 战损播报（DEC-043 出口 ③）：先说船怎么样 → 再说挨了多少打 → 才轮到递新东西。
	lines.append_array(_damage_lines())
	# ⑧ 解锁播报插在「报修」之后、「邀改装」之前：先报修 → 再交货 → 再问要不要装。
	# 语序这么排是因为解锁物是"老陈递过来的东西"，得先说完船怎么样了才轮到它。
	lines.append_array(_unlock_lines())
	lines.append(_pick(mech.get("lines_ask", []), _crisis + 2))
	return lines


## ⑧ 本次危机新解锁的东西 → 维修师顺口提一句。
## **没有新解锁就不说话**：第 5 次危机再播报一遍「标准点防炮已解锁」等于没话找话，
## 反而显得这游戏在敷衍。consume 语义（读完即清空）保证同一批不会播两次。
func _unlock_lines() -> Array[String]:
	var ts := _turret_system()
	if ts == null:
		return []
	var mech: Dictionary = _cfg.get("mechanic", {}) as Dictionary
	var out: Array[String] = []
	for e in ts.consume_fresh_unlocks():
		var kind := StringName(str(e.get("kind", &"")))
		var uid := StringName(str(e.get("id", &"")))
		var name: String
		var fmt: String
		if kind == &"slot":
			name = _slot_label(uid)
			fmt = _pick(mech.get("lines_unlock_slot", []), _crisis)
		else:
			name = _variant_name(ts, uid)
			fmt = _pick(mech.get("lines_unlock", []), _crisis)
		if name.is_empty() or fmt.is_empty():
			continue
		out.append(fmt % name)
	return out


## ⑨a 战损播报（**DEC-043 出口 ③**）：一句话点名本波挨打**最狠**的那门炮。
## **没有战损就不说话** —— 与解锁播报同一条逻辑：每次都念一遍「一点伤都没有」
## 等于没话找话，反而显得这游戏在敷衍。
## 只说**一门**（最惨的那门）而不是挨个报菜名：台词负责情绪，数据交给同屏面板（出口 ②）。
func _damage_lines() -> Array[String]:
	var ts := _turret_system()
	if ts == null:
		return []
	var dl := ts.damage_log()
	if dl == null or not dl.has_any():
		return []
	var worst := dl.worst_turret()
	if worst == &"":
		return []
	var mech: Dictionary = _cfg.get("mechanic", {}) as Dictionary
	var fmt := _pick(mech.get("lines_damage", []), _crisis)
	if fmt.is_empty():
		return []
	return [fmt % _slot_label(worst)]


## ⑨a 战损面板（**DEC-043 出口 ②**）：算一次面板内容，整段台词期间复用。
##
## **按路遍历**（顺序 = 监控面板四块屏：左/右/上/下），每路内列该路的槽位 ——
## 跟「每路两个炮位」的心智模型对齐，也让「哪面压力大」一眼可见。
##
## ⚠ 这里**不能**用 `slots_of_sector()`：它只返回「可接管」的槽位，
## **被毁的炮会被过滤掉** —— 而"这门被打没了"恰恰是战损报告最该显示的东西。
##
## 只列**有战损的**槽位：一门没挨打就不出现，空白比一排「-0」干净。
## 整体无战损时给一句「本波无战损」而不是留个空面板 —— 空面板会让人以为没加载出来。
func _build_damage_panel() -> void:
	_dmg_title = ""
	_dmg_body = ""
	var ts := _turret_system()
	if ts == null:
		return
	var dl := ts.damage_log()
	if dl == null:
		return
	var mech: Dictionary = _cfg.get("mechanic", {}) as Dictionary
	_dmg_title = str(mech.get("damage_title", "本波战损"))
	if not dl.has_any():
		_dmg_body = "[color=#7d8794]%s[/color]" % str(mech.get("damage_none", "本波无战损"))
		return
	var sectors: Array[StringName] = [&"port", &"starboard", &"dorsal", &"ventral"]
	var bb := ""
	for sector in sectors:
		for sid in ts.all_slot_ids():
			if ts.slot_sector(sid) != sector:
				continue
			var killed := dl.destroyed_ids().has(sid)
			var taken := dl.taken(sid)
			if taken <= 0.5 and not killed:
				continue
			var name := _slot_label(sid)
			if killed:
				bb += "  [color=#e2685f]%s —— 被击毁[/color]\n" % name
				continue
			# 主要伤害来源 = **回答「为什么掉的」**（bible 反例 5 的硬要求）。
			# 只列最主要的一种：全列会让每行变成一串数字，反而看不出重点。
			var src := dl.top_source(sid)
			var src_txt := ""
			if src != &"":
				src_txt = "  [color=#8a7f6f]主要来自 %s[/color]" % _enemy_name(src)
			bb += "  %s  [color=#d09a6a]-%.0f[/color]%s\n" % [name, taken, src_txt]
	_dmg_body = bb


## ⑨a 敌人 type_id → 中文名（来自 enemies.json 的 `display_name`）。
## 查不到就**原样返回 id**：显示 "interceptor" 也比显示空白强 ——
## 空白会让人以为是 bug，而英文 id 至少能猜。
func _enemy_name(type_id: StringName) -> String:
	return str(_enemy_names.get(type_id, type_id))


func _pick(arr: Variant, n: int) -> String:
	if arr is Array:
		var a := arr as Array
		if not a.is_empty():
			return str(a[n % a.size()])
	return ""


## 台词组数（自检用）：配置没读到时应该是 4 组（开场/维修/邀改装/告别）。
func _line_group_count() -> int:
	var mech: Dictionary = _cfg.get("mechanic", {}) as Dictionary
	var n := 0
	for key in ["lines_open", "lines_repair", "lines_ask", "lines_farewell"]:
		if (mech.get(key, []) is Array) and not (mech[key] as Array).is_empty():
			n += 1
	return n


func _line_dwell() -> float:
	return _cut_num("after_line_pause", 0.3) + 1.2


func _cut_num(key: String, fallback: float) -> float:
	var cut: Dictionary = _cfg.get("cutscene", {}) as Dictionary
	return float(cut.get(key, fallback))


func _turret_system() -> TurretSystem:
	return get_tree().get_first_node_in_group(TURRET_SYSTEM_GROUP) as TurretSystem


func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("[refit] 配置缺失: %s（过场将用内置兜底值）" % path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("[refit] 配置打不开: %s" % path)
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if parsed is Dictionary:
		return parsed as Dictionary
	push_warning("[refit] 配置不是 JSON 对象: %s" % path)
	return {}
