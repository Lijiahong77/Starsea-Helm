extends Node3D

## ============================================================
## 白盒主控室 —— 行为脚本
##
## 场景结构全部在 scenes/bridge/bridge_whitebox.tscn（可见可点选）：
##   舱室六面 / 舷窗框 / 控制台 / 监控面板 + 4 屏 / 4 路 SubViewport feed /
##   4 个舷外标记 / 玩家 / HUD / 灯光 / 环境。
## 本脚本只做「行为」：摆标记 → 把 feed 相机挂到舰壁并对焦 → 生成屏幕网格 →
##   运行时绑定 feed 纹理 + 应用材质旋钮 → 第一人称转头 → ESC → HUD 尺度自检 →
##   星空(装饰) → 出图诊断。
##
## 数值外置（铁律）：凡影响玩法/布局的数值一律在 data/presentation.json，
##   本文件只保留「结构映射」（哪路 feed 拍哪个扇区）与 JSON 缺项时的兜底值。
##   两处例外，均已在原地注明理由：
##     ① 星空（_build_starfield）——纯装饰，不参与玩法判定；
##     ② 诊断阈值（_diag_feeds / _content_centroid）——只影响日志，不影响玩法。
##
## ⚠ 初始化有顺序依赖，改 _ready() 之前先看那里的注释。
## ============================================================

const DATA_PATH := "res://data/presentation.json"
# 敌人参数的单一真源是 enemies.json（目录约定见 docs/MODULES.md §五）。
const ENEMY_DATA_PATH := "res://data/enemies.json"

# 数字键 → 接管目标。1 = 主炮（**唯一**的一门，直接接管）；
# 2-5 = 四路 feed 的**扇区**（左/右/上/下），顺序与 SCREEN_FEED 四块屏一致。
#
# ⚠ **2-5 的值是扇区不是炮塔 id**（⑧ 起）：每路可以装两门炮，按同键会
# 在该路的炮位之间**循环切换**（转完一圈释放回主控室，见 TurretSystem.takeover_sector）。
# 所以键位不会因为炮位数从 4 涨到 8 而膨胀到 9 个 ——
# 「2-5 = 监控面板上 4 块屏」这个肌肉记忆保持不变。
const TAKEOVER_KEYS := {
	KEY_1: &"main", KEY_2: &"port", KEY_3: &"starboard",
	KEY_4: &"dorsal", KEY_5: &"ventral",
}

# 屏幕(显示屏) Mesh → 对应 feed(SubViewport) 的节点路径映射。
#
# 【唯一真源 · feed 清单】本文件有 3 处需要「4 路 feed」：屏幕绑定(_bind_screens)、
# 共享 World3D、设置分辨率(_configure_feeds)。三者一律从这张表派生（见 _ready()），
# 不再各存一份常量 —— 之前 FEED_NODES 与这里重复，改一处漏一处会静默错位。
#
# 关键坑：在 .tscn 里用 ViewportTexture(viewport_path=...) 引用会在加载期
# 报 "Path to node is invalid" 且运行时粉黑/白板，故纹理完全不在 .tscn 里引用，
# 改由 _bind_screens() 在运行时用 SubViewport.get_texture() 绑定
# （这是 Godot 4 社区公认最稳的做法，绕开路径解析）。
# 另注：Godot 编辑器每次保存都可能把 ViewportTexture 写回 .tscn（本项目已复发 3 次），
# 所以运行时绑定不只是"更稳"，而是唯一可靠的防线 —— 磁盘上干净是靠不住的。
const SCREEN_FEED := [
	["MonitorPanel/ScreenPort", "Feeds/SVPort"],
	["MonitorPanel/ScreenStarboard", "Feeds/SVStarboard"],
	["MonitorPanel/ScreenDorsal", "Feeds/SVDorsal"],
	["MonitorPanel/ScreenVentral", "Feeds/SVVentral"],
]
# 各 feed 相机的「结构映射」：哪路 feed 拍哪个扇区的标记、朝哪个方向。
#
# 【唯一真源 · 标记清单】同时也是 4 个舷外标记的清单：_place_markers() 摆放、
# _process() 里旋转、_aim_feeds() 对焦，三处都从这张表取 marker 名。
#
# 坐标/距离一律不写在这里（铁律：数值外置），只有方向这类结构信息留在代码，
# 具体挂载点（mount / hull_offset）与 up 来自 data/presentation.json 的 monitor.feed_cams。
# 三级优先级见 _feed_cam_configs()，最坏情况下按「标记距离 × FEED_CAM_STANDOFF_RATIO」
# 推导，仍然不 hardcode 坐标。
const FEED_CAM_FALLBACK := [
	{"feed": "SVPort", "marker": "MarkerPort", "axis": Vector3(-1, 0, 0)},
	{"feed": "SVStarboard", "marker": "MarkerStarboard", "axis": Vector3(1, 0, 0)},
	{"feed": "SVDorsal", "marker": "MarkerDorsal", "axis": Vector3(0, 1, 0)},
	{"feed": "SVVentral", "marker": "MarkerVentral", "axis": Vector3(0, -1, 0)},
]
# 最后兜底：JSON 既没给 mount、船体尺寸也拿不到时，相机停在
# 「标记到船中心距离」的这个比例处。正常不会走到这里（见 _hull_radius）。
const FEED_CAM_STANDOFF_RATIO := 0.75

const STAR_SHADER := """
shader_type spatial;
render_mode unshaded, cull_front;
uniform float grid : hint_range(50.0, 900.0) = 420.0;
uniform float density : hint_range(0.5, 1.0) = 0.972;
uniform float radius : hint_range(0.01, 0.35) = 0.09;
uniform float brightness : hint_range(0.0, 4.0) = 1.7;
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}
void fragment() {
	vec2 uv = UV * grid;
	vec2 cell = floor(uv);
	float h = hash21(cell);
	float star = 0.0;
	if (h > density) {
		vec2 f = fract(uv) - 0.5;
		star = smoothstep(radius, 0.0, length(f));
		star *= (h - density) / max(1.0 - density, 0.001);
		star *= 0.35 + 0.65 * fract(h * 97.13);
	}
	ALBEDO = vec3(star * brightness);
}
"""

var _data: Dictionary = {}
var _player: Node3D
var _camera: Camera3D
var _hud: Label
var _feeds: Array[SubViewport] = []
var _markers: Array[Node3D] = []
# 敌人系统（③六扇区+敌人，挂在本场景 EnemySystem 节点）。现在**只服务 E/R 调试生成** ——
# 正式波次由 WaveSystem 驱动（它自己按 group 找 EnemySystem），因此这里拿引用只为了
# 手动 spawn 与可见性诊断（KEY_E / KEY_R / KEY_F）。
var _enemy_system: EnemySystem
# 炮塔系统（④炮塔开火 Round 1 + Round 2）。Round 1 只接主炮。
var _turret_system: TurretSystem
# 波次调度（⑨波次调度与难度曲线）。BATTLE 进入时整波生成、清空后转 REFIT。
# 本脚本只在 HUD 里读它的计数，不参与调度决策。
var _wave_system: WaveSystem
# ⑦ 维修站过场（改装阶段）。**本脚本只做两件事**：过场期间吞掉按键、镜头跟焦点炮位。
# 时序 / 台词 / 换装决策全在 RefitSequence 里 —— 这里越薄，过场就越不会和主循环打架。
var _refit_seq: RefitSequence
# ⑨b 陷落演出编排器（L1/L2 屏幕标记 + L3 终局镜头）。运行时 new 挂成子节点。
# 本脚本只做「L3 期间锁输入」+「HUD 读它状态」两件事，演出细节全在 CollapseSequence 里。
var _collapse: CollapseSequence
# ⑪ 相机手感编排器（震屏 / 推镜）。同样是运行时 new 挂成子节点。
# 分工见 game_feel.gd 头注释：它只写 Camera3D.position / fov，本脚本写 Player.position / rotation，
# 两边零重叠 —— 所以接管搬移与震屏可以同时存在，不需要互相避让。
var _game_feel: GameFeel
# 当前全局阶段名（&"REFIT" / &"BATTLE" / &"RESULT"）。镜像 GameStateManager，
# 只为 HUD 显示用 —— 状态转移本身仍由 GameStateManager 独占。
# 初值在 _ready 里从 GameStateManager.state_name() 读一次：autoload 的 _ready
# 早于主场景，初始那次 game_state_changed 广播**收不到**（那时还没 connect）。
var _state: StringName = &"REFIT"
# 手动接管时的预测点 marker（绿色十字 BoxMesh）。仅在 MANUAL + 找到目标时显示。
var _lead_marker: MeshInstance3D
const LEAD_MARK_SIZE := Vector3(0.4, 0.4, 0.4)

# ── 接管副炮时的主视角搬移（DEC-038）────────────────────
# 接管副炮 = 主视角切到该炮（舰体外表面，朝外看）；释放 = 搬回主控室。
# 为什么是**搬 Player** 而不是新建相机：本脚本的转头状态（_yaw/_pitch）就是为
# Player/Camera3D 写的，复用它能零改动复用鼠标瞄准；新建相机要同时改输入路由，
# 收益不抵复杂度。代价是 Player 会短暂离开主控室 —— 白盒阶段可接受，
# 若将来主控室加了「玩家碰撞/可走动」，这里要换成独立的 TakeoverRig 相机。
# 主控室视角（位置 + yaw/pitch）在此暂存，释放时原样还原，玩家不会「转了个身」。
var _bridge_pos := Vector3.ZERO
var _bridge_yaw := 0.0
var _bridge_pitch := 0.0
var _takeover_view := false

# ── 可见性判定的几何常量（**与 .tscn 同步**：改艏部窗洞尺寸时这里要一起改）──
const WIN_Z := 1.8        # 艏部墙所在平面
const WIN_X_HALF := 2.15  # 窗洞左右半宽 = WallFrontFillLeft/Right 的内边缘
const WIN_Y_MIN := 0.55   # 窗洞下沿 = WallFrontFillBelow 顶边
const WIN_Y_MAX := 2.85   # 窗洞上沿 = WallFrontFillAbove 底边
# 监控面板上边缘（含 16° 前倾）：中心(0, 0.9, 0.912) + 半高 0.45 × Y 轴(0, 0.9613, 0.2756)
const PANEL_TOP_Y := 1.3326
const PANEL_TOP_Z := 1.036
const PANEL_X_HALF := 0.575

var _yaw := PI            # 起始朝 +Z 舷窗（DEC-026：信息不对称物理保证）
						  #   注：Godot 相机默认朝 -Z，故 rotation.y=PI 才是朝向 +Z。
