---
name: winfix
description: Use when the user asks Codex to inspect, diagnose, clean, repair, or optimize a Windows PC, including disk space, performance, memory, startup, crashes, blue screen clues, Windows Update, drivers, devices, audio, display, printers, security, browser/app issues, WeChat files, WSL/Docker/VM leftovers, proxy/network checks, and developer environment readiness.
---

# WinFix

## Overview

Use this skill for Windows machine care where local state matters. The user may only describe a symptom; translate that symptom into a diagnosis route, gather evidence, then fix or propose the safest next action. It covers common Windows problems, but not physical repair, warranty service, or unsupported third-party account recovery.

## Operating Rules

- Start with inspection unless the user explicitly gives a precise cleanup target.
- If the user gives only a problem statement, do not ask for a checklist up front. Pick the most likely route and inspect.
- Treat user data as precious: documents, downloads, desktop files, chat files, browser profiles, SSH keys, API keys, and project folders are not cleanup targets without explicit approval.
- Prefer moving to a dated quarantine folder or using application-safe cleanup commands before permanent deletion.
- Explain each cleanup class as: what it is, whether it is safe, impact after cleaning, and how to restore or regenerate.
- Avoid full-drive recursive scans when a bounded scan is enough. On large folders, sample top-level sizes first.
- On Windows, use PowerShell-native commands for file operations. Do not pipe computed paths into `cmd /c` deletion commands.
- Before recursive deletion, resolve the absolute path and verify it is inside the intended target directory.

## Quick Workflow

1. Identify the task category: disk, performance, memory/process, browser, app cache, developer environment, network/proxy, update/driver/device, audio/display/print, security, crash logs, or software leftovers.
2. Run a read-only inspection first. Prefer the bundled script:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode overview
```

For a broad health check before narrowing:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode health
```

Prefer JSON when the next step needs structured reasoning or comparison:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode health -Format json
```

3. Summarize findings with sizes, paths, and risk levels.
4. Propose cleanup actions grouped by risk.
5. Only clean after the user asks to proceed or already requested cleanup directly.
6. Verify by rerunning the relevant inspection and comparing before/after.

For vague symptom prompts, use `-Mode issue`:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode issue -Issue "用户原话"
```

## Symptom Router

| User says | Inspect with | First answer should include |
|---|---|---|
| C 盘空间不够、哪些可以清理、电脑变满 | `-Mode disk`, then `-Mode large` if needed | top candidates, risk level, expected reclaimed space |
| Chrome/Edge 内存高、浏览器卡 | `-Mode chrome`, optionally `-Mode memory` | process count, memory total/top process, cache/profile risk |
| VS Code 点不了、WebView 报错、插件问题 | `-Mode vscode` | Code processes, cache folders, extension size, whether Code must be closed |
| 微信/企业微信文件太大 | `-Mode wechat` | distinguish received files from cache; ask before deleting |
| 安卓/Flutter/Java/adb 环境能不能用 | `-Mode android` and `-Mode dev` | readiness verdict and exact missing tools/env vars |
| 代理、网络、API 连不上 | `-Mode network` | env proxies, WinHTTP proxy, test endpoint result |
| 某网站/API/下载地址打不开 | `-Mode net-test -Target <url-or-host>` | DNS, proxy state, HTTP headers/errors |
| 某个软件卡、闪退、打不开 | `-Mode app -ProcessName <name>` plus `-Mode events` if needed | matching processes and recent app errors |
| WSL/Ubuntu/Linux 占空间或坏了 | `-Mode wsl` | distro list, status, deletion/export warning |
| Docker/镜像/容器占空间 | `-Mode docker` | Docker availability, `docker system df`, volume warning |
| 蓝屏、自动重启、闪退、卡死 | `-Mode events`, then `-Mode drivers` if device-related | recent critical/error events, likely failing provider |
| 开机慢、启动项太多 | `-Mode startup`, optionally `-Mode services` | startup entries, non-running automatic services |
| Windows 更新失败 | `-Mode updates` | recent hotfixes, update services status, admin repair commands if needed |
| 驱动/设备异常、USB 不识别 | `-Mode devices` or `-Mode drivers` | problem devices and error codes |
| 没声音、麦克风、扬声器问题 | `-Mode audio` | audio devices and audio service status |
| 黑屏、分辨率、显卡、外接屏 | `-Mode display` | GPU driver, monitor status |
| 打印机不能打印 | `-Mode printer` | printer state and spooler status |
| 病毒、防火墙、Defender | `-Mode security` | Defender and firewall status |
| 电池、睡眠、耗电、无法休眠 | `-Mode power` | battery, active power plan, sleep states |
| 系统文件损坏、需要修复 | `-Mode repair-check` | read-only repair commands and admin boundary |
| 不知道哪里占空间 | `-Mode overview`, then `-Mode large` | broad triage and next narrow scan |

## Task Routes

### C Drive Space

Check:
- drive free space
- largest user folders
- `%TEMP%`, `C:\Windows\Temp`
- browser caches
- package caches: npm, pip, pnpm, yarn, Gradle, Maven
- VM/runtime bundles: Docker, WSL, Android emulator, large app local data

Use:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode disk
```

Report top candidates; do not delete from `Downloads`, `Desktop`, `Documents`, or chat file folders without explicit user approval.

If the user asks to clean immediately, low-risk temp cleanup can use:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode cleanup-temp
```

Then rerun `-Mode disk`.

### Chrome High Memory

