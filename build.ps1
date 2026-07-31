[CmdletBinding()]
param(
    [ValidateSet('All', 'Windows', 'Linux')]
    [string] $Target = 'All',
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',
    [string] $RtiHome,
    [string] $RtiPlatform,
    [switch] $Doctor,
    [switch] $InstallTools,
    [switch] $StartDocker,
    [switch] $Clean,
    [switch] $SkipTests,
    [switch] $Force,
    [switch] $IncludeRtiRuntime,
    [switch] $CreateSourcePackage
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Find-RtiHome {
    param([string] $RequestedHome)
    $candidates = @()
    if ($RequestedHome) { $candidates += $RequestedHome }
    if ($env:NDDSHOME) { $candidates += $env:NDDSHOME }
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    if ($programFiles) {
        $candidates += Get-ChildItem -LiteralPath $programFiles -Directory -Filter 'rti_connext_dds-*' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -ExpandProperty FullName
    }
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
    Write-Host ("[{0}] {1}: {2}" -f $Status, $Name, $Detail) -ForegroundColor $color
    return [pscustomobject]@{ status = $Status; name = $Name; detail = $Detail }
}

function Invoke-Doctor {
    $checks = [System.Collections.Generic.List[object]]::new()
    foreach ($commandName in @('dotnet', 'cmake', 'python')) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($command) { $checks.Add((Write-Check OK $commandName $command.Source)) }
        else { $checks.Add((Write-Check WARN $commandName 'Not on PATH; run offline-tools\windows-x64\install-tools.ps1.')) }
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $vsPath = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($vsPath) { $checks.Add((Write-Check OK 'Visual Studio C++' $vsPath)) }
        else { $checks.Add((Write-Check WARN 'Visual Studio C++' 'C++ workload was not found.')) }
    }
    else { $checks.Add((Write-Check WARN 'Visual Studio C++' 'vswhere was not found.')) }

    $resolvedRti = Find-RtiHome $RtiHome
    if ($resolvedRti) {
        $version = 'unknown'
        $versionsFile = Join-Path $resolvedRti 'rti_versions.xml'
        if (Test-Path -LiteralPath $versionsFile) {
            try { $version = ([xml](Get-Content -LiteralPath $versionsFile -Raw)).rti.host.base_version } catch {}
        }
        $checks.Add((Write-Check OK 'RTI product' "$version at $resolvedRti"))
        $windowsTargets = @(Get-ChildItem (Join-Path $resolvedRti 'lib') -Directory -Filter 'x64Win64VS*' -ErrorAction SilentlyContinue)
        $linuxTargets = @(Get-ChildItem (Join-Path $resolvedRti 'lib') -Directory -Filter 'x64Linux*' -ErrorAction SilentlyContinue)
        if ($windowsTargets) { $checks.Add((Write-Check OK 'RTI Windows targets' (($windowsTargets.Name) -join ', '))) }
        else { $checks.Add((Write-Check WARN 'RTI Windows targets' 'No x64Win64VS* target found.')) }
        if ($linuxTargets) { $checks.Add((Write-Check OK 'RTI Linux targets' (($linuxTargets.Name) -join ', '))) }
        else { $checks.Add((Write-Check WARN 'RTI Linux targets' 'No x64Linux* target found.')) }
        $licenseCandidates = @($env:RTI_LICENSE_FILE, (Join-Path $resolvedRti 'rti_license.dat')) |
            Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }
        if ($licenseCandidates) { $checks.Add((Write-Check OK 'RTI license' (@($licenseCandidates)[0]))) }
        else { $checks.Add((Write-Check WARN 'RTI license' 'Set RTI_LICENSE_FILE or install rti_license.dat.')) }
    }
    else { $checks.Add((Write-Check WARN 'RTI product' 'RTI host tools were not found.')) }

    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if ($docker) {
        $dockerInfo = & $docker.Source info --format '{{.ServerVersion}} / {{.OSType}} / {{.Architecture}}' 2>$null
        if ($LASTEXITCODE -eq 0) { $checks.Add((Write-Check OK 'Docker engine' $dockerInfo)) }
        else { $checks.Add((Write-Check WARN 'Docker engine' 'Docker Desktop is installed but the Linux engine is not running.')) }
    }
    else { $checks.Add((Write-Check WARN 'Docker engine' 'Docker Desktop is not installed or not on PATH.')) }

    try {
        & (Join-Path $repoRoot 'offline-tools\windows-x64\install-tools.ps1') -VerifyOnly | Out-Null
        $checks.Add((Write-Check OK 'Windows offline tools' 'Installer checksums match.'))
    } catch { $checks.Add((Write-Check FAIL 'Windows offline tools' $_.Exception.Message)) }
    try {
        & (Join-Path $repoRoot 'offline-tools\linux-x64\update-builder-image.ps1') -VerifyOnly | Out-Null
        $checks.Add((Write-Check OK 'Linux builder image' 'Image and source checksums match.'))
    } catch { $checks.Add((Write-Check FAIL 'Linux builder image' $_.Exception.Message)) }

    $drive = [System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($repoRoot))
    $freeGb = [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
    $checks.Add((Write-Check $(if ($freeGb -ge 5) { 'OK' } else { 'WARN' }) 'Free disk space' "$freeGb GiB"))
    $summary = [pscustomobject]@{
        checked_at = [DateTimeOffset]::Now.ToString('o')
        ready = -not ($checks.status -contains 'FAIL')
        warnings = @($checks | Where-Object status -eq 'WARN').Count
        checks = $checks
    }
    Write-Host "`nDoctor result: $(@($checks | Where-Object status -eq 'FAIL').Count) failure(s), $($summary.warnings) warning(s)."
    return $summary
}

