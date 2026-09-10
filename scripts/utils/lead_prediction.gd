extends RefCounted
class_name LeadPrediction

## 提前量预测工具（DEC-034 · bible 02 §2.1）
##
## **为什么需要**：主炮弹丸速度 150-250 m/s，敌人移动 17 m/s（白盒），
## 若瞄当前位置发射，1 秒后弹丸到时敌人已跑 17 m（弹丸飞到 100 m 处时差 5 m），
## 永远打不中。需要**预测**「弹丸飞行时间 t 后敌人的位置」= 拦截点。
##
## 数学：
##   设 P0 = 炮位, P = 目标当前位置, V = 目标速度, S = 弹速。
##   弹丸轨迹：P0 + t·S·u（u 为飞行单位向量），但 u 未知，所以改写约束：
##   |(P + V·t) - P0| = S·t
##   展开平方：
##     |P-P0|^2 + 2t·(P-P0)·V + t^2·|V|^2 = S^2·t^2
##     t^2·(|V|^2 - S^2) + 2t·(P-P0)·V + |P-P0|^2 = 0
##   令 a = |V|^2 - S^2,  b = 2(P-P0)·V,  c = |P-P0|^2
##   求 a·t^2 + b·t + c = 0 的最小正根 t → 拦截点 = P + V·t
##
## 退化情况：
##   a ≈ 0（目标速度与弹速几乎相等）：降级为线性解 t = |P-P0| / S（向量方向平行即可）
##   b^2 - 4ac < 0（弹速追不上目标，物理拦截不可能）：返回 ZERO + 时间 = -1 表示失败
##
## **不在脚本里硬编码任何数值**，调用方传 (shooter_pos, target_pos, target_velocity, projectile_speed)
## 即可。数值（弹速）来自 data/turrets.json main_gun.projectile_speed，由调用方注入。

## 求「弹丸应在 t 秒后飞到、与目标当前位置重合的点」—— 即发射方向瞄准此点就能命中。
## 返回 Vector3.ZERO 表示「物理上拦截不到」（弹丸追不上目标）。
## 同时通过 out_t（可选）返回拦截时间（秒），调用方可显示「预判 0.45 s」之类 HUD 数字。
static func intercept_point(shooter_pos: Vector3, target_pos: Vector3,
		target_velocity: Vector3, projectile_speed: float) -> Vector3:
	var t := _intercept_time(shooter_pos, target_pos, target_velocity, projectile_speed)
	if t <= 0.0:
		return Vector3.ZERO
	return target_pos + target_velocity * t


## 只返回拦截时间（秒）。返回 <= 0 表示拦截失败（弹速不够 / 已在身后 / 距离 0）。
static func intercept_time(shooter_pos: Vector3, target_pos: Vector3,
		target_velocity: Vector3, projectile_speed: float) -> float:
	var rel: Vector3 = target_pos - shooter_pos
	var dist := rel.length()
	if dist < 1e-4:
		return 0.0
	if projectile_speed <= 0.0:
		return -1.0
	var v_sq := target_velocity.length_squared()
	var a := v_sq - projectile_speed * projectile_speed
	var b := 2.0 * rel.dot(target_velocity)
	var c := dist * dist
	# 退化：目标速度与弹速几乎相等（|a| < 1e-3 视作相等）
	if absf(a) < 1e-3:
		# 0·t^2 + b·t + c = 0 → t = -c/b（仅在 b<0 时有正解，即 rel·V < 0 表示目标在靠近）
		if b >= 0.0:
			return -1.0
		return -c / b
	var disc: float = b * b - 4.0 * a * c
	if disc < 0.0:
		return -1.0
	var sqrt_disc: float = sqrt(disc)
	# 二次方程两根：(-b ± sqrt_disc) / (2a)
	# 取最小正根。
	var t1: float = (-b - sqrt_disc) / (2.0 * a)
	var t2: float = (-b + sqrt_disc) / (2.0 * a)
	var t: float = min(t1, t2) if t1 > 0.0 else t2
	if t <= 0.0:
		# 两根都非正 → 目标在身后或已过拦截窗
		var alt: float = max(t1, t2)
		t = alt if alt > 0.0 else -1.0
	return t


## 私有：从四参数求 t。intercept_point / intercept_time 复用，避免重复分支。
static func _intercept_time(shooter_pos: Vector3, target_pos: Vector3,
		target_velocity: Vector3, projectile_speed: float) -> float:
	return intercept_time(shooter_pos, target_pos, target_velocity, projectile_speed)
