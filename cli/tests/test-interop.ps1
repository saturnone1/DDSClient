param(
    [Parameter(Mandatory = $true)] [string] $CppCli,
    [Parameter(Mandatory = $true)] [string] $Dotnet,
    [Parameter(Mandatory = $true)] [string] $CSharpProject,
    [Parameter(Mandatory = $true)] [string] $Definitions
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../tools/build/common.ps1')

function Quote-Argument([string] $Value) {
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Assert-Received([string] $Text, [string] $Direction) {
    foreach ($expected in @('TimeTickInformation', 'TCC', 'TDS')) {
        if ($Text -notmatch [regex]::Escape($expected)) {
            throw "$Direction 수신 결과에 예상 값 '$expected'이(가) 없습니다."
        }
    }
}

function Start-Subscriber(
    [string] $Kind,
    [string] $CSharpCli,
    [string] $OutputPath,
    [string] $ErrorPath
) {
    $common = "subscribe TimeTickInformation --qos $(Quote-Argument (Join-Path $Definitions 'qos_profiles.xml')) --count 4 --timeout-ms 20000"
    if ($Kind -eq 'csharp') {
        return Start-Process -FilePath $Dotnet `
            -ArgumentList "$(Quote-Argument $CSharpCli) $common" `
            -RedirectStandardOutput $OutputPath `
            -RedirectStandardError $ErrorPath `
            -WindowStyle Hidden `
            -PassThru
    }

    return Start-Process -FilePath $CppCli `
        -ArgumentList $common `
        -RedirectStandardOutput $OutputPath `
        -RedirectStandardError $ErrorPath `
        -WindowStyle Hidden `
        -PassThru
}

function Invoke-Publisher([string] $Kind, [string] $CSharpCli) {
    if ($Kind -eq 'csharp') {
        & $Dotnet $CSharpCli publish TimeTickInformation --qos (Join-Path $Definitions 'qos_profiles.xml') --repeat 4 --wait-for-subscribers 3 --wait-for-acks --wait-timeout-ms 10000
    }
    else {
        & $CppCli publish TimeTickInformation --qos (Join-Path $Definitions 'qos_profiles.xml') --repeat 4 --wait-for-subscribers 3 --wait-for-acks --wait-timeout-ms 10000
    }

    if ($LASTEXITCODE -ne 0) {
        throw "$Kind 송신기가 종료 코드 $LASTEXITCODE 로 실패했습니다."
    }
}

function Invoke-Direction(
    [int] $Domain,
    [string] $Subscriber,
    [string] $Publisher,
    [string] $CSharpCli,
    [string] $TempDirectory
) {
    $env:DDS_DOMAIN_ID = [string] $Domain
    $name = "$Subscriber-from-$Publisher"
    $processes = @()
    try {
        foreach ($index in 1..3) {
            $processes += Start-Subscriber $Subscriber $CSharpCli `
                (Join-Path $TempDirectory "$name-$index.out.txt") `
                (Join-Path $TempDirectory "$name-$index.err.txt")
        }
        # No startup sleep: discovery must gate this four-sample burst.
        Invoke-Publisher $Publisher $CSharpCli
        foreach ($index in 1..3) {
            $process = $processes[$index - 1]
            if (-not $process.WaitForExit(25000)) { throw "$name 수신기 $index 의 대기 시간이 초과되었습니다." }
            $process.WaitForExit()
            $output = Get-Content -LiteralPath (Join-Path $TempDirectory "$name-$index.out.txt") -Raw
            $errors = Get-Content -LiteralPath (Join-Path $TempDirectory "$name-$index.err.txt") -Raw -ErrorAction SilentlyContinue
            if ($process.ExitCode -ne 0) {
                throw "$name 수신기 $index 가 종료 코드 $($process.ExitCode)로 실패했습니다.`n$output`n$errors"
            }
            Assert-Received $output $name
            $pattern = if ($Subscriber -eq 'csharp') { '(?m)^\[.*\] TimeTickInformation\r?$' } else { '(?m)^TimeTickInformation\r?$' }
            $received = [regex]::Matches($output, $pattern).Count
            if ($received -ne 4) { throw "$name 수신기 $index 가 메시지 $received 개를 받았습니다. 예상 건수는 4개입니다." }
        }
        Write-Host "통과: $name, 도메인 $Domain, 수신기 3개 × 메시지 4개"
    }
    finally {
        foreach ($process in $processes) {
            if (-not $process.HasExited) { $process.Kill() }
            $process.Dispose()
        }
    }
}

foreach ($path in @($CppCli, $Dotnet, $CSharpProject, $Definitions)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "필수 상호운용 테스트 입력이 없습니다: $path"
    }
}

& $Dotnet build $CSharpProject -c Release --nologo
if ($LASTEXITCODE -ne 0) {
    throw "C# CLI 빌드가 종료 코드 $LASTEXITCODE 로 실패했습니다."
}

$targetPathOutput = & $Dotnet msbuild $CSharpProject -nologo -property:Configuration=Release -getProperty:TargetPath
if ($LASTEXITCODE -ne 0) {
    throw "C# CLI TargetPath 조회가 종료 코드 $LASTEXITCODE 로 실패했습니다."
}
$csharpCli = ($targetPathOutput -join [Environment]::NewLine).Trim()
if (-not $csharpCli -or -not (Test-Path -LiteralPath $csharpCli -PathType Leaf)) {
    throw "TargetPath에 빌드된 C# CLI가 없습니다: $csharpCli"
}
Write-Host "테스트할 C# CLI: $csharpCli"
Write-Host "테스트할 C++ CLI: $CppCli"

$tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ("dds-interop-" + [System.Guid]::NewGuid())
$previousDomain = $env:DDS_DOMAIN_ID
New-Item -ItemType Directory -Path $tempDirectory | Out-Null

try {
    # Windows의 한글 인수·환경변수·파일 경로를 실제 CLI로 검증합니다.
    $unicodeDirectory = Join-Path $tempDirectory '한글 경로'
    New-Item -ItemType Directory -Path $unicodeDirectory | Out-Null
    $unicodeQos = Join-Path $unicodeDirectory '통신 설정.xml'
    Copy-Item -LiteralPath (Join-Path $Definitions 'qos_profiles.xml') -Destination $unicodeQos
    $unicodeJson = Join-Path $unicodeDirectory '한글 메시지.json'
    Set-Content -LiteralPath $unicodeJson -Value '{}' -Encoding utf8
    foreach ($kind in @('csharp', 'cpp')) {
        [string[]]$cliPrefix = @()
        if ($kind -eq 'csharp') { $cliPrefix = @($csharpCli) }
        $executable = if ($kind -eq 'csharp') { $Dotnet } else { $CppCli }
        $failure = @(& $executable @cliPrefix publish --없는옵션 2>&1)
        if ($LASTEXITCODE -eq 0 -or ($failure -join "`n") -notmatch '--없는옵션') {
            throw "$kind 한글 인수가 보존되지 않았습니다: $failure"
        }
        $result = @(& $executable @cliPrefix list --qos $unicodeQos 2>&1)
        if ($LASTEXITCODE -ne 0 -or ($result -join "`n") -notmatch 'TimeTickInformation') {
            throw "$kind 한글 QoS 경로를 읽지 못했습니다: $result"
        }
        $previousQos = $env:DDS_QOS_PROFILES_XML_PATH
        try {
            $env:DDS_QOS_PROFILES_XML_PATH = $unicodeQos
            $result = @(& $executable @cliPrefix list 2>&1)
            if ($LASTEXITCODE -ne 0) { throw "$kind 한글 환경변수 경로를 읽지 못했습니다: $result" }
        } finally { $env:DDS_QOS_PROFILES_XML_PATH = $previousQos }
        $previousSimulator = $env:DDS_CLI_SRC_SIM_ID
        try {
            $env:DDS_CLI_SRC_SIM_ID = '잘못된값'
            $result = @(& $executable @cliPrefix publish TimeTickInformation --qos $unicodeQos 2>&1)
            if ($LASTEXITCODE -eq 0 -or ($result -join "`n") -notmatch '잘못된값') {
                throw "$kind 한글 환경변수 값이 보존되지 않았습니다: $result"
            }
        } finally { $env:DDS_CLI_SRC_SIM_ID = $previousSimulator }
        $result = @(& $executable @cliPrefix publish TimeTickInformation --qos $unicodeQos --json $unicodeJson --participant '한글 참여자' --wait-for-subscribers 2147483647 --wait-timeout-ms 100 2>&1)
        if ($LASTEXITCODE -eq 0 -or ($result -join "`n") -notmatch '구독자 연결 대기 시간이 초과되었습니다') {
            throw "$kind 한글 JSON 경로·참여자 설정을 처리하지 못했습니다: $result"
        }
        Write-Host "통과: $kind 한글 인수·환경변수·QoS/JSON 파일 경로·참여자"
    }
    foreach ($kind in @('csharp', 'cpp')) {
        $arguments = @('publish', 'TimeTickInformation', '--domain', '76',
            '--qos', (Join-Path $Definitions 'qos_profiles.xml'),
            '--wait-for-subscribers', '2147483647', '--wait-timeout-ms', '100')
        $failure = if ($kind -eq 'csharp') { & $Dotnet $csharpCli @arguments 2>&1 } else { & $CppCli @arguments 2>&1 }
        $code = $LASTEXITCODE
        $text = $failure -join "`n"
        if ($code -eq 0 -or $text -notmatch '구독자 연결 대기 시간이 초과되었습니다' -or $text -match 'DDS ACK 확인 완료') {
            throw "$kind 수신기 부재 테스트가 예상대로 실패하지 않았습니다: $text"
        }
        Write-Host "통과: $kind 수신기 부재 시 시간 초과, 성공으로 오인하지 않음"
    }
    $baseDomain = 80 + ([System.Diagnostics.Process]::GetCurrentProcess().Id % 40)
    Invoke-Direction $baseDomain 'csharp' 'cpp' $csharpCli $tempDirectory
    Invoke-Direction ($baseDomain + 1) 'cpp' 'csharp' $csharpCli $tempDirectory

    # XML에 유니캐스트 Discovery를 설정하고 QoS 파일만으로 반복합니다.
    # 이 실행 설정 폴더에는 DDSSim.xml이 없습니다.
    $unicastDefinitions = Join-Path $tempDirectory 'unicast'
    New-Item -ItemType Directory -Path $unicastDefinitions | Out-Null
    [xml] $qos = Get-Content -LiteralPath (Join-Path $Definitions 'qos_profiles.xml') -Raw
    $discovery = $qos.SelectSingleNode('//qos_profile[@name="ReliableRealtime"]/domain_participant_qos/discovery')
    $peers = $discovery.SelectSingleNode('initial_peers')
    $peers.RemoveAll()
    $peer = $qos.CreateElement('element')
    $peer.InnerText = 'builtin.udpv4://127.0.0.1'
    [void] $peers.AppendChild($peer)
    [void] $discovery.AppendChild($qos.CreateElement('multicast_receive_addresses'))
    $qos.Save((Join-Path $unicastDefinitions 'qos_profiles.xml'))
    $Definitions = $unicastDefinitions
    Invoke-Direction ($baseDomain + 2) 'csharp' 'cpp' $csharpCli $tempDirectory
    Invoke-Direction ($baseDomain + 3) 'cpp' 'csharp' $csharpCli $tempDirectory
}
finally {
    $env:DDS_DOMAIN_ID = $previousDomain
    Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