if ($Doctor) {
    $doctorResult = Invoke-Doctor
    $doctorOutputDirectory = Join-Path $repoRoot 'artifacts'
    New-Item -ItemType Directory -Force -Path $doctorOutputDirectory | Out-Null
    $doctorResult | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $doctorOutputDirectory 'BUILD-DOCTOR.json') -Encoding utf8
    return
}

if ($InstallTools) {
    & (Join-Path $repoRoot 'offline-tools\windows-x64\install-tools.ps1')
    $env:PATH = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
        [Environment]::GetEnvironmentVariable('Path', 'User')
}

if ($StartDocker -and $Target -in @('All', 'Linux')) {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $docker) { throw 'Docker Desktop is not installed or not on PATH.' }
    & $docker.Source info *> $null
    if ($LASTEXITCODE -ne 0) {
        $desktop = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
        if (-not (Test-Path -LiteralPath $desktop)) { throw 'Docker Desktop executable was not found.' }
        Start-Process -FilePath $desktop -WindowStyle Hidden
        $ready = $false
        for ($attempt = 0; $attempt -lt 45; $attempt++) {
            Start-Sleep -Seconds 2
            & $docker.Source info *> $null
            if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        }
        if (-not $ready) { throw 'Docker Desktop did not become ready within 90 seconds.' }
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
        $arguments = @{ Configuration = $Configuration }
        if ($RtiHome) { $arguments.RtiHome = $RtiHome }
        if ($SkipTests) { $arguments.SkipTests = $true }
        if ($Clean) { $arguments.Clean = $true }
        & (Join-Path $repoRoot 'build-all.ps1') @arguments
        $report.outputs += 'DDS_Nuget/artifacts/packages'
        $report.outputs += 'DDSCPP/build'
    }
    if ($Target -in @('All', 'Linux')) {
        $arguments = @{}
        if ($RtiHome) { $arguments.RtiHome = $RtiHome }
        if ($RtiPlatform) { $arguments.RtiPlatform = $RtiPlatform }
        if ($Force) { $arguments.Force = $true }
        if ($IncludeRtiRuntime) { $arguments.IncludeRtiRuntime = $true }
        if ($SkipTests) { $arguments.SkipTests = $true }
        & (Join-Path $repoRoot 'build-linux.ps1') @arguments
        $report.outputs += 'artifacts/linux/DDSClient-CPP-rocky9-x64.tar.gz'
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
    Write-Host "Build report: $reportPath"
    Write-Host "Build log   : $logPath"
}
