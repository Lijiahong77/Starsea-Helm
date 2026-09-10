# 给外部 AI 原型平台的提示词（Starsea Helm 浓缩版）
> 2026-09-02 · 用途：投喂给 Rosebud / Playabl / SEELE / Replit / Sider / Websim 一类的 prompt-to-game 网站，
> 让它们在 10 分钟内吐一个可玩网页原型，用来替我们验证**三条设计假设**，而不是替我们做美术。
>
> 主推英文版（代码生成质量最稳）。中文版给中文平台或自己对照用。极简版给 token 受限的平台。

---

## 一、主提示词（英文 · 直接整段复制）

```
You are building a single-file browser game PROTOTYPE: one index.html, pure HTML + CSS + vanilla JavaScript, Canvas 2D, ZERO external libraries, ZERO image/audio assets (draw everything with rectangles, circles, lines and text). It must run by just opening the file. No build step.

This is a DESIGN RESEARCH prototype, not a polished game. Priority order: (1) the mechanics below exist and are legible, (2) every number lives in one tunable place, (3) visual polish last.

# GAME: STARSEA HELM
You are the captain of a stationary spaceship under repeated attacks. The game is about deciding how to arm your ship BETWEEN attacks, and only lightly steering during the fight. Combat is deliberately LOW-APM: guns fire by themselves, slowly; the player optionally takes over ONE turret at a time to speed it up.

## The one innovation: you can only see forward
The bridge has a SINGLE FORWARD WINDOW. You can literally see the battle only in the FORWARD direction. Every other direction is knowable exclusively through FOUR small always-on monitor feeds (one per side) plus a compact radar. This information asymmetry IS the game. Do not give the player a free overview of all directions.

## Loop — the unit is a "crisis", not a "run"
REFIT (no time limit) -> BATTLE (one wave) -> REFIT -> ... until all turrets are destroyed -> RESULT -> "again" (same ship, unlocks kept).

## Six sectors around the ship
fore (the only one visible through the window), aft (engine exhaust; enemies almost never come from here), port, starboard, dorsal, ventral.

## Turrets
- MAIN GUN (1 group): fixed, only fires at fore. Fires DISCRETE PROJECTILES that take time to fly (~200 m/s), so hitting requires leading the target. Highest damage, highest durability (150-250), usually the last to fall.
- SUB TURRETS: one group per side (port/starboard/dorsal/ventral), 0-N guns per side. Medium durability (60-100 each). When every sub turret on a side is destroyed, that side is BREACHED.
- Every turret has two modes:
  - AUTO (default): fires on its own, slowly and intermittently (sub turret ~1 shot every 3s), auto-aimed, low DPS. Enough to hold, not enough to win.
  - MANUAL: the player takes over that ONE turret, aims and fires themselves at a much higher rate. Only one turret at a time.
- All turrets are restored to full durability at the start of every crisis. There is NO repair economy.

## Enemies
Spawn at the outer edge of a sector, fly straight at the ship, stop at attack range (45-60 units), then deal continuous damage to the nearest surviving turret; if it dies they retarget to the next nearest. Deliberately SLOW (6-20 units/s). Three types:
- Interceptor: fast, fragile, numerous.
- Bomber: slow, tanky, high damage to turrets.
- Heavy: very tanky, very slow.

## Losing
Every turret destroyed = run over. No hull, no shields, no repair. The main gun usually dies last simply because it has the most durability — that is an emergent result of the numbers, NOT a scripted rule.

## The player has exactly THREE verbs
1. FIT (between waves): swap turret types into slots, add turrets. This is the main gameplay.
2. TAKE OVER one turret (during combat), typically 0-3 times per wave.
3. SCAN: read the 4 monitor feeds / radar to decide which side needs taking over.
There is NO movement, NO resource management, NO issuing orders, NO active abilities. If you feel like adding any of those, don't.

## Turret types (unlock automatically by crisis count, NO currency)
rapid (high rate, low damage) | heavy (slow, high damage, tanky) | spread (hits several targets, good vs swarm) | aa (bonus vs interceptors) | anti_armor (bonus vs heavies) | aoe (splash, clears clusters).
Start with one standard sub turret on each of the four sides + the standard main gun. Unlock one new type at crises 3, 5, 7, 9, 11. Growth also comes from unlocking EXTRA SLOTS so one side can stack more guns.

## Screen layout — recreate this
+---------------------------------------------------------------+
|  FORWARD WINDOW (big, ~65% width)    |  MONITORS (2x2 grid)    |
|  the only live view you get:         |  [ PORT ]  [STARBOARD]  |
|  fore sector, main gun projectiles,  |  [DORSAL]  [ VENTRAL ]  |
|  incoming enemies                    |  tiny, low-res, ~8 fps  |
|                                      |  click one = take over  |
|  [F] take over main gun              |  that turret's view     |
|                                      |-------------------------|
|                                      |  RADAR / PRESSURE       |
|                                      |  six bars, one per      |
|                                      |  sector, 0..1           |
+---------------------------------------------------------------+
|  bottom strip: per-sector durability bars | crisis # | wave state |
+---------------------------------------------------------------+
Monitor feeds can be simplified symbolic top-down mini-views of that side (enemy blips + tracers). They do NOT need to be real 3D.

## CONFIG — put EVERY number in one object at the top
const CONFIG = {
  mainGun:   { hp: 200, projSpeed: 200, autoInterval: 2.5, manualInterval: 0.35, damage: 40 },
  subTurret: { hp: 80,  projSpeed: 150, autoInterval: 3.0, manualInterval: 0.50, damage: 15 },
  manualDpsMultiplier: 2.5,
  enemies: {
    interceptor: { hp: 30,  speed: 18, turretDps: 4,  armor: 0 },
    bomber:      { hp: 120, speed: 10, turretDps: 12, armor: 2 },
    heavy:       { hp: 300, speed: 7,  turretDps: 8,  armor: 6 },
  },
  spawnRadius: 170, attackRange: 50,
  sectorWeights: { fore: 0.25, port: 0.2, starboard: 0.2, dorsal: 0.15, ventral: 0.15, aft: 0.05 },
  waveGrowth: 1.35,
  windowFovDeg: 70,
  monitorFps: 8,
};
Also expose a LIVE TUNING PANEL (a collapsible <details> block of number inputs bound to CONFIG) so I can change any value and replay instantly without editing code.

## BENCHMARK MODE — the most important part for me
Add a "Run benchmark" button that runs the simulation headlessly, without rendering:
- Arm A "random": every refit picks turret types at random; during combat it never takes over a turret.
- Arm B "thoughtful": a fixed reasonable policy — spreads turrets toward the sectors the next-wave preview says will be pressured, and takes over the highest-pressure sector for part of each wave.
- 20 trials each. Print: average crises survived, best, worst, and a one-line verdict, e.g. `random 4.2 vs thoughtful 9.6 -> gap 5.4 (PASS)`.
This benchmark is how I judge whether the design works at all. If the gap is under ~3 crises the design FAILS — say so plainly in your report.

## The result screen must be attributable
Show which sector was breached FIRST, which was breached LAST, crises survived, total kills. The player must be able to say out loud: "I lost because I never took over the dorsal turret."

## DO NOT BUILD
Currency, shops, drops, repair, hull integrity, shields, energy/mana, skill trees, active abilities, story, characters, save files, sound, mobile support, pathfinding, or any 3D engine. No tutorial wall of text — one line of hint text is enough.

## DELIVERABLE
1. One index.html that opens and plays.
2. A short report at the end: (a) what you had to simplify or guess, (b) the benchmark numbers if you ran it, (c) the 2-3 knobs you would turn first if the random-vs-thoughtful gap is too small.
```

