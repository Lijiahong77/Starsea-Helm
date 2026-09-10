extends SceneTree

## 一次性探针：算出 4 路 feed 相机的 Transform3D，打印成可直接粘回 .tscn 的格式。
##
## 目的：让编辑器里 FeedCam 的 Camera Preview == 运行时 _aim_feeds() 摆出来的位置。
## 注意这只影响**编辑器预览**：bridge_whitebox.gd 在 _ready() 里会重新写一遍
## cam.position / look_at，所以在编辑器里拖动 FeedCam 运行时是无效的。
##
## 用法（工程须已导入，即存在 .godot/ 目录）：
##   godot_console --headless --path <proj> --script res://scripts/tests/cam_probe.gd
##
## ✅ 本脚本**读的是 presentation.json**，与主场景同源 —— 改了 JSON 不用同步这里。
##   （旧版把坐标写死在脚本里，改完 JSON 就脱节，正是"两份真源"的典型坑。）
##   挂载优先级与主场景 _feed_cam_configs() 完全一致：
##     ① JSON 显式 "mount": [x,y,z]          —— 精确控制
##     ② 舰壁推导 axis × (ship 半宽 + hull_offset)  —— 默认
##     ③ 标记距离 × 0.75                     —— 船体尺寸缺失时的最后兜底
##
## 坑：节点不在树上时 Node3D.look_at() 会报 "Node not inside tree" 且**静默不生效**
##   （transform 保持单位矩阵，看上去"算出来了"其实是错的）→ 必须用
##   look_at_from_position()。本脚本的 Node3D 是 new 出来的，故走这条路径。

const DATA_PATH := "res://data/presentation.json"

# 内置方向表：只在 JSON 没有该项时才用（与主场景的 FEED_CAM_FALLBACK 一致）
const AXIS_FALLBACK := {
	"SVPort": Vector3(-1, 0, 0),
	"SVStarboard": Vector3(1, 0, 0),
	"SVDorsal": Vector3(0, 1, 0),
	"SVVentral": Vector3(0, -1, 0),
}
const STANDOFF_RATIO := 0.75

var _data: Dictionary = {}


func _initialize() -> void:
	_load_data()
	print("===== CAM PROBE（读 presentation.json）=====")
	var cams: Array = []
	if _data.has("monitor") and (_data["monitor"] is Dictionary):
		var m := _data["monitor"] as Dictionary
		if m.has("feed_cams") and (m["feed_cams"] is Array):
			cams = m["feed_cams"] as Array
	if cams.is_empty():
		push_warning("presentation.json 缺 monitor.feed_cams，改用内置方向表的 4 路")
		for k in AXIS_FALLBACK:
			cams.append({"feed": k})

	var dist: float = _num("monitor", "marker_distance", 60.0)
	for d in cams:
		if not (d is Dictionary):
			continue
		var item := d as Dictionary
		var feed_name: String = str(item.get("feed", "?"))
		var axis: Vector3 = _v3(item.get("axis", null), AXIS_FALLBACK.get(feed_name, Vector3(1, 0, 0)))
		if axis.length_squared() < 0.000001:
			axis = AXIS_FALLBACK.get(feed_name, Vector3(1, 0, 0))
		axis = axis.normalized()

		# 挂载点三级优先级（与主场景一致）
		var mount: Vector3 = _v3(item.get("mount", null), Vector3.ZERO)
		if mount.length_squared() < 0.000001:
			var hull_r: float = _hull_radius(axis)
			mount = axis * (hull_r if hull_r > 0.0 else dist * STANDOFF_RATIO)
		var up: Vector3 = _v3(item.get("up", null), Vector3(0, 1, 0))

		# 看向点 = 标记实际位置（距离不进旋转矩阵，只取方向，故用 marker_distance 即可）
		var target: Vector3 = axis * dist

		var n := Node3D.new()
		n.look_at_from_position(mount, target, up)
		var t := n.transform
		var b := t.basis
		print("%-12s 挂载=%s  看向=%s  up=%s" % [feed_name, str(mount), str(target), str(up)])
		print("  transform = Transform3D(%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)" % [
			_f(b.x.x), _f(b.y.x), _f(b.z.x),
			_f(b.x.y), _f(b.y.y), _f(b.z.y),
			_f(b.x.z), _f(b.y.z), _f(b.z.z),
			_f(t.origin.x), _f(t.origin.y), _f(t.origin.z)])
		print("  fwd(-Z)   = %s" % str(-b.z))
		n.free()
	print("===== END =====")
	quit()


## 沿 axis 的舰体外表面半径 + monitor.feed_cam_hull_offset（与主场景 _hull_radius 一致）
func _hull_radius(axis: Vector3) -> float:
	var half := 0.0
	if absf(axis.x) > 0.5:
		half = _num("ship", "width", 22.0) * 0.5
	elif absf(axis.y) > 0.5:
		half = _num("ship", "height", 16.0) * 0.5
	elif absf(axis.z) > 0.5:
		half = _num("ship", "length", 64.0) * 0.5
	if half <= 0.0:
		return 0.0
	return half + _num("monitor", "feed_cam_hull_offset", 0.5)


func _load_data() -> void:
	if not FileAccess.file_exists(DATA_PATH):
		push_warning("找不到 %s，全部回退默认值" % DATA_PATH)
		return
	var f := FileAccess.open(DATA_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		_data = parsed as Dictionary


func _num(section: String, key: String, fallback: float) -> float:
	if not _data.has(section) or not (_data[section] is Dictionary):
		return fallback
	var d := _data[section] as Dictionary
	if not d.has(key):
		return fallback
	return float(d[key])


func _v3(v: Variant, fallback: Vector3) -> Vector3:
	if v is Array:
		var a := v as Array
		if a.size() >= 3:
			return Vector3(float(a[0]), float(a[1]), float(a[2]))
	if v is Vector3:
		return v as Vector3
	return fallback


func _f(v: float) -> String:
	if is_zero_approx(v):
		return "0"
	return str(snappedf(v, 1e-7))
