# Security Policy

WinFix 会在你的机器上运行 PowerShell，所以「可以放心运行」不能只靠口头承诺。
本文件说明这个 skill 的安全模型，以及**你如何在不信任我们的前提下自行验证**。

## 脚本能力边界（可逐行核对的事实）

`scripts/inspect_windows.ps1` 是唯一的可执行文件，单文件、纯标准库命令：

1. **零网络行为**：脚本自身不发起任何网络请求（`net-test` 模式只在你显式
   给出目标地址时才用 `curl.exe -I` 测试那个地址）。
2. **零遥测、零自动更新**：不上报任何数据，不检查更新，不下载任何内容。
3. **删除用户文件只存在于一个模式**：`cleanup-temp`。它默认只输出预览，必须显式加
   `-Apply` 才执行；删除根来自白名单（`%LOCALAPPDATA%\Temp`、`C:\Windows\Temp`，
   以及目录名是 `temp`/`tmp` 的重定向 `%TEMP%`/`%TMP%`），磁盘根/`C:\Windows`/用户
   目录一律拒绝；跳过 24 小时内修改过的文件；目录软链接（junction/symlink）永不穿透，
   且每次删除前重新校验父目录。另外 `self-test` 模式会创建并删除**它自己在
   `%TEMP%` 下新建的沙箱**，不触碰任何既有文件。
4. **写入只存在于两个位置**：基线快照存到 `~\.winfix\baselines\`（只保留
   最近 20 份），以及上述 `self-test` 沙箱。快照里只有设备名、容量、启动项
   名称与位置、计划任务名称与路径——不含完整命令行、不含文件内容、不含文件名清单。
5. **输出自动脱敏**：代理地址、URL 中可能内嵌的 `user:password` 凭据在展示
   前会被替换为 `***`。
6. **高风险区不存在代码路径**：下载、桌面、文档、微信文件、浏览器配置、
   SSH/API 密钥、注册表、驱动、BitLocker、磁盘分区——脚本中没有能触及
   这些区域的语句（CI 用 AST 检查 `Remove-Item` 只出现在允许的函数里）。
7. **扫描有硬上限**：每目录 20000 文件 / 6 秒、每 section 45 秒、不穿透
   目录软链接；外部命令一律有超时（默认 20 秒，`flutter` 90 秒）。

## 一条命令自证（推荐）

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\inspect_windows.ps1 -Mode self-test
```

它会逐项断言：临时目录白名单（接受 `%LOCALAPPDATA%\Temp`、`C:\Windows\Temp`、
重定向的 `%TEMP%`；拒绝 `C:\`、`C:\Windows`、用户目录）、凭据脱敏、24 小时跳过、
junction 不被列入删除计划、基线目录位置、路由回归、以及脚本版本与 CHANGELOG 一致。
任何一项失败都会打印 FAIL 并以非零退出码结束。它删除的唯一东西是自己在 `%TEMP%`
下新建的沙箱。

## 自行验证（复制粘贴即可）

不想逐行读 2000 行脚本的话，在你的克隆目录里跑这几条，自己看结果：

```powershell
# 1) 确认没有远程执行 / 下载 / 表达式求值构造
#    预期：零命中（脚本已不使用 Start-Process，外部命令统一走
#    System.Diagnostics.Process + 超时）
Select-String -Path .\scripts\inspect_windows.ps1 -Pattern 'Invoke-Expression','iex ','DownloadString','DownloadFile','System.Net.WebClient','Invoke-WebRequest','Invoke-RestMethod','Start-Process'

# 2) 确认所有删除语句的位置与上下文
#    预期：只出现在 Invoke-TempCleanup（cleanup-temp）、Save-Baseline 的
#    保留清理（只删自己目录里的 baseline-*.json）、Invoke-SelfTest 的沙箱清理
Select-String -Path .\scripts\inspect_windows.ps1 -Pattern 'Remove-Item' -Context 2,2

# 3) 确认所有网络访问只有 net-test 的 curl 和 DNS 查询
Select-String -Path .\scripts\inspect_windows.ps1 -Pattern 'curl|Resolve-DnsName|Get-DnsClientServerAddress'

# 4) 确认脚本确实是 UTF-8 with BOM（PS 5.1 读非 ASCII 字面量的前提）
$b = [System.IO.File]::ReadAllBytes('.\scripts\inspect_windows.ps1')[0..2]
($b[0] -eq 0xEF) -and ($b[1] -eq 0xBB) -and ($b[2] -eq 0xBF)
```

CI 会把上面这些检查（含 AST 级别的 `Remove-Item` 归属检查、全模式 JSON 校验、
路由回归）当作门禁执行。

## 报告漏洞

不要在公开 issue 里描述可利用细节。请使用 GitHub 的
**Private vulnerability reporting**（仓库 Security 页签），或在 issue 中
只描述现象而不含利用细节。我们会在修复后于 CHANGELOG 中披露。
