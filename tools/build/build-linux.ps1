[CmdletBinding()]
param(
    [string] $RtiHome,
    [string] $RtiPlatform,
    [string] $OutputDirectory,
    [string] $DockerImage,
    [ValidatePattern('^\d+(\.\d+)*$')]
    [string] $RockyVersion = '9.7',
    [switch] $SkipImageBuild,
    [switch] $RebuildImage,
    [switch] $IncludeRtiRuntime,
    [switch] $SkipTests,
    [switch] $WithCli,
    [switch] $WithTests,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $PSScriptRoot 'common.ps1')
# Rocky 주 버전별 이름으로 산출물과 이미지를 구분한다.
# Rocky 10 결과가 Rocky 9 결과를 덮어쓰지 않도록 한다.
$rockyMajor = ($RockyVersion -split '\.')[0]
$packageName = "DDSClient-CPP-rocky$rockyMajor-x64"
if (-not $DockerImage) { $DockerImage = "ddsclient-rocky$rockyMajor-builder:latest" }

# 지원하는 Rocky 버전마다 오프라인 빌더 이미지를 하나씩 동봉한다.
# 폐쇄망에서 외부 레지스트리에 연결하지 않고 지원 버전의 빌드를 선택할 수 있게 한다.
$bundledImageTag = "ddsclient-rocky$rockyMajor-builder:latest"
$bundledImageDirectory = Join-Path $repoRoot 'offline-tools\linux-x64'
$bundledImage = Join-Path $bundledImageDirectory "ddsclient-rocky$rockyMajor-builder.tar"

function Test-RtiLinuxTarget {
    param([Parameter(Mandatory)] [System.IO.DirectoryInfo] $Directory)
    return (Test-Path -LiteralPath (Join-Path $Directory.FullName 'libnddscpp2.so')) -and
        (Test-Path -LiteralPath (Join-Path $Directory.FullName 'libnddsc.so')) -and
        (Test-Path -LiteralPath (Join-Path $Directory.FullName 'libnddscore.so'))
}

