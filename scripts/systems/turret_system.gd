extends Node3D
class_name TurretSystem

## 炮塔编排系统（MODULES §四 Round 1 + Round 2）
##
## **职责**：
##   ① _ready 时建所有炮塔（Round 1：1 主炮；Round 2：+ 4 副炮）
##   ② _physics_process 推进每个 turret.advance(delta) + 收尾 Projectile
##   ③ 接管路由：玩家按 1-5 或点 feed → 目标 turret 切 MANUAL（切相机在 bridge_whitebox）
##   ④ 监听 GameState：BATTLE 进入时 enable auto，REFIT 进入时 disable
##   ⑤ 炮塔耐久：每波开战回满、被毁后踢出接管、扇区失守与全毁广播
##   ⑦ 换装：把某槽位的炮整体换成另一种型号（数值 + 外观）
##   ⑧ 解锁：撑过的危机数驱动，自动解锁新型号 / 新槽位（DEC-033 / DEC-042）
##
## **不在本类里写具体炮塔逻辑**：开火 / 瞄准 / 扣血都在 Turret 基类。
## 本类只做「编排」（instantiate + per-frame tick + 切换）。
##
## **切相机不在本类**：接管时主视角要搬到舰体外表面（DEC-038），那是**场景**的事
## —— bridge_whitebox 拥有 Player / _yaw / _pitch，本类越权去改会破坏转头状态。
## 故本类只 emit `turret_takeover_started/ended`，由 bridge_whitebox 订阅并执行搬移。
##
## **数值外置**：turrets.json 是唯一真源；本类读 JSON 注入 turret.configure(dict)。
##
## **DEC-040 · 多门炮各自独立开火**：同一位置/同一扇区装多门炮时，**不做 DPS 合并**，
## 每门一个 Turret 实例、各自维护 cooldown、各自锁敌、各自发射。
## 理由：同位置多门可能不是同一种炮（速射小炮 + 慢速重炮混装），合并成一个 DPS
## 在数学上无意义（节奏不同），且会抹平装配决策。详见 docs/bible/99_decisions.md。

const DATA_PATH := "res://data/turrets.json"

## 【日志纪律 2026-09-05】新模块打开 print，验证完改 false。
## 日志覆盖：初始化 / BATTLE 切换 / 接管 / 释放。
const DEBUG_LOG := false

## ⑦ 换装特效时长（秒）。**没有外置到 JSON**：这是纯演出手感，跟玩法数值无关，
## 外置反而增加一层间接；真要调就改这三个常量。
const SWAP_RETIRE_SEC := 0.35
const SWAP_INSTALL_SEC := 0.45
const SWAP_RING_SEC := 0.55

## 子弹活跃列表（Turret._fire 时 append，advance 返回 false 时 erase）。
## 不在 _physics_process 收尾而是用 list comprehension 一次筛掉，避免迭代器失效。
var _projectiles: Array[Projectile] = []

## 所有炮塔（键 = turret_id）。Round 1 只有 main；Round 2 加 4 sub。
var _turrets: Dictionary = {}

## ⑦ 可选炮塔类型库（键 = variant_id，值 = turrets.json 的 variants 段原样）。
## 改装时按 id 取一份配置整体替换某门炮 —— 数值与外观都从这儿来。
var _variants: Dictionary = {}

## ⑦ 每门炮**当前装的是哪种**（键 = turret_id，值 = variant_id）。
## 单独记一份而不是从 Turret 反查：Turret 只持有展开后的数值，
## 拿数值去反推"这是哪种炮"既脆弱又没必要（两种炮数值可能相同）。
## 空槽位**不在本字典里**（equipped_variant 返回 &""）—— 有炮才有型号。
var _equipped: Dictionary = {}

## ⑧ 槽位定义（键 = slot_id，值 = {"mount": Vector3, "sector": StringName, "unlock_at": int}）。
## **含未解锁的槽位**：定义是「船上有这么个炮座」这个物理事实，与解没解锁无关；
## 解锁状态另存 _unlocked_slots。分开存是为了让 UI 能灰显"危机 2 解锁"的槽位 ——
## 只存已解锁的话，玩家永远不知道前面还有东西等着。
var _slot_defs: Dictionary = {}

## ⑧ 已解锁槽位（有序，与 _slot_defs 的插入序一致）。槽位**可以没有炮**（空槽）。
var _unlocked_slots: Array[StringName] = []

## ⑧ 已解锁的炮塔型号。开局由 _sync_unlocks(0) 填充（flak）。
var _unlocked_variants: Array[StringName] = []

## ⑧ 撑过的危机数 = 解锁进度。由 EventBus.crisis_cleared 驱动自增，
## 不读 WaveSystem.crisis_cleared —— 那边是「波次」的计数，本系统只该知道
## 「又撑过一次」这件事，两个概念将来可能分家（例如跳过波次 / 特殊事件）。
var _cleared := 0

## ⑧ 本次危机**新**解锁的项（Array[Dictionary]：{"kind": &"variant"|&"slot", "id": StringName}）。
## 供维修师台词播报；由 RefitSequence 读过展名字后 consume 掉。
## 只记"新"的：第 5 次危机时再播报一遍 flak 已解锁，等于没话找话。
var _fresh_unlocks: Array[Dictionary] = []

## ⑦ 换装特效的常驻父节点（在 _ready 里建）。见 _play_shock_ring 的注释。
var _fx_root: Node3D

