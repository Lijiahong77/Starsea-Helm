extends Node3D
class_name Projectile

## 离散飞行弹丸（DEC-034 · 9/1 修订）
##
## 主炮副炮皆发离散弹丸（非光束 / 非瞬时扣血）。本类负责：
##   ① 沿 direction 直线推进（速度 = projectile_speed）
##   ② 寿命衰减，超 max_lifetime 自动 queue_free
##   ③ 命中检测：AABB 球（半径 = 敌人 size/2 + 自身 0.3）
##   ④ 命中后调 enemy.take_damage(damage, owner_turret_id) → queue_free
##
## **由 Turret 基类 spawn**，不是自己挂进树。弹丸自己 collide 检测，
## 不走 CollisionShape3D / Area3D —— 物理引擎开销大且白盒阶段不要 Area 信号噪声。
## 命中检测用每帧 `_test_hit()`：遍历 group「enemies」做球-线段测试（不是遍历
## EnemySystem 的子节点 —— 那样会把弹丸和场景树结构绑死，见 _test_hit 注释）。
## 当前满编 20 个敌人线性遍历 O(N) 可接受；大量敌人才考虑空间索引。
##
## **不在 _physics_process**，而由 ProjectileManager / TurretSystem 统一调 advance(delta) ——
## 这样跟敌人推进一个套路（enemy_system.gd 注释：少 N 次回调）。
## 但**本类自带 _physics_process 兜底**：万一被独立 add_child（测试场景 / 子弹撞墙）
## 也能正常动，不至于停在原地。
##
## **不在 .tscn / _init 拉任何参数**：参数由 spawn(owner, origin, dir, ...) 传入，
## 不写默认值，配置全在 data/turrets.json。
##

# 【日志纪律 2026-09-05】白盒验收完后改 false；想看弹丸失效改 true。
const DEBUG_LOG := false
## 视觉：白盒 BoxMesh 0.4×0.4×0.8（enemies.json 区间），沿飞行方向拉长；
## 子弹无尾迹（trail 是 VFX · P1）。命中死亡不画爆炸（P1）。

const HIT_RADIUS_BULLET := 0.3   # 自身碰撞半径（与敌人 size 叠加 = 真实命中范围）
const HIT_PAD_ENEMY := 0.5       # 敌人中心 + 这层壳 = 偏大判定（容错高速弹丸穿模）

## 敌人所在 group。Enemy.setup() 里 add_to_group 同一个名字（两处必须一致，
## 改这里就要改 enemy.gd —— 这是本项目里少数「靠约定而非类型」的耦合点）。
const ENEMY_GROUP := &"enemies"

var _origin_pos := Vector3.ZERO
var _direction := Vector3.FORWARD
## 上一帧位置。命中检测用它和当前位置连成**线段**做检测（见 _test_hit）。
var _prev_pos := Vector3.ZERO
var _speed := 200.0
var _damage := 1.0
var _owner_turret_id: StringName = &""
var _max_lifetime := 4.0
var _max_range := 130.0
var _alive := true

## 由 Turret 调用：写入飞行参数；不 add_child（Turret 自己 add_child）。
## 调用顺序：t.spawn_p(this); add_child(this); this.setup(...)。也可以 setup + add_child 一起。
func setup(p_direction: Vector3, p_speed: float, p_damage: float,
		p_owner: StringName, p_max_lifetime: float, p_max_range: float) -> void:
	_direction = p_direction.normalized() if p_direction.length_squared() > 1e-6 else Vector3.FORWARD
	_speed = p_speed
	_damage = p_damage
	_owner_turret_id = p_owner
	_max_lifetime = p_max_lifetime
	_max_range = p_max_range
	# 射程以**炮口**为原点，不是世界原点。
	# ⚠ 2026-09-06 修复：本行原先漏了 —— _origin_pos 一直停在 (0,0,0)，
	#   于是副炮（炮位在 x=±11.5 / y=±8.5）的射程被多算/少算了一个船体半径，
	#   且朝船心方向飞的弹丸射程判定完全失真。
	_origin_pos = global_position
	_prev_pos = global_position
	# 朝向：弹丸长 0.8 沿 +Z 拉伸，所以模型 +Z 朝飞行方向 = look_at(direction)。
	look_at(global_position + _direction, Vector3.UP)
	_build_visual()


