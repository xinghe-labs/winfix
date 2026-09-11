# WinFix Safety Reference

## Safe by default

- `%TEMP%` and `C:\Windows\Temp`: applications may recreate files. Skip locked files.
- Browser HTTP cache: sites may load slower once; do not clear cookies/passwords unless requested.
- VS Code cache folders: stop Code first; keep User settings, snippets, keybindings, and extensions.
- Package download caches: npm/pip/pnpm/yarn can redownload packages; builds may be slower next time.

## Needs explanation first

- Docker data: can remove images, containers, volumes, and databases. Ask what projects depend on Docker.
- WSL distributions: unregistering deletes Linux files. Export or confirm before removal.
- Android emulator AVDs: deleting removes emulator devices and their app data.
- Gradle/Maven caches: usually safe but first rebuild may be slow and offline builds may fail.
- Large app folders under `%LOCALAPPDATA%`: distinguish cache from user profile or project data.

## High risk

- `Downloads`, `Desktop`, `Documents`, OneDrive, WeChat received files, QQ files.
- Browser profile directories containing cookies, passwords, extensions, sessions, and history.
- `.ssh`, `.gnupg`, `.aws`, `.config`, `.npmrc`, `.pypirc`, API key files, project `.env` files.
- Source repositories and build workspaces unless the user names the exact target.

## Reporting language

For each candidate, say:

```text
路径：
大小：
类型：
风险：
清理后影响：
建议：
```

When uncertain, classify as medium or high risk and ask for path-level approval.

