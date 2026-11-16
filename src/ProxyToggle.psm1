#Requires -Version 5.1
# WinProxyToggle 核心模块
#
# 设计原则：
# 1. 默认只修改当前用户 WinINET，不碰 HKLM，避免影响整台机器。
# 2. disable 先保存状态，restore 负责恢复；不靠用户记忆。
# 3. WinHTTP 是另一套代理配置，需要管理员权限；没有权限时明确报告 skipped。
# 4. 所有写操作都支持 DryRun；测试使用独立注册表键，绝不碰真实代理。
#
# 编码说明：本文件保存为 UTF-8 with BOM，Windows PowerShell 5.1 才能正确读取中文注释。
Set-StrictMode -Version Latest

$script:DefaultRegistryKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$script:DefaultStatePath = Join-Path $env:LOCALAPPDATA 'WinProxyToggle\state.json'
$script:WinInetTypeLoaded = $false

function Get-DefaultProxyRegistryKey {
    return $script:DefaultRegistryKey
}

function Get-DefaultProxyStatePath {
    return $script:DefaultStatePath
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 从注册表对象安全读取属性。
# 不能直接写 $item.ProxyServer：在 Set-StrictMode 下，属性不存在会抛错。
function Get-PropertyValue {
    param($Object, [string]$Name)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

# 读取 WinINET 代理状态。
# 这一层对应“设置 → 网络和 Internet → 代理”里的手动代理。
function Get-ProxyState {
    [CmdletBinding()]
    param(
        [string]$RegistryKey = $script:DefaultRegistryKey
    )

    if (-not (Test-Path -LiteralPath $RegistryKey)) {
        throw "Registry key not found: $RegistryKey"
    }

    $item = Get-ItemProperty -LiteralPath $RegistryKey -ErrorAction Stop
    $enabled = 0
    $enableValue = Get-PropertyValue -Object $item -Name 'ProxyEnable'
    if ($null -ne $enableValue) { $enabled = [int]$enableValue }

    return [pscustomobject]@{
        ProxyEnable   = $enabled
        ProxyServer   = [string](Get-PropertyValue -Object $item -Name 'ProxyServer')
        ProxyOverride = [string](Get-PropertyValue -Object $item -Name 'ProxyOverride')
        AutoConfigURL = [string](Get-PropertyValue -Object $item -Name 'AutoConfigURL')
    }
}

# 读取 WinHTTP 代理。
# 注意：netsh 的输出会随系统语言变化，所以同时匹配英文和中文标签；
# 解析不出来时返回 Unknown，不做猜测。
function Get-WinHttpProxy {
    [CmdletBinding()]
    param()

    $raw = ''
    try {
        $raw = (& netsh winhttp show proxy 2>&1 | Out-String).Trim()
    } catch {
        return [pscustomobject]@{
            Mode       = 'Unknown'
            Proxy      = $null
            BypassList = $null
            Raw        = $_.Exception.Message
        }
    }

    $isDirect = $raw -match '(?im)^\s*(Direct access|直接访问|直接存取)'
    if ($isDirect) {
        return [pscustomobject]@{
            Mode       = 'Direct'
            Proxy      = $null
            BypassList = $null
            Raw        = $raw
        }
    }

    $proxy = $null
    $bypass = $null
    $proxyMatch = [regex]::Match(
        $raw,
        '(?im)^\s*(?:Proxy Server\(s\)|代理服务器)\s*[:：]\s*(.+?)\s*$'
    )
    if ($proxyMatch.Success) { $proxy = $proxyMatch.Groups[1].Value.Trim() }

    $bypassMatch = [regex]::Match(
        $raw,
        '(?im)^\s*(?:Bypass List|跳过列表)\s*[:：]\s*(.*?)\s*$'
    )
    if ($bypassMatch.Success) { $bypass = $bypassMatch.Groups[1].Value.Trim() }

    $mode = if ($proxy) { 'Proxy' } else { 'Unknown' }
    return [pscustomobject]@{
        Mode       = $mode
        Proxy      = $proxy
        BypassList = $bypass
        Raw        = $raw
    }
}

# 写注册表值。
# ProxyEnable 必须是 REG_DWORD；Set-ItemProperty 不保证类型，所以 DWORD 用
# New-ItemProperty -PropertyType DWord -Force。
# 空字符串表示删除该值，用于恢复“原本没有这个值”的状态。
function Set-RegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$Value,
        [ValidateSet('DWord', 'String')][string]$Type = 'String'
    )

    if ($null -eq $Value -or ($Value -is [string] -and $Value -eq '')) {
        Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
        return
    }

    if ($Type -eq 'DWord') {
        New-ItemProperty -LiteralPath $Path -Name $Name -Value ([int]$Value) -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        return
    }

    $existing = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -ErrorAction Stop
    } else {
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType String -Force -ErrorAction Stop | Out-Null
    }
}

