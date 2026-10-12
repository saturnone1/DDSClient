# Failure injection only: all filesystem mutation commands are mocked.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$implementation = Join-Path $PSScriptRoot '../create-source-package.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($implementation, [ref]$null, [ref]$null)
$function = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Publish-FileSet'
}, $true)
. ([scriptblock]::Create($function.Extent.Text))
$outputDirectory = Join-Path $PSScriptRoot 'mock-output'
$destinations = @((Join-Path $outputDirectory 'package.zip'), (Join-Path $outputDirectory 'package.zip.sha256'))
function New-Item { param($ItemType, $Path) }
function Test-Path { param($LiteralPath) return $true }
function Move-Item {
    [CmdletBinding()] param($LiteralPath, $Destination)
    if ($failPublish -and $LiteralPath -eq 'new.sha256') { throw '의도적으로 발생시킨 배포 실패' }
    if ($LiteralPath -like '*.source-package-backup-*/*' -or $LiteralPath -like '*.source-package-backup-*\*') {
        if ($failRestore) { throw '의도적으로 발생시킨 복구 실패' }
        $restored.Add($Destination)
    }
}
function Remove-Item {
    [CmdletBinding()] param($LiteralPath, [switch]$Recurse, [switch]$Force)
    if ($Recurse) { $deletedBackups.Add($LiteralPath) }
}
foreach ($scenario in @('success', 'restored', 'retained')) {
    $failPublish = $scenario -ne 'success'
    $failRestore = $scenario -eq 'retained'
    $restored = [System.Collections.Generic.List[string]]::new()
    $deletedBackups = [System.Collections.Generic.List[string]]::new()
    $failed = $false
    try { Publish-FileSet @('new.zip', 'new.sha256') $destinations }
    catch {
        $failed = $true
        if ($_.Exception.Message -ne '의도적으로 발생시킨 배포 실패') { throw }
    }
    if ($failed -ne $failPublish) { throw "예상하지 않은 배포 결과: $scenario" }
    if ($scenario -eq 'restored' -and $restored.Count -ne 2) { throw '원본 두 개를 모두 복구하지 못했습니다' }
    if ($scenario -eq 'retained' -and $deletedBackups.Count -ne 0) { throw '미복구 백업을 삭제했습니다' }
    if ($scenario -ne 'retained' -and $deletedBackups.Count -ne 1) { throw '완료 후 불필요한 백업이 남았습니다' }
    Write-Host "통과: 소스 패키지 교체·복구 검증 ($scenario)"
}
