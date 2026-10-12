<#
.SYNOPSIS
기존 코어 바이너리를 유지하면서 새 메시지 모듈을 생성하고 검증합니다.
.DESCRIPTION
같은 코어 API/ABI와 RTI 7.3.1을 사용하는 Windows 검증입니다.
빌드된 코어 DLL과 설치된 C++ 패키지가 필요하며 코어를 다시 빌드하지 않습니다.
다른 빌드가 입력 파일을 변경하지 않을 때 실행하세요.
각 실행의 입력 복사본·모듈·소비자·해시·로그를 보관합니다.
.EXAMPLE
.\tools\build\test-module-addition.ps1 -CoreAssembly .\DDS_Nuget\build\dotnet\DdsAmbassador.DDSClient.Core\bin\Release\net9.0\DdsAmbassador.DDSClient.Core.dll -CppPrefix .\DDSCPP\artifacts\install
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $CoreAssembly,
    [Parameter(Mandatory)] [string] $CppPrefix,
    [string] $RtiHome = 'C:/Program Files/rti_connext_dds-7.3.1',
    [string] $RtiPlatform = 'x64Win64VS2017',
    [string] $LicenseFile,
    [ValidateSet('Release', 'Debug')] [string] $Configuration = 'Release',
    [ValidateSet('Static', 'Shared')] [string[]] $CppLinkage = @('Static', 'Shared'),
    [ValidateRange(0, 232)] [int] $DomainId = 186,
    [string] $CMakeGenerator,
    [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $PSScriptRoot 'common.ps1')

function Get-CoreFingerprint {
    param([string] $Path)
    $item = Get-Item -LiteralPath $Path
    return [pscustomobject]@{
        path = $item.FullName
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
        last_write_utc = $item.LastWriteTimeUtc.ToString('o')
    }
}

function Assert-CoreUnchanged {
    param([object[]] $Snapshots)
    foreach ($snapshot in $Snapshots) {
        $now = Get-CoreFingerprint $snapshot.path
        if ($now.sha256 -ne $snapshot.sha256 -or $now.last_write_utc -ne $snapshot.last_write_utc) {
            throw "모듈 추가 중 코어가 변경되었습니다: $($snapshot.path)"
        }
    }
}

function Assert-SameHash {
    param([string] $Path, [string] $Expected)
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Expected) {
        throw "코어 복사본이 코드 생성 전 원본과 다릅니다: $Path"
    }
}