var _pitch := 0.0
# 以下 4 个初值只是「JSON 缺项时的兜底」，_ready() 里会立刻被 presentation.json 覆盖，
# 数值与 JSON 中的默认值保持一致（改数值请改 JSON，不要改这里）。
var _sens := 0.0022
var _pitch_limit := 80.0
var _feed_fps := 10.0
var _fps := 0
var _fps_frames := 0
var _fps_time := 0.0
var _diag_t := 0.0       # 诊断计时（feed 出图验证，启动后跑一次）
var _diag_done := false  # 诊断是否已执行
var _feed_cam_cache: Array = []   # feed 相机配置缓存（启动时解析一次，避免重复告警）
# ImageTexture 用于在 CPU 端读 SubViewport 内容再推到 GPU。
# 【关键坑 2026-09-03】Godot 4 用 sv.get_texture() 或 new ViewportTexture()+viewport_path
# 拿到的贴图，被 3D 网格材质采样时仍然返回白色 —— SubViewport 的渲染目标没绑到 ViewportTexture
# 上。原因不明（可能 Godot 4.7 行为变更或 ViewportTexture 只在编辑器里写才解析）。
# 唯一稳妥的路线：get_image() 走 CPU 读回，再 ImageTexture.update() 推到 GPU。
# 代价是每帧 N×W×H×4B 的回读带宽（4 路 320×240 @ 10fps ≈ 12MB/s，可接受）。
var _feed_textures: Array[ImageTexture] = []   # 与 _feeds 一一对应的 ImageTexture
var _feed_readback_acc := 0.0  # 上次回读距今的时间（用于节流到 feed_fps）

# 调试抓帧开关：true 时启动约 1 秒后，把「主窗口画面」和「4 路 feed 原始画面」
# 各存成 PNG 到 user://shots/，并在日志里打印路径。
# 用途：日志里的指标只能证明"采样到东西"，证明不了"人眼看到什么"。
# 排查"屏幕全黑 / 画面不对"时，直接开这个看 PNG —— 肉眼所见才是终审。
# Windows 下 user:// = %APPDATA%/Godot/app_userdata/<项目名>/
# 出包前请改回 false。
# 2026-09-05：监控子系统（4 路 feed 出图 / 材质 / 相机挂载）已验证通过，关掉不再刷屏。
# 需要复查画面时把它改回 true（同时会重新抓 5 张 PNG 到 user://shots/）。
const DEBUG_CAPTURE := false

# 【日志纪律 2026-09-05 · 用户要求】
#   已验证通过的模块 → 打印关掉，避免 Output 刷屏盖住新模块的日志；
#   新写的模块 → 打印打开，用来在 Output 里直接判断功能是否正常。
# 本脚本（白盒主控室）属**已验证模块**，故 DEBUG_LOG=false，所有常规 print 都走
# _log()；需要复查时改成 true 一次性全部恢复，不用逐行取消注释。
# 例外：KEY_E 生成敌人的调试打印是**新功能**，单独直接 print，不受本开关控制。
const DEBUG_LOG := false

## 受 DEBUG_LOG 控制的日志输出。用法同 print：_log("格式 %s", [参数])
func _log(fmt: String, args: Array = []) -> void:
	if DEBUG_LOG:
		if args.is_empty():
			print(fmt)
		else:
			print(fmt % args)


## 配置场景环境光（WorldEnvironment）。
##
## 坑：.tscn 里 env 的 ambient_light_source=1（DISABLED），意味着整个场景
## 不接受环境光填充 —— JSON 里的 render.ambient_color / ambient_energy
## 看起来存在，实际没生效，房间整体漆黑。
## 修法：运行时强制把 source 设为 COLOR(=2) 并应用 JSON 数值，让环境光
## 真正参与光照计算。这是双保险：.tscn 里 source 改回 DISABLED 也免疫。
##
## DirectionalLight3D（Sun）由 .tscn 直接光负责，不在这里动。
func _configure_environment() -> void:
	var we := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we == null:
		push_warning("WorldEnvironment 节点缺失，环境光配置跳过")
		return
	var env := we.environment
	if env == null:
		push_warning("WorldEnvironment.environment 为空")
		return
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	var col: Variant = _data.get("render", {}).get("ambient_color", [0.13, 0.15, 0.21]) if _data is Dictionary else null
	if col is Array and (col as Array).size() >= 3:
		env.ambient_light_color = _color_from(col, env.ambient_light_color)
	var energy: float = _num("render", "ambient_energy", 1.0)
	env.ambient_light_energy = energy
	_log("[env] ambient_light_source=COLOR color=%s energy=%.2f（强制覆盖 .tscn 的 DISABLED）", [
		str(env.ambient_light_color), energy])


func _ready() -> void:
	_load_data()
	_configure_environment()
	_state = GameStateManager.state_name()
	_sens = _num("input", "mouse_sensitivity", 0.0022)
	_pitch_limit = _num("camera", "pitch_limit", 80.0)
	_feed_fps = _num("monitor", "feed_fps", 10.0)

	_player = $Player
	_camera = $Player/Camera3D
	_hud = $HUD/Label
	_enemy_system = get_node_or_null("EnemySystem") as EnemySystem
	if _enemy_system == null:
		push_warning("EnemySystem 节点缺失，敌人调试生成（KEY_E）不可用")
	_wave_system = get_node_or_null("WaveSystem") as WaveSystem
	if _wave_system == null:
		push_warning("WaveSystem 节点缺失，波次调度不可用（进 BATTLE 不会有敌人）")
	else:
		# ⑨ 波次事件只用来刷 HUD（危机数 / 剩余敌人数）。**调度决策全在 WaveSystem**，
		# 本脚本不参与 —— 否则「谁决定回 REFIT」就会散在两个地方。
		EventBus.wave_started.connect(_on_wave_event)
		EventBus.crisis_cleared.connect(_on_wave_event)
	_refit_seq = get_node_or_null("RefitSequence") as RefitSequence
	if _refit_seq == null:
		push_warning("RefitSequence 节点缺失，维修站过场与改装不可用")
	else:
		# ⑦ 改装台选槽位时把镜头搬到那个炮位（玩家要看得见自己换的炮 + 换装特效）。
		EventBus.refit_focus_slot.connect(_on_refit_focus)
		# ⑦ 过场开始前先退接管：镜头要交给改装台调度，玩家手上还抓着一门炮会打架
		# （典型：危机清空时正在接管副炮 → 相机既被接管占着又被改装台搬）。
		EventBus.cutscene_started.connect(_on_cutscene_started)
	_turret_system = get_node_or_null("TurretSystem") as TurretSystem
	if _turret_system == null:
		push_warning("TurretSystem 节点缺失，主炮开火/接管不可用")
	else:
		# BATTLE 状态自动开火：监听状态机，按状态切换主炮 auto_enabled
		EventBus.game_state_changed.connect(_on_game_state_changed)
		# ⑤ 全部炮塔被毁 = 本局失败（DEC-037），由流程层转 RESULT
		EventBus.all_turrets_destroyed.connect(_on_all_turrets_destroyed)
		# 接管入口：feed 被点 = turret_system.takeover_by_feed
		EventBus.monitor_feed_clicked.connect(_turret_system.takeover_by_feed)
		# 接管/释放 → 主视角搬移（DEC-038：接管副炮 = 主视角切到该炮视角）
		EventBus.turret_takeover_started.connect(_on_takeover_started)
		EventBus.turret_takeover_ended.connect(_on_takeover_ended)
		# LeadPrediction marker：接管 MANUAL 时显示
		_build_lead_marker()
	# feed / 标记清单都从上面两张「唯一真源」表派生（节点缺失即 fail-fast，
	# 比后面静默缺一路画面好查）。has() 去重是为了兼容"一块 feed 供多块屏"。
	for pair in SCREEN_FEED:
		var sv := get_node(pair[1]) as SubViewport
		if sv != null and not _feeds.has(sv):
			_feeds.append(sv)
	for fb in FEED_CAM_FALLBACK:
		var mk := get_node("Markers/" + str(fb["marker"])) as Node3D
		if mk != null and not _markers.has(mk):
			_markers.append(mk)
	if _feeds.size() != SCREEN_FEED.size():
		push_warning("feed 数量 %d != 屏幕数 %d，检查 SCREEN_FEED 路径" % [_feeds.size(), SCREEN_FEED.size()])

	# SubViewport 的 world_3d 共享 + UPDATE_ALWAYS 强制每帧渲染，
	# 已挪到 _configure_feeds() 里统一处理（见那里注释的三个坑）。

	_log("[ready] feeds 数量 = %d", [_feeds.size()])

	_build_starfield()

	# ↓↓↓ 以下 4 步存在顺序依赖，不要随意调换 ↓↓↓
	# ① _configure_feeds 先定 feed 分辨率 —— 屏幕长宽比要跟着它走（见 ③）；
	# ② _place_markers 先摆好标记 —— ①相机看向标记的「实际位置」，
	#    ②standoff 的兜底值按标记最终距离推算（若先解析配置会算成旧的 33.75m，
	#    详见 _place_markers() 里的注释）；
	# ③ _layout_screens 用 ① 的分辨率决定屏幕网格长宽比；
	# ④ _bind_screens 最后绑纹理（要等网格与视口都就绪）。
	var feed_size := _configure_feeds()
	_place_markers()
	_aim_feeds()
	_layout_screens(feed_size.x, feed_size.y)
	_bind_screens()
	# ↑↑↑ 顺序依赖结束 ↑↑↑
	_player.rotation.y = _yaw
	_camera.rotation.x = _pitch

	# FeedTimer 目前是空转：SubViewport 用 UPDATE_ALWAYS(=4) 持续渲染，定时器并不驱动出图。
	# 保留它（含下面这次手动触发）作为将来切回 UPDATE_ONCE 省性能时的开关位。
	$FeedTimer.wait_time = 1.0 / maxf(_feed_fps, 1.0)
	$FeedTimer.timeout.connect(_on_feed_timer)
	_on_feed_timer()   # 注意：当前函数体为空，这次调用不产生任何渲染

	# ⑨b 陷落演出编排器：运行时挂成子节点（像 DamageLog 挂 TurretSystem）。
	# 它用自己的 _ready 连事件，延迟绑定屏幕 / 相机 —— 这里只需 new + add_child。
	var collapse := CollapseSequence.new()
	collapse.name = "CollapseSequence"
	add_child(collapse)
	_collapse = collapse

	# ⑪ Game Feel：相机反馈（震屏 / 推镜）。**必须排在 CollapseSequence 之后** ——
	# GameFeel 靠兄弟节点名 "CollapseSequence" 找它来判断「L3 期间是否该让位」，
	# 反过来就没得找了（见 game_feel.gd `_locked_out`）。
	var feel := GameFeel.new()
	feel.name = "GameFeel"
	add_child(feel)
	feel.setup(_camera, _player)
	_game_feel = feel

	# ⑪ ⑤ 敌人血量反馈 · B 层：接管时屏幕上方中央的「当前目标」血条。
	# 目标用**闭包现查**而不是让它持有 EnemySystem / 波次：
	# 「当前目标」在工程里已有一个权威定义 = `Turret.acquire_target()`
	# （最近、悬停、在射程内），手动开火的 LeadPrediction 也用它 —— 复用同一个，
	# 血条与你实际瞄的那台就不会对不上。
	var bar := TargetHealthBar.new()
	bar.name = "TargetHealthBar"
	add_child(bar)
	bar.target_provider = func() -> Enemy:
		if _turret_system == null or _turret_system.current_manual_id == &"":
			return null
		var t := _turret_system.get_turret(_turret_system.current_manual_id)
		if t == null:
			return null
		return t.acquire_target()

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_report_selfcheck()


