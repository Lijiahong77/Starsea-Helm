extends SceneTree

## 一次性几何探针：打印 BoxMesh / QuadMesh / PlaneMesh 的顶点 / UV / 法线，
## 按法线分组统计每个面的 UV 范围 —— 用来判定「显示屏」用的网格，
## 朝向玩家的那一面 UV 是否真的是 0..1 铺满（而不是只采样到图集的一角）。
##
## 用法（工程须已导入，即存在 .godot/ 目录）：
##   godot_console --headless --path <proj> --script res://scripts/tests/uv_probe.gd
##
## 实测结论（2026-09-02，本项目显示屏中心偏移问题的根因）：
##   BoxMesh(0.5,0.375,0.02)  正面(法线 +Z)  uv = (0,0)..(0.3333, 0.5)
##                            ← 3×2 图集，6 个面各占 1/3 宽 × 1/2 高
##   QuadMesh(0.5,0.375)      uv = (0,0)..(1,1)  ← 铺满，朝向/法线与 BoxMesh 正面一致
##   PlaneMesh(0.5,0.375)     uv = (0,0)..(1,1)，但在 XZ 平面、法线 +Y，需额外旋转 90°
##
## 要探测自己的网格：在 _initialize() 里加一行 _probe("标签", 你的 Mesh) 即可。

func _initialize() -> void:
	print("===== UV PROBE =====")
	_probe("BoxMesh(0.5,0.375,0.02)", _make_box())
	_probe("QuadMesh(0.5,0.375)", _make_quad())
	_probe("PlaneMesh(0.5,0.375)", _make_plane())
	print("===== END =====")
	quit()


func _make_box() -> Mesh:
	var m := BoxMesh.new()
	m.size = Vector3(0.5, 0.375, 0.02)
	return m


func _make_quad() -> Mesh:
	var m := QuadMesh.new()
	m.size = Vector2(0.5, 0.375)
	return m


func _make_plane() -> Mesh:
	var m := PlaneMesh.new()
	m.size = Vector2(0.5, 0.375)
	return m


func _probe(label: String, m: Mesh) -> void:
	print("\n---- %s ----" % label)
	print("surface count = %d" % m.get_surface_count())
	var arr := m.surface_get_arrays(0)
	var verts := arr[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var uvs := arr[Mesh.ARRAY_TEX_UV] as PackedVector2Array
	var norms := arr[Mesh.ARRAY_NORMAL] as PackedVector3Array
	var idx := arr[Mesh.ARRAY_INDEX] as PackedInt32Array
	print("verts=%d uvs=%d normals=%d indices=%d" % [verts.size(), uvs.size(), norms.size(), idx.size()])

	# 按法线分组，统计每个面的 UV 范围
	var faces := {}
	for i in norms.size():
		var key := _nk(norms[i])
		if not faces.has(key):
			faces[key] = {"uvmin": Vector2(INF, INF), "uvmax": Vector2(-INF, -INF), "count": 0,
					"pmin": Vector3(INF, INF, INF), "pmax": Vector3(-INF, -INF, -INF)}
		var f: Dictionary = faces[key]
		f["uvmin"] = (f["uvmin"] as Vector2).min(uvs[i])
		f["uvmax"] = (f["uvmax"] as Vector2).max(uvs[i])
		f["pmin"] = (f["pmin"] as Vector3).min(verts[i])
		f["pmax"] = (f["pmax"] as Vector3).max(verts[i])
		f["count"] = int(f["count"]) + 1

	for key in faces.keys():
		var f2: Dictionary = faces[key]
		print("  face n=%s  verts=%d" % [key, int(f2["count"])])
		print("        uv  range = %s .. %s" % [str(f2["uvmin"]), str(f2["uvmax"])])
		print("        pos range = %s .. %s" % [str(f2["pmin"]), str(f2["pmax"])])

	# 逐顶点明细（顶点数不多，直接全打）
	for i in verts.size():
		print("  v%d  pos=%s  uv=%s  n=%s" % [i, str(verts[i]), str(uvs[i]), _nk(norms[i])])


func _nk(v: Vector3) -> String:
	var r := Vector3(snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001))
	return "(%s,%s,%s)" % [str(r.x), str(r.y), str(r.z)]
