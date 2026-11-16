#Requires -Version 5.1
# 测试套件：全部使用临时注册表键，绝不修改真实系统代理。
# 这样即使测试失败，也不会把机器的网络配置弄坏。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\src\ProxyToggle.psm1'
Import-Module $modulePath -Force

$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:Passed++
        Write-Host "PASS  $Message" -ForegroundColor Green
    } else {
        $script:Failed++
        Write-Host "FAIL  $Message" -ForegroundColor Red
    }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    $ok = ($Actual -eq $Expected)
    if ($ok) {
        $script:Passed++
        Write-Host "PASS  $Message" -ForegroundColor Green
    } else {
        $script:Failed++
        Write-Host "FAIL  $Message (expected '$Expected', got '$Actual')" -ForegroundColor Red
    }
}

$testRoot = "HKCU:\Software\WinProxyToggle\Tests\$([guid]::NewGuid().ToString('N'))"
$statePath = Join-Path $env:TEMP "WinProxyToggle-test-$([guid]::NewGuid().ToString('N')).json"
$lastStatePath = Join-Path $env:TEMP "WinProxyToggle-last-$([guid]::NewGuid().ToString('N')).json"

try {
    New-Item -Path $testRoot -Force | Out-Null

    # Initial state: proxy on with PAC.
    New-ItemProperty -Path $testRoot -Name ProxyEnable -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $testRoot -Name ProxyServer -Value '127.0.0.1:7890' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $testRoot -Name ProxyOverride -Value '<local>' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $testRoot -Name AutoConfigURL -Value 'http://pac.example/proxy.pac' -PropertyType String -Force | Out-Null

    $before = Get-ProxyState -RegistryKey $testRoot
    Assert-Equal $before.ProxyEnable 1 'Initial ProxyEnable is 1'
    Assert-Equal $before.ProxyServer '127.0.0.1:7890' 'Initial ProxyServer is saved'

    # Dry run must not write state or change the registry.
    $dry = Disable-ProxyToggle -RegistryKey $testRoot -StatePath $statePath -SkipWinHttp -IncludeAutoConfig -DryRun
    Assert-True $dry.DryRun 'Disable dry-run returns DryRun=true'
    Assert-True (-not (Test-Path -LiteralPath $statePath)) 'Disable dry-run does not create state file'
    $afterDry = Get-ProxyState -RegistryKey $testRoot
    Assert-Equal $afterDry.ProxyEnable 1 'Disable dry-run leaves ProxyEnable unchanged'

    # Disable saves state and turns the proxy off.
    $disabled = Disable-ProxyToggle -RegistryKey $testRoot -StatePath $statePath -SkipWinHttp -IncludeAutoConfig
    $afterDisable = Get-ProxyState -RegistryKey $testRoot
    Assert-Equal $afterDisable.ProxyEnable 0 'Disable sets ProxyEnable to 0'
    Assert-Equal $afterDisable.AutoConfigURL '' 'Disable clears AutoConfigURL when requested'
    Assert-True (Test-Path -LiteralPath $statePath) 'Disable creates a state file'
    $saved = Get-SavedProxyState -StatePath $statePath
    Assert-Equal $saved.WinInet.ProxyServer '127.0.0.1:7890' 'State preserves ProxyServer'
    Assert-Equal $saved.WinInet.AutoConfigURL 'http://pac.example/proxy.pac' 'State preserves AutoConfigURL'

    # Enable turns it back on and restores missing proxy fields from state.
    $enabled = Enable-ProxyToggle -RegistryKey $testRoot -StatePath $statePath
    $afterEnable = Get-ProxyState -RegistryKey $testRoot
    Assert-Equal $afterEnable.ProxyEnable 1 'Enable sets ProxyEnable to 1'
    Assert-Equal $afterEnable.AutoConfigURL 'http://pac.example/proxy.pac' 'Enable restores AutoConfigURL from state'

    # Restore applies the exact original state and clears the state file.
    $restored = Restore-ProxyToggle -RegistryKey $testRoot -StatePath $statePath -SkipWinHttp
    $afterRestore = Get-ProxyState -RegistryKey $testRoot
    Assert-Equal $afterRestore.ProxyEnable 1 'Restore applies ProxyEnable'
    Assert-Equal $afterRestore.ProxyServer '127.0.0.1:7890' 'Restore applies ProxyServer'
    Assert-Equal $afterRestore.ProxyOverride '<local>' 'Restore applies ProxyOverride'
    Assert-Equal $afterRestore.AutoConfigURL 'http://pac.example/proxy.pac' 'Restore applies AutoConfigURL'
    Assert-True (-not (Test-Path -LiteralPath $statePath)) 'Restore removes the state file'

    # A key with only ProxyEnable must not throw under StrictMode.
    $minimalRoot = "$testRoot-minimal"
    New-Item -Path $minimalRoot -Force | Out-Null
    New-ItemProperty -Path $minimalRoot -Name ProxyEnable -Value 0 -PropertyType DWord -Force | Out-Null
    $minimal = Get-ProxyState -RegistryKey $minimalRoot
    Assert-Equal $minimal.ProxyEnable 0 'Minimal key reads ProxyEnable'
    Assert-Equal $minimal.ProxyServer '' 'Minimal key returns empty ProxyServer'
    Remove-Item -Path $minimalRoot -Recurse -Force

    # Status object contains the expected sections.
    $status = Get-ProxyToggleStatus -RegistryKey $testRoot -StatePath $lastStatePath -SkipWinHttp
    Assert-True ($null -ne $status.WinInet) 'Status contains WinInet'
    Assert-True ($null -ne $status.Environment) 'Status contains Environment'
    Assert-Equal $status.SavedState $null 'Status reports no saved state after restore'

    $formatted = Format-ProxyStatus -Status $status
    Assert-True ($formatted -match 'WinINET system proxy') 'Formatted status contains WinINET section'
} finally {
    Remove-Item -Path $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $statePath -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $lastStatePath -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Passed: $script:Passed  Failed: $script:Failed"
if ($script:Failed -gt 0) { exit 1 }
exit 0
