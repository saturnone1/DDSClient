[CmdletBinding()]
param([string] $OutputPath, [switch] $Force)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $repoRoot 'artifacts\DDSClient-Source-Build-windows-x64.zip'
}
elseif (-not [System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath = Join-Path $repoRoot $OutputPath }
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
if ([System.IO.Path]::GetExtension($OutputPath) -ne '.zip') { throw 'OutputPath의 확장자는 .zip이어야 합니다.' }
$checksumPath = "$OutputPath.sha256"
$outputDirectory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

function Publish-FileSet {
    param([string[]] $Sources, [string[]] $Destinations)
    $backupDirectory = Join-Path $outputDirectory ('.source-package-backup-' + [guid]::NewGuid().ToString('N'))
    $published = [System.Collections.Generic.List[string]]::new()
    $backedUp = [System.Collections.Generic.List[object]]::new()
    $preserveBackup = $false
    New-Item -ItemType Directory -Path $backupDirectory | Out-Null
    try {
        for ($index = 0; $index -lt $Destinations.Count; $index++) {
            if (Test-Path -LiteralPath $Destinations[$index]) {
                $backup = Join-Path $backupDirectory ([System.IO.Path]::GetFileName($Destinations[$index]))
                Move-Item -LiteralPath $Destinations[$index] -Destination $backup
                $backedUp.Add([pscustomobject]@{ Source = $backup; Destination = $Destinations[$index] })
            }
        }
        for ($index = 0; $index -lt $Sources.Count; $index++) {
            Move-Item -LiteralPath $Sources[$index] -Destination $Destinations[$index]
            $published.Add($Destinations[$index])
        }
    }
    catch {
        foreach ($path in $published) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        foreach ($item in $backedUp) {
            if (Test-Path -LiteralPath $item.Source) {
                try { Move-Item -LiteralPath $item.Source -Destination $item.Destination -ErrorAction Stop }
                catch {
                    $preserveBackup = $true
                    Write-Warning "패키지 복구에 실패했습니다. 다음 위치에서 원본을 복구하세요: $($item.Source)"
                }
            }
        }
        throw
    }
    finally {
        if (-not $preserveBackup) { Remove-Item -LiteralPath $backupDirectory -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

& (Join-Path $repoRoot 'offline-tools\windows-x64\install-tools.ps1') -VerifyOnly
& (Join-Path $repoRoot 'offline-tools\linux-x64\update-builder-image.ps1') -VerifyOnly -UseSourceBuildScript

$lockStream = $null
$lockPath = Join-Path $outputDirectory '.ddsclient-source-package.lock'
$stagingRoot = $null
$temporaryArchive = Join-Path $outputDirectory ('.DDSClient-source-' + [guid]::NewGuid().ToString('N') + '.zip')
$temporaryChecksum = "$temporaryArchive.sha256"
try {
    try {
        $lockStream = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    }
    catch { throw "${outputDirectory}에서 다른 소스 패키지 작업이 실행 중입니다." }
    $existing = @($OutputPath, $checksumPath) | Where-Object { Test-Path -LiteralPath $_ }
    if ($existing -and -not $Force) { throw "출력 파일이 이미 있습니다: $($existing -join ', '). 검증 후 교체하려면 -Force를 지정하세요." }

    $stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('DDSClient-source-package-' + [guid]::NewGuid().ToString('N'))
    $packageRoot = Join-Path $stagingRoot 'DDSClient'
    New-Item -ItemType Directory -Path $packageRoot | Out-Null

    $rootFiles = @('.dockerignore', 'README.md', 'THIRD-PARTY-NOTICES.md',
        'build-all.ps1', 'build-linux.ps1', 'build.ps1', 'create-source-package.ps1', 'global.json')
    foreach ($file in $rootFiles) { Copy-Item -LiteralPath (Join-Path $repoRoot $file) -Destination $packageRoot }

    foreach ($directory in @('docs', 'definitions', 'cli', 'tools', 'DDS_Nuget', 'DDSCPP', 'offline-tools')) {
        $source = Join-Path $repoRoot $directory
        $destination = Join-Path $packageRoot $directory
        New-Item -ItemType Directory -Path $destination | Out-Null
        # tools/build는 빌드 결과가 아니라 관리하는 스크립트 소스다.
        $excludedDirectories = @('.git', '.vs', '__pycache__', 'bin', 'obj', 'artifacts', '.generation-*', '.generated-backup-*')
        if ($directory -ne 'tools') { $excludedDirectories += @('build', 'build-*') }
        & robocopy.exe $source $destination /E /R:2 /W:1 /NFL /NDL /NJH /NJS /NP /XD @excludedDirectories /XF '*.dat' '*.pfx' '*.pem' '*.key' '.git' '*.lock' | Out-Null
        if ($LASTEXITCODE -gt 7) { throw "$directory 복사 실패(robocopy 종료 코드 $LASTEXITCODE)." }
        # robocopy는 파일 복사 성공도 1 같은 0이 아닌 종료 코드로 보고한다.
        # 마지막 네이티브 명령의 종료 코드는 호출자 스크립트에도 영향을 준다.
        # 성공한 패키지 작업을 실패로 보고하지 않도록 종료 코드를 정상화한다.
        $global:LASTEXITCODE = 0
    }

    $manifest = @(
        'DDSClient 폐쇄망 소스 빌드 패키지',
        "생성 시각: $([DateTimeOffset]::Now.ToString('o'))",
        '빌드 호스트: Windows x64',
        '빌드 대상: Windows x64, Rocky Linux 9.7 x64, Rocky Linux 10.0 x64',
        '.NET SDK: 9.0.316', 'CMake: 4.4.0', 'Python: 3.13.14',
        'RTI 제품: 7.3.1 호환(설치본 별도 준비)',
        '참고: RTI 7.3.1에 x64Linux4gcc7.3.0 대상 라이브러리가 포함될 수 있습니다.',
        '', 'README.md와 docs/build.md를 읽고 build.ps1 -Doctor로 시작하세요.')
    Set-Content -LiteralPath (Join-Path $packageRoot 'PACKAGE-MANIFEST.txt') -Value $manifest -Encoding utf8

    # 패키지 목록은 파일명으로 고정하지 않고 실제 XML에서 발견한다.
    $moduleList = & python (Join-Path $repoRoot 'tools/codegen/schema_modules.py') --definitions (Join-Path $repoRoot 'definitions') --list
    if ($LASTEXITCODE -ne 0) { throw '모듈 목록을 읽지 못했습니다.' }
    $moduleNames = @((($moduleList -join '').Trim() -split ';') | Where-Object { $_ })
    foreach ($languageRoot in @('DDS_Nuget', 'DDSCPP')) {
        $stagedModules = Join-Path $packageRoot "$languageRoot/generated"
        foreach ($folder in @(Get-ChildItem -LiteralPath $stagedModules -Directory -ErrorAction SilentlyContinue)) {
            if ($folder.Name -notin $moduleNames) {
                $resolved = [IO.Path]::GetFullPath($folder.FullName)
                $prefix = [IO.Path]::GetFullPath($stagedModules).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
                if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw '잘못된 임시 모듈 경로입니다.' }
                Remove-Item -LiteralPath $resolved -Recurse -Force
            }
        }
    }
    Compress-Archive -LiteralPath $packageRoot -DestinationPath $temporaryArchive -CompressionLevel Optimal
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archiveReader = [System.IO.Compression.ZipFile]::OpenRead($temporaryArchive)
    try {
        foreach ($required in @('DDSClient/build.ps1', 'DDSClient/build-linux.ps1',
            'DDSClient/build-all.ps1',
            'DDSClient/create-source-package.ps1',
            'DDSClient/tools/build/build.ps1',
            'DDSClient/tools/build/build-windows.ps1',
            'DDSClient/tools/build/build-linux.ps1',
            'DDSClient/tools/build/create-source-package.ps1',
            'DDSClient/tools/build/common.ps1',
            'DDSClient/tools/build/test-docker.ps1',
            'DDSClient/tools/docker/Dockerfile.linux',
            'DDSClient/tools/docker/build-linux.sh',
            'DDSClient/tools/docker/Dockerfile.test',
            'DDSClient/tools/docker/test-linux.sh',
            'DDSClient/cli/codegen/generate-registry.py',
            'DDSClient/tools/codegen/schema_modules.py',
            'DDSClient/tools/codegen/isolate_types.py',
            'DDSClient/tools/codegen/codegen_io.py',
            'DDSClient/tools/codegen/backends/csharp.py',
            'DDSClient/tools/codegen/backends/cpp.py',
            'DDSClient/tools/codegen/validate-dds.py',
            'DDSClient/DDS_Nuget/core/DdsAmbassador.DDSClient.Core.csproj',
            'DDSClient/DDSCPP/cmake/AutoMessageModules.cmake',
            'DDSClient/DDSCPP/core/include/dds_cpp/api/Topic.hpp',
            'DDSClient/DDS_Nuget/tests/DdsAmbassador.DDSClient.Tests.csproj',
            'DDSClient/cli/csharp/DdsAmbassador.DDSClient.Cli.csproj',
            'DDSClient/cli/cpp/ddsclient.cpp',
            'DDSClient/cli/Directory.Build.props',
            'DDSClient/docs/build.md',
            'DDSClient/docs/configuration.md',
            'DDSClient/docs/csharp.md',
            'DDSClient/docs/cpp.md',
            'DDSClient/docs/cli.md',
            'DDSClient/docs/architecture.md',
            'DDSClient/offline-tools/linux-x64/ddsclient-rocky9-builder.tar',
            'DDSClient/offline-tools/linux-x64/ddsclient-rocky10-builder.tar')) {
            if (-not ($archiveReader.Entries | Where-Object FullName -eq $required)) {
                throw "생성한 압축 파일에 필수 항목이 없습니다: $required"
            }
        }
        foreach ($module in $moduleNames) {
            foreach ($relative in @("definitions/$module.xml", "DDS_Nuget/generated/$module/DdsAmbassador.Messages.$module.csproj",
                "DDS_Nuget/generated/$module/${module}Messages.cs", "DDS_Nuget/generated/$module/ModuleContract.g.cs",
                "DDS_Nuget/generated/$module/$module.cs")) {
                if (-not $archiveReader.GetEntry("DDSClient/$relative")) { throw "모듈 파일이 없습니다: $relative" }
            }
        }
        foreach ($feed in @('rti', 'third-party')) {
            $feedRoot = Join-Path $repoRoot "offline-tools/nuget/$feed"
            $packages = @(Get-ChildItem -LiteralPath $feedRoot -Filter '*.nupkg' -File)
            if ($packages.Count -eq 0) { throw "오프라인 NuGet 저장소가 비어 있습니다: $feedRoot" }
            foreach ($package in $packages) {
                $entryName = "DDSClient/offline-tools/nuget/$feed/$($package.Name)"
                $entry = $archiveReader.GetEntry($entryName)
                if (-not $entry -or $entry.Length -ne $package.Length) {
                    throw "압축 파일의 NuGet 패키지가 없거나 불완전합니다: $entryName"
                }
            }
        }
        if ($archiveReader.Entries | Where-Object { $_.Name -eq 'topics.xml' -or $_.Name -like 'dds_client*.xml' }) {
            throw '압축 파일에 폐기된 메시지 목록 또는 연결 설정 XML이 포함되어 있습니다.'
        }
        if ($archiveReader.Entries | Where-Object { $_.Name -match '\.(dat|pfx|pem|key)$' -or $_.Name -eq '.git' }) {
            throw '압축 파일에 라이선스·키 또는 Git 연결 파일이 포함되어 있습니다.'
        }
    }
    finally { $archiveReader.Dispose() }

    $hash = (Get-FileHash -LiteralPath $temporaryArchive -Algorithm SHA256).Hash
    Set-Content -LiteralPath $temporaryChecksum -Value "$hash  $([System.IO.Path]::GetFileName($OutputPath))" -Encoding ascii
    Publish-FileSet @($temporaryArchive, $temporaryChecksum) @($OutputPath, $checksumPath)

    $archive = Get-Item -LiteralPath $OutputPath
    Write-Host '소스 빌드 패키지를 생성했습니다.'
    Write-Host "  압축 파일: $($archive.FullName)"
    Write-Host "  파일 크기: $([math]::Round($archive.Length / 1MB, 1)) MiB"
    Write-Host "  SHA-256 : $hash"
}
finally {
    foreach ($temporary in @($temporaryArchive, $temporaryChecksum)) {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
    if ($stagingRoot -and (Test-Path -LiteralPath $stagingRoot)) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($lockStream) { $lockStream.Dispose() }
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
}
