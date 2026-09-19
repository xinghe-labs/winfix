# Changelog

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