# ── 舷外标记摆放（位置/尺寸外置，JSON 是唯一真源）──────────
# 之前标记位置写死在 .tscn 里，且 Dorsal/Ventral(±45) 与 Port/Starboard(±60)
# 不一致 —— 导致 monitor.marker_distance=60 这个旋钮对一半扇区是谎言。
# 现在由 JSON 驱动：改 marker_distance / marker_size，4 个标记与 4 路相机
# 一起联动（相机看向标记实际位置），不会脱焦。
func _place_markers() -> void:
	var dist: float = _num("monitor", "marker_distance", 60.0)
	var size: float = _num("monitor", "marker_size", 6.0)
	# 注意：这里刻意只读 FEED_CAM_FALLBACK 的结构（feed/marker 名 + 方向），
	# 不走 _feed_cam_configs()。因为配置里 standoff 的兜底值依赖「标记当前距离」，
	# 若先解析配置、后摆标记，兜底就会按摆放前的旧距离算（曾导致 dorsal 算出 33.75
	# 而不是 45）。先摆标记、再解析配置，兜底才落在最终距离上。
	for fb in FEED_CAM_FALLBACK:
		var marker := get_node_or_null("Markers/" + str(fb["marker"])) as MeshInstance3D
		if marker == null:
			continue
		marker.position = (fb["axis"] as Vector3) * dist
		# 独立建网格，避免改写 .tscn 里 4 个标记共享的 box_marker 资源
		var bm := BoxMesh.new()
		bm.size = Vector3(size, size, size)
		marker.mesh = bm
	_log("[markers] 距离=%.1fm 尺寸=%.1fm（JSON 驱动）", [dist, size])


# ── feed 相机：挂在舰壁上，看向舷外标记 ─────────────────
# 每个 FeedCam 是其父 SubViewport 的子节点，故“最近的父 Viewport”= 该 SubViewport，
# 由官方文档确认：Camera3D 总是渲染在最近的父 Viewport 上。设置 local position/朝向即可。
#
# 【为什么必须贴舰壁】按 DEC-038，监控 = 4 路**副炮**实时画面，副炮装在舰体外表面；
# 相机浮在 45m 外的太空里既不成立、也拍不到"本舰周边"的态势。故挂载点由
# ship 尺寸推导（_hull_radius），方向取 axis，看向点取标记的**实际世界坐标**
# —— 改 marker_distance / ship.* 后相机会自动跟随，不会脱焦。
#
# ⚠ 挂载点在运行时由本函数每帧（启动时一次）写入 cam.position，
#   所以在编辑器里拖动 FeedCam 是**无效的**，改数值请改 presentation.json。
#   想让编辑器的 Camera Preview 与运行时一致，跑 scripts/tests/cam_probe.gd
#   拿到 Transform3D 粘回 .tscn（该探针读同一份 JSON，不会脱节）。
func _aim_feeds() -> void:
	for cfg in _feed_cam_configs():
		var feed_name: String = str(cfg["feed"])
		var marker_name: String = str(cfg["marker"])
		var sv := get_node_or_null("Feeds/" + feed_name) as SubViewport
		var marker := get_node_or_null("Markers/" + marker_name) as Node3D
		if sv == null:
			push_warning("feed 节点缺失: Feeds/%s" % feed_name)
			continue
		var cam := sv.get_node_or_null("FeedCam") as Camera3D
		if cam == null:
			push_warning("FeedCam 缺失于 %s" % sv.name)
			continue
		if marker == null:
			push_warning("标记节点缺失: Markers/%s（跳过 %s 的瞄准）" % [marker_name, feed_name])
			continue

		var mount: Vector3 = cfg["mount"]
		# 健全性检查：相机不能贴到标记上或跑到标记更外面，否则拍不到/拍反
		var marker_dist: float = marker.global_position.length()
		var mount_dist: float = mount.length()
		if mount_dist >= marker_dist * 0.95:
			push_warning("%s 挂载点距中心 %.1fm 已接近/超过标记距离 %.1f，画面可能拍不到标记" % [
				feed_name, mount_dist, marker_dist])
		# SubViewport 非 Node3D，其下 Node3D 的 local == 世界坐标
		cam.position = mount
		cam.look_at(marker.global_position, cfg["up"] as Vector3)
		var mount_src: String = cfg["mount_src"]
		# 打印 src 是为了排查「改了 JSON 却没生效」：显示 [JSON] 说明读到了配置，
		# 显示 [兜底] 说明这项在 JSON 里缺失/非法，用的是推导值。
		# mount_src 则说明挂载点来自哪一级：显式 / 舰壁 / 比例兜底（见 _feed_cam_configs 头注释）。
		_log("[aim] %-11s 挂载=%s (距中心%.1fm, %s) -> %s(%.1fm 处) up=%s [%s]", [
			sv.name, str(mount), mount_dist, mount_src, marker_name, marker_dist,
			str(cfg["up"]), "JSON" if str(cfg["src"]) == "JSON" else "兜底"])


## 读取 monitor.feed_cams，逐项校验并补全缺省值。
## 每项最终保证含：feed / marker / axis(Vector3,已归一化) / mount(Vector3 挂载点) / up(Vector3)。
##
## 【挂载点三级优先级】数值一律外置，代码不含任何坐标常量：
##   ① JSON 显式 "mount": [x,y,z]           —— 想精确控制某路相机时用（如 dorsal 往前挪）
##   ② 舰壁推导 axis × _hull_radius(axis)   —— 默认。ship.width/height/length 均来自 JSON
##   ③ 标记距离 × FEED_CAM_STANDOFF_RATIO   —— 船体尺寸缺失才会走到，属"别忘了还能跑"
func _feed_cam_configs() -> Array:
	if not _feed_cam_cache.is_empty():
		return _feed_cam_cache
	var out: Array = []
	var raw: Variant = null
	if _data.has("monitor") and (_data["monitor"] is Dictionary):
		var m := _data["monitor"] as Dictionary
		if m.has("feed_cams"):
			raw = m["feed_cams"]

	if not (raw is Array) or (raw as Array).is_empty():
		push_warning("presentation.json 缺 monitor.feed_cams，回退内置方向（挂载点=舰壁，见 _hull_radius）")
		raw = []

	var by_feed := {}   # feed 名 -> 配置（JSON 项按名索引，顺序无关）
	for item in (raw as Array):
		if not (item is Dictionary):
			push_warning("feed_cams 存在非对象项，已跳过")
			continue
		var d := item as Dictionary
		if not d.has("feed") or not d.has("marker"):
			push_warning("feed_cams 项缺 feed/marker 键，已跳过: %s" % str(d))
			continue
		by_feed[str(d["feed"])] = d

	for fb in FEED_CAM_FALLBACK:
		var feed_name: String = fb["feed"]
		var marker_name: String = fb["marker"]
		var axis: Vector3 = fb["axis"]
		# 挂载点（Vector3，世界坐标）。三级优先级见本函数头注释。
		# mount_src 记录挂载点**实际来自哪一级**，进日志用——排查「改了 mount 没生效」时看它。
		var mount := Vector3.ZERO
		var mount_src := ""
		var up := Vector3(0, 1, 0)
		var src := ""
		if by_feed.has(feed_name):
			var d := by_feed[feed_name] as Dictionary
			var m_name: String = str(d["marker"])
			if m_name != marker_name:
				push_warning("feed_cams[%s].marker=%s 与内置映射 %s 不一致，以 JSON 为准" % [feed_name, m_name, marker_name])
				marker_name = m_name
			if d.has("axis"):
				axis = _vec3_from(d["axis"], axis)
			if axis.length_squared() < 0.000001:
				push_warning("feed_cams[%s].axis 为零向量，回退内置方向 %s" % [feed_name, str(fb["axis"])])
				axis = fb["axis"]
			if d.has("mount"):
				mount = _vec3_from(d["mount"], Vector3.ZERO)
				if mount.length_squared() > 0.000001:
					mount_src = "显式"
			if d.has("up"):
				up = _vec3_from(d["up"], up)
			src = "JSON"
		axis = axis.normalized()
		# 挂载点缺省/非法 → 贴舰壁（②），再不行 → 按标记距离的比例兜底（③）
		var marker := get_node_or_null("Markers/" + marker_name) as Node3D
		var marker_dist: float = marker.global_position.length() if marker != null else 0.0
		if mount.length_squared() < 0.000001:
			var hull_r: float = _hull_radius(axis)
			if hull_r > 0.0:
				mount = axis * hull_r
				mount_src = "舰壁"
			else:
				mount = axis * marker_dist * FEED_CAM_STANDOFF_RATIO
				mount_src = "比例兜底"
		if mount.length_squared() < 0.000001:
			mount = axis * FEED_CAM_STANDOFF_RATIO   # 极端兜底：避免零位姿
			mount_src = "极端兜底"
		# up 与朝向共线会让 look_at 报警并给出不确定的滚转 → 自动换一个正交轴
		if absf(axis.dot(up.normalized())) > 0.99:
			var fixed := Vector3(0, 0, -1) if absf(axis.dot(Vector3(0, 0, -1))) < 0.99 else Vector3(1, 0, 0)
			push_warning("feed_cams[%s].up=%s 与朝向共线，自动改为 %s" % [feed_name, str(up), str(fixed)])
			up = fixed
		out.append({
			"feed": feed_name, "marker": marker_name,
			"axis": axis, "mount": mount, "mount_src": mount_src, "up": up, "src": src})
	_feed_cam_cache = out
	return out


## 沿 axis 方向的「舰体外表面半径」（米）—— 监控相机就装在这一点上
## （DEC-038：监控 = 副炮视角，副炮在舰体外表面；不是漂在太空里的自由相机）。
## 半宽取自 JSON 的 ship.width / ship.height / ship.length 各除 2，
## 再外扩 monitor.feed_cam_hull_offset —— 留出镜头长度，将来补上船体网格
## 时相机不会陷进舱壁里看不见外面。
## 返回 0 表示船体尺寸拿不到（此时调用方退到比例兜底）。
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


## Variant → Vector3（数组逐项转 float；踩坑 #5：不能 float(数组)，须 float(a[0])）
func _vec3_from(v: Variant, fallback: Vector3) -> Vector3:
	if v is Array:
		var a := v as Array
		if a.size() >= 3:
			return Vector3(float(a[0]), float(a[1]), float(a[2]))
	if v is Vector3:
		return v as Vector3
	return fallback


