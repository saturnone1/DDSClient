# Offline orchestration contract checks. No Docker engine, images, builds, or
# output directories are created: the Docker runner is exercised with stubs.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$runner = Join-Path $repoRoot 'tools\build\test-docker.ps1'
$fixtureLicense = $PSCommandPath

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

foreach ($pair in @(
    @('build.ps1', 'build.ps1'),
    @('build-all.ps1', 'build-windows.ps1'),
    @('build-linux.ps1', 'build-linux.ps1'),
    @('create-source-package.ps1', 'create-source-package.ps1'))) {
    $wrapper = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repoRoot $pair[0]), [ref]$null, [ref]$null)
    $implementation = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repoRoot "tools\build\$($pair[1])"), [ref]$null, [ref]$null)
    Assert-True (($wrapper.ParamBlock.Extent.Text -replace '\s', '') -ceq
        ($implementation.ParamBlock.Extent.Text -replace '\s', '')) "진입점 인수 불일치: $($pair[0])"
}

. (Join-Path $repoRoot 'tools\build\common.ps1')
Assert-True ([Console]::OutputEncoding.CodePage -eq 65001) '콘솔 출력은 UTF-8이어야 합니다.'
Assert-True ($OutputEncoding.CodePage -eq 65001) '하위 도구 입력은 UTF-8이어야 합니다.'
$korean = & python -c 'print("한글 출력 검증")'
Assert-True ($LASTEXITCODE -eq 0 -and $korean -ceq '한글 출력 검증') 'Python 한글 출력이 손상되었습니다.'
$utf8Props = [xml](Get-Content (Join-Path $repoRoot 'tools/build/utf8.props') -Raw)
Assert-True ($utf8Props.Project.ItemDefinitionGroup.CustomBuild.StdOutEncoding -eq 'utf-8') 'MSBuild UTF-8 출력 해석 설정이 필요합니다.'
$linuxBuild = Get-Content (Join-Path $repoRoot 'tools/build/build-linux.ps1') -Raw
Assert-True ($linuxBuild.Contains("'--entrypoint', 'bash', `$DockerImage, '/workspace/tools/docker/build-linux.sh'")) 'Linux 빌드는 소스의 한국어 스크립트를 실행해야 합니다.'
Assert-True ($linuxBuild.Contains('-VerifyOnly -UseSourceBuildScript -RockyVersions')) 'Linux 빌더 이미지 검증 경로가 실행 방식과 달라졌습니다.'
Invoke-Checked 'python' @((Join-Path $repoRoot 'tools/codegen/test_validate_dds.py'))
# A stopped Docker engine must be a failed probe, not a terminating stderr error.
function Invoke-StoppedDocker {
    Write-Error '엔진 중지'
    $global:LASTEXITCODE = 1
}
function Invoke-WindowsDocker { $global:LASTEXITCODE = 0; 'windows' }
function Invoke-LinuxDocker { $global:LASTEXITCODE = 0; 'linux' }
Assert-True (-not (Get-DockerEngineState 'Invoke-StoppedDocker').Ready) '중지된 Docker가 정상으로 판정되었습니다.'
Assert-True (-not (Get-DockerEngineState 'Invoke-WindowsDocker').Ready) 'Windows 컨테이너가 허용되었습니다.'
Assert-True ((Get-DockerEngineState 'Invoke-LinuxDocker').Ready) 'Linux 컨테이너가 거부되었습니다.'
$entry = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repoRoot 'build.ps1'), [ref]$null, [ref]$null)
$targetParameter = $entry.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Target' }
Assert-True ($targetParameter.DefaultValue.Value -eq 'Windows') '기본 빌드는 Docker를 요구하면 안 됩니다.'
Assert-True (@($entry.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'RockyVersion' }).Count -eq 1) 'Rocky 버전 선택이 없습니다.'
$savedRtiHome = $env:NDDSHOME
try {
    $env:NDDSHOME = 'C:\RTI candidate with spaces'
    $candidates = @(Get-RtiHomeCandidates 'C:\explicit RTI')
    Assert-True ($candidates[0] -eq 'C:\explicit RTI' -and $candidates[1] -eq $env:NDDSHOME) 'RTI 경로 우선순위가 변경되었습니다.'
    Assert-True (@(Get-RtiHomeCandidates ' ')[0] -eq ' ') '진단/Linux 공백 처리가 변경되었습니다.'
    Assert-True (@(Get-RtiHomeCandidates ' ' -SkipWhitespace)[0] -eq $env:NDDSHOME) 'Windows 공백 처리가 변경되었습니다.'
}
finally { $env:NDDSHOME = $savedRtiHome }

# These functions are visible to the runner's child scope. The script's normal
# Invoke-Checked still executes, including its native exit-code check.
function Get-Command {
    [CmdletBinding()]
    param([string] $Name)
    Assert-True ($Name -eq 'docker') "예상하지 않은 명령 탐색: $Name"
    return [pscustomobject]@{ Source = 'Invoke-FakeDocker' }
}