Check:
- Chrome process count and total working set
- top Chrome child processes when available
- running extensions if browser automation can inspect them
- tab count and profile cache size

Safe first actions:
- close unused tabs/windows
- restart Chrome after saving work
- clear cache only, not passwords/cookies, unless requested
- disable suspicious extensions only after naming them

Use:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode chrome
```

### VS Code Or WebView Problems

Check:
- `Code.exe` processes
- extension count and largest extension folders
- Service Worker, Cache, CachedData, Code Cache, GPUCache

If clearing WebView/cache, stop Code first. Preserve settings, keybindings, snippets, and extension lists unless the user explicitly asks for a reset.

Use:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode vscode
```

### WeChat And Chat Files

WeChat paths often contain important received files. Never bulk-delete message files. Prefer:
- identify large folders
- separate cache/media/temp from user documents
- ask before deleting received files or chat history

Use:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode wechat
```

### Developer Environment Readiness

For environment checks, inspect actual commands and versions:

```powershell
node -v; npm -v; python --version; pip --version; git --version
java -version; adb version; flutter --version; docker --version
```

For Android development, also check:
- `ANDROID_HOME`, `ANDROID_SDK_ROOT`, Java version
- `adb devices`
- Android SDK platform-tools path
- emulator/AVD disk usage
- `flutter doctor -v` when Flutter readiness is the actual question

Return a readiness verdict: supported, partially supported, or blocked, with exact missing pieces.

Use:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode android
```

### Network And Proxy

Check:
- WinHTTP proxy: `netsh winhttp show proxy`
- environment proxies: `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`
- app-specific proxy settings if the app is named
- `curl.exe -I` to a known endpoint

Do not remove a working proxy blindly. If proxy caused a failure, preserve current values before changing them.

Use:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode network
```

If a host or URL is known, test it directly:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode net-test -Target "https://example.com"
```

### Any App Problem

When the user names an app that does not have a dedicated route, inspect the process and application event log:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode app -ProcessName "appname"
```

Use process names without `.exe` when possible, such as `chrome`, `Code`, `WeChat`, `QQ`, `Photoshop`, or `java`.

### System, Crash, Update, Driver, Device

Use these routes when the symptom is broad, intermittent, or system-level:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode system
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode events
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode startup
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode services
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode drivers
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode updates
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode devices
```

For system repair, start read-only:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode repair-check
```

Do not run `sfc /scannow`, `DISM /RestoreHealth`, driver removal, registry edits, service resets, or Windows Update component resets without explaining the risk and whether admin PowerShell is required.

### Hardware And Peripherals

Use narrow hardware routes before changing settings:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode audio
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode display
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode printer
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode power
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode security
```

If diagnostics point to physical failure, overheating, swollen battery, disk SMART failure, repeated BSOD with hardware codes, or no power/no display before Windows loads, report that software repair is insufficient and suggest hardware service or vendor diagnostics.

### WSL And Docker

For WSL, never run `wsl --unregister` unless the user explicitly confirms the distro name and accepts that Linux files will be deleted. For Docker, explain that volumes can contain databases and project state.

Use:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode wsl
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode docker
```

## Cleanup Risk Levels

| Level | Examples | Default action |
|---|---|---|
| Low | temp files, old logs, browser HTTP cache, package download cache | Can clean after user asks |
| Medium | app caches, old build outputs, Docker unused data, Android emulator images | Explain impact first |
| High | Downloads, Desktop, Documents, WeChat received files, browser profile, SSH/API keys, source repos | Ask for explicit path-level approval |
| Admin | Windows component store, system restore, feature removal, DISM, WSL feature disable | Explain admin requirement and risk |

Read `references/safety.md` when planning non-trivial cleanup or when user asks "哪些可以清理".
Read `references/issue-routes.md` when the problem is vague or multi-symptom.
Read `references/release-checklist.md` before packaging or publishing this skill.

## Output Format

Use concise Chinese by default:

```text
结论：...

证据：
- ...

可清理：
- 路径：...
  大小：...
  风险：低/中/高
  影响：...
  建议：清理/保留/先备份

不建议动：
- ...

下一步：...
```

For non-cleanup problems, use:

```text
结论：...
最可能原因：...
证据：...
建议修复：
1. ...
风险/影响：...
验证方式：...
```

For command output, relay the important lines because the user may not see terminal output.

## Fix Policy

- If the fix only deletes low-risk temp files and the user asked "帮我清理", perform it and verify.
- If the fix closes apps, removes caches that cause login/session impact, disables extensions, changes proxy, unregisters WSL, prunes Docker volumes, or deletes user-visible files, explain and ask for confirmation.
- If the fix changes drivers, services, startup entries, firewall, Defender, registry, Windows Update components, boot settings, BitLocker, partitions, or power firmware settings, ask for explicit confirmation and prefer a restore point/backup.
- If admin rights are required, give exact commands and say they must be run in an elevated PowerShell.
- If a scan times out, report partial findings and narrow the next scan instead of repeating the same broad scan.

## Common Mistakes

- Mistaking cache cleanup for account/profile reset. Cache is usually safe; profile data is not.
- Counting `%TEMP%` and `C:\Windows\Temp` twice when environment variables resolve unexpectedly.
- Scanning the whole drive recursively before checking known high-yield locations.
- Deleting browser cookies or WeChat files under the label "cache".
- Reporting "cleaned" without rerunning size or process checks.
- Publishing changes without running `quick_validate.py`, JSON smoke tests, and the safety eval prompts.

