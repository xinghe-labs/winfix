# Issue Routes

Use this reference when a Windows problem is vague or multi-symptom.

## Disk suddenly dropped

1. Run `overview`.
2. Run `disk`.
3. If ordinary caches are small, run `large`.
4. Check hidden VM/runtime bundles: Docker, WSL, Android AVD, emulator images, app VM bundles.
5. Report likely cause before cleaning.

## Browser memory high

1. Run `chrome`.
2. Compare total browser memory to system pressure.
3. Separate normal multi-process browser behavior from a runaway tab/extension.
4. Prefer restart, cache cleanup, extension review, and tab reduction before profile reset.

## App cannot open webview or blank page

1. Identify app: VS Code, Codex, Chrome, Edge, Electron app.
2. Stop the app.
3. Clear Service Worker/cache folders only.
4. Keep user data and extension lists.
5. Reopen and verify.

## Development environment

1. Run `dev`.
2. For Android/Flutter, run `android`.
3. Verify PATH and environment variables.
4. Run one tool-specific health command when available, such as `flutter doctor`.
5. Return exact missing install/config step.

## Network or API failures

1. Run `network`.
2. Test `curl.exe -I` against the affected host if known.
3. Preserve working proxy values before changing them.
4. Distinguish DNS, TLS, proxy, gateway API, and server-side 5xx errors.

If the user provides a URL or host, run `net-test -Target <url>` and classify:
- DNS failure: name resolution issue or proxy DNS issue.
- TLS/certificate failure: time, certificate store, MITM proxy, or server cert.
- 4xx: client/auth/permission/path issue.
- 5xx: remote service or gateway issue; do not over-fix local machine.
- Timeout: network path, proxy, firewall, or remote block.

## Any app crashes or will not open

1. Run `app -ProcessName <name>` if a process/app name is known.
2. Run `events` if the app log is empty or the failure is system-level.
3. Check whether the app has cache folders, WebView dependency, GPU acceleration, or plugin/extension system.
4. Stop before reinstalling. Prefer cache reset, safe mode, extension disable, or config backup first.
5. Preserve user profiles and project data.

## Blue screen, crash, freeze, sudden reboot

1. Run `events`.
2. Look for Kernel-Power, BugCheck, WHEA-Logger, Display driver, disk, or service crash events.
3. Run `drivers` and `devices` if hardware or driver names appear.
4. Ask whether the issue happens under load, after sleep, after update, or when a device is plugged in.
5. Avoid registry, driver removal, or BIOS advice without a clear target.

## Windows Update failure

1. Run `updates`.
2. Check whether `wuauserv`, `bits`, `cryptsvc`, and `msiserver` are present and runnable.
3. Report recent hotfixes and whether the update services are stopped.
4. Give admin repair commands only after explaining impact.

## Startup slow

1. Run `startup`.
2. Run `services` for non-running automatic services.
3. Separate user startup apps from system services.
4. Disable only named startup items after confirmation.

## Device not working

1. Run `devices`.
2. If driver-related, run `drivers`.
3. Record error code and device name.
4. Prefer unplug/replug, vendor driver reinstall, or Windows Update optional driver before deletion.

## Audio, display, printer

Audio:
1. Run `audio`.
2. Check audio services before changing devices.

Display:
1. Run `display`.
2. Check GPU driver and monitor detection.

Printer:
1. Run `printer`.
2. Check spooler status before clearing queue.

## Security warning

1. Run `security`.
2. Check Defender and firewall status.
3. Do not disable security features unless the user explicitly asks and understands the risk.
4. For suspected malware, recommend offline scan or Defender full scan before deleting random files.

## Cleanup response contract

After cleanup, always include:

- before/after evidence if available
- skipped locked files if any
- what may regenerate
- what was deliberately not touched

