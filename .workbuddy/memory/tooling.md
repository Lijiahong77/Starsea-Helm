# 工具链 · 协作约定（冷区 · 按需读）
> 触发时机：要接 MCP / 改文件前确认协作规矩时读。**跑测试与运行环境坑见 `testing.md`。**
> 预算 6000 字符。（2026-09-10 拆分：测试/验证部分独立成 `testing.md`。）

## Godot MCP（Coding-Solo/godot-mcp）
- 本地仓库 `D:\GameProject\godot-mcp-server`（GitHub HEAD 2026-04-16，**含 RCE 修复，比 npm 发布版新 → 勿改成 npx**）。
- 配置位置 `~/.workbuddy/mcp.json`，entry 名 `godot`；`GODOT_PATH` 指向 Godot **控制台版** `_console.exe`，`DEBUG=true`。
- 能力：launch_editor / run_project / get_debug_output / stop_project 等 14 个工具。
- **验证一律走 `run_project` + `get_debug_output`，不让用户 F5 贴日志。** stdio 传输 = NDJSON（每条 JSON-RPC 一行 + `\n`）。
- ⚠ **进程 quit 后 `get_debug_output` 拿不到任何数据**（报 "No active Godot process"）→ 需要收尾日志的
  长跑场景改走 Bash `run_in_background` 起控制台版 + stdout/stderr 重定向 `.workbuddy/logs/*.log`，再 Read。
  探针模板：`create_timer(1.5)` 生成×3 → `create_timer(12)` quit；**quit 要早于客户端失去进程的窗口**。

## 协作约定（用户亲授，务必遵守）
1. **用户审阅批准后才写代码；未经「开工」不建 `.gd` / `.tscn`。**
2. **三轮对话节奏**：AI 先自陈理解 → 只回答疑问 → 才实现。
3. **一次只改一件事**，改完验证通过再动下一个。
4. 复杂/高风险功能先建**独立测试场景**（`scenes/tests/` + `scripts/tests/`）跑通、性能达标，再搬进主场景。
5. 分批改文档，每批 2–3 份，给用户检查间隙。
6. 每会话先读 `docs/bible/_index.md` 只取相关分页，不要全量灌。
7. 数值只给旋钮不给终值，一律外置 `data/*.json`，禁止 hardcode。
8. **注释不许写易腐内容**（2026-09-02 审计后定的规矩，用户会亲自检查）：
   - 不写行数 / 日期 / "重构后"这类会随时间变假的话；
   - 不写做不到的绝对声明（如"零 hardcode"）——做不到就写明**例外与理由**；
   - 文档引用补全路径+章节（`docs/bible/04_presentation.md §八`，不要只写"第八节"）；
   - **改完代码回头审一遍注释**，重点是"函数改了、注释没改"和重复清单
     （同一份数据存两处常量 → 必合并为单一真源，否则改一处漏一处会静默错位）。
9. **用户说"界面 / UI / 颜色不好看"默认指「Godot 编辑器自身主题」**，不是游戏内 HUD。
   （9/3 他问"Godot 能自定义主题吗"附的是 `Editor Settings → Interface → Theme` 截图，我误判成游戏 HUD
   改了 `.tscn`，白改一轮后被要求回滚。）除非上下文明确在讨论游戏内 HUD/玩法，否则先按编辑器主题理解。
10. **日志纪律（2026-09-05 用户亲授）**：Output 是排查问题的主战场，必须保持可读 ——
    - **新写的模块 → 打印打开**（`const DEBUG_LOG := true`），让功能可在 Output 里直接验证；
    - **已验证通过的模块 → 打印关掉**（改 `DEBUG_LOG := false`），不然几十条日志盖住新模块，
      用户看不完（9/5 原话："已检验过的脚本应该把之前的打印日志都注释掉，不然太多条看不完"）。
    - 实现用**常量开关 + `_log()` 包装**，不要逐行注释：一键可恢复，且代码不变成一堆注释垃圾。
    - 日志只打**状态发生变化的那一刻**（生成 / 悬停 / 压力变化 / 移除），**绝不能每帧打** ——
      20 个敌人 × 60fps 会瞬间淹没 Output。
    - 例外：新功能的**调试入口**（如生成按键）要直接 `print`，不走开关 —— 否则被关掉后
      "按了键没反应" 就分不清是「按键没进来」还是「功能失败」。

