# Release Checklist

Use before publishing the skill to a public marketplace.

## Required checks

1. Run frontmatter validation:
   ```powershell
   $env:PYTHONUTF8='1'; python "$env:USERPROFILE\.codex\skills\.system\skill-creator\scripts\quick_validate.py" "$env:USERPROFILE\.agents\skills\winfix"
   ```
2. Run smoke tests:
   ```powershell
   powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode health -Format json
   powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode disk -Format json
   powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.agents\skills\winfix\scripts\inspect_windows.ps1" -Mode net-test -Target "https://www.microsoft.com"
   ```
3. Review `evals/evals.json` and test at least the safety-sensitive cases.
4. Confirm no secrets, machine-specific credentials, or personal paths are embedded in docs except generic `$env:USERPROFILE` examples.
5. Confirm destructive actions require explicit user confirmation.

## Package notes

The skill is useful as a personal skill as-is. For public release, place `README.md`, license, and marketplace metadata at the repository root, while keeping `SKILL.md`, `scripts/`, `references/`, and `agents/` inside the skill folder.

