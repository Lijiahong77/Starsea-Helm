class_name HealthKit
extends RefCounted

## ⑪ ⑤ 敌人血量反馈参数的**只读访问器**（2026-09-10）
##
## 单一真源 = `data/presentation.json` 的 `healthbar` 段。本类只做「读 + 解析 + 兜底」，
## 不含任何玩法逻辑，也不存任何数值 —— 数值永远在 JSON 里（宪法第 3 条：不给终值）。
##
## **为什么与 `FeelKit` 分成两个类而不是塞进同一个**：
##   · `feel` 段管「打上去的手感」（震屏 / 推镜 / 闪白）—— 消费者是 GameFeel + 实体
##   · `healthbar` 段管「血量信息怎么呈现」—— 消费者是目标血条 + 敌人本体染色
## 两类旋钮的消费者不同，混在一个段里会让「调手感」和「调 HUD」互相干扰。
## 结构照抄 FeelKit（同为静态访问器、同缓存语义、同"缺键告警只打一次"）。
##
## **缓存语义**：首次访问解析一次并常驻（静态变量，进程级）。
## 运行期改 JSON 不会自动生效 —— 需要时显式 `HealthKit.reload()`（调试用）。

const DATA_PATH := "res://data/presentation.json"

## 代码兜底值。**只在 JSON 缺失 / 损坏时使用**，正常路径一律以 JSON 为准。
## 与 presentation.json 的 healthbar 段保持同值（改数值请改 JSON，不要改这里）。
const FALLBACK := {
	"enabled": true,
	"enemy_tint": {
		"dim_color": [0.22, 0.09, 0.07],
		"curve": 1.0,
	},
	"target_bar": {
		"title": "当前目标",
		"offset_top": 84.0,
		"label_height": 22.0,
		"gap": 6.0,
		"width": 440.0,
		"height": 18.0,
		"bg_color": [0.02, 0.02, 0.03, 0.72],
		"fill_color": [0.86, 0.26, 0.20],
		"low_color": [0.98, 0.72, 0.16],
		"low_ratio": 0.3,
		"font_size": 14,
		"fade_time": 0.22,
	},
}

## 缺键告警只打一次（同一个键刷屏没有信息量）。
static var _warned: Dictionary = {}
static var _cfg: Dictionary = {}
## 是否真的从 JSON 读到了 healthbar 段（false = 走了代码兜底值）。
## **给测试 / 排障用**：光看"数值看起来对"分辨不出"读了文件"和"读了兜底值"——
## 两边的值本来就被设计成一致的。这个显式标志能把这件事断言出来。
static var _from_json := false


## 当前生效的 healthbar 配置（首次调用时懒加载）。
static func cfg() -> Dictionary:
	if _cfg.is_empty():
		_cfg = _load()
	return _cfg


## 配置是否来自 presentation.json（而不是代码兜底）。**访问 cfg() 之后再问才有意义。**
static func loaded_from_json() -> bool:
	if _cfg.is_empty():
		_cfg = _load()
	return _from_json


## 丢弃缓存重新读盘。调试用（改 JSON 后不想重启工程时）。
static func reload() -> void:
	_cfg = _load()
	_warned.clear()


## 总开关。false = 关掉整个 ⑤（既不变暗也不出血条），排查时用。
static func enabled() -> bool:
	return bool(cfg().get("enabled", true))


## 目标血条的全部旋钮（已并入兜底值，可直接 `get`）。
## ⚠ 返回的是缓存内层字典的**引用**，请只读，不要就地改。
static func bar() -> Dictionary:
	var v: Variant = cfg().get("target_bar", FALLBACK["target_bar"])
	if v is Dictionary:
		return v as Dictionary
	_warn_once("target_bar", "healthbar.target_bar 不是字典，血条走兜底值")
	return FALLBACK["target_bar"] as Dictionary


## C 层：按血量比例把「满血本色」插值到暗色。
## hp_ratio = 1 → 返回本色（满血不该变色）；hp_ratio = 0 → 返回 dim_color。
## `curve` 调「掉血时变暗的快慢」：1.0 线性；>1 = 前期不明显、后期陡降。
static func tint_color(base: Color, hp_ratio: float) -> Color:
	if not enabled():
		return base
	var t: Dictionary = cfg().get("enemy_tint", {}) as Dictionary
	var dim := parse_color(t.get("dim_color", [0.22, 0.09, 0.07]), Color(0.22, 0.09, 0.07))
	var curve := maxf(float(t.get("curve", 1.0)), 0.01)
	var k := pow(clampf(1.0 - hp_ratio, 0.0, 1.0), curve)
	return base.lerp(dim, k)


## JSON 里的颜色一律是 `[r,g,b]` 或 `[r,g,b,a]` 数组。非法 / 缺失 → fallback。
static func parse_color(v: Variant, fallback: Color) -> Color:
	if not (v is Array):
		return fallback
	var a: Array = v as Array
	if a.size() < 3:
		return fallback
	var col := Color(float(a[0]), float(a[1]), float(a[2]))
	if a.size() >= 4:
		col.a = float(a[3])
	return col


static func _warn_once(key: String, msg: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning("HealthKit: " + msg)


static func _load() -> Dictionary:
	var out: Dictionary = FALLBACK.duplicate(true)
	_from_json = false
	if not FileAccess.file_exists(DATA_PATH):
		push_warning("HealthKit: 找不到 %s，血量反馈参数全部走代码兜底值" % DATA_PATH)
		return out
	var f := FileAccess.open(DATA_PATH, FileAccess.READ)
	if f == null:
		push_warning("HealthKit: 打不开 %s（err=%d），走兜底值" % [DATA_PATH, FileAccess.get_open_error()])
		return out
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if not (parsed is Dictionary):
		push_warning("HealthKit: %s 不是合法 JSON 对象，走兜底值" % DATA_PATH)
		return out
	var hb: Variant = (parsed as Dictionary).get("healthbar", null)
	if not (hb is Dictionary):
		push_warning("HealthKit: %s 缺少 healthbar 段，走兜底值" % DATA_PATH)
		return out
	# 逐键并入（**含两层嵌套**：enemy_tint / target_bar 各自逐键并），
	# 新增旋钮时旧工程不会因为少一个键就全盘失效。
	for k in (hb as Dictionary).keys():
		if str(k).begins_with("_"):
			continue      # `_doc*` 是给人看的注释，不进运行时配置
		var v: Variant = (hb as Dictionary)[k]
		if v is Dictionary and out.get(k) is Dictionary:
			var dst: Dictionary = out[k]
			for kk in (v as Dictionary).keys():
				if str(kk).begins_with("_"):
					continue
				dst[kk] = (v as Dictionary)[kk]
		else:
			out[k] = v
	_from_json = true
	return out