if ($env:OS -ne 'Windows_NT') { throw '이 검증 도구는 Windows용 C# 및 설치된 C++ 바이너리를 대상으로 합니다.' }
if (-not $CppLinkage -or $CppLinkage.Count -eq 0) { throw 'C++ 링크 방식을 하나 이상 선택하세요.' }
$CoreAssembly = (Resolve-Path -LiteralPath $CoreAssembly).ProviderPath
$CppPrefix = (Resolve-Path -LiteralPath $CppPrefix).ProviderPath.TrimEnd('\', '/')
$RtiHome = (Resolve-Path -LiteralPath $RtiHome).ProviderPath
if (-not (Test-Path -LiteralPath $CoreAssembly -PathType Leaf) -or
    [System.IO.Path]::GetFileName($CoreAssembly) -ne 'DdsAmbassador.DDSClient.Core.dll') {
    throw 'CoreAssembly에는 빌드된 DdsAmbassador.DDSClient.Core.dll을 지정하세요.'
}
if (-not (Test-Path -LiteralPath $CppPrefix -PathType Container)) { throw 'CppPrefix에는 설치된 C++ 패키지 폴더를 지정하세요.' }
$configs = @(Get-ChildItem -LiteralPath $CppPrefix -Recurse -Filter DDSClientConfig.cmake -File)
if ($configs.Count -ne 1) { throw 'CppPrefix에는 설치된 DDSClientConfig.cmake가 정확히 하나 있어야 합니다.' }
$cppCore = @(Get-ChildItem -LiteralPath $CppPrefix -Recurse -File |
    Where-Object { $_.Name -in @('dds_cpp.dll', 'dds_cpp.lib', 'dds_cpp_static.lib') })
foreach ($linkage in $CppLinkage) {
    $required = if ($linkage -eq 'Static') { @('dds_cpp_static.lib') } else { @('dds_cpp.dll', 'dds_cpp.lib') }
    foreach ($name in $required) {
        if (@($cppCore | Where-Object Name -eq $name).Count -ne 1) { throw "$linkage 설치 패키지에는 $name 파일이 정확히 하나 있어야 합니다." }
    }
}
$rtiLibraries = if ([System.IO.Path]::IsPathRooted($RtiPlatform)) { $RtiPlatform } else { Join-Path $RtiHome "lib\$RtiPlatform" }
foreach ($file in @('nddscpp2.lib', 'nddsc.lib', 'nddscore.lib')) {
    if (-not (Test-Path -LiteralPath (Join-Path $rtiLibraries $file))) { throw "RTI 대상 폴더 ${rtiLibraries}에 $file 파일이 없습니다." }
}
if (-not $LicenseFile) { $LicenseFile = $env:RTI_LICENSE_FILE }
if (-not $LicenseFile) { $LicenseFile = Join-Path $RtiHome 'rti_license.dat' }
if (-not (Test-Path -LiteralPath $LicenseFile -PathType Leaf)) { throw '유효한 -LicenseFile 또는 RTI_LICENSE_FILE을 지정하세요.' }
$LicenseFile = (Resolve-Path -LiteralPath $LicenseFile).ProviderPath
$cmake = (Get-Command cmake -ErrorAction Stop).Source
$dotnet = (Get-Command dotnet -ErrorAction Stop).Source
$python = (Get-Command python -ErrorAction Stop).Source

if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'artifacts\module-addition' }
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$runId = [guid]::NewGuid().ToString('N')
$work = Join-Path $OutputDirectory $runId
if ($work.StartsWith($CppPrefix + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputDirectory는 검증할 설치 패키지 내부에 둘 수 없습니다.'
}
New-Item -ItemType Directory -Path $work | Out-Null
$reportPath = Join-Path $work 'MODULE-ADDITION-REPORT.json'
$report = [ordered]@{
    scope = 'Same Core API/ABI; new generated message module; not arbitrary older releases'
    configuration = $Configuration
    started_at = [DateTimeOffset]::Now.ToString('o')
    status = 'running'
    originals = @()
    frozen = @()
    core_unchanged = $false
    results = @()
    error = $null
}
$snapshots = @()
$savedPath = $env:PATH
$savedLicense = $env:RTI_LICENSE_FILE
$savedNddsHome = $env:NDDSHOME
$transcribing = $false
try {
    Start-Transcript -LiteralPath (Join-Path $work 'module-addition.log') | Out-Null
    $transcribing = $true
    $report.originals = @((Get-CoreFingerprint $CoreAssembly)) + @($cppCore | ForEach-Object { Get-CoreFingerprint $_.FullName })
    $snapshots = @($report.originals)
    $frozenRoot = Join-Path $work 'frozen'
    $frozenCsharp = Join-Path $frozenRoot 'csharp'
    $frozenCpp = Join-Path $frozenRoot 'cpp'
    New-Item -ItemType Directory -Path $frozenCsharp | Out-Null
    Copy-Item -LiteralPath $CoreAssembly -Destination $frozenCsharp
    Copy-Item -LiteralPath $CppPrefix -Destination $frozenCpp -Recurse
    $frozenAssembly = Join-Path $frozenCsharp 'DdsAmbassador.DDSClient.Core.dll'
    $frozenPaths = @($frozenAssembly) + @($cppCore | ForEach-Object {
        Join-Path $frozenCpp $_.FullName.Substring($CppPrefix.Length + 1)
    })
    for ($index = 0; $index -lt $frozenPaths.Count; $index++) {
        Assert-SameHash $frozenPaths[$index] $report.originals[$index].sha256
    }
    $report.frozen = @($frozenPaths | ForEach-Object { Get-CoreFingerprint $_ })
    $snapshots += @($report.frozen)
    Assert-CoreUnchanged $snapshots
    # 새 XML 생성이나 컴파일 전에 기존 Core의 상태를 기록한다.
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8

    $fixtures = Join-Path $PSScriptRoot 'fixtures\module-addition'
    $source = Join-Path $work 'consumer'
    # 예제 소스만 복사하고 IDE가 만든 bin/obj 결과는 제외한다.
    foreach ($relative in @('AddedAfterFreeze.xml', 'csharp\Consumer.csproj',
        'csharp\Program.cs', 'csharp\Module\AddedModule.csproj', 'cpp\CMakeLists.txt', 'cpp\main.cpp')) {
        $destination = Join-Path $source $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath (Join-Path $fixtures $relative) -Destination $destination
    }
    $xml = Join-Path $source 'AddedAfterFreeze.xml'
    $qos = Join-Path $source 'qos_profiles.xml'
    Copy-Item -LiteralPath (Join-Path $repoRoot 'definitions\qos_profiles.xml') -Destination $qos
    $generatedCs = Join-Path $work 'generated\csharp'
    $generatedCpp = Join-Path $work 'generated\cpp'
    $generator = Join-Path $repoRoot 'tools\codegen\schema_modules.py'
    # 이 예제는 생성기의 프로젝트 대신 고정된 Core를 참조하는 전용 프로젝트를 사용한다.
    # 새 모듈은 고정한 Core 어셈블리를 직접 참조해 컴파일한다.
    Invoke-Checked $python @($generator, '--xml', $xml, '--output', $generatedCs, '--language', 'c#', '--rti-home', $RtiHome)
    Invoke-Checked $python @($generator, '--xml', $xml, '--output', $generatedCpp, '--language', 'C++11', '--rti-home', $RtiHome)
    Assert-CoreUnchanged $snapshots
    $env:RTI_LICENSE_FILE = $LicenseFile
    $env:NDDSHOME = $RtiHome
    $env:PATH = "$rtiLibraries;$(Join-Path $frozenCpp 'bin');$savedPath"

    $consumerProject = Join-Path $source 'csharp\Consumer.csproj'
    $csOutput = Join-Path $work 'build\csharp'
    $properties = @("-p:FrozenCoreAssembly=$frozenAssembly", "-p:GeneratedModuleDirectory=$generatedCs",
        '-p:ImportDirectoryBuildProps=false', '-p:ImportDirectoryBuildTargets=false')
    Invoke-Checked $dotnet (@('restore', $consumerProject, '--configfile', (Join-Path $repoRoot 'DDS_Nuget\NuGet.config'),
        '--packages', (Join-Path $work 'nuget')) + $properties)
    Invoke-Checked $dotnet (@('build', $consumerProject, '--no-restore', '--configuration', $Configuration, '--output', $csOutput) + $properties)
    Assert-SameHash (Join-Path $csOutput 'DdsAmbassador.DDSClient.Core.dll') $report.originals[0].sha256
    $lines = @(Invoke-Checked $dotnet @((Join-Path $csOutput 'ModuleAdditionConsumer.dll'), $qos, "$DomainId", "AddedAfterFreeze_${runId}_cs", $report.originals[0].sha256))
    $lines | ForEach-Object { Write-Host $_ }
    if ($lines -notcontains 'MODULE_ADDITION_PASS csharp 4') { throw 'C# 소비자가 RTI 메시지 4개의 수신을 확인하지 못했습니다.' }
    Assert-CoreUnchanged $snapshots
    $report.results += [pscustomobject]@{ language = 'csharp'; messages = 4; core_sha256 = $report.originals[0].sha256 }

    $configDirectory = Join-Path $frozenCpp $configs[0].Directory.FullName.Substring($CppPrefix.Length + 1)
    foreach ($linkage in ($CppLinkage | Select-Object -Unique)) {
        $cppBuild = Join-Path $work "build\cpp-$($linkage.ToLowerInvariant())"
        $static = if ($linkage -eq 'Static') { 'ON' } else { 'OFF' }
        $configure = @('-S', (Join-Path $source 'cpp'), '-B', $cppBuild,
            "-DCMAKE_BUILD_TYPE=$Configuration", "-DDDSClient_DIR=$configDirectory",
            "-DDDSClient_RTI_HOME=$RtiHome", "-DDDSClient_RTI_PLATFORM=$RtiPlatform",
            "-DDDSClient_USE_STATIC_LIBS=$static", "-DGENERATED_MODULE_DIR=$generatedCpp")
        if ($CMakeGenerator) { $configure += @('-G', $CMakeGenerator) }
        Invoke-Checked $cmake $configure
        $linkedCore = (Get-Content -LiteralPath (Join-Path $cppBuild "linked-core-$Configuration.txt") -Raw).Trim()
        $linkedCore = [System.IO.Path]::GetFullPath($linkedCore)
        $linkedSnapshot = @($report.frozen | Where-Object { $_.path -eq $linkedCore })
        if ($linkedSnapshot.Count -ne 1) { throw "소비자가 검증용으로 고정한 바이너리 밖의 코어를 참조합니다: $linkedCore" }
        Invoke-Checked $cmake @('--build', $cppBuild, '--config', $Configuration, '--target', 'module_addition_consumer')
        if ($linkage -eq 'Shared') {
            Assert-SameHash (Join-Path $cppBuild 'bin\dds_cpp.dll') $linkedSnapshot[0].sha256
        }
        $lines = @(Invoke-Checked (Join-Path $cppBuild 'bin\module_addition_consumer.exe') @($qos, "$DomainId", "AddedAfterFreeze_${runId}_$linkage"))
        $lines | ForEach-Object { Write-Host $_ }
        if ($lines -notcontains 'MODULE_ADDITION_PASS cpp 4') { throw "C++ $linkage 소비자가 RTI 메시지 4개의 수신을 확인하지 못했습니다." }
        Assert-CoreUnchanged $snapshots
        $report.results += [pscustomobject]@{ language = 'cpp'; linkage = $linkage; messages = 4; core_sha256 = $linkedSnapshot[0].sha256; linked_core = $linkedCore }
    }
    $report.status = 'passed'
}
catch {
    $report.status = 'failed'
    $report.error = $_.Exception.Message
    throw
}
finally {
    $integrityFailure = $null
    try {
        if ($snapshots.Count -gt 0) { Assert-CoreUnchanged $snapshots; $report.core_unchanged = $true }
    }
    catch {
        $integrityFailure = $_.Exception.Message
        $report.status = 'failed'
        $report.error = @($report.error, $integrityFailure) -join "`n"
    }
    $env:PATH = $savedPath
    $env:RTI_LICENSE_FILE = $savedLicense
    $env:NDDSHOME = $savedNddsHome
    $report.completed_at = [DateTimeOffset]::Now.ToString('o')
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8
    if ($transcribing) { Stop-Transcript | Out-Null }
    Write-Host "모듈 추가 검증 보고서: $reportPath"
    if ($integrityFailure) { throw $integrityFailure }
}