## ⑨a 战损记录（在 _ready 里建 + add_child）。**DEC-043：四个出口共用这一份数据**。
## 做成**子节点而不是普通成员变量**，是因为它要订阅 EventBus —— 进了树才有 _ready，
## 才能在自己内部连线；否则得靠本类代收再转发一次，凭空多一层间接。
## 挂自己名下也保证生命周期一致（本类没了它也跟着没）。
var _damage_log: DamageLog

## 系统节点 group 名。系统之间**不硬编码节点路径**（记忆 tooling.md 约定）：
## WaveSystem / RefitSequence 都靠这个 group 找到本系统。
const SYSTEM_GROUP := &"turret_system"

## 主炮固定不可换（DEC-030：主炮固定正面）。改装 UI 据此过滤槽位。
const MAIN_ID := &"main"

## 当前被接管的炮塔 id（&"" 表示未接管）。供 bridge_whitebox 读，决定 ESC 行为。
var current_manual_id: StringName = &""


## 由 Turret 发射后调用：把弹丸纳入本系统的统一推进。
## 返回 true = 已接管（调用方应关掉弹丸自带的 _physics_process，避免一帧推两次）。
## 返回 false = 未接管（弹丸靠自己的 _physics_process 兜底，仍能飞，只是不受本系统管理）。
func register_projectile(p: Projectile) -> bool:
	if p == null:
		return false
	if _projectiles.has(p):
		return true
	_projectiles.append(p)
	return true


## 按 id 取炮塔（公共 getter）。bridge_whitebox 用来读 muzzle_pos 给 LeadPrediction marker。
## 返回 null 表示该 id 未注册（Round 2 副炮待接入时常见）。
func get_turret(id: StringName) -> Turret:
	return _turrets.get(id, null) as Turret


## 列所有已注册的炮塔 id。诊断 / HUD 用。
func registered_ids() -> Array:
	return _turrets.keys()


## ⑦⑧ 可改装的槽位 id 列表 = **已解锁**的槽位（含空槽；主炮固定不可换 DEC-030）。
##
## ⚠ 与 `_turrets` 是两回事：`_turrets` 是「已装上的炮」，本函数是「能装炮的位置」。
## 扩展槽位解锁后是**空的** —— 它在本列表里，但 get_turret() 返回 null，这是正常的，
## 不是 bug。改装台靠这个区别渲染「[空]」并让玩家装第一门炮。
##
## 顺序稳定（起始 4 槽 → 扩展槽），别让调用方自己去过滤 main。
func swappable_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for id in _unlocked_slots:
		out.append(id)
	return out


## ⑧ **全部**槽位 id（含未解锁）。改装台靠它灰显"危机 2 解锁"的槽位 ——
## 只给已解锁列表的话，玩家不知道前面还有东西等着，成长预期无从建立。
func all_slot_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for id in _slot_defs:
		out.append(id)
	return out


## ⑧ 某扇区（= 某路 feed）当前**可接管**的槽位 id，按槽位定义顺序。
##
## 过滤掉三类不能接管的：未解锁的、还没装炮的空槽位、已被毁的死炮 ——
## 接管到它们会得到「按扳机毫无反应 / 相机不动」的假故障。
func slots_of_sector(sector: StringName) -> Array[StringName]:
	var out: Array[StringName] = []
	for sid in _slot_defs:
		var sd: Variant = _slot_defs[sid]
		if not (sd is Dictionary):
			continue
		if StringName(str((sd as Dictionary).get("sector", &""))) != sector:
			continue
		if not _unlocked_slots.has(sid):
			continue
		var t := _turrets.get(sid, null) as Turret
		if t == null or t.destroyed:
			continue
		out.append(sid)
	return out


## ⑧ 该槽位是否已解锁。
func is_slot_unlocked(slot_id: StringName) -> bool:
	return _unlocked_slots.has(slot_id)


## ⑧ 该槽位的解锁门槛（撑过 N 次危机）。未定义的槽位返回 99（= 永不解锁）。
func slot_unlock_at(slot_id: StringName) -> int:
	var d: Variant = _slot_defs.get(slot_id, null)
	if d is Dictionary:
		return int((d as Dictionary).get("unlock_at", 99))
	return 99


## ⑧ 槽位的**物理位置**（即使还没装炮也有值）。
## 改装台聚焦空槽位时，相机要靠它定位 —— 没炮就问不到 muzzle_pos。
func slot_mount(slot_id: StringName) -> Vector3:
	var d: Variant = _slot_defs.get(slot_id, null)
	if d is Dictionary:
		var v: Variant = (d as Dictionary).get("mount", null)
		if v is Vector3:
			return v as Vector3
	return Vector3.ZERO


## ⑧ 槽位所属扇区。扩展槽位与它加装的那面同扇区（port2 → port），
## 于是「两门都死了才算左舷失守」天然成立，不需要额外判定。
func slot_sector(slot_id: StringName) -> StringName:
	var d: Variant = _slot_defs.get(slot_id, null)
	if d is Dictionary:
		return StringName(str((d as Dictionary).get("sector", &"")))
	return &""


## ⑧ 该型号是否已解锁。改装台据此灰显 / 拒绝装配。
func is_variant_unlocked(variant_id: StringName) -> bool:
	return _unlocked_variants.has(variant_id)


## ⑧ 该型号的解锁门槛（撑过 N 次危机）。
func variant_unlock_at(variant_id: StringName) -> int:
	var v: Variant = _variants.get(variant_id, null)
	if v is Dictionary:
		return int((v as Dictionary).get("unlock_at_crisis", 99))
	return 99