## Variant → Color（接受 [r,g,b] 或 [r,g,b,a]，0..1；也接受 0..255 的整数写法，
## 因为美术在 JSON 里更习惯写 255 —— 判定规则：任一项 >1 就整体当 0..255 处理）。
func _color_from(v: Variant, fallback: Color) -> Color:
	if not (v is Array):
		return fallback
	var a := v as Array
	if a.size() < 3:
		return fallback
	var r := float(a[0])
	var g := float(a[1])
	var b := float(a[2])
	var al := float(a[3]) if a.size() >= 4 else 1.0
	if maxf(r, maxf(g, b)) > 1.0 or al > 1.0:
		return Color(r / 255.0, g / 255.0, b / 255.0, al / 255.0)
	return Color(r, g, b, al)


## 读 monitor.screen_material 里的一个键；返回 null = JSON 没给（调用方据此保留原值）。
func _mat_conf(key: String) -> Variant:
	if not _data.has("monitor") or not (_data["monitor"] is Dictionary):
		return null
	var m := _data["monitor"] as Dictionary
	if not m.has("screen_material") or not (m["screen_material"] is Dictionary):
		return null
	var sm := m["screen_material"] as Dictionary
	if not sm.has(key):
		return null
	return sm[key]


# ── feed 分辨率（外置，来自 presentation.json）──────────────
# 4 路 SubViewport 统一用同一分辨率；它同时决定画面的长宽比，
# 屏幕网格会据此等比生成（见 _layout_screens）。
## 配置 4 路 feed SubViewport：分辨率 + 共享主世界 + 强制每帧渲染。
##
## 三个坑（每个不修都会出诡异现象）：
##   ① .tscn 里 render_target_update_mode=3（UPDATE_WHEN_PARENT_VISIBLE），
##      对贴在 3D 网格上的 SubViewport 而言"父可见"语义不准，GPU 采样时
##      纹理可能还是白色空缓冲 → 屏幕全白。强制设为 UPDATE_ALWAYS(=4)。
##   ② 默认 SubViewport.own_world_3d=true，会建独立 World3D，
##      feed 相机拍不到主世界里的标记/星空/灯光 → 黑/白画面。需共享主世界。
##   ③ 分辨率兜底：JSON 缺/非法时回退 320x240（与 presentation.json 默认值一致）。
func _configure_feeds() -> Vector2i:
	var fw: int = int(_num("monitor", "feed_width", 320.0))
	var fh: int = int(_num("monitor", "feed_height", 240.0))
	if fw <= 0 or fh <= 0:
		push_warning("feed 分辨率非法(%dx%d)，回退 320x240" % [fw, fh])
		# 这里的 320x240 与 presentation.json 里的默认值保持一致
		# （解析失败时才走到这，属"最后的兜底"，不是可配置项）
		fw = 320
		fh = 240
	var main_world := get_viewport().world_3d   # 必须在循环前取好
	for sv in _feeds:
		sv.size = Vector2i(fw, fh)
		sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		sv.world_3d = main_world                # 共享主世界，feed 相机才能拍到标记/星空
	return Vector2i(fw, fh)


## 屏幕长宽比策略（一个旋钮，语义明确）：
##   monitor.screen_aspect <= 0  → 自动跟随 feed 分辨率【默认/推荐】
##       网格长宽比 == 渲染目标长宽比 ⇒ 整幅画面 1:1 等比铺满，中心对中心，
##       不裁切、不拉伸；改 feed 分辨率时屏幕自动跟着变。
##   monitor.screen_aspect >  0  → 强制该长宽比
##       与 feed 长宽比不一致时，画面会被裁切或留黑边（一般不需要）。
func _screen_aspect(feed_w: int, feed_h: int) -> float:
	var declared: float = _num("monitor", "screen_aspect", 0.0)
	if declared > 0.0:
		return declared
	if feed_w > 0 and feed_h > 0:
		return float(feed_w) / float(feed_h)
	return 4.0 / 3.0   # feed 尺寸也拿不到时的最后兜底


# ── 屏幕网格：运行时重建，保证「整幅画面等比铺满、中心对中心」──────
#
# 【根因记录 2026-09-02，实测数据】Godot 的 BoxMesh 使用 3×2 的 UV 图集：
# 立方体 6 个面各占 UV 空间的 1/3 × 1/2。实测 BoxMesh(0.5,0.375,0.02) 的
# 正面（法线 +Z，即朝向玩家的那一面）UV 区间只有 (0,0)..(0.3333,0.5)，
# 也就是整幅画面的「左上角 1/3 宽 × 1/2 高」。于是摄像机画面的中心(uv 0.5,0.5)
# 被映射到屏幕右边缘之外、且贴上边缘 —— 表现为
# “摄像机预览里方块在正中心，监控屏幕上方块却不在中心”。
#
# 【修法】屏幕改用 QuadMesh：实测其朝向/法线(+Z)/uv(0,0)位于左上角
# 与 BoxMesh 正面完全一致，但 UV 铺满 (0,0)..(1,1)，属直接替换、无需改 transform。
# 再让网格长宽比 == feed 长宽比，即得「整幅画面等比缩放铺满屏幕」。
#
# 这里在运行时重建而非只改 .tscn，是双保险：即便 Godot 编辑器把 .tscn
# 回退成旧版（编辑器开着的已知坑），运行起来的画面依旧正确。
func _layout_screens(feed_w: int, feed_h: int) -> void:
	var w: float = _num("monitor", "screen_width", 0.5)
	var aspect: float = _screen_aspect(feed_w, feed_h)
	var h: float = w / maxf(aspect, 0.01)   # maxf 防 aspect 为 0 时除零
	for pair in SCREEN_FEED:
		var screen := get_node_or_null(pair[0]) as MeshInstance3D
		if screen == null:
			push_warning("屏节点缺失: %s" % pair[0])
			continue
		var q := QuadMesh.new()
		q.size = Vector2(w, h)
		screen.mesh = q
	_log("[layout] 屏幕网格 QuadMesh %.3f x %.3f (aspect %.4f, feed %dx%d)", [w, h, aspect, feed_w, feed_h])


# 把每屏材质纹理设为对应 SubViewport 的渲染结果，并应用 JSON 里的材质旋钮。
# 官方/社区确认：运行时最可靠的做法是 SubViewport.get_texture()——它返回一个
# 已经绑定好该视口的 ViewportTexture，彻底绕开 viewport_path 在编辑器/实例化时的
# “路径丢失 → 粉黑棋盘 / 白板”问题（之前用 ViewportTexture.new()+viewport_path 失败）。
#
# 【材质旋钮：monitor.screen_material】
#   键**存在** → 以 JSON 为准（运行时强制写入，编辑器里的值会被覆盖）；
#   键**不存在** → 保留 .tscn / 编辑器里的值，交给美术在检查器里调。
#   这样既守住"数值外置"铁律，又不剥夺在编辑器里试手感的能力。
#
# 【默认 emission_enabled=false + emission=(0,0,0)：原始画面 = albedo 直接显示 feed】
# 监控 feed 是"暗深空 + 彩色标记"的暗画面，自发光一开（尤其非黑）会把整块屏
# 洗成亮斑/白板，反而看不见标记。所以默认【不加自发光覆盖】，画面靠 room 环境光
# 照亮（见 _apply_environment 把 ambient_light_source 强制为 COLOR）。要自发光只
# 改 JSON 的 emission_enabled/emission，不影响其它逻辑。
# ALBEDO = albedo_color.rgb × albedo_texture.rgb，albedo_color 默认 (1,1,1) 让
# feed 原样呈现，不二次染色。
func _bind_screens() -> void:
	for pair in SCREEN_FEED:
		var screen := get_node(pair[0]) as MeshInstance3D
		var sv := get_node(pair[1]) as SubViewport
		if screen == null or sv == null:
			push_warning("屏/feed 节点缺失: %s -> %s" % [pair[0], pair[1]])
			continue
		# ViewportTexture 必须显式把 viewport 指给 SubViewport，否则 GPU 采样时
		# 渲染目标未绑定，画面就是白色占位符（CPU 端的 get_image() 走的是另一条路，
		# 所以诊断里 "纹理已绑=true" 也会骗人 —— 必须看 viewport 字段非空才算通）。
		var vt := ViewportTexture.new()
		vt.viewport_path = sv.get_path()    # 显式指给 SubViewport；GPU 采样才能拿到渲染目标
		if vt == null:   # pragma: no cover
			push_warning("%s SubViewport.get_texture() 返回空" % pair[1])
			continue
		# 准备 ImageTexture —— 运行时由 _process 节流推送 SubViewport 画面。
		# 跳过 ViewportTexture 直接 GPU 采样的"白板"坑（详见 _ready 注释）。
		var it := ImageTexture.new()
		# 与 _feeds 一一对应（顺序由 SCREEN_FEED 决定）
		# 注：不在这里预填黑图。0×0 的 ImageTexture 在首帧前只会被采样成黑色（不是白），
		# 首帧 _process 用 set_image() 填进真实 feed（含正确格式），不会出现持久白板。
		# 之前试图预填黑图，但 ViewportTexture.get_format() 返回的是 GPU 内部格式(47)，
		# 不能用来 Image.create() —— 那条路走不通，故撤掉。
		_feed_textures.append(it)
		# 全新构造材质（彻底绕开 .tscn 里那 4 个带 vt_* 的陈旧子资源 + 编辑器覆盖陷阱）
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(1, 1, 1)
		m.albedo_texture = it          # 用 ImageTexture，绕开 ViewportTexture 采样白板坑
		# 默认不加自发光覆盖：feed 是暗画面，emission 一开就被洗成白板。
		# 原始画面靠 albedo + 房间环境光照亮（见 _apply_environment）。
		m.emission_enabled = false
		m.emission = Color(0, 0, 0)
		# 注意：不再绑 emission_texture —— 自发光关着时绑了也无效，反而迷惑。
		# UV 变换显式归位：防御 mesh 残留的 uv1_scale/offset 把画面缩到一角。
		m.uv1_scale = Vector3(1, 1, 1)
		m.uv1_offset = Vector3(0, 0, 0)
		# ── JSON 材质覆盖（存在即覆盖；缺失保留上面默认值）──
		# 注意：_mat_conf 返回 Variant，必须写显式类型 `var x: Variant`。
		# 写 `var x := _mat_conf(...)` 会触发本工程 "Warning treated as error"。
		var ac: Variant = _mat_conf("albedo_color")
		if ac != null:
			m.albedo_color = _color_from(ac, m.albedo_color)
		var em: Variant = _mat_conf("emission")
		var ee: Variant = _mat_conf("emission_enabled")
		if em != null:
			var col := _color_from(em, m.emission)
			m.emission = col
			# 未显式给 emission_enabled 时按 emission 是否非黑自动判定，
			# 免掉「改了 emission 却忘了开开关 → 白改」这个经典坑。
			if ee == null:
				m.emission_enabled = (col.r + col.g + col.b) > 0.0001
		if ee != null:
			m.emission_enabled = bool(ee)   # 显式开关优先
		# material_override 优先于 surface_material_override；赋给节点即生效。
		screen.material_override = m
		# 诊断：dump emission_texture 的身份 —— 排查「以为绑上了实际是白色占位」
		var et := m.emission_texture
		var et_info: String = "null"
		if et != null:
			et_info = "%s viewport=%s viewport_path=%s" % [et.get_class(),
				str(et.get("viewport")), str(et.get("viewport_path"))]
		_log("[bind] %-24s <- %-14s albedo=%s emission=%s(enabled=%s) 纹理已绑=%s | et=%s", [
			pair[0], pair[1], str(m.albedo_color), str(m.emission),
			str(m.emission_enabled), str(m.albedo_texture != null), et_info])


