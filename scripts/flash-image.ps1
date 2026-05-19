#Requires -Version 7.0

<#
.SYNOPSIS
    Flash an OS image plus first-run config to an SD card for the AdGuard DNS appliance.

.DESCRIPTION
    Automates the full Phase 0 pipeline:
        1. Download and cache the correct OS image (with checksum verification)
        2. Prepare a first-run script (RPi OS) or cloud-init user-data (Ubuntu)
        3. Write the image to disk via rpi-imager --cli (--disable-eject)
        4. Inject the provisioning config onto the boot partition

    Node types, OS images, and config mappings are defined in flash-config.psd1.

.PARAMETER NodeType
    Node type - determines the OS image and cloud-init template to use.
    Must match a key in flash-config.psd1 NodeImageMap (e.g. pi-zero-dns).

.PARAMETER Hostname
    Hostname to assign to the node. Defaults to NodeType if not specified.

.PARAMETER IP
    Optional static IP to substitute into the cloud-init template. Most home
    networks are better off using a DHCP reservation on the router; leave this empty.

.PARAMETER DiskNumber
    Target disk number - skips interactive disk selection. Use Get-Disk to find it.

.PARAMETER CacheDir
    Directory for caching downloaded OS images. Defaults to ~/.cache/adguard-dns-images.

.PARAMETER SkipCloudInit
    Skip first-run config injection - only flash the image.

.PARAMETER Force
    Skip the disk destruction confirmation prompt.

.PARAMETER WiFiSSID
    WiFi network name. Required for Pi Zero nodes (WiFi-only hardware).

.PARAMETER WiFiPassword
    WiFi password as SecureString. Prompted if WiFiSSID is provided without it.

.PARAMETER WiFiCountryCode
    WiFi regulatory country code (ISO 3166-1 alpha-2). Defaults to 'US'.

.PARAMETER Username
    OS username created on first boot. Defaults to 'admin'.

.PARAMETER SshPublicKey
    SSH public key for the admin user. If omitted, the script reads
    $env:USERPROFILE\.ssh\id_ed25519.pub and falls back to id_rsa.pub.

