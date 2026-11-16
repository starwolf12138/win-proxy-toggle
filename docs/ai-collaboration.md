# AI collaboration record

This is a factual record of how AI was used in this project. It is intentionally not "AI wrote everything".

## Starting point

The original tool was a 6-line `.bat` I wrote to turn off the Windows system proxy:

```bat
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 0 /f
```

I asked AI to review it as a small portfolio project, not to "make it bigger".

## What AI contributed

### 1. Failure-mode review

AI pointed out that the script:

- could not restore the previous state
- did not handle `AutoConfigURL` (PAC)
- did not handle WinHTTP
- did not check whether the registry write succeeded
- reported `[OK]` unconditionally

This changed the scope from "one command" to "reversible state change".

### 2. Research map

AI helped map the relevant Windows layers:

| Layer | Where | Who uses it |
|---|---|---|
| WinINET | `HKCU\...\Internet Settings` | Edge/IE, many desktop apps |
| WinHTTP | `netsh winhttp` | services and some apps |
| PAC | `AutoConfigURL` | automatic proxy configuration |

The key conclusion: setting `ProxyEnable=0` is not the same as "no proxy anywhere".

### 3. Scaffolding

AI generated the first draft of:

- `ProxyToggle.psm1`
- `proxy-toggle.ps1`
- `ProxyToggle.Tray.ps1`
- `tests/run-tests.ps1`

I reviewed and changed the safety boundaries.

## Decisions I made

- **HKCU only by default.** No machine-wide changes without an explicit admin path.
- **No service, no scheduled task, no driver.** The tool is a local convenience, not infrastructure.
- **State before change.** `disable` saves first; `restore` is the primary undo.
- **Dry-run is mandatory.** Every write path has a preview.
- **WinHTTP is best-effort.** If not elevated, it reports `Skipped (needs administrator)` instead of pretending.
- **Tests use an isolated registry key.** The test suite must never touch the real proxy.
- **No credentials in state.** The state file contains proxy addresses, not secrets.

## Real bugs found during the build

These are useful because they show the review loop, not just the happy path.

### `$args` collision

The first `restore` implementation did:

```powershell
$args = @('winhttp', 'set', 'proxy', $saved.WinHttp.Proxy)
& netsh @args
```

`$args` is an automatic variable in PowerShell. Assigning to it is a bad idea and can produce confusing behavior. Fixed by renaming it to `$netshArgs`.

### StrictMode and missing registry values

With `Set-StrictMode -Version Latest`, reading a missing custom property from a registry object can throw. The first version assumed the property always existed. Fixed with a small `Get-PropertyValue` helper that checks `PSObject.Properties` first.

### DWORD type

`Set-ItemProperty` does not reliably enforce the registry value type. `ProxyEnable` must stay a `REG_DWORD`. Fixed by using `New-ItemProperty -PropertyType DWord -Force` for that value.

### Localized `netsh` output

`netsh winhttp show proxy` is localized. The parser handles both English and Chinese direct-access / proxy labels, and falls back to `Unknown` rather than guessing.

### Test isolation

An early test idea used the real `HKCU:\...\Internet Settings` key. That was rejected: the test suite must be able to run on a machine with a real proxy and leave it untouched. Every test now uses:

```text
HKCU\Software\WinProxyToggle\Tests\<guid>
```

## Verification

```text
Tests: Passed 23, Failed 0
CLI status: read-only, works against the real registry
CLI disable -DryRun: no writes
Tray: process starts and stays alive; no service or scheduled task
```

## What AI did not do

- It did not decide the scope.
- It did not decide to avoid HKLM.
- It did not decide the test isolation model.
- It did not verify the real machine's proxy state.
- It did not write the final README claims without review.

The useful pattern was:

```text
AI suggests → I choose → we implement → tests verify → I keep or reject
```

That loop is the actual skill this project is meant to show.
