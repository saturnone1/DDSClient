[CmdletBinding()]
param([switch] $VerifyOnly)

$ErrorActionPreference = 'Stop'
$toolDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $toolDirectory '..\..'))
$dockerfile = Join-Path $repoRoot 'DDSCPP\Dockerfile.linux'
$buildScript = Join-Path $repoRoot 'DDSCPP\tools\build-linux.sh'
$imageArchive = Join-Path $toolDirectory 'ddsclient-rocky9-builder.tar'
$archiveChecksum = Join-Path $toolDirectory 'ddsclient-rocky9-builder.tar.sha256'
$sourceChecksums = Join-Path $toolDirectory 'builder-image-sources.sha256'
$imageName = 'ddsclient-rocky9-builder:latest'

function Get-ChecksumLine {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $DisplayName)
    return "$((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash)  $DisplayName"
}

function Test-BuilderImage {
    foreach ($path in @($imageArchive, $archiveChecksum, $sourceChecksums)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Bundled Linux builder image file is missing: $path" }
    }
    $expectedArchive = ((Get-Content -LiteralPath $archiveChecksum -Raw).Trim() -split '\s+')[0]
    $actualArchive = (Get-FileHash -LiteralPath $imageArchive -Algorithm SHA256).Hash
    if (-not $actualArchive.Equals($expectedArchive, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Bundled Linux builder image checksum does not match.'
    }
    $expectedSources = Get-Content -LiteralPath $sourceChecksums
    $actualSources = @(Get-ChecksumLine $dockerfile 'DDSCPP/Dockerfile.linux';
        Get-ChecksumLine $buildScript 'DDSCPP/tools/build-linux.sh')
    if (($expectedSources -join "`n") -ne ($actualSources -join "`n")) {
        throw 'The Linux builder sources changed. Run offline-tools\linux-x64\update-builder-image.ps1.'
    }
}

if ($VerifyOnly) {
    Test-BuilderImage
    Write-Host 'Bundled Linux builder image passed checksum verification.'
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
    $temporaryArchive = Join-Path $temporaryRoot 'ddsclient-rocky9-builder.tar'
    $temporaryArchiveChecksum = Join-Path $temporaryRoot 'ddsclient-rocky9-builder.tar.sha256'
    $temporarySourceChecksums = Join-Path $temporaryRoot 'builder-image-sources.sha256'

    & $docker.Source build --build-arg 'ROCKY_VERSION=9.7' -f $dockerfile -t $imageName (Join-Path $repoRoot 'DDSCPP')
    if ($LASTEXITCODE -ne 0) { throw 'Failed to build the Linux builder image.' }
    & $docker.Source save --output $temporaryArchive $imageName
    if ($LASTEXITCODE -ne 0) { throw 'Failed to export the Linux builder image.' }
    Set-Content -LiteralPath $temporaryArchiveChecksum -Encoding ascii -Value (Get-ChecksumLine $temporaryArchive 'ddsclient-rocky9-builder.tar')
    Set-Content -LiteralPath $temporarySourceChecksums -Encoding ascii -Value @(
        Get-ChecksumLine $dockerfile 'DDSCPP/Dockerfile.linux'
        Get-ChecksumLine $buildScript 'DDSCPP/tools/build-linux.sh')

    $destinations = @($imageArchive, $archiveChecksum, $sourceChecksums)
    $sources = @($temporaryArchive, $temporaryArchiveChecksum, $temporarySourceChecksums)
    for ($index = 0; $index -lt $destinations.Count; $index++) {
        if (Test-Path -LiteralPath $destinations[$index]) {
            Move-Item -LiteralPath $destinations[$index] -Destination (Join-Path $backupRoot ([System.IO.Path]::GetFileName($destinations[$index])))
        }
    }
    try {
        for ($index = 0; $index -lt $sources.Count; $index++) {
            Move-Item -LiteralPath $sources[$index] -Destination $destinations[$index]
        }
        Test-BuilderImage
    }
    catch {
        foreach ($destination in $destinations) { Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue }
        foreach ($destination in $destinations) {
            $backup = Join-Path $backupRoot ([System.IO.Path]::GetFileName($destination))
            if (Test-Path -LiteralPath $backup) { Move-Item -LiteralPath $backup -Destination $destination }
        }
        throw
    }
    Write-Host "Linux builder image updated: $imageArchive"
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
    if ($lockStream) { $lockStream.Dispose() }
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
}
