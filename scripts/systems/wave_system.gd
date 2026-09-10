extends Node
class_name WaveSystem

## 波次调度与难度曲线（BACKLOG P0 项「波次调度与难度曲线（无时间限制）」）。
##
## **职责边界**（MODULES.md §一：本系统只管「一波打什么、打完没」）：
##   ① 危机计数 —— `wave_index`（1 起）/ `crisis_cleared`（撑过的危机数，RESULT 显示它）
##   ② 按 `data/waves.json` 算本波组成（总数 + bomber 配比）
##   ③ BATTLE 进入时**整波一次生成**（用户 9/8 拍板「一次全出」，见 waves.json 的 _doc_not_here）
##   ④ 清空判定 → emit `crisis_cleared` → 请求 GameStateManager 回 REFIT
## **本系统不管**：
##   · 敌人怎么飞 / 扇区归属 / 攻击炮塔 —— EnemySystem + Enemy
##   · 炮塔耐久与失败判定 —— TurretSystem，全毁走 bridge_whitebox 的 all_turrets_destroyed
##   · 波次预览 UI（下波类型预告）—— BACKLOG P2，本轮不做
##
## **为什么「清空」只数自己生成的敌人**：主场景还有 E/R 调试键手动 spawn
## （见 bridge_whitebox.gd），那些是调试用的。若改用 `EnemySystem.enemy_count()`
## 判定，按几下 E 就会让本波永远清不空、卡死在 BATTLE。所以这里自存一份
## `_wave_enemies`，**调试生成的敌人不参与波次推进**。
##
## 数值全部来自 `data/waves.json`，本文件不 hardcode 任何数值（只写 JSON 缺项兜底）。

const DATA_PATH := "res://data/waves.json"

## 找 EnemySystem 用的 group 名。系统节点之间**不硬编码节点路径** ——
## 同 `projectile.gd` / `turret.gd` 当年从 "Bridge/EnemySystem" 改 group 的修法，
## 这样测试场景换节点结构也不会坏。
const ENEMY_SYSTEM_GROUP := &"enemy_system"

# 【日志纪律 2026-09-05 · 用户要求】新写的模块打开打印，验完改 false，
# 免得刷屏盖住下一个模块的日志。本模块只在**波次状态变化**时打（开始 / 清空 /
# 中止），不每帧打。
const DEBUG_LOG := false

var _cfg: Dictionary = {}
var _enemy_system: EnemySystem

# ── 数值（来自 waves.json） ────────────────
var _base_count := 4.0
var _count_growth := 1.0
var _max_count := 20.0
var _hp_scale := 0.0
var _bomber_start := 4.0
var _bomber_ratio_base := 0.15
var _bomber_ratio_growth := 0.08
var _bomber_ratio_max := 0.6

## 当前波次编号（1 起）。0 = 本局还没开打。
var wave_index := 0
## 已撑过的危机数（= 已清空的波数）。RESULT 界面要显示的成绩就是它。
var crisis_cleared := 0

var _active := false
## 本波生成的敌人（**只含本系统 spawn 的**，E/R 调试生成的不进这里）。
var _wave_enemies: Array[Enemy] = []
## 本波敌人总数（生成时记下，HUD 显示「剩余 / 总数」用）。
var _wave_total := 0


func _ready() -> void:
	_load_config()
	_enemy_system = get_tree().get_first_node_in_group(ENEMY_SYSTEM_GROUP) as EnemySystem
	if _enemy_system == null:
		push_warning("[wave] 找不到 group=%s 的 EnemySystem，波次无法生成敌人" % ENEMY_SYSTEM_GROUP)
	EventBus.game_state_changed.connect(_on_game_state_changed)


func _physics_process(_delta: float) -> void:
	if _active:
		_check_clear()


# ── 对外读数（HUD / 测试用） ─────────────────

## 本波还剩几只活的。
func remaining() -> int:
	var n := 0
	for e in _wave_enemies:
		if is_instance_valid(e) and not e.is_dead():
			n += 1
	return n


## 本波敌人总数（生成时确定，不随死亡变化）。
func total() -> int:
	return _wave_total


## 按波次编号算组成。**纯函数**，测试场景直接调它断言难度曲线，不用真生成敌人。
## 返回 `{"interceptor": n, "bomber": m, "total": t}`。
func compose(idx: int) -> Dictionary:
	var total_n := int(minf(_base_count + float(idx - 1) * _count_growth, _max_count))
	total_n = maxi(total_n, 1)   # 兜底：配置写 0 或负数时至少出 1 只，否则开局即清空
	var bomber_n := 0
	if float(idx) >= _bomber_start:
		var steps := float(idx) - _bomber_start
		var ratio := minf(_bomber_ratio_base + steps * _bomber_ratio_growth, _bomber_ratio_max)
		bomber_n = int(roundf(float(total_n) * ratio))
		bomber_n = clampi(bomber_n, 0, total_n)
	return {
		"interceptor": total_n - bomber_n,
		"bomber": bomber_n,
		"total": total_n,
	}


# ── 内部 ────────────────────────────────────

## 监听状态机：BATTLE → 开波；离开 BATTLE（收战 / 失败）→ 中止并清场。
func _on_game_state_changed(new_state: StringName) -> void:
	if new_state == &"BATTLE":
		_start_wave()
	else:
		_abort_wave(new_state)


