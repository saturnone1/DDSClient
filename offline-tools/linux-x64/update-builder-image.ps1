[CmdletBinding()]
param(
    # Every Rocky version whose builder image is bundled for offline builds. The source
    # package ships one image per entry so a closed network can build any of them.
    [ValidatePattern('^\d+(\.\d+)*$')]
    [string[]] $RockyVersions = @('9.7', '10.0'),
    [switch] $VerifyOnly
)

$ErrorActionPreference = 'Stop'
$toolDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $toolDirectory '..\..'))
$dockerfile = Join-Path $repoRoot 'DDSCPP\Dockerfile.linux'
$buildScript = Join-Path $repoRoot 'DDSCPP\tools\build-linux.sh'
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
        Get-ChecksumLine $dockerfile 'DDSCPP/Dockerfile.linux'
        Get-ChecksumLine $buildScript 'DDSCPP/tools/build-linux.sh')
}

function Test-BuilderSources {
    if (-not (Test-Path -LiteralPath $sourceChecksums -PathType Leaf)) {
        throw "Bundled Linux builder source checksums are missing: $sourceChecksums"
    }
    $expected = Get-Content -LiteralPath $sourceChecksums
    if (($expected -join "`n") -ne ((Get-ExpectedSourceChecksums) -join "`n")) {
        throw 'The Linux builder sources changed. Run offline-tools\linux-x64\update-builder-image.ps1.'
    }
}

function Test-BuilderImage {
    param([Parameter(Mandatory)] [object] $Names)
    foreach ($path in @($Names.Archive, $Names.ArchiveChecksum)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Bundled Linux builder image file is missing: $path`nRun offline-tools\linux-x64\update-builder-image.ps1 -RockyVersions $($Names.Version)."
        }
    }
    $expected = ((Get-Content -LiteralPath $Names.ArchiveChecksum -Raw).Trim() -split '\s+')[0]
    $actual = (Get-FileHash -LiteralPath $Names.Archive -Algorithm SHA256).Hash
    if (-not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Bundled Linux builder image checksum does not match: $($Names.ArchiveName)"
    }
}

if ($VerifyOnly) {
    Test-BuilderSources
    foreach ($version in $RockyVersions) {
        Test-BuilderImage (Get-BuilderNames $version)
    }
    Write-Host "Bundled Linux builder images passed checksum verification: $($RockyVersions -join ', ')"
    return
}

$docker = Get-Command docker -ErrorAction SilentlyContinue
if (-not $docker) { throw 'Docker was not found.' }
& $docker.Source info *> $null
if ($LASTEXITCODE -ne 0) { throw 'The Docker Linux engine is not running.' }

$lockStream = $null
$lockPath = Join-Path $toolDirectory '.builder-image.lock'
$temporaryRoot = Join-Path $toolDirectory ('.builder-image-staging-' + [guid]::NewGuid().ToString('N'))
$backupRoot = Join-Path $toolDirectory ('.builder-image-backup-' + [guid]::NewGuid().ToString('N'))
try {
    try {
        $lockStream = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    }
    catch { throw 'Another builder image update is already running.' }
    New-Item -ItemType Directory -Path $temporaryRoot, $backupRoot | Out-Null

    $sources = [System.Collections.Generic.List[string]]::new()
    $destinations = [System.Collections.Generic.List[string]]::new()

    foreach ($version in $RockyVersions) {
        $names = Get-BuilderNames $version
        Write-Host "Building $($names.ImageName) from Rocky $version..."
        $temporaryArchive = Join-Path $temporaryRoot $names.ArchiveName
        $temporaryArchiveChecksum = "$temporaryArchive.sha256"

        & $docker.Source build --build-arg "ROCKY_VERSION=$version" -f $dockerfile -t $names.ImageName (Join-Path $repoRoot 'DDSCPP')
        if ($LASTEXITCODE -ne 0) { throw "Failed to build the Linux builder image for Rocky $version." }
        & $docker.Source save --output $temporaryArchive $names.ImageName
        if ($LASTEXITCODE -ne 0) { throw "Failed to export the Linux builder image for Rocky $version." }
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
    Write-Host "Linux builder images updated: $($RockyVersions -join ', ')"
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
    if ($lockStream) { $lockStream.Dispose() }
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
}
