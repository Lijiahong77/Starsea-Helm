# 测试与验证（冷区 · 按需读）
> 触发时机：**跑验证 / 写测试探针 / 怀疑测试结果**时读。协作规矩见 `tooling.md`，引擎坑见 `godot_pitfalls.md`。
> 预算 6000 字符。（2026-09-10 从 `tooling.md` 拆出 —— 原来一个文件混了「工具链/协作」与「跑测试」两件事。）

## 验证纪律
- 改完文件 → **re-read 确认落地** → 实跑确认 `errors:[]`（细节见 `godot_pitfalls.md` 第 5 节）。不许凭"我以为改了"报成功。
- 渲染 / feed 类问题用**像素采样**实测，不靠目视。
- 用户开着 Godot 编辑器时改 `.tscn` 有被覆盖风险 → 改前请用户关编辑器，改后提醒 Reload。
- **跨阶段必须清场**（9/8 踩）：敌人 / 子弹是 `call_deferred queue_free` 的，不等它就把**上一波的尸体**
  算进 `enemy_count()`（实测「6+1」断言成 12）→ 阶段之间 `await get_tree().physics_frame` ×2 + 强制 `queue_free` 残留。
  ⚠ 清场**只能在波次未激活时做**，BATTLE 中清会让系统误判「本波已清空」。
- **走真实调用路径，别抄近路**：伤害调 `Turret.take_damage` 而非直接 `emit`（直接 emit 跳过 `source_id`
  传递，坏了也是绿的，9/10）；**测试手动调入口而不走事件链，会在新规则下骗自己**（9/9 改走
  `EventBus.crisis_cleared.emit(1)` 才恢复 33/33）。
- 断言「过场走到某阶段」时，推进时长按**最坏台词量**给，别按典型值给（9/9 踩）。

## 现成探针与测试场景
| 脚本 | 用途（断言点） |
|------|------|
| `scripts/tests/uv_probe.gd` | headless dump 任意 Mesh 的 UV，查贴图错位 |
| `scripts/tests/cam_probe.gd` | **读 presentation.json** 算 4 路 feed 相机挂载点 + Transform3D，打印成 `.tscn` 可粘贴（与运行时同源） |
| `scripts/tests/font_probe.gd` | **字体 / 排版探针**（SceneTree 型，可 headless）：TextServer 接口 / 内嵌字体身份 / **shaping 逐 glyph 判定**（`index==0` 豆腐、`font_rid` 外来 = 系统兜底）/ 数字等宽推进宽 |
| ③ `enemy_test` | 生成 / 移动 / 扇区归属 / 攻击最近炮塔 |
| ④ `turret_round2` | 4 副炮接入：独立开火 / 炮位推导 / 端到端击杀 |
| ⑤ `turret_hp_test` | 伤害路由 / 被毁停火 / 全毁事件 / 死炮不可接管 / 开战回满 |
| ⑦ `refit_test` | 阶段机走位 / 换装真生效 / 隐形跳过 / 主炮不可换 / 未知型号拒绝 |
| ⑧ `unlock_test` | 开局锁定 / 锁定项装不上 / 危机 1·2·3·5 解锁 / 空槽装炮 / 播报 consume |
| ⑨ `wave_test` | 难度曲线 / 开波生成 / 清空回 REFIT / 调试生成不计入 / 收战清场 / RESULT 归零 |
| ⑨a `damage_test` | 累计 / **按敌类分解** / 扇区汇总 / 被毁标记 / 开战清空 / 四出口同源 |
| ⑨b `collapse_test` | L1 计数 / L2 红叉 / L3 夺操控+镜头+RESULT / 重置 / 表现层容错 |
| ⑩ `audio_test` | 总线层级 / 缺素材回退合成音 / 同帧去重+时间窗+**限流键含扇区** / 池 / 听觉 HUD / BGM 淡化 / 事件接线 |
| ⑪ `feel_test` | feel 旋钮 / 接线表 / 推镜**精确归位** / 震屏不超上限且归零 / 总闸 / L3 让位 / 闪白冷却 |
| ⑪ `healthbar_test` | 真源读取（`loaded_from_json`）/ 层号 5 / `hp_max` 快照 / `scale_hp` **同乘** / `enemy_damaged` 载荷（含致死）/ C 层按比例变暗且**不吃闪白** / B 层显隐·比例·换目标 |
| `scenes/tests/subviewport_feed_test.tscn` | 多路 SubViewport feed 独立验证 |
| `.workbuddy/memory/_check.py` | **记忆体积自检**（预算 vs 实际） |

