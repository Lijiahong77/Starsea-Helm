# -*- coding: utf-8 -*-
"""
blender_merge_doubles.py —— 重合顶点合并（修复重复导入造成的虚焊网格）

用途
====
模型被"重复导入"后，同一位置的顶点被拆成多个独立顶点（拓扑上没焊在一起）。
本脚本对**当前选中的网格物体**做"按距离合并顶点"（= Blender 的 Merge by Distance /
Merge Vertices），把位置几乎重合的点焊成一个，直到不再有可合并的点为止。

为什么不是"两两合并 → 复查 → 再合并"的手写循环
------------------------------------------------
Blender 的 merge 在 UI 上确实是"两两"语义（要指定 First/Last），但 Python 层
`bmesh.ops.remove_doubles(bm, verts, dist)` 可以**一次性处理 N 个重合点**：
它内部按距离做空间分组，一组里的点（不管是 2 个、3 个还是 10 个）直接融合成一个。

手写"两两合并 + 循环"有个致命坑：**合并一个点会让顶点索引失效**，
第二轮再引用旧索引就会合并到错误的点上 —— 而且 Blender 不会报错，
表现为网格被悄悄搞坏。所以正确做法是：
  ① 内部用 remove_doubles 一次做完；
  ② 外层再用循环复查（merge 后可能产生新的重合，例如三方重合先合了俩），
     直到某轮"顶点数不再减少"为止。

合并到哪个位置（At First / At Last）
------------------------------------
`remove_doubles` 把一组合并到该组**第一个顶点**的位置。对"重复导入造成的
几乎完全重合点"来说，合到哪个位置差异在浮点误差级，肉眼不可见。
若你想严格对齐到"组内平均位置"，用下面的 USE_CENTER：

使用方法
========
方式 A（推荐，通用）：Blender 顶部 Scripting 工作区 → Open → 选本文件 → Run Script。
方式 B（外部脚本）：命令行执行
    blender --background your_file.blend --python blender_merge_doubles.py
      （注意：这种方式需要自己保证选中物体；见 main() 里的说明）

运行前：在 3D 视图里选中要处理的物体（可多选）。
"""

import bpy
import bmesh
from mathutils import Vector

# ============================================================
# 参数（按需改）
# ============================================================

# 合并距离阈值（单位 = Blender 单位 = 米）。
# 1e-4 m = 0.1 mm：只吃"几乎完全重合"的点，不会误伤正常建模的细节间距。
# 若模型是"从网站导入时被整体缩放过"导致重差点稍大，可放宽到 1e-3（1 mm）。
MERGE_DIST = 1e-4

# 复查循环的安全上限。正常情况下 2~3 轮就收敛（连续合并 + 连锁重合消除）。
# 设上限是防止极端情况死循环。
MAX_PASSES = 20

# True  = 合并到"组内平均位置"（更居中，但需要额外实现，稍慢）
# False = 用 Blender 原生 remove_doubles（合到组内第一个点，最快最稳）—— 默认
USE_CENTER = False


# ============================================================
# 核心
# ============================================================

def count_doubles(bm, dist):
    """统计"按该距离合并后能消掉多少个顶点"（用于复查是否收敛）。
    返回 (将有重合的点数, 合并后剩余点数)。"""
    before = len(bm.verts)
    # 用一份拷贝计算，不动原网格
    tmp = bm.copy()
    bmesh.ops.remove_doubles(tmp, verts=tmp.verts[:], dist=dist)
    after = len(tmp.verts)
    tmp.free()
    return (before - after, after)