# 通知 WinINET 设置已变化。
# 只改注册表，已经运行的程序不一定会立刻读到新值，所以需要 InternetSetOption。
function Invoke-WinInetRefresh {
    [CmdletBinding()]
    param()

    if (-not $script:WinInetTypeLoaded) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ProxyToggleWinInet
{
    [DllImport("wininet.dll", SetLastError = true)]
    public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
}
'@
        $script:WinInetTypeLoaded = $true
    }

    # INTERNET_OPTION_SETTINGS_CHANGED = 39, INTERNET_OPTION_REFRESH = 37
    [void][ProxyToggleWinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
    [void][ProxyToggleWinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
}

# 保存当前状态到 JSON。
# 只在第一次 disable 时保存；如果已经有状态文件，不覆盖，避免把“关闭后的状态”
# 当成原始状态保存。
function Save-ProxyState {
    [CmdletBinding()]
    param(
        [string]$StatePath = $script:DefaultStatePath,
        [string]$RegistryKey = $script:DefaultRegistryKey,
        [switch]$IncludeAutoConfig,
        [switch]$SkipWinHttp
    )

    $winhttp = $null
    if (-not $SkipWinHttp) { $winhttp = Get-WinHttpProxy }

    $state = [ordered]@{
        Version          = 1
        SavedAt          = (Get-Date).ToString('o')
        ComputerName     = $env:COMPUTERNAME
        UserName         = $env:USERNAME
        IncludeAutoConfig = [bool]$IncludeAutoConfig
        WinInet          = Get-ProxyState -RegistryKey $RegistryKey
        WinHttp          = $winhttp
    }

    $directory = Split-Path -Parent $StatePath
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $StatePath -Encoding UTF8
    return $state
}

function Get-SavedProxyState {
    [CmdletBinding()]
    param([string]$StatePath = $script:DefaultStatePath)

    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    try {
        return (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json)
    } catch {
        throw "Saved state is unreadable: $StatePath"
    }
}

# 关闭系统代理。
# 关键顺序：先保存状态，再写注册表；失败时状态文件仍在，用户可以 restore。
function Disable-ProxyToggle {
    [CmdletBinding()]
    param(
        [string]$StatePath = $script:DefaultStatePath,
        [string]$RegistryKey = $script:DefaultRegistryKey,
        [switch]$IncludeAutoConfig,
        [switch]$SkipWinHttp,
        [switch]$DryRun
    )

    $current = Get-ProxyState -RegistryKey $RegistryKey
    $saved = Get-SavedProxyState -StatePath $StatePath
    $winhttp = if ($SkipWinHttp) { $null } else { Get-WinHttpProxy }
    $isAdmin = Test-IsAdministrator

    if ($DryRun) {
        return [pscustomobject]@{
            DryRun            = $true
            Action            = 'disable'
            WouldSaveState    = ($null -eq $saved)
            ProxyEnableBefore = $current.ProxyEnable
            ProxyEnableAfter  = 0
            AutoConfigURL     = if ($IncludeAutoConfig -and $current.AutoConfigURL) { $current.AutoConfigURL } else { $null }
            WinHttpMode       = if ($winhttp) { $winhttp.Mode } else { 'Skipped' }
            IsAdministrator   = $isAdmin
        }
    }

    if (-not $saved) {
        $null = Save-ProxyState -StatePath $StatePath -RegistryKey $RegistryKey -IncludeAutoConfig:$IncludeAutoConfig -SkipWinHttp:$SkipWinHttp
    }

    Set-RegistryValue -Path $RegistryKey -Name 'ProxyEnable' -Value 0 -Type DWord
    if ($IncludeAutoConfig) {
        Set-RegistryValue -Path $RegistryKey -Name 'AutoConfigURL' -Value $null
    }
    Invoke-WinInetRefresh

    $winhttpResult = 'Skipped'
    if (-not $SkipWinHttp) {
        if ($isAdmin) {
            try {
                & netsh winhttp reset proxy | Out-Null
                $winhttpResult = 'Reset'
            } catch {
                $winhttpResult = "Failed: $($_.Exception.Message)"
            }
        } else {
            $winhttpResult = 'Skipped (needs administrator)'
        }
    }

    return [pscustomobject]@{
        Action          = 'disable'
        ProxyEnable     = 0
        SavedState      = $StatePath
        WinHttp         = $winhttpResult
        IsAdministrator = $isAdmin
    }
}

# 打开系统代理。
# 如果 ProxyServer 被清空，会尝试从状态文件恢复，保证 disable → enable 是可用循环。
function Enable-ProxyToggle {
    [CmdletBinding()]
    param(
        [string]$StatePath = $script:DefaultStatePath,
        [string]$RegistryKey = $script:DefaultRegistryKey,
        [switch]$DryRun
    )

    $current = Get-ProxyState -RegistryKey $RegistryKey
    $saved = Get-SavedProxyState -StatePath $StatePath
    if ($DryRun) {
        return [pscustomobject]@{
            DryRun           = $true
            Action           = 'enable'
            ProxyEnableBefore = $current.ProxyEnable
            ProxyEnableAfter = 1
        }
    }

    # If the proxy server was cleared, use the value saved by "disable".
    if (-not $current.ProxyServer -and $saved -and $saved.WinInet.ProxyServer) {
        Set-RegistryValue -Path $RegistryKey -Name 'ProxyServer' -Value ([string]$saved.WinInet.ProxyServer)
        Set-RegistryValue -Path $RegistryKey -Name 'ProxyOverride' -Value ([string]$saved.WinInet.ProxyOverride)
    }
    if (-not $current.AutoConfigURL -and $saved -and $saved.WinInet.AutoConfigURL) {
        Set-RegistryValue -Path $RegistryKey -Name 'AutoConfigURL' -Value ([string]$saved.WinInet.AutoConfigURL)
    }

    Set-RegistryValue -Path $RegistryKey -Name 'ProxyEnable' -Value 1 -Type DWord
    Invoke-WinInetRefresh

    $after = Get-ProxyState -RegistryKey $RegistryKey
    $warning = $null
    if (-not $after.ProxyServer -and -not $after.AutoConfigURL) {
        $warning = 'ProxyEnable is on, but no ProxyServer or AutoConfigURL is configured.'
    }

    return [pscustomobject]@{
        Action      = 'enable'
        ProxyEnable = 1
        ProxyServer = $after.ProxyServer
        Warning     = $warning
        SavedState  = $StatePath
    }
}

# 恢复到 disable 之前的状态。
# 如果 WinHTTP 需要管理员权限但当前不是管理员，会保留状态文件，方便之后
# 用管理员终端重新 restore；不会把“没恢复成功”当成成功。
function Restore-ProxyToggle {
    [CmdletBinding()]
    param(
        [string]$StatePath = $script:DefaultStatePath,
        [string]$RegistryKey = $script:DefaultRegistryKey,
        [switch]$SkipWinHttp,
        [switch]$DryRun
    )

    $saved = Get-SavedProxyState -StatePath $StatePath
    if (-not $saved) {
        throw "No saved proxy state found: $StatePath"
    }

    $w = $saved.WinInet
    if ($DryRun) {
        return [pscustomobject]@{
            DryRun       = $true
            Action       = 'restore'
            ProxyEnable  = [int]$w.ProxyEnable
            ProxyServer  = [string]$w.ProxyServer
            AutoConfigURL = [string]$w.AutoConfigURL
            WinHttpMode  = if ($saved.WinHttp) { $saved.WinHttp.Mode } else { 'Skipped' }
        }
    }

    Set-RegistryValue -Path $RegistryKey -Name 'ProxyEnable' -Value ([int]$w.ProxyEnable) -Type DWord
    Set-RegistryValue -Path $RegistryKey -Name 'ProxyServer' -Value ([string]$w.ProxyServer)
    Set-RegistryValue -Path $RegistryKey -Name 'ProxyOverride' -Value ([string]$w.ProxyOverride)
    Set-RegistryValue -Path $RegistryKey -Name 'AutoConfigURL' -Value ([string]$w.AutoConfigURL)
    Invoke-WinInetRefresh

    $winhttpResult = 'Skipped'
    $winhttpNeedsRetry = $false
    if (-not $SkipWinHttp -and $saved.WinHttp) {
        if (Test-IsAdministrator) {
            try {
                if ($saved.WinHttp.Mode -eq 'Direct') {
                    & netsh winhttp reset proxy | Out-Null
                    $winhttpResult = 'Restored direct'
                } elseif ($saved.WinHttp.Mode -eq 'Proxy' -and $saved.WinHttp.Proxy) {
                    $netshArgs = @('winhttp', 'set', 'proxy', $saved.WinHttp.Proxy)
                    if ($saved.WinHttp.BypassList) {
                        $netshArgs += @('bypass-list', $saved.WinHttp.BypassList)
                    }
                    & netsh @netshArgs | Out-Null
                    $winhttpResult = "Restored $($saved.WinHttp.Proxy)"
                } else {
                    $winhttpResult = 'Unknown saved WinHTTP mode'
                }
            } catch {
                $winhttpResult = "Failed: $($_.Exception.Message)"
                $winhttpNeedsRetry = $true
            }
        } else {
            $winhttpResult = 'Skipped (needs administrator)'
            $winhttpNeedsRetry = $true
        }
    }

    # Keep the state file if WinHTTP still needs an elevated restore.
    if (-not $winhttpNeedsRetry) {
        Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        Action      = 'restore'
        ProxyEnable = [int]$w.ProxyEnable
        ProxyServer = [string]$w.ProxyServer
        WinHttp     = $winhttpResult
        StateKept   = $winhttpNeedsRetry
        StatePath   = $StatePath
    }
}

# 汇总状态，供 CLI 和托盘使用。
function Get-ProxyToggleStatus {
    [CmdletBinding()]
    param(
        [string]$StatePath = $script:DefaultStatePath,
        [string]$RegistryKey = $script:DefaultRegistryKey,
        [switch]$SkipWinHttp
    )

    $wininet = Get-ProxyState -RegistryKey $RegistryKey
    $winhttp = if ($SkipWinHttp) { $null } else { Get-WinHttpProxy }
    $saved = Get-SavedProxyState -StatePath $StatePath

    return [pscustomobject]@{
        WinInet = $wininet
        WinHttp = $winhttp
        Environment = [pscustomobject]@{
            HTTP_PROXY  = [string]$env:HTTP_PROXY
            HTTPS_PROXY = [string]$env:HTTPS_PROXY
            ALL_PROXY   = [string]$env:ALL_PROXY
            NO_PROXY    = [string]$env:NO_PROXY
        }
        SavedState = $saved
        IsAdministrator = Test-IsAdministrator
        Timestamp = (Get-Date).ToString('o')
    }
}

function Format-ProxyStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Status)

    $w = $Status.WinInet
    $state = if ($w.ProxyEnable -eq 1) { 'ON' } else { 'OFF' }
    $server = if ($w.ProxyServer) { $w.ProxyServer } else { '(none)' }
    $pac = if ($w.AutoConfigURL) { $w.AutoConfigURL } else { '(none)' }
    $winhttp = if ($Status.WinHttp) {
        if ($Status.WinHttp.Mode -eq 'Proxy') { "Proxy: $($Status.WinHttp.Proxy)" }
        elseif ($Status.WinHttp.Mode -eq 'Direct') { 'Direct access' }
        else { 'Unknown' }
    } else { 'Skipped' }

    $lines = @(
        'WinINET system proxy',
        "  State          : $state",
        "  ProxyServer    : $server",
        "  ProxyOverride  : $($w.ProxyOverride)",
        "  AutoConfigURL  : $pac",
        '',
        'WinHTTP proxy',
        "  $winhttp",
        '',
        'Environment',
        "  HTTP_PROXY     : $($Status.Environment.HTTP_PROXY)",
        "  HTTPS_PROXY    : $($Status.Environment.HTTPS_PROXY)",
        "  ALL_PROXY      : $($Status.Environment.ALL_PROXY)",
        "  NO_PROXY       : $($Status.Environment.NO_PROXY)",
        '',
        "Administrator    : $($Status.IsAdministrator)",
        "Saved state      : $(if ($Status.SavedState) { 'yes' } else { 'no' })"
    )
    return ($lines -join [Environment]::NewLine)
}

Export-ModuleMember -Function @(
    'Get-DefaultProxyRegistryKey',
    'Get-DefaultProxyStatePath',
    'Test-IsAdministrator',
    'Get-ProxyState',
    'Get-WinHttpProxy',
    'Save-ProxyState',
    'Get-SavedProxyState',
    'Disable-ProxyToggle',
    'Enable-ProxyToggle',
    'Restore-ProxyToggle',
    'Get-ProxyToggleStatus',
    'Format-ProxyStatus',
    'Invoke-WinInetRefresh'
)
