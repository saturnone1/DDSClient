[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',

    [string] $RtiHome,

    [switch] $SkipTests,

    [switch] $Clean
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Find-CommandPath {
    param([Parameter(Mandatory)] [string] $Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "Required command '$Name' was not found. Run offline-tools\windows-x64\install-tools.ps1 as Administrator, then open a new PowerShell window."
    }
    return $command.Source
}

function Resolve-RtiHome {
    param([string] $RequestedHome)

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($RequestedHome)) {
        $candidates.Add($RequestedHome)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:NDDSHOME)) {
        $candidates.Add($env:NDDSHOME)
    }

    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
        Get-ChildItem -LiteralPath $programFiles -Directory -Filter 'rti_connext_dds-*' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { $candidates.Add($_.FullName) }
    }

    foreach ($candidate in $candidates) {
        $fullPath = [System.IO.Path]::GetFullPath($candidate)
        $generator = Join-Path $fullPath 'bin\rtiddsgen.bat'
        if (-not (Test-Path -LiteralPath $generator)) {
            $generator = Join-Path $fullPath 'bin\rtiddsgen.exe'
        }
        $schema = Join-Path $fullPath 'resource\schema\rti_dds_profiles.xsd'
        $platformLibraries = Get-ChildItem -LiteralPath (Join-Path $fullPath 'lib') -Directory -Filter 'x64Win64VS*' -ErrorAction SilentlyContinue |
            Where-Object {
                (Test-Path -LiteralPath (Join-Path $_.FullName 'nddscpp2.lib')) -and
                (Test-Path -LiteralPath (Join-Path $_.FullName 'nddsc.lib')) -and
                (Test-Path -LiteralPath (Join-Path $_.FullName 'nddscore.lib'))
            }
        if ((Test-Path -LiteralPath $generator -PathType Leaf) -and
            (Test-Path -LiteralPath $schema -PathType Leaf) -and
            $platformLibraries) {
            return $fullPath
        }
    }

    throw 'A complete RTI Connext DDS installation was not found. It must contain rtiddsgen, resource\schema\rti_dds_profiles.xsd, and Windows x64 nddscpp2/nddsc/nddscore libraries. Set NDDSHOME or pass -RtiHome.'
}

function Remove-BuildDirectory {
    param([Parameter(Mandatory)] [string] $BuildDirectory)

    if (-not (Test-Path -LiteralPath $BuildDirectory)) {
        return
    }

    $resolvedBuildDirectory = [System.IO.Path]::GetFullPath($BuildDirectory)
    $repositoryPrefix = [System.IO.Path]::GetFullPath($repoRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedBuildDirectory.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a build directory outside the repository: $resolvedBuildDirectory"
    }

    Remove-Item -LiteralPath $resolvedBuildDirectory -Recurse -Force
}

function Reset-IncompatibleCMakeCache {
    param(
        [Parameter(Mandatory)] [string] $BuildDirectory,
        [Parameter(Mandatory)] [string] $SourceDirectory
    )

    $cachePath = Join-Path $BuildDirectory 'CMakeCache.txt'
    if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
        return
    }

    $cache = Get-Content -LiteralPath $cachePath
    $cachedSource = ($cache | Where-Object { $_ -like 'CMAKE_HOME_DIRECTORY:INTERNAL=*' } | Select-Object -First 1) -replace '^CMAKE_HOME_DIRECTORY:INTERNAL=', ''
    $cachedCmake = ($cache | Where-Object { $_ -like 'CMAKE_COMMAND:INTERNAL=*' } | Select-Object -First 1) -replace '^CMAKE_COMMAND:INTERNAL=', ''
    $expectedSource = [System.IO.Path]::GetFullPath($SourceDirectory).Replace('\', '/')

    $sourceMoved = [string]::IsNullOrWhiteSpace($cachedSource) -or
        -not $cachedSource.Equals($expectedSource, [StringComparison]::OrdinalIgnoreCase)
    $cmakeMissing = -not [string]::IsNullOrWhiteSpace($cachedCmake) -and
        -not (Test-Path -LiteralPath $cachedCmake -PathType Leaf)

    if ($sourceMoved -or $cmakeMissing) {
        Write-Host "Removing incompatible CMake cache: $BuildDirectory"
        Remove-BuildDirectory $BuildDirectory
    }
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [string[]] $Arguments
    )

    Write-Host "> $FilePath $($Arguments -join ' ')"
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath"
    }
}

