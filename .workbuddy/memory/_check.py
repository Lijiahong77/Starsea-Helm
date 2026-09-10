#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
记忆体积自检 —— 防止 MEMORY.md 膨胀到被注入时截断。

用法：
    python .workbuddy/memory/_check.py

预算：
    MEMORY.md          2800 字符   （每会话自动注入，超了会被静默截断）
       └ 其中「分册索引区」 700 字符 （索引是增长最快的一块，单独盯）
    分册（非日期 .md）  6000 字符   （按需读取）
    日志 YYYY-MM-DD.md 4000 字符   （按需读取，读最近 1-2 天）
"""
import re
import sys
from pathlib import Path

BUDGET_HOT = 2800
BUDGET_BOOK = 6000
BUDGET_LOG = 4000
BUDGET_INDEX_REGION = 700   # 热区里的「分册索引」小节

# 分册文件名 -> 该装什么内容（超限时用来提示往哪搬）
BOOKS = {
    "design_snapshot.md": "玩法 / 数值 / 系统边界 -> design_snapshot.md",
    "godot_pitfalls.md": "Godot 4 引擎 / 渲染 / UV 踩坑 -> godot_pitfalls.md",
    "gdscript_snags.md": "GDScript 语言层踩坑 -> gdscript_snags.md",
    "monitor_feed.md": "监控 / feed 出图 -> monitor_feed.md",
    "audio.md": "音频 / 音效 / BGM -> audio.md",
    "game_feel.md": "Game Feel / 手感反馈 -> game_feel.md",
    "healthbar.md": "敌人血量反馈（血条 / 本体变暗 / hp_max）-> healthbar.md",
    "damage_collapse.md": "战损四出口 / 陷落三级演出 / L3 镜头 -> damage_collapse.md",
    "fonts.md": "字体 / 文本渲染 / 系统兜底 -> fonts.md",
    "testing.md": "验证纪律 / 测试清单 / 运行环境坑 -> testing.md",
    "tooling.md": "MCP / 协作约定 / 工具使用纪律 -> tooling.md",
    "history.md": "逐日大事记（阶段成果 + DEC 演进）-> history.md",
}
DATE_LOG = re.compile(r"^\d{4}-\d{2}-\d{2}\.md$")


def budget_of(name: str) -> int:
    if name == "MEMORY.md":
        return BUDGET_HOT
    if DATE_LOG.match(name):
        return BUDGET_LOG
    return BUDGET_BOOK


def index_region(text: str) -> str:
    """抠出热区里「分册在哪 / 记忆索引」那一个小节（到下一个 ## 为止）。"""
    m = re.search(r"(?ms)^## [^\n]*(?:分册|索引)[^\n]*\n.*?(?=^## |\Z)", text)
    return m.group(0) if m else ""


def main() -> int:
    root = Path(__file__).resolve().parent
    files = sorted(p for p in root.glob("*.md"))
    if not files:
        print("没有找到 .md 记忆文件")
        return 0

    problems = []
    rows = []
    for p in files:
        n = len(p.read_text(encoding="utf-8"))
        budget = budget_of(p.name)
        rows.append((p.name, n, budget, n / budget))
        if n > budget:
            problems.append((p.name, n, budget))

    width = max(len(r[0]) for r in rows) + 2
    print(f"{'文件'.ljust(width)}{'实际':>8}{'预算':>8}{'占比':>8}  状态")
    print("-" * (width + 34))
    for name, n, budget, ratio in rows:
        bar = "超限" if n > budget else ("接近" if ratio > 0.85 else "OK")
        print(f"{name.ljust(width)}{n:>8}{budget:>8}{ratio:>7.0%}  {bar}")

    # ── 热区里的索引小节：增长最快的一块，单独盯 ──────────────────
    hot = root / "MEMORY.md"
    if hot.exists():
        idx = index_region(hot.read_text(encoding="utf-8"))
        if idx:
            n = len(idx)
            r = n / BUDGET_INDEX_REGION
            tag = "超限" if n > BUDGET_INDEX_REGION else ("接近" if r > 0.85 else "OK")
            print(f"\nMEMORY.md · 索引小节：{n} / {BUDGET_INDEX_REGION}（{r:.0%}）  {tag}")
            if n > BUDGET_INDEX_REGION:
                print("  -> 索引不该长成一长串清单。处置：")
                print("     · 跨阶段必读的 4-5 项明确列；其余模块**按「玩家能否感知」分两组**、每册只留一个词；")
                print("     · 模块名自解释就够了（`audio` / `vfx`），别写「什么时候读」整句；")
                print("     · 拿不准的目录交给 Glob —— **文件名就是索引**。")

    # ── 分册目录速览（顺手补足「发现」：不用翻热区也知道有哪些册）──
    books = [p for p in files if p.name != "MEMORY.md" and not DATE_LOG.match(p.name)]
    if books:
        print(f"\n分册目录（{len(books)} 册 · 首行即触发时机，拿不准就 Glob 本目录）：")
        for p in books:
            head = ""
            for line in p.read_text(encoding="utf-8").splitlines():
                if line.startswith("# ") or not line.strip():
                    continue
                head = line.strip().lstrip("> ").strip()
                break
            print(f"  {p.name.replace('.md', ''):<18}{head[:52]}")

    print()
    if not problems:
        print("全部在预算内。")
        return 0

    print(f"有 {len(problems)} 个文件超限：")
    for name, n, budget in problems:
        print(f"\n  [{name}] {n} / {budget}（超 {n - budget}）")
        if name == "MEMORY.md":
            print("    -> 每会话自动注入的热区，超了会被静默截断，最贵的条目最容易丢。")
            print("    -> 处置：把正文搬到分册，本文件只留子索引；先看上面「索引小节」那一行。")
        elif DATE_LOG.match(name):
            print("    -> 处置：蒸馏成 3-5 行「结论 + 关键证据 + 指针」；")
            print("       蒸馏前先查内容是否已在 bible / 既有分册，避免建重复册。")
        else:
            print("    -> 处置：拆出新分册，并在 MEMORY.md 的「模块专册」加一个词。")
    return 1


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.exit(main())
