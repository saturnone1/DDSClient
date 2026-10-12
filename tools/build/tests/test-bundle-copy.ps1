[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repo 'tools/build/create-release-bundles.ps1'), [ref]$null, [ref]$null)
$copy = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Copy-Tree' }, $true)
Invoke-Expression $copy.Extent.Text
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('dds-bundle-copy-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path (Join-Path $fixture 'input/bin'), (Join-Path $fixture 'input/obj') -Force | Out-Null
    Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $fixture 'input/bin/dds_cpp.dll')
    Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $fixture 'input/obj/cache')
    Copy-Tree (Join-Path $fixture 'input') (Join-Path $fixture 'deployment') -IncludeBin
    Copy-Tree (Join-Path $fixture 'input') (Join-Path $fixture 'source')
    if (-not (Test-Path (Join-Path $fixture 'deployment/bin/dds_cpp.dll'))) { throw '배포 DLL이 누락되었습니다.' }
    if (Test-Path (Join-Path $fixture 'source/bin')) { throw '소스에 빌드 결과가 포함되었습니다.' }
    if (Test-Path (Join-Path $fixture 'deployment/obj')) { throw '배포본에 중간 파일이 포함되었습니다.' }
    Write-Host '번들 배포 DLL 보존·소스 빌드 결과 제외 검증 통과.'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ($resolved.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $resolved -Leaf) -like 'dds-bundle-copy-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
