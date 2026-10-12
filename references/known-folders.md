# 目录知识库（known-folders）

分析"这个文件夹是做什么的、能不能清理"时，先查本文件。**匹配不到的一律按
文末「未知目录排查流程」处理，绝不猜测用途、绝不建议盲删。**

约定：风险=清理的风险等级；「可再生」= 删除后由工具/系统自动重建或重新下载。

## 系统核心（勿动）

| 路径 | 是什么 | 风险 |
|---|---|---|
| `C:\Windows`、`System32` | 系统本体 | 不可清理 |
| `C:\Windows\WinSxS` | 组件存储 | 只能用 `DISM /Online /Cleanup-Image /StartComponentCleanup`，勿手删 |
| `C:\Windows\Installer` | MSI 安装包缓存 | 勿删：删了软件将无法卸载/修复 |
| `C:\Windows\System32\DriverStore` | 驱动仓库 | 勿删 |
| `C:\Users\<用户>`（已知缓存除外） | 用户数据 | 高风险 |

## 系统管理（改设置，不是删文件）

| 路径 | 是什么 | 说明 |
|---|---|---|
| `pagefile.sys` / `swapfile.sys` / `hiberfil.sys`（盘根） | 虚拟内存/快速启动/休眠 | 通过系统设置调整，删除会导致异常 |
| `System Volume Information` | 系统还原点 | 还原点在"系统保护"里管理 |
| `C:\Windows.old` | 旧系统备份 | 磁盘清理的"以前的 Windows 安装"或 10 天后自动清；删后无法回退旧版本 |
| `C:\Windows\WinSxS` | 组件存储 | 用 `DISM /Online /Cleanup-Image /AnalyzeComponentStore` 看可回收量，再用 `StartComponentCleanup`；勿手删 |

## 低风险可清理（可再生）

| 路径 | 是什么 | 清理方式 |
|---|---|---|
| `%TEMP%`、`%LOCALAPPDATA%\Temp`、`C:\Windows\Temp` | 临时文件 | `cleanup-temp`（预览 → -Apply，24h 保护，junction 不穿透） |
| `%LOCALAPPDATA%\CrashDumps` | 程序崩溃转储 | 可删；下次崩溃会重建（经常是几个 GB 的无名大户） |
| `%LOCALAPPDATA%\Microsoft\Windows\WER`、`C:\ProgramData\Microsoft\Windows\WER` | Windows 错误报告 | 可删；只影响错误上报 |
| `%LOCALAPPDATA%\Microsoft\Windows\INetCache` | 系统/IE 网络缓存 | 可删 |
| `C:\Windows\Logs`、`C:\PerfLogs` | 系统日志 / 性能计数器日志 | 可清旧日志，不影响运行 |
| `C:\Windows\SoftwareDistribution\Download` | Windows 更新下载缓存 | 停 `wuauserv` 后清，自动重建 |
| `C:\Windows\Prefetch` | 预读缓存 | 会自动重建，收益小，不建议频繁清 |
| `C:\$Recycle.Bin` | 回收站 | 确认无需恢复后清空 |
| `DeliveryOptimization`（任意盘） | 传递优化缓存 | 磁盘清理或设置里清 |
| `npm-cache` / `%APPDATA%\npm-cache` / `%LOCALAPPDATA%\npm-cache` | npm 包缓存 | `npm cache clean --force` |
| `%LOCALAPPDATA%\pip\Cache` | pip 缓存 | `pip cache purge` |
| `pnpm\store` / `.pnpm-store` | pnpm 仓库 | `pnpm store prune` |
| `%LOCALAPPDATA%\Yarn\Cache` | Yarn 包缓存 | 可删，下次安装重下 |
| `%LOCALAPPDATA%\NuGet\v3-cache` | NuGet HTTP 缓存 | 可删 |
| `AppData\Local\go-build` | Go 编译缓存 | `go clean -cache` |
| `.gradle\caches` / `.m2\repository` / `.nuget\packages` | Java/.NET 构建依赖 | 删后构建时重下 |
| `electron`（LocalAppData） | Electron 下载缓存 | 可删，自动重下 |
| `Chrome/Edge/Brave ...\<profile>\Cache`、`Code Cache`、`GPUCache`、`Service Worker` | 浏览器/应用缓存 | 关浏览器后清；**每个 profile 都要算**；勿碰 Cookies/Login Data/History |
| `%APPDATA%\Code\Cache`、`CachedData`、`Code Cache`、`GPUCache`、`logs` | VS Code 缓存/日志 | 关 VS Code 后清；勿碰 User 设置/快捷键/插件列表 |
| `%LOCALAPPDATA%\Discord\Cache`、`%APPDATA%\discord\Cache` | Discord 缓存 | 可删，重启后重建 |

