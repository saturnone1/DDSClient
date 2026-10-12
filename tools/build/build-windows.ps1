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

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $PSScriptRoot 'common.ps1')

function Find-CommandPath {
    param([Parameter(Mandatory)] [string] $Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "필수 명령 '$Name'을 찾을 수 없습니다. offline-tools\windows-x64\install-tools.ps1을 관리자 권한으로 실행한 뒤 새 PowerShell 7 창을 여세요."
    }
    return $command.Source
}

function Resolve-RtiHome {
    param([string] $RequestedHome)

    $candidates = @(Get-RtiHomeCandidates -RequestedHome $RequestedHome -SkipWhitespace)

    foreach ($candidate in $candidates) {
        $fullPath = [System.IO.Path]::GetFullPath($candidate)
        $generator = Join-Path $fullPath 'bin\rtiddsgen.bat'
        if (-not (Test-Path -LiteralPath $generator)) {
            $generator = Join-Path $fullPath 'bin\rtiddsgen.exe'
        }
        $schema = Join-Path $fullPath 'resource\schema\rti_dds_profiles.xsd'
        $platformLibraries = if ($buildCpp) { Get-ChildItem -LiteralPath (Join-Path $fullPath 'lib') -Directory -Filter 'x64Win64VS*' -ErrorAction SilentlyContinue |
            Where-Object {
                (Test-Path -LiteralPath (Join-Path $_.FullName 'nddscpp2.lib')) -and
                (Test-Path -LiteralPath (Join-Path $_.FullName 'nddsc.lib')) -and
                (Test-Path -LiteralPath (Join-Path $_.FullName 'nddscore.lib'))
            }
        } else { @() }
        if ((Test-Path -LiteralPath $generator -PathType Leaf) -and
            (Test-Path -LiteralPath $schema -PathType Leaf) -and
            (-not $buildCpp -or $platformLibraries)) {
            return $fullPath
        }
    }

    throw 'RTI 설치가 불완전합니다. rtiddsgen, resource\schema\rti_dds_profiles.xsd와 Windows x64 nddscpp2/nddsc/nddscore 라이브러리가 필요합니다. NDDSHOME 또는 -RtiHome을 지정하세요.'
}

function Remove-BuildDirectory {
    param([Parameter(Mandatory)] [string] $BuildDirectory)

    if (-not (Test-Path -LiteralPath $BuildDirectory)) {
        return
    }

    $resolvedBuildDirectory = [System.IO.Path]::GetFullPath($BuildDirectory)
    $repositoryPrefix = [System.IO.Path]::GetFullPath($repoRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedBuildDirectory.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "저장소 밖의 빌드 폴더는 삭제하지 않습니다: $resolvedBuildDirectory"
    }

    Remove-Item -LiteralPath $resolvedBuildDirectory -Recurse -Force
}

