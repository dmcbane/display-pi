# splash-replace.ps1 — volunteer-facing script (Windows).
#
# Replaces the splash image on the church-display Pi. Validates the file
# locally first (so an obviously-wrong file fails fast with a clear
# message), then uploads via SSH to the kiosk. The Pi re-validates on
# arrival and refuses to install anything that isn't a 1920x1080 PNG,
# JPEG, GIF, or WebP.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File splash-replace.ps1 <path\to\image>
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

# When the volunteer right-clicks "Run with PowerShell", a fresh window
# opens, runs the script, then closes. If the script errors and exits
# before they can read the message, the window vanishes with the error
# unread. Pause at exit ONLY when stdin is interactive (no pipe), so
# automation / dev runs don't pause.
try {

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

# 1. Detect the format from magic bytes (first 12 bytes cover all four:
#    PNG 89504E47..., JPEG FFD8FF, GIF "GIF87a"/"GIF89a", WebP is
#    "RIFF"<4-byte size>"WEBP").
$header = [System.IO.File]::ReadAllBytes($resolved) | Select-Object -First 12
$magic = ($header | ForEach-Object { '{0:X2}' -f $_ }) -join ''
$fmt = $null
if ($magic.StartsWith('89504E470D0A1A0A')) { $fmt = 'PNG' }
elseif ($magic.StartsWith('FFD8FF')) { $fmt = 'JPEG' }
elseif ($magic.StartsWith('474946383761') -or $magic.StartsWith('474946383961')) { $fmt = 'GIF' }
elseif ($magic.StartsWith('52494646') -and $magic.Length -ge 24 -and $magic.Substring(16, 8) -eq '57454250') { $fmt = 'WEBP' }
if (-not $fmt) {
    Write-Host "ERROR: '$ImagePath' is not a PNG, JPEG, GIF, or WebP file." -ForegroundColor Red
    Write-Host '       Save your image in one of those formats (not HEIC/BMP/etc) and try again.'
    exit 2
}

# 2. Dimensions via System.Drawing (built-in on Windows; decodes PNG/JPEG/GIF
#    but not WebP — for WebP the Pi-side check is the gatekeeper).
if ($fmt -ne 'WEBP') {
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
        Write-Host '       Resize in your image editor and try again.'
        exit 2
    }

    Write-Host "[splash-replace] file looks good (1920x1080 $fmt)"
} else {
    Write-Host '[splash-replace] file looks like a WEBP image; the display will'
    Write-Host '[splash-replace] verify the 1920x1080 size when it arrives.'
}
Write-Host "[splash-replace] uploading to $Host_..."

# Pipe the file over SSH. PowerShell's `<` doesn't redirect binary safely,
# so we shell out to cmd which has native binary stdin redirection.
# /c "ssh ... < file" — cmd handles the redirect, ssh reads stdin.
$keyArg = '"' + $Key + '"'
$fileArg = '"' + $resolved + '"'
$sshCmd = "ssh -i $keyArg -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 splash-updater@$Host_ < $fileArg"

$exit = (Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $sshCmd -Wait -NoNewWindow -PassThru).ExitCode
exit $exit

}
finally {
    if (-not [Console]::IsInputRedirected) {
        Write-Host ''
        Write-Host 'Press Enter to close...' -ForegroundColor Yellow
        $null = Read-Host
    }
}