# 一次性诊断：用四项实测证明「摄像机画面的中心 == 监控屏幕的中心，且画面没被材质洗过」。
#   ① UV 区间：屏幕网格实际采样范围必须是 (0,0)..(1,1)，否则画面只显示了一角；
#   ② 长宽比：屏幕网格 aspect 必须 == feed aspect，否则画面被拉伸/压扁；
#   ③ 内容重心：舷外彩色标记在画面中的归一化重心应 ≈ (0.5,0.5)；
#   ④ 材质：albedo_texture 必须已绑定，且 emission 不能是"发光覆盖层"
#      （emission_enabled=false，或 emission 为黑）—— 否则画面被自发光洗白，
#      看起来就不是摄像机原始画面了（9/3 用户实测结论）。
# ①②③ 成立 = 整幅画面等比铺满且中心对齐；④ 成立 = 显示的是原始画面。
func _diag_feeds() -> void:
	print("=== feed 出图诊断：画面中心 == 屏幕中心？ ===")
	for pair in SCREEN_FEED:
		var sv := get_node_or_null(pair[1]) as SubViewport
		var screen := get_node_or_null(pair[0]) as MeshInstance3D
		if sv == null or screen == null:
			continue

		# ① 屏幕网格的 UV 采样区间
		var uv_min := Vector2(INF, INF)
		var uv_max := Vector2(-INF, -INF)
		var m := screen.mesh
		if m != null and m.get_surface_count() > 0:
			var arr := m.surface_get_arrays(0)
			var uvs := arr[Mesh.ARRAY_TEX_UV] as PackedVector2Array
			for uv in uvs:
				uv_min = uv_min.min(uv)
				uv_max = uv_max.max(uv)
		var uv_full: bool = uv_min.length() < 0.001 and (uv_max - Vector2(1, 1)).length() < 0.001

		# ② 长宽比是否一致
		var feed_a: float = float(sv.size.x) / maxf(float(sv.size.y), 1.0)
		var quad := m as QuadMesh
		var mesh_a: float = (quad.size.x / maxf(quad.size.y, 0.0001)) if quad != null else 0.0
		var aspect_ok: bool = absf(mesh_a - feed_a) < 0.01

		# ③ 画面内容重心
		var c := _content_centroid(sv)
		# 容差 0.06：标记是转动的立方体，重心会随姿态小幅摆动；实测摆幅 <0.02，
		# 留 3 倍余量。若哪天这里报"超出"，说明中心真的偏了，不是标记在转。
		var centroid_ok: bool = c.x >= 0.0 and absf(c.x - 0.5) < 0.06 and absf(c.y - 0.5) < 0.06

		# ④ 材质：纹理绑上了吗？自发光会洗白画面吗？
		# 注意：这里必须写显式类型（var mat: StandardMaterial3D = ... as ...）。
		# 用 `var mat := x as T` 时推断自 Variant，会被本工程的
		# "Warning treated as error" 拦下来（冒烟时当场炸过一次）。
		var mat: StandardMaterial3D = screen.get_active_material(0) as StandardMaterial3D
		var tex_bound: bool = mat != null and mat.albedo_texture != null
		var glow_off: bool = mat == null or (not mat.emission_enabled) \
			or (mat.emission.r + mat.emission.g + mat.emission.b) < 0.0001
		# albedo 若接近黑，画面会被 albedo_color 乘没了（ALBEDO = color × texture）
		var albedo_ok: bool = mat != null and (mat.albedo_color.r + mat.albedo_color.g + mat.albedo_color.b) > 0.3

		print("[diag] %-13s uv=%s..%s %s | aspect feed=%.4f mesh=%.4f %s | 内容重心=(%.3f, %.3f) %s" % [
			sv.name,
			str(uv_min), str(uv_max), _ok(uv_full),
			feed_a, mesh_a, _ok(aspect_ok),
			c.x, c.y, _ok(centroid_ok)])
		print("[diag] %-13s 材质:纹理已绑%s | 无自发光覆盖%s | albedo够亮%s" % [
			sv.name, _ok(tex_bound), _ok(glow_off), _ok(albedo_ok)])


## 抓帧存盘（DEBUG_CAPTURE=true 时启动约 1 秒后自动跑一次）。
## 存两类图：① 主窗口截图（人眼实际看到的监控屏长什么样）
##           ② 4 路 feed 原始画面（摄像机到底拍到了什么）
## 加统计量（平均亮度 / 最亮值 / 非黑像素占比）是因为：只看 PNG 容易漏，
## 而"平均亮度≈0"能一票判定"feed 根本没出图"。
func _capture_debug() -> void:
	var dir := "user://shots"
	DirAccess.make_dir_recursive_absolute(dir)
	var abs_dir: String = ProjectSettings.globalize_path(dir + "/")
	print("[capture] 抓帧输出目录: %s" % abs_dir)

	# ① 主窗口画面（此刻 _process 在绘制前，拿到的是上一帧，正是玩家看到的）
	var main_img := get_viewport().get_texture().get_image()
	if main_img != null:
		var p := dir + "/main.png"
		var err := main_img.save_png(p)
		print("[capture] 主窗口 -> %s  (%dx%d, err=%d) 平均亮度=%.4f" % [
			ProjectSettings.globalize_path(p), main_img.get_width(), main_img.get_height(),
			err, _mean_luma(main_img)])
	else:
		push_warning("[capture] 主窗口截图失败")

	# ② 4 路 feed
	for pair in SCREEN_FEED:
		var sv := get_node_or_null(pair[1]) as SubViewport
		if sv == null:
			continue
		var tex := sv.get_texture()
		var img := tex.get_image() if tex != null else null
		if img == null:
			push_warning("[capture] %s 无图像" % sv.name)
			continue
		var fp := dir + "/feed_%s.png" % sv.name.to_lower()
		var ferr := img.save_png(fp)
		print("[capture] %-11s -> %s  (%dx%d, err=%d) 平均亮度=%.4f 最亮=%.3f 非黑像素=%.1f%%" % [
			sv.name, ProjectSettings.globalize_path(fp), img.get_width(), img.get_height(),
			ferr, _mean_luma(img), _max_luma(img), _nonblack_ratio(img) * 100.0])


## 全图平均亮度（0..1）。feed 若根本没渲染，这个值会是 0.0000。
func _mean_luma(img: Image) -> float:
	var s := 0.0
	var n := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c := img.get_pixel(x, y)
			s += (c.r + c.g + c.b) / 3.0
			n += 1
	return s / maxf(float(n), 1.0)


## 全图最亮像素的亮度。用来区分"暗但不是全黑"（有星点/标记）与"纯黑"。
func _max_luma(img: Image) -> float:
	var mx := 0.0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c := img.get_pixel(x, y)
			mx = maxf(mx, (c.r + c.g + c.b) / 3.0)
	return mx


## 亮度 > 0.02 的像素占比。用来判断画面里"有多少东西"，而不是"平均有多亮"。
func _nonblack_ratio(img: Image) -> float:
	var hit := 0
	var n := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c := img.get_pixel(x, y)
			if (c.r + c.g + c.b) / 3.0 > 0.02:
				hit += 1
			n += 1
	return float(hit) / maxf(float(n), 1.0)


## 计算 feed 画面内容的加权重心（归一化到 0..1，纹理坐标：v=0 为画面顶部）。
## 只统计「够亮且够饱和」的像素 —— 即舷外的彩色发光标记；
## 暗背景（太空）与白色星点因饱和度≈0 会被滤掉，不干扰重心。
## 重心 ≈ (0.5,0.5) 即证明标记正好落在画面正中央。
func _content_centroid(sv: SubViewport) -> Vector2:
	var tex := sv.get_texture()
	if tex == null:
		push_warning("[diag] %s 纹理为空!" % sv.name)
		return Vector2(-1, -1)
	var img := tex.get_image()
	if img == null:
		push_warning("[diag] %s get_image() 返回空（可能尚未渲染）" % sv.name)
		return Vector2(-1, -1)
	var w := img.get_width()
	var h := img.get_height()
	var sum_x := 0.0
	var sum_y := 0.0
	var sum_w := 0.0
	# 步长 2 = 隔像素采样，像素量降到 1/4。重心是统计量，半采样足够准，
	# 而 get_pixel() 是逐像素函数调用，全采样在 320×240×4 路上会明显卡顿。
	# 阈值（mx≥0.25 且 sat≥0.12）是"够亮且够彩"的判据，取值来自实测：
	# 暗太空 mx≈0.02、白色星点 sat≈0.01，都被滤掉；标记本身 mx≈1、sat≈0.5 稳定入选。
	for y in range(0, h, 2):
		for x in range(0, w, 2):
			var c := img.get_pixel(x, y)
			var mx: float = maxf(c.r, maxf(c.g, c.b))
			var mn: float = minf(c.r, minf(c.g, c.b))
			var sat: float = mx - mn
			if mx < 0.25 or sat < 0.12:
				continue
			var weight: float = mx * sat
			sum_x += float(x) * weight
			sum_y += float(y) * weight
			sum_w += weight
	if sum_w <= 0.0:
		return Vector2(-1, -1)
	return Vector2(sum_x / sum_w / float(w), sum_y / sum_w / float(h))


## FeedTimer 回调。当前为空实现：SubViewport 的 render_target_update_mode
## 运行时由 _configure_feeds() 强制设为 UPDATE_ALWAYS(=4)，每帧都渲染，
## 定时器无事可做。
## 将来若要省性能：把 _configure_feeds 里改成 UPDATE_ONCE(=1)，并在这里写
##   `for sv in _feeds: sv.render_target_update_mode = SubViewport.UPDATE_ONCE`
## 即可按 monitor.feed_fps 节流，无需改动其它代码。
func _on_feed_timer() -> void:
	pass


