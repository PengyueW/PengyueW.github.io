<#
.SYNOPSIS
    Builds the Windows distribution of World Brief.

.DESCRIPTION
    Produces two things in dist\:
      WorldBrief-<version>-setup.exe    the installer (per-user, no administrator needed)
      WorldBrief-<version>-windows-x64.zip   a portable copy that runs from any folder

    Needs Python 3.11 or newer on PATH. Inno Setup 6 builds the installer; without it the
    script still produces the portable zip and says what is missing.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File packaging\windows\build_windows.ps1
    powershell -ExecutionPolicy Bypass -File packaging\windows\build_windows.ps1 -SkipDeps
#>
[CmdletBinding()]
param(
    [switch]$SkipDeps,     # reuse the existing .venv as it is
    [switch]$SkipBuild     # package what is already in dist\worldbrief
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $Root

$Version = (Select-String -Path "desktop\__init__.py" -Pattern '^__version__ = "(.*)"').Matches[0].Groups[1].Value
Write-Host "==> World Brief $Version" -ForegroundColor Cyan

# --------------------------------------------------------------------------- environment

$VenvPy = Join-Path $Root ".venv\Scripts\python.exe"
if (-not $SkipDeps) {
    if (-not (Test-Path $VenvPy)) {
        Write-Host "==> creating .venv"
        & python -m venv .venv
    }
    Write-Host "==> installing dependencies"
    & $VenvPy -m pip install --upgrade pip --quiet
    & $VenvPy -m pip install -r requirements-desktop.txt --quiet
}
if (-not (Test-Path $VenvPy)) { throw "no virtual environment at $VenvPy" }

# --------------------------------------------------------------------------- compile

if (-not $SkipBuild) {
    Write-Host "==> icons"
    & $VenvPy packaging\make_icons.py
    Write-Host "==> pyinstaller"
    Remove-Item -Recurse -Force dist\worldbrief -ErrorAction SilentlyContinue
    & $VenvPy -m PyInstaller packaging\worldbrief.spec --noconfirm --distpath dist --workpath build\pyi
}
if (-not (Test-Path "dist\worldbrief\worldbrief.exe")) { throw "PyInstaller produced no worldbrief.exe" }

# --------------------------------------------------------------------------- portable zip

Write-Host "==> portable zip"
$Zip = "dist\WorldBrief-$Version-windows-x64.zip"
Remove-Item $Zip -ErrorAction SilentlyContinue
$Readme = @"
World Brief $Version — portable edition

Run worldbrief.exe. Nothing is installed and nothing is written outside your user profile:
the news database, the briefs and any language packages go to
%LOCALAPPDATA%\WorldBrief.

The first launch spends a few minutes fetching from several hundred news outlets before the
first brief appears. After that it refreshes in the background every half hour, whether or not
the window is open — closing the window leaves it running in the notification area.

Everything runs on this PC. No account, no cloud, no external AI service.
"@
Set-Content -Path "dist\worldbrief\READ ME.txt" -Value $Readme -Encoding UTF8
Compress-Archive -Path "dist\worldbrief\*" -DestinationPath $Zip -CompressionLevel Optimal

# --------------------------------------------------------------------------- installer

$Iscc = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles}\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $Iscc) { $Iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source }

if ($Iscc) {
    Write-Host "==> installer"
    & $Iscc "/DAppVersion=$Version" "packaging\windows\worldbrief.iss"
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed with exit code $LASTEXITCODE" }

    # Signing is optional; unsigned installers work, SmartScreen simply warns the first time.
    if ($env:WINDOWS_CERT_PFX -and (Test-Path $env:WINDOWS_CERT_PFX)) {
        Write-Host "==> signing"
        & signtool sign /f $env:WINDOWS_CERT_PFX /p $env:WINDOWS_CERT_PASSWORD `
            /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 `
            "dist\WorldBrief-$Version-setup.exe"
    }
} else {
    Write-Warning "Inno Setup 6 was not found, so only the portable zip was built."
    Write-Warning "Install it from https://jrsoftware.org/isdl.php and run this script again."
}

Write-Host ""
Write-Host "==> packages in dist\" -ForegroundColor Cyan
Get-ChildItem dist -File | Where-Object { $_.Name -match 'setup\.exe$|\.zip$' } |
    Format-Table Name, @{N="Size";E={"{0:N1} MB" -f ($_.Length / 1MB)}}