## 中风险（确认后清理）

| 路径 | 是什么 | 注意 |
|---|---|---|
| `ms-playwright` | Playwright 浏览器二进制 | 删后 `npx playwright install` 重下 |
| `JetBrains`（LocalAppData） | IDE 索引与旧版本缓存 | 删后首次打开重建索引，耗时 |
| `Microsoft\VisualStudio`（LocalAppData） | VS 组件缓存 | 删后首次启动变慢 |
| `C:\ProgramData\Package Cache` | VS / VC++ 安装缓存 | 删后修复/卸载安装包会重新下载 |
| `%LOCALAPPDATA%\Packages` | Store 应用数据（含 LocalCache） | 里面可能有真实用户文档，逐项确认 |
| `%USERPROFILE%\.cache` | 通用缓存（HuggingFace 等） | 可能含模型权重/数据集，删后重下代价高 |
| `%USERPROFILE%\.ollama\models` | Ollama 模型 | 删后需重新下载 |
| Android Studio 缓存 / `.android\avd` | 模拟器镜像 | AVD 是完整虚拟机，删了要重配 |
| 微信开发者工具 | 小程序 IDE 缓存 | 确认无未同步项目 |
| `OpenAI`、`Claude-3p` 等工具目录 | AI 工具运行数据 | 见下方 AI 工具条目 |

## 高风险（默认勿动）

| 路径 | 是什么 | 注意 |
|---|---|---|
| `WeChat Files` / `xwechat_files` | 微信：混合了缓存与**接收的文件** | 只区分后清理缓存部分；聊天记录/文件需路径级确认 |
| `.codex` / `.claude` / `.gemini` / `.lingma` / `.antigravity` / `.cc-switch` / `.agent-browser` / `.nst-agent` | AI 工具的配置、会话、密钥、工作数据 | 常含 API key 与不可再生的会话/项目数据；逐项确认 |
| `Downloads` / `Desktop` / `Documents` | 用户文档 | 无路径级确认不碰 |
| `~\.ssh`、任何含 `key`/`token` 字样的目录 | 密钥 | 不碰 |

## 更新残留（2026-09 实锤案例）

| 特征 | 是什么 | 处理 |
|---|---|---|
| 盘根 `C:\<哈希名>\` 内含 `DesktopDeployment.cab`、`SSU-*.cab`、`*.psf`、`*.wim` | Windows 更新的部署暂存文件 | `Get-HotFix` 确认对应 KB 已安装后，整目录可删 |
| 盘根 `C:\LeakHotfix` 类目录内含 `*.msu` | 已下载的更新补丁包 | 同上；安装完成后就是纯残留 |

## 未知目录排查流程（库中无匹配时）

1. **看名字**：工具名？哈希名？日期后缀？
2. **看内容特征**（只列目录与前几个文件名，不打开文件）：
   - `.msu` / `.cab` / `.psf` / `.wim` → Windows 更新相关
   - `.dll` / `.exe` / `.msi` → 某程序的安装/运行目录
   - `.vhdx` / `.vmdk` / `.qcow2` → 虚拟机/容器磁盘（只能压缩，不能删）
   - 文档/照片/压缩包 → 用户数据，按高风险处理
3. **查使用状态**：LastWriteTime 是否近期？相关工具还在运行吗？对应 KB 是否已安装？
4. **拿不准就保守**：标注「未知目录，建议保留」，把判断交给用户。宁可不清理，
   不可错清理。

> 注意：脚本给出的每个大小都带 `full` / `sampled`（超过 20000 文件截断）/ `partial`（超过时间预算）/ `missing` 标记。
> 向用户汇报时不要把 `sampled`/`partial` 当作精确总量。
