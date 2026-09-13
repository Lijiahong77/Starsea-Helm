extends Node3D

## 第③步「六扇区 + 敌人」的独立验证场景。
## 依据协作约定第 4 条：复杂功能先建独立测试场景跑通，再搬进主场景。
##
## 验证八件事：
## ① 六扇区归属判定正确（六个轴向的点各归各面，且带船中心偏移时依然正确）
## ② `aft` 权重为 0 → 随机生成永远不会落在 aft（DEC-036 推进器高温区）
## ③ **hold** 飞行：直线飞向船，进入 attack_range 后停住悬停
## ④ 压力随敌人数变化并广播（③ 阶段公式 = 威胁数 / pressure_reference_count）
## ⑤ 飞行方式被正确注入 + 进场段速度采样（DEC-049）
## ⑥ **orbit** 绕飞：一直在动，但半径守恒在 attack_range 上、速度是切向
## ⑦ **strike_retreat** 巡航：反复来回进出攻击圈、掠过不撞船心
## ⑧ 各型号数值互不串（DEC-049 回归护栏：heavy 不该拿到拦截机的数）
##
## ⚠ 本场景依赖 EventBus autoload，只能在**完整主场景运行路径**下跑
## （`--script` 模式不实例化 autoload）。验证时把 main_scene 临时切到这里。

const DATA_PATH := "res://data/enemies.json"

var _pass := 0
var _fail := 0


func _ready() -> void:
	# 等一帧，确保子节点的 _ready（EnemySystem 读配置）已经跑完。
	await get_tree().process_frame
	var sys := $EnemySystem as EnemySystem

	print("=== ③ 六扇区 + 敌人 · 独立验证 ===")
	_test_sector_mapping()
	_test_aft_excluded(sys)
	_test_movement(sys)
	_test_flight_field(sys)
	_test_orbit(sys)
	_test_strike_retreat(sys)
	_test_type_stats_isolated(sys)
	await _test_pressure(sys)
	print("=== 结果：通过 %d / 失败 %d ===" % [_pass, _fail])
	if _fail > 0:
		push_error("存在失败的断言，见上方 NG 行")


## ① 六扇区归属判定。
func _test_sector_mapping() -> void:
	# 纯轴向（船中心在原点）
	var axial := {
		&"fore": Vector3(0, 0, 100),
		&"aft": Vector3(0, 0, -100),
		&"port": Vector3(-100, 0, 0),
		&"starboard": Vector3(100, 0, 0),
		&"dorsal": Vector3(0, 100, 0),
		&"ventral": Vector3(0, -100, 0),
	}
	for want in axial:
		_check("归属·纯轴向 %s" % want, Sectors.sector_of(axial[want], Vector3.ZERO) == want)

	# 带船中心偏移（白盒实际值 ship_center=(0,1.5,-1.3)）
	var c := Vector3(0, 1.5, -1.3)
	_check("归属·带船中心偏移 fore", Sectors.sector_of(Vector3(0, 1.5, 88.7), c) == &"fore")
	_check("归属·带船中心偏移 ventral", Sectors.sector_of(Vector3(0, -8.5, -1.3), c) == &"ventral")


## ② aft 必须从随机生成中排除。
func _test_aft_excluded(sys: EnemySystem) -> void:
	var counts := {}
	for _i in 60:
		var e := sys.spawn_one(&"interceptor")
		counts[e.sector] = int(counts.get(e.sector, 0)) + 1
		e.queue_free()
	var aft_count: int = int(counts.get(&"aft", 0))
	_check("aft 随机生成数为 0（DEC-036）", aft_count == 0)
	_check("随机生成覆盖了多个扇区（%d 面）" % counts.size(), counts.size() >= 3)
	print("   随机分布: %s" % str(counts))


