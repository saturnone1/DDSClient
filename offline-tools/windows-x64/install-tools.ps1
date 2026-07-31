[CmdletBinding()]
param(
    [switch] $VerifyOnly
)

$ErrorActionPreference = 'Stop'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-FileHash {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Algorithm,
        [Parameter(Mandatory)] [string] $Expected
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Installation file was not found: $Path"
    }

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash
    if ($actual -ne $Expected) {
        throw "Checksum mismatch: $Path`nExpected: $Expected`nActual:   $actual"
    }
}

if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'These installation files require 64-bit Windows.'
}

$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$installerRoot = Join-Path $toolRoot 'installers'
$dotnetInstaller = Join-Path $installerRoot 'dotnet-sdk-9.0.316-win-x64.exe'
$cmakeInstaller = Join-Path $installerRoot 'cmake-4.4.0-windows-x86_64.msi'
$pythonInstaller = Join-Path $installerRoot 'python-3.13.14-amd64.exe'

Write-Host 'Verifying installation files...'
Assert-FileHash $dotnetInstaller SHA512 '1134B85430FAAA808A30CE50457577E06A841A2091E132BB5EAAE6ACF29369ADEC55AFC65D7DE3D32636FB73DB4D4A99E3075049941D005737ABF8B787EED746'
Assert-FileHash $cmakeInstaller SHA256 '82DB53FCB8F38BE541A26093489F39D5ED79B71B53CD121FC32A022A6BF310B1'
Assert-FileHash $pythonInstaller SHA256 'C54D9B9BBB8A36E6489363DDD01139707FD781D72F1F9E90C7EC65D0061368E0'

if ($VerifyOnly) {
    Write-Host 'All installation files passed checksum verification.'
    return
}

if (-not (Test-Administrator)) {
    throw 'Open PowerShell as Administrator and run this script again.'
}

$restartRequired = $false

Write-Host 'Installing .NET SDK 9.0.316...'
$process = Start-Process -FilePath $dotnetInstaller -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
if ($process.ExitCode -notin 0, 3010) {
    throw ".NET SDK installation failed with exit code $($process.ExitCode)."
}
$restartRequired = $restartRequired -or ($process.ExitCode -eq 3010)

Write-Host 'Installing CMake 4.4.0...'
$process = Start-Process -FilePath 'msiexec.exe' -ArgumentList '/i', "`"$cmakeInstaller`"", '/qn', '/norestart', 'ADD_CMAKE_TO_PATH=System' -Wait -PassThru
if ($process.ExitCode -notin 0, 3010) {
    throw "CMake installation failed with exit code $($process.ExitCode)."
}
$restartRequired = $restartRequired -or ($process.ExitCode -eq 3010)

Write-Host 'Installing Python 3.13.14...'
$process = Start-Process -FilePath $pythonInstaller -ArgumentList '/quiet', 'InstallAllUsers=1', 'PrependPath=1', 'Include_test=0' -Wait -PassThru
if ($process.ExitCode -notin 0, 3010) {
    throw "Python installation failed with exit code $($process.ExitCode)."
}
$restartRequired = $restartRequired -or ($process.ExitCode -eq 3010)

Write-Host ''
Write-Host 'Installation completed. Close this PowerShell window, open a new one, and run:'
Write-Host '  .\build-all.ps1'
if ($restartRequired) {
    Write-Host 'Windows requested a restart before building.'
}
