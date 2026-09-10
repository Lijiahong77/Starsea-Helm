extends Control
# 独立 SubViewport 测试场景（技术验证，不并入主游戏）
# 目的：验证「主控室常驻 4 路副炮实时画面」是否可行 + 性能是否可控
# 运行方式：在 Godot 打开本场景，按「运行当前场景」(Play Scene / F6 或 Ctrl+F5)
#           —— 不要按 F5（F5 跑的是尚未搭建的主游戏场景）
# 看什么：2x2 四块带标签、带彩色边框的画面是否在转动；顶部 FPS 是否 ≥55
# 调参：下方 FEED_W / FEED_H 改渲染分辨率；若卡就调小。

const FEED_W := 320
const FEED_H := 180

# 每个扇区：名称 / 画面内背景色 / 外边框色 / 立方体色
const FEEDS := [
	{"name": "① PORT 左舷",   "bg": Color(0.04, 0.10, 0.22), "accent": Color(0.30, 0.70, 1.00), "cube": Color(0.20, 0.60, 1.00)},
	{"name": "② STBD 右舷",   "bg": Color(0.05, 0.18, 0.08), "accent": Color(0.40, 1.00, 0.50), "cube": Color(0.30, 1.00, 0.40)},
	{"name": "③ DORSAL 上",   "bg": Color(0.20, 0.10, 0.04), "accent": Color(1.00, 0.65, 0.25), "cube": Color(1.00, 0.60, 0.20)},
	{"name": "④ VENTRAL 下",  "bg": Color(0.16, 0.04, 0.16), "accent": Color(1.00, 0.35, 0.95), "cube": Color(1.00, 0.30, 0.90)},
]

var _fps_label: Label
var _spinning: Array[MeshInstance3D] = []

func _ready():
	_fps_label = Label.new()
	_fps_label.position = Vector2(16, 12)
	_fps_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.2))
	_fps_label.add_theme_font_size_override("font_size", 26)
	add_child(_fps_label)

	var W := get_viewport_rect().size.x
	var H := get_viewport_rect().size.y
	var margin := 48.0
	var gap := 36.0
	# 2×2 网格布局：窗口按行列均分，四周留 margin、中间留 gap
	var pw := (W - margin * 2 - gap) / 2.0
	var ph := (H - margin * 2 - gap) / 2.0

	for i in FEEDS.size():
		var info: Dictionary = FEEDS[i]
		var name: String = info["name"] as String
		var bg: Color = info["bg"] as Color
		var accent: Color = info["accent"] as Color
		var cube: Color = info["cube"] as Color

		var col := i % 2
		var row := int(i / 2)          # GDScript 4 的 / 是浮点除法，行号必须取整
		var px := margin + col * (pw + gap)
		var py := margin + row * (ph + gap)

		# 彩色边框（先加 = 画在底下，露出 4px 边，一眼区分四块）
		var frame := ColorRect.new()
		frame.color = accent
		frame.size = Vector2(pw + 8, ph + 8)
		frame.position = Vector2(px - 4, py - 4)
		add_child(frame)

		# 画面容器
		var svc := SubViewportContainer.new()
		svc.name = "Feed%d" % i
		svc.stretch = true
		svc.size = Vector2(pw, ph)
		svc.position = Vector2(px, py)
		add_child(svc)

		var vp := SubViewport.new()
		vp.name = "Viewport"
		vp.size = Vector2(FEED_W, FEED_H)
		# ⚠ 两处「与主场景相反」的写法，别照抄到主游戏：
		# ① 这里**刻意不共享 World3D** —— 本测试每路是独立小场景，只验证渲染开销；
		#    主场景必须 `vp.world_3d = get_viewport().world_3d`，否则 4 路拍到空世界
		#    （表现：屏幕全黑/被 emission 糊成白板，且相机"看着没动"）。
		# ② 这里不设 render_target_update_mode —— 由 SubViewportContainer 的可见性
		#    驱动更新（UPDATE_WHEN_VISIBLE），够用且更省；主场景的 SubViewport 不在
		#    容器里（贴到 3D 网格上），没有可见性概念，必须显式设为 UPDATE_ALWAYS。
		svc.add_child(vp)

		# Godot 4 没有 SubViewport.default_clear_color；用 WorldEnvironment 设背景色
		var env := WorldEnvironment.new()
		var env_res := Environment.new()
		env_res.background_mode = Environment.BG_COLOR
		env_res.background_color = bg
		env.environment = env_res
		vp.add_child(env)

		var light := DirectionalLight3D.new()
		light.rotation_degrees = Vector3(-50, 30, 0)
		vp.add_child(light)

		var cam := Camera3D.new()
		cam.position = Vector3(0, 0.8, 4.0)
		cam.look_at(Vector3.ZERO)
		vp.add_child(cam)

		var cube_mesh := MeshInstance3D.new()
		var mat := StandardMaterial3D.new()
		mat.albedo_color = cube
		mat.emission_enabled = true
		mat.emission = cube
		mat.emission_energy = 0.5
		cube_mesh.mesh = BoxMesh.new()
		cube_mesh.position = Vector3(0, 0, 0)
		vp.add_child(cube_mesh)
		_spinning.append(cube_mesh)

		# 2D 标签（覆盖在面板左上角，即使 3D 失败也能看清是哪块）
		var lab := Label.new()
		lab.text = name
		lab.position = Vector2(px + 12, py + 8)
		lab.add_theme_color_override("font_color", Color(1, 1, 1))
		lab.add_theme_font_size_override("font_size", 22)
		add_child(lab)

func _process(_delta):
	for c in _spinning:
		c.rotation.y += 1.6 * _delta
		c.rotation.x += 0.7 * _delta
	_fps_label.text = "FPS %d  |  共 %d 路 feed @ %dx%d（窗口 1920x1080）" % [
		Engine.get_frames_per_second(), FEEDS.size(), FEED_W, FEED_H]
