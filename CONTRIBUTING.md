# 贡献指南

感谢关注 WinFix。这个项目刻意保持很小：一个 PowerShell 脚本、一份 SKILL.md、
一份安全契约。改动前请先读 [SECURITY.md](SECURITY.md)——它是本项目的红线。

## 改动原则

1. **只读优先**：新的诊断能力必须是只读的。任何写入或删除能力都需要先在
   SECURITY.md 中说明设计（写哪里、删什么、什么条件下允许），并默认要求
   显式确认开关。扫描要有上限（文件数 + 时间预算），不得穿透目录软链接。
2. **证据先行**：报告的每个结论都要有可复现的实测数据支撑，数据源缺失就
   降级跳过并如实标注，不要编造；每个大小都要标 `full`/`sampled`/`partial`/`missing`。
3. **中文必须能正确输出**：文本模式输出 UTF-8；JSON 模式必须只输出 ASCII
   （非 ASCII 转 `\uXXXX`），否则父进程按 OEM 代码页解码会弄坏中文路径。
3. **同步五处**：改能力时同步更新 `SKILL.md`（路由与契约）、`README.md`
   （用户视角）、`CHANGELOG.md`（版本）、`evals/evals.json`（预期行为）、
   `examples/*.json`（示例输出，里面的 `version` 字段必须等于脚本版本，
   CI 会校验，忘了就红）。
4. **版本一致**：`scripts/inspect_windows.ps1` 的 `$WinfixVersion` 必须与
   `CHANGELOG.md` 顶部条目一致，`-Mode self-test` 和 CI 都会检查。
5. **编码一致**：`scripts/inspect_windows.ps1` 必须保持 UTF-8 with BOM +
   CRLF（Windows PowerShell 5.1 读非 ASCII 字面量的前提，`.gitattributes`
   已声明 `text eol=crlf`，CI 会检查 BOM）。JSON 文件（如
   `evals/evals.json`）保持 UTF-8 **无** BOM，因此在中文区域用
   `Get-Content -Raw` 读会被 cp936 弄坏；请用
   `[System.IO.File]::ReadAllText($path)` 或 `Get-Content -Encoding UTF8`。
6. **模式清单一致**：文档里出现的每个 `-Mode X` 必须在脚本的 `ValidateSet`
   里存在，反之亦然；CI 会双向校验。
7. **路由关键词不退化**：`issue` 路由的关键词必须≥ 2 个字符（单字匹配曾
   把"电脑最近变卡了"路由到电池检查）；`self-test` 里已有断言。

## 本地验证（提交前）

```powershell
# 语法解析
$e = $null; $null = [System.Management.Automation.Language.Parser]::ParseFile(
  "$PWD/scripts/inspect_windows.ps1", [ref]$null, [ref]$e); $e.Count  # 应为 0

# 安全契约自证（任一失败则退出码非零）
powershell -ExecutionPolicy Bypass -File ./scripts/inspect_windows.ps1 -Mode self-test

# 冒烟（应输出合法 JSON 且带 score.total）
powershell -ExecutionPolicy Bypass -File ./scripts/inspect_windows.ps1 -Mode health -Format json
```

CI 会在 windows-latest 上跑同样的检查，外加：危险构造守卫、AST 级别的
`Remove-Item` 归属检查（只允许出现在 `Invoke-TempCleanup` / `Save-Baseline` /
`Invoke-SelfTest` 中）、全模式 JSON 校验、文档↔模式清单双向校验、路由回归断言。

## 发布流程（维护者）

1. 更新 `CHANGELOG.md` 与 `$WinfixVersion`。
2. 本地全模式回归：`health / baseline / compare / overview / disk / wsl / cleanup-temp(预览)`。
3. 打 `v<version>` 标签并推送。
4. `git archive` 导出 zip，计算 SHA-256，创建 GitHub Release 并附两个文件。