> 上表 `_test.tscn` 都在 `scenes/tests/`，探针都在 `scripts/tests/`（省略前缀）。

## 运行命令（本机实测可用）
```bash
export PATH="$PATH:/usr/bin:/bin"   # 必须，见下坑 1
G="C:/Users/lijia/Desktop/Godot_v4.7-stable_win64.exe/Godot_v4.7-stable_win64_console.exe"

# 单跑
/usr/bin/timeout 150 "$G" --headless --path . res://scenes/tests/feel_test.tscn 2>&1 | grep -E "断言:|结果：" | head -1

# 整套（11 套 / 408 断言。**别漏 healthbar 与 enemy** —— 9/10 曾漏，见下坑 5）
for s in feel_test audio_test healthbar_test turret_round2 turret_hp_test \
         enemy_test wave_test refit_test unlock_test damage_test collapse_test; do
  printf "%-16s " "$s"
  /usr/bin/timeout 150 "$G" --headless --path . res://scenes/tests/$s.tscn 2>&1 | grep -E "断言:|结果：" | head -1
done

# 探针（SceneTree 脚本；工程须已导入，即有 .godot/）
"$G" --headless --path . --script res://scripts/tests/xxx.gd
```
⚠ **三个环境坑（2026-09-10 实测）**：
1. bash 里 `dirname` / `tail` / `grep` / `timeout` 全部 `command not found` —— 不是没装，是 PATH 少了
   Git 的 `/usr/bin`。开头 `export PATH="$PATH:/usr/bin:/bin"` 即可。
2. 直接写 `timeout` 会撞上 **Windows 自带的 `TIMEOUT.EXE`**（报「默认选项不允许超过 '1' 次」，且静默吞掉真命令）
   → 必须写全路径 `/usr/bin/timeout`。
3. 断言行格式**不统一**：`feel/audio/refit/unlock/damage/collapse/healthbar` 打 `断言: n/m 通过`，
   `turret_round2/turret_hp/wave` 打 `结果：通过 n / 失败 m` → grep 模式要同时含两者，
   老的 `grep "断言"` 会漏掉后三个。
4. **headless 主场景必然刷 `texture_2d_get: Parameter "t" is null`**（`bridge_whitebox.gd` 的 feed 回读处）——
   这是 **dummy 渲染驱动**的固有限制：`SubViewport.get_texture()` 返回 ViewportTexture 对象，但其后端 RID 为 null，
   所以 `get_image()` 报错并返回 null。**三行纯引擎代码即可复现**（`sv.get_texture().get_image()`），与你的改动无关。
   判读主场景 headless 输出时先滤掉这一条，否则会淹没真正的新错误。
   同理退出时那句 `N ObjectDB instances were leaked at exit` 是 **`quit()` 早于清理**的常态（每个探针都有），不是泄漏 bug。
5. **汇总断言数要按两种格式分别抓**：`grep -oE '[0-9]+/[0-9]+'` 只能匹配「断言: n/m」那 7 套，
   `turret_round2 / turret_hp / enemy / wave` 打的是「结果：通过 n」，会被**静默漏掉 91 条**
   （9/10 实测汇总出 317，真值是 **408 / 11 套**）。要点：**0 命中和漏抓长得一样**，报数前先核对套数。
