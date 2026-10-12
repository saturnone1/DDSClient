[CmdletBinding()]
param(
    [ValidateSet('All','CSharp','Cpp')][string]$Language = 'All',
    [ValidateSet('All', 'Windows', 'Linux')]
    [string] $Target = 'Windows',
    [ValidateSet('9.7', '10.0')]
    [string] $RockyVersion = '9.7',
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',
    [string] $RtiHome,
    [string] $RtiPlatform,
    [switch] $Doctor,
    [switch] $InstallTools,
    [switch] $StartDocker,
    [switch] $Clean,
    [switch] $SkipTests,
    [switch] $WithCli,
    [switch] $WithTests,
    [switch] $Force,
    [switch] $IncludeRtiRuntime,
    [switch] $CreateSourcePackage
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $PSScriptRoot 'common.ps1')

function Find-RtiHome {
    param([string] $RequestedHome)
    $candidates = @(Get-RtiHomeCandidates -RequestedHome $RequestedHome)
    foreach ($candidate in $candidates) {
        try { $full = [System.IO.Path]::GetFullPath($candidate) } catch { continue }
        if ((Test-Path -LiteralPath (Join-Path $full 'bin\rtiddsgen.bat')) -or
            (Test-Path -LiteralPath (Join-Path $full 'bin\rtiddsgen.exe'))) { return $full }
    }
    return $null
}

function Write-Check {
    param([string] $Status, [string] $Name, [string] $Detail)
    $color = if ($Status -eq 'OK') { 'Green' } elseif ($Status -eq 'WARN') { 'Yellow' } else { 'Red' }
    $label = @{ OK = '정상'; WARN = '경고'; FAIL = '실패' }[$Status]
    Write-Host ("[{0}] {1}: {2}" -f $label, $Name, $Detail) -ForegroundColor $color
    return [pscustomobject]@{ status = $Status; name = $Name; detail = $Detail }
}