## ⑧ 已解锁的型号（改装台真正能装进去的）。
func unlocked_variant_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for id in _unlocked_variants:
		out.append(id)
	return out


## ⑧ 撑过的危机数 = 解锁进度。HUD 与改装台标题显示用。
func cleared_count() -> int:
	return _cleared


## ⑧ 本次危机**新**解锁的项（只读，不清空）。
## 元素 = {"kind": &"variant" | &"slot", "id": StringName}
func fresh_unlocks() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in _fresh_unlocks:
		out.append(e)
	return out


## ⑧ 取走本次新解锁清单（**读完即清空**，避免下次过场重复播报）。
func consume_fresh_unlocks() -> Array[Dictionary]:
	var out := fresh_unlocks()
	_fresh_unlocks.clear()
	return out


## ⑦ 可选炮塔类型 id 列表（turrets.json 的 variants 段，下划线键已剔除）。
func variant_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for k in _variants:
		if str(k).begins_with("_"):
			continue
		out.append(StringName(str(k)))
	return out


## ⑦ 取某类型的展示信息（名称 / 描述 / 关键数值），改装 UI 与测试都用它。
## 只回 UI 需要的字段，不把整份配置丢出去 —— 免得 UI 顺手去读内部键。
func variant_info(variant_id: StringName) -> Dictionary:
	# 显式 Variant：Dictionary.get 返回 Variant，`var v :=` 会被推断成 Variant
	# 而触发「从 Variant 推断」告警 —— 本工程把告警当错误，必须写类型。
	var v: Variant = _variants.get(variant_id, null)
	if v is Dictionary:
		var d := v as Dictionary
		return {
			"id": variant_id,
			"name": str(d.get("display_name", variant_id)),
			"desc": str(d.get("desc", "")),
			"dps": float(d.get("auto_dps", 0.0)),
			"damage": float(d.get("projectile_damage", 0.0)),
			"interval": float(d.get("auto_fire_interval", 0.0)),
			"range": float(d.get("range", 0.0)),
			"hp": float(d.get("hp", 0.0)),
			# ⑧ 解锁信息一并返回：改装台要灰显未解锁项并写出解锁条件，
			# 与其让它再调一次 is_variant_unlocked，不如一次拿全。
			"unlocked": is_variant_unlocked(variant_id),
			"unlock_at": variant_unlock_at(variant_id),
		}
	return {}


## ⑦ 某门炮当前装的 variant_id（主炮返回 &""）。
func equipped_variant(turret_id: StringName) -> StringName:
	return StringName(str(_equipped.get(turret_id, &"")))


## 按注册顺序返回所有炮塔实例（HUD 显血 / 诊断用）。
## 走出参数组而不是让调用方遍历 registered_ids()：那边拿回来的是 Variant，
## 每次都要 `StringName(str(id))` 转一道才能喂给 get_turret，容易漏。
func all_turrets() -> Array[Turret]:
	var out: Array[Turret] = []
	for id in _turrets:
		var t := _turrets[id] as Turret
		if t != null:
			out.append(t)
	return out


## 仍存活（未被毁）的炮塔数。0 = 本局失败条件（DEC-037）。
func alive_count() -> int:
	var n := 0
	for id in _turrets:
		var t := _turrets[id] as Turret
		if t != null and t.is_alive():
			n += 1
	return n


## 每波开战回满所有炮塔（bible 02 §二：无维修经济，每波开始自动回满）。
## 由 set_battle_active(true) 统一调用，不在 bridge_whitebox 里单独调 ——
## 否则「测试里手动开战」和「正式开战」会走两条路，回满这条规则就有可能漏掉。
func restore_all() -> void:
	for id in _turrets:
		var t := _turrets[id] as Turret
		if t != null:
			t.restore()


## ⑨a 战损记录（**DEC-043：四个出口共用这一份数据**）。
## 出口 = ① 主控室 HUD / ② 维修站面板 / ③ 维修师台词 / ④ 改装台。
## 返回 null 只在「_ready 之前就被问到」这种极端情况；调用方判一下即可
## （与 refit_sequence 的 `_turret_system()` 一个套路）。
func damage_log() -> DamageLog:
	return _damage_log