## Git / GitHub（2026-09-10 项目首次上仓）
- 远程 `https://github.com/Lijiahong77/Starsea-Helm`（**公开**），默认分支 `main`。
- **提交身份配在 `--local`，没动全局**：`Li Jiahong <Lijiahong77@users.noreply.github.com>`。
  换机器要重配（`git config --local user.name/email`），否则 commit 直接报错。
- `.gitignore` 已按 **Godot 4.1+ 官方**重写：只忽略 `.godot/` + `*.translation`。
  ⚠ **`*.import` 与 `*.uid` 不能忽略** —— 前者存导入设置（mipmap/滤波/压缩），后者存资源引用。
  原文件是 Godot 3 写法（忽略了 `*.import`），会让 clone 后全部按默认参数重导。
- `.gitattributes`：`* text=auto eol=lf`（Windows 上不用再改 `core.autocrlf`）+ 常见二进制标记。
- 已排除 `.workbuddy/logs/`；`memory/` 与 `HANDOFF.md` **故意留在仓库里**（过程展示）。
- **Git LFS 还没开**（git-lfs 3.7.1 已装）。GitHub Free 只有 1 GiB 存储 + 1 GiB/月带宽 →
  美术资产落地前定规矩：源文件（.blend / .psd）不进 git，只提交运行时资产。
- ⚠ **`gh repo create` 不支持 `--add-topic`**（本机 gh 2.97.0）→ topics 用 `gh repo edit --add-topic a,b,c` 单独设。
- ⚠ **本机 bash 里 `git fetch` / `git push` 写不进 `.git/refs/remotes/origin/`**：报告 `[new branch]` 成功，
  目录却始终为空（疑为工具沙箱**不允许创建该子目录**）→ 症状 `git status` 显示 `## main...origin/main [gone]`。
  **`git update-ref refs/remotes/origin/main <sha>` 也无效 —— 它同样报成功但不落盘**（9/10 复现，白花一轮）。
  **别再试标准命令，直接走绕过**：用 Write 工具把 40 位 SHA + 换行写进 `.git/refs/remotes/origin/main`。
  **每次 push 后都要补一次**（不是一次性问题）。**只影响状态显示，push / pull 本身正常**，李自己机器上不会出现。

## 工具使用纪律（踩过坑，别再犯）
- **同一文件不要并行发两次编辑**：编辑是「读-改-写」，并发时后写的整份内容会覆盖先写的，
  而两次都返回成功 —— 9/3 就这样静默丢了一处 `var mount` 声明，多花了 3 轮才定位。
  → 同一文件连续改多处必须**串行**，或改用一次性脚本批量替换（python 读写整个文件）。
- 改完脚本立刻跑一次冒烟，不要攒着一起验 —— 上面的坑就是攒着验才拖了 3 轮。
- **新增 `class_name` 脚本后**，headless 跑测试会报「Could not find type <新类名>」——
  全局类缓存是 `--import` 时才刷新的。先跑 `godot_console --headless --import --path .` 一次，再跑测试（9/10 踩）。
- **`--script res://xxx.gd` 与 autoload 的可用时机**（2026-09-10 更正）：早先记的是"不会实例化 autoload"，
  实测**不准确** —— 在 `_initialize()` 里 `root.has_node("EventBus")` 为 **true**（节点已在），
  但它们 `_ready` 的日志出现在 `quit()` **之后** → 探针代码里**别依赖它们的就绪状态**。
  结论不变：**测 autoload 逻辑走场景路径**（`--path . res://scenes/tests/xxx.tscn`）；
  `--script` 只用来测与 autoload 无关的东西（几何 / 字体排版 / UV）。
- **别手编 `.gd.uid`**：格式不符会报 `invalid UID`（回退用 path，功能不受影响但脏）。
  正确做法：删掉手写的 `.uid` 文件，让 `--import` 自动生成合法 uid（9/10 踩）。
- 写带 `_` 前缀方法被测试探针直调（`col._advance_l3`）是本项目惯例，不是坏味道；
  但**跨类调带下划线方法**前想清楚——它语义是「内部实现，可能变」。
