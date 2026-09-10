extends Node
class_name DamageLog

## ⑨a 战损记录（**DEC-043 决定 1** 的数据层）
##
## **一句话**：订阅伤害事件，按「本波」累计每门炮挨了多少打、被谁打的。
## 四个出口（① 主控室 HUD / ② 维修站面板 / ③ 维修师台词 / ④ 改装台）
## **共用这一份数据** —— 它们只是同一份数字的四个展示位，不是四个功能（DEC-043）。
##
## **为什么记「本波」而不是「累计」**：战损报告要回答的是「上一波哪门炮挨打了」。
## 跨波累计会让"这波刚挨的打"被历史数据淹没，玩家看不出该改哪门 —— 决策价值归零。
##
## **清空时机 = 开战**（由 `TurretSystem.set_battle_active(true)` 调 `reset()`）。
## 挂在开战而不是"危机清空"上，是为了让整条 REFIT 链
## （维修站 → 维修师 → 改装台）全程都能读到上一波的数据。
## 顺序上它也正好和「开战回满耐久」挨在一起，两件事一起发生，心智上说得通。
##
## **不自己判死活 / 不自己算扇区**：本类只记账。扇区从 TurretSystem 现查一次后缓存，
## 「这门炮是不是死了」由 `turret_destroyed` 事件告知 —— 判断归编排层，记账归本类。

const DEBUG_LOG := false

## 每门炮一条：`{"taken": float, "by_type": Dictionary, "destroyed": bool, "sector": StringName}`。
## `by_type` 键 = 敌人类型 id（interceptor / bomber），值 = 该类型造成的伤害合计。
## **空来源记为 `unknown`**：`take_damage` 的 source_id 有默认值，
## 测试或未来的无来源伤害会走进来，留个兜底比假装没发生好。
var _per_turret: Dictionary = {}


func _ready() -> void:
	EventBus.turret_damaged.connect(_on_turret_damaged)
	EventBus.turret_destroyed.connect(_on_turret_destroyed)
	if DEBUG_LOG:
		print("[dmg] 战损记录就绪（等开战时 reset）")


# ── 记账入口（只被 EventBus 调用，业务代码别直接调）────────────────

## 伤害是**连续的**（bible 02 §四：进入攻击距离后持续 dps），
## 所以这里每帧都会被调一次，不是"挨了一发"调一次。amount 通常很小。
func _on_turret_damaged(turret_id: StringName, amount: float, source_id: StringName) -> void:
	if amount <= 0.0:
		return
	var e := _entry(turret_id)
	e["taken"] = float(e.get("taken", 0.0)) + amount
	var key: StringName = source_id if source_id != &"" else &"unknown"
	var by_type: Dictionary = e.get("by_type", {}) as Dictionary
	by_type[key] = float(by_type.get(key, 0.0)) + amount
	e["by_type"] = by_type


func _on_turret_destroyed(turret_id: StringName, sector: StringName) -> void:
	var e := _entry(turret_id)
	e["destroyed"] = true
	e["sector"] = sector       # 事件带了就用事件的（比现查准，此时炮已死）
	if DEBUG_LOG:
		print("[dmg] %s 被毁（扇区 %s，本波承伤 %.0f）" % [
			turret_id, sector, float(e.get("taken", 0.0))])


# ── 查询 API（四个出口都从这里取数）────────────────────────────────

## 本波该门炮承伤合计。没挨过打 = 0。
func taken(turret_id: StringName) -> float:
	if not _per_turret.has(turret_id):
		return 0.0
	return float((_per_turret[turret_id] as Dictionary).get("taken", 0.0))


## 本波该门炮被**某种敌人**打了多少（回答「为什么掉的」）。
func taken_by_type(turret_id: StringName, type_id: StringName) -> float:
	if not _per_turret.has(turret_id):
		return 0.0
	var by_type: Dictionary = (_per_turret[turret_id] as Dictionary).get("by_type", {}) as Dictionary
	return float(by_type.get(type_id, 0.0))


