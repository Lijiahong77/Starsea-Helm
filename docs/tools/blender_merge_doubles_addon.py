# -*- coding: utf-8 -*-
"""
blender_merge_doubles_addon.py —— 重合顶点合并（Blender 插件版）

与同目录 `blender_merge_doubles.py` 的区别
=========================================
- 独立脚本版：丢进 Scripting 跑一次，轻量。
- 本插件版：装进 Blender 后常驻，**在 3D 视图右侧 N 面板出现一个「网格修复」标签页**，
  按钮点一下就处理选中物体；并带 **Dry Run（只预览不修改）**，让你先看会合并掉多少点
  再决定是否真做。适合反复清洗模型。

安装
====
1. Blender → Edit → Preferences → Add-ons → Install… → 选本 .py 文件 → 勾选启用。
2. 3D 视图右侧按 N → 出现「网格修复」标签页。

用法
====
1. 选中要处理的网格物体（可多选）。
2. 点「预览（Dry Run）」→ 看 Console / 面板底部列出每个物体将合并掉多少点。
3. 确认无误 → 点「合并重合顶点」。

设计要点（为什么这么写）
======================
- 用 `bmesh.ops.remove_doubles` 一次处理 N 个重合点，**不手写"两两合并+循环"**
  （手写循环会因顶点索引失效而静默合并错点）。
- 外层仍保留「复查循环」：remove_doubles 偶尔会让"三重重合"先合掉两个，
  需要再跑一轮才能把剩下的也合掉，直到顶点数不再减少。
- 合并后 `recalc_face_normals` 重算法线：合并会改变原有的分裂法线，
  不重算会出现"着色有缝 / 法线朝里"。
"""

bl_info = {
    "name": "Merge Doubles (Batch Repair)",
    "author": "Starsea Helm toolchain",
    "version": (1, 0, 0),
    "blender": (3, 0, 0),
    "location": "View3D > Sidebar (N) > 网格修复",
    "description": "合并选中网格里的重合顶点，修复重复导入造成的虚焊网格",
    "category": "Mesh",
}

import bpy
import bmesh
from mathutils import Vector


# ------------------------------------------------------------
# 属性
# ------------------------------------------------------------
class MERGED_Props(bpy.types.PropertyGroup):
    dist: bpy.props.FloatProperty(
        name="合并距离",
        description="位置距离小于该值的顶点会被合并（单位：米）。"
                    "0.0001 = 0.1mm，只吃几乎完全重合的点",
        default=0.0001, min=0.0, max=10.0, precision=6, step=0.0001,
    )
    max_passes: bpy.props.IntProperty(
        name="最大轮数",
        description="复查循环上限，防止极端情况死循环；正常 2~3 轮收敛",
        default=20, min=1, max=200,
    )


# ------------------------------------------------------------
# 核心算法
# ------------------------------------------------------------
def _merge_once(bm, dist):
    """一轮按距离合并，返回本轮消掉的顶点数。"""
    before = len(bm.verts)
    bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=dist)
    return before - len(bm.verts)


def _process_mesh(me, dist, max_passes):
    """对 mesh 数据做"合并 + 复查"直到收敛。返回 (消掉总数, 起始数, 结束数)。"""
    bm = bmesh.new()
    bm.from_mesh(me)
    v0 = len(bm.verts)
    removed = 0
    for _ in range(max_passes):
        r = _merge_once(bm, dist)
        removed += r
        if r == 0:
            break
    v1 = len(bm.verts)
    if removed > 0:
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
        bm.to_mesh(me)
        me.update()
    bm.free()
    return removed, v0, v1


def _count_only(me, dist, max_passes):
    """Dry Run：只统计会消掉多少点，不改动原 mesh（用拷贝算）。"""
    bm = bmesh.new()
    bm.from_mesh(me)
    v0 = len(bm.verts)
    removed = 0
    for _ in range(max_passes):
        r = _merge_once(bm, dist)
        removed += r
        if r == 0:
            break
    v1 = len(bm.verts)
    bm.free()
    return removed, v0, v1