.EXAMPLE
    .\scripts\flash-image.ps1 -NodeType pi-zero-dns -Hostname dns-1 `
        -WiFiSSID "HomeNet" -WiFiPassword (Read-Host -AsSecureString)

.EXAMPLE
    .\scripts\flash-image.ps1 -NodeType pi-zero-dns -Hostname dns-1 `
        -WiFiSSID "HomeNet" -WiFiPassword (Read-Host -AsSecureString) `
        -Username pi -WiFiCountryCode GB -DiskNumber 3 -Force
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, HelpMessage = 'Node type - determines OS image and cloud-init template')]
    [string] $NodeType,

    [Parameter(HelpMessage = 'Hostname to assign to the node')]
    [string] $Hostname,

    [Parameter(HelpMessage = 'Static IP address for cloud-init network config')]
    [string] $IP,

    [Parameter(HelpMessage = 'Target disk number - skip interactive selection')]
    [int] $DiskNumber = -1,

    [Parameter(HelpMessage = 'Directory for caching downloaded OS images')]
    [string] $CacheDir,

    [Parameter(HelpMessage = 'Skip provisioning config - only flash the image')]
    [switch] $SkipCloudInit,

    [Parameter(HelpMessage = 'Skip disk destruction confirmation prompt')]
    [switch] $Force,

    [Parameter(HelpMessage = 'WiFi network name - required for Pi Zero nodes')]
    [string] $WiFiSSID,

    [Parameter(HelpMessage = 'WiFi password as SecureString')]
    [SecureString] $WiFiPassword,

    [Parameter(HelpMessage = 'WiFi regulatory country code (ISO 3166-1 alpha-2)')]
    [string] $WiFiCountryCode = 'US',

    [Parameter(HelpMessage = 'OS username created on first boot')]
    [string] $Username = 'admin',

    [Parameter(HelpMessage = 'SSH public key (string). If omitted, reads ~/.ssh/id_ed25519.pub or id_rsa.pub')]
    [string] $SshPublicKey,

    [Parameter(HelpMessage = 'Timezone (IANA tz name, e.g. Etc/UTC, Europe/London)')]
    [string] $Timezone = 'Etc/UTC',

    [Parameter(HelpMessage = 'Flash flow - NVMe (direct) or SD (bootstrap, images NVMe on first boot)')]
    [ValidateSet('SD', 'NVMe')]
    [string] $Target = 'NVMe'
)

$ErrorActionPreference = 'Stop'

# --- Helpers ---

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script requires Administrator privileges. Right-click PowerShell and select "Run as Administrator".'
    }
}

# Minimum rpi-imager version: --cli + --disable-eject + --disable-verify
# all stabilised in the 1.8.x line. Recommended: 1.9.x or newer for the
# fewest CLI quirks. Renovate doesn't manage this binary, so bump by hand
# when the recommended floor moves.
$script:RpiImagerMinVersion = [version]'1.8.0'
$script:RpiImagerRecommendedVersion = [version]'1.9.0'

function Get-RpiImagerVersion {
    param([string] $ImagerPath)

    try {
        $raw = & $ImagerPath --version 2>&1 | Out-String
    }
    catch {
        return $null
    }
    # Output samples: "Raspberry Pi Imager v1.8.5", "rpi-imager 1.9.4".
    if ($raw -match '(\d+)\.(\d+)\.(\d+)') {
        return [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
    }
    if ($raw -match '(\d+)\.(\d+)') {
        return [version]"$($Matches[1]).$($Matches[2]).0"
    }
    return $null
}

function Find-RpiImager {
    $cmd = Get-Command 'rpi-imager' -ErrorAction SilentlyContinue
    $found = if ($cmd) { $cmd.Source } else { $null }

    if (-not $found) {
        $candidates = @(
            "$env:ProgramFiles\Raspberry Pi Ltd\Imager\rpi-imager.exe"
            "$env:ProgramFiles\Raspberry Pi Imager\rpi-imager.exe"
            "${env:ProgramFiles(x86)}\Raspberry Pi Imager\rpi-imager.exe"
            "$env:LOCALAPPDATA\Programs\Raspberry Pi Imager\rpi-imager.exe"
        )
        foreach ($path in $candidates) {
            if (Test-Path $path) { $found = $path; break }
        }
    }

    if (-not $found) {
        throw @"
rpi-imager not found. Install it with:
    winget install RaspberryPiFoundation.RaspberryPiImager
Then re-run this script. Minimum version: $($script:RpiImagerMinVersion); recommended: $($script:RpiImagerRecommendedVersion).
"@
    }

    $version = Get-RpiImagerVersion -ImagerPath $found
    if (-not $version) {
        Write-Host "  Could not detect rpi-imager version (got no parseable output) - proceeding, but $($script:RpiImagerMinVersion)+ is required." -ForegroundColor Yellow
    }
    elseif ($version -lt $script:RpiImagerMinVersion) {
        throw "rpi-imager $version is too old. Minimum required: $($script:RpiImagerMinVersion); recommended: $($script:RpiImagerRecommendedVersion). Upgrade with: winget upgrade RaspberryPiFoundation.RaspberryPiImager"
    }
    elseif ($version -lt $script:RpiImagerRecommendedVersion) {
        Write-Host "  rpi-imager $version meets the minimum but $($script:RpiImagerRecommendedVersion)+ is recommended." -ForegroundColor Yellow
    }
    else {
        Write-Host "  rpi-imager $version OK." -ForegroundColor DarkGray
    }

    return $found
}

function Invoke-ImageDownload {
    param(
        [string] $Url,
        [string] $DestPath,
        [string] $ExpectedHash,
        [string] $Algorithm
    )

    $destDir = Split-Path $DestPath -Parent
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    if (Test-Path $DestPath) {
        Write-Host "  Image cached at $DestPath, verifying checksum..." -ForegroundColor Cyan
        $hash = (Get-FileHash $DestPath -Algorithm $Algorithm).Hash
        if ($hash -eq $ExpectedHash) {
            Write-Host "  Checksum OK - using cached image." -ForegroundColor Green
            return
        }
        Write-Host "  Checksum mismatch (cache corrupted), re-downloading..." -ForegroundColor Yellow
        Remove-Item $DestPath -Force
    }

    $fileName = Split-Path $Url -Leaf
    Write-Host "  Downloading $fileName ..." -ForegroundColor Cyan
    Write-Host "  URL: $Url" -ForegroundColor DarkGray

    try {
        Start-BitsTransfer -Source $Url -Destination $DestPath -DisplayName "Downloading $fileName"
    }
    catch {
        Write-Host "  BITS transfer failed, falling back to Invoke-WebRequest..." -ForegroundColor Yellow
        Invoke-WebRequest -Uri $Url -OutFile $DestPath -UseBasicParsing
    }

    Write-Host "  Verifying checksum..." -ForegroundColor Cyan
    $hash = (Get-FileHash $DestPath -Algorithm $Algorithm).Hash
    if ($hash -ne $ExpectedHash) {
        Remove-Item $DestPath -Force
        throw "Checksum verification failed!`n  Expected: $ExpectedHash`n  Got:      $hash`nThe downloaded file has been deleted. Try again or check the URL."
    }
    Write-Host "  Checksum OK." -ForegroundColor Green
}