## 该门炮本波的**主要伤害来源**（挨打最多的那种敌人）。没挨打返回 &""。
## ③ 维修师台词与 ① HUD 都靠它把「被打穿了」说成「被轰炸机打穿了」——
## 后者才是能指导配装的信息（"该换打重甲的了"）。
func top_source(turret_id: StringName) -> StringName:
	if not _per_turret.has(turret_id):
		return &""
	var by_type: Dictionary = (_per_turret[turret_id] as Dictionary).get("by_type", {}) as Dictionary
	var best: StringName = &""
	var best_val := 0.0
	for k in by_type:
		var v := float(by_type[k])
		if v > best_val:
			best_val = v
			best = k
	return best


## 本波**全局**被某种敌人打掉的耐久合计（不分哪门炮）。
## 用于「这波压力主要来自哪种敌人」这种整局判断。
func by_type_total(type_id: StringName) -> float:
	var total := 0.0
	for id in _per_turret:
		total += taken_by_type(id, type_id)
	return total


## 本波该**扇区（= 那路 feed）**承伤合计。
## 回答 DEC-043 战损报告的核心问题之一：「哪面压力大」。
func sector_taken(sector: StringName) -> float:
	var total := 0.0
	for id in _per_turret:
		var e := _per_turret[id] as Dictionary
		if StringName(e.get("sector", &"")) == sector:
			total += float(e.get("taken", 0.0))
	return total


## 本波被摧毁的炮塔 id 列表（按被毁顺序）。
func destroyed_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for id in _per_turret:
		if bool((_per_turret[id] as Dictionary).get("destroyed", false)):
			out.append(id)
	return out


## 本波**承伤最多**的那门炮（③ 维修师台词点名用）。一门都没挨打返回 &""。
func worst_turret() -> StringName:
	var best: StringName = &""
	var best_val := 0.0
	for id in _per_turret:
		var v := float((_per_turret[id] as Dictionary).get("taken", 0.0))
		if v > best_val:
			best_val = v
			best = id
	return best


## 本波有没有任何战损（③ 台词与 ② 面板靠它决定"值不值得说/显示"）。
## **没有战损就不播报** —— 每次都念一遍"一点伤都没有"等于没话找话（同 DEC-042 解锁播报的逻辑）。
func has_any() -> bool:
	var total := 0.0
	for id in _per_turret:
		total += float((_per_turret[id] as Dictionary).get("taken", 0.0))
	return total > 0.0


## 本波承伤总计。
func total_taken() -> float:
	var total := 0.0
	for id in _per_turret:
		total += float((_per_turret[id] as Dictionary).get("taken", 0.0))
	return total


## 清空（开战时由 TurretSystem 调）。
func reset() -> void:
	_per_turret.clear()
	if DEBUG_LOG:
		print("[dmg] 战损已清空（新一波开始）")


## 调试用：把本波战损打成一行。
func dump_line() -> String:
	if not has_any():
		return "本波无战损"
	var parts: Array[String] = []
	for id in _per_turret:
		var e := _per_turret[id] as Dictionary
		var s := "%s:%.0f" % [id, float(e.get("taken", 0.0))]
		if bool(e.get("destroyed", false)):
			s += "(毁)"
		parts.append(s)
	return "本波战损 " + " ".join(parts)


# ── 内部 ────────────────────────────────────────────────────────

## 惰性建条目。**sector 现查一次后缓存**：伤害事件不带扇区，而扇区又几乎不变
## （换装保留 sector，见 swap_turret），没必要每帧查。查不到就留空，
## `sector_taken` 自然算不进去 —— 宁可少算也别猜，猜错比漏掉更糟。
func _entry(turret_id: StringName) -> Dictionary:
	if not _per_turret.has(turret_id):
		var sector: StringName = &""
		var ts := get_parent() as TurretSystem
		if ts != null:
			var t := ts.get_turret(turret_id)
			if t != null:
				sector = t.sector
		_per_turret[turret_id] = {
			"taken": 0.0,
			"by_type": {},
			"destroyed": false,
			"sector": sector,
		}
	return _per_turret[turret_id] as Dictionary
