# PowerShell과 하위 도구가 같은 UTF-8 인코딩을 사용하도록 맞춥니다.
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'
$env:DOTNET_CLI_UI_LANGUAGE = 'ko-KR'
$env:VSLANG = '1042'

function Get-DockerEngineState {
    param([Parameter(Mandatory)] [string] $FilePath)
    # 엔진 탐색 실패는 스크립트를 중단하는 예외가 아니라 진단 결과로 취급한다.
    # PowerShell 버전에 따라 네이티브 표준 오류가 예외로 해석될 수 있으므로 명시적으로 처리한다.
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $output = @(& $FilePath info --format '{{.OSType}}' 2>&1)
    $code = $LASTEXITCODE
    $ready = $code -eq 0 -and ($output -join '').Trim() -eq 'linux'
    return [pscustomobject]@{
        Ready = $ready
        Detail = $(if ($ready) { 'Linux 컨테이너 엔진이 실행 중입니다.' }
            else { 'Docker Linux 엔진을 사용할 수 없습니다. Docker Desktop을 Linux 컨테이너 모드로 실행하세요.' })
    }
}

function Get-MsvcBuildEnvironment {
    param([object[]]$Installations)
    if (-not $PSBoundParameters.ContainsKey('Installations')) {
        $locator = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
        if (Test-Path -LiteralPath $locator) {
            # IDE뿐 아니라 단독 C++ Build Tools 제품도 탐색한다.
            $json = & $locator -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json -utf8
            if ($LASTEXITCODE -ne 0) { throw 'C++ 도구 설치 탐색에 실패했습니다.' }
            $Installations = @($json | ConvertFrom-Json)
        } else {
            $Installations = @()
        }
    }
    $supported = @($Installations | Where-Object { ([version]$_.installationVersion).Major -in @(17,18) } |
        Sort-Object @{ Expression = { if (([version]$_.installationVersion).Major -eq 17) { 0 } else { 1 } } },
                    @{ Expression = { [version]$_.installationVersion }; Descending = $true })
    if (-not $supported.Count) {
        # 수동 MSVC 환경에서도 IDE 없이 Ninja로 빌드할 수 있다.
        $compiler = Get-Command cl.exe -ErrorAction SilentlyContinue
        $ninja = Get-Command ninja.exe -ErrorAction SilentlyContinue
        if ($compiler -and $ninja -and $env:INCLUDE -and $env:LIB -and $env:VSCMD_ARG_TGT_ARCH -eq 'x64') {
            return [pscustomobject]@{ Generator='Ninja'; Instance=''; Architecture='x64'; Version='PATH MSVC'; IsVisualStudioGenerator=$false }
        }
        throw 'C++ 빌드에는 VS2022 C++ 도구 또는 단독 C++ Build Tools와 Windows SDK가 필요합니다. IDE는 필수가 아닙니다. 컴파일러가 없으면 -Language CSharp를 사용하세요.'
    }
    $selected = $supported[0]
    $major = ([version]$selected.installationVersion).Major
    [pscustomobject]@{
        Generator = $(if ($major -eq 17) { 'Visual Studio 17 2022' } else { 'Visual Studio 18 2026' })
        Instance = $selected.installationPath
        Architecture = 'x64'
        Version = $selected.installationVersion
        IsVisualStudioGenerator = $true
    }
}

function Get-RtiHomeCandidates {
    param([string] $RequestedHome, [switch] $SkipWhitespace)

    # 명시적 경로·환경변수·기본 설치 순서와 기존 중복 후보를 유지한다.
    # Windows 빌드는 공백 경로를 건너뛰며 기존 진단·Linux 경로 규칙은 유지한다.
    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @($RequestedHome, $env:NDDSHOME)) {
        if ($candidate -and (-not $SkipWhitespace -or -not [string]::IsNullOrWhiteSpace($candidate))) {
            $candidates.Add($candidate)
        }
    }
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    if ($programFiles -and (-not $SkipWhitespace -or -not [string]::IsNullOrWhiteSpace($programFiles))) {
        Get-ChildItem -LiteralPath $programFiles -Directory -Filter 'rti_connext_dds-*' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { $candidates.Add($_.FullName) }
    }
    return $candidates.ToArray()
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [string[]] $Arguments
    )

    Write-Host "> $FilePath $($Arguments -join ' ')"
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "명령 실행 실패(종료 코드 ${LASTEXITCODE}): $FilePath"
    }
}
