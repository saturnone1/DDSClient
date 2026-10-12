[CmdletBinding()]
param(
    [ValidateSet('All','CSharp','Cpp')][string]$Language = 'All',
    [ValidateSet('All', 'Windows', 'Linux')]
    [string] $Target = 'Windows',
    [ValidateSet('9.7', '10.0')]
    [string] $RockyVersion = '9.7',
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',
    [string] $RtiHome,
    [string] $RtiPlatform,
    [switch] $Doctor,
    [switch] $InstallTools,
    [switch] $StartDocker,
    [switch] $Clean,
    [switch] $SkipTests,
    [switch] $WithCli,
    [switch] $WithTests,
    [switch] $Force,
    [switch] $IncludeRtiRuntime,
    [switch] $CreateSourcePackage
)

# Compatibility entry point; paths are resolved by the implementation.
& (Join-Path $PSScriptRoot 'tools\build\build.ps1') @PSBoundParameters
