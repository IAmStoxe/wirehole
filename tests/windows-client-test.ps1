#Requires -Version 5.1
<#
.SYNOPSIS
    WireHole - test a VPN connection from a Windows computer.

.DESCRIPTION
    This script connects this Windows computer to your WireHole server and
    checks that the connection works. It then disconnects again.

    The script does these checks:
      1. The WireGuard program is installed.
      2. The VPN port of the server answers.
      3. The tunnel starts and the handshake succeeds.
      4. The server answers inside the tunnel.
      5. Pi-hole answers the DNS queries.
      6. Pi-hole blocks an advertisement domain.

    The script removes the tunnel at the end. It leaves nothing behind.

    RUN THIS SCRIPT AS ADMINISTRATOR. WireGuard needs administrator rights
    to make a network interface.

    The script runs on Windows PowerShell 5.1, which every Windows computer
    has, and on PowerShell 7.

.PARAMETER ConfigPath
    The path to the client file that you downloaded from the VPN web
    interface. The file ends with ".conf".

.PARAMETER PiholeIp
    The address of Pi-hole. The default value is 10.2.0.100.

.PARAMETER ServerVpnIp
    The address of the server inside the tunnel. The default value is
    10.8.0.1, which wg-easy uses. The profile "wireguard" uses 10.13.13.1.

.PARAMETER Endpoint
    Use another address for the server. Give this value when you test on
    your own Wi-Fi and the file holds a public address.
    Example: -Endpoint 192.168.1.50

.EXAMPLE
    .\windows-client-test.ps1 -ConfigPath .\phone.conf

.EXAMPLE
    .\windows-client-test.ps1 -ConfigPath .\phone.conf -Endpoint 192.168.1.50
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [string]$PiholeIp = '10.2.0.100',
    [string]$ServerVpnIp = '10.8.0.1',
    [string]$Endpoint = ''
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 has no variable $IsWindows. That version only runs
# on Windows, so the value is true there.
if ($null -eq $IsWindows) { $IsWindows = $true }

# Test-Connection has different parameters in 5.1 and in 7. This function
# hides the difference.
function Test-Reachable {
    param([string]$Target, [int]$Count = 1)
    try {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            return (Test-Connection -TargetName $Target -Count $Count -Quiet -TimeoutSeconds 2 -ErrorAction SilentlyContinue)
        }
        return (Test-Connection -ComputerName $Target -Count $Count -Quiet -ErrorAction SilentlyContinue)
    }
    catch { return $false }
}

$script:Pass = 0
$script:Fail = 0
$script:TunnelName = ''
$script:WorkConfig = ''

function Write-Head { param($Text) Write-Host "`n$Text" -ForegroundColor White }
function Write-Pass { param($Text) Write-Host "  [ PASS ] $Text" -ForegroundColor Green; $script:Pass++ }
function Write-Fail { param($Text) Write-Host "  [ FAIL ] $Text" -ForegroundColor Red; $script:Fail++ }
function Write-Note { param($Text) Write-Host "  ....... $Text" -ForegroundColor Gray }
function Write-Fix  { param($Text) Write-Host "           -> $Text" -ForegroundColor Yellow }

function Remove-TestTunnel {
    if ($script:TunnelName -and $IsWindows) {
        & "$env:ProgramFiles\WireGuard\wireguard.exe" /uninstalltunnelservice $script:TunnelName 2>&1 | Out-Null
        # Wait until the service is really gone. Windows removes it a few
        # seconds after the command returns.
        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep -Seconds 1
            $s = Get-Service -Name "WireGuardTunnel`$$($script:TunnelName)" -ErrorAction SilentlyContinue
            if (-not $s) { break }
        }
    }
    if ($script:WorkConfig -and (Test-Path $script:WorkConfig)) {
        Remove-Item $script:WorkConfig -Force -ErrorAction SilentlyContinue
    }
}

