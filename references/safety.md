# WinFix Safety Reference

## Safe by default

- `%TEMP%`, `%LOCALAPPDATA%\Temp`, `C:\Windows\Temp`: applications may recreate files. Skip locked files.
- Browser HTTP cache (any profile): sites may load slower once; do not clear cookies/passwords unless requested.
- VS Code cache folders: stop Code first; keep User settings, snippets, keybindings, and extensions.
- Package download caches: npm/pip/pnpm/yarn/NuGet can redownload packages; builds may be slower next time.
- Crash dumps (`%LOCALAPPDATA%\CrashDumps`), Windows Error Reporting, `C:\Windows\Logs`, `C:\PerfLogs`: regenerated on demand.
- Recycle Bin: only "clean" it after confirming nothing needs to be restored.

## Needs explanation first

- Docker data: can remove images, containers, volumes, and databases. Ask what projects depend on Docker.
- WSL distributions: unregistering deletes Linux files. Export or confirm before removal. A `.vhdx` only grows — compact it, never delete it to "free space".
- Android emulator AVDs: deleting removes emulator devices and their app data.
- Gradle/Maven/NuGet caches: usually safe but the first rebuild is slow and offline builds may fail.
- `%USERPROFILE%\.cache`, `.ollama\models`: often holds model weights that are expensive to re-download.
- Large app folders under `%LOCALAPPDATA%`: distinguish cache from user profile or project data.
- `Windows.old`: deleting removes the rollback path to the previous Windows build.

## High risk

- `Downloads`, `Desktop`, `Documents`, OneDrive, WeChat received files, QQ files.
- Browser profile directories containing cookies, passwords, extensions, sessions, and history.
- `.ssh`, `.gnupg`, `.aws`, `.config`, `.npmrc`, `.pypirc`, API key files, project `.env` files.
- Source repositories and build workspaces unless the user names the exact target.
- `%LOCALAPPDATA%\Packages`: store-app data can include real user documents.

## Mechanical rules the script enforces

These are not style advice; they are implemented and self-tested:

1. **Deletion roots are an allowlist.** `cleanup-temp` may only touch
   `%LOCALAPPDATA%\Temp`, `C:\Windows\Temp`, and a redirected `%TEMP%`/`%TMP%`
   whose leaf name is `temp` or `tmp`. Drive roots, `C:\Windows`, and profile
   roots are refused even if an environment variable points there.
2. **Nothing recent is deleted.** Entries modified within 24 hours are skipped, so
   a running installer is never disturbed.
3. **No traversal through reparse points.** Junctions and symlinks inside a temp
   root are excluded from the deletion plan and never counted as folder size.
4. **Re-check before delete.** The parent is re-validated against the allowlist
   immediately before each `Remove-Item`.
5. **Bounded scanning.** 20000 files / 6s per folder, 45s per section, hard
   timeouts on every external command. `full`/`sampled`/`partial`/`missing` is
   reported per number.
6. **Redaction before display.** `user:password@` in URLs and `password=`/`token=`
   style values become `***`.

## Reporting language

For each candidate, say:

```text
路径：
大小：（并说明是 full / sampled / partial）
类型：
风险：
清理后影响：
建议：
```

When uncertain, classify as medium or high risk and ask for path-level approval.
