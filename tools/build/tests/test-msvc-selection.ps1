$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../common.ps1')
$vs17 = [pscustomobject]@{ installationVersion='17.12.35527.113'; installationPath='C:/VS2022' }
$vs18 = [pscustomobject]@{ installationVersion='18.9.12105.275'; installationPath='C:/VS2026' }
foreach ($inputList in @(@($vs17), @($vs18), @($vs18,$vs17))) {
    $result = Get-MsvcBuildEnvironment -Installations $inputList
    $expected = if ($inputList.installationVersion -contains $vs17.installationVersion) { 'Visual Studio 17 2022' } else { 'Visual Studio 18 2026' }
    if ($result.Generator -ne $expected -or $result.Architecture -ne 'x64') { throw '설치된 MSVC 생성기 선택 오류' }
}
$failed = $false
try { Get-MsvcBuildEnvironment -Installations @() } catch { $failed = $true }
if (-not $failed) { throw 'MSVC가 없는 환경을 허용했습니다.' }
Write-Host 'VS2022 17.12·VS2026·동시 설치·미설치 환경의 생성기 선택 검증 통과.'
