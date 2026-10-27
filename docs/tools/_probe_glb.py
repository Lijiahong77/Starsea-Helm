# -*- coding: utf-8 -*-
"""
_probe_glb.py — 不启动 Godot / Blender，直接读 .glb 的元数据。

读的是 glb 容器里的 JSON chunk（glTF 规范），能拿到：
  - 节点树 + 各级 TRS
  - 世界空间包围盒（用于锚定米数 / 判断尺度）
  - 每个材质的 doubleSided / alphaMode（判断"从内部看是否透明"）
  - 网格 / 顶点总数（性能预算）
  - 动画、贴图数量

用法:
  python _probe_glb.py <path-to-model.glb>

为什么有用：模型拖进引擎前，先知道它多大、朝哪、材质单双面，
免得在 Godot 里靠猜。glb 是二进制，但这个脚本只解码它的 JSON 头。
"""
import json
import struct
import sys
import os

JSON_CHUNK = 0x4E4F534A
BIN_CHUNK = 0x004E4942


def read_glb(path):
    with open(path, "rb") as f:
        data = f.read()
    magic, version, total = struct.unpack_from("<4sII", data, 0)
    if magic != b"glTF":
        raise ValueError("not a glb: magic=%r" % magic)
    off, js, bin_len, nchunk = 12, None, 0, 0
    while off < len(data):
        clen, ctype = struct.unpack_from("<II", data, off)
        off += 8
        chunk = data[off:off + clen]
        nchunk += 1
        if ctype == JSON_CHUNK:
            js = json.loads(chunk.decode("utf-8"))
        elif ctype == BIN_CHUNK:
            bin_len = clen
        off += clen
    return js, bin_len, version, total, nchunk


def node_matrix(node):
    if "matrix" in node:
        return list(node["matrix"])
    t = node.get("translation", [0.0, 0.0, 0.0])
    r = node.get("rotation", [0.0, 0.0, 0.0, 1.0])
    s = node.get("scale", [1.0, 1.0, 1.0])
    x, y, z, w = r
    xx, yy, zz = x * x, y * y, z * z
    xy, xz, yz = x * y, x * z, y * z
    wx, wy, wz = w * x, w * y, w * z
    m = [
        1 - 2 * (yy + zz), 2 * (xy + wz), 2 * (xz - wy), 0.0,
        2 * (xy - wz), 1 - 2 * (xx + zz), 2 * (yz + wx), 0.0,
        2 * (xz + wy), 2 * (yz - wx), 1 - 2 * (xx + yy), 0.0,
        0.0, 0.0, 0.0, 1.0,
    ]
    for c in range(3):
        for row in range(3):
            m[c * 4 + row] *= s[c]
    m[12], m[13], m[14] = t[0], t[1], t[2]
    return m


def mat_mul(a, b):
    r = [0.0] * 16
    for c in range(4):
        for row in range(4):
            r[c * 4 + row] = sum(a[k * 4 + row] * b[c * 4 + k] for k in range(4))
    return r


def xform(m, p):
    x, y, z = p
    return (m[0] * x + m[4] * y + m[8] * z + m[12],
            m[1] * x + m[5] * y + m[9] * z + m[13],
            m[2] * x + m[6] * y + m[10] * z + m[14])


IDENT = [1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0]


def main(path):
    js, bin_len, ver, total, nchunk = read_glb(path)
    print("=" * 62)
    print("模型: %s" % os.path.basename(path))
    print("文件: %.2f MB  |  glTF 版本 %d  |  %d chunks  |  BIN %.2f MB"
          % (total / 1048576.0, ver, nchunk, bin_len / 1048576.0))
    print("生成器: %s" % js.get("asset", {}).get("generator", "?"))

    nodes = js.get("nodes", [])
    meshes = js.get("meshes", [])
    accessors = js.get("accessors", [])
    mats = js.get("materials", [])

    # ---- 包围盒：递归走场景，累积世界变换 ----
    lo = [float("inf")] * 3
    hi = [float("-inf")] * 3
    tri_total = 0
    vert_total = 0

    def walk(idx, parent):
        nonlocal tri_total, vert_total
        n = nodes[idx]
        m = mat_mul(parent, node_matrix(n))
        if "mesh" in n:
            for prim in meshes[n["mesh"]].get("primitives", []):
                a = accessors[prim["attributes"]["POSITION"]]
                if "min" in a and "max" in a:
                    mn, mx = a["min"], a["max"]
                    for cx in (mn[0], mx[0]):
                        for cy in (mn[1], mx[1]):
                            for cz in (mn[2], mx[2]):
                                w = xform(m, (cx, cy, cz))
                                for i in range(3):
                                    lo[i] = min(lo[i], w[i])
                                    hi[i] = max(hi[i], w[i])
                vert_total += a.get("count", 0)
                if "indices" in prim:
                    tri_total += accessors[prim["indices"]].get("count", 0) // 3
        for c in n.get("children", []):
            walk(c, m)

    for scene in js.get("scenes", []):
        for root in scene.get("nodes", []):
            walk(root, IDENT)

    if lo[0] == float("inf"):
        print("\n[!] 没有读到位姿数据")
        return

    size = [hi[i] - lo[i] for i in range(3)]
    ctr = [(hi[i] + lo[i]) / 2 for i in range(3)]

    print("\n--- 世界包围盒 (glTF 坐标: X右 / Y上 / Z前) ---")
    print("  最小   x %8.3f   y %8.3f   z %8.3f" % tuple(lo))
    print("  最大   x %8.3f   y %8.3f   z %8.3f" % tuple(hi))
    print("  尺寸   x %8.3f   y %8.3f   z %8.3f   <-- 宽/高/长" % tuple(size))
    print("  中心   x %8.3f   y %8.3f   z %8.3f" % tuple(ctr))
    print("  最长边 %.2f m   次长 %.2f m" % (max(size), sorted(size)[1]))

    print("\n--- 几何规模 ---")
    print("  节点数 %d   网格数 %d   材质数 %d" % (len(nodes), len(meshes), len(mats)))
    print("  顶点 %d   三角面 %d" % (vert_total, tri_total))
    print("  贴图 %d   动画 %d" % (len(js.get("images", [])), len(js.get("animations", []))))

    print("\n--- 材质 (关键: doubleSided) ---")
    print("  %-28s %-11s %-10s %s" % ("名称", "doubleSided", "alphaMode", "判定"))
    for i, mt in enumerate(mats):
        ds = mt.get("doubleSided", False)
        am = mt.get("alphaMode", "OPAQUE")
        if ds:
            verdict = "双面 -> Godot cull_mode=关闭 (会挡住内外视线)"
        else:
            verdict = "单面 -> Godot cull_mode=背面剔除 (从内部透明)"
        print("  %-28s %-11s %-10s %s" % (mt.get("name", "material_%d" % i)[:28], ds, am, verdict))

    print("\n--- 节点树 ---")
    def dump(idx, depth):
        n = nodes[idx]
        tag = ""
        if "mesh" in n:
            tag = " [mesh %d]" % n["mesh"]
        tr = ""
        if any(k in n for k in ("translation", "rotation", "scale", "matrix")):
            if "matrix" in n:
                tr = " matrix=yes"
            else:
                tr = " t=%s s=%s" % (n.get("translation", [0, 0, 0]), n.get("scale", [1, 1, 1]))
        print("  " + "  " * depth + "- %s%s%s" % (n.get("name", "node%d" % idx), tag, tr))
        for c in n.get("children", []):
            dump(c, depth + 1)

    for scene in js.get("scenes", []):
        for root in scene.get("nodes", []):
            dump(root, 0)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    main(sys.argv[1])
