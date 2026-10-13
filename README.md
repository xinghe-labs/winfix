# WinFix

[![CI](https://github.com/xinghe-labs/winfix/actions/workflows/ci.yml/badge.svg)](https://github.com/xinghe-labs/winfix/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![no telemetry](https://img.shields.io/badge/telemetry-none-brightgreen.svg)

WinFix 是一个用于 Windows 电脑维护的 agent skill。你只需要描述遇到的问题，它会先检查本机状态，再根据证据给出清理、修复或优化建议。

它的原则是"先诊断，再处理"：先收集磁盘、内存、网络、驱动、事件日志等证据，再解释问题原因，优先选择低风险方案，并在操作后做验证。默认不会静默删除用户文件，也不会直接修改系统关键设置。

## 和一般"清理工具"的区别

- **健康分**：一条命令给出 0-100 的机器健康分，七个组件各自打分并附实测证据（磁盘余量、内存压力、系统错误事件与问题设备、物理磁盘健康、开机耗时、启动项数量、更新新鲜度、实时防护），并直接点名"最该修的那一项"（按 权重 × 缺口 排序，而不是单纯看谁分数低）。数据不可用的组件自动剔除、权重重归一化，不装样子。安全那一项读的是 Defender 运行模式加上 SecurityCenter2 里注册的杀软，所以装了火绒/360 这类第三方杀软时不会被误报成"防护关闭"；事件数来自有上限的查询，所以写成 `50+ (capped)` 而不是伪装成精确总数。
- **磁盘健康**：`smart` 模式读物理磁盘/卷的 HealthStatus、OperationalStatus 和 SMART 计数器（计数器通常需要管理员，脚本会如实说明"没权限"而不是假装磁盘健康）。
- **基线与对比**：它记得你的机器长什么样。`baseline` 存一份快照（含启用的非微软计划任务），之后任何时刻 `compare` 都能告诉你：这段时间哪个盘少了多少空间、多了哪些开机启动项和计划任务、异常服务数量变化。"感觉电脑变卡了"从此不再是玄学。为了避免无意义的重复快照把历史冲掉，**15 分钟内且状态没实质变化（每个盘变动 < 200MB、启动项一致、重启状态一致）时不会重复保存**，会明确告诉你"没保存、因为没变"；确实想存就加 `-Force`。
- **大文件定位**：`files` 模式按大小列出目录下的最大文件（含修改日期），补上"只知道占空间、不知道是哪个文件"的最后一公里。
- **一条命令自证安全**：`self-test` 逐项断言安全契约（临时目录白名单、凭据脱敏、24 小时跳过、junction 不穿透、基线位置、路由回归、安全态势分支、版本一致），任何一项失败就退出码非零。其中五条是**端到端**的：在子进程里把临时目录重定向到沙箱、跑真实的 `cleanup-temp` 分发器，证明"不加 `-Apply` 就什么都删不掉"；再对同一沙箱跑真实的删除函数，证明过期项被清、24 小时内的项保留、junction 目标不受影响。
- **开机耗时分析**：从系统诊断日志读取最近几次真实开机时长，纳入健康分（日志不可用时自动跳过，不猜数）。
- **WSL/Docker 虚胖检测**：从注册表读取每个发行版的真实 BasePath（自定义安装路径也能找到），给出每个 vhdx 的大小和安全的收缩路线（含管理员边界和备份提醒）。
- **零依赖**：单个 PowerShell 脚本，全部使用 Windows 内置命令，不捆绑任何 EXE，不需要管理员权限即可完成全部只读诊断。

## 能解决什么

- C 盘空间不足、大文件定位、临时文件和缓存清理（含回收站、崩溃转储、错误报告、更新残留）
- 内存占用高、进程排查、开机启动项与计划任务分析、开机耗时
- Chrome、Edge、VS Code、微信以及普通软件卡顿或打不开
- 网络、代理（WinHTTP + 系统代理）、DNS、HTTP 连通性检查与故障分类
- Windows 更新、驱动、设备、声音、显示器、打印机问题
- 硬盘健康、SMART、坏道怀疑
- WSL、Docker、Android、Flutter、Java、Node、Python、Git 开发环境检查（含"哪些工具没装/版本不对"的结论）
- 蓝屏、自动重启、卡死、闪退等事件日志线索分析
- Defender 和防火墙状态检查
- "电脑最近变卡了"——和上个月的基线对比，差异说话
- 分析每个文件夹是干什么的、能不能清——内置目录知识库，未知目录走排查流程而不是猜

## 安装

推荐：一条命令，直接克隆进用户级共享 skill 目录，路径写死，不指定宿主。`%USERPROFILE%\.agents\skills\` 是 Agent Skills 的通用约定目录，ZCode、Claude Code 等宿主都从这里读取，装一份全局生效：

```powershell
git clone --depth 1 https://github.com/xinghe-labs/winfix.git "$env:USERPROFILE\.agents\skills\winfix"
```

- 更新：进入该目录 `git pull`（见下方"更新与版本"）。
- 备选，用 skills CLI 代管：`npx skills add xinghe-labs/winfix -g` 会自动铺到检测到的所有宿主，之后用 `npx skills update winfix` 统一更新；只想装指定宿主就加 `-a`，例如 `npx skills add xinghe-labs/winfix -a codex -y` 装到 `%USERPROFILE%\.codex\skills\winfix`。
- 备选，手动复制：把仓库内容复制成 `%USERPROFILE%\.agents\skills\winfix`，目录内含 `SKILL.md` 即可。

安装后，可以这样问 agent：

```text
给电脑打个健康分
帮我分析 C 盘空间
D 盘哪的文件大
感觉电脑最近变卡了
WSL 是不是把 C 盘吃满了
Chrome 内存占用很高
这个 API 地址访问不了
```

## 直接运行脚本

```powershell
powershell -ExecutionPolicy Bypass -File "<skill-root>\scripts\inspect_windows.ps1" -Mode health
powershell -ExecutionPolicy Bypass -File "<skill-root>\scripts\inspect_windows.ps1" -Mode baseline
powershell -ExecutionPolicy Bypass -File "<skill-root>\scripts\inspect_windows.ps1" -Mode baseline -Force
powershell -ExecutionPolicy Bypass -File "<skill-root>\scripts\inspect_windows.ps1" -Mode compare
powershell -ExecutionPolicy Bypass -File "<skill-root>\scripts\inspect_windows.ps1" -Mode disk -Format json
powershell -ExecutionPolicy Bypass -File "<skill-root>\scripts\inspect_windows.ps1" -Mode disk -Deep
powershell -ExecutionPolicy Bypass -File "<skill-root>\scripts\inspect_windows.ps1" -Mode files -Path "D:\Projects" -MinSizeMB 200
powershell -ExecutionPolicy Bypass -File "<skill-root>\scripts\inspect_windows.ps1" -Mode smart
powershell -ExecutionPolicy Bypass -File "<skill-root>\scripts\inspect_windows.ps1" -Mode net-test -Target "https://www.microsoft.com"
powershell -ExecutionPolicy Bypass -File "<skill-root>\scripts\inspect_windows.ps1" -Mode app -ProcessName chrome
powershell -ExecutionPolicy Bypass -File "<skill-root>\scripts\inspect_windows.ps1" -Mode self-test
```

所有模式都支持 `-Format json`（核心模式是原生结构化 JSON，其余模式按 `=== 标题 ===` 切成 `sections`），而且 JSON 模式只输出 ASCII（非 ASCII 字符转成 `\uXXXX`），所以中文路径不会被中间层的代码页弄坏；JSON 模式下 stderr 保持为空，`2>&1` 不会污染结果。

健康分输出示例（真实机器）：

```text
Version       : 0.3.1
Score         : 32
PendingReboot : True

Component Score Weight Measured
--------- ----- ------ --------
disk         38     30 min drive free 12.7%
memory       59     25 memory used 74.5%
stability     0     15 50 critical/error events in 3d; 0 problem devices; 0 unhealthy disks
startup      65     10 15 startup items
updates     100      5 last hotfix 13 days ago
security      0      5 Defender real-time off

Biggest lever: disk (min drive free 12.7%)
```

基线对比示例（"感觉变卡了"时跑 `compare`）：

```text
Baseline: 2026-09-19T12:10:06   Now: 2026-09-19T12:10:10
=== Drive free-space change ===

Drive Before    Now       Change
----- ------    -------   --------
C:    23.18 GB  23.18 GB  -69632 B
D:    59.25 GB  59.25 GB  0 B

=== Startup items ===
added: 0   removed: 0
```

临时清理预览示例（不加 `-Apply` 永远只预览）：

```text
=== Temp cleanup preview ===
Nothing has been deleted. Add -Apply to execute the plan below.

Root              Allowed WouldDeleteEntries WouldFree SkippedRecent24h SkippedLinks
----              ------- ------------------ --------- ---------------- ------------
C:\Windows\Temp      True                 31 23.25 MB               27            0
D:\Temp              True                120 355.37 MB               14            2
```

被重定向到其它盘的 `%TEMP%` 也能清（只要目录名是 `temp`/`tmp`），而 `C:\`、`C:\Windows`、用户目录会被直接拒绝。

磁盘候选输出示例（每个候选项都是 `大小 | 风险 | 是什么 | 完整路径`，并标明数字是 `full`/`sampled`/`partial`）：

```text
1.03 GB  [low]  Chrome 缓存 (Profile 21)
    C:\Users\you\AppData\Local\Google\Chrome\User Data\Profile 21\Service Worker
983.82 MB  [low]  回收站
    C:\$Recycle.Bin
723.19 MB  [low]  npm 包缓存
    C:\Users\you\AppData\Local\npm-cache
```

## 更新与版本

- git 克隆到 `.agents\skills` 的（推荐方式）：进入 skill 目录 `git pull`；若提示 unrelated histories，说明没有本地改动，`git fetch` 后 `git reset --hard origin/main`
- 通过 skills CLI 安装的：`npx skills update winfix`
- 手动复制的：重新复制覆盖
- 当前运行版本看 `health` 输出的 `Version` 字段，与 [CHANGELOG.md](CHANGELOG.md) 对照

## 安全边界

默认情况下，WinFix 只做只读检查。安全边界不是承诺，是代码路径 —— 你可以一条命令自己验证：

```powershell
powershell -ExecutionPolicy Bypass -File "<skill-root>\scripts\inspect_windows.ps1" -Mode self-test
```

它会逐项断言：临时目录白名单（接受重定向的 `%TEMP%`，拒绝磁盘根/`C:\Windows`/用户目录）、凭据脱敏、24 小时跳过、junction 不被列入删除计划、基线目录位置、症状路由回归、脚本版本与 CHANGELOG 一致。任何一项失败都打印 FAIL 并以非零退出码结束。

下面这些不是姿态，是同一个脚本里可以逐行核对、并且被 CI 强制检查的事实：

- 整个脚本里能**删除**用户文件的模式只有一个：`-Mode cleanup-temp`。而且它默认只输出预览，必须显式加 `-Apply` 才会执行；删除根来自白名单（`%LOCALAPPDATA%\Temp`、`C:\Windows\Temp`，以及目录名是 `temp`/`tmp` 的重定向 `%TEMP%`/`%TMP%`），磁盘根目录/`C:\Windows`/用户目录一律拒绝；自动跳过 24 小时内修改过的文件（不弄崩正在跑的安装程序）；目录软链接（junction/symlink）永不穿透删除，删除前还会再校验一次父目录。
- 能**写入**文件的地方只有两处：基线快照存到你自己的 `~\.winfix\baselines\` 目录（只保留最近 20 份），以及 `self-test` 在自己创建的 `%TEMP%\winfix-selftest-*` 沙箱里建/删自己的测试文件。
- 至于下载、桌面、文档、微信文件、浏览器配置、SSH/API 密钥这些高风险区——脚本里不存在能触及它们的代码路径。这不是姿态，是源码里可以逐行核对的事实，CI 还会用 AST 检查 `Remove-Item` 只出现在允许的函数里。
- 扫描是**有上限**的：每个目录 20000 个文件 / 6 秒，每个 section 45 秒，不穿透目录软链接；每个数字都标 `full`/`sampled`/`partial`/`missing`，不会把"采样值"当"精确值"报给你。

除非用户明确确认，否则它不会注销 WSL 发行版、清理 Docker 卷、修改注册表、卸载驱动、调整安全设置，也不会运行系统修复命令。

另外三条硬事实：脚本自身**零网络行为**（`net-test` 只在你显式给地址时才测试那个地址）、**零遥测零自动更新**（不上报任何数据、不下载任何内容）、输出**自动脱敏**（代理和 URL 里内嵌的凭据会替换成 `***`）。完整的威胁模型和「不信任我们就自己跑一遍」的验证命令见 [SECURITY.md](SECURITY.md)。

高风险区域包括：下载、桌面、文档、聊天文件、浏览器配置、SSH/API 密钥、Docker 卷、WSL 发行版、驱动、注册表、BitLocker、磁盘分区和 Windows 安全设置。

## 常见问题

**会误删我的文件吗？**
不会。全脚本只有 `cleanup-temp` 能删东西，而且默认只预览，不加 `-Apply` 不执行；范围只限临时目录白名单，24 小时内改过的文件跳过，junction 不穿透。不放心就跑 `-Mode self-test` 自己验一遍。

**需要管理员权限吗？**
只读诊断不需要。少数项（SMART 计数器、Windows 组件存储）没权限时会直说“不可用”，不会假装读到了。

**会联网吗？**
脚本自身零网络请求，零遥测，零自动更新。`net-test` 只在你显式给地址时测那一个地址。

**支持 Windows 10 吗？**
Win10 / Win11 + PowerShell 5.1 或 7 都测过。数据源缺失时（比如开机性能日志被禁）对应组件自动剔除并在分数里重归一化，不猜数。

## 兼容性

已在 Windows PowerShell 5.1 与 PowerShell 7（Windows 10/11，中文控制台）上测试。部分诊断命令受 Windows 版本、PowerShell 版本和权限影响；某些数据源不存在时（如开机性能日志被禁用、SMART 计数器需要管理员），对应组件自动跳过或如实标注不可用，而不是报错中断。

外部命令一律带超时（默认 20 秒，`flutter` 90 秒），卡住会返回"超时"而不是永远挂着；输出编码按字节嗅探（wsl.exe 是 UTF-16LE、netsh/powercfg 是 OEM 代码页、curl 是 UTF-8），不再假设一种编码。

## 社区

本项目在 [LINUX DO 社区](https://linux.do) 发布与交流，感谢佬友们的反馈与监督。
Issue 与 PR 同样欢迎：https://github.com/xinghe-labs/winfix/issues

## 主要文件

- [`SKILL.md`](SKILL.md) —— agent 读的路由与契约
- [`scripts/inspect_windows.ps1`](scripts/inspect_windows.ps1) —— 唯一的可执行文件（UTF-8 with BOM，Windows PowerShell 5.1 需要）
- [`references/safety.md`](references/safety.md) / [`known-folders.md`](references/known-folders.md) / [`issue-routes.md`](references/issue-routes.md) / [`release-checklist.md`](references/release-checklist.md)
- [`evals/evals.json`](evals/evals.json) —— 预期行为用例（CI 校验）
- [`SECURITY.md`](SECURITY.md) —— 威胁模型与自审命令
- [`CONTRIBUTING.md`](CONTRIBUTING.md) —— 改动原则与本地验证
- [`LICENSE`](LICENSE) —— MIT
