# splash-replace.ps1 — volunteer-facing script (Windows).
#
# Replaces the splash image on the church-display Pi. Validates the file
# locally first (so an obviously-wrong file fails fast with a clear
# message), then uploads via SSH to the kiosk. The Pi re-validates on
# arrival and refuses to install anything that isn't a 1920x1080 PNG.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File splash-replace.ps1 <path\to\image.png>
#
# Optional environment:
#   $env:SPLASH_HOST       Override the Pi hostname/IP (default: displaypi)
#   $env:SPLASH_KEY        Override path to the SSH private key
#                          (default: splash-updater next to this script,
#                           then $HOME\.ssh\splash-updater)
#
# Requires: Windows 10 or 11 (built-in OpenSSH client). No extra installs.

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$ImagePath
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$Host_ = $env:SPLASH_HOST
if (-not $Host_) { $Host_ = 'displaypi' }

# Locate SSH key: env var > bundled > $HOME\.ssh.
$Key = $env:SPLASH_KEY
if (-not $Key) {
    $candidate = Join-Path $ScriptDir 'splash-updater'
    if (Test-Path $candidate) { $Key = $candidate }
}
if (-not $Key) {
    $candidate = Join-Path $HOME '.ssh\splash-updater'
    if (Test-Path $candidate) { $Key = $candidate }
}
if (-not $Key) {
    Write-Host 'ERROR: SSH key not found.' -ForegroundColor Red
    Write-Host '       Place the splash-updater key file next to this script,'
    Write-Host '       or at %USERPROFILE%\.ssh\splash-updater. Ask your admin for the key.'
    exit 2
}

if (-not (Test-Path $ImagePath)) {
    Write-Host "ERROR: file not found: $ImagePath" -ForegroundColor Red
    exit 2
}

$resolved = (Resolve-Path $ImagePath).Path

# 1. PNG magic bytes (first 8 bytes: 89 50 4E 47 0D 0A 1A 0A).
$header = [System.IO.File]::ReadAllBytes($resolved) | Select-Object -First 8
$magic = ($header | ForEach-Object { '{0:X2}' -f $_ }) -join ''
if ($magic -ne '89504E470D0A1A0A') {
    Write-Host "ERROR: '$ImagePath' is not a PNG file." -ForegroundColor Red
    Write-Host '       Save your image as PNG (not JPG/HEIC/etc) and try again.'
    exit 2
}

# 2. Dimensions via System.Drawing (built-in on Windows).
Add-Type -AssemblyName System.Drawing
$img = $null
try {
    $img = [System.Drawing.Image]::FromFile($resolved)
    $width = $img.Width
    $height = $img.Height
}
finally {
    if ($img) { $img.Dispose() }
}

if ($width -ne 1920 -or $height -ne 1080) {
    Write-Host "ERROR: image is ${width}x${height}, but must be exactly 1920x1080." -ForegroundColor Red
    Write-Host '       Resize in your image editor and export as PNG.'
    exit 2
}

Write-Host '[splash-replace] file looks good (1920x1080 PNG)'
Write-Host "[splash-replace] uploading to $Host_..."

# Pipe the file over SSH. PowerShell's `<` doesn't redirect binary safely,
# so we shell out to cmd which has native binary stdin redirection.
# /c "ssh ... < file" — cmd handles the redirect, ssh reads stdin.
$keyArg = '"' + $Key + '"'
$fileArg = '"' + $resolved + '"'
$sshCmd = "ssh -i $keyArg -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 splash-updater@$Host_ < $fileArg"

$exit = (Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $sshCmd -Wait -NoNewWindow -PassThru).ExitCode
exit $exit