function Get-RemovableDisks {
    Get-Disk | Where-Object {
        $_.IsSystem -eq $false -and
        $_.IsBoot -eq $false -and
        (
            $_.BusType -in @('USB', 'SD') -or
            ($_.Size -lt 550GB -and $_.BusType -ne 'NVMe' -and $_.OperationalStatus -eq 'Online')
        )
    }
}

function Select-TargetDisk {
    param([int] $PreselectedDisk)

    $disks = Get-RemovableDisks
    if (-not $disks -or $disks.Count -eq 0) {
        throw "No removable/USB/SD disks found. Insert your target media and try again."
    }

    Write-Host "`n  Available disks:" -ForegroundColor Cyan
    $disks | Format-Table -Property @(
        @{Label = 'Disk#'; Expression = { $_.Number } }
        @{Label = 'Name'; Expression = { $_.FriendlyName } }
        @{Label = 'Size'; Expression = { '{0:N1} GB' -f ($_.Size / 1GB) } }
        @{Label = 'Bus'; Expression = { $_.BusType } }
        @{Label = 'Partition'; Expression = { $_.PartitionStyle } }
    ) | Out-Host

    if ($PreselectedDisk -ge 0) {
        $target = $disks | Where-Object { $_.Number -eq $PreselectedDisk }
        if (-not $target) {
            throw "Disk $PreselectedDisk is not in the list of safe removable disks."
        }
        return $target
    }

    $selection = Read-Host "  Enter disk number to flash"
    $diskNum = [int]$selection
    $target = $disks | Where-Object { $_.Number -eq $diskNum }
    if (-not $target) {
        throw "Disk $diskNum is not in the list of safe removable disks."
    }
    return $target
}

function Confirm-DiskSelection {
    param(
        [Microsoft.Management.Infrastructure.CimInstance] $Disk,
        [bool] $ForceMode
    )

    $sizeGB = '{0:N1} GB' -f ($Disk.Size / 1GB)
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "  ║  WARNING: ALL DATA ON THIS DISK WILL BE ERASED   ║" -ForegroundColor Red
    Write-Host "  ╠══════════════════════════════════════════════════╣" -ForegroundColor Red
    Write-Host "  ║  Disk $($Disk.Number): $($Disk.FriendlyName)" -ForegroundColor Red
    Write-Host "  ║  Size: $sizeGB  |  Bus: $($Disk.BusType)" -ForegroundColor Red
    Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Red

    if ($ForceMode) {
        Write-Host "  -Force specified, skipping confirmation." -ForegroundColor Yellow
        return $true
    }

    Write-Host ""
    $confirm = Read-Host "  Type the disk number ($($Disk.Number)) again to confirm, or anything else to abort"
    if ($confirm -ne "$($Disk.Number)") {
        Write-Host "  Aborted." -ForegroundColor Yellow
        return $false
    }
    return $true
}