# ── 输入：第一人称转头 + ESC 释放鼠标 ───────────────────
func _input(event: InputEvent) -> void:
	# ⑨b L3 终局演出期间**夺玩家操控**（DEC-043：取消操控 → 镜头运动 → 宣告）。
	if _collapse != null and _collapse.is_locked():
		return
	if event is InputEventMouseMotion:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			return
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * _sens
		_pitch -= mm.relative.y * _sens
		var lim := deg_to_rad(_pitch_limit)
		_pitch = clampf(_pitch, -lim, lim)
		_player.rotation.y = _yaw
		_camera.rotation.x = _pitch
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			else:
				# 已 CAPTURED + 按下 = 扳机（手动模式下）
				if _turret_system != null and _turret_system.current_manual_id != &"":
					EventBus.turret_fired.emit(_turret_system.current_manual_id)
	elif event is InputEventKey:
		var k := event as InputEventKey
		# ⑦ 维修站过场期间：**所有**按键先交给过场。
		# 不拦的后果很具体：改装台按 1-4 会同时触发「接管炮塔」，按 B 会在过场里开战，
		# 表现为「改装 UI 抽风」。
		# 拦截写在这里而不是让 RefitSequence 自己接 _input —— Godot 的 _input 广播顺序
		# 不保证，抢不过来；显式转调才有确定的先后顺序。
		if _refit_seq != null and _refit_seq.is_playing() and k.pressed:
			_refit_seq.handle_key(k.keycode)
			return
		if k.pressed and k.keycode == KEY_ESCAPE:
			# ESC 双阶段（④接管引入）：
			#   ① 若当前接管某门炮 → 释放接管（回主控室），不切鼠标模式
			#   ② 否则按原逻辑：CAPTURED → VISIBLE；VISIBLE → quit
			if _turret_system != null and _turret_system.current_manual_id != &"":
				_turret_system.takeover(&"")
				return
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			else:
				get_tree().quit()
		elif k.pressed and TAKEOVER_KEYS.has(k.keycode):
			# 1 = 主炮（直接接管）；2-5 = 某一路 feed，**再按同键切该路下一门炮**，
			# 转完一圈回主控室（⑧ 每路两个炮位，见 TurretSystem.takeover_sector）。
			# 接管副炮时主视角会搬到舰体外表面（见 _on_takeover_started）。
			if _turret_system != null:
				var target := TAKEOVER_KEYS[k.keycode] as StringName
				# ⑩ 控制台点击音：接管是玩家最高频的操作，没有听觉反馈时
				# 「按了 3 键但没切过去」和「按了 3 键切过去了但画面变化不明显」分不清。
				# 键盘事件天然不会同帧重复，但仍过 AudioManager 的统一入口（限流表里 limit_ms=0）。
				AudioManager.play_sfx(&"sfx_ui_click")
				if target == &"main":
					_turret_system.takeover(&"main")
				else:
					_turret_system.takeover_sector(target)
		elif k.pressed and k.keycode == KEY_B:
			# B = 开战 / 收战开关。**这是第⑤步之前缺失的 BATTLE 入口**：
			# 状态机初始 REFIT，而此前没有任何输入能切到 BATTLE，
			# 于是 set_battle_active(true) 从未在实机被调用过 —— 5 门炮的自动开火
			# 代码一直是对的，只是从没跑起来（Round 2 的断言是测试里手动调的）。
			# RESULT 状态下按 B 先回 REFIT（RESULT→BATTLE 是非法转移，见
			# GameStateManager.ALLOWED_TRANSITIONS），再按一次才开战。
			#
			# 这条 print 是**调试入口**，刻意不走 _log：入口类日志一关，
			# "按了 B 没反应"就分不清是「按键没进 _input」还是「状态机没切」。
			if GameStateManager.is_battle() or GameStateManager.is_result():
				print("[debug] 按 B → 收战（请求 REFIT）")
				GameStateManager.change_state(GameStateManager.State.REFIT)
			else:
				print("[debug] 按 B → 开战（请求 BATTLE，炮塔回满 + 自动开火）")
				# ⑩ 开战确认音：在白盒阶段 B 就是「装配完成 → 出击」的确认键，
				# 用 audio.json 里的 sfx_refit_confirm。将来接真 UI 时它挪到确认按钮上。
				AudioManager.play_sfx(&"sfx_refit_confirm")
				GameStateManager.change_state(GameStateManager.State.BATTLE)
			_refresh_hud()
		elif k.pressed and k.keycode == KEY_SPACE:
			# 扳机：手动接管状态下按 Space 发弹（鼠标左键同效，见上面 MouseButton 分支）
			if _turret_system != null and _turret_system.current_manual_id != &"":
				EventBus.turret_fired.emit(_turret_system.current_manual_id)
		elif k.pressed and (k.keycode == KEY_E or k.keycode == KEY_R):
			# 白盒调试生成敌人。**不是波次调度**（⑨ 波次已由 WaveSystem 接管）。
			# 保留理由：验证扇区分布 / 压力计算 / 舷窗可见性时，不必等一波打完。
			# ⚠ 这些敌人**不计入波次**（WaveSystem 只追踪自己 spawn 的那批），
			# 故按 E 既不会让本波永远清不空，也不会推进危机数。
			#   E = 随机扇区（5 面，aft 按 DEC-036 排除）—— 验证扇区分布与压力
			#   R = 全部生成在 fore —— 艏部舷窗正对的方向，保证主视角**看得见**
			#
			# 为什么还要有 R：DEC-026 规定舰桥只有艏部一面舷窗，随机生成的敌人
			# 有 5/6 概率落在舷窗外，于是"按了 E 却看不到任何东西" —— 这**不是
			# 生成失败**，是设计使然。R 用来绕开这一点，确认敌人确实生成并飞来。
			#
			# 这条 print 是**新功能调试**，刻意不走 _log 开关：否则一旦被关掉，
			# "按了键却没反应" 就分不清是「按键没进 _input」还是「生成失败」。
			if _enemy_system == null:
				print("[debug] 生成失败：EnemySystem 不可用（节点缺失）")
				return
			var forced: StringName = &"fore" if k.keycode == KEY_R else &""
			print("[debug] 触发生成（%s）：2 拦截机 + 1 轰炸机" % [
				"定向 fore" if forced != &"" else "随机扇区"])
			_enemy_system.spawn_one(&"interceptor", forced)
			_enemy_system.spawn_one(&"interceptor", forced)
			_enemy_system.spawn_one(&"bomber", forced)
			_probe_enemies()
		elif k.pressed and k.keycode == KEY_F:
			# F = 敌人可见性诊断。调舷窗尺寸 / 来袭锥角 / 生成距离后按它，
			# 能立刻拿到"这个敌人到底看不看得见、被谁挡住"的实测数据，
			# 不用每次重新写探针。（输出格式见 _probe_dump）
			print("[debug] KEY_F 敌人可见性诊断（存活=%d）" % _enemy_system.enemy_count())
			_probe_enemies()


## 敌人可见性诊断（按 F 随时触发，也可由 E/R 生成后自动跑一次）。
## 用来同时回答「模型到底加没加进场景」和「为什么画面里看不见」两个问题。
##
## 输出四项：① 节点在场景树里的完整路径  ② Body 子节点与 mesh 实际尺寸
##          ③ 是否在主相机视锥内 + 投影到屏幕的哪个像素
##          ④ 相机→敌人的射线打在艏部墙平面(z=1.8)的交点是否落在**窗洞内**
##             （DEC-026 只有一面舷窗，被前墙挡住是"看不见"的头号嫌疑）
func _probe_enemies() -> void:
	_probe_dump()


func _probe_dump() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		print("[probe] 主相机不可用")
		return
	if _enemy_system == null:
		print("[probe] EnemySystem 缺失")
		return
	var vp: Vector2 = get_viewport().get_visible_rect().size
	print("[probe] ── 视口=%s 相机=%s fov=%.0f far=%.0f 存活=%d" % [
		str(vp), str(cam.global_position), cam.fov, cam.far, _enemy_system.enemy_count()])
	var total := 0
	var visible_n := 0
	for child in _enemy_system.get_children():
		var e := child as Enemy
		if e == null:
			continue
		total += 1
		var gp: Vector3 = e.global_position
		var body := e.get_node_or_null("Body") as MeshInstance3D
		var sp: Vector2 = cam.unproject_position(gp)
		var on_screen := sp.x >= 0.0 and sp.y >= 0.0 and sp.x <= vp.x and sp.y <= vp.y
		var verdict := _visibility_verdict(cam, gp)
		if verdict.begins_with("★"):
			visible_n += 1
		print("[probe] %s" % e.get_path())
		print("        全局=%s 距船=%.1f 距相机=%.1f" % [
			str(gp), gp.length(), cam.global_position.distance_to(gp)])
		print("        模型: Body=%s mesh尺寸=%s 材质=%s" % [
			"有" if body != null else "**缺失**",
			str(body.mesh.get_aabb().size) if body != null and body.mesh != null else "-",
			str(body.material_override.get_class()) if body != null and body.material_override != null else "-"])
		print("        视锥内=%s 屏幕像素=%s %s | %s" % [
			str(cam.is_position_in_frustum(gp)), str(sp),
			"在屏幕内" if on_screen else "（屏幕外）", verdict])
	if total > 0:
		print("[probe] 汇总：主视角可见 %d/%d（%.0f%%）" % [
			visible_n, total, 100.0 * float(visible_n) / float(total)])


## 判断某个世界坐标点能不能从主相机**真正看见**（不只是"在视锥里"）。
## 三级判定：① 相机→该点的射线打在艏部墙平面 z=WIN_Z 上的交点，是否落在窗洞内
##           ② 穿过窗洞后，视线会不会被**监控面板**挡住（它的上边缘投影到窗平面
##              大约在 y=1.21，是下半视野的真正杀手，比前墙填充块更致命）
##           ③ 敌人整体 vs 中心点：这里只判中心点，够用了（敌人尺寸远小于窗洞）
func _visibility_verdict(cam: Camera3D, target: Vector3) -> String:
	var to_e: Vector3 = target - cam.global_position
	if to_e.z <= 1e-4:
		return "在相机后方（视线不穿前墙）"
	var hit: Vector3 = cam.global_position + to_e * ((WIN_Z - cam.global_position.z) / to_e.z)
	if absf(hit.x) > WIN_X_HALF or hit.y < WIN_Y_MIN or hit.y > WIN_Y_MAX:
		return "被艏部墙挡住（命中 x=%.2f y=%.2f；窗洞 x±%.2f / y %.2f~%.2f）" % [
			hit.x, hit.y, WIN_X_HALF, WIN_Y_MIN, WIN_Y_MAX]
	# 穿过窗洞了，再查监控面板：看视线在面板所在深度处是否低于面板顶边
	var t_p: float = (PANEL_TOP_Z - cam.global_position.z) / to_e.z
	var p: Vector3 = cam.global_position + to_e * t_p
	if p.y < PANEL_TOP_Y and absf(p.x) <= PANEL_X_HALF:
		return "被监控面板挡住（面板处 x=%.2f y=%.2f < 顶边 %.2f）" % [p.x, p.y, PANEL_TOP_Y]
	return "★主视角可见"