function Resolve-RtiInstallation {
    param([string] $RequestedHome, [string] $RequestedPlatform)
    $candidates = @(Get-RtiHomeCandidates -RequestedHome $RequestedHome)
    foreach ($candidate in $candidates) {
        $full = [System.IO.Path]::GetFullPath($candidate)
        $generator = @('bin\rtiddsgen.bat', 'bin\rtiddsgen.exe') |
            ForEach-Object { Join-Path $full $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
        $platformRoot = Join-Path $full 'lib'
        if ($RequestedPlatform) {
            $requestedPath = if ([System.IO.Path]::IsPathRooted($RequestedPlatform)) {
                [System.IO.Path]::GetFullPath($RequestedPlatform)
            } else { Join-Path $platformRoot $RequestedPlatform }
            $linuxTargets = @(Get-Item -LiteralPath $requestedPath -ErrorAction SilentlyContinue |
                Where-Object { $_ -is [System.IO.DirectoryInfo] -and (Test-RtiLinuxTarget $_) })
        }
        else {
            $linuxTargets = @(Get-ChildItem -LiteralPath $platformRoot -Directory -Filter 'x64Linux*' -ErrorAction SilentlyContinue |
                Where-Object { Test-RtiLinuxTarget $_ } |
                Sort-Object {
                    if ($_.Name -match 'gcc([0-9]+(?:\.[0-9]+)*)') { [version]$Matches[1] }
                    else { [version]'0.0' }
                } -Descending)
        }
        $schema = Join-Path $full 'resource\schema\rti_dds_profiles.xsd'
        if ($generator -and $linuxTargets.Count -gt 0 -and (Test-Path -LiteralPath $schema -PathType Leaf)) {
            $productVersion = 'unknown'
            $versionsFile = Join-Path $full 'rti_versions.xml'
            if (Test-Path -LiteralPath $versionsFile -PathType Leaf) {
                try { $productVersion = ([xml](Get-Content -LiteralPath $versionsFile -Raw)).rti.host.base_version }
                catch { Write-Warning "${versionsFile}에서 RTI 제품 버전을 읽지 못했습니다." }
            }
            return [pscustomobject]@{
                Home = $full
                Generator = $generator
                LinuxTarget = $linuxTargets[0].FullName
                LinuxPlatform = $linuxTargets[0].Name
                ProductVersion = $productVersion
            }
        }
    }
    $suffix = if ($RequestedPlatform) { " 요청한 대상: $RequestedPlatform." } else { '' }
    throw "RTI 코드 생성 도구 또는 사용 가능한 x64Linux 라이브러리가 없습니다. NDDSHOME 또는 -RtiHome/-RtiPlatform을 지정하세요.$suffix"
}

function Publish-OutputSet {
    param(
        [Parameter(Mandatory)] [string] $StagingDirectory,
        [Parameter(Mandatory)] [string] $DestinationDirectory,
        [Parameter(Mandatory)] [string[]] $Names)
    $backupDirectory = Join-Path $DestinationDirectory ('.ddsclient-backup-' + [guid]::NewGuid().ToString('N'))
    $published = [System.Collections.Generic.List[string]]::new()
    $backedUp = [System.Collections.Generic.List[object]]::new()
    New-Item -ItemType Directory -Path $backupDirectory | Out-Null
    try {
        foreach ($name in $Names) {
            $destination = Join-Path $DestinationDirectory $name
            if (Test-Path -LiteralPath $destination) {
                $backup = Join-Path $backupDirectory $name
                Move-Item -LiteralPath $destination -Destination $backup
                $backedUp.Add([pscustomobject]@{ Source = $backup; Destination = $destination })
            }
        }
        foreach ($name in $Names) {
            $source = Join-Path $StagingDirectory $name
            $destination = Join-Path $DestinationDirectory $name
            Move-Item -LiteralPath $source -Destination $destination
            $published.Add($destination)
        }
    }
    catch {
        foreach ($path in $published) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
        foreach ($item in $backedUp) {
            if (Test-Path -LiteralPath $item.Source) {
                Move-Item -LiteralPath $item.Source -Destination $item.Destination -ErrorAction SilentlyContinue
            }
        }
        throw
    }
    finally {
        Remove-Item -LiteralPath $backupDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($SkipImageBuild -and $RebuildImage) { throw '-SkipImageBuild와 -RebuildImage는 함께 사용할 수 없습니다.' }
$docker = Get-Command docker -ErrorAction SilentlyContinue
if (-not $docker) { throw 'Docker를 찾을 수 없습니다. Docker Desktop을 설치하고 Linux 컨테이너를 활성화하세요.' }
& $docker.Source info *> $null
if ($LASTEXITCODE -ne 0) { throw 'Docker Linux 엔진이 실행 중이 아닙니다. Docker Desktop을 실행한 뒤 다시 시도하세요.' }
$cmake = Get-Command cmake -ErrorAction SilentlyContinue
if (-not $cmake) { throw 'CMake를 찾을 수 없습니다. offline-tools\windows-x64\install-tools.ps1을 먼저 실행하세요.' }
$rti = Resolve-RtiInstallation $RtiHome $RtiPlatform

if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'DDSCPP\artifacts\linux' }
elseif (-not [System.IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory = Join-Path $repoRoot $OutputDirectory }
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$lockStream = $null
$lockPath = $null
$generatedRoot = $null
$stagingRoot = $null
$testNetwork = $null
try {
    $lockPath = Join-Path $OutputDirectory '.ddsclient-linux.lock'
    try {
        $lockStream = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    }
    catch { throw "다른 Linux 빌드가 이 출력 폴더를 사용 중입니다: $OutputDirectory" }

    $finalNames = @($packageName, "$packageName.tar.gz", "$packageName.tar.gz.sha256")
    $existing = $finalNames | ForEach-Object { Join-Path $OutputDirectory $_ } | Where-Object { Test-Path -LiteralPath $_ }
    if ($existing -and -not $Force) {
        throw "Linux 결과 파일이 이미 있습니다. 빌드 성공 후 교체하려면 -Force를 지정하세요: $($existing -join ', ')"
    }

    $generatedRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('DDSClient-linux-generated-' + [guid]::NewGuid().ToString('N'))
    $stagingRoot = Join-Path $OutputDirectory ('.ddsclient-staging-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $generatedRoot, $stagingRoot | Out-Null

    $definitions = Join-Path $repoRoot 'definitions'
    $moduleGenerator = Join-Path $repoRoot 'tools/codegen/schema_modules.py'
    Invoke-Checked 'python' @($moduleGenerator, '--definitions', $definitions,
        '--output', $generatedRoot, '--language', 'C++11', '--rti-home', $rti.Home)


    if ($SkipImageBuild) {
        # 이미 로드된 Rocky 이미지를 재사용하는 분기를 먼저 처리한다.
        # 이미지를 재사용할 때는 레지스트리나 이미지 압축 파일이 없어도 동작한다.
        Invoke-Checked $docker.Source @('image', 'inspect', '--format', '{{.Id}}', $DockerImage)
    }
    elseif ($RebuildImage) {
        Invoke-Checked $docker.Source @('build', '--build-arg', "ROCKY_VERSION=$RockyVersion", '-f',
            (Join-Path $repoRoot 'tools\docker\Dockerfile.linux'), '-t', $DockerImage, $repoRoot)
    }
    elseif (Test-Path -LiteralPath $bundledImage -PathType Leaf) {
        # 불러올 이미지만 검증하며 선택하지 않은 버전의 이미지는 요구하지 않는다.
        & (Join-Path $bundledImageDirectory 'update-builder-image.ps1') -VerifyOnly -UseSourceBuildScript -RockyVersions $RockyVersion
        Invoke-Checked $docker.Source @('load', '--input', $bundledImage)
        if ($DockerImage -ne $bundledImageTag) {
            Invoke-Checked $docker.Source @('tag', $bundledImageTag, $DockerImage)
        }
        Invoke-Checked $docker.Source @('image', 'inspect', '--format', '{{.Id}}', $DockerImage)
    }
    else {
        Invoke-Checked $docker.Source @('build', '--build-arg', "ROCKY_VERSION=$RockyVersion", '-f',
            (Join-Path $repoRoot 'tools\docker\Dockerfile.linux'), '-t', $DockerImage, $repoRoot)
    }

    $runtimeFlag = if ($IncludeRtiRuntime) { 'ON' } else { 'OFF' }
    $skipTestsFlag = if ($WithTests -and -not $SkipTests) { 'OFF' } else { 'ON' }
    # 멀티캐스트 가능한 격리 인터페이스를 사용해 다른 빌드와 섞이지 않게 한다.
    $networkName = 'ddsclient-test-' + [guid]::NewGuid().ToString('N')
    & $docker.Source network create --internal $networkName
    if ($LASTEXITCODE -ne 0) { throw '격리된 Docker 테스트 네트워크를 만들지 못했습니다.' }
    $testNetwork = $networkName
    Invoke-Checked $docker.Source @(
        'run', '--rm', '--network', $testNetwork,
        '--mount', "type=bind,source=$repoRoot,target=/workspace,readonly",
        '--mount', "type=bind,source=$($rti.Home),target=/opt/rti,readonly",
        '--mount', "type=bind,source=$generatedRoot,target=/generated,readonly",
        '--mount', "type=bind,source=$stagingRoot,target=/out",
        '--env', "DDSCLIENT_PACKAGE_NAME=$packageName",
        '--env', "DDSCLIENT_INCLUDE_RTI_RUNTIME=$runtimeFlag",
        '--env', "DDSCLIENT_SKIP_TESTS=$skipTestsFlag",
        '--env', "DDSCLIENT_BUILD_CLI=$(if ($WithCli) { 'ON' } else { 'OFF' })",
        '--env', "DDSCLIENT_RTI_PLATFORM=$($rti.LinuxPlatform)",
        '--env', "DDSCLIENT_RTI_PRODUCT_VERSION=$($rti.ProductVersion)",
        '--entrypoint', 'bash', $DockerImage, '/workspace/tools/docker/build-linux.sh')

    $stagedArchive = Join-Path $stagingRoot "$packageName.tar.gz"
    $stagedChecksum = "$stagedArchive.sha256"
    foreach ($name in $finalNames) {
        if (-not (Test-Path -LiteralPath (Join-Path $stagingRoot $name))) { throw "Linux 결과 파일이 없습니다: $name" }
    }
    $expectedHash = ((Get-Content -LiteralPath $stagedChecksum -Raw).Trim() -split '\s+')[0]
    $actualHash = (Get-FileHash -LiteralPath $stagedArchive -Algorithm SHA256).Hash
    if (-not $actualHash.Equals($expectedHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw '생성한 Linux 패키지의 체크섬이 일치하지 않습니다.'
    }
    Publish-OutputSet $stagingRoot $OutputDirectory $finalNames

    Write-Host 'Linux C++ 패키지 생성이 완료되었습니다.'
    Write-Host "  RTI    : $($rti.ProductVersion) / $($rti.LinuxPlatform)"
    Write-Host "  압축 파일: $(Join-Path $OutputDirectory "$packageName.tar.gz")"
    Write-Host "  SHA-256: $actualHash"
}
finally {
    if ($testNetwork) {
        & $docker.Source network rm $testNetwork
        if ($LASTEXITCODE -ne 0) { Write-Warning "테스트 네트워크를 삭제하지 못했습니다: $testNetwork" }
    }
    if ($generatedRoot -and (Test-Path -LiteralPath $generatedRoot)) {
        Remove-Item -LiteralPath $generatedRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($stagingRoot -and (Test-Path -LiteralPath $stagingRoot)) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($lockStream) { $lockStream.Dispose() }
    if ($lockPath) { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue }
}
