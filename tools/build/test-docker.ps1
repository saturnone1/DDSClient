[CmdletBinding()]
param(
    [ValidatePattern('^\d+(\.\d+)*$')]
    [string[]] $RockyVersions = @('9.7', '10.0'),
    [string] $RtiHome,
    [string] $LicenseFile,
    [string] $OutputDirectory,
    [string] $DotnetImage = 'mcr.microsoft.com/dotnet/sdk:9.0',
    [switch] $SkipImageBuild
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $PSScriptRoot 'common.ps1')

$docker = Get-Command docker -ErrorAction SilentlyContinue
if (-not $docker) { throw 'Docker를 찾을 수 없습니다. Docker Desktop을 설치하고 Linux 컨테이너를 활성화하세요.' }
$engine = & $docker.Source info --format '{{.OSType}}'
if ($LASTEXITCODE -ne 0 -or $engine -ne 'linux') { throw 'Docker Linux 엔진이 실행 중이 아닙니다.' }

# 네이티브 런타임은 로컬 NuGet 저장소에서 가져오고 라이선스만 호스트에서 마운트한다.
# 명시적 라이선스 경로나 RTI_LICENSE_FILE을 호스트 기본 경로보다 우선한다.
if (-not $LicenseFile) { $LicenseFile = $env:RTI_LICENSE_FILE }
if (-not $LicenseFile) {
    foreach ($candidate in @(Get-RtiHomeCandidates -RequestedHome $RtiHome -SkipWhitespace)) {
        $candidateLicense = Join-Path $candidate 'rti_license.dat'
        if (Test-Path -LiteralPath $candidateLicense -PathType Leaf) {
            $LicenseFile = $candidateLicense
            break
        }
    }
}
if (-not $LicenseFile -or -not (Test-Path -LiteralPath $LicenseFile -PathType Leaf)) {
    throw 'RTI 라이선스 파일이 필요합니다. -LicenseFile, RTI_LICENSE_FILE 또는 -RtiHome을 지정하세요.'
}
$LicenseFile = (Resolve-Path -LiteralPath $LicenseFile).ProviderPath

if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'artifacts\docker-csharp' }
elseif (-not [System.IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory = Join-Path $repoRoot $OutputDirectory }
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)

foreach ($version in $RockyVersions) {
    $major = ($version -split '\.')[0]
    $builderImage = "ddsclient-rocky$major-builder:latest"
    $testImage = "ddsclient-csharp-rocky$major-test:local"
    if ($SkipImageBuild) {
        Invoke-Checked $docker.Source @('image', 'inspect', '--format', '{{.Id}}', $testImage)
    }
    else {
        # 폐쇄망에서 사용할 기반 이미지는 미리 준비되어 있어야 한다.
        # 테스트 실행기가 동봉된 빌더 이미지를 갱신하거나 내보내지 않는다.
        Invoke-Checked $docker.Source @('image', 'inspect', '--format', '{{.Id}}', $builderImage)
        Invoke-Checked $docker.Source @('image', 'inspect', '--format', '{{.Id}}', $DotnetImage)
        Invoke-Checked $docker.Source @('build', '--build-arg', "ROCKY_IMAGE=$builderImage",
            '--build-arg', "DOTNET_IMAGE=$DotnetImage", '-f', (Join-Path $repoRoot 'tools\docker\Dockerfile.test'),
            '-t', $testImage, $repoRoot)
    }

    $runId = [guid]::NewGuid().ToString('N')
    $results = Join-Path $OutputDirectory "rocky$version\$runId"
    New-Item -ItemType Directory -Force -Path $results | Out-Null
    $networkName = "ddsclient-csharp-rocky$major-$runId"
    $networkCreated = $false
    try {
        Invoke-Checked $docker.Source @('network', 'create', '--driver', 'bridge', '--internal', $networkName)
        $networkCreated = $true
        Write-Host "C# RTI 테스트: Rocky $version / 결과: $results"
        Invoke-Checked $docker.Source @('run', '--rm', '--network', $networkName,
            '--mount', "type=bind,source=$repoRoot,target=/workspace,readonly",
            '--mount', "type=bind,source=$LicenseFile,target=/run/rti-license.dat,readonly",
            '--mount', "type=bind,source=$results,target=/out",
            '--env', 'RTI_LICENSE_FILE=/run/rti-license.dat',
            # 스크립트 이동 전의 이미지를 재사용하더라도 현재 소스의 진입점을 사용한다.
            '--entrypoint', 'bash', $testImage, '/workspace/tools/docker/test-linux.sh')
    }
    finally {
        if ($networkCreated) {
            & $docker.Source network rm $networkName
            if ($LASTEXITCODE -ne 0) { Write-Warning "테스트 네트워크를 삭제하지 못했습니다: $networkName" }
        }
    }
}
