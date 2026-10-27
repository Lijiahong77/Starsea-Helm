# -*- coding: utf-8 -*-
"""纯 Python 验证：模拟 bmesh.ops.remove_doubles 的"按距离合并"语义，
检验「按距离合并 + 复查循环」在边界情况下是否正确。

不依赖 Blender。目的是在交付脚本前，先把算法逻辑跑通。
"""
import collections
import itertools

# ---------- 模拟 Blender 的 remove_doubles ----------
def remove_doubles(verts, dist):
    """verts: list of (x,y,z) 元组。
    模拟 Blender 语义：按距离把点聚类，每簇保留【第一个】（索引最小）点的位置，
    删除同簇其余点。返回 (新顶点列表, 消掉的数量)。

    注：真实 Blender 用的是空间哈希 + 顺序扫描，这里用并查集近似，
    结论（哪些点会合并）一致。
    """
    n = len(verts)
    parent = list(range(n))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[max(ra, rb)] = min(ra, rb)  # 保留索引小的为根

    def d2(a, b):
        return sum((verts[a][i] - verts[b][i]) ** 2 for i in range(3))

    thr = dist * dist
    for i in range(n):
        for j in range(i + 1, n):
            if d2(i, j) <= thr:
                union(i, j)

    groups = collections.defaultdict(list)
    for i in range(n):
        groups[find(i)].append(i)

    kept = []
    removed = 0
    for root in sorted(groups):
        members = sorted(groups[root])
        # Blender 合到"组内第一个顶点"的位置
        kept.append(verts[members[0]])
        removed += len(members) - 1
    return kept, removed


def merge_until_converged(verts, dist, max_passes=20):
    """外层复查循环：直到某轮消不掉点为止。"""
    v = list(verts)
    total = 0
    for p in range(max_passes):
        v, r = remove_doubles(v, dist)
        total += r
        if r == 0:
            return v, total, p + 1
    return v, total, max_passes


# ---------- 测试 ----------
def approx(a, b, eps=1e-9):
    return all(abs(a[i] - b[i]) < eps for i in range(3))


def run():
    dist = 1e-4
    cases = []

    # 1) 两两重合
    v = [(0, 0, 0), (0, 0, 0), (1, 0, 0), (1, 0, 0)]
    cases.append(("两两重合", v, 2))

    # 2) 三重、四重重合（同一位置 4 个点）
    v = [(5, 5, 5)] * 4 + [(0, 0, 0)]
    cases.append(("单点四重", v, 3))

    # 3) 连锁：A-B 近、B-C 近、但 A-C 远（会通过 B 桥接）
    v = [(0, 0, 0), (0.00008, 0, 0), (0.00016, 0, 0)]
    cases.append(("链条式桥接", v, 2))

    # 4) 分组内点多于2、但分属不同簇（不该跨簇合并）
    v = [(0, 0, 0), (0, 0, 0), (1, 0, 0), (1, 0, 0), (1, 0, 0)]
    cases.append(("两簇各多重", v, 3))

    # 5) 无重合
    v = [(0, 0, 0), (1, 0, 0), (2, 0, 0)]
    cases.append(("无重合", v, 0))

    # 6) 四点全重合
    v = [(9, 9, 9)] * 5
    cases.append(("五点全重合", v, 4))

    print("=" * 62)
    print("算法验证（模拟 Blender remove_doubles + 复查循环）")
    print("=" * 62)
    all_ok = True
    for name, verts, expect_removed in cases:
        final, removed, passes = merge_until_converged(verts, dist)
        ok = (removed == expect_removed)
        all_ok = all_ok and ok
        mark = "✓" if ok else "✗"
        print("%s %-14s 输入 %d 点 → 输出 %d 点（消 %d，期望 %d，%d 轮）"
              % (mark, name, len(verts), len(final), removed, expect_removed, passes))

    # 7) 幂等性：对已合并的结果再跑一次，应该 0 变化
    v = [(0, 0, 0)] * 3 + [(1, 0, 0)] * 2
    f1, r1, _ = merge_until_converged(v, dist)
    f2, r2, _ = merge_until_converged(f1, dist)
    idem = (r2 == 0 and len(f2) == len(f1))
    all_ok = all_ok and idem
    print("%s %-14s 二次运行消掉 %d（期望 0）"
          % ("✓" if idem else "✗", "幂等性", r2))

    # 8) 结果位置 = 组内首点（验证 Blender "At First" 语义）
    v = [(7, 7, 7), (7, 7, 7.00001), (2, 0, 0)]
    f, _, _ = merge_until_converged(v, dist)
    first_ok = any(approx(p, (7, 7, 7)) for p in f)
    all_ok = all_ok and first_ok
    print("%s %-14s 合并结果含首点(7,7,7)" % ("✓" if first_ok else "✗", "合到首点"))

    print("-" * 62)
    print("全部通过 ✓" if all_ok else "存在失败 ✗")
    print("=" * 62)


if __name__ == "__main__":
    run()
