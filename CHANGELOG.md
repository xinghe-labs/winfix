# Changelog

## 0.3.1 - 2026-10-12

- `baseline` no longer churns history. A snapshot is now skipped when the newest baseline is younger than 15 minutes **and** nothing material changed (every drive within 200 MB, the same startup set, the same pending-reboot state). Before this, anything that called `baseline` a few times in a row — an agent doing a health check, a regression test — silently pushed real history out of the newest-20 window. `-Force` saves anyway, and the skipped response says exactly why and what to do next.
- `-Mode baseline` JSON now reports `saved: true|false`; when skipped it also returns `skipped_reason`, `existing_path`, `existing_created_at` and `hint` instead of pretending a snapshot was written.
- Added `Get-NewestBaselineFile` and `Test-BaselineRedundant`; the three places that used to scan the baseline directory inline now share them.

## 0.3.0 - 2026-10-12

- Fixed a bug that made `dev` / `android` useless: the helper's `$Args` parameter collided with PowerShell's automatic `$Args`, so no argument was ever passed (git printed its usage text as its "version", npm printed its command list, node/python printed nothing). Dev probes now report `status` (ok/missing/timeout/error), the resolved path and a readiness verdict, and every external command has a hard timeout.
- Fixed `cleanup-temp` doing nothing on machines whose `%TEMP%` is redirected to another drive (it was judged "not an allowed root" and skipped). The allowlist now accepts a redirected `%TEMP%`/`%TMP%` whose leaf is `temp`/`tmp`, and still refuses drive roots, `C:\Windows`, and profile roots.
- Fixed WSL virtual-disk detection: distros imported to a custom `BasePath` (for example `D:\WSL\Ubuntu`) were invisible, so a machine with 6 GB of WSL vhdx reported "no vhdx found". Detection now reads `HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss` first and falls back to bounded wildcard lookups.
- Fixed mojibake output. PowerShell now emits UTF-8, and external tools are captured with byte-level encoding detection (wsl.exe is UTF-16LE, netsh/powercfg are the OEM codepage, curl is UTF-8) instead of assuming UTF-16 for everything.
- Rebuilt the `issue` symptom router on multi-character keywords. The old single-character matching sent "电脑最近变卡了" to the battery check (电), "打印机不能用" to the startup list (开) and "保存一下现在电脑的状态" to the browser check (存). The chosen route and matched keyword are now printed, and an unmatched prompt gets an honest generic triage instead of a wrong route.
- Added `-Mode smart` (physical disk / volume health, with an explicit note that SMART counters need elevation), `-Mode files` (largest files under a path, `-MinSizeMB`) and `-Mode self-test` (one command that verifies the safety contract and exits non-zero on failure).
- Added `-Deep` disk candidates and many more high-yield locations: crash dumps, Windows Error Reporting, Recycle Bin, `Windows.old`, update download and Delivery Optimization caches, system logs, npm/pip/pnpm/Yarn/NuGet/Gradle/Maven caches, `.cache`, `.ollama`, Playwright, JetBrains, `ProgramData\Package Cache`, Discord. Browser caches are measured for every profile, not just `Default`.
- Scans are bounded instead of unbounded: 20000 files and 6s per folder, 45s per section, junctions/symlinks are never followed, and every number is labelled `full`/`sampled`/`partial`/`missing`. `vscode` dropped from ~35s, `wsl` from ~17s, `health` from ~23s (measurements are now collected once per run).
- `-Format json` is no longer silently ignored: every mode returns JSON, either natively or as `sections` derived from the rendered text. Added native JSON for `wsl`, `events`, `net-test`, `dev` and `network`.
- `events` no longer floods the caller with full event messages: messages are collapsed to one line, capped, and summarised by provider + event id.
- Health score gained a `security` component (Defender real-time state, weight 5) and folds unhealthy physical disks into `stability`; "weakest component" became "biggest lever" (weight x deficit), so a 5-point component no longer outranks a 15-point one.
- Baselines are schema v2 and record enabled non-Microsoft scheduled tasks; `compare` diffs them and says so honestly when an older baseline predates the field. `startup` mode lists those tasks too.
- `network` now reports the WinINET system proxy (what browsers actually use) alongside WinHTTP, plus DNS servers; `net-test` classifies the failure (dns/timeout/tls/proxy/4xx/5xx/connect) and retries with a ranged GET when a server rejects HEAD.
- `system` no longer calls `Get-ComputerInfo` (~8s); it reads targeted CIM plus the registry build/display version.
- `repair-check` adds the read-only `DISM /AnalyzeComponentStore` route and reports the WinSxS size.
- The script is now UTF-8 with BOM (required for Windows PowerShell 5.1 to read non-ASCII literals). CI checks the BOM, the docs-to-script mode list, JSON for every mode, router regressions, and that `Remove-Item` only appears inside the allowed functions (AST-based).

