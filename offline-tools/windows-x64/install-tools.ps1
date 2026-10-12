[CmdletBinding()]
param(
    [switch] $VerifyOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../tools/build/common.ps1')

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
        throw "설치 파일이 없습니다: $Path"
    }

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash
    if ($actual -ne $Expected) {
        throw "체크섬 불일치: $Path`n기대값: $Expected`n실제값: $actual"
    }
}

if (-not [Environment]::Is64BitOperatingSystem) {
    throw '이 설치 파일에는 64비트 Windows가 필요합니다.'
}

$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$installerRoot = Join-Path $toolRoot 'installers'
$dotnetInstaller = Join-Path $installerRoot 'dotnet-sdk-9.0.316-win-x64.exe'
$cmakeInstaller = Join-Path $installerRoot 'cmake-4.4.0-windows-x86_64.msi'
$pythonInstaller = Join-Path $installerRoot 'python-3.13.14-amd64.exe'

Write-Host '설치 파일의 무결성을 검사합니다...'
Assert-FileHash $dotnetInstaller SHA512 '1134B85430FAAA808A30CE50457577E06A841A2091E132BB5EAAE6ACF29369ADEC55AFC65D7DE3D32636FB73DB4D4A99E3075049941D005737ABF8B787EED746'
Assert-FileHash $cmakeInstaller SHA256 '82DB53FCB8F38BE541A26093489F39D5ED79B71B53CD121FC32A022A6BF310B1'
Assert-FileHash $pythonInstaller SHA256 'C54D9B9BBB8A36E6489363DDD01139707FD781D72F1F9E90C7EC65D0061368E0'

if ($VerifyOnly) {
    Write-Host '모든 설치 파일의 체크섬 검증을 통과했습니다.'
    return
}

if (-not (Test-Administrator)) {
    throw 'PowerShell 7을 관리자 권한으로 열고 다시 실행하세요.'
}

$restartRequired = $false

Write-Host '.NET SDK 9.0.316을 설치합니다...'
$process = Start-Process -FilePath $dotnetInstaller -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
if ($process.ExitCode -notin 0, 3010) {
    throw ".NET SDK 설치 실패(종료 코드 $($process.ExitCode))."
}
$restartRequired = $restartRequired -or ($process.ExitCode -eq 3010)

Write-Host 'CMake 4.4.0을 설치합니다...'
$process = Start-Process -FilePath 'msiexec.exe' -ArgumentList '/i', "`"$cmakeInstaller`"", '/qn', '/norestart', 'ADD_CMAKE_TO_PATH=System' -Wait -PassThru
if ($process.ExitCode -notin 0, 3010) {
    throw "CMake 설치 실패(종료 코드 $($process.ExitCode))."
}
$restartRequired = $restartRequired -or ($process.ExitCode -eq 3010)

Write-Host 'Python 3.13.14를 설치합니다...'
$process = Start-Process -FilePath $pythonInstaller -ArgumentList '/quiet', 'InstallAllUsers=1', 'PrependPath=1', 'Include_test=0' -Wait -PassThru
if ($process.ExitCode -notin 0, 3010) {
    throw "Python 설치 실패(종료 코드 $($process.ExitCode))."
}
$restartRequired = $restartRequired -or ($process.ExitCode -eq 3010)

Write-Host ''
Write-Host '설치가 완료되었습니다. 새 PowerShell 7 창에서 다음 명령을 실행하세요:'
Write-Host '  .\build.ps1 -Doctor'
if ($restartRequired) {
    Write-Host 'Windows에서 재시작을 요청했습니다. 재부팅한 뒤 빌드하세요.'
}