---

## 二、中文版（同一份，给中文平台或自己对照）

```
做一个单文件网页游戏原型：一个 index.html，纯 HTML+CSS+原生 JS，Canvas 2D，零外部库、零图片音效资源（全部用矩形/圆形/线条和文字画出来），双击打开就能玩，不需要构建。

这是「设计研究原型」不是成品游戏。优先级：① 下列机制真实存在且看得懂；② 所有数值集中可调；③ 画面美化最后。

# 游戏：星海舵手
你是一艘静止飞船的舰长，反复抵御来袭。游戏的重点是「两次战斗之间怎么给船配炮」，战斗中只需轻度操作。战斗刻意低 APM：炮塔自己会慢慢开火，玩家可选择「接管」其中一门来提速。

## 唯一的创新点：你只能看见正前方
舰桥只有一扇前向舷窗。你肉眼只能看到 fore（正前）方向的战斗。其它方向只能靠 4 块常驻小监控画面（每面一块）+ 一个紧凑雷达来了解。这个信息不对称就是本作的核心。不要给玩家六向全局视野。

## 循环 —— 单位是「危机」不是「开一局」
装配（无时限）→ 战斗（一波）→ 装配 → …… 直到所有炮塔被毁 → 结算 → 再来一次（同一艘船，保留解锁）。

## 六个扇区
fore（唯一肉眼可见）、aft（推进器尾焰，敌人几乎不来）、port、starboard、dorsal、ventral。

## 炮塔
- 主炮（1 组）：固定，只打正前。发射有飞行时间的离散弹丸（~200 m/s），命中需要打提前量。伤害最高、耐久最高（150–250），通常最后才沦陷。
- 副炮：四个方向各一组，每面可 0–N 门。单门耐久 60–100。某面副炮全灭 = 该面失守。
- 每门炮两态：
  - 自动（默认）：自己慢慢打（副炮约 3 秒一发），自动瞄准，DPS 低 —— 拖得住，赢不了。
  - 手动：玩家接管这一门，自己瞄准、射速大幅提高。同时只能接管一门。
- 每波危机开始时所有炮塔自动回满耐久，没有维修经济。

## 敌人
在扇区外缘生成 → 直线飞向飞船 → 进入攻击距离（45–60）后持续伤害最近的存活炮塔 → 该炮塔被毁则改打下一个最近的。速度刻意偏慢（6–20/秒）。三种：拦截机（快、脆、多）、轰炸机（慢、厚、对炮塔伤害高）、重甲（极厚、极慢）。

## 失败
所有炮塔被毁 = 失败。没有舰体、没有护盾、没有维修。主炮通常最后死，只因为它耐久最高 —— 这是数值自然涌现的结果，不要写成硬规则。

## 玩家只有三个动词
1. 装配（波次间）：换炮塔类型、加装炮塔 —— 这是主玩法。
2. 接管某一门炮（战斗中），每波 0–3 次。
3. 扫视：看 4 路监控 / 雷达，判断该去接管哪面。
没有移动、没有资源管理、没有下达指令、没有主动技能。想加这些就别加。

## 炮塔类型（按危机数自动解锁，无货币）
速射（高射速低单发）/ 重炮（慢、高伤、耐打）/ 散射（打多目标，克集群）/ 对空（克拦截机）/ 对重甲（克重甲）/ 范围（溅射清场）。
开局：四向各一门标准副炮 + 标准主炮。在第 3、5、7、9、11 次危机各解锁一种。成长还来自解锁「额外槽位」，让同一面能叠更多炮。

## 界面布局（照这个来）
+---------------------------------------------------------------+
|  前向舷窗（大，约 65% 宽）              |  监控 2x2              |
|  唯一实时可见的画面：                    |  [ 左舷 ][ 右舷 ]      |
|  fore 扇区、主炮弹丸、来袭敌人           |  [ 上极 ][ 下极 ]      |
|                                         |  小、低清、约 8fps     |
|  [F] 接管主炮                            |  点一下 = 接管该面视角 |
|                                         |-----------------------|
|                                         |  雷达 / 压力           |
|                                         |  六条 0..1 压力条      |
+---------------------------------------------------------------+
|  底部条：各扇区耐久条 | 危机数 | 波次状态                        |
+---------------------------------------------------------------+
监控画面可以是简化符号化的俯视小图（敌方光点 + 弹道），不需要真 3D。

## CONFIG —— 所有数值集中放在顶部一个对象里
（同英文版 CONFIG，照抄即可）
同时做一个「实时调参面板」（可折叠 <details>，数字输入框绑定 CONFIG），让我能改任意数值立刻重开一局，不用改代码。

## 基准测试模式 —— 对我最重要
加一个「跑基准」按钮，无渲染高速模拟：
- A 组「随机」：每次装配随机选炮型，战斗中从不接管。
- B 组「认真」：固定合理策略 —— 按下一波预告把炮塔调配到高压扇区，并在每波中花一部分时间接管压力最大的扇区。
- 各跑 20 次，输出：平均存活危机数、最好、最差，以及一行结论，如 `随机 4.2 vs 认真 9.6 → 差距 5.4（通过）`。
这个基准是我判断设计是否成立的唯一依据。差距小于约 3 次危机就算设计失败 —— 请在报告里直说。

## 结算必须可归因
显示：最先失守的扇区、最后失守的扇区、存活危机数、总击杀。玩家要能说出「我输在没接管上极那门炮」。

## 不要做
货币、商店、掉落、维修、舰体耐久、护盾、能量、技能树、主动技能、剧情、角色、存档、音效、移动端、寻路、3D 引擎。不要新手教程长文 —— 一行提示就够。

## 交付
1. 一个打开就能玩的 index.html。
2. 末尾简短报告：① 你简化了/猜测了什么；② 若跑了基准，数字是多少；③ 如果随机 vs 认真差距太小，你会先拧哪 2–3 个旋钮。
```