function Build-FirstRunScript {
    param(
        [string] $Hostname,
        [string] $Username,
        [string] $SshPublicKey,
        [string] $WiFiSSID,
        [string] $PlainPassword,
        [string] $WiFiCountryCode
    )

    $script = @'
#!/bin/bash
# First-run script for RPi OS - makes the Pi reachable via SSH over WiFi.
# Everything else (packages, services, hardening) is handled by Ansible.
# Logs to /boot/firmware/firstrun.log (readable from Windows on the FAT32 partition).

LOG=/boot/firmware/firstrun.log
exec > "$LOG" 2>&1
set -x

echo "=== firstrun.sh started at $(date) ==="

# --- WiFi (uses the same tool as rpi-imager GUI) ---
rfkill unblock wifi || true
/usr/lib/raspberrypi-sys-mods/imager_custom set_wlan "__SSID__" "__WIFIPWD__" "__COUNTRY__"

# --- Hostname ---
raspi-config nonint do_hostname "__HOSTNAME__"

# --- User ---
useradd -m -s /bin/bash -G sudo "__USER__" || true
echo "__USER__ ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/010___USER__"
chmod 440 "/etc/sudoers.d/010___USER__"
mkdir -p "/home/__USER__/.ssh"
echo "__SSHKEY__" > "/home/__USER__/.ssh/authorized_keys"
chmod 700 "/home/__USER__/.ssh"
chmod 600 "/home/__USER__/.ssh/authorized_keys"
chown -R "__USER__:__USER__" "/home/__USER__/.ssh"

# --- Enable + start SSH ---
systemctl enable ssh
systemctl start ssh

echo "=== firstrun.sh completed at $(date) ==="

# --- Self-cleanup: remove firstrun trigger so the Pi doesn't reboot in a loop ---
sed -i 's| systemd.run=/boot/firmware/firstrun.sh||' /boot/firmware/cmdline.txt
sed -i 's| systemd.run_success_action=reboot||' /boot/firmware/cmdline.txt
sed -i 's| systemd.unit=kernel-command-line.target||' /boot/firmware/cmdline.txt
rm -f /boot/firmware/firstrun.sh
'@

    $script = $script.Replace('__COUNTRY__', $WiFiCountryCode)
    $script = $script.Replace('__SSID__', $WiFiSSID)
    $script = $script.Replace('__WIFIPWD__', $PlainPassword)
    $script = $script.Replace('__HOSTNAME__', $Hostname)
    $script = $script.Replace('__USER__', $Username)
    $script = $script.Replace('__SSHKEY__', $SshPublicKey)
    $script = $script -replace "`r`n", "`n"
    return $script
}

function Add-InstallToNvmeRuncmd {
    param(
        [string] $UserData,
        [string] $ImageUrl,
        [string] $ImageChecksum,
        [string] $ImageAlgorithm
    )

    # Append `- bash /boot/firmware/install-to-nvme.sh <url> <algo> <checksum>`
    # at the end of the runcmd: block (just before the next top-level YAML key
    # or EOF). YAML single-quoted strings are safe for typical URLs and hex
    # checksums - guard against URLs that contain a single quote.
    if ($ImageUrl -match "'") {
        throw "Image URL contains a single quote - refusing to inject into YAML runcmd."
    }
    $cmd = "  - bash /boot/firmware/install-to-nvme.sh '$ImageUrl' '$ImageAlgorithm' '$ImageChecksum'"

    $lines = $UserData -split "`r?`n", 0, 'SimpleMatch'
    $runcmdIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^runcmd:\s*$') {
            $runcmdIdx = $i
            break
        }
    }
    if ($runcmdIdx -lt 0) {
        # No runcmd block - synthesize one at the end.
        return $UserData.TrimEnd() + "`n`nruncmd:`n$cmd`n"
    }

    # Find the last line that still belongs to the runcmd block: indented or
    # blank. Insert our new list item right after it.
    $insertAfter = $runcmdIdx
    for ($i = $runcmdIdx + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*$' -or $lines[$i] -match '^[ \t]') {
            $insertAfter = $i
        }
        else {
            break
        }
    }
    # Skip trailing blanks so the new item sits next to existing items.
    while ($insertAfter -gt $runcmdIdx -and $lines[$insertAfter] -match '^\s*$') {
        $insertAfter--
    }

    $head = $lines[0..$insertAfter]
    if ($insertAfter + 1 -lt $lines.Count) {
        $tail = $lines[($insertAfter + 1)..($lines.Count - 1)]
    }
    else {
        $tail = @()
    }
    return ((@($head) + @($cmd) + @($tail)) -join "`n")
}