function New-Item {
    [CmdletBinding()]
    param([string] $Path, [string] $ItemType, [switch] $Force)
    Assert-True ($ItemType -eq 'Directory') '예상하지 않은 파일 작업입니다.'
    $resultDirectories.Add($Path)
}

function Invoke-FakeDocker {
    $dockerCalls.Add(@($args))
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'info') { return 'linux' }
    if (($failOperation -eq 'run' -and $args[0] -eq 'run') -or
        ($failOperation -eq 'network' -and $args[0] -eq 'network' -and $args[1] -eq 'create')) {
        $global:LASTEXITCODE = 7
    }
}

function Reset-DockerCalls {
    $script:dockerCalls = [System.Collections.Generic.List[object]]::new()
    $script:resultDirectories = [System.Collections.Generic.List[string]]::new()
    $script:failOperation = ''
}

Reset-DockerCalls
& $runner -LicenseFile $fixtureLicense -OutputDirectory 'artifacts\runner-contract-check'
$builds = @($dockerCalls | Where-Object { $_[0] -eq 'build' })
$runs = @($dockerCalls | Where-Object { $_[0] -eq 'run' })
$creates = @($dockerCalls | Where-Object { $_[0] -eq 'network' -and $_[1] -eq 'create' })
$removes = @($dockerCalls | Where-Object { $_[0] -eq 'network' -and $_[1] -eq 'rm' })
Assert-True ($builds.Count -eq 2 -and $runs.Count -eq 2 -and $creates.Count -eq 2 -and $removes.Count -eq 2) '기본 두 버전 모두 빌드·실행·정리를 수행해야 합니다.'
Assert-True ($creates[0][-1] -ne $creates[1][-1]) '버전별 격리 네트워크가 필요합니다.'
for ($i = 0; $i -lt 2; $i++) {
    Assert-True ($builds[$i][-1] -eq $repoRoot) 'Docker 빌드 기준은 저장소 루트여야 합니다.'
    Assert-True ($creates[$i] -contains '--internal' -and $creates[$i] -contains 'bridge') '테스트에는 내부 브리지가 필요합니다.'
    Assert-True ($runs[$i] -contains $creates[$i][-1] -and $removes[$i][-1] -eq $creates[$i][-1]) '네트워크 생성·삭제 대상 불일치.'
    Assert-True ($runs[$i] -contains "type=bind,source=$repoRoot,target=/workspace,readonly") '소스는 읽기 전용이어야 합니다.'
    Assert-True ($runs[$i] -contains "type=bind,source=$fixtureLicense,target=/run/rti-license.dat,readonly") '라이선스는 읽기 전용이어야 합니다.'
    Assert-True ($runs[$i] -contains 'RTI_LICENSE_FILE=/run/rti-license.dat') '라이선스 환경변수는 마운트 파일을 가리켜야 합니다.'
    Assert-True ($runs[$i][-1] -eq '/workspace/tools/docker/test-linux.sh') '현재 위치의 테스트 스크립트를 실행해야 합니다.'
}
Assert-True ($resultDirectories[0] -like '*\artifacts\runner-contract-check\rocky9.7\*' -and
    $resultDirectories[1] -like '*\artifacts\runner-contract-check\rocky10.0\*') '결과는 버전과 실행별로 분리되어야 합니다.'

Reset-DockerCalls
& $runner -RockyVersions 10.0 -LicenseFile $fixtureLicense -SkipImageBuild
Assert-True (@($dockerCalls | Where-Object { $_[0] -eq 'build' }).Count -eq 0) 'SkipImageBuild가 이미지를 재생성했습니다.'
Assert-True (@($dockerCalls | Where-Object { $_[0] -eq 'run' }).Count -eq 1) '단일 버전 선택 실패.'

foreach ($failure in @('run', 'network')) {
    Reset-DockerCalls
    $script:failOperation = $failure
    $caught = $false
    try { & $runner -RockyVersions 9.7 -LicenseFile $fixtureLicense -SkipImageBuild }
    catch { $caught = $_.Exception.Message -like '명령 실행 실패(종료 코드 7):*' }
    Assert-True $caught "Docker $failure 실패가 보고되지 않았습니다."
    $removes = @($dockerCalls | Where-Object { $_[0] -eq 'network' -and $_[1] -eq 'rm' })
    $expectedRemoves = if ($failure -eq 'run') { 1 } else { 0 }
    Assert-True ($removes.Count -eq $expectedRemoves) "$failure 실패 후 정리가 잘못되었습니다."
}
$global:LASTEXITCODE = 0
Write-Host '통과: UTF-8 출력, 진입점 인수, RTI 탐색, 버전별 Docker 실행, 읽기 전용 마운트, 이미지 재사용, 실패 정리.'