def merge_by_distance_bmesh(bm, dist, use_center=False):
    """对 bmesh 做一轮按距离合并。返回本轮消掉的顶点数。

    use_center=False → bmesh.ops.remove_doubles（原生，快，合到组内首点）
    use_center=True  → 自实现：把每个重合组平移到组中心再合并（结果更居中）
    """
    before = len(bm.verts)
    if not use_center:
        bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=dist)
        return before - len(bm.verts)

    # —— 居中版：先按距离聚类，把每簇移到簇心，再 remove_doubles 到 dist/2 ——
    # 聚类用简单网格哈希（把空间切成 dist 大小的格子，相邻格子都查）
    import collections
    inv = 1.0 / dist if dist > 0 else 0.0

    def cell_of(v):
        return (int(round(v.co.x * inv)),
                int(round(v.co.y * inv)),
                int(round(v.co.z * inv)))

    grid = collections.defaultdict(list)
    for v in bm.verts:
        grid[cell_of(v.co)].append(v)

    visited = set()
    clusters = []
    for key, verts in grid.items():
        # 集合本身用 id 去重；这里 key 唯一，直接扩展邻居
        cx, cy, cz = key
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for dz in (-1, 0, 1):
                    nk = (cx + dx, cy + dy, cz + dz)
                    if nk in grid and nk != key:
                        verts.extend(grid[nk])
        # 上面把邻居也塞进来了，稍后统一去重
    # 重新按并查集聚类，保证正确（hash 预筛 + 精算距离）
    parent = {v: v for v in bm.verts}

    def find(x):
        while parent[x] is not x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra is not rb:
            parent[rb] = ra

    # 只在同一/相邻格子内两两比距离
    for key, verts in grid.items():
        uniq = list({v for v in verts})
        for i in range(len(uniq)):
            for j in range(i + 1, len(uniq)):
                a, b = uniq[i], uniq[j]
                if (a.co - b.co).length <= dist:
                    union(a, b)

    groups = collections.defaultdict(list)
    for v in bm.verts:
        groups[find(v)].append(v)

    for root, members in groups.items():
        if len(members) > 1:
            center = Vector((0, 0, 0))
            for m in members:
                center += m.co
            center /= len(members)
            for m in members:
                m.co = center

    # 居中后严格重合，用极小 dist 合并
    bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=dist * 0.5)
    return before - len(bm.verts)


def process_object(obj, dist, max_passes, use_center, report):
    """处理单个网格物体。返回 (是否改动过, 最终顶点数)。"""
    if obj.type != 'MESH':
        return False, 0

    me = obj.data
    if me is None or len(me.vertices) == 0:
        return False, 0

    bm = bmesh.new()
    bm.from_mesh(me)

    v_start = len(bm.verts)
    total_removed = 0

    for p in range(max_passes):
        removed = merge_by_distance_bmesh(bm, dist, use_center)
        total_removed += removed
        # 本轮没消掉顶点 → 已收敛，停
        if removed == 0:
            break
        # 安全检查：顶点太少说明可能出问题，停手
        if len(bm.verts) <= 0:
            break

    v_end = len(bm.verts)

    if total_removed > 0:
        bm.to_mesh(me)
        me.update()
        # 让法线重算（合并后原有的分裂法线可能不再正确）
        bm2 = bmesh.new()
        bm2.from_mesh(me)
        bmesh.ops.recalc_face_normals(bm2, faces=bm2.faces[:])
        bm2.to_mesh(me)
        bm2.free()
        bm.free()
        report.append(
            "  ✓ %-28s 顶点 %d → %d（合并 %d，共 %d 轮）"
            % (obj.name, v_start, v_end, total_removed, p + 1)
        )
        return True, v_end
    else:
        bm.free()
        report.append("  · %-28s 无可合并顶点（无需处理）" % obj.name)
        return False, v_end


# ============================================================
# 入口
# ============================================================

def main():
    print("\n" + "=" * 60)
    print("重合顶点合并 —— 距离阈值 %.6f m" % MERGE_DIST)
    print("=" * 60)

    targets = [o for o in bpy.context.selected_objects if o.type == 'MESH']
    if not targets:
        print("⚠ 没有选中任何网格物体。请在 3D 视图里选中后重跑。")
        return

    report = []
    changed = 0
    for obj in targets:
        ok, _ = process_object(
            obj, MERGE_DIST, MAX_PASSES, USE_CENTER, report)
        if ok:
            changed += 1

    print("处理了 %d 个网格物体：" % len(targets))
    for line in report:
        print(line)
    print("-" * 60)
    print("实际改动 %d 个物体。" % changed)
    print("提示：若想撤销，Blender 里按 Ctrl+Z（一次运行算一步）。")
    print("=" * 60 + "\n")


# Blender 直接 Run Script 时执行；被 import 时不自动跑
if __name__ == "__main__":
    main()