## 建炮塔 + 打一行自检日志。
## 日志里列出每门炮的 炮位 / 射程 / 耐久，试玩前扫一眼就能发现 JSON 改坏了
## （典型：hull_radius 写错 → 炮位跑到船体内；mount 手工覆盖 → 与 axis 推导值不符）。
func _ready() -> void:
	add_to_group(SYSTEM_GROUP)
	# ⑦ 换装特效的专用父节点。特效要挂在一个**不会被释放**的节点下：
	# 旧炮塔马上 queue_free，挂它身上特效会跟着没；挂 get_tree().get_root() 又会在
	# 「root 正在 setup 子节点」时 add_child 失败（实测 ERROR，见记忆 godot_pitfalls）。
	_fx_root = Node3D.new()
	_fx_root.name = "SwapFXRoot"
	add_child(_fx_root)
	_load_and_build_turrets()
	# ⑨a 战损记录。**放在建炮之后挂**：DamageLog 记账时要向本类查炮塔所属扇区，
	# 而 add_child 会立刻触发它的 _ready（连 EventBus）—— 先进树后建炮的话，
	# 理论上存在「炮塔还没建好就收到事件」的窗口。顺序反过来就没这个隐患。
	_damage_log = DamageLog.new()
	_damage_log.name = "DamageLog"
	add_child(_damage_log)
	# ⑧ 开局解锁（flak + 4 个起始槽位）**静默**处理：不 emit、不记 fresh。
	# 理由：emit 会让订阅方在各自的 _ready 还没跑完时就收到信号（本节点的 _ready
	# 早于 RefitSequence），那时对方还没准备好；而"开局就有的东西"也不是成长事件，
	# 没有播报价值。真正的解锁播报从第一次危机清空开始。
	_sync_unlocks(0, true)
	# ⑤ 被毁事件由 Turret 发，本系统做「扇区失守 / 全毁」的**聚合判定** ——
	# Turret 自己不知道还有几门炮活着，这种全局结论只能由编排层下。
	EventBus.turret_destroyed.connect(_on_turret_destroyed)
	# ⑧ 撑过一次危机 = 解锁进度 +1。本系统**自己数**而不是读 WaveSystem 的字段。
	EventBus.crisis_cleared.connect(_on_crisis_cleared)
	if DEBUG_LOG:
		print("[turret] 系统就绪，已建 %d 门炮塔: %s" % [_turrets.size(), str(_turrets.keys())])
		print("[turret] 默认模式: 所有炮塔 AUTO（按 1-5 接管任一门进手动）")
		for id in _turrets:
			var t := _turrets[id] as Turret
			if t == null:
				continue
			print("[turret]   %-10s 扇区=%-10s 炮位=%s 射程=%.0f 耐久=%.0f" % [
				str(id), str(t.sector), str(t.muzzle_pos), t.fire_range, t.hp])


## 读 turrets.json 建炮塔：1 主炮（fore）+ 4 副炮（port/starboard/dorsal/ventral）。
##
## 副炮 mount 不写死坐标：由 sub_gun_instances 的 `axis × hull_radius` 推导
## （2026-09-06 预修复）。axis 与 Sectors.AXES 同向，hull_radius 来自船体尺寸。
func _load_and_build_turrets() -> void:
	var cfg: Dictionary = _load_json_dict(DATA_PATH)
	if cfg.is_empty():
		push_warning("[turret] turrets.json 缺失或解析失败，无炮塔可用")
		return

	# ⓪ ⑦ 炮塔类型库（改装用）。先于建炮塔读，swap_turret 随时可能用到。
	#    注意：variants.flak 的数值必须与 sub_gun_template **保持一致** ——
	#    template 是开局默认，flak 是「标准点防炮」，改了一个忘了另一个就会出现
	#    「UI 上写着装的是标准炮，实际数值对不上」的幽灵 bug。
	var v: Variant = cfg.get("variants", {})
	if v is Dictionary:
		_variants = (v as Dictionary).duplicate(true)
	else:
		push_warning("[turret] variants 缺失/非法，改装功能不可用")

	# ① 主炮（固定正面，DEC-030）
	if cfg.has("main_gun"):
		var mg: Dictionary = cfg["main_gun"] as Dictionary
		var mg_dict: Dictionary = mg.duplicate()
		mg_dict["id"] = &"main"
		mg_dict["sector"] = &"fore"
		_build_one_turret(mg_dict)

	# ② 副炮 × 4（Round 2 接入）
	#    数值共用 sub_gun_template；位置由 sub_gun_instances 的 hull_radius + axis 推导。
	#    DEC-040：每门一个独立 Turret 实例，各自 cooldown / 各自锁敌，不合并 DPS。
	#    → 将来同一扇区装多门异型炮（速射 + 重炮）时天然成立，无需改本函数。
	var tpl: Dictionary = cfg.get("sub_gun_template", {}) as Dictionary
	var inst: Variant = cfg.get("sub_gun_instances", {})
	if not (inst is Dictionary):
		push_warning("[turret] sub_gun_instances 缺失/非法，副炮不建")
		return
	var inst_dict := inst as Dictionary
	var built_n := 0
	for sector_key in inst_dict:
		var sector_id := StringName(str(sector_key))
		# JSON 里的 `_doc` 等下划线前缀键是给人看的注释，不是炮位
		if str(sector_key).begins_with("_"):
			continue
		var one: Variant = inst_dict[sector_key]
		if not (one is Dictionary):
			push_warning("[turret] sub_gun_instances.%s 不是对象，跳过" % sector_id)
			continue
		var one_dict := one as Dictionary
		var axis := _vec3_from(one_dict.get("axis", [0, 0, 1]), Vector3(0, 0, 1)).normalized()
		var radius := float(one_dict.get("hull_radius", 10.0))
		var mount: Vector3 = axis * radius
		# ⑧ 登记槽位定义（起始槽 unlock_at = 0，开局即解锁）。
		_register_slot(sector_id, sector_id, mount, 0)
		var sub_dict: Dictionary = tpl.duplicate()
		sub_dict["id"] = sector_id
		sub_dict["sector"] = sector_id
		# 键名映射：template 用 hp_per_gun / auto_dps_per_gun（强调「每门」的量），
		# Turret.configure 读的是 hp / auto_dps。这里做一次翻译，别在 Turret 里 if 分叉。
		sub_dict["hp"] = tpl.get("hp_per_gun", 80.0)
		sub_dict["auto_dps"] = tpl.get("auto_dps_per_gun", 8.0)
		sub_dict["mount"] = [mount.x, mount.y, mount.z]
		_build_one_turret(sub_dict)
		# 开局默认装「标准点防炮」（flak），与 sub_gun_template 同数值。
		_equipped[sector_id] = &"flak"
		built_n += 1
	if built_n == 0 and DEBUG_LOG:
		print("[turret] 未建出任何副炮：检查 turrets.json 的 sub_gun_instances")

	# ③ ⑧ 扩展槽位（DEC-042）：只登记定义，**不建炮**。
	#    解锁时是空的 —— 玩家得自己挑一门装上去，这个动作本身就是装配乐趣；
	#    自动送一门 flak 等于替玩家做了决定。
	var extra: Variant = cfg.get("extra_slots", {})
	if not (extra is Dictionary):
		return
	for key in (extra as Dictionary):
		if str(key).begins_with("_"):
			continue
		var one: Variant = (extra as Dictionary)[key]
		if not (one is Dictionary):
			push_warning("[turret] extra_slots.%s 不是对象，跳过" % str(key))
			continue
		var d := one as Dictionary
		var e_axis := _vec3_from(d.get("axis", [0, 0, 1]), Vector3(0, 0, 1)).normalized()
		var e_radius := float(d.get("hull_radius", 10.0))
		var e_mount: Vector3 = e_axis * e_radius \
			+ _vec3_from(d.get("mount_offset", [0, 0, 0]), Vector3.ZERO)
		var e_sector := StringName(str(d.get("sector", str(key))))
		_register_slot(StringName(str(key)), e_sector, e_mount,
			int(d.get("unlock_at_crisis", 99)))


