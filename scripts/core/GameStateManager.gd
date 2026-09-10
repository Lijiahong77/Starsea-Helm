extends Node
## GameStateManager —— 阶段状态机（架构地基，P0）
##
## 职责（MODULES.md §1 / 01_core_loop.md §状态机）：管理全局阶段
## `MENU / REFIT / BATTLE / RESULT`，是改装开关、波次切换、死亡结算的归口。
## 只做状态判定与广播，不承载任何战斗/改装逻辑（那些归各业务系统）。
##
## 状态图（01_core_loop.md）：
##   MENU ──开始航行──► REFIT ──玩家确认──► BATTLE
##                               ▲                │ 本波清空
##                               │                ▼
##                           RESULT ◄──全炮被毁── REFIT(自动满血重进)
##   REFIT ──再来一次(保留解锁)── (来自 RESULT)
##
## 命名用 StringName 常量（Godot 字符串优化 + 日志可读）。
## ⚠ 改状态集合 / 合法转移前先回填 01_core_loop.md §状态机，保持单一真源。

enum State {
	MENU,
	REFIT,
	BATTLE,
	RESULT,
}

## 合法转移表：key = 当前状态 → value = 允许跳到的目标状态集合。
## 对齐 01_core_loop.md 状态图；非法转移只告警不 crash（宽进，方便现阶段 debug/接入 UI）。
const ALLOWED_TRANSITIONS := {
	State.MENU: [State.REFIT],
	State.REFIT: [State.BATTLE, State.RESULT],
	State.BATTLE: [State.REFIT, State.RESULT],
	State.RESULT: [State.REFIT, State.MENU],
}

const _STATE_NAMES := {
	State.MENU: &"MENU",
	State.REFIT: &"REFIT",
	State.BATTLE: &"BATTLE",
	State.RESULT: &"RESULT",
}

## 当前状态。初始 REFIT：白盒主控室即局内起点，无独立 MENU/RESULT 界面。
## 用「任意键回到 REFIT」的空转状态替代原生 MENU 会让验证失真，
## 故首局直接落 REFIT，等 UI 接入后再由外部触发 MENU→REFIT。
var current_state: int = State.REFIT

# 【日志纪律 2026-09-05】白盒验收完后改 false；想看状态切换改 true。
const DEBUG_LOG := false

func _ready() -> void:
	# autoload 就绪后宣告初始状态，让业务系统 / UI 能据此做首帧初始化。
	EventBus.game_state_changed.emit(_state_name(current_state))

## 请求状态转移。合法 → 切状态 + 广播；非法 → 告警（不崩溃）。
func change_state(new_state: int) -> bool:
	if new_state == current_state:
		# 幂等：已在该状态不重复广播，静默返回 true。
		return true
	if not ALLOWED_TRANSITIONS.get(current_state, []).has(new_state):
		push_warning(
			"[GameState] 非法转移 %s → %s（忽略）。见 ALLOWED_TRANSITIONS。" %
			[_state_name(current_state), _state_name(new_state)]
		)
		return false
	var prev_name := _state_name(current_state)
	current_state = new_state
	var s_name := _state_name(new_state)
	if DEBUG_LOG:
		print("[GameState] 状态: %s → %s" % [prev_name, s_name])
	EventBus.game_state_changed.emit(s_name)
	return true

## 便捷判定（供业务系统读，不必手比枚举）。
func is_refit() -> bool: return current_state == State.REFIT
func is_battle() -> bool: return current_state == State.BATTLE
func is_result() -> bool: return current_state == State.RESULT

## 当前状态的**名字**（&"REFIT" / &"BATTLE" / ...）。
## 给 UI / 诊断读：外部不必碰 _STATE_NAMES，也不该自己去比枚举再翻译一遍
## （同一份映射存两处，改枚举时必漏一处）。
func state_name() -> StringName:
	return _state_name(current_state)

func _state_name(s: int) -> StringName:
	return _STATE_NAMES.get(s, &"UNKNOWN")