function Reset-IncompatibleCMakeCache {
    param(
        [Parameter(Mandatory)] [string] $BuildDirectory,
        [Parameter(Mandatory)] [string] $SourceDirectory,
        [Parameter(Mandatory)] $Compiler
    )

    $cachePath = Join-Path $BuildDirectory 'CMakeCache.txt'
    if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
        return
    }

    $cache = Get-Content -LiteralPath $cachePath
    $cachedSource = ($cache | Where-Object { $_ -like 'CMAKE_HOME_DIRECTORY:INTERNAL=*' } | Select-Object -First 1) -replace '^CMAKE_HOME_DIRECTORY:INTERNAL=', ''
    $cachedCmake = ($cache | Where-Object { $_ -like 'CMAKE_COMMAND:INTERNAL=*' } | Select-Object -First 1) -replace '^CMAKE_COMMAND:INTERNAL=', ''
    $expectedSource = [System.IO.Path]::GetFullPath($SourceDirectory).Replace('\', '/')

    $sourceMoved = [string]::IsNullOrWhiteSpace($cachedSource) -or
        -not $cachedSource.Equals($expectedSource, [StringComparison]::OrdinalIgnoreCase)
    $cmakeMissing = -not [string]::IsNullOrWhiteSpace($cachedCmake) -and
        -not (Test-Path -LiteralPath $cachedCmake -PathType Leaf)

    $cachedGenerator = ($cache | Where-Object { $_ -like 'CMAKE_GENERATOR:INTERNAL=*' } | Select-Object -First 1) -replace '^CMAKE_GENERATOR:INTERNAL=', ''
    $cachedInstance = ($cache | Where-Object { $_ -like 'CMAKE_GENERATOR_INSTANCE:INTERNAL=*' } | Select-Object -First 1) -replace '^CMAKE_GENERATOR_INSTANCE:INTERNAL=', ''
    $cachedArchitecture = ($cache | Where-Object { $_ -like 'CMAKE_GENERATOR_PLATFORM:INTERNAL=*' } | Select-Object -First 1) -replace '^CMAKE_GENERATOR_PLATFORM:INTERNAL=', ''
    $compilerChanged = $cachedGenerator -ne $Compiler.Generator -or ($Compiler.IsVisualStudioGenerator -and $cachedArchitecture -ne $Compiler.Architecture) -or
        ($cachedInstance -and $cachedInstance.Replace('\','/') -ne $Compiler.Instance.Replace('\','/'))
    if ($sourceMoved -or $cmakeMissing -or $compilerChanged) {
        Write-Host "현재 경로와 맞지 않는 CMake 캐시를 정리합니다: $BuildDirectory"
        # .NET 출력과 패키지는 유지하고 생성기 메타데이터만 다시 구성한다.
        $root = [IO.Path]::GetFullPath($BuildDirectory).TrimEnd('\','/')
        $prefix = [IO.Path]::GetFullPath($repoRoot).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
        if (-not $root.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw '저장소 밖의 CMake 캐시는 정리하지 않습니다.'
        }
        foreach ($name in @('CMakeCache.txt', 'CMakeFiles')) {
            $metadata = [IO.Path]::GetFullPath((Join-Path $root $name))
            if (-not $metadata.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                throw '잘못된 CMake 메타데이터 경로입니다.'
            }
            if (Test-Path -LiteralPath $metadata) { Remove-Item -LiteralPath $metadata -Recurse -Force }
        }
    }
}

$windowsLock = $null
try {
try {
    $windowsLock = [System.IO.File]::Open((Join-Path $repoRoot '.ddsclient-windows-build.lock'),
        'OpenOrCreate', 'ReadWrite', 'None')
}
catch { throw '이 저장소에서 다른 Windows C#/C++ 빌드가 실행 중입니다.' }

$buildCSharp = $Language -in @('All','CSharp')
$buildCpp = $Language -in @('All','Cpp')
$cmake = if ($buildCpp) { Find-CommandPath 'cmake' } else { $null }
$dotnet = if ($buildCSharp) { Find-CommandPath 'dotnet' } else { $null }
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    $python = Get-Command py -ErrorAction SilentlyContinue
}
if (-not $python) {
    throw "Python을 찾을 수 없습니다. offline-tools\windows-x64\install-tools.ps1을 관리자 권한으로 실행한 뒤 새 PowerShell 7 창을 여세요."
}

$resolvedRtiHome = Resolve-RtiHome $RtiHome
$compiler = if ($buildCpp) { Get-MsvcBuildEnvironment } else { $null }
$env:NDDSHOME = $resolvedRtiHome
$env:PATH = "$(Join-Path $resolvedRtiHome 'bin');$env:PATH"

Write-Host 'DDSClient 빌드 환경'
Write-Host "  저장소     : $repoRoot"
Write-Host "  빌드 구성  : $Configuration"
Write-Host "  RTI Connext: $resolvedRtiHome"
Write-Host "  CMake      : $cmake"
Write-Host "  .NET       : $dotnet"
Write-Host "  Python     : $($python.Source)"
Write-Host "  MSVC 환경  : $($compiler.Generator) / $($compiler.Version) / $($compiler.Architecture)"
Write-Host "  VS 설치본  : $($compiler.Instance)"

$csharpBuild = Join-Path $repoRoot 'DDS_Nuget\build'
$cppBuild = Join-Path $repoRoot 'DDSCPP\build'
$csharpSource = Join-Path $repoRoot 'DDS_Nuget'
$cppSource = Join-Path $repoRoot 'DDSCPP'

if ($buildCSharp) {
    # C#은 dotnet과 생성 도구만 사용한다. Visual Studio와 CMake가 없어도 동작한다.
    $moduleGenerator = Join-Path $repoRoot 'tools/codegen/schema_modules.py'
    Invoke-Checked $python.Source @($moduleGenerator, '--definitions', (Join-Path $repoRoot 'definitions'),
        '--output', (Join-Path $csharpSource 'generated'), '--language', 'c#', '--rti-home', $resolvedRtiHome,
        '--core', (Join-Path $csharpSource 'core/DdsAmbassador.DDSClient.Core.csproj'))
    $moduleText = & $python.Source $moduleGenerator --definitions (Join-Path $repoRoot 'definitions') --list
    if ($LASTEXITCODE -ne 0) { throw '모듈 목록을 읽지 못했습니다.' }
    $moduleNames = @(($moduleText -join '').Split(';') | Where-Object { $_ })
    $projects = @((Join-Path $csharpSource 'core/DdsAmbassador.DDSClient.Core.csproj')) +
        @($moduleNames | ForEach-Object { Join-Path $csharpSource "generated/$_/DdsAmbassador.Messages.$_.csproj" })
    if ($WithCli) {
        if ('DDSSim' -notin $moduleNames) { throw '선택한 예제 CLI의 DDSSim 모듈이 없습니다.' }
        $projects += Join-Path $repoRoot 'cli/csharp/DdsAmbassador.DDSClient.Cli.csproj'
    }
    if ($WithTests -and -not $SkipTests) { $projects += Join-Path $csharpSource 'tests/DdsAmbassador.DDSClient.Tests.csproj' }
    foreach ($project in $projects) {
        Invoke-Checked $dotnet @('restore', $project, '--configfile', (Join-Path $csharpSource 'NuGet.config'))
        $buildArguments = @('build', $project, '-c', $Configuration, '--no-restore')
        if ($Clean) { $buildArguments += '--no-incremental' }
        Invoke-Checked $dotnet $buildArguments
    }
    foreach ($project in $projects | Where-Object { $_ -notmatch '[/\\](cli|tests)[/\\]' }) {
        Invoke-Checked $dotnet @('pack', $project, '-c', $Configuration, '--no-build', '--no-restore',
            '-o', (Join-Path $csharpSource 'artifacts/packages'))
    }
    if ($WithTests -and -not $SkipTests) {
        Invoke-Checked $dotnet @('test', (Join-Path $csharpSource 'tests/DdsAmbassador.DDSClient.Tests.csproj'), '-c', $Configuration, '--no-build', '--no-restore')
    }
}
if ($buildCpp) {
    if ($Clean) { Remove-BuildDirectory $cppBuild }
    else { Reset-IncompatibleCMakeCache $cppBuild $cppSource $compiler }
    $generatorArguments = @('-G', $compiler.Generator)
    if ($compiler.IsVisualStudioGenerator) {
        $generatorArguments += @('-A', $compiler.Architecture, "-DCMAKE_GENERATOR_INSTANCE=$($compiler.Instance)")
    }
    $cppConfigure = $generatorArguments + @('-S', $cppSource, '-B', $cppBuild, '-DDDSCPP_ENABLE_RTI=ON',
        "-DCMAKE_BUILD_TYPE=$Configuration", "-DDDSCPP_RTI_HOME=$resolvedRtiHome",
        "-DDDSCPP_BUILD_TESTS=$(if ($WithTests -and -not $SkipTests) { 'ON' } else { 'OFF' })",
        "-DDDSCPP_BUILD_CLI=$(if ($WithCli) { 'ON' } else { 'OFF' })")
    Invoke-Checked $cmake $cppConfigure
    Invoke-Checked $cmake @('--build', $cppBuild, '--config', $Configuration)
    if ($WithTests -and -not $SkipTests) {
        Invoke-Checked (Find-CommandPath 'ctest') @('--test-dir', $cppBuild, '-C', $Configuration, '--output-on-failure')
    }
}

Write-Host ''
Write-Host '빌드가 완료되었습니다.'
Write-Host "  C# NuGet: $(Join-Path $repoRoot 'DDS_Nuget\artifacts\packages')"
Write-Host "  C++ 결과: $cppBuild"
}
finally {
    if ($windowsLock) { $windowsLock.Dispose() }
    Remove-Item -LiteralPath (Join-Path $repoRoot '.ddsclient-windows-build.lock') -Force -ErrorAction SilentlyContinue
}
