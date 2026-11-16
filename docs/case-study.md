# Case study: from a 6-line .bat to a reversible proxy tool

## 1. The original problem

I switch between a local proxy and a direct connection many times a day. Windows Settings makes this a multi-click operation, and after a while I stop remembering whether I left the proxy on.

The first solution was a 6-line batch file, kept in [`legacy/close-proxy.bat`](legacy/close-proxy.bat):

```bat
@echo off
title Close Proxy
set "key=HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
reg add "%key%" /v ProxyEnable /t REG_DWORD /d 0 /f >nul
echo [OK] System proxy has been disabled.
pause
```

It solved the immediate annoyance. It was also a good example of why "it works" is not the same as "it is reliable".

## 2. What the 6-line version got wrong

| Assumption | Reality |
|---|---|
| Turning `ProxyEnable` off is enough | PAC (`AutoConfigURL`) and WinHTTP are separate |
| The user will remember the old server | Most people will not, and neither did I |
| The registry write always succeeds | Permissions, policy, and locked keys exist |
| One registry location covers Windows | WinINET and WinHTTP are different layers |
| `[OK]` means success | The script never checked the exit code |

The last point is the most important one for a tool that changes system settings: a false success is worse than a clear failure.

## 3. Design constraints

I deliberately kept the scope small:

- no service
- no driver
- no scheduled task
- no elevation by default
- current-user WinINET first
- WinHTTP only when elevated, and reported as skipped otherwise
- every change must be reversible
- every write must be previewable with `-DryRun`

This is a convenience tool, not a system management platform. Keeping the scope small made it possible to test.

## 4. The design

```text
CLI / tray
   │
   ├─ ProxyToggle.psm1
   │    ├─ read WinINET registry
   │    ├─ read WinHTTP via netsh
   │    ├─ save state JSON
   │    ├─ apply state
   │    └─ refresh WinINET
   │
   └─ state file in %LOCALAPPDATA%\WinProxyToggle\state.json
```

### State model

Before the first `disable`, the tool writes:

```json
{
  "Version": 1,
  "SavedAt": "2026-11-16T...",
  "WinInet": {
    "ProxyEnable": 1,
    "ProxyServer": "127.0.0.1:7890",
    "ProxyOverride": "<local>",
    "AutoConfigURL": ""
  },
  "WinHttp": {
    "Mode": "Direct",
    "Proxy": null,
    "BypassList": null
  }
}
```

`restore` writes these values back and deletes the state file. The state file is intentionally human-readable JSON; it contains no credentials.

### Refresh, not just write

Writing `ProxyEnable` to the registry does not always make running applications notice the change. The tool calls `InternetSetOption` with `INTERNET_OPTION_SETTINGS_CHANGED` and `INTERNET_OPTION_REFRESH`. This was one of the first things the original batch file missed.

## 5. Verification

The test suite uses a temporary registry key, not the real proxy:

```text
HKCU\Software\WinProxyToggle\Tests\<guid>
```

Tests cover:

- initial state read
- dry-run does not write
- disable saves state and writes `ProxyEnable=0`
- disable clears PAC only when requested
- enable restores the saved server/PAC
- restore applies every original value
- restore removes the state file
- missing registry properties do not throw under `Set-StrictMode`
- formatted status includes the expected sections

Result:

```text
Passed: 23  Failed: 0
```

I also ran `status` and `disable -DryRun` against the real registry; both are read-only and do not change the machine.

## 6. What I would do next

- Pester tests in CI on a Windows runner
- signed release build
- a small settings file for custom proxy profiles
- optional support for process-level environment variables (with a clear warning that it cannot change already-running processes)
- a proper icon set and installer

I would not add those before the core state model is stable. Scope discipline is part of the design.

## 7. What this project demonstrates

- turning a vague annoyance into a defined problem
- finding the difference between "the visible setting" and the actual system layers
- designing for rollback instead of hoping nothing goes wrong
- writing tests for a Windows tool without touching the real machine
- using AI for research and scaffolding while keeping the safety decisions human