## 开一波：算组成 → 整波一次生成 → emit wave_started。
func _start_wave() -> void:
	if _enemy_system == null:
		push_warning("[wave] 无法开波：EnemySystem 不可用（波次不会推进）")
		return
	wave_index += 1
	_wave_enemies.clear()
	var c := compose(wave_index)
	_wave_total = int(c["total"])
	# hp 缩放：waves.json 的 hp_scale_per_crisis（当前 0 = 不放大）。
	# 难度优先靠「数量 + 配比」调，这个旋钮留到实测自动火力过剩时再开。
	var scale := 1.0 + _hp_scale * float(wave_index - 1)
	for _i in int(c["interceptor"]):
		_spawn_tracked(&"interceptor", scale)
	for _i in int(c["bomber"]):
		_spawn_tracked(&"bomber", scale)
	_active = true
	if DEBUG_LOG:
		print("[wave] 第 %d 危机开始：拦截机 %d + 轰炸机 %d = %d 只（hp×%.2f）" % [
			wave_index, int(c["interceptor"]), int(c["bomber"]), _wave_total, scale])
	EventBus.wave_started.emit(wave_index)


## 生成一个敌人并**登记进本波名单**（E/R 调试键不走这里，见类注释）。
func _spawn_tracked(type_id: StringName, hp_scale: float) -> void:
	var e := _enemy_system.spawn_one(type_id)
	if e == null:
		return
	# 难度缩放在 Enemy 内部**同步改 hp 与 hp_max**（⑪ ⑤ 血条依赖后者）。
	# 直接写 `e.hp *= hp_scale` 会让血条比例算成 > 1 —— 不变量收进实体自己身上。
	e.scale_hp(hp_scale)
	_wave_enemies.append(e)


## 每帧查一次本波是否已清空。
## 用 `is_dead()` 而不是等 queue_free —— 敌人 hp<=0 当帧 is_dead() 就为真，
## 但真正 queue_free 在下一帧（Enemy 内部用 call_deferred，见 enemy.gd），
## 等节点消失会晚一帧且要处理 is_instance_valid；直接判死更准也更快。
func _check_clear() -> void:
	if remaining() > 0:
		return
	_clear_wave()


## 本波清空 → 危机数 +1 → 广播 → 回 REFIT（bible 01 状态图：本波敌人清空 → REFIT）。
func _clear_wave() -> void:
	_active = false
	crisis_cleared += 1
	_wave_enemies.clear()
	if DEBUG_LOG:
		print("[wave] 第 %d 危机清空 → REFIT（已撑过 %d 危机）" % [wave_index, crisis_cleared])
	EventBus.crisis_cleared.emit(wave_index)
	GameStateManager.change_state(GameStateManager.State.REFIT)


## 离开 BATTLE：中止本波并**清掉残留敌人**。
##
## 为什么要清场：玩家按 B 收战时敌人还在场上飞，不清就会① 下一波叠加，越堆越多；
## ② 更糟的是 TurretSystem.set_battle_active(true) 会**回满所有炮塔耐久** ——
## 残留敌人 + 反复按 B = 无限续命，⑤ 的失败条件直接失效。
##
## RESULT 进入时额外重置波次编号：bible 01「失败 → 退回装配重打同一艘船」，
## 再来一次从第 1 危机重新数（解锁进度保留 —— 那是 ⑧ 自动解锁的事，本轮不做）。
func _abort_wave(new_state: StringName) -> void:
	if not _active and _wave_enemies.is_empty():
		return
	var left := remaining()
	for e in _wave_enemies:
		if is_instance_valid(e):
			e.queue_free()
	_wave_enemies.clear()
	_active = false
	if DEBUG_LOG:
		print("[wave] 离开 BATTLE → %s，清掉残留 %d 只" % [new_state, left])
	if new_state == &"RESULT":
		wave_index = 0
		_wave_total = 0


func _load_config() -> void:
	_cfg = _load_json_section(DATA_PATH, "wave")
	_base_count = _num("base_count", 4.0)
	_count_growth = _num("count_growth", 1.0)
	_max_count = _num("max_count", 20.0)
	_hp_scale = _num("hp_scale_per_crisis", 0.0)
	_bomber_start = _num("bomber_start_crisis", 4.0)
	_bomber_ratio_base = _num("bomber_ratio_base", 0.15)
	_bomber_ratio_growth = _num("bomber_ratio_growth", 0.08)
	_bomber_ratio_max = _num("bomber_ratio_max", 0.6)


## 读 json 的指定段。文件缺失 / 解析失败 → 空字典，所有取值走兜底值
## （与 EnemySystem 同一套，保持一致便于对照）。
func _load_json_section(path: String, section: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("找不到 %s，波次配置回退默认值" % path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("无法打开 %s，波次配置回退默认值" % path)
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		push_warning("%s 解析失败，波次配置回退默认值" % path)
		return {}
	var root := parsed as Dictionary
	if not root.has(section) or not (root[section] is Dictionary):
		push_warning("%s 里没有 %s 段，波次配置回退默认值" % [path, section])
		return {}
	return root[section] as Dictionary


func _num(key: String, fallback: float) -> float:
	if not _cfg.has(key):
		return fallback
	return float(_cfg[key])
