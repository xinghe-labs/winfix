# 贡献指南

感谢关注 WinFix。这个项目刻意保持很小：一个 PowerShell 脚本、一份 SKILL.md、
一份安全契约。改动前请先读 [SECURITY.md](SECURITY.md)——它是本项目的红线。

## 改动原则

1. **只读优先**：新的诊断能力必须是只读的。任何写入或删除能力都需要先在
   SECURITY.md 中说明设计（写哪里、删什么、什么条件下允许），并默认要求
   显式确认开关。
2. **证据先行**：报告的每个结论都要有可复现的实测数据支撑，数据源缺失就
   降级跳过，不要编造。
3. **同步四处**：改能力时同步更新 `SKILL.md`（路由与契约）、`README.md`
   （用户视角）、`CHANGELOG.md`（版本）、`evals/evals.json`（预期行为）。
4. **版本一致**：`scripts/inspect_windows.ps1` 的 `$WinfixVersion` 必须与
   `CHANGELOG.md` 顶部条目一致，CI 会检查。

## 本地验证（提交前）

```powershell
# 语法解析
$e = $null; $null = [System.Management.Automation.Language.Parser]::ParseFile(
  "$PWD/scripts/inspect_windows.ps1", [ref]$null, [ref]$e); $e.Count  # 应为 0

# 冒烟（应输出合法 JSON 且带 score.total）
powershell -ExecutionPolicy Bypass -File ./scripts/inspect_windows.ps1 -Mode health -Format json
```

CI 会在 windows-latest 上跑同样的检查，外加危险构造守卫
（Security.md 里的承诺由 CI 强制为真）。

## 发布流程（维护者）

1. 更新 `CHANGELOG.md` 与 `$WinfixVersion`。
2. 本地全模式回归：`health / baseline / compare / overview / disk / wsl / cleanup-temp(预览)`。
3. 打 `v<version>` 标签并推送。
4. `git archive` 导出 zip，计算 SHA-256，创建 GitHub Release 并附两个文件。
