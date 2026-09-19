# Security Policy

WinFix 会在你的机器上运行 PowerShell，所以「可以放心运行」不能只靠口头承诺。
本文件说明这个 skill 的安全模型，以及**你如何在不信任我们的前提下自行验证**。

## 脚本能力边界（可逐行核对的事实）

`scripts/inspect_windows.ps1` 是唯一的可执行文件，单文件、纯标准库命令：

1. **零网络行为**：脚本自身不发起任何网络请求（`net-test` 模式只在你显式
   给出目标地址时才用 `curl.exe -I` 测试那个地址）。
2. **零遥测、零自动更新**：不上报任何数据，不检查更新，不下载任何内容。
3. **删除只存在于一个模式**：`cleanup-temp`。它默认只输出预览，必须显式加
   `-Apply` 才执行；执行范围被限制在 `%TEMP%` 和 `C:\Windows\Temp` 两个解析
   后的精确根目录，并跳过 24 小时内修改过的文件。
4. **写入只存在于一个位置**：基线快照存到 `~\.winfix\baselines\`，只保留
   最近 20 份。快照里只有设备名、容量、启动项名称与位置——不含完整命令行、
   不含文件内容、不含文件名清单。
5. **输出自动脱敏**：代理地址、URL 中可能内嵌的 `user:password` 凭据在展示
   前会被替换为 `***`。
6. **高风险区不存在代码路径**：下载、桌面、文档、微信文件、浏览器配置、
   SSH/API 密钥、注册表、驱动、BitLocker、磁盘分区——脚本中没有能触及
   这些区域的语句。

## 自行验证（复制粘贴即可）

不想逐行读 900 行脚本的话，在你的克隆目录里跑这几条，自己看结果：

```powershell
# 1) 确认没有远程执行 / 下载 / 表达式求值构造
Select-String -Path .\scripts\inspect_windows.ps1 -Pattern 'Invoke-Expression','iex ','DownloadString','DownloadFile','WebClient','Start-Process','Invoke-WebRequest','Invoke-RestMethod','New-Object System.Net'

# 2) 确认所有删除语句只有两处，并核对它们的上下文
Select-String -Path .\scripts\inspect_windows.ps1 -Pattern 'Remove-Item' -Context 3,3

# 3) 确认所有网络访问只有 net-test 的 curl 和 DNS 查询
Select-String -Path .\scripts\inspect_windows.ps1 -Pattern 'curl|Resolve-DnsName|Invoke-'
```

预期结果：第 1 条零命中；第 2 条命中 `cleanup-temp`（有 `-Apply` 门禁与
24 小时跳过）与基线保留清理（只删自己目录里 `baseline-*.json`）；第 3 条
命中 `net-test` 的显式目标测试。

## 报告漏洞

不要在公开 issue 里描述可利用细节。请使用 GitHub 的
**Private vulnerability reporting**（仓库 Security 页签），或在 issue 中
只描述现象而不含利用细节。我们会在修复后于 CHANGELOG 中披露。
