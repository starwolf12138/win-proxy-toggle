#Requires -Version 5.1
# 托盘入口：只负责交互，不重复实现代理逻辑。
# 所有操作都调用 ProxyToggle.psm1，保证 CLI 和托盘行为一致。
[CmdletBinding()]
param(
    [string]$StatePath,
    [string]$RegistryKey
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$modulePath = Join-Path $PSScriptRoot 'ProxyToggle.psm1'
Import-Module $modulePath -Force

if (-not $StatePath) { $StatePath = Get-DefaultProxyStatePath }
if (-not $RegistryKey) { $RegistryKey = Get-DefaultProxyRegistryKey }

$logDir = Split-Path -Parent $StatePath
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$logPath = Join-Path $logDir 'tray.log'

function Write-TrayLog {
    param([string]$Message)
    try {
        $line = "[{0}] {1}" -f (Get-Date).ToString('s'), $Message
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    } catch { }
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\WinProxyToggleTray')
if (-not $mutex.WaitOne(0)) {
    exit 0
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ProxyToggleTrayNative
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
'@

function New-TrayIcon {
    $bitmap = New-Object System.Drawing.Bitmap 32, 32
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(47, 111, 237))
    $graphics.FillEllipse($brush, 0, 0, 31, 31)
    $font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $graphics.DrawString('P', $font, [System.Drawing.Brushes]::White, 7, 3)
    $handle = $bitmap.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($handle)
    $graphics.Dispose()
    $brush.Dispose()
    $font.Dispose()
    $bitmap.Dispose()
    return @{ Icon = $icon; Handle = $handle }
}

$trayIconData = New-TrayIcon
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = $trayIconData.Icon
$notifyIcon.Text = 'WinProxyToggle'
$notifyIcon.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
$statusItem.Enabled = $false
[void]$menu.Items.Add($statusItem)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$disableItem = New-Object System.Windows.Forms.ToolStripMenuItem('Disable system proxy')
$enableItem = New-Object System.Windows.Forms.ToolStripMenuItem('Enable system proxy')
$restoreItem = New-Object System.Windows.Forms.ToolStripMenuItem('Restore previous state')
[void]$menu.Items.Add($disableItem)
[void]$menu.Items.Add($enableItem)
[void]$menu.Items.Add($restoreItem)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$aboutItem = New-Object System.Windows.Forms.ToolStripMenuItem('About / open folder')
$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem('Exit')
[void]$menu.Items.Add($aboutItem)
[void]$menu.Items.Add($exitItem)
$notifyIcon.ContextMenuStrip = $menu

function Show-Balloon {
    param([string]$Title, [string]$Text, [System.Windows.Forms.ToolTipIcon]$Icon = [System.Windows.Forms.ToolTipIcon]::Info)
    $notifyIcon.BalloonTipTitle = $Title
    $notifyIcon.BalloonTipText = $Text
    $notifyIcon.BalloonTipIcon = $Icon
    $notifyIcon.ShowBalloonTip(3000)
}

function Update-TrayStatus {
    try {
        $status = Get-ProxyToggleStatus -StatePath $StatePath -RegistryKey $RegistryKey -SkipWinHttp
        $on = $status.WinInet.ProxyEnable -eq 1
        $server = if ($status.WinInet.ProxyServer) { $status.WinInet.ProxyServer } else { 'no server' }
        $statusItem.Text = if ($on) { "Proxy: ON ($server)" } else { 'Proxy: OFF (direct)' }
        $notifyIcon.Text = if ($on) { 'WinProxyToggle - Proxy ON' } else { 'WinProxyToggle - Proxy OFF' }
        $disableItem.Enabled = $on
        $enableItem.Enabled = -not $on
        $restoreItem.Enabled = $null -ne $status.SavedState
    } catch {
        $statusItem.Text = 'Proxy: status unavailable'
        Write-TrayLog "status failed: $($_.Exception.Message)"
    }
}

$disableItem.add_Click({
    try {
        $r = Disable-ProxyToggle -StatePath $StatePath -RegistryKey $RegistryKey
        Show-Balloon 'Proxy disabled' "System proxy is now OFF. WinHTTP: $($r.WinHttp)"
        Write-TrayLog 'disabled'
    } catch {
        Show-Balloon 'Proxy disable failed' $_.Exception.Message ([System.Windows.Forms.ToolTipIcon]::Error)
        Write-TrayLog "disable failed: $($_.Exception.Message)"
    }
    Update-TrayStatus
})

$enableItem.add_Click({
    try {
        $r = Enable-ProxyToggle -StatePath $StatePath -RegistryKey $RegistryKey
        Show-Balloon 'Proxy enabled' "System proxy is now ON. Server: $($r.ProxyServer)"
        Write-TrayLog 'enabled'
    } catch {
        Show-Balloon 'Proxy enable failed' $_.Exception.Message ([System.Windows.Forms.ToolTipIcon]::Error)
        Write-TrayLog "enable failed: $($_.Exception.Message)"
    }
    Update-TrayStatus
})

$restoreItem.add_Click({
    try {
        $r = Restore-ProxyToggle -StatePath $StatePath -RegistryKey $RegistryKey
        Show-Balloon 'Proxy restored' "Restored previous state. WinHTTP: $($r.WinHttp)"
        Write-TrayLog 'restored'
    } catch {
        Show-Balloon 'Restore failed' $_.Exception.Message ([System.Windows.Forms.ToolTipIcon]::Error)
        Write-TrayLog "restore failed: $($_.Exception.Message)"
    }
    Update-TrayStatus
})

$aboutItem.add_Click({
    try {
        Start-Process explorer.exe $logDir
    } catch { }
})

$exitItem.add_Click({
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

$notifyIcon.add_DoubleClick({
    try {
        $status = Get-ProxyToggleStatus -StatePath $StatePath -RegistryKey $RegistryKey -SkipWinHttp
        if ($status.WinInet.ProxyEnable -eq 1) {
            $null = Disable-ProxyToggle -StatePath $StatePath -RegistryKey $RegistryKey
            Show-Balloon 'Proxy disabled' 'Double-click toggle: proxy is now OFF.'
        } else {
            $null = Enable-ProxyToggle -StatePath $StatePath -RegistryKey $RegistryKey
            Show-Balloon 'Proxy enabled' 'Double-click toggle: proxy is now ON.'
        }
    } catch {
        Show-Balloon 'Toggle failed' $_.Exception.Message ([System.Windows.Forms.ToolTipIcon]::Error)
    }
    Update-TrayStatus
})

$menu.add_Opening({ Update-TrayStatus })

$notifyIcon.add_MouseUp({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        # The context menu opens on right-click; left-click is a quick status balloon.
        Update-TrayStatus
    }
})

[System.Windows.Forms.Application]::EnableVisualStyles()
Update-TrayStatus
Show-Balloon 'WinProxyToggle' 'Tray icon is running. Right-click for actions.'
Write-TrayLog 'tray started'

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    if ($trayIconData.Handle -ne [IntPtr]::Zero) {
        [void][ProxyToggleTrayNative]::DestroyIcon($trayIconData.Handle)
    }
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
    Write-TrayLog 'tray exited'
}
