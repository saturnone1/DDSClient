[CmdletBinding()]
param(
    # Every Rocky version whose builder image is bundled for offline builds. The source
    # package ships one image per entry so a closed network can build any of them.
    [ValidatePattern('^\d+(\.\d+)*$')]
    [string[]] $RockyVersions = @('9.7', '10.0'),
    [switch] $VerifyOnly,
    # 저장소의 빌드 스크립트를 읽기 전용으로 실행하는 호출자만 사용합니다.
    [switch] $UseSourceBuildScript
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../tools/build/common.ps1')
$toolDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $toolDirectory '..\..'))
$dockerfile = Join-Path $repoRoot 'tools\docker\Dockerfile.linux'
$buildScript = Join-Path $repoRoot 'tools\docker\build-linux.sh'
# Shared across versions: it records the builder sources, which are the same Dockerfile
# and script for every Rocky version.
$sourceChecksums = Join-Path $toolDirectory 'builder-image-sources.sha256'

function Get-ChecksumLine {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $DisplayName)
    return "$((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash)  $DisplayName"
}

function Get-BuilderNames {
    param([Parameter(Mandatory)] [string] $Version)
    $major = ($Version -split '\.')[0]
    $archiveName = "ddsclient-rocky$major-builder.tar"
    return [pscustomobject]@{
        Version         = $Version
        Major           = $major
        ImageName       = "ddsclient-rocky$major-builder:latest"
        ArchiveName     = $archiveName
        Archive         = Join-Path $toolDirectory $archiveName
        ArchiveChecksum = Join-Path $toolDirectory "$archiveName.sha256"
    }
}

function Get-ExpectedSourceChecksums {
    return @(
        Get-ChecksumLine $dockerfile 'tools/docker/Dockerfile.linux'
        Get-ChecksumLine $buildScript 'tools/docker/build-linux.sh')
}

function Test-BuilderSources {
    if (-not (Test-Path -LiteralPath $sourceChecksums -PathType Leaf)) {
        throw "동봉된 Linux 빌더 소스의 체크섬 파일이 없습니다: $sourceChecksums"
    }
    $expected = Get-Content -LiteralPath $sourceChecksums
    $actual = @(Get-ExpectedSourceChecksums)
    if ($UseSourceBuildScript) {
        # 이미지 안의 구형 실행 스크립트는 사용하지 않습니다. 기반 이미지의
        # Dockerfile과 이미지 전체 해시는 계속 검증하며 기록을 재작성하지 않습니다.
        $expected = @($expected | Where-Object { $_ -match '  tools/docker/Dockerfile\.linux$' })
        $actual = @($actual | Where-Object { $_ -match '  tools/docker/Dockerfile\.linux$' })
        if ($expected.Count -ne 1) { throw '빌더 Dockerfile의 체크섬 기록이 없거나 중복되었습니다.' }
    }
    if (($expected -join "`n") -ne ($actual -join "`n")) {
        throw 'Linux 빌더 소스가 변경되었습니다. offline-tools\linux-x64\update-builder-image.ps1을 실행하세요.'
    }
}

function Test-BuilderImage {
    param([Parameter(Mandatory)] [object] $Names)
    foreach ($path in @($Names.Archive, $Names.ArchiveChecksum)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "동봉된 Linux 빌더 이미지 파일이 없습니다: $path`noffline-tools\linux-x64\update-builder-image.ps1 -RockyVersions $($Names.Version)을 실행하세요."
        }
    }
    $expected = ((Get-Content -LiteralPath $Names.ArchiveChecksum -Raw).Trim() -split '\s+')[0]
    $actual = (Get-FileHash -LiteralPath $Names.Archive -Algorithm SHA256).Hash
    if (-not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "동봉된 Linux 빌더 이미지의 체크섬이 일치하지 않습니다: $($Names.ArchiveName)"
    }
}

