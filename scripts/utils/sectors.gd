extends RefCounted
class_name Sectors

## 六扇区（Sector）定义、归属判定与压力归一化 —— 共享工具，无状态。
##
## 权威定义见 `docs/bible/02_entities.md §一`：
## fore(前) / aft(后) / port(左舷) / starboard(右舷) / dorsal(上) / ventral(下)。
## aft 是推进器高温区，敌人不主攻（DEC-036）。
##
## **坐标轴约定**（实测自 `scenes/bridge/bridge_whitebox.tscn`，不是猜的）：
## | 扇区 | 轴 | 证据 |
## |------|-----|------|
## | fore | +Z | 艏部舷窗 WallFrontFill* 在 z=+1.8 |
## | aft  | -Z | WallBack 在 z=-4.4 |
## | port / starboard | -X / +X | WallLeft x=-2.6 / WallRight x=+2.6 |
## | dorsal / ventral | +Y / -Y | Ceiling y=+3.1 / Floor y=-0.1 |
## 与 `data/presentation.json` 里 monitor 的 4 路 feed 相机轴向一致。

const IDS: Array[StringName] = [&"fore", &"aft", &"port", &"starboard", &"dorsal", &"ventral"]

## 每个扇区的外法线（单位向量）。
const AXES: Dictionary = {
	&"fore": Vector3(0, 0, 1),
	&"aft": Vector3(0, 0, -1),
	&"port": Vector3(-1, 0, 0),
	&"starboard": Vector3(1, 0, 0),
	&"dorsal": Vector3(0, 1, 0),
	&"ventral": Vector3(0, -1, 0),
}


## 判定某点属于哪个扇区：取「相对 center 的方向」与 6 个扇区轴点积最大的那个。
## 点正好落在两轴分界上时取先遍历到的扇区 —— 分界是零测度情况，不影响玩法判定。
static func sector_of(pos: Vector3, center: Vector3) -> StringName:
	var dir: Vector3 = pos - center
	if dir.length_squared() < 1e-6:
		return &"fore"
	dir = dir.normalized()
	var best_id: StringName = &"fore"
	var best_dot := -INF
	for id in IDS:
		var axis: Vector3 = AXES[id]
		var d := dir.dot(axis)
		if d > best_dot:
			best_dot = d
			best_id = id
	return best_id


## 压力归一化：威胁数 / 参考值，钳到 0..1。
##
## ⚠ **这是③阶段的临时公式**。`docs/bible/02_entities.md §一` 定义
## pressure = 威胁值 / 剩余防御力，但炮塔实体属④⑤步，③ 还没有防御力可除。
## ⑤ 接入炮塔耐久后，应把本函数换成「威胁值 / 剩余防御力」——
## 换的时候记得两处调用方（EnemySystem 的压力更新）一起改。
static func pressure_from_count(count: int, reference_count: float) -> float:
	if reference_count <= 0.0:
		return 0.0
	return clampf(float(count) / reference_count, 0.0, 1.0)