$windowsLock = $null
try {
try {
    $windowsLock = [System.IO.File]::Open((Join-Path $repoRoot '.ddsclient-windows-build.lock'),
        'OpenOrCreate', 'ReadWrite', 'None')
}
catch { throw 'Another Windows C#/C++ build is already running in this repository.' }

$cmake = Find-CommandPath 'cmake'
$dotnet = Find-CommandPath 'dotnet'
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    $python = Get-Command py -ErrorAction SilentlyContinue
}
if (-not $python) {
    throw "Python was not found. Run offline-tools\windows-x64\install-tools.ps1 as Administrator, then open a new PowerShell window."
}

$resolvedRtiHome = Resolve-RtiHome $RtiHome
$env:NDDSHOME = $resolvedRtiHome
$env:PATH = "$(Join-Path $resolvedRtiHome 'bin');$env:PATH"

Write-Host 'DDSClient build environment'
Write-Host "  Repository : $repoRoot"
Write-Host "  Configuration: $Configuration"
Write-Host "  RTI Connext: $resolvedRtiHome"
Write-Host "  CMake      : $cmake"
Write-Host "  .NET       : $dotnet"
Write-Host "  Python     : $($python.Source)"

$csharpBuild = Join-Path $repoRoot 'DDS_Nuget\build'
$cppBuild = Join-Path $repoRoot 'DDSCPP\build'
$csharpSource = Join-Path $repoRoot 'DDS_Nuget'
$cppSource = Join-Path $repoRoot 'DDSCPP'

if ($Clean) {
    foreach ($buildDirectory in @($csharpBuild, $cppBuild)) {
        Remove-BuildDirectory $buildDirectory
    }
}
else {
    Reset-IncompatibleCMakeCache $csharpBuild $csharpSource
    Reset-IncompatibleCMakeCache $cppBuild $cppSource
}

$csharpConfigure = @(
    '-S', $csharpSource,
    '-B', $csharpBuild,
    '-DDDS_GENERATE=ON',
    "-DDDS_DOTNET_CONFIGURATION=$Configuration",
    "-DDDS_SKIP_TESTS=$(if ($SkipTests) { 'ON' } else { 'OFF' })"
)

Write-Host ''
Write-Host 'Generating and building C# types...'
Invoke-Checked $cmake $csharpConfigure
Invoke-Checked $cmake @('--build', $csharpBuild, '--config', $Configuration)

$cppConfigure = @(
    '-S', $cppSource,
    '-B', $cppBuild,
    '-DDDSCPP_ENABLE_RTI=ON',
    "-DDDSCPP_RTI_HOME=$resolvedRtiHome",
    "-DDDSCPP_BUILD_TESTS=$(if ($SkipTests) { 'OFF' } else { 'ON' })"
)

Write-Host ''
Write-Host 'Generating and building C++ types...'
Invoke-Checked $cmake $cppConfigure
Invoke-Checked $cmake @('--build', $cppBuild, '--config', $Configuration)

if (-not $SkipTests) {
    $ctest = Find-CommandPath 'ctest'
    Invoke-Checked $ctest @('--test-dir', $cppBuild, '-C', $Configuration, '--output-on-failure')
}

Write-Host ''
Write-Host 'Build completed.'
Write-Host "  C# NuGet: $(Join-Path $repoRoot 'DDS_Nuget\artifacts\packages')"
Write-Host "  C++ build: $cppBuild"
}
finally {
    if ($windowsLock) { $windowsLock.Dispose() }
    Remove-Item -LiteralPath (Join-Path $repoRoot '.ddsclient-windows-build.lock') -Force -ErrorAction SilentlyContinue
}
