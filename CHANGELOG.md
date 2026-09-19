# Changelog

## 0.2.0 - 2026-09-19

- Added a 0-100 health score to `health` mode: disk, memory, stability, boot, startup, and updates components each scored from live measurements with weights; unavailable data sources are excluded and weights renormalized; pending reboot subtracts 10. The weakest component is always reported with its evidence.
- Added `baseline` and `compare` modes: snapshot drives, startup items, auto-start-but-stopped services, and pending-reboot state into `~\.winfix\baselines\` (newest 20 kept), then diff any later moment against it (per-drive byte deltas, startup added/removed, service count change).
- Added boot-duration analysis from the Diagnostics-Performance log where available.
- Added WSL/Docker vhdx virtual-disk detection with a safe compaction route (admin boundary and backup warning included).
- Hardened `cleanup-temp`: preview-only by default; deletion requires an explicit `-Apply` switch, skips entries modified within 24h, and stays restricted to the exact `%TEMP%` / `C:\Windows\Temp` roots.

## 0.1.0 - 2026-06-14

- Initial publishable package.
- Added Windows diagnostic routes for disk, memory, apps, network, updates, devices, drivers, audio, display, printer, power, security, WSL, Docker, Android, and developer tools.
- Added JSON output for `health`, `overview`, `disk`, `memory`, `dev`, and `network`.
- Added safety reference, issue-route reference, release checklist, and eval prompts.