function Invoke-Doctor {
    $checks = [System.Collections.Generic.List[object]]::new()
    $windows = $Target -in @('Windows', 'All')
    $linux = $Target -in @('Linux', 'All')
    $commands = @('python')
    if (-not $windows -or $Language -ne 'CSharp') { $commands += 'cmake' }
    if ($windows) { if ($Language -ne 'Cpp') { $commands += 'dotnet' }; if ($WithTests -and -not $SkipTests) { $commands += 'ctest' } }
    foreach ($commandName in $commands) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($command) { $checks.Add((Write-Check OK $commandName $command.Source)) }
        else { $checks.Add((Write-Check FAIL $commandName 'PATH에서 찾을 수 없습니다. offline-tools\windows-x64\install-tools.ps1을 관리자 권한으로 실행한 뒤 새 PowerShell 7 창을 여세요.')) }
    }

    if ($windows -and $Language -ne 'CSharp') {
        try {
            $selected = Get-MsvcBuildEnvironment
            $checks.Add((Write-Check OK 'Visual Studio C++' "$($selected.Generator) / $($selected.Instance) / $($selected.Architecture)"))
        } catch {
            $checks.Add((Write-Check FAIL 'Visual Studio C++' $_.Exception.Message))
        }
    }

    $resolvedRti = Find-RtiHome $RtiHome
    if ($resolvedRti) {
        $version = 'unknown'
        $versionsFile = Join-Path $resolvedRti 'rti_versions.xml'
        if (Test-Path -LiteralPath $versionsFile) {
            try { $version = ([xml](Get-Content -LiteralPath $versionsFile -Raw)).rti.host.base_version } catch {}
        }
        $checks.Add((Write-Check OK 'RTI 제품' "$version at $resolvedRti"))
        $windowsTargets = @(Get-ChildItem (Join-Path $resolvedRti 'lib') -Directory -Filter 'x64Win64VS*' -ErrorAction SilentlyContinue)
        $linuxTargets = @(Get-ChildItem (Join-Path $resolvedRti 'lib') -Directory -Filter 'x64Linux*' -ErrorAction SilentlyContinue)
        if ($windows) {
            if ($windowsTargets) { $checks.Add((Write-Check OK 'RTI Windows 대상 라이브러리' (($windowsTargets.Name) -join ', '))) }
            else { $checks.Add((Write-Check FAIL 'RTI Windows 대상 라이브러리' 'x64Win64VS* 대상 라이브러리가 없습니다.')) }
        }
        if ($linux) {
            if ($linuxTargets) { $checks.Add((Write-Check OK 'RTI Linux 대상 라이브러리' (($linuxTargets.Name) -join ', '))) }
            else { $checks.Add((Write-Check FAIL 'RTI Linux 대상 라이브러리' 'x64Linux* 대상 라이브러리가 없습니다.')) }
        }
        $licenseCandidates = @($env:RTI_LICENSE_FILE, (Join-Path $resolvedRti 'rti_license.dat')) |
            Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }
        if ($licenseCandidates) { $checks.Add((Write-Check OK 'RTI 라이선스' (@($licenseCandidates)[0]))) }
        else { $checks.Add((Write-Check $(if ($WithTests -and -not $SkipTests) { 'FAIL' } else { 'WARN' }) 'RTI 라이선스' 'RTI_LICENSE_FILE을 지정하거나 rti_license.dat를 설치하세요.')) }
    }
    else { $checks.Add((Write-Check FAIL 'RTI 제품' 'RTI 코드 생성 도구를 찾을 수 없습니다.')) }

    if ($linux) {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if ($docker) {
        $probe = Get-DockerEngineState $docker.Source
        if ($probe.Ready) { $checks.Add((Write-Check OK 'Docker 엔진' $probe.Detail)) }
        else { $checks.Add((Write-Check FAIL 'Docker 엔진' $probe.Detail)) }
    }
    else { $checks.Add((Write-Check FAIL 'Docker 엔진' 'Docker Desktop이 설치되지 않았거나 PATH에 없습니다.')) }
    }

    if ($windows -or $CreateSourcePackage) {
    try {
        & (Join-Path $repoRoot 'offline-tools\windows-x64\install-tools.ps1') -VerifyOnly | Out-Null
        $checks.Add((Write-Check OK 'Windows 오프라인 설치 파일' '설치 파일의 체크섬이 일치합니다.'))
    } catch { $checks.Add((Write-Check FAIL 'Windows 오프라인 설치 파일' $_.Exception.Message)) }
    }
    if ($linux -or $CreateSourcePackage) {
    try {
        $versions = if ($CreateSourcePackage) { @('9.7', '10.0') } else { @($RockyVersion) }
        & (Join-Path $repoRoot 'offline-tools\linux-x64\update-builder-image.ps1') -VerifyOnly -UseSourceBuildScript -RockyVersions $versions | Out-Null
        $checks.Add((Write-Check OK 'Linux 빌더 이미지' '이미지와 소스의 체크섬이 일치합니다.'))
    } catch { $checks.Add((Write-Check FAIL 'Linux 빌더 이미지' $_.Exception.Message)) }
    }

    $drive = [System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($repoRoot))
    $freeGb = [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
    $checks.Add((Write-Check $(if ($freeGb -ge 5) { 'OK' } else { 'WARN' }) '디스크 여유 공간' "$freeGb GiB"))
    $summary = [pscustomobject]@{
        checked_at = [DateTimeOffset]::Now.ToString('o')
        target = $Target
        rocky_version = $(if ($linux) { $RockyVersion } else { $null })
        ready = -not ($checks.status -contains 'FAIL')
        warnings = @($checks | Where-Object status -eq 'WARN').Count
        checks = $checks
    }
    Write-Host "`n진단 결과: 실패 $(@($checks | Where-Object status -eq 'FAIL').Count)건, 경고 $($summary.warnings)건."
    return $summary
}

if ($Doctor) {
    $doctorResult = Invoke-Doctor
    $doctorOutputDirectory = Join-Path $repoRoot 'artifacts'
    New-Item -ItemType Directory -Force -Path $doctorOutputDirectory | Out-Null
    $doctorResult | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $doctorOutputDirectory 'BUILD-DOCTOR.json') -Encoding utf8
    if (-not $doctorResult.ready) { throw '빌드 준비 조건을 충족하지 못했습니다. artifacts/BUILD-DOCTOR.json을 확인하세요.' }
    return
}

