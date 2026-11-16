#Requires -Version 5.1
# 命令行入口：把用户意图映射到 ProxyToggle.psm1 的函数。
# 这里不直接写注册表，所有逻辑都在模块里，便于测试。
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'disable', 'enable', 'restore', 'tray', 'help')]
    [string]$Action = 'status',

    [switch]$DryRun,
    [switch]$Json,
    [switch]$IncludeAutoConfig,
    [switch]$SkipWinHttp,
    [string]$StatePath,
    [string]$RegistryKey
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'ProxyToggle.psm1'
Import-Module $modulePath -Force

if (-not $StatePath) { $StatePath = Get-DefaultProxyStatePath }
if (-not $RegistryKey) { $RegistryKey = Get-DefaultProxyRegistryKey }

function Write-JsonOrText {
    param($Object, [string]$Text)
    if ($Json) {
        $Object | ConvertTo-Json -Depth 8
    } else {
        Write-Host $Text
    }
}

try {
    switch ($Action) {
        'status' {
            $status = Get-ProxyToggleStatus -StatePath $StatePath -RegistryKey $RegistryKey -SkipWinHttp:$SkipWinHttp
            if ($Json) {
                $status | ConvertTo-Json -Depth 8
            } else {
                Write-Host (Format-ProxyStatus -Status $status)
            }
        }

        'disable' {
            $result = Disable-ProxyToggle -StatePath $StatePath -RegistryKey $RegistryKey -IncludeAutoConfig:$IncludeAutoConfig -SkipWinHttp:$SkipWinHttp -DryRun:$DryRun
            $text = if ($DryRun) {
                "Dry run: would disable system proxy (ProxyEnable=$($result.ProxyEnableBefore) -> 0)."
            } else {
                "System proxy disabled. Saved state: $StatePath`nWinHTTP: $($result.WinHttp)"
            }
            Write-JsonOrText -Object $result -Text $text
        }

        'enable' {
            $result = Enable-ProxyToggle -StatePath $StatePath -RegistryKey $RegistryKey -DryRun:$DryRun
            $text = if ($DryRun) {
                "Dry run: would enable system proxy (ProxyEnable=$($result.ProxyEnableBefore) -> 1)."
            } else {
                "System proxy enabled. ProxyServer: $($result.ProxyServer)"
                if ($result.Warning) { Write-Warning $result.Warning }
            }
            Write-JsonOrText -Object $result -Text $text
        }

        'restore' {
            $result = Restore-ProxyToggle -StatePath $StatePath -RegistryKey $RegistryKey -SkipWinHttp:$SkipWinHttp -DryRun:$DryRun
            $text = if ($DryRun) {
                "Dry run: would restore ProxyEnable=$($result.ProxyEnable), ProxyServer=$($result.ProxyServer)."
            } else {
                "Previous proxy state restored. WinHTTP: $($result.WinHttp)"
                if ($result.StateKept) {
                    Write-Warning "State kept at $($result.StatePath) because WinHTTP needs an elevated restore. Re-run from an administrator shell."
                }
            }
            Write-JsonOrText -Object $result -Text $text
        }

        'tray' {
            $trayScript = Join-Path $PSScriptRoot 'ProxyToggle.Tray.ps1'
            $shell = if (Get-Command powershell.exe -ErrorAction SilentlyContinue) { 'powershell.exe' } else { 'pwsh.exe' }
            $arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$trayScript`" -StatePath `"$StatePath`" -RegistryKey `"$RegistryKey`""
            Start-Process -FilePath $shell -ArgumentList $arguments -WindowStyle Hidden | Out-Null
            Write-Host 'Tray icon started.'
        }

        'help' {
            @'
WinProxyToggle

Usage:
  .\proxy-toggle.ps1 status
  .\proxy-toggle.ps1 disable
  .\proxy-toggle.ps1 enable
  .\proxy-toggle.ps1 restore
  .\proxy-toggle.ps1 tray

Options:
  -DryRun            Show what would change without writing.
  -Json              Output JSON for scripting.
  -IncludeAutoConfig Also disable/save AutoConfigURL (PAC).
  -SkipWinHttp       Do not touch WinHTTP (no admin needed).
  -StatePath <path>  Custom state file.
  -RegistryKey <key> Custom WinINET registry key (mainly for tests).

Examples:
  .\proxy-toggle.ps1 disable -IncludeAutoConfig
  .\proxy-toggle.ps1 restore
  .\proxy-toggle.ps1 tray
'@ | Write-Host
        }
    }
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