func _process(delta: float) -> void:
	_fps_frames += 1
	_fps_time += delta
	if _fps_time >= 0.5:
		_fps = int(round(float(_fps_frames) / _fps_time))
		_fps_frames = 0
		_fps_time = 0.0
		_refresh_hud()
	# ⑦ 过场期间每帧刷 HUD：阶段会自己走（淡入/飞行/台词/改装），
	# 靠事件驱动刷新的话 HUD 会一直停在开始那一个阶段名上。
	# 过场分支里的 _refresh_hud 只拼 3 行短文本，每帧跑不心疼。
	if _refit_seq != null and _refit_seq.is_playing():
		_refresh_hud()
	# 标记自转：纯视觉点缀（让画面里能看出"东西在动"），不参与任何玩法判定，
	# 转速故直接写在代码里，不上浮到 JSON。
	for m in _markers:
		m.rotation.y += delta * 0.6
		m.rotation.x += delta * 0.3

	# 启动约 1 秒后跑一次出图诊断（等 SubViewport 出过几帧，纹理才有内容）。
	# ── feed 画面回读 → ImageTexture（节流到 feed_fps）────────
	# Godot 4 把 SubViewport 内容推到 ImageTexture 上才能被 3D 网格采样到（详见 _ready）。
	var feed_interval := 1.0 / maxf(_feed_fps, 1.0)
	_feed_readback_acc += delta
	if _feed_readback_acc >= feed_interval and not _feed_textures.is_empty():
		_feed_readback_acc = 0.0
		for i in _feeds.size():
			var sv := _feeds[i]
			# 必须写全 `var img: Image`：get_image() 在这一层返回的是 Variant
			# （SubViewport 未经 get_texture() 中转时静态类型推不出来），
			# 用 `:=` 会触发 "Cannot infer the type" —— 本项目开了警告即错误，
			# 一个推断不出来就是整个脚本 Parse Error，全部玩法跟着停摆。
			var feed_tex := sv.get_texture()
			if feed_tex == null:
				continue
			var img: Image = feed_tex.get_image()
			if img == null:
				continue
			# ImageTexture.update() 要求新图尺寸与纹理完全一致。首帧时纹理还是
			# 刚 new 出来的 0×0，直接 update() 会报 "The new image dimensions
			# must match the texture size" 却**不抛异常、只是不更新** ——
			# 表现就是"代码全对、屏幕永远全黑"。尺寸不符时改用 set_image()
			# 重新分配一次（首帧 / feed 分辨率被改时各触发一次），之后走 update()。
			var it := _feed_textures[i]
			if it.get_width() != img.get_width() or it.get_height() != img.get_height():
				it.set_image(img)
			else:
				it.update(img)

	# 诊断内容见 _diag_feeds()：UV 区间 / 长宽比 / 内容重心 / 材质 四项实测。
	# 2026-09-05：这四项已全部验证通过（4 路 feed 全 OK），故纳入 DEBUG_LOG 一起关掉，
	# 免得 8 条诊断行每天刷屏、盖住真正在调试的新模块日志。
	# 想复查画面时把 DEBUG_LOG 改回 true，诊断会重跑一遍（DEBUG_CAPTURE 再管抓帧）。
	_diag_t += delta
	if _diag_t > 1.0 and not _diag_done:
		_diag_done = true
		if DEBUG_LOG:
			_diag_feeds()
			if DEBUG_CAPTURE:
				_capture_debug()

	# ── LeadPrediction 标记位置（手动接管时实时跟拦截点）──
	_update_lead_marker(delta)


## 监听 game_state_changed：BATTLE 进入时启用自动开火；其他状态关闭。
##
## 「每波开战回满耐久」不在这里写 —— 它在 TurretSystem.set_battle_active 内部，
## 保证正式流程与测试场景手动开战走同一条路（详见那里的注释）。
func _on_game_state_changed(new_state: StringName) -> void:
	_state = new_state
	if _turret_system == null:
		return
	_turret_system.set_battle_active(new_state == &"BATTLE")
	_refresh_hud()


## ⑨ 波次开始 / 清空 → 刷 HUD。
## 两个信号共用这一个回调：本脚本对它们的反应完全相同（只是刷新显示），
## 拆成两个函数纯属样板。**调度决策不在这里** —— 全在 WaveSystem。
func _on_wave_event(_wave_index: int) -> void:
	_refresh_hud()


## ⑦ 过场开始：先退接管再交给改装台（见 _ready 里 connect 处的注释）。
func _on_cutscene_started() -> void:
	if _turret_system != null and _turret_system.current_manual_id != &"":
		_turret_system.takeover(&"")
	_refresh_hud()


## ⑦ 改装台把镜头搬到指定炮位（turret_id == &"" → 回主控室）。
## **完全复用接管的搬移逻辑，但不改炮塔模式**：改装时炮塔仍是 AUTO，
## 玩家只是被带过去看一眼自己要换的那门炮以及换装特效。
## 不复用 _on_takeover_started / _on_takeover_ended 的原因：那两个函数还会动
## current_manual_id 并发 takeover 信号，改装时发「接管」信号是错的语义。
func _on_refit_focus(turret_id: StringName) -> void:
	if _turret_system == null or _player == null:
		return
	if turret_id == &"":
		if _takeover_view:
			_takeover_view = false
			_player.position = _bridge_pos
			_yaw = _bridge_yaw
			_pitch = _bridge_pitch
			_player.rotation.y = _yaw
			_camera.rotation.x = _pitch
		return
	var t: Turret = _turret_system.get_turret(turret_id)
	# ⑧ 空槽位（已解锁但还没装炮）**没有 Turret 实例**，问不到 muzzle_pos ——
	# 改用槽位自己的物理位置，否则选中空槽位时相机一动不动，玩家会以为改装台卡了。
	var pos := t.muzzle_pos if t != null else _turret_system.slot_mount(turret_id)
	if t == null and pos == Vector3.ZERO:
		return    # 既没炮也没槽位定义（真·未知 id）：别把相机搬到原点
	if not _takeover_view:
		_bridge_pos = _player.position
		_bridge_yaw = _yaw
		_bridge_pitch = _pitch
		_takeover_view = true
	_player.position = pos
	_aim_outward(pos)


## ⑤ 全部炮塔被毁 → RESULT（DEC-037：失败条件 = 所有炮塔被毁，无 Hull / 无护盾）。
## ⑨b 之后这里不再是「立刻切 RESULT」，而是交给 CollapseSequence 启动 L3 终局演出
## （夺操控 → 拉远环绕镜头 → 宣告），演完由它自己切 RESULT。结算界面 / 最高危机数记录是 P1。
func _on_all_turrets_destroyed() -> void:
	_log("[battle] 全部炮塔被毁 → 启动终局演出（L3）")
	if _collapse != null:
		_collapse.start_l3()
		return
	# 兜底：无编排器（例如某些轻量测试场景）时，保持旧行为直接切 RESULT。
	GameStateManager.change_state(GameStateManager.State.RESULT)
	_refresh_hud()


## 接管某门炮 → 把主视角搬到该炮位（DEC-038）。
## **主炮（fore）不搬**：玩家留在主控室通过艏部舷窗打正面（DEC-026 + DEC-030），
## 搬出去反而看不见舷窗、也丢掉「信息不对称」的体验前提。
func _on_takeover_started(turret_id: StringName) -> void:
	if _turret_system == null or _player == null:
		return
	var t: Turret = _turret_system.get_turret(turret_id)
	if t == null or t.sector == &"fore":
		return
	# 已在外视角时再接管另一门炮：不要覆盖掉「主控室原始视角」，直接改落点即可
	if not _takeover_view:
		_bridge_pos = _player.position
		_bridge_yaw = _yaw
		_bridge_pitch = _pitch
		_takeover_view = true
	_player.position = t.muzzle_pos
	_aim_outward(t.muzzle_pos)
	if DEBUG_LOG:
		print("[takeover] 主视角 -> %s 炮位 %s（扇区 %s）" % [turret_id, str(t.muzzle_pos), t.sector])


## 释放接管 → 主视角搬回主控室，朝向还原到接管前。
func _on_takeover_ended(_turret_id: StringName) -> void:
	if not _takeover_view:
		return
	_takeover_view = false
	_player.position = _bridge_pos
	_yaw = _bridge_yaw
	_pitch = _bridge_pitch
	_player.rotation.y = _yaw
	_camera.rotation.x = _pitch
	if DEBUG_LOG:
		print("[takeover] 主视角 <- 回主控室 %s" % str(_bridge_pos))


## 把视角朝向「远离船中心」的方向 —— 副炮装在舰体外表面，朝外才看得见来袭敌人。
##
## 推导（Godot 节点默认朝 **-Z**）：
##   绕 Y 轴转 θ 后，朝向 = (-sinθ, 0, -cosθ) → 要等于 out 的水平分量，
##   故 θ = atan2(-out.x, -out.z)。验证：out=+Z 时 θ=π，与 _yaw 初值 PI 一致。
##   绕 X 轴转 φ 后，朝向的 y 分量 = sin(φ) → φ = asin(out.y)。
## pitch 仍受 pitch_limit 约束：dorsal/ventral 会得到 ±limit 而非 ±90°，
## 差的那 10° 玩家一动鼠标就补上了，不值得为它破例放宽限制。
func _aim_outward(muzzle: Vector3) -> void:
	var out_dir := muzzle.normalized()
	if out_dir.length_squared() < 1e-6:
		out_dir = Vector3(0, 0, 1)
	_yaw = atan2(-out_dir.x, -out_dir.z)
	var lim := deg_to_rad(_pitch_limit)
	_pitch = clampf(asin(clampf(out_dir.y, -1.0, 1.0)), -lim, lim)
	_player.rotation.y = _yaw
	_camera.rotation.x = _pitch


## 建 LeadPrediction 标记（绿色十字 BoxMesh）。
## 接管 MANUAL 时 _update_lead_marker 每帧改位置 → 不接管时 visible=false。
func _build_lead_marker() -> void:
	var mi := MeshInstance3D.new()
	mi.name = "LeadMarker"
	var box := BoxMesh.new()
	box.size = LEAD_MARK_SIZE
	mi.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.4, 1.0, 0.4)
	mat.emission_enabled = true
	mat.emission = Color(0.4, 1.0, 0.4)
	mi.material_override = mat
	mi.visible = false
	add_child(mi)
	_lead_marker = mi