## ③ 移动与悬停（**hold 飞行**）。用手动 advance() 推进而不是等真实帧 —— 快且确定。
##
## ⚠ DEC-049：显式钉 `hold`。拦截机默认已改成绕飞，「直线飞进 → 停住」是 hold 的定义，
## 不是拦截机的定义了。想让本用例验什么就钉什么，别让它随 JSON 漂移。
func _test_movement(sys: EnemySystem) -> void:
	var cfg := _read_cfg()
	var center: Vector3 = cfg["center"]
	var spawn_r: float = cfg["spawn_radius"]
	var atk_r: float = cfg["attack_range"]

	var e := sys.spawn_one(&"interceptor", &"fore", &"hold")
	var d0 := e.global_position.distance_to(center)
	_check("生成距离 ≈ spawn_radius(%.0f)" % spawn_r, absf(d0 - spawn_r) < 1.0)
	_check("生成时扇区 == fore", e.sector == &"fore")

	# 手动推进 12 秒（足够跑完 190→52 的 8.1 秒行程）
	for _i in 720:
		e.advance(1.0 / 60.0)
	var d1 := e.global_position.distance_to(center)

	_check("推进后进入悬停（hold）", e.is_hovering())
	_check("推进后 is_engaged（可被锁定）", e.is_engaged())
	_check("悬停距离 ≈ attack_range(%.0f)" % atk_r, absf(d1 - atk_r) < 1.0)
	print("   行程: %.1fm → %.1fm（attack_range=%.0f）" % [d0, d1, atk_r])
	e.queue_free()


## ⑤ 飞行方式注入 + 进场段速度采样（DEC-049）。
##
## 断言的是「数据怎么流」而不是「飞得好不好看」：
##   · `flight_<type>` 被 EnemySystem 读到并交给 Enemy（否则分发器永远走默认分支）
##   · **三种飞行在"进场段"共用同一条直线**，且 `velocity()` 指向 `flight_target()`、
##     模长 ≈ speed —— 这是 `advance()` 速度采样的地基，错了后面全歪
func _test_flight_field(sys: EnemySystem) -> void:
	var cfg := _read_cfg()

	for tid in [&"interceptor", &"bomber", &"heavy"]:
		var e := sys.spawn_one(tid, &"fore")
		var want := StringName(String(cfg.get("flight_%s" % tid, "hold")))
		_check("%s 飞行方式注入 = %s" % [tid, want], e.flight_mode() == want)
		_check("%s 生成时未交战" % tid, not e.is_engaged())
		e.queue_free()

	# 速度采样：飞 1 秒后应有非零速度，方向指向它当前在飞的那个点。
	# 用 `flight_target()` 而不是"船心"—— 巡航型的进场目标是**通过点**，不是船心。
	var m := sys.spawn_one(&"interceptor", &"fore")
	var p0 := m.global_position
	for _i in 60:
		m.advance(1.0 / 60.0)
	var v := m.velocity()
	_check("进场中 velocity() 非零", v.length() > 0.1)
	var to_aim: Vector3 = (m.flight_target() - m.global_position).normalized()
	_check("进场中速度方向指向 flight_target（dot≈1）", v.normalized().dot(to_aim) > 0.999)
	_check("速度模长 ≈ speed(%.0f)" % cfg["speed_interceptor"],
		absf(v.length() - float(cfg["speed_interceptor"])) < 0.5)
	print("   1s 位移 %.1fm（speed=%.0f），velocity=%.2f m/s" % [
		p0.distance_to(m.global_position), cfg["speed_interceptor"], v.length()])
	m.queue_free()