# ------------------------------------------------------------
# Operators
# ------------------------------------------------------------
class MERGED_OT_preview(bpy.types.Operator):
    bl_idname = "mesh.merge_doubles_preview"
    bl_label = "预览（Dry Run）"
    bl_description = "只统计将合并多少顶点，不做任何修改"
    bl_options = {'REGISTER'}

    def execute(self, context):
        props = context.scene.merge_doubles_props
        targets = [o for o in context.selected_objects if o.type == 'MESH']
        if not targets:
            self.report({'WARNING'}, "没有选中网格物体")
            return {'CANCELLED'}
        lines = []
        total = 0
        for obj in targets:
            removed, v0, v1 = _count_only(
                obj.data, props.dist, props.max_passes)
            total += removed
            if removed:
                lines.append("  %s: %d → %d（可合并 %d）" % (obj.name, v0, v1, removed))
            else:
                lines.append("  %s: 无可合并点" % obj.name)
        print("\n[预览] 将处理 %d 个物体，共可合并 %d 个顶点：" % (len(targets), total))
        print("\n".join(lines))
        self.report({'INFO'}, "预览：共可合并 %d 个顶点（详见 Console）" % total)
        return {'FINISHED'}


class MERGED_OT_apply(bpy.types.Operator):
    bl_idname = "mesh.merge_doubles_apply"
    bl_label = "合并重合顶点"
    bl_description = "对选中网格执行按距离合并（会修改数据，可 Ctrl+Z 撤销）"
    bl_options = {'REGISTER', 'UNDO'}

    def execute(self, context):
        props = context.scene.merge_doubles_props
        targets = [o for o in context.selected_objects if o.type == 'MESH']
        if not targets:
            self.report({'WARNING'}, "没有选中网格物体")
            return {'CANCELLED'}
        lines = []
        total = 0
        changed = 0
        for obj in targets:
            removed, v0, v1 = _process_mesh(
                obj.data, props.dist, props.max_passes)
            total += removed
            if removed:
                changed += 1
                lines.append("  ✓ %s: %d → %d（合并 %d）" % (obj.name, v0, v1, removed))
            else:
                lines.append("  · %s: 无需处理" % obj.name)
        print("\n[合并] 处理 %d 个物体，改动 %d 个，共合并 %d 个顶点：" % (
            len(targets), changed, total))
        print("\n".join(lines))
        self.report({'INFO'}, "合并完成：%d 个物体，共 %d 个顶点" % (changed, total))
        return {'FINISHED'}


# ------------------------------------------------------------
# UI 面板
# ------------------------------------------------------------
class MERGED_PT_panel(bpy.types.Panel):
    bl_label = "网格修复"
    bl_idname = "MERGED_PT_panel"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "网格修复"

    def draw(self, context):
        layout = self.layout
        props = context.scene.merge_doubles_props

        box = layout.box()
        box.label(text="重合顶点合并", icon='AUTOMERGE_ON')
        box.prop(props, "dist")
        box.prop(props, "max_passes")

        col = layout.column(align=True)
        col.scale_y = 1.3
        col.operator(MERGED_OT_preview.bl_idname, icon='ZOOM_ALL')
        col.operator(MERGED_OT_apply.bl_idname, icon='AUTOMERGE_ON')

        n_sel = len([o for o in context.selected_objects if o.type == 'MESH'])
        layout.label(text="已选中 %d 个网格物体" % n_sel, icon='INFO')
        layout.label(text="提示：先预览，再合并", icon='QUESTION')


# ------------------------------------------------------------
# 注册
# ------------------------------------------------------------
_classes = (
    MERGED_Props,
    MERGED_OT_preview,
    MERGED_OT_apply,
    MERGED_PT_panel,
)


def register():
    for c in _classes:
        bpy.utils.register_class(c)
    bpy.types.Scene.merge_doubles_props = bpy.props.PointerProperty(
        type=MERGED_Props)


def unregister():
    del bpy.types.Scene.merge_doubles_props
    for c in reversed(_classes):
        bpy.utils.unregister_class(c)


if __name__ == "__main__":
    register()