## 手动接管时实时算拦截点并把 marker 摆到那里。未接管 / 未找到目标时隐藏。
## 拦截点算法与 Turret._on_turret_fired 一致（LeadPrediction.intercept_point），复算每帧以
## 跟随玩家视角与敌人轨迹；不与子弹发射耦合，避免影响发射逻辑。
func _update_lead_marker(_delta: float) -> void:
	if _lead_marker == null:
		return
	if _turret_system == null or _turret_system.current_manual_id == &"":
		_lead_marker.visible = false
		return
	# 找当前手动炮塔 → 算 muzzle_pos
	var t: Turret = _turret_system.get_turret(_turret_system.current_manual_id)
	if t == null:
		_lead_marker.visible = false
		return
	var target := t.acquire_target()
	if target == null:
		_lead_marker.visible = false
		return
	var v_e: Vector3 = Vector3.ZERO
	if not target.is_hovering():
		var center := Vector3(0, 1.5, -1.3)
		v_e = (center - target.global_position).normalized() * target.speed
	var intercept := LeadPrediction.intercept_point(t.muzzle_pos, target.global_position,
		v_e, t.projectile_speed)
	if intercept.length_squared() < 1e-6:
		_lead_marker.visible = false
		return
	_lead_marker.global_position = intercept
	_lead_marker.visible = true


# ── 数据读取 ────────────────────────────────────────────
# JSON.parse_string() 返回 Variant，可能是 Dictionary / Array / null / 解析失败。
# 一律先 `is Dictionary` 判断再转型，绝不直接 `as` 强转（null 强转不报错但会
# 变成"空字典"，导致后面所有配置项静默走兜底值，极难排查 —— 这是本项目的踩坑之一）。
func _load_data() -> void:
	_data = _load_json_dict(DATA_PATH, "presentation.json")
	# 敌人参数住在 enemies.json，但本脚本（及将来的业务系统）统一用
	# `_num("enemy", ...)` 取值 —— 所以在这里把它并进 _data，
	# 让调用方不必知道这段配置来自哪个文件。缺文件时 _num 自然走兜底值。
	var ed := _load_json_dict(ENEMY_DATA_PATH, "enemies.json")
	if ed.has("enemy") and (ed["enemy"] is Dictionary):
		_data["enemy"] = ed["enemy"]


## 把一个 JSON 文件读成 Dictionary。
## 文件不存在 / 打不开 / 解析失败 → 告警并返回**空字典**（不是 null），
## 这样调用方能统一用 `has()` 判断，不必到处判空。
func _load_json_dict(path: String, label: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("找不到 %s，相关配置回退默认值" % path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("无法打开 %s，相关配置回退默认值" % path)
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		push_warning("%s 解析失败，相关配置回退默认值" % label)
		return {}
	return parsed as Dictionary


## 读取 presentation.json 中的数值：_num("monitor", "feed_width", 320.0)
## section/key 任一缺失、类型不对、或 _data 还没加载成功 → 返回 fallback。
## 所有配置读取都走这里，保证"JSON 缺项 = 用兜底值"，不会崩。
func _num(section: String, key: String, fallback: float) -> float:
	if not _data.has(section) or not (_data[section] is Dictionary):
		return fallback
	var d := _data[section] as Dictionary
	if not d.has(key):
		return fallback
	return float(d[key])


# ── 星空（纯装饰）───────────────────────────────────────
# 代码生成而非进 .tscn，是因为它只有一个球壳 + 一个 shader，放进场景反而难找；
# 尺度/密度等数值直接写在 STAR_SHADER 的 uniform 默认值里 —— 星空不参与任何玩法
# 判定，属于文件头列出的「例外①」，故不上浮到 presentation.json。
# （符合 05 课白盒精神：docs/开发指导/知识库-阶段一-01-05.md）
func _build_starfield() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = 700.0
	sphere.height = 1400.0
	sphere.radial_segments = 48
	sphere.rings = 24
	var shader := Shader.new()
	shader.code = STAR_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = shader
	var mi := MeshInstance3D.new()
	mi.name = "Starfield"
	mi.mesh = sphere
	mi.material_override = mat
	add_child(mi)


# ── 尺度自检四步 ────────────────────────────────────────
# 出处：docs/bible/04_presentation.md §八「旋钮表」下的「尺度自检（改任何一个
# 尺度参数后，跑一遍这四条）」。这四条是"为什么是这些数"的可执行版本 ——
# 改了 JSON 里任何尺度参数，跑一下看是否还 OK，比凭感觉调快得多。
# 阈值（100-120° / ≥8s / ≥15px / ≈4.0m）直接来自该文档，故不另外外置。
func _selfcheck_lines() -> Array:
	var win_w := _num("bridge", "viewport_width", 4.4)
	var glass_d := _num("bridge", "console_distance", 1.7)
	var D := _num("bridge", "depth", 6.0)
	var fov := _num("camera", "fov", 70.0)
	var spawn_r := _num("enemy", "spawn_radius", 190.0)
	var atk_r := _num("enemy", "attack_range", 52.0)
	var spd_i := _num("enemy", "speed_interceptor", 17.0)
	var size_i := _num("enemy", "size_interceptor", 6.0)

	var fov_win: float = rad_to_deg(2.0 * atan(win_w * 0.5 / maxf(glass_d, 0.01)))
	var window_s: float = (spawn_r - atk_r) / maxf(spd_i, 0.01)
	var ang: float = 2.0 * atan(size_i * 0.5 / maxf(spawn_r, 0.01))
	var px: float = ang / maxf(deg_to_rad(fov), 0.0001) * 1080.0
	var back: float = D - glass_d
	var back_delta: float = absf(back - 4.0)

	var lines: Array = []
	lines.append("① 舷窗视野全角  %.1f°   (目标 100-120°)  %s" % [fov_win, _ok(fov_win >= 100.0 and fov_win <= 120.0)])
	lines.append("② 威胁窗口(最快敌) %.1fs  (目标 ≥8s)    %s" % [window_s, _ok(window_s >= 8.0)])
	lines.append("③ 进场可见度(小型) %.1fpx @1080p (目标 ≥15px) %s" % [px, _ok(px >= 15.0)])
	lines.append("④ 背后空间       %.2fm  (目标 ≈4.0m)   %s" % [back, _ok(back_delta <= 0.6)])
	return lines


func _ok(cond: bool) -> String:
	return "OK" if cond else "!! 超出"


func _refresh_hud() -> void:
	if _hud == null:
		return
	# ⑦ 过场期间接管 HUD 的操作提示：此时 B / 1-5 / E / R 全被吞掉了，
	# 不换提示语玩家会以为按键坏了。
	if _refit_seq != null and _refit_seq.is_playing():
		_hud.text = "FPS %d\n★ 维修站 · %s\n数字键选择 · Enter 出发 · Esc 返回/跳过 · 任意键快进\n" % [
			_fps, _refit_seq.phase_name()]
		return
	var txt := "FPS %d\n" % _fps
	txt += "阶段 %s   （B 开战/收战）\n" % _state
	# ⑨ 波次进度。**剩余敌人数只在 BATTLE 显示** —— REFIT 时上一波已清场，
	# 显示"剩余 0/4"会让人以为下一波已经打完了。
	if _wave_system != null:
		txt += "危机 %d（已撑过 %d）" % [
			maxi(_wave_system.wave_index, 1), _wave_system.crisis_cleared]
		if _state == &"BATTLE":
			txt += "   本波剩余 %d / %d" % [_wave_system.remaining(), _wave_system.total()]
		txt += "\n"
	for l in _selfcheck_lines():
		txt += l + "\n"
	if _turret_system != null:
		# ⑧ 装配进度：白盒阶段这是判断「我离下一个解锁还有多远」的唯一依据 ——
		# 没有进度条、没有解锁弹窗，全靠这行小字给期待感。
		txt += "\n装配: 槽位 %d/%d · 型号 %d/%d（已撑过 %d 次危机）" % [
			_turret_system.swappable_ids().size(), _turret_system.all_slot_ids().size(),
			_turret_system.unlocked_variant_ids().size(), _turret_system.variant_ids().size(),
			_turret_system.cleared_count()]
		# ⑤ 炮塔耐久：**手玩时判断 ⑤ 是否生效的唯一直接反馈**，比翻 Output 快。
		# 被毁的显示"已毁"而不是"0/80"，是为了让"这门没了"和"这门快没了"一眼可分。
		txt += "\n炮塔耐久（存活 %d/%d）:" % [_turret_system.alive_count(),
			_turret_system.all_turrets().size()]
		# ⑨a 战损（**DEC-043 出口 ①**）：本波承伤**直接标在耐久后面**，不另起一段 ——
		# 「还剩多少血」和「这波掉了多少」是同一个判断的两半，分两处看要来回对。
		# 阈值 0.5 是为了躲开"刚挨了一帧 dps"这种噪声，否则屏上会飘一片 -0。
		var dl := _turret_system.damage_log()
		for t in _turret_system.all_turrets():
			var bar := "已毁" if t.destroyed else "%3.0f / %3.0f" % [t.hp, t.hp_max]
			var dmg := ""
			if dl != null:
				var taken := dl.taken(t.turret_id)
				if taken > 0.5:
					dmg = "   本波 -%.0f" % taken
			txt += "\n  %-10s %s%s" % [str(t.turret_id), bar, dmg]
	# ⑨b 陷落状态：L1/L2 已打到对应 feed 上，但 HUD 也列一行文字 ——
	# 白盒阶段 4 块屏挤在一起、眼睛跟不上时，这行字是唯一能「数得清」的地方。
	if _collapse != null:
		var ann: String = _collapse.announce_text()
		if ann != "":
			txt += "\n▌ %s\n" % ann
		var line := ""
		var tags := {&"port": "左", &"starboard": "右", &"dorsal": "上", &"ventral": "下"}
		for s in [&"port", &"starboard", &"dorsal", &"ventral"]:
			var st: int = _collapse.sector_state(s)
			var tag: String = str(tags.get(s, "?"))
			var mark := "好"
			if st == CollapseSequence.SectorState.DEGRADED:
				mark = "损"
			elif st == CollapseSequence.SectorState.BREACHED:
				mark = "失守"
			line += "%s:%s  " % [tag, mark]
		txt += "\n各面  " + line
	if _state == &"RESULT":
		txt += "\n★ 全部炮塔被毁 —— 按 B 回 REFIT 再来一次"
	txt += "\n鼠标转头 (yaw 360° / pitch ±%.0f°) · ESC 释放鼠标 · 再按 ESC 退出" % _pitch_limit
	txt += "\n1 主炮 · 2-5 接管某路(左/右/上/下)，再按同键换该路另一门炮 · Space 或左键 开火 · E/R 生成敌人 · F 可见性诊断"
	if _turret_system != null and _turret_system.current_manual_id != &"":
		txt += "\n★ 接管中: %s（再按同键换该路下一门 / ESC 回主控室）" % _turret_system.current_manual_id
	_hud.text = txt


func _report_selfcheck() -> void:
	_log("=== 白盒主控室 · 尺度自检 ===")
	for l in _selfcheck_lines():
		_log("  " + str(l))
	_log("===========================")