if ($VerifyOnly) {
    Test-BuilderSources
    foreach ($version in $RockyVersions) {
        Test-BuilderImage (Get-BuilderNames $version)
    }
    Write-Host "동봉된 Linux 빌더 이미지의 체크섬 검증을 통과했습니다: $($RockyVersions -join ', ')"
    return
}

$docker = Get-Command docker -ErrorAction SilentlyContinue
if (-not $docker) { throw 'Docker를 찾을 수 없습니다.' }
& $docker.Source info *> $null
if ($LASTEXITCODE -ne 0) { throw 'Docker Linux 엔진이 실행 중이 아닙니다.' }

$lockStream = $null
$lockPath = Join-Path $toolDirectory '.builder-image.lock'
$temporaryRoot = Join-Path $toolDirectory ('.builder-image-staging-' + [guid]::NewGuid().ToString('N'))
$backupRoot = Join-Path $toolDirectory ('.builder-image-backup-' + [guid]::NewGuid().ToString('N'))
try {
    try {
        $lockStream = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    }
    catch { throw '다른 빌더 이미지 갱신 작업이 실행 중입니다.' }
    New-Item -ItemType Directory -Path $temporaryRoot, $backupRoot | Out-Null

    $sources = [System.Collections.Generic.List[string]]::new()
    $destinations = [System.Collections.Generic.List[string]]::new()

    foreach ($version in $RockyVersions) {
        $names = Get-BuilderNames $version
        Write-Host "Rocky $version 기반의 $($names.ImageName) 이미지를 생성합니다..."
        $temporaryArchive = Join-Path $temporaryRoot $names.ArchiveName
        $temporaryArchiveChecksum = "$temporaryArchive.sha256"

        & $docker.Source build --build-arg "ROCKY_VERSION=$version" -f $dockerfile -t $names.ImageName $repoRoot
        if ($LASTEXITCODE -ne 0) { throw "Rocky $version 빌더 이미지 생성에 실패했습니다." }
        & $docker.Source save --output $temporaryArchive $names.ImageName
        if ($LASTEXITCODE -ne 0) { throw "Rocky $version 빌더 이미지 내보내기에 실패했습니다." }
        Set-Content -LiteralPath $temporaryArchiveChecksum -Encoding ascii -Value (Get-ChecksumLine $temporaryArchive $names.ArchiveName)

        $sources.Add($temporaryArchive); $destinations.Add($names.Archive)
        $sources.Add($temporaryArchiveChecksum); $destinations.Add($names.ArchiveChecksum)
    }

    $temporarySourceChecksums = Join-Path $temporaryRoot 'builder-image-sources.sha256'
    Set-Content -LiteralPath $temporarySourceChecksums -Encoding ascii -Value (Get-ExpectedSourceChecksums)
    $sources.Add($temporarySourceChecksums); $destinations.Add($sourceChecksums)

    for ($index = 0; $index -lt $destinations.Count; $index++) {
        if (Test-Path -LiteralPath $destinations[$index]) {
            Move-Item -LiteralPath $destinations[$index] -Destination (Join-Path $backupRoot ([System.IO.Path]::GetFileName($destinations[$index])))
        }
    }
    try {
        for ($index = 0; $index -lt $sources.Count; $index++) {
            Move-Item -LiteralPath $sources[$index] -Destination $destinations[$index]
        }
        Test-BuilderSources
        foreach ($version in $RockyVersions) { Test-BuilderImage (Get-BuilderNames $version) }
    }
    catch {
        foreach ($destination in $destinations) { Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue }
        foreach ($destination in $destinations) {
            $backup = Join-Path $backupRoot ([System.IO.Path]::GetFileName($destination))
            if (Test-Path -LiteralPath $backup) { Move-Item -LiteralPath $backup -Destination $destination }
        }
        throw
    }
    Write-Host "Linux 빌더 이미지 갱신 완료: $($RockyVersions -join ', ')"
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
    if ($lockStream) { $lockStream.Dispose() }
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
}
