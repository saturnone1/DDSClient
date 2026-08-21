[CmdletBinding()]
param([string] $OutputPath, [switch] $Force)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $repoRoot 'artifacts\DDSClient-Source-Build-windows-x64.zip'
}
elseif (-not [System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath = Join-Path $repoRoot $OutputPath }
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
if ([System.IO.Path]::GetExtension($OutputPath) -ne '.zip') { throw 'OutputPath must end in .zip.' }
$checksumPath = "$OutputPath.sha256"
$outputDirectory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

function Publish-FileSet {
    param([string[]] $Sources, [string[]] $Destinations)
    $backupDirectory = Join-Path $outputDirectory ('.source-package-backup-' + [guid]::NewGuid().ToString('N'))
    $published = [System.Collections.Generic.List[string]]::new()
    $backedUp = [System.Collections.Generic.List[object]]::new()
    New-Item -ItemType Directory -Path $backupDirectory | Out-Null
    try {
        for ($index = 0; $index -lt $Destinations.Count; $index++) {
            if (Test-Path -LiteralPath $Destinations[$index]) {
                $backup = Join-Path $backupDirectory ([System.IO.Path]::GetFileName($Destinations[$index]))
                Move-Item -LiteralPath $Destinations[$index] -Destination $backup
                $backedUp.Add([pscustomobject]@{ Source = $backup; Destination = $Destinations[$index] })
            }
        }
        for ($index = 0; $index -lt $Sources.Count; $index++) {
            Move-Item -LiteralPath $Sources[$index] -Destination $Destinations[$index]
            $published.Add($Destinations[$index])
        }
    }
    catch {
        foreach ($path in $published) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        foreach ($item in $backedUp) {
            if (Test-Path -LiteralPath $item.Source) {
                Move-Item -LiteralPath $item.Source -Destination $item.Destination -ErrorAction SilentlyContinue
            }
        }
        throw
    }
    finally { Remove-Item -LiteralPath $backupDirectory -Recurse -Force -ErrorAction SilentlyContinue }
}

& (Join-Path $repoRoot 'offline-tools\windows-x64\install-tools.ps1') -VerifyOnly
& (Join-Path $repoRoot 'offline-tools\linux-x64\update-builder-image.ps1') -VerifyOnly

$lockStream = $null
$lockPath = Join-Path $outputDirectory '.ddsclient-source-package.lock'
$stagingRoot = $null
$temporaryArchive = Join-Path $outputDirectory ('.DDSClient-source-' + [guid]::NewGuid().ToString('N') + '.zip')
$temporaryChecksum = "$temporaryArchive.sha256"
try {
    try {
        $lockStream = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    }
    catch { throw "Another source package operation is already running in $outputDirectory" }
    $existing = @($OutputPath, $checksumPath) | Where-Object { Test-Path -LiteralPath $_ }
    if ($existing -and -not $Force) { throw "Output already exists: $($existing -join ', '). Pass -Force to replace it after validation." }

    $stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('DDSClient-source-package-' + [guid]::NewGuid().ToString('N'))
    $packageRoot = Join-Path $stagingRoot 'DDSClient'
    New-Item -ItemType Directory -Path $packageRoot | Out-Null

    $rootFiles = @('.dockerignore', 'README.md', 'BUILD-WINDOWS-OFFLINE.md', 'BUILD-LINUX.md', 'THIRD-PARTY-NOTICES.md',
        'build-all.ps1', 'build-linux.ps1', 'build.ps1', 'create-source-package.ps1', 'global.json')
    foreach ($file in $rootFiles) { Copy-Item -LiteralPath (Join-Path $repoRoot $file) -Destination $packageRoot }

    foreach ($directory in @('DDS_Nuget', 'DDSCPP', 'offline-tools')) {
        $source = Join-Path $repoRoot $directory
        $destination = Join-Path $packageRoot $directory
        New-Item -ItemType Directory -Path $destination | Out-Null
        & robocopy.exe $source $destination /E /R:2 /W:1 /NFL /NDL /NJH /NJS /NP /XD .git .vs build 'build-*' bin obj artifacts | Out-Null
        if ($LASTEXITCODE -gt 7) { throw "Failed to stage $directory (robocopy exit code $LASTEXITCODE)." }
        # robocopy reports success with a non-zero code (1 = files copied). It is the last
        # native command in this script, so leaving it set makes the script exit non-zero
        # even when the package was built correctly.
        $global:LASTEXITCODE = 0
    }

    $manifest = @(
        'DDSClient offline source build package',
        "Created: $([DateTimeOffset]::Now.ToString('o'))",
        'Host platform: Windows x64',
        'Build targets: Windows x64 and Rocky Linux 9 x64',
        '.NET SDK: 9.0.316', 'CMake: 4.4.0', 'Python: 3.13.14',
        'RTI product: 7.3.1 compatible (installation supplied separately)',
        'Note: an RTI 7.3.1 installation may contain the x64Linux4gcc7.3.0 target name.',
        '', 'Start with build.ps1 -Doctor, BUILD-WINDOWS-OFFLINE.md, or BUILD-LINUX.md.')
    Set-Content -LiteralPath (Join-Path $packageRoot 'PACKAGE-MANIFEST.txt') -Value $manifest -Encoding utf8

    Compress-Archive -LiteralPath $packageRoot -DestinationPath $temporaryArchive -CompressionLevel Optimal
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archiveReader = [System.IO.Compression.ZipFile]::OpenRead($temporaryArchive)
    try {
        foreach ($required in @('DDSClient/build.ps1', 'DDSClient/build-linux.ps1',
            'DDSClient/DDSCPP/Dockerfile.linux',
            'DDSClient/offline-tools/linux-x64/ddsclient-rocky9-builder.tar',
            'DDSClient/offline-tools/linux-x64/ddsclient-rocky10-builder.tar')) {
            if (-not ($archiveReader.Entries | Where-Object FullName -eq $required)) {
                throw "Generated archive is missing: $required"
            }
        }
    }
    finally { $archiveReader.Dispose() }

    $hash = (Get-FileHash -LiteralPath $temporaryArchive -Algorithm SHA256).Hash
    Set-Content -LiteralPath $temporaryChecksum -Value "$hash  $([System.IO.Path]::GetFileName($OutputPath))" -Encoding ascii
    Publish-FileSet @($temporaryArchive, $temporaryChecksum) @($OutputPath, $checksumPath)

    $archive = Get-Item -LiteralPath $OutputPath
    Write-Host 'Source build package created.'
    Write-Host "  Archive : $($archive.FullName)"
    Write-Host "  Size    : $([math]::Round($archive.Length / 1MB, 1)) MiB"
    Write-Host "  SHA-256 : $hash"
}
finally {
    foreach ($temporary in @($temporaryArchive, $temporaryChecksum)) {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
    if ($stagingRoot -and (Test-Path -LiteralPath $stagingRoot)) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($lockStream) { $lockStream.Dispose() }
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
}