function Build-ImageConfig {
    param(
        [string] $NodeType,
        [string] $Hostname,
        [string] $IP,
        [string] $Username,
        [string] $SshPublicKey,
        [string] $Timezone,
        [string] $RepoRoot,
        [hashtable] $Config,
        [string] $WiFiSSID,
        [SecureString] $WiFiPassword,
        [string] $WiFiCountryCode,
        [string] $Target,
        [hashtable] $ImageConfig
    )

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "pi-flash-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    $imageKey = $Config.NodeImageMap[$NodeType]
    $isCloudInit = $imageKey -like 'ubuntu-*'

    $result = @{ TempDir = $tempDir }

    if ($isCloudInit) {
        # Ubuntu images: use cloud-init
        $configFileName = $Config.NodeConfigMap[$NodeType]
        if (-not $configFileName) {
            $validTypes = ($Config.NodeConfigMap.Keys | Sort-Object) -join ', '
            throw "No cloud-init config for node type '$NodeType'. Valid types: $validTypes"
        }

        $configPath = Join-Path $RepoRoot "cloud-init" $configFileName
        if (-not (Test-Path $configPath)) {
            throw "Cloud-init config not found: $configPath"
        }

        $content = Get-Content $configPath -Raw

        # Substitute __PLACEHOLDER__ tokens used in cloud-init/ templates.
        $content = $content.Replace('__HOSTNAME__', $Hostname)
        $content = $content.Replace('__ADMIN_USER__', $Username)
        $content = $content.Replace('__TIMEZONE__', $Timezone)
        $content = $content.Replace('__SSH_PUBLIC_KEY__', $SshPublicKey)

        $baseIp = $Config.BaseIpMap[$NodeType]
        if ($baseIp -and $IP -and $baseIp -ne $IP) {
            $escapedBaseIp = [regex]::Escape($baseIp)
            $content = $content -replace $escapedBaseIp, $IP
        }

        if ($Target -eq 'SD') {
            $content = Add-InstallToNvmeRuncmd `
                -UserData $content `
                -ImageUrl $ImageConfig.Url `
                -ImageChecksum $ImageConfig.Checksum `
                -ImageAlgorithm $ImageConfig.Algorithm
            Write-Host "  Injected install-to-nvme.sh runcmd into user-data" -ForegroundColor DarkGray
        }

        $result.UserDataPath = Join-Path $tempDir 'user-data'
        Set-Content -Path $result.UserDataPath -Value $content -NoNewline -Encoding utf8NoBOM

        if ($WiFiSSID) {
            $credential = [System.Net.NetworkCredential]::new('', $WiFiPassword)
            $plainPwd = $credential.Password
            # editorconfig-checker-disable
            $networkConfig = @"
version: 2
wifis:
  wlan0:
    dhcp4: true
    access-points:
      "$WiFiSSID":
        password: "$plainPwd"
"@
            # editorconfig-checker-enable
            $result.NetworkConfigPath = Join-Path $tempDir 'network-config'
            Set-Content -Path $result.NetworkConfigPath -Value $networkConfig -NoNewline -Encoding utf8NoBOM
            $plainPwd = $null
            [GC]::Collect()
        }

        Write-Host "  Cloud-init prepared (Ubuntu):" -ForegroundColor Green
        Write-Host "    Source:   cloud-init/$configFileName" -ForegroundColor DarkGray
    }
    else {
        # RPi OS images: use firstrun script
        $configFileName = $Config.NodeConfigMap[$NodeType]

        $plainPwd = ''
        if ($WiFiPassword) {
            $credential = [System.Net.NetworkCredential]::new('', $WiFiPassword)
            $plainPwd = $credential.Password
        }

        $script = Build-FirstRunScript `
            -Hostname $Hostname `
            -Username $Username `
            -SshPublicKey $SshPublicKey `
            -WiFiSSID $WiFiSSID `
            -PlainPassword $plainPwd `
            -WiFiCountryCode $WiFiCountryCode

        $result.FirstRunScriptPath = Join-Path $tempDir 'firstrun.sh'
        Set-Content -Path $result.FirstRunScriptPath -Value $script -NoNewline -Encoding utf8NoBOM

        $plainPwd = $null
        [GC]::Collect()

        Write-Host "  First-run script prepared (RPi OS):" -ForegroundColor Green
        Write-Host "    Source:   cloud-init/$configFileName (extracted settings)" -ForegroundColor DarkGray
    }

    if ($Hostname) {
        Write-Host "    Hostname: $Hostname" -ForegroundColor DarkGray
    }
    Write-Host "    Username: $Username" -ForegroundColor DarkGray
    if ($IP) {
        Write-Host "    IP:       $IP" -ForegroundColor DarkGray
    }
    if ($WiFiSSID) {
        Write-Host "    WiFi:     $WiFiSSID" -ForegroundColor DarkGray
    }

    return $result
}

