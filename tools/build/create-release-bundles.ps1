[CmdletBinding()]
param(
    [ValidateSet('DDSClient','SignalForge','All')][string]$Target = 'All',
    [Parameter(Mandatory)][string]$SourceArchive,
    [string]$WindowsCpp,
    [string]$Rocky9Archive,
    [string]$Rocky10Archive,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$SignalForgeRoot = (Join-Path $PSScriptRoot '../../../Signal-Forge'),
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_./:-]*$')]
    [string]$SignalForgeImage,
    [string]$SignalForgeImageArchive,
    [string]$SignalForgePublished,
    [switch]$KeepStaging
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Add-Type -AssemblyName System.IO.Compression.FileSystem
$includeDds = $Target -in @('DDSClient','All')
$includeSf = $Target -in @('SignalForge','All')
if ($includeSf) {
    $SignalForgeRoot = (Resolve-Path -LiteralPath $SignalForgeRoot).Path
    if (-not $SignalForgeImage) { throw 'Signal Forge 번들은 최신 빌드의 -SignalForgeImage를 명시하세요.' }
}
if ($includeDds -and -not ($WindowsCpp -or $Rocky9Archive -or $Rocky10Archive)) { throw '선택한 플랫폼의 C++ 배포본을 하나 이상 지정하세요.' }
$inputs = @($SourceArchive)
if ($includeDds) { $inputs += @($WindowsCpp,$Rocky9Archive,$Rocky10Archive) | Where-Object { $_ } }
foreach ($inputPath in $inputs) {
    if (-not (Test-Path -LiteralPath $inputPath)) { throw "입력 파일 또는 폴더가 없습니다: $inputPath" }
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw '새 출력 폴더를 지정하세요. 기존 배포본은 덮어쓰지 않습니다.' }
New-Item -ItemType Directory -Path $output | Out-Null
$stage = Join-Path $output 'contents'
$dds = Join-Path $stage 'DDSClient-Bundle'
$sf = Join-Path $stage 'SignalForge-Bundle'
$bundleRoots = @()
if ($includeDds) { $bundleRoots += $dds }
if ($includeSf) { $bundleRoots += $sf }
foreach ($root in $bundleRoots) {
    New-Item -ItemType Directory -Path (Join-Path $root 'source'), (Join-Path $root 'deployment') -Force | Out-Null
    Copy-Item -LiteralPath $SourceArchive -Destination (Join-Path $root 'source/DDSClient-source.zip')
}
function Copy-Tree([string]$From, [string]$To, [switch]$IncludeBin) {
    $excludedDirectories = @('.git', '.vs', 'obj', 'artifacts')
    if (-not $IncludeBin) { $excludedDirectories += 'bin' }
    & robocopy.exe $From $To /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XD @excludedDirectories /XF '*.dat' '*.pfx' '*.pem' '*.key' | Out-Null
    if ($LASTEXITCODE -gt 7) { throw "복사 실패: $From" }
    $global:LASTEXITCODE = 0
}
if ($includeDds) {
    if ($WindowsCpp) {
        Copy-Tree $WindowsCpp (Join-Path $dds 'deployment/windows-cpp') -IncludeBin
        $installed = Join-Path $dds 'deployment/windows-cpp'
        if (-not ((Test-Path (Join-Path $installed 'bin/dds_cpp.dll')) -or
                  (Test-Path (Join-Path $installed 'lib/dds_cpp_static.lib')))) { throw 'Windows 코어 라이브러리가 없습니다.' }
    }
    foreach ($archive in @($Rocky9Archive,$Rocky10Archive) | Where-Object { $_ }) {
        Copy-Item -LiteralPath $archive -Destination (Join-Path $dds 'deployment')
    }
    $feed = Join-Path $dds 'deployment/nuget-feed'
    New-Item -ItemType Directory -Path $feed | Out-Null
    # 입력 소스 ZIP 자체의 모듈을 사용한다.
    $moduleNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $sourceReader = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $SourceArchive).Path)
    try {
        foreach ($entry in $sourceReader.Entries) {
            if ($entry.FullName -notmatch '^DDSClient/definitions/([A-Za-z][A-Za-z0-9_]*)\.xml$') { continue }
            $module = $Matches[1]
            $stream = $entry.Open()
            try { $xml = [System.Xml.Linq.XDocument]::Load($stream) } finally { $stream.Dispose() }
            if (-not @($xml.Root.Elements() | Where-Object { $_.Name.LocalName -eq 'types' }).Count) { continue }
            if (-not $moduleNames.Add($module)) { throw "소스 ZIP에 중복 모듈이 있습니다: $module" }
        }
    } finally { $sourceReader.Dispose() }
    $packages = @('DdsAmbassador.DDSClient.Core') + @($moduleNames | Sort-Object | ForEach-Object { "DdsAmbassador.Messages.$_" })
    foreach ($package in $packages) {
        $files = @(Get-ChildItem (Join-Path $repo 'DDS_Nuget/artifacts/packages') -Filter "$package.*.nupkg" -File)
        if (-not $files.Count) { throw "패키지가 없습니다: $package" }
        $files | Copy-Item -Destination $feed
    }
    foreach ($folder in @('offline-tools/nuget/rti','offline-tools/nuget/third-party')) {
        Get-ChildItem (Join-Path $repo $folder) -Filter '*.nupkg' -File | Copy-Item -Destination $feed
    }
}
if ($includeSf) {
$source = Join-Path $sf 'source/Signal-Forge'
New-Item -ItemType Directory -Path $source | Out-Null
foreach ($name in @('ASAP.csproj', 'ASAP.sln', 'Program.cs', 'appsettings.json', 'nuget.config', 'Dockerfile',
                    'Dockerfile.dockerignore', '.dockerignore', 'README.md', 'validate-docker-package-allowlist.ps1')) {
    Copy-Item -LiteralPath (Join-Path $SignalForgeRoot $name) -Destination $source
}
foreach ($name in @('src', 'wwwroot', 'samples', 'eng', 'tests', 'packages', 'deploy')) {
    Copy-Tree (Join-Path $SignalForgeRoot $name) (Join-Path $source $name)
}
Copy-Tree (Join-Path $SignalForgeRoot 'rti/nupkg') (Join-Path $source 'rti/nupkg')
Copy-Tree (Join-Path $SignalForgeRoot 'deploy') (Join-Path $sf 'deployment')
Copy-Item -LiteralPath (Join-Path $SignalForgeRoot 'deploy/README.txt') -Destination (Join-Path $sf 'README.txt')
if ($SignalForgePublished) {
    if (-not (Test-Path -LiteralPath (Join-Path $SignalForgePublished 'ASAP.dll'))) { throw 'Signal Forge publish 결과가 없습니다.' }
    Copy-Tree $SignalForgePublished (Join-Path $sf 'deployment/published') -IncludeBin
    $notes = @'

추가 배포본: deployment/published는 최신 소스의 프레임워크 의존 publish 결과입니다.
.NET 9 ASP.NET Core 실행 환경과 RTI 라이선스를 별도로 준비하고 dotnet ASAP.dll로 실행할 수 있습니다.
Docker 기본 구성은 앱 하나입니다. 테스트 또는 앱 실행은 번들 생성 과정에서 수행하지 않습니다.
'@
    Add-Content -LiteralPath (Join-Path $sf 'README.txt') -Value $notes -Encoding utf8
}
if ($SignalForgeImageArchive) {
    $notes = @'

이미지 준비 방식: 보관된 .NET SDK/ASP.NET Linux x64 기반 이미지와 최신 publish 결과로 구성했습니다.
Docker 엔진이 중지되어 Docker load 및 컨테이너 실행은 검증하지 않았습니다.
기반 이미지의 .NET 버전은 보관본 버전이며, 최신 패치 수준으로 갱신한 이미지는 아닙니다.
'@
    Add-Content -LiteralPath (Join-Path $sf 'README.txt') -Value $notes -Encoding utf8
}
$baseImages = [Collections.Generic.List[string]]::new()
$stages = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$dockerfile = Get-Content -LiteralPath (Join-Path $SignalForgeRoot 'Dockerfile') -Raw
foreach ($match in [regex]::Matches($dockerfile, '^FROM(?:\s+--platform=\S+)?\s+(\S+)(?:\s+AS\s+(\S+))?', 'IgnoreCase,Multiline')) {
    $image = $match.Groups[1].Value
    if (-not $stages.Contains($image)) {
        if ($image.Contains('$')) { throw '기반 이미지 변수를 실제 태그로 지정한 Dockerfile이 필요합니다.' }
        $baseImages.Add($image)
    }
    if ($match.Groups[2].Success) { [void]$stages.Add($match.Groups[2].Value) }
}
$images = @($SignalForgeImage) + @($baseImages | Select-Object -Unique)
if ($SignalForgeImageArchive) {
    if (-not (Test-Path -LiteralPath $SignalForgeImageArchive -PathType Leaf)) { throw '사전 준비한 Docker 이미지 파일이 없습니다.' }
    Copy-Item -LiteralPath $SignalForgeImageArchive -Destination (Join-Path $sf 'deployment/signal-forge-images.tar')
} else {
    & docker image inspect @images | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '선택한 앱과 Dockerfile 기반 이미지가 로컬에 있어야 합니다.' }
    & docker save -o (Join-Path $sf 'deployment/signal-forge-images.tar') @images
    if ($LASTEXITCODE -ne 0) { throw 'Docker 이미지 내보내기에 실패했습니다.' }
}
foreach ($composePath in @((Join-Path $sf 'deployment/compose.yaml'), (Join-Path $source 'deploy/compose.yaml'))) {
    $compose = Get-Content -LiteralPath $composePath -Raw
    $pattern = '\$\{SIGNAL_FORGE_IMAGE:-[^}]+\}'
    if (-not [regex]::IsMatch($compose,$pattern)) { throw '배포 이미지 변수 기본값이 필요합니다.' }
    $updated = [regex]::Replace($compose,$pattern,[Text.RegularExpressions.MatchEvaluator]{
        param($match) '${SIGNAL_FORGE_IMAGE:-' + $SignalForgeImage + '}'
    })
    Set-Content -LiteralPath $composePath -Encoding utf8 -Value $updated
}
}
if ($includeDds) {
$readme = @'
DDSClient 소스·배포 번들

1. source/DDSClient-source.zip을 source/ 아래에 풉니다.
2. DDSClient/docs/build.md를 읽고 PowerShell 7에서 build.ps1 -Doctor를 실행합니다.
3. Windows는 build.ps1, Linux는 build.ps1 -Target Linux -RockyVersion 9.7 또는 10.0으로 빌드합니다.

포함 항목
- 소스: 코드·메시지 생성물·CLI·테스트·스크립트·오프라인 설치 파일·Rocky 빌더 이미지
- deployment/nuget-feed: 코어·메시지 모듈·의존 패키지. 앱의 NuGet 저장소로 등록하세요.
- deployment/windows-cpp: 선택한 Windows C++ 배포본(지정한 경우에만 포함)
- deployment/*.tar.gz: 선택한 Linux C++ 배포본(지정한 플랫폼만 포함)

별도 준비: RTI SDK·라이선스, Visual Studio C++ 개발 도구, Docker/WSL, 필요한 .NET 실행 환경.
이 설치본과 라이선스 키는 번들에 포함하지 않습니다. RTI 재배포 권한은 별도로 확인하세요.
앱은 이 배포본과 맞는 헤더·코어·모듈로 빌드하세요.

Git 기록·운영 데이터·라이선스 파일은 제외합니다. 커밋 전 변경을 포함한 현재 소스로 만듭니다.
반입 후 내부 CONTENTS.sha256과 ZIP 옆의 .sha256을 확인하세요.
'@
Set-Content -LiteralPath (Join-Path $dds 'README.txt') -Value $readme -Encoding utf8
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($root in $bundleRoots) {
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File)
    $forbidden = $files | Where-Object { $_.Name -match '(^rti_license|\.(dat|pfx|pem|key)$)' -or $_.FullName -match '[\\/](data-protection-keys|\.git)[\\/]' }
    if ($forbidden) { throw "번들에 포함할 수 없는 파일: $($forbidden.FullName -join ', ')" }
    $hashes = foreach ($file in $files | Sort-Object FullName) {
        $relative = [IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')
        '{0}  {1}' -f (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash, $relative
    }
    Set-Content -LiteralPath (Join-Path $root 'CONTENTS.sha256') -Value $hashes -Encoding ascii
    $name = Split-Path $root -Leaf
    $archive = Join-Path $output "$name.zip"
    [IO.Compression.ZipFile]::CreateFromDirectory($root, $archive, [IO.Compression.CompressionLevel]::Optimal, $true)
    $reader = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        foreach ($required in @("$name/README.txt", "$name/CONTENTS.sha256", "$name/source/DDSClient-source.zip")) {
            if (-not $reader.GetEntry($required)) { throw "압축 파일에 항목이 없습니다: $required" }
        }
        if (@($reader.Entries | Where-Object Name).Count -ne $files.Count + 1) { throw '압축 파일의 항목 수가 준비한 파일 수와 다릅니다.' }
        foreach ($line in $hashes) {
            $expected, $relative = $line -split '  ', 2
            $entry = $reader.GetEntry("$name/$relative")
            if (-not $entry) { throw "압축 파일에 항목이 없습니다: $relative" }
            $stream = $entry.Open()
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $actual = [Convert]::ToHexString($sha.ComputeHash($stream)) }
            finally { $sha.Dispose(); $stream.Dispose() }
            if ($actual -ne $expected) { throw "압축 항목의 체크섬이 다릅니다: $relative" }
        }
    } finally { $reader.Dispose() }
    Set-Content -LiteralPath "$archive.sha256" -Encoding ascii -Value ('{0}  {1}' -f (Get-FileHash -LiteralPath $archive).Hash, "$name.zip")
    Write-Output "번들 생성 완료: $archive"
}
# 새로 만든 임시 복사본만 제거합니다. 검사 실패 시에는 증거로 남깁니다.
if (-not $KeepStaging) {
    $stagePath = [IO.Path]::GetFullPath($stage)
    if ($stagePath -ne (Join-Path $output 'contents') -or -not $stagePath.StartsWith($output + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw '임시 폴더가 지정한 출력 폴더 안에 있지 않습니다.'
    }
    Remove-Item -LiteralPath $stagePath -Recurse -Force
    Write-Host '검증을 마친 임시 복사본을 정리했습니다. ZIP과 체크섬은 보관합니다.'
}
