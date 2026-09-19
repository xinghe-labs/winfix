# WinFix

WinFix 是一个用于 Windows 电脑维护的 agent skill。你只需要描述遇到的问题，它会先检查本机状态，再根据证据给出清理、修复或优化建议。

它的原则是"先诊断，再处理"：先收集磁盘、内存、网络、驱动、事件日志等证据，再解释问题原因，优先选择低风险方案，并在操作后做验证。默认不会静默删除用户文件，也不会直接修改系统关键设置。

## 和一般"清理工具"的区别

- **健康分**：一条命令给出 0-100 的机器健康分，六个组件各自打分并附实测证据（磁盘余量、内存压力、系统错误事件、开机耗时、启动项数量、更新新鲜度），最薄弱项直接点名。数据不可用的组件自动剔除、权重重归一化，不装样子。
- **基线与对比**：它记得你的机器长什么样。`baseline` 存一份快照，之后任何时刻 `compare` 都能告诉你：这段时间哪个盘少了多少空间、多了哪些开机启动项、异常服务数量变化。"感觉电脑变卡了"从此不再是玄学。
- **开机耗时分析**：从系统诊断日志读取最近几次真实开机时长，纳入健康分（日志不可用时自动跳过，不猜数）。
- **WSL/Docker 虚胖检测**：定位每个发行版和 Docker 的 vhdx 虚拟磁盘文件——它们只涨不缩，脚本会给出安全的收缩路线（含管理员边界和备份提醒）。
- **零依赖**：单个 PowerShell 脚本，全部使用 Windows 内置命令，不捆绑任何 EXE，不需要管理员权限即可完成全部只读诊断。

## 能解决什么

- C 盘空间不足、大文件定位、临时文件和缓存清理
- 内存占用高、进程排查、开机启动项分析、开机耗时
- Chrome、Edge、VS Code、微信以及普通软件卡顿或打不开
- 网络、代理、DNS、HTTP 连通性检查
- Windows 更新、驱动、设备、声音、显示器、打印机问题
- WSL、Docker、Android、Flutter、Java、Node、Python、Git 开发环境检查
- 蓝屏、自动重启、卡死、闪退等事件日志线索分析
- Defender 和防火墙状态检查
- "电脑最近变卡了"——和上个月的基线对比，差异说话

## 安装

从 GitHub 安装：

```powershell
npx skills add xinghe-labs/winfix -g
```

也可以手动复制到 Codex skills 目录：

```powershell
Copy-Item -Recurse . "$env:USERPROFILE\.agents\skills\winfix"
```

安装后，可以这样问 agent：

```text
给电脑打个健康分
帮我分析 C 盘空间
感觉电脑最近变卡了
WSL 是不是把 C 盘吃满了
Chrome 内存占用很高
这个 API 地址访问不了
```

## 直接运行脚本

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode health
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode baseline
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode compare
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode disk -Format json
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode net-test -Target "https://www.microsoft.com"
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode app -ProcessName chrome
```

健康分输出示例（真实机器）：

```text
Score         : 33
PendingReboot : True

Component Score Weight Measured
--------- ----- ------ --------
disk         34     30 min drive free 11.7%
memory       61     25 memory used 73.5%
stability     0     15 21 critical/error events in 3d; 0 problem devices
startup      65     10 15 startup items
updates     100      5 last hotfix 5 days ago

Weakest component: stability (21 critical/error events in 3d)
```

## 安全边界

默认情况下，WinFix 只做只读检查。安全边界不是承诺，是代码路径：

- 整个脚本里能**删除**文件的模式只有一个：`-Mode cleanup-temp`。而且它默认只输出预览，必须显式加 `-Apply` 才会执行；执行时只允许 `%TEMP%` 和 `C:\Windows\Temp` 两个精确根目录，并自动跳过 24 小时内修改过的文件（不弄崩正在跑的安装程序）。
- 能**写入**文件的地方只有一处：基线快照存到你自己的 `~\.winfix\baselines\` 目录。
- 至于下载、桌面、文档、微信文件、浏览器配置、SSH/API 密钥这些高风险区——脚本里不存在能触及它们的代码路径。这不是姿态，是源码里可以逐行核对的事实。

除非用户明确确认，否则它不会注销 WSL 发行版、清理 Docker 卷、修改注册表、卸载驱动、调整安全设置，也不会运行系统修复命令。

高风险区域包括：下载、桌面、文档、聊天文件、浏览器配置、SSH/API 密钥、Docker 卷、WSL 发行版、驱动、注册表、BitLocker、磁盘分区和 Windows 安全设置。

## 兼容性

已在 Windows PowerShell 环境下测试（Windows 10/11，中文控制台）。部分诊断命令受 Windows 版本、PowerShell 版本和权限影响；某些数据源不存在时（如开机性能日志被禁用），对应组件自动跳过而不是报错中断。

## 主要文件

- `SKILL.md`
- `scripts/inspect_windows.ps1`
- `references/safety.md`
- `references/issue-routes.md`
- `references/release-checklist.md`
- `evals/evals.json`