## ⑧ 登记一个槽位定义（起始槽与扩展槽共用一条路径，避免两处各写一份推导）。
## mount 在**这里**算好存下，不在每次查询时重算：槽位是船上的物理事实，
## 位置不该随解锁状态变化；存下后 slot_mount() 对空槽也能返回正确位置
## （改装台聚焦空槽位时相机要靠它定位 —— 没有炮就没有 muzzle_pos 可问）。
func _register_slot(slot_id: StringName, sector: StringName, mount: Vector3, unlock_at: int) -> void:
	_slot_defs[slot_id] = {
		"mount": mount,
		"sector": sector,
		"unlock_at": unlock_at,
	}


## Variant → Vector3（逐项 float，踩坑：不能 float(数组)，须 float(a[0])）。
## 与 bridge_whitebox._vec3_from 同逻辑，各系统自持一份以免跨模块耦合。
func _vec3_from(v: Variant, fallback: Vector3) -> Vector3:
	if v is Array:
		var a := v as Array
		if a.size() >= 3:
			return Vector3(float(a[0]), float(a[1]), float(a[2]))
	if v is Vector3:
		return v as Vector3
	return fallback


## 单个炮塔 instantiate + configure + snap_to + 挂入 _turrets。
func _build_one_turret(turret_cfg: Dictionary) -> void:
	var t := Turret.new()
	t.name = "Turret_%s" % str(turret_cfg["id"])
	add_child(t)
	t.configure(turret_cfg)
	t.snap_to()
	_turrets[StringName(turret_cfg["id"])] = t


## 每物理帧：推所有 turret + 推所有 projectile + 清理死弹。
func _physics_process(delta: float) -> void:
	advance_all(delta)


## 推进一帧（所有炮塔 + 所有子弹）。
## 抽成公开方法是为了**测试可手动推进**：等真实帧既慢又不确定
## （副炮 fire_interval=3s，等一轮要真等 3 秒），手动推 60 次即等价于 1 秒。
## 与 Enemy.advance / Projectile.advance 同一套约定。
func advance_all(delta: float) -> void:
	for id in _turrets:
		var t := _turrets[id] as Turret
		if t != null:
			t.advance(delta)
	# 子弹推进 + 清理：倒序遍历，避免 erase 后索引跳号。
	var n := _projectiles.size()
	for i in range(n - 1, -1, -1):
		var p := _projectiles[i] as Projectile
		if p == null or not p.advance(delta):
			_projectiles.remove_at(i)


## 接管入口（按 1-5 / 点 feed 都调这里）。
##   target_id = 炮塔 id：&"main" / &"port" / &"starboard" / &"dorsal" / &"ventral"
##   若 == &"" 则退接管回主控室。
##   若当前已在接管某门炮，再按同一 id = 退接管（toggle 行为）。
##   同时只支持 1 门 MANUAL（bible DEC-030）。
func takeover(target_id: StringName) -> void:
	if target_id == &"":
		_release()
		return
	# toggle
	if current_manual_id == target_id:
		_release()
		return
	# 若已在接管另一门，先释放再接管
	if current_manual_id != &"":
		_release()
	if not _turrets.has(target_id):
		if DEBUG_LOG:
			print("[turret] 接管 %s 失败：未注册（已注册 %s）" % [target_id, str(_turrets.keys())])
		return
	var t := _turrets[target_id] as Turret
	# ⑤ 死炮不可接管：接管一门被毁的炮会得到「按扳机毫无反应」的假故障。
	if t.destroyed:
		if DEBUG_LOG:
			print("[turret] 接管 %s 失败：已被毁" % target_id)
		return
	t.set_mode(Turret.Mode.MANUAL)
	current_manual_id = target_id
	EventBus.turret_takeover_started.emit(target_id)
	if DEBUG_LOG:
		print("[turret] 接管 -> %s（手动模式）" % target_id)


