[CmdletBinding()]
param(
    [string] $RtiHome,
    [string] $RtiPlatform,
    [string] $OutputDirectory,
    [string] $DockerImage = 'ddsclient-rocky9-builder:latest',
    [string] $RockyVersion = '9.7',
    [switch] $SkipImageBuild,
    [switch] $RebuildImage,
    [switch] $IncludeRtiRuntime,
    [switch] $SkipTests,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$packageName = 'DDSClient-CPP-rocky9-x64'
$bundledImageTag = 'ddsclient-rocky9-builder:latest'
$bundledRockyVersion = '9.7'
$bundledImageDirectory = Join-Path $repoRoot 'offline-tools\linux-x64'
$bundledImage = Join-Path $bundledImageDirectory 'ddsclient-rocky9-builder.tar'

function Invoke-Checked {
    param([Parameter(Mandatory)] [string] $FilePath, [Parameter(Mandatory)] [string[]] $Arguments)
    Write-Host "> $FilePath $($Arguments -join ' ')"
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed with exit code ${LASTEXITCODE}: $FilePath" }
}

function Test-RtiLinuxTarget {
    param([Parameter(Mandatory)] [System.IO.DirectoryInfo] $Directory)
    return (Test-Path -LiteralPath (Join-Path $Directory.FullName 'libnddscpp2.so')) -and
        (Test-Path -LiteralPath (Join-Path $Directory.FullName 'libnddsc.so')) -and
        (Test-Path -LiteralPath (Join-Path $Directory.FullName 'libnddscore.so'))
}

function Resolve-RtiInstallation {
    param([string] $RequestedHome, [string] $RequestedPlatform)
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($RequestedHome) { $candidates.Add($RequestedHome) }
    if ($env:NDDSHOME) { $candidates.Add($env:NDDSHOME) }
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    if ($programFiles) {
        Get-ChildItem -LiteralPath $programFiles -Directory -Filter 'rti_connext_dds-*' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | ForEach-Object { $candidates.Add($_.FullName) }
    }
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
                catch { Write-Warning "Could not read RTI product version from $versionsFile" }
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
    $suffix = if ($RequestedPlatform) { " Requested target: $RequestedPlatform." } else { '' }
    throw "RTI host tools and a usable x64Linux target were not found. Set NDDSHOME or pass -RtiHome/-RtiPlatform.$suffix"
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

if ($SkipImageBuild -and $RebuildImage) { throw '-SkipImageBuild and -RebuildImage cannot be used together.' }
$docker = Get-Command docker -ErrorAction SilentlyContinue
if (-not $docker) { throw 'Docker was not found. Install Docker Desktop and enable Linux containers.' }
& $docker.Source info *> $null
if ($LASTEXITCODE -ne 0) { throw 'The Docker Linux engine is not running. Start Docker Desktop and try again.' }
$cmake = Get-Command cmake -ErrorAction SilentlyContinue
if (-not $cmake) { throw 'CMake was not found. Run offline-tools\windows-x64\install-tools.ps1 first.' }
$rti = Resolve-RtiInstallation $RtiHome $RtiPlatform

if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'artifacts\linux' }
elseif (-not [System.IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory = Join-Path $repoRoot $OutputDirectory }
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$lockStream = $null
$lockPath = $null
$generatedRoot = $null
$stagingRoot = $null
try {
    $lockPath = Join-Path $OutputDirectory '.ddsclient-linux.lock'
    try {
        $lockStream = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    }
    catch { throw "Another Linux build is already using this output directory: $OutputDirectory" }

    $finalNames = @($packageName, "$packageName.tar.gz", "$packageName.tar.gz.sha256")
    $existing = $finalNames | ForEach-Object { Join-Path $OutputDirectory $_ } | Where-Object { Test-Path -LiteralPath $_ }
    if ($existing -and -not $Force) {
        throw "Linux output already exists. Pass -Force to replace it after a successful build: $($existing -join ', ')"
    }

    $generatedRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('DDSClient-linux-generated-' + [guid]::NewGuid().ToString('N'))
    $stagingRoot = Join-Path $OutputDirectory ('.ddsclient-staging-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $generatedRoot, $stagingRoot | Out-Null

    $schemaDir = Join-Path $rti.Home 'resource\schema'
    $definitions = Join-Path $repoRoot 'DDS_Nuget\definitions'
    Invoke-Checked $cmake.Source @(
        "-DRTIDDSGEN=$($rti.Generator)", "-DRTI_SCHEMA_DIR=$schemaDir",
        "-DDDS_XML=$(Join-Path $definitions 'DDSSim.xml')",
        "-DTOPICS_XML=$(Join-Path $definitions 'topics.xml')",
        "-DOUTPUT_DIR=$generatedRoot", '-P', (Join-Path $repoRoot 'DDSCPP\cmake\GenerateRtiTypes.cmake'))

    $customRockyRequested = $PSBoundParameters.ContainsKey('RockyVersion') -and $RockyVersion -ne $bundledRockyVersion
    if ($RebuildImage -or $customRockyRequested) {
        Invoke-Checked $docker.Source @('build', '--build-arg', "ROCKY_VERSION=$RockyVersion", '-f',
            (Join-Path $repoRoot 'DDSCPP\Dockerfile.linux'), '-t', $DockerImage, (Join-Path $repoRoot 'DDSCPP'))
    }
    elseif ($SkipImageBuild) {
        Invoke-Checked $docker.Source @('image', 'inspect', '--format', '{{.Id}}', $DockerImage)
    }
    elseif (Test-Path -LiteralPath $bundledImage -PathType Leaf) {
        & (Join-Path $bundledImageDirectory 'update-builder-image.ps1') -VerifyOnly
        Invoke-Checked $docker.Source @('load', '--input', $bundledImage)
        if ($DockerImage -ne $bundledImageTag) {
            Invoke-Checked $docker.Source @('tag', $bundledImageTag, $DockerImage)
        }
        Invoke-Checked $docker.Source @('image', 'inspect', '--format', '{{.Id}}', $DockerImage)
    }
    else {
        Invoke-Checked $docker.Source @('build', '--build-arg', "ROCKY_VERSION=$RockyVersion", '-f',
            (Join-Path $repoRoot 'DDSCPP\Dockerfile.linux'), '-t', $DockerImage, (Join-Path $repoRoot 'DDSCPP'))
    }

    $runtimeFlag = if ($IncludeRtiRuntime) { 'ON' } else { 'OFF' }
    $skipTestsFlag = if ($SkipTests) { 'ON' } else { 'OFF' }
    Invoke-Checked $docker.Source @(
        'run', '--rm',
        '--mount', "type=bind,source=$repoRoot,target=/workspace,readonly",
        '--mount', "type=bind,source=$($rti.Home),target=/opt/rti,readonly",
        '--mount', "type=bind,source=$generatedRoot,target=/generated,readonly",
        '--mount', "type=bind,source=$stagingRoot,target=/out",
        '--env', "DDSCLIENT_PACKAGE_NAME=$packageName",
        '--env', "DDSCLIENT_INCLUDE_RTI_RUNTIME=$runtimeFlag",
        '--env', "DDSCLIENT_SKIP_TESTS=$skipTestsFlag",
        '--env', "DDSCLIENT_RTI_PLATFORM=$($rti.LinuxPlatform)",
        '--env', "DDSCLIENT_RTI_PRODUCT_VERSION=$($rti.ProductVersion)",
        $DockerImage)

    $stagedArchive = Join-Path $stagingRoot "$packageName.tar.gz"
    $stagedChecksum = "$stagedArchive.sha256"
    foreach ($name in $finalNames) {
        if (-not (Test-Path -LiteralPath (Join-Path $stagingRoot $name))) { throw "Linux output is missing: $name" }
    }
    $expectedHash = ((Get-Content -LiteralPath $stagedChecksum -Raw).Trim() -split '\s+')[0]
    $actualHash = (Get-FileHash -LiteralPath $stagedArchive -Algorithm SHA256).Hash
    if (-not $actualHash.Equals($expectedHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The generated Linux package checksum does not match.'
    }
    Publish-OutputSet $stagingRoot $OutputDirectory $finalNames

    Write-Host 'Linux C++ package completed.'
    Write-Host "  RTI    : $($rti.ProductVersion) / $($rti.LinuxPlatform)"
    Write-Host "  Archive: $(Join-Path $OutputDirectory "$packageName.tar.gz")"
    Write-Host "  SHA-256: $actualHash"
}
finally {
    if ($generatedRoot -and (Test-Path -LiteralPath $generatedRoot)) {
        Remove-Item -LiteralPath $generatedRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($stagingRoot -and (Test-Path -LiteralPath $stagingRoot)) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($lockStream) { $lockStream.Dispose() }
    if ($lockPath) { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue }
}