## ⑥ 绕飞（orbit）：进攻击距离后**一直在动，但始终待在 attack_range 那个圈上**。
##
## 「半径守恒」是本用例的核心断言 —— 它同时证明了两件事：
##   ① 绕飞没有偷偷改「离船多远」（威胁窗口与 hold 相同，李要的正是这个）；
##   ② 轨迹真的是一段圆弧，不是随机抖动。
func _test_orbit(sys: EnemySystem) -> void:
	var cfg := _read_cfg()
	var center: Vector3 = cfg["center"]
	var atk_r: float = cfg["attack_range"]

	var e := sys.spawn_one(&"interceptor", &"fore")
	for _i in 1200:
		e.advance(1.0 / 60.0)
	_check("绕飞中仍处于交战（自动炮锁得住）", e.is_engaged())

	var p0 := e.global_position
	var d0 := p0.distance_to(center)
	for _i in 120:
		e.advance(1.0 / 60.0)
	var moved := p0.distance_to(e.global_position)
	var d1 := e.global_position.distance_to(center)

	_check("绕飞时位置在变（2 秒位移 %.1fm）" % moved, moved > 5.0)
	_check("绕飞**半径守恒**：2 秒前后都在 attack_range(%.0f) 上（%.2f / %.2f）" % [
		atk_r, d0, d1], absf(d0 - atk_r) < 1.0 and absf(d1 - atk_r) < 1.0)
	_check("绕飞时不静止（is_hovering 必须为 false）", not e.is_hovering())

	var v := e.velocity()
	var radial := (e.global_position - center).normalized()
	var along := absf(v.normalized().dot(radial))
	_check("绕飞速度是**切向**（与径向垂直，|dot| 实测 %.4f < 0.05）" % along, along < 0.05)
	print("   绕飞 2 秒位移 %.1fm，半径 %.1f→%.1f（attack_range=%.0f）" % [
		moved, d0, d1, atk_r])
	e.queue_free()


## ⑦ 巡航（strike_retreat）：**反复来回进攻**，不是"打完就逃"。
##
## 李 2026-09-11 纠正：「它们都是会来回进攻的，飞来飞去的进攻，不是说逃跑了」。
## 所以本用例断言的是**循环**：至少进入攻击圈 2 次、离开 ≥1 次，且中途确实飞远过。
## 顺带钉住「掠过时不撞进船心」（通过点偏移 `pass_distance`）——
## 少了这条，航线会变成直线穿过舰桥。
func _test_strike_retreat(sys: EnemySystem) -> void:
	var cfg := _read_cfg()
	var center: Vector3 = cfg["center"]
	var retreat_r: float = cfg["retreat_range"]
	var pass_d: float = cfg["pass_distance"]

	var e := sys.spawn_one(&"bomber", &"fore")
	var entries := 0
	var exits := 0
	var farthest := 0.0
	var closest := INF
	var was := false
	for _i in 6000:   # 100 秒，够跑 2 趟以上（单趟 ≈ 27 s + 回旋 ≈ 11 s）
		e.advance(1.0 / 60.0)
		var d := e.global_position.distance_to(center)
		farthest = maxf(farthest, d)
		closest = minf(closest, d)
		if e.is_engaged() and not was:
			entries += 1
		elif not e.is_engaged() and was:
			exits += 1
		was = e.is_engaged()

	_check("会进入攻击圈（%d 次）" % entries, entries >= 1)
	_check("**来回进攻**：进入 ≥2 次且离开 ≥1 次（实测 %d/%d）" % [entries, exits],
		entries >= 2 and exits >= 1)
	_check("确实飞远过：最远 %.1fm ≥ retreat_range(%.0f)" % [farthest, retreat_r],
		farthest >= retreat_r - 1.0)
	_check("掠过**不撞船心**：最近 %.1fm ≈ pass_distance(%.0f)" % [closest, pass_d],
		closest >= pass_d - 6.0)
	_check("巡航型不静止（is_hovering 恒为 false）", not e.is_hovering())
	print("   巡航 100 s：进入 %d / 离开 %d，最近 %.1fm / 最远 %.1fm" % [
		entries, exits, closest, farthest])
	e.queue_free()