## ⑧ 接管某一**路 feed**（扇区）：在该路已装的炮位之间**循环切换**。
##
## **为什么是"按路循环"而不是"一键一门炮"**（李 2026-09-09 定的交互）：
##   每路可以装两门炮之后，8 个炮位若各占一个数字键，键位要从 5 个涨到 9 个，
##   而且「2-5 = 监控面板上 4 块屏」这个已有肌肉记忆会被打乱。
##   改成按路接管：首按进该路第一门，**再按同一个键切到该路下一门**，
##   **转完一圈则释放**（回主控室）。键位仍是 1-5，同路两门炮在"再按一次"里选 ——
##   比"先记住 8 个键再决定按哪个"省脑子，符合本作低 APM 的初衷。
##
## 只循环「已解锁 + 已装炮 + 未被毁」的槽位（见 slots_of_sector）：
## 空槽位与死炮不占循环位，否则会出现「按了键但相机没动」的假故障。
## ESC 随时可直接退出接管，不依赖转完一圈。
func takeover_sector(sector: StringName) -> void:
	var ids := slots_of_sector(sector)
	if ids.is_empty():
		if DEBUG_LOG:
			print("[turret] 接管 %s 路失败：该路无可用炮塔" % sector)
		return
	if current_manual_id == &"":
		takeover(ids[0])
		return
	var i := ids.find(current_manual_id)
	if i < 0:
		takeover(ids[0])        # 当前接管的不在这一路 → 切过来，从第一门开始
		return
	if i + 1 < ids.size():
		takeover(ids[i + 1])    # 同路下一门
		return
	_release()                  # 转完一圈 → 回主控室


## 释放当前接管：回主控室 + 目标 turret 切回 AUTO。
func _release() -> void:
	if current_manual_id == &"":
		return
	if _turrets.has(current_manual_id):
		var t := _turrets[current_manual_id] as Turret
		t.set_mode(Turret.Mode.AUTO)
	var prev := current_manual_id
	current_manual_id = &""
	EventBus.turret_takeover_ended.emit(prev)
	if DEBUG_LOG:
		print("[turret] 释放接管 <- %s（回主控室）" % prev)


## BATTLE 进入 / 退出时调。开战 = 新一波开始 → 先回满耐久，再启用自动开火。
##
## **回满放在这里**（而不是调用方）是为了让「每波回满」这条 bible 规则只有一处实现：
## 正式流程（bridge_whitebox 监听 game_state_changed）与测试场景手动开战
## 都走本函数，不会出现「测试里没回满、正式里回满」的不一致。
## GameStateManager 不直接调本函数；由 bridge_whitebox.gd 监听 game_state_changed 后转调。
func set_battle_active(active: bool) -> void:
	if active:
		restore_all()
		# ⑨a 开战 = 新一波开始 → 清空上一波战损。
		# **清空挂在开战而不是「危机清空」上**：一清空就再也读不到，而整条 REFIT 链
		# （维修站 → 维修师 → 改装台）都要读它。下一个「肯定不再需要上一波数据」
		# 的时机，就是下一波开战前。跟「开战回满耐久」挨在一起，心智上也说得通。
		if _damage_log != null:
			_damage_log.reset()
	for id in _turrets:
		var t := _turrets[id] as Turret
		if t != null:
			t.set_auto_enabled(active)
	if DEBUG_LOG:
		print("[turret] 战斗状态: %s（auto_enabled=%s）" % [
			"BATTLE" if active else "REFIT", str(active)])


## ⑦ 换装：把 target_id 这门的**数值 + 外观**整体换成 variant_id 那一型。
##
## **空槽位也能调**（⑧ 扩展槽位解锁时是空的）：此时没有旧炮可退场，
## 直接走"新炮弹出"一支。这让「解锁槽位 → 给它装第一门炮」和
## 「把旧炮换成新型号」共用同一个入口，调用方不用关心槽位是不是空的。
##
## **为什么是销毁重建而不是就地改数值**：
##   Turret 的 hp_max / 视觉 Mesh 都在 configure + snap_to 里一次性建好，
##   就地改要重新实现一遍赋值 + 重建 Mesh，等于把 configure 抄一遍 —— 两份必然走偏。
##   重建让「换装」和「开局建炮」走完全同一条代码路径（_build_one_turret 的同款写法），
##   不会出现「开局装的炮和换上去的炮行为不一致」。
##
## 换装后一律回 AUTO：接管状态下换炮会留下"手动模式 + 空 current_manual_id"的烂摊子，
## 而改装发生在 REFIT（本来就在 AUTO），这条只影响测试里手动调 swap 的情况。
##
## 返回 false = 没换成（主炮 / 型号不存在 / 型号未解锁 / 槽位未解锁）。调用方据此给反馈。
func swap_turret(target_id: StringName, variant_id: StringName) -> bool:
	if target_id == MAIN_ID:
		if DEBUG_LOG:
			print("[turret] 换装 %s 失败：主炮固定不可换（DEC-030）" % target_id)
		return false
	var vd: Variant = _variants.get(variant_id, null)
	if not (vd is Dictionary):
		if DEBUG_LOG:
			print("[turret] 换装 %s 失败：型号 %s 不存在" % [target_id, variant_id])
		return false
	# ⑧ 未解锁不许装。**判在本层而不是 UI 层**：UI 可能漏判（键盘直调 / 测试探针 /
	# 将来任何新入口），而"能不能装"是规则，规则只该有一处实现。
	if not is_variant_unlocked(variant_id):
		if DEBUG_LOG:
			print("[turret] 换装 %s 失败：型号 %s 未解锁（需撑过 %d 次危机）" % [
				target_id, variant_id, variant_unlock_at(variant_id)])
		return false
	if not is_slot_unlocked(target_id):
		if DEBUG_LOG:
			print("[turret] 换装 %s 失败：槽位未解锁或不存在（需撑过 %d 次危机）" % [
				target_id, slot_unlock_at(target_id)])
		return false

	var old := _turrets.get(target_id, null) as Turret
	if old == null:
		return _install_fresh(target_id, variant_id)

	var sector := old.sector
	var mount := old.muzzle_pos
	var was_active := old.is_auto_enabled()

	# 正在接管它 → 先释放。否则 current_manual_id 会指向马上要被删掉的节点，
	# 下一次 _release() 时 get_turret 返回 null，静默吞掉退出接管的流程。
	if current_manual_id == target_id:
		_release()

	_turrets.erase(target_id)
	# 改名再 queue_free：Godot 里同名兄弟节点会被自动改名，add_child 新炮时
	# 若旧节点还没真正释放，会出现 "Turret_port" 与 "Turret_port_2" 并存的短暂状态。
	old.name = "Retired_%s" % str(target_id)
	_play_retire_fx(old)
	old.queue_free()

	var t := _spawn_turret(target_id, sector, mount, variant_id)
	if t == null:
		return false
	t.set_auto_enabled(was_active)
	_play_install_fx(t)

	EventBus.turret_equipped.emit(variant_id, -1)
	if DEBUG_LOG:
		print("[turret] 换装 %s → %s（hp=%.0f dmg=%.0f/%.1fs 射程=%.0f）" % [
			str(target_id), str(variant_id), t.hp, t.projectile_damage,
			t.auto_fire_interval, t.fire_range])
	return true


