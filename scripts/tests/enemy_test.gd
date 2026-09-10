extends Node3D

## 第③步「六扇区 + 敌人」的独立验证场景。
## 依据协作约定第 4 条：复杂功能先建独立测试场景跑通，再搬进主场景。
##
## 验证四件事：
## ① 六扇区归属判定正确（六个轴向的点各归各面，且带船中心偏移时依然正确）
## ② `aft` 权重为 0 → 随机生成永远不会落在 aft（DEC-036 推进器高温区）
## ③ 敌人直线飞向船，进入 attack_range 后停住悬停
## ④ 压力随敌人数变化并广播（③ 阶段公式 = 威胁数 / pressure_reference_count）
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


## ③ 移动与悬停。用手动 advance() 推进而不是等真实帧 —— 快且确定。
func _test_movement(sys: EnemySystem) -> void:
	var cfg := _read_cfg()
	var center: Vector3 = cfg["center"]
	var spawn_r: float = cfg["spawn_radius"]
	var atk_r: float = cfg["attack_range"]

	var e := sys.spawn_one(&"interceptor", &"fore")
	var d0 := e.global_position.distance_to(center)
	_check("生成距离 ≈ spawn_radius(%.0f)" % spawn_r, absf(d0 - spawn_r) < 1.0)
	_check("生成时扇区 == fore", e.sector == &"fore")

	# 手动推进 12 秒（足够跑完 190→52 的 8.1 秒行程）
	for _i in 720:
		e.advance(1.0 / 60.0)
	var d1 := e.global_position.distance_to(center)

	_check("推进后进入悬停", e.is_hovering())
	_check("悬停距离 ≈ attack_range(%.0f)" % atk_r, absf(d1 - atk_r) < 1.0)
	print("   行程: %.1fm → %.1fm（attack_range=%.0f）" % [d0, d1, atk_r])
	e.queue_free()


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
func _read_cfg() -> Dictionary:
	var out := {
		"center": Vector3(0, 1.5, -1.3),
		"spawn_radius": 190.0,
		"attack_range": 52.0,
		"pressure_reference_count": 6.0,
	}
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
	if e.has("ship_center") and (e["ship_center"] is Array):
		var a: Array = e["ship_center"]
		out["center"] = Vector3(float(a[0]), float(a[1]), float(a[2]))
	if e.has("spawn_radius"):
		out["spawn_radius"] = float(e["spawn_radius"])
	if e.has("attack_range"):
		out["attack_range"] = float(e["attack_range"])
	if e.has("pressure_reference_count"):
		out["pressure_reference_count"] = float(e["pressure_reference_count"])
	return out