## ⑥ 各型号数值互不串（DEC-049 回归护栏）。
##
## **为什么专门写这条**：`_stats_for` 曾经把类型塌陷成两档
## （`"bomber" if type_id == &"bomber" else "interceptor"`），heavy 于是静默
## 拿到拦截机的 speed/hp/size/dps —— 不报错、表现只是「重甲跑得跟战机一样快」。
## 现在按 type_id 直拼后缀，本用例把「不同型号 = 不同数」钉死：
## 只要有人再把后缀写死成某一档，这里立刻红。
## 断言值从 JSON 现读（见 `_read_cfg`），所以改数值不会误伤本用例。
func _test_type_stats_isolated(sys: EnemySystem) -> void:
	var cfg := _read_cfg()
	var heavy := sys.spawn_one(&"heavy", &"fore")
	_check("heavy 速度 = speed_heavy(%.0f) 而非拦截机的 %.0f" % [
		cfg["speed_heavy"], cfg["speed_interceptor"]],
		is_equal_approx(heavy.speed, float(cfg["speed_heavy"])))
	_check("heavy dps = dps_heavy(%.0f) 而非拦截机的 %.0f" % [
		cfg["dps_heavy"], cfg["dps_interceptor"]],
		is_equal_approx(heavy.dps, float(cfg["dps_heavy"])))
	heavy.queue_free()

	var inter := sys.spawn_one(&"interceptor", &"fore")
	_check("interceptor 速度 = speed_interceptor(%.0f)" % cfg["speed_interceptor"],
		is_equal_approx(inter.speed, float(cfg["speed_interceptor"])))
	_check("interceptor dps = dps_interceptor(%.0f)" % cfg["dps_interceptor"],
		is_equal_approx(inter.dps, float(cfg["dps_interceptor"])))
	inter.queue_free()


## ④ 压力随敌人数变化（需要真实帧，因为压力更新是节流的）。
func _test_pressure(sys: EnemySystem) -> void:
	var cfg := _read_cfg()
	var ref_n: float = cfg["pressure_reference_count"]

	# 清掉上一个用例残留（queue_free 要等一帧才生效）
	await get_tree().process_frame
	for i in 3:
		sys.spawn_one(&"bomber", &"port")
	await get_tree().create_timer(0.6).timeout  # 压力间隔 0.25s，等两轮

	var got: float = float(sys.pressures().get(&"port", -1.0))
	var want := Sectors.pressure_from_count(3, ref_n)
	_check("port 压力 = 3/%.0f" % ref_n, absf(got - want) < 0.002)
	print("   port 压力: %.3f（期望 %.3f）" % [got, want])


# ── 工具 ────────────────────────────────────────────

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("   OK  %s" % label)
	else:
		_fail += 1
		print("   NG  %s" % label)


## 独立读一次 enemies.json —— 刻意不复用 EnemySystem 里已解析的值，
## 这样测试断言的是「配置文件里写的数」，被测代码自己读错才会失败。
##
## **新增断言要用到的键，只需加进 `defaults`** —— 下面按表逐个覆盖，
## 不写成一长串 `if e.has(...)`。理由：那种写法加一个键要改三处（表 / if / 兜底），
## 漏一处会**静默用兜底值**通过断言，等于护栏自己先断了。
## 表里的值只在 JSON 缺键时才生效（兜底），平时不参与断言。
func _read_cfg() -> Dictionary:
	var defaults := {
		"center": Vector3(0, 1.5, -1.3),
		"spawn_radius": 190.0,
		"attack_range": 52.0,
		"pressure_reference_count": 6.0,
		"speed_interceptor": 17.0,
		"speed_heavy": 8.0,
		"dps_interceptor": 3.0,
		"dps_heavy": 12.0,
		"flight_interceptor": "hold",
		"flight_bomber": "hold",
		"flight_heavy": "hold",
		# DEC-049 Phase 1：巡航（strike_retreat）的两个几何旋钮。
		"pass_distance": 30.0,
		"retreat_range": 120.0,
	}
	var out: Dictionary = defaults.duplicate()
	if not FileAccess.file_exists(DATA_PATH):
		push_warning("测试读不到 %s，用硬编码期望值" % DATA_PATH)
		return out
	var f := FileAccess.open(DATA_PATH, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return out
	var root := parsed as Dictionary
	if not root.has("enemy") or not (root["enemy"] is Dictionary):
		return out
	var e := root["enemy"] as Dictionary
	for key in defaults:
		if key == "center":
			if e.has("ship_center") and (e["ship_center"] is Array):
				var a: Array = e["ship_center"]
				if a.size() >= 3:
					out["center"] = Vector3(float(a[0]), float(a[1]), float(a[2]))
			continue
		if not e.has(key):
			continue
		# 字符串键（flight_*）原样取，其余按数值取 —— 类型错了会在这里当场炸，
		# 比事后拿一个 NaN 去比断言好查得多。
		if defaults[key] is String:
			out[key] = String(e[key])
		else:
			out[key] = float(e[key])
	return out