---

## 三、极简版（token 受限 / 平台输入框很短时用）

```
Make a single-file HTML5 Canvas prototype (no libraries, no assets) of a spaceship defense game. The ship is stationary and surrounded by 6 sectors; the player only SEES the forward direction through one window, and must rely on 4 small monitor feeds + a radar for the other sides. One fixed main gun covers the front; each of the 4 side sectors (port/starboard/dorsal/ventral) can hold 0-N sub turrets. All turrets auto-fire slowly by default; the player may TAKE OVER one turret at a time to fire much faster. Enemies fly in slowly, stop at range, and chew through the nearest turret's durability; a side is breached when its sub turrets all die; the run ends when every turret is destroyed. Between waves the player REFITS with no time limit, swapping among 6 turret types unlocked by crisis count (no currency). Player has only 3 verbs: fit / take over / scan. Put every number in one top-level CONFIG object and add a live tuning panel. Add a headless "benchmark" button that simulates 20 runs with a random loadout vs 20 runs with a thoughtful loadout and prints the average crises survived for each — the design only works if the gap is >= 3 crises. Keep art to plain shapes. No economy, no shields, no skills, no story.
```

---

## 四、平台适配（一行替换，别重写整份）

| 平台 | 差异 | 怎么改 |
|------|------|--------|
| **Rosebud AI** | 底层是 Phaser 3，会自己换框架 | 首句改成 `single-file HTML5 game, Phaser 3 from CDN is fine`；其余照抄。它会保留 CONFIG 与 benchmark 的概率更高 |
| **Playabl / SEELE** | 默认走 3D（Three.js/Unity） | 追加一句：`Keep it 2D top-down/abstract. Do NOT generate 3D assets or 3D models — I only need the systems.` 否则时间全花在建模上 |
| **Replit / Sider / Websim** | 原生 HTML 输出 | 英文版原样贴即可 |
| **Websim** | 输出不稳定 | 先发极简版，跑通后再把完整版作为第二轮追问 |