## 由 TurretSystem 在 _physics_process 中对所有 Projectile 调用：推进 + 命中检测 + 寿命。
## 返回 false 表示本弹丸已死（命中或超寿命），调用方应从活跃列表移除。
func advance(delta: float) -> bool:
	if not _alive:
		return false
	# 推进
	_prev_pos = global_position
	global_position += _direction * _speed * delta
	# 寿命
	_max_lifetime -= delta
	if _max_lifetime <= 0.0:
		_die(&"lifetime")
		return false
	# 射程：超出 owner 射程上限就当打飞，self-destruct（防止远处子弹乱飞）
	if global_position.distance_to(_origin_pos) > _max_range:
		_die(&"range")
		return false
	# 命中
	if _test_hit():
		return false
	return true


## 独立测试场景用：add_child 后靠 _physics_process 自动飞（兜底）。
## 正常游戏流程下 advance() 由 TurretSystem 调用，_physics_process 是空转。
func _physics_process(delta: float) -> void:
	if _alive:
		advance(delta)


## 命中检测：遍历 group「enemies」，对每段飞行**线段**做球-线段测试。
## 判定：dist(敌人中心, 本帧飞行线段) < 敌人 size/2 + HIT_PAD_ENEMY + HIT_RADIUS_BULLET。
## 命中后 take_damage + _die(hit)，TurretSystem 收到 false 后从列表移除。
##
## ⚠ 两个 2026-09-06 修复（都是 Round 2 副炮接入时才暴露的）：
##   ① **线段检测取代点检测**：副炮弹速 300 m/s，一帧（1/60s）走 5 m，
##      而命中半径只有 ~3.8 m —— 只判「弹丸当前点 vs 敌人」会整发穿过去（隧道效应），
##      表现是「炮在响、血不掉」。改为判「上一帧位置 → 当前位置」这一段线段。
##   ② **用 group 取代硬编码路径**：原实现 get_node("Bridge/EnemySystem")，
##      一旦主场景改名或本弹丸跑在独立测试场景里，查找静默返回 null →
##      永远打不中任何东西，且没有任何报错。group 与场景结构解耦。
func _test_hit() -> bool:
	if not _alive:
		return false
	var nodes := get_tree().get_nodes_in_group(ENEMY_GROUP)
	for node in nodes:
		var e := node as Enemy
		if e == null or e.is_dead():
			continue
		var half: float = e.size * 0.5 + HIT_PAD_ENEMY + HIT_RADIUS_BULLET
		if _dist_to_segment(e.global_position, _prev_pos, global_position) < half:
			e.take_damage(_damage, _owner_turret_id)
			# ⑩ 命中音：高频（一帧可能多发自机命中，且多门炮同时开火），
			# 直调 AudioManager 并由它内部的 50ms 时间窗 + 同帧去重压住。
			# 不带 sector —— 命中点是**敌人**的位置，不归属某个受击扇区。
			# （按伤害/距离变调是 ⑪ Game Feel 的活，这里先给一个稳定的反馈音。）
			AudioManager.play_sfx(&"sfx_projectile_hit")
			_die(&"hit")
			return true
	return false


## 点 p 到线段 [a, b] 的最短距离。t 钳在 0..1，保证只算线段本身、不算两端延长线。
func _dist_to_segment(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq < 1e-9:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t)


## 死亡原因：hit / lifetime / range。命中以外的死法都静默（不 emit 任何东西），
## 只 print 一行调试。命中路径已经通过 EventBus.enemy_killed 传出。
func _die(reason: StringName) -> void:
	_alive = false
	# 真实释放放在下一帧，避免从当前 advance 遍历里直接 queue_free 导致迭代器失效。
	# 用 call_deferred 比 queue_free 安全（后者会在 idle 帧回收，advance 同帧再访问就崩）。
	call_deferred(&"_free_self")
	if reason == &"hit":
		return
	if DEBUG_LOG:
		print("[projectile] %s 失效（%s）距离=%.1f" % [
			name, reason, global_position.distance_to(_origin_pos)])


func _free_self() -> void:
	if is_inside_tree():
		queue_free()


## 视觉：白色细长 BoxMesh 沿飞行方向拉长 0.8 m。
## 用 look_at 在 setup 时已转好朝向，所以 +Z 自然朝 direction。
## 故意只 1 个面可见，省去 6 面网格。
func _build_visual() -> void:
	var mi := MeshInstance3D.new()
	mi.name = "Body"
	var box := BoxMesh.new()
	box.size = Vector3(0.4, 0.4, 0.8)
	mi.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.9, 0.4)   # 子弹白偏黄（视觉上像金属弹丸）
	mat.emission_enabled = true
	mat.emission = Color(0.8, 0.7, 0.3)        # 子弹自带一点光，方便在暗背景看到
	mi.material_override = mat
	add_child(mi)