## 0.2.3 - 2026-09-19

- Added `references/known-folders.md`: a curated folder knowledge base (what each common Windows folder is, its risk level, whether/how it can be cleaned, and what regenerates afterwards), including a verified case for Windows-update staging leftovers (hash-named roots containing .cab/.psf/.msu). Unmatched paths follow an explicit unknown-folder triage flow instead of guessed purposes. SKILL.md routes folder-explanation questions through it.

## 0.2.2 - 2026-09-19

- `large` mode accepts `-Path <dir>` to deep-scan any directory or drive root (previously hardcoded to the user profile), and now includes a system root breakdown (`C:\Windows`, `Program Files`, `ProgramData`, ...) plus pagefile/hiberfil/swapfile sizes with honest "sampled" caveats.
- Temp-cleanup candidate list no longer shows zero-byte or missing entries.
- Folder scans report progress on stderr and total elapsed time, so long scans never look hung.

## 0.2.1 - 2026-09-19

- Multi-host: SKILL.md and README are host-neutral; commands reference `<skill-root>` instead of a hardcoded Codex path, and install instructions now cover Codex, Claude Code, and any Agent Skills host.
- Fixed garbled wsl.exe output on non-Unicode consoles (wsl writes UTF-16LE; it is now decoded explicitly instead of relying on the console codepage).
- Script version constant surfaced in health output; consistency enforced by CI.
- Added CI (syntax parse, dangerous-construct guard, JSON smoke tests, evals/schema validation), GitHub issue templates, CONTRIBUTING.md, and a v0.2.1 GitHub Release with a SHA-256 checksum for the archive.

## 0.2.0 - 2026-09-19

- Added a 0-100 health score to `health` mode: disk, memory, stability, boot, startup, and updates components each scored from live measurements with weights; unavailable data sources are excluded and weights renormalized; pending reboot subtracts 10. The weakest component is always reported with its evidence.

- Added `baseline` and `compare` modes: snapshot drives, startup items, auto-start-but-stopped services, and pending-reboot state into `~\.winfix\baselines\` (newest 20 kept), then diff any later moment against it (per-drive byte deltas, startup added/removed, service count change).

- Added boot-duration analysis from the Diagnostics-Performance log where available.

- Added WSL/Docker vhdx virtual-disk detection with a safe compaction route (admin boundary and backup warning included).
- Hardened `cleanup-temp`: preview-only by default; deletion requires an explicit `-Apply` switch, skips entries modified within 24h, and stays restricted to the exact `%TEMP%` / `C:\Windows\Temp` roots.
- Added SECURITY.md with the threat model and copy-paste self-audit commands; net-test now redacts embedded credentials in the echoed target URL; baselines persist startup identity (name + location) only, never full command lines.

## 0.1.0 - 2026-06-14

- Initial publishable package.

- Added Windows diagnostic routes for disk, memory, apps, network, updates, devices, drivers, audio, display, printer, power, security, WSL, Docker, Android, and developer tools.

- Added JSON output for `health`, `overview`, `disk`, `memory`, `dev`, and `network`.

- Added safety reference, issue-route reference, release checklist, and eval prompts.