通用追加句（第二轮追问时贴）：
```
Now add: (1) a visible pressure bar per sector, (2) a one-line hint text, (3) the result screen showing which sector was breached first. Keep CONFIG and the benchmark intact.
```

---

## 五、拿回结果后，我们看什么（对照本项目三条假设）

| 本项目假设 | 在网页原型上怎么判 | 过关线 |
|-----------|------------------|--------|
| **P-3（最关键）随机 vs 认真** | 点 benchmark，看两个数字 | 差距 ≥ 3 危机。AI 给的默认值大概率不过关 —— 那正好是我们回头拧 `manualDpsMultiplier` / `autoInterval` / `sectorWeights` 的入口 |
| **P-2 监控真的被看** | 你自己玩 5 分钟，记录眼睛有没有主动去看那 4 块小窗 | 若全程只盯主画面 → 信息不对称没做成，说明 forward window 视野要收窄或非正向来袭比例要提高 |
| **P-1 接管有张力** | 接管和不接管的手感差 | 接管后压力条肉眼可见地掉 |

**平台能力本身也值得打分**（这才是我让你去试的另一半目的）：
代码是否一次跑通 / CONFIG 是否真的外置（能不能现场改数）/ benchmark 这种"非游戏逻辑"它做不做得到 / 它敢不敢按"不要做"清单砍东西。**第四项最能看出差距** —— 大部分生成器会忍不住加金币和技能树。
