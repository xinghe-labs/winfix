# Release Checklist

Use before publishing the skill to a public marketplace.

## Required checks

1. Run the built-in self-test (read-only, exits non-zero on failure):

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\inspect_windows.ps1 -Mode self-test
   ```

2. Run smoke tests. Every mode must produce text without parser errors and JSON
   that parses, with empty stderr in JSON mode:

   ```powershell
   $s = '.\scripts\inspect_windows.ps1'
   foreach ($m in @('overview','health','disk','memory','dev','network','wsl','docker','large','files','smart','events','startup','security','cleanup-temp')) {
     $json = powershell -NoProfile -ExecutionPolicy Bypass -File $s -Mode $m -Format json 2>$null
     if (-not ($json | ConvertFrom-Json)) { throw "mode $m produced invalid JSON" }
   }
   ```

3. Verify the script still carries a UTF-8 BOM (Windows PowerShell 5.1 needs it
   to read the non-ASCII literals in the symptom router):

   ```powershell
   $b = [System.IO.File]::ReadAllBytes('.\scripts\inspect_windows.ps1')[0..2]
   if (-not (($b[0] -eq 0xEF) -and ($b[1] -eq 0xBB) -and ($b[2] -eq 0xBF))) { throw 'missing UTF-8 BOM' }
   ```

4. Check that every `-Mode` documented in `SKILL.md` exists in the script's
   `ValidateSet`, and every `ValidateSet` entry is documented. CI does this
   automatically; do it locally if you changed either file.

5. Review `evals/evals.json` and test at least the safety-sensitive cases
   (WeChat deletion, Docker prune, "don't ask me, just delete", firewall off).

6. Confirm no secrets, machine-specific credentials, or personal paths are
   embedded in docs except generic `$env:USERPROFILE` examples.

7. Confirm destructive actions still require explicit user confirmation, and that
   `cleanup-temp` still previews without `-Apply`.

8. Bump `$WinfixVersion` in the script and add the matching top entry in
   `CHANGELOG.md` (the self-test and CI both check this pairing).

## Package notes

The skill is useful as a personal skill as-is. For public release, place
`README.md`, license, and marketplace metadata at the repository root, while
keeping `SKILL.md`, `scripts/`, `references/`, and `agents/` inside the skill
folder.
