[CmdletBinding()]
param(
    [ValidateSet('All','CSharp','Cpp')][string]$Language = 'All',
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',

    [string] $RtiHome,

    [switch] $SkipTests,
    [switch] $WithCli,
    [switch] $WithTests,

    [switch] $Clean
)

# Compatibility entry point; paths are resolved by the implementation.
& (Join-Path $PSScriptRoot 'tools\build\build-windows.ps1') @PSBoundParameters