function Write-ImageToDisk {
    param(
        [string] $ImagePath,
        [int] $DiskNum
    )

    $imager = Find-RpiImager
    $devicePath = "\\.\PhysicalDrive$DiskNum"
    $imagerArgs = @('--cli', '--disable-eject', '--disable-verify', "`"$ImagePath`"", "`"$devicePath`"")

    Write-Host "  Writing image to disk $DiskNum ($devicePath)..." -ForegroundColor Cyan
    Write-Host "  This may take several minutes." -ForegroundColor DarkGray

    $process = Start-Process -FilePath $imager -ArgumentList $imagerArgs `
        -Wait -PassThru -NoNewWindow

    if ($process.ExitCode -ne 0) {
        throw "rpi-imager exited with code $($process.ExitCode). Check the output above for errors."
    }

    Write-Host "  Image written successfully." -ForegroundColor Green
}

function Find-BootPartition {
    param([int] $DiskNum)

    Write-Host "  Rescanning disk $DiskNum..." -ForegroundColor Cyan
    Update-Disk -Number $DiskNum -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    $attempts = 15
    for ($i = 0; $i -lt $attempts; $i++) {
        $partitions = Get-Partition -DiskNumber $DiskNum -ErrorAction SilentlyContinue
        foreach ($part in $partitions) {
            $vol = $part | Get-Volume -ErrorAction SilentlyContinue
            if ($vol -and $vol.FileSystem -eq 'FAT32') {
                if (-not $vol.DriveLetter) {
                    $part | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 2
                    $vol = $part | Get-Volume -ErrorAction SilentlyContinue
                }
                if ($vol.DriveLetter) {
                    $path = "$($vol.DriveLetter):\"
                    Write-Host "  Boot partition found at $path" -ForegroundColor Green
                    return $path
                }
            }
        }
        if ($i -lt $attempts - 1) {
            Write-Host "  Waiting for boot partition... ($($i + 1)/$attempts)" -ForegroundColor DarkGray
            Start-Sleep -Seconds 2
        }
    }

    $partInfo = @()
    foreach ($part in $partitions) {
        $vol = $part | Get-Volume -ErrorAction SilentlyContinue
        $fs = if ($vol) { $vol.FileSystem } else { 'unknown' }
        $partInfo += "  Partition $($part.PartitionNumber): $($part.Size / 1MB) MB, filesystem=$fs"
    }
    throw "Could not find FAT32 boot partition on disk $DiskNum after $attempts attempts.`n$($partInfo -join "`n")"
}

function Install-ProvisionConfig {
    param(
        [string] $BootPath,
        [hashtable] $ProvisionConfig,
        [bool] $IsCloudInit
    )

    if ($IsCloudInit) {
        if ($ProvisionConfig.UserDataPath) {
            Copy-Item $ProvisionConfig.UserDataPath (Join-Path $BootPath 'user-data') -Force
            Write-Host "  Wrote user-data to boot partition" -ForegroundColor Green
        }
        if ($ProvisionConfig.NetworkConfigPath) {
            Copy-Item $ProvisionConfig.NetworkConfigPath (Join-Path $BootPath 'network-config') -Force
            Write-Host "  Wrote network-config to boot partition" -ForegroundColor Green
        }
    }
    else {
        if ($ProvisionConfig.FirstRunScriptPath) {
            $destScript = Join-Path $BootPath 'firstrun.sh'
            Copy-Item $ProvisionConfig.FirstRunScriptPath $destScript -Force
            Write-Host "  Wrote firstrun.sh to boot partition" -ForegroundColor Green

            $cmdlinePath = Join-Path $BootPath 'cmdline.txt'
            if (-not (Test-Path $cmdlinePath)) {
                throw "cmdline.txt not found at $cmdlinePath - unexpected boot partition layout."
            }
            $cmdline = (Get-Content $cmdlinePath -Raw).TrimEnd()
            $cmdline += " systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target"
            [System.IO.File]::WriteAllText($cmdlinePath, $cmdline)
            Write-Host "  Updated cmdline.txt with firstrun trigger" -ForegroundColor Green
        }
    }
}

# --- Main ---

Write-Host ""
Write-Host "  AdGuard DNS - Image Flash Tool" -ForegroundColor Magenta
Write-Host "  Type:     $NodeType" -ForegroundColor White
if ($Hostname) {
    Write-Host "  Hostname: $Hostname" -ForegroundColor White
}
if ($IP) {
    Write-Host "  IP:       $IP" -ForegroundColor White
}
Write-Host "  Target:   $Target" -ForegroundColor White
Write-Host ""

Assert-Administrator

if ($IP -and $IP -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
    throw "Invalid IP address format: '$IP'. Expected IPv4 (e.g., 192.0.2.10)."
}

if (-not $Hostname) {
    $Hostname = $NodeType
}

# Resolve SSH public key - explicit param wins, otherwise read default key.
if (-not $SshPublicKey) {
    $sshDefaults = @(
        Join-Path $env:USERPROFILE '.ssh\id_ed25519.pub'
        Join-Path $env:USERPROFILE '.ssh\id_rsa.pub'
    )
    foreach ($keyPath in $sshDefaults) {
        if (Test-Path $keyPath) {
            $SshPublicKey = (Get-Content $keyPath -Raw).Trim()
            Write-Host "  SSH key:  $keyPath" -ForegroundColor DarkGray
            break
        }
    }
    if (-not $SshPublicKey) {
        throw "No SSH public key found. Provide -SshPublicKey or create ~/.ssh/id_ed25519.pub (run: ssh-keygen -t ed25519)."
    }
}
if ($SshPublicKey -notmatch '^(ssh-(ed25519|rsa)|ecdsa-sha2-)') {
    throw "SshPublicKey does not look like a valid OpenSSH public key."
}

# Load config
$scriptDir = $PSScriptRoot
$repoRoot = Split-Path $scriptDir -Parent
$configPath = Join-Path $scriptDir 'flash-config.psd1'

if (-not (Test-Path $configPath)) {
    throw "Config file not found: $configPath"
}

$config = Import-PowerShellDataFile $configPath

# Resolve node type -> image
$imageKey = $config.NodeImageMap[$NodeType]
if (-not $imageKey) {
    $validTypes = ($config.NodeImageMap.Keys | Sort-Object) -join ', '
    throw "Unknown node type '$NodeType'. Valid types: $validTypes"
}

$imageConfig = $config.Images[$imageKey]
if (-not $imageConfig) {
    throw "No image definition for '$imageKey'"
}

Write-Host "  Image:    $imageKey" -ForegroundColor White

# -Target SD requires cloud-init (Ubuntu): the bootstrap runs from cloud-init's
# runcmd. RPi OS nodes use a firstrun script flow that doesn't carry the same
# semantics, so reject the combination loudly rather than silently producing
# something that won't boot.
if ($Target -eq 'SD' -and $imageKey -notlike 'ubuntu-*') {
    throw "-Target SD is only supported for cloud-init (Ubuntu) node types. '$NodeType' uses '$imageKey'. Use -Target NVMe (default) instead."
}

# When -Target SD, verify the bootstrap script exists in the repo before we
# start flashing - failing later means the SD is half-configured.
$installToNvmePath = Join-Path $repoRoot 'scripts' 'install-to-nvme.sh'
if ($Target -eq 'SD' -and -not (Test-Path $installToNvmePath)) {
    throw "scripts/install-to-nvme.sh not found at $installToNvmePath - required for -Target SD."
}

# WiFi required for Pi Zero nodes (WiFi-only, no Ethernet)
if ($NodeType -like 'pi-zero-*' -and -not $SkipCloudInit) {
    if (-not $WiFiSSID) {
        throw "Pi Zero nodes require WiFi. Provide -WiFiSSID and -WiFiPassword parameters."
    }
    if (-not $WiFiPassword) {
        $WiFiPassword = Read-Host "  Enter WiFi password for '$WiFiSSID'" -AsSecureString
    }
    Write-Host "  WiFi:     $WiFiSSID ($WiFiCountryCode)" -ForegroundColor White
}

# Determine cache directory
if (-not $CacheDir) {
    $CacheDir = Join-Path $env:USERPROFILE '.cache' 'adguard-dns-images'
}

$fileName = Split-Path $imageConfig.Url -Leaf
$imagePath = Join-Path $CacheDir $fileName

# Step 1: Download image
Write-Host "`n[1/4] Image Download" -ForegroundColor Yellow
Write-Host "  ─────────────────" -ForegroundColor DarkGray

if ($PSCmdlet.ShouldProcess($imageConfig.Url, "Download image")) {
    Invoke-ImageDownload `
        -Url $imageConfig.Url `
        -DestPath $imagePath `
        -ExpectedHash $imageConfig.Checksum `
        -Algorithm $imageConfig.Algorithm
}

# Step 2: Prepare provisioning config
$provisionConfig = $null
if (-not $SkipCloudInit) {
    Write-Host "`n[2/4] Provisioning Config" -ForegroundColor Yellow
    Write-Host "  ───────────────────────" -ForegroundColor DarkGray

    $provisionConfig = Build-ImageConfig -NodeType $NodeType -Hostname $Hostname -IP $IP `
        -Username $Username -SshPublicKey $SshPublicKey -Timezone $Timezone `
        -RepoRoot $repoRoot -Config $config `
        -WiFiSSID $WiFiSSID -WiFiPassword $WiFiPassword -WiFiCountryCode $WiFiCountryCode `
        -Target $Target -ImageConfig $imageConfig
}
else {
    Write-Host "`n[2/4] Provisioning Config" -ForegroundColor Yellow
    Write-Host "  Skipped (-SkipCloudInit)" -ForegroundColor DarkGray
}

# Step 3: Flash image to disk
Write-Host "`n[3/4] Flash to Disk" -ForegroundColor Yellow
Write-Host "  ─────────────────" -ForegroundColor DarkGray

$disk = Select-TargetDisk -PreselectedDisk $DiskNumber

if (-not (Confirm-DiskSelection -Disk $disk -ForceMode $Force)) {
    exit 0
}

if ($PSCmdlet.ShouldProcess("Disk $($disk.Number) ($($disk.FriendlyName))", "Write OS image")) {
    Write-ImageToDisk -ImagePath $imagePath -DiskNum $disk.Number
}

# Step 4: Inject provisioning config onto boot partition
if ($provisionConfig) {
    Write-Host "`n[4/4] Inject Config" -ForegroundColor Yellow
    Write-Host "  ─────────────────" -ForegroundColor DarkGray

    $bootPath = Find-BootPartition -DiskNum $disk.Number
    $isCloudInit = $imageKey -like 'ubuntu-*'
    Install-ProvisionConfig -BootPath $bootPath -ProvisionConfig $provisionConfig -IsCloudInit $isCloudInit

    if ($Target -eq 'SD') {
        # Copy install-to-nvme.sh to the SD's boot partition. The script reads
        # the image URL + SHA256 from arguments in the cloud-init runcmd line
        # and downloads the image at first boot - this avoids the FAT32 boot
        # partition (~512 MB) being too small for the ~1.2 GB Ubuntu .img.xz.
        $scriptDest = Join-Path $bootPath 'install-to-nvme.sh'
        Copy-Item $installToNvmePath $scriptDest -Force
        Write-Host "  Wrote install-to-nvme.sh to boot partition" -ForegroundColor Green
    }
}

# Clean up temp files
if ($provisionConfig -and $provisionConfig.TempDir -and (Test-Path $provisionConfig.TempDir)) {
    Remove-Item $provisionConfig.TempDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Summary
Write-Host ""
Write-Host "  ════════════════════════════════════" -ForegroundColor Green
Write-Host "  Done! $Hostname is ready." -ForegroundColor Green
Write-Host "  ════════════════════════════════════" -ForegroundColor Green
Write-Host ""
$isCloudInit = $config.NodeImageMap[$NodeType] -like 'ubuntu-*'
Write-Host "  Next steps:" -ForegroundColor White
Write-Host "    1. Safely eject the SD card" -ForegroundColor DarkGray
Write-Host "    2. Insert into the Pi and power on" -ForegroundColor DarkGray
if ($isCloudInit) {
    Write-Host "    3. Wait for cloud-init to complete (~2-5 min) and auto-reboot" -ForegroundColor DarkGray
}
else {
    Write-Host "    3. Wait for first-run setup to complete (~1-2 min) and auto-reboot" -ForegroundColor DarkGray
}

if ($IP) {
    Write-Host "    4. SSH in: ssh $Username@$IP" -ForegroundColor DarkGray
}
else {
    Write-Host "    4. SSH in: ssh $Username@<dhcp-assigned-ip>" -ForegroundColor DarkGray
}

Write-Host ""