## ⑧ 往**空槽位**装第一门炮（没有旧炮可退场，只有"新炮弹出"一支）。
func _install_fresh(slot_id: StringName, variant_id: StringName) -> bool:
	var sector := slot_sector(slot_id)
	if sector == &"":
		push_warning("[turret] 空槽位 %s 没有 sector 定义，装不了" % str(slot_id))
		return false
	var t := _spawn_turret(slot_id, sector, slot_mount(slot_id), variant_id)
	if t == null:
		return false
	# 空槽装炮**不碰 auto_enabled**：改装发生在 REFIT，本来就是关的，
	# 等开战时 set_battle_active(true) 统一打开。这里主动开会让炮在过场里就开始打。
	_play_install_fx(t)
	EventBus.turret_equipped.emit(variant_id, -1)
	if DEBUG_LOG:
		print("[turret] 空槽位 %s 装上 %s（hp=%.0f dmg=%.0f/%.1fs）" % [
			str(slot_id), str(variant_id), t.hp, t.projectile_damage,
			t.auto_fire_interval])
	return true


## 按某型号配置在指定槽位建一门炮 —— **换装重建与空槽安装共用这一条路径**。
## 共用是刻意的：两处各写一份必然走偏，走偏的表现是「换上去的炮和空槽装的炮
## 行为不一致」这种极难查的幽灵 bug。
## （开局建炮另走 _build_one_turret，用的是 sub_gun_template —— 数值与 flak 一致，
##  那份 _doc 里写明了两者必须同步改。)
func _spawn_turret(turret_id: StringName, sector: StringName, mount: Vector3,
		variant_id: StringName) -> Turret:
	var cfg: Dictionary = (_variants[variant_id] as Dictionary).duplicate()
	cfg["id"] = turret_id
	cfg["sector"] = sector
	cfg["mount"] = [mount.x, mount.y, mount.z]
	var t := Turret.new()
	t.name = "Turret_%s" % str(turret_id)
	add_child(t)
	t.configure(cfg)
	t.snap_to()
	_turrets[turret_id] = t
	_equipped[turret_id] = variant_id
	return t


## ⑦ 旧炮退场特效：整体缩小到 0 + 一圈冲击环扩散淡出。
## 用 Tween 驱动 Mesh 而非 GPUParticles：白盒阶段够用，且**headless 下零风险**
## （粒子在 dummy 渲染驱动里会打一堆无害但吓人的 ERROR，见记忆 godot_pitfalls #12）。
func _play_retire_fx(t: Turret) -> void:
	_play_shock_ring(t.global_position, Color(0.9, 0.45, 0.25))
	var tw := t.create_tween()
	tw.tween_property(t, "scale", Vector3(0.01, 0.01, 0.01), SWAP_RETIRE_SEC)\
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)


## ⑦ 新炮登场特效：从 0 弹出（带一点点过冲）+ 一圈冷色聚合环。
func _play_install_fx(t: Turret) -> void:
	_play_shock_ring(t.global_position, Color(0.35, 0.75, 1.0))
	t.scale = Vector3(0.01, 0.01, 0.01)
	var tw := t.create_tween()
	tw.tween_property(t, "scale", Vector3.ONE, SWAP_INSTALL_SEC)\
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## 冲击环：一个自发光球壳，0.55 秒内从 0.3 扩到 2.2 并淡出，然后自删。
## 挂在 _fx_root（TurretSystem 的常驻子节点）而不是 root / 炮塔：
##   - 挂旧炮塔 → 特效随 queue_free 一起消失
##   - 挂 root   → root 正在 setup 子节点时 add_child 直接失败（ERROR）
## _fx_root 为空（_ready 未跑完）时**静默跳过特效**而不是报错：特效是锦上添花，
## 为了它把换装主流程搞挂不值得。
func _play_shock_ring(pos: Vector3, col: Color) -> void:
	if _fx_root == null:
		return
	var mi := MeshInstance3D.new()
	mi.name = "SwapFX"
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	mi.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 2.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	_fx_root.add_child(mi)
	mi.global_position = pos   # 必须在 add_child 之后：global_position 需要在树里才准
	mi.scale = Vector3(0.3, 0.3, 0.3)
	var tw := mi.create_tween()
	tw.set_parallel(true)
	tw.tween_property(mi, "scale", Vector3(2.2, 2.2, 2.2), SWAP_RING_SEC)
	tw.tween_property(mat, "albedo_color", Color(col.r, col.g, col.b, 0.0), SWAP_RING_SEC)
	tw.chain().tween_callback(mi.queue_free)