try {
    # -----------------------------------------------------------------------
    Write-Head '1. Check this computer'
    # -----------------------------------------------------------------------

    if (-not $IsWindows) {
        Write-Fail 'This script only runs on Windows.'
        Write-Fix 'On Linux or macOS, use ./tests/e2e-vpn.sh instead.'
        exit 1
    }
    Write-Pass 'This computer runs Windows.'

    $admin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
             ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($admin) {
        Write-Pass 'The script runs as administrator.'
    }
    else {
        Write-Fail 'The script does not run as administrator.'
        Write-Fix 'Open PowerShell 7 with "Run as administrator" and try again.'
        exit 1
    }

    $wgExe = Join-Path $env:ProgramFiles 'WireGuard\wireguard.exe'
    $wgCli = Join-Path $env:ProgramFiles 'WireGuard\wg.exe'
    if (Test-Path $wgExe) {
        Write-Pass 'The WireGuard program is installed.'
    }
    else {
        Write-Fail 'WireGuard is not installed.'
        Write-Fix 'Get it from https://www.wireguard.com/install/'
        Write-Fix 'Or run: winget install WireGuard.WireGuard'
        exit 1
    }

    if (-not (Test-Path $ConfigPath)) {
        Write-Fail "The file '$ConfigPath' does not exist."
        Write-Fix 'Download a client file from the VPN web interface first.'
        exit 1
    }
    Write-Pass "The client file exists ($ConfigPath)."

    # -----------------------------------------------------------------------
    Write-Head '2. Prepare the tunnel'
    # -----------------------------------------------------------------------

    $conf = Get-Content $ConfigPath -Raw

    # Use a narrow AllowedIPs value. A full tunnel would send all traffic of
    # this computer through the VPN during the test, and that is not needed
    # to prove that the connection works.
    $conf = $conf -replace '(?m)^\s*AllowedIPs\s*=.*', "AllowedIPs = $ServerVpnIp/32, $PiholeIp/32"

    if ($Endpoint) {
        $conf = $conf -replace '(?m)^\s*Endpoint\s*=\s*[^:]+:', "Endpoint = ${Endpoint}:"
        Write-Note "The test uses the address $Endpoint for the server."
    }

    $endpointLine = ($conf -split "`n" | Where-Object { $_ -match '^\s*Endpoint' }) -join ''
    if ($endpointLine -match 'Endpoint\s*=\s*(.+?):(\d+)') {
        $serverHost = $Matches[1].Trim()
        $serverPort = $Matches[2]
        Write-Note "The server is $serverHost on port $serverPort."
    }
    else {
        Write-Fail 'The client file has no Endpoint line.'
        exit 1
    }

    # WireGuard takes the tunnel name from the file name.
    $script:TunnelName = 'whtest'
    $script:WorkConfig = Join-Path $env:TEMP "$($script:TunnelName).conf"
    Set-Content -Path $script:WorkConfig -Value $conf -Encoding ascii
    Write-Pass 'The test made a temporary tunnel file.'

    # -----------------------------------------------------------------------
    Write-Head '3. Start the tunnel'
    # -----------------------------------------------------------------------

    & $wgExe /installtunnelservice $script:WorkConfig 2>&1 | Out-Null

    # Windows needs time to install the service and then start it. The wait
    # must be a loop. A single short pause reports a false failure on a
    # computer that is only a little slower.
    $service = $null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        $service = Get-Service -Name "WireGuardTunnel`$$($script:TunnelName)" -ErrorAction SilentlyContinue
        if ($service -and $service.Status -eq 'Running') { break }
    }

    if ($service -and $service.Status -eq 'Running') {
        Write-Pass 'The tunnel service runs.'
    }
    else {
        $state = if ($service) { $service.Status } else { 'not installed' }
        Write-Fail "The tunnel service did not start (state: $state)."
        Write-Fix 'Open the WireGuard program and look at the log.'
        exit 1
    }

    # -----------------------------------------------------------------------
    Write-Head '4. Test the connection'
    # -----------------------------------------------------------------------

    $handshake = $false
    for ($i = 0; $i -lt 15; $i++) {
        Test-Reachable -Target $ServerVpnIp -Count 1 | Out-Null
        $hs = (& $wgCli show $script:TunnelName latest-handshakes 2>$null)
        if ($hs) {
            $value = ($hs -split '\s+')[1]
            if ($value -and $value -ne '0') { $handshake = $true; break }
        }
        Start-Sleep -Seconds 2
    }

    if ($handshake) {
        Write-Pass 'The handshake succeeded. This computer reached the server.'
    }
    else {
        Write-Fail 'No handshake. This computer cannot reach the VPN server.'
        Write-Fix "Check that UDP port $serverPort reaches your server."
        Write-Fix 'On your own Wi-Fi, use -Endpoint with the local address of the server.'
        Write-Fix 'From outside, check the port forwarding rule in your router.'
    }

    if ($handshake) {
        if (Test-Reachable -Target $ServerVpnIp -Count 2) {
            Write-Pass 'Traffic passes through the tunnel.'
        }
        else {
            Write-Note 'The server does not answer a ping. Some servers refuse ping.'
        }

        # -------------------------------------------------------------------
        Write-Head '5. Test the DNS and the ad blocking'
        # -------------------------------------------------------------------

        try {
            $answer = Resolve-DnsName -Name 'example.com' -Server $PiholeIp -Type A -DnsOnly -QuickTimeout -ErrorAction Stop
            $ip = ($answer | Where-Object { $_.IPAddress } | Select-Object -First 1).IPAddress
            if ($ip) {
                Write-Pass "Pi-hole answers the DNS queries ($ip)."
            }
            else {
                Write-Fail 'Pi-hole gave an empty answer.'
            }
        }
        catch {
            Write-Fail 'Pi-hole does not answer through the tunnel.'
            Write-Fix "Check that $PiholeIp is inside the AllowedIPs of your client."
        }

        try {
            $blocked = Resolve-DnsName -Name 'doubleclick.net' -Server $PiholeIp -Type A -DnsOnly -QuickTimeout -ErrorAction Stop
            $bip = ($blocked | Where-Object { $_.IPAddress } | Select-Object -First 1).IPAddress
            if ($bip -eq '0.0.0.0') {
                Write-Pass 'Pi-hole blocks an advertisement domain.'
            }
            else {
                Write-Fail "Pi-hole did not block the test domain (got '$bip')."
            }
        }
        catch {
            Write-Note 'The blocked domain gave no answer. That is also a block.'
            $script:Pass++
        }
    }
}
finally {
    Write-Head 'Clean up'
    Remove-TestTunnel
    $left = $null
    if ($IsWindows) {
        $left = Get-Service -Name "WireGuardTunnel`$whtest" -ErrorAction SilentlyContinue
    }
    if ($left) {
        Write-Fail 'The tunnel service is still installed.'
        Write-Fix "Remove it with: & '$env:ProgramFiles\WireGuard\wireguard.exe' /uninstalltunnelservice whtest"
    }
    else {
        Write-Host '  ....... The test removed the tunnel.' -ForegroundColor Gray
    }

    Write-Head 'Result'
    Write-Host "  Passed: $script:Pass"
    Write-Host "  Failed: $script:Fail"
    if ($script:Fail -eq 0 -and $script:Pass -gt 0) {
        Write-Host "`nThis Windows computer connects and gets filtered internet.`n" -ForegroundColor Green
    }
    else {
        Write-Host "`nSome tests failed. Read the suggestions above.`n" -ForegroundColor Red
    }
}
