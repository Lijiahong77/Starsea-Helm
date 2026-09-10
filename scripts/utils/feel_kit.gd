class_name FeelKit
extends RefCounted

## ⑪ Game Feel 参数的**只读访问器**（2026-09-10）
##
## 单一真源 = `data/presentation.json` 的 `feel` 段。本类只做「读 + 解析 + 兜底」，
## 不含任何玩法逻辑，也不存任何数值 —— 数值永远在 JSON 里（知识库铁律：不给终值）。
##
## **为什么需要它**：手感参数有三个消费者，分散在三层 ——
##   · `GameFeel`（相机反馈：震屏 / 推镜）—— 系统层
##   · `Enemy.take_damage` / `Turret.take_damage`（命中闪白）—— 实体层
## 实体层不该为了两个颜色常量去读整个 presentation.json（那是呈现层的文件），
## 也不该各自 hardcode 一份（就是「同一份数据存两处」，改一处漏一处）。
## 静态访问器让三边读同一份值，且不引入新的 autoload（autoload 顺序是项目已知的坑，
## 见 godot_pitfalls.md #13 —— 少一个就少一个坑）。
##
## **缓存语义**：首次访问解析一次并常驻（静态变量，进程级）。
## 运行期改 JSON 不会自动生效 —— 需要时显式 `FeelKit.reload()`（调试用）。

const DATA_PATH := "res://data/presentation.json"

## 代码兜底值。**只在 JSON 缺失 / 损坏时使用**，正常路径一律以 JSON 为准。
## 与 presentation.json 的 feel 段保持同值（改数值请改 JSON，不要改这里）。
const FALLBACK := {
	"master_scale": 1.0,
	"shake_time": 0.22,
	"shake_max_offset": 0.05,
	"shake_freq": 14.0,
	"zoom_in_time": 0.05,
	"zoom_out_time": 0.18,
	"flash_time": 0.08,
	"flash_color": [2.4, 2.0, 1.8],
	"events": {},
}

## 缺键告警只打一次（同一个键刷屏没有信息量）。
static var _warned: Dictionary = {}
static var _cfg: Dictionary = {}


## 当前生效的 feel 配置（首次调用时懒加载）。
static func cfg() -> Dictionary:
	if _cfg.is_empty():
		_cfg = _load()
	return _cfg


## 丢弃缓存重新读盘。调试用（改 JSON 后不想重启工程时）。
static func reload() -> void:
	_cfg = _load()
	_warned.clear()


## 全局强度总闸。0 = 全部反馈静默。
static func master() -> float:
	return float(cfg().get("master_scale", 1.0))


static func shake_time() -> float:
	return float(cfg().get("shake_time", 0.22))


static func shake_max() -> float:
	return float(cfg().get("shake_max_offset", 0.05))


static func shake_freq() -> float:
	return float(cfg().get("shake_freq", 14.0))


static func zoom_in() -> float:
	return float(cfg().get("zoom_in_time", 0.05))


static func zoom_out() -> float:
	return float(cfg().get("zoom_out_time", 0.18))


static func flash_time() -> float:
	return float(cfg().get("flash_time", 0.08))


## 闪白颜色。**允许分量 > 1**：StandardMaterial3D 的 albedo > 1 会一并抬高自发光，
## 在暗舱里才有"亮了一下"的观感（这是 enemy.gd 原有死亡闪红用的同一招）。
static func flash_color() -> Color:
	var c: Variant = cfg().get("flash_color", [2.4, 2.0, 1.8])
	if c is Array and (c as Array).size() >= 3:
		var a: Array = c as Array
		return Color(float(a[0]), float(a[1]), float(a[2]))
	return Color(2.4, 2.0, 1.8)


## 查某事件该给多强的反馈。
## 返回 `{ "shake": float, "zoom": float }`，缺项为 0，**已乘上 master_scale**。
##
## ⚠ 事件键写错是**静默失效**（返回 0 = 没反应，不报错）—— 所以这里主动 warn，
## 把静默失败变成嘈杂失败。⑩ 音频接线踩过一模一样的坑（memory/audio.md #7）。
static func feedback(event_key: String) -> Dictionary:
	var zero := {"shake": 0.0, "zoom": 0.0}
	var events: Variant = cfg().get("events", {})
	if not (events is Dictionary):
		_warn_once(event_key, "feel.events 不是字典，全部事件反馈静默")
		return zero
	var tbl: Dictionary = events as Dictionary
	if not tbl.has(event_key):
		_warn_once(event_key, "feel.events 缺少键 '%s'，该反馈静默（检查键名拼写）" % event_key)
		return zero
	var entry: Variant = tbl[event_key]
	if not (entry is Dictionary):
		_warn_once(event_key, "feel.events['%s'] 不是字典，该反馈静默" % event_key)
		return zero
	var e: Dictionary = entry as Dictionary
	var m := master()
	return {
		"shake": float(e.get("shake", 0.0)) * m,
		"zoom": float(e.get("zoom", 0.0)) * m,
	}


## 某事件是否存在（不告警的探测版）。给测试用：验接线表完整性时不希望刷警告。
static func has_event(event_key: String) -> bool:
	var events: Variant = cfg().get("events", {})
	return events is Dictionary and (events as Dictionary).has(event_key)


static func _warn_once(key: String, msg: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning("FeelKit: " + msg)


static func _load() -> Dictionary:
	var out: Dictionary = FALLBACK.duplicate(true)
	if not FileAccess.file_exists(DATA_PATH):
		push_warning("FeelKit: 找不到 %s，手感参数全部走代码兜底值" % DATA_PATH)
		return out
	var f := FileAccess.open(DATA_PATH, FileAccess.READ)
	if f == null:
		push_warning("FeelKit: 打不开 %s（err=%d），走兜底值" % [DATA_PATH, FileAccess.get_open_error()])
		return out
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if not (parsed is Dictionary):
		push_warning("FeelKit: %s 不是合法 JSON 对象，走兜底值" % DATA_PATH)
		return out
	var feel: Variant = (parsed as Dictionary).get("feel", null)
	if not (feel is Dictionary):
		push_warning("FeelKit: %s 缺少 feel 段，走兜底值" % DATA_PATH)
		return out
	# 逐键并入而非整体替换：新增旋钮时旧工程不会因为少一个键就全盘失效。
	for k in (feel as Dictionary).keys():
		if str(k).begins_with("_"):
			continue      # `_doc*` 是给人看的注释，不进运行时配置
		out[k] = (feel as Dictionary)[k]
	return out