## ⑤ 某门炮被毁后的聚合处理（订阅 EventBus.turret_destroyed）。
##   ① 玩家正接管它 → 强制释放（否则对着死炮按扳机毫无反馈）
##   ② 该扇区再无存活炮塔 → sector_breached（该面失守，P1 演出/压力可视化的挂钩点）
##   ③ 全局再无存活炮塔 → all_turrets_destroyed（DEC-037 本局失败，由流程层转 RESULT）
func _on_turret_destroyed(turret_id: StringName, sector: StringName) -> void:
	if current_manual_id == turret_id:
		_release()
	if not _sector_has_alive(sector):
		EventBus.sector_breached.emit(sector)
		if DEBUG_LOG:
			print("[turret] 扇区 %s 失守（该面已无存活炮塔）" % sector)
	if alive_count() == 0:
		if DEBUG_LOG:
			print("[turret] 全部炮塔被毁 → all_turrets_destroyed")
		EventBus.all_turrets_destroyed.emit()


## 该扇区是否还有存活炮塔（判定「面失守」）。
func _sector_has_alive(sector: StringName) -> bool:
	for id in _turrets:
		var t := _turrets[id] as Turret
		if t != null and t.sector == sector and t.is_alive():
			return true
	return false


## 接管入口辅助：把 EventBus.monitor_feed_clicked 转成 takeover。
## 由 bridge_whitebox.gd 在 _ready 里 connect：signal → takeover_by_feed。
##
## 4 路 feed 各对应一门副炮，且**炮塔 id == 扇区名**（见 _load_and_build_turrets ②），
## 所以这里直接把 sector 当 id 用。fore 没有副炮（主炮固定正面，DEC-030），
## 所以 fore 的点击落到主炮接管。
func takeover_by_feed(sector: StringName) -> void:
	if sector == &"fore":
		takeover(&"main")
		return
	# ⑧ 按路接管：**同一路可能有两门炮**，交给 takeover_sector 在该路内循环。
	# 这里不再自己判断有没有炮 —— 「该路有哪些能接管的炮位」是 TurretSystem 的知识，
	# 输入层不该替它做这个判断（否则解锁第二炮位后还要回来改这里）。
	takeover_sector(sector)


# ── ⑧ 解锁（DEC-033 无货币 · DEC-042 节奏）────────────────────────────

## 撑过一次危机 → 进度 +1 → 重算解锁集合。
## wave_index 用不上但参数得接：信号带几个参数就得接几个，少了 connect 会失败。
func _on_crisis_cleared(_wave_index: int) -> void:
	_cleared += 1
	_sync_unlocks(_cleared, false)


## 按当前危机数重算「已解锁」集合。
##   silent = true：只填集合，不 emit、不记 fresh（_ready 里的开局初始化用）。
##
## **全量重算而不是增量追加**：门槛是数据（JSON 的 unlock_at_crisis），
## 全量重算保证「改了 JSON 数值 → 行为立刻跟着变」，而且天然幂等 ——
## 增量追加漏一次就永久错位，全量重算漏了下次也会补上。
func _sync_unlocks(cleared: int, silent: bool) -> void:
	for key in _variants:
		if str(key).begins_with("_"):
			continue
		var vid := StringName(str(key))
		if _unlocked_variants.has(vid):
			continue
		var vd: Variant = _variants[key]
		if not (vd is Dictionary):
			continue
		if int((vd as Dictionary).get("unlock_at_crisis", 0)) > cleared:
			continue
		_unlocked_variants.append(vid)
		if silent:
			continue
		_fresh_unlocks.append({"kind": &"variant", "id": vid})
		EventBus.turret_type_unlocked.emit(vid)
		if DEBUG_LOG:
			print("[turret] 解锁新型号 %s（撑过 %d 次危机）" % [str(vid), cleared])

	var before := _unlocked_slots.size()
	for key in _slot_defs:
		var sid := StringName(str(key))
		if _unlocked_slots.has(sid):
			continue
		var sd: Variant = _slot_defs[key]
		if not (sd is Dictionary):
			continue
		if int((sd as Dictionary).get("unlock_at", 0)) > cleared:
			continue
		_unlocked_slots.append(sid)
		if silent:
			continue
		_fresh_unlocks.append({"kind": &"slot", "id": sid})
		if DEBUG_LOG:
			print("[turret] 解锁新槽位 %s（撑过 %d 次危机）" % [str(sid), cleared])
	# 槽位数**变化后广播一次**而不是每解锁一个广播一次：
	# 订阅方（HUD）只关心"现在有几个槽位"，逐个广播等于逼它自己再数一遍。
	if not silent and _unlocked_slots.size() != before:
		EventBus.slot_count_changed.emit(_unlocked_slots.size())


## ── JSON 读取工具（同 bridge_whitebox.gd _load_json_dict）────────────────
func _load_json_dict(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("[turret] 找不到 %s" % path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return {}
	return parsed as Dictionary
