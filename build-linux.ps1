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

# Compatibility entry point; paths are resolved by the implementation.
& (Join-Path $PSScriptRoot 'tools\build\build-linux.ps1') @PSBoundParameters
