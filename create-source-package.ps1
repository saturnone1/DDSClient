[CmdletBinding()]
param([string] $OutputPath, [switch] $Force)

# Compatibility entry point; paths are resolved by the implementation.
& (Join-Path $PSScriptRoot 'tools\build\create-source-package.ps1') @PSBoundParameters
