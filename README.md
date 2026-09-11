# WinFix

WinFix 是一个用于 Windows 电脑维护的 Codex skill。你只需要描述遇到的问题，它会先检查本机状态，再根据证据给出清理、修复或优化建议。

它的原则是“先诊断，再处理”：先收集磁盘、内存、网络、驱动、事件日志等信息，再解释问题原因，优先选择低风险方案，并在操作后做验证。默认不会静默删除用户文件，也不会直接修改系统关键设置。

## 能解决什么

- C 盘空间不足、大文件定位、临时文件和缓存清理
- 内存占用高、进程排查、开机启动项分析
- Chrome、Edge、VS Code、微信以及普通软件卡顿或打不开
- 网络、代理、DNS、HTTP 连通性检查
- Windows 更新、驱动、设备、声音、显示器、打印机问题
- WSL、Docker、Android、Flutter、Java、Node、Python、Git 开发环境检查
- 蓝屏、自动重启、卡死、闪退等事件日志线索分析
- Defender 和防火墙状态检查

## 安装

从 GitHub 安装：

```powershell
npx skills add xinghe-labs/winfix -g
```

也可以手动复制到 Codex skills 目录：

```powershell
Copy-Item -Recurse . "$env:USERPROFILE\.agents\skills\winfix"
```

安装后，可以这样问 Codex：

```text
帮我分析 C 盘空间
Chrome 内存占用很高
这个 API 地址访问不了
电脑刚才自动重启了
安卓开发环境能不能用
```

## 直接运行脚本

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode health
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode disk -Format json
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode net-test -Target "https://www.microsoft.com"
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode app -ProcessName chrome
```

## 安全边界

默认情况下，WinFix 只做只读检查。除非用户明确确认，否则它不会删除用户文件、注销 WSL 发行版、清理 Docker 卷、修改注册表、卸载驱动、调整安全设置，也不会运行系统修复命令。

高风险区域包括：下载、桌面、文档、聊天文件、浏览器配置、SSH/API 密钥、Docker 卷、WSL 发行版、驱动、注册表、BitLocker、磁盘分区和 Windows 安全设置。

## 兼容性

已在 Windows PowerShell 环境下测试。部分诊断命令会受到 Windows 版本、PowerShell 版本和权限影响；如果某些工具不可用，脚本会尽量降级处理，而不是直接中断。

## 主要文件

- `SKILL.md`
- `scripts/inspect_windows.ps1`
- `references/safety.md`
- `references/issue-routes.md`
- `references/release-checklist.md`
- `evals/evals.json`