if ($InstallTools) {
    & (Join-Path $repoRoot 'offline-tools\windows-x64\install-tools.ps1')
    $env:PATH = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
        [Environment]::GetEnvironmentVariable('Path', 'User')
}

if ($StartDocker -and $Target -in @('All', 'Linux')) {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $docker) { throw 'Docker Desktop이 설치되지 않았거나 PATH에 없습니다.' }
    if (-not (Get-DockerEngineState $docker.Source).Ready) {
        $desktop = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
        if (-not (Test-Path -LiteralPath $desktop)) { throw 'Docker Desktop 실행 파일을 찾을 수 없습니다.' }
        Start-Process -FilePath $desktop -WindowStyle Hidden
        $ready = $false
        for ($attempt = 0; $attempt -lt 45; $attempt++) {
            Start-Sleep -Seconds 2
            if ((Get-DockerEngineState $docker.Source).Ready) { $ready = $true; break }
        }
        if (-not $ready) { throw '90초 안에 Docker Desktop이 준비되지 않았습니다.' }
    }
}

$logDirectory = Join-Path $repoRoot 'artifacts\logs'
New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $logDirectory "build-$stamp.log"
$reportPath = Join-Path $repoRoot 'artifacts\BUILD-REPORT.json'
$report = [ordered]@{
    started_at = [DateTimeOffset]::Now.ToString('o')
    completed_at = $null
    status = 'running'
    target = $Target
    rocky_version = $(if ($Target -in @('All', 'Linux')) { $RockyVersion } else { $null })
    configuration = $Configuration
    rti_home = $RtiHome
    rti_platform = $RtiPlatform
    log = $logPath
    outputs = @()
    error = $null
}

Start-Transcript -LiteralPath $logPath | Out-Null
try {
    if ($Target -in @('All', 'Windows')) {
        $arguments = @{ Configuration = $Configuration; Language = $Language }
        if ($RtiHome) { $arguments.RtiHome = $RtiHome }
        if ($SkipTests) { $arguments.SkipTests = $true }
        if ($WithCli) { $arguments.WithCli = $true }
        if ($WithTests) { $arguments.WithTests = $true }
        if ($Clean) { $arguments.Clean = $true }
        & (Join-Path $PSScriptRoot 'build-windows.ps1') @arguments
        if ($Language -ne 'Cpp') { $report.outputs += 'DDS_Nuget/artifacts/packages' }
        if ($Language -ne 'CSharp') { $report.outputs += 'DDSCPP/build' }
    }
    if ($Target -in @('All', 'Linux')) {
        $arguments = @{ RockyVersion = $RockyVersion }
        if ($RtiHome) { $arguments.RtiHome = $RtiHome }
        if ($RtiPlatform) { $arguments.RtiPlatform = $RtiPlatform }
        if ($Force) { $arguments.Force = $true }
        if ($IncludeRtiRuntime) { $arguments.IncludeRtiRuntime = $true }
        if ($SkipTests) { $arguments.SkipTests = $true }
        if ($WithCli) { $arguments.WithCli = $true }
        if ($WithTests) { $arguments.WithTests = $true }
        & (Join-Path $repoRoot 'build-linux.ps1') @arguments
        $rockyMajor = ($RockyVersion -split '\.')[0]
        $report.outputs += "DDSCPP/artifacts/linux/DDSClient-CPP-rocky$rockyMajor-x64.tar.gz"
    }
    if ($CreateSourcePackage) {
        $arguments = @{}
        if ($Force) { $arguments.Force = $true }
        & (Join-Path $repoRoot 'create-source-package.ps1') @arguments
        $report.outputs += 'artifacts/DDSClient-Source-Build-windows-x64.zip'
    }
    $report.status = 'success'
}
catch {
    $report.status = 'failed'
    $report.error = $_.Exception.Message
    throw
}
finally {
    $report.completed_at = [DateTimeOffset]::Now.ToString('o')
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportPath -Encoding utf8
    Stop-Transcript | Out-Null
    Write-Host "빌드 결과 보고서: $reportPath"
    Write-Host "빌드 로그   : $logPath"
}
