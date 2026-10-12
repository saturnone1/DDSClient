# 빌드와 폐쇄망 반입

명령은 저장소 루트의 **PowerShell 7**에서 실행합니다. 일반 빌드 진입점은 `build.ps1` 하나입니다.

## 1. 준비

| 대상 | 별도로 준비할 것 |
|---|---|
| Windows | Visual Studio 2022(17.12 포함) 또는 2026의 x64 C++ 개발 도구, RTI 7.3.1 SDK·Windows 대상 라이브러리·라이선스 |
| Rocky 9.7 / 10.0 | Docker Linux 엔진, RTI 코드 생성 도구·Linux 대상 라이브러리·라이선스 |
| 공통 | CMake, Python. Windows C# 빌드에는 .NET 9 SDK도 필요 |

폐쇄망 소스 ZIP에는 .NET SDK·CMake·Python 설치 파일, NuGet 의존 패키지, Rocky 빌더 이미지가 들어 있습니다.
**Visual Studio·Docker/WSL·RTI SDK·라이선스는 포함하지 않습니다.** Git 복사본에는 설치 파일과 이미지가 없을 수 있습니다.

필수 도구가 없다면 관리자 권한으로 설치하고 **새 PowerShell 7 창**을 여세요.

~~~powershell
.\offline-tools\windows-x64\install-tools.ps1
~~~

RTI가 기본 설치 경로에 없다면 지정합니다.

~~~powershell
$env:NDDSHOME = 'D:\RTI\rti_connext_dds-7.3.1'
$env:RTI_LICENSE_FILE = 'D:\RTI\rti_license.dat'
~~~

## 2. 대상 선택 → 진단 → 빌드

| 원하는 결과 | 진단 | 빌드 |
|---|---|---|
| Windows C#·C++ | `.\build.ps1 -Doctor` | `.\build.ps1` |
| Rocky 9.7 C++ | `.\build.ps1 -Target Linux -RockyVersion 9.7 -Doctor` | `.\build.ps1 -Target Linux -RockyVersion 9.7` |
| Rocky 10.0 C++ | `.\build.ps1 -Target Linux -RockyVersion 10.0 -Doctor` | `.\build.ps1 -Target Linux -RockyVersion 10.0` |

- 기본값은 Windows입니다. Windows만 빌드할 때 Docker는 필요 없습니다.
- `All`은 Windows와 **선택한 Rocky 버전 하나**를 빌드합니다.
- 진단은 설치·Docker 시작을 수행하지 않습니다. 필수 조건이 없으면 실패합니다.
- 기존 Linux 결과를 교체하려면 `-Force`를 붙입니다. 새 결과 검증 후 교체합니다.
- `-SkipTests`는 빠른 개발 확인용입니다. 배포본은 테스트를 생략하지 마세요.

~~~powershell
# Windows와 Rocky 10.0을 순서대로 빌드
.\build.ps1 -Target All -RockyVersion 10.0 -Force

# Windows 빌드 캐시를 지우고 다시 구성
.\build.ps1 -Target Windows -Clean
~~~

`build-all.ps1`은 Windows 전용 호환 명령입니다.
`build-linux.ps1`은 `-SkipImageBuild`, `-RebuildImage`, `-OutputDirectory` 같은 고급 옵션용입니다.

Windows는 설치된 VS2022를 우선 선택하고, 없으면 VS2026을 선택합니다. 생성기·설치 경로·x64를 명시하므로 MSVC 19.51에 고정되지 않습니다.
Visual Studio IDE가 없어도 단독 C++ Build Tools와 Windows SDK가 있으면 C++을 빌드할 수 있습니다. 개발 환경에 MSVC와 Ninja가 직접 준비돼 있으면 해당 환경도 사용합니다.
`build.ps1 -Language CSharp`는 Visual Studio·MSVC·CMake 탐색 없이 C# 라이브러리와 NuGet만 빌드합니다. C++ 컴파일러가 전혀 없는 경우 C++ 빌드는 불가능하며 필요한 도구를 명확히 안내합니다.
컴파일러나 저장소 경로가 바뀌면 CMake 메타데이터만 재설정합니다. 기본 빌드는 라이브러리만 만들며 테스트를 실행하지 않습니다.
DDSSim 예제 CLI는 `-WithCli`, 예제 테스트는 `-WithTests`로 명시적으로 선택합니다. `-SkipTests`는 테스트 선택보다 우선합니다.

DDSSim과 Telemetry도 다른 XML과 동일한 메시지 모듈입니다. 이전 `DdsAmbassador.DDSClient` 패키지 참조는 `DdsAmbassador.Messages.DDSSim`으로 바꾸세요.
코어 이름 `DdsAmbassador.DDSClient.Core`는 그대로이며, 코어에는 메시지 모듈 참조가 없습니다.
공통 검증과 소스 패키징은 실제 모듈 목록을 사용하므로 DDSSim이 없는 구성도 허용합니다. CLI와 예제 테스트를 선택한 경우에만 해당 예제 모듈이 필요합니다.

배포 번들 생성기는 `tools/build/create-release-bundles.ps1 -Target DDSClient` 또는 `-Target SignalForge`로 따로 사용할 수 있습니다.
DDSClient 번들은 선택한 플랫폼 결과만 지정하면 되고 Signal Forge 폴더·Docker를 요구하지 않습니다. Signal Forge 번들은 `-SignalForgeImage`에 배포할 실제 이미지 태그를 명시해야 합니다.

## 3. 결과 사용

| 결과 | 위치 / 용도 |
|---|---|
| C# NuGet | `DDS_Nuget/artifacts/packages/` — 앱의 NuGet 저장소로 등록 |
| Windows 정적 코어 | `DDSCPP/build/lib/Release/dds_cpp_static.lib` |
| Windows 공유 코어 | `DDSCPP/build/bin/Release/dds_cpp.dll`과 링크용 `dds_cpp.lib` |
| C++ 메시지 모듈 | `dds_module_DDSSim`, `dds_module_Telemetry`, `dds_module_<이름>` 라이브러리 |
| Rocky C++ | `DDSCPP/artifacts/linux/DDSClient-CPP-rocky9-x64.tar.gz` / `rocky10` |
| 빌드 기록 | `artifacts/BUILD-REPORT.json`, `artifacts/logs/` |
| 진단 기록 | `artifacts/BUILD-DOCTOR.json` |

C# 앱에는 **코어 + 사용할 메시지 모듈 + 의존 패키지**가 필요합니다.
C++ 앱에는 코어와 메시지 라이브러리를 함께 링크합니다.
연동 예제는 [C#](csharp.md) / [C++](cpp.md)를 참고하세요.

C++ 설치 패키지를 만들려면:

~~~powershell
cmake --install DDSCPP/build --config Release --prefix DDSCPP/artifacts/install
~~~

RTI 실행 라이브러리와 라이선스는 실행 환경에도 필요합니다.
Linux 패키지에 RTI 실행 라이브러리를 넣으려면 `-IncludeRtiRuntime`을 지정하세요.
재배포 권한은 조직의 RTI 계약을 확인해야 합니다. Rocky 빌드 성공이 공급사의 공식 지원 보증은 아닙니다.

## XML 추가로 메시지 패키지 만들기

1. `definitions/Radar.xml`에 독립적인 RTI 타입 정의를 추가합니다.
2. 위의 빌드 명령을 실행합니다.
3. 앱에서 생성된 패키지를 참조하고 사용할 망·모듈·토픽을 선택합니다.

| 항목 | Radar.xml 결과 |
|---|---|
| C# 패키지 / 모듈 | `DdsAmbassador.Messages.Radar` / `RadarMessages.Module` |
| C++ 설치 타깃 / 모듈 | `DDSClient::Radar` / `dds_cpp::RadarMessages()` |
| 생성 위치 | C#은 `DDS_Nuget/generated/Radar/`, C++은 `DDSCPP/generated/Radar/` |

입력 규칙:

- 파일명은 영문자로 시작하는 영문·숫자·밑줄 조합입니다. 대소문자만 다른 파일명은 금지합니다.
- 등록할 struct/union은 module 안에 두며, 한 XML 안의 짧은 메시지 이름은 고유해야 합니다.
- 외부 XML 포함은 지원하지 않습니다. RTI XML의 `topLevel="false"` 타입은 등록하지 않습니다.
- QoS처럼 `<types>`가 없는 XML은 메시지 생성 대상이 아닙니다.
- 서로 다른 XML의 같은 타입 이름은 생성 네임스페이스로 격리합니다. DDS 통신 규격의 이름은 바꾸지 않습니다.
- XML 삭제 시 예전 패키지 파일까지 자동 삭제하지 않습니다. 배포할 모듈은 빌드 폴더의 `message-modules.txt`로 확인하세요.

생성 코드·등록부·CMake 타깃을 손으로 수정할 필요는 없습니다.
**빌드에 포함되는 것과 실행 중 연결하는 것은 별개입니다.** 자세한 설정은 [연결 설정](configuration.md)을 참고하세요.

## 폐쇄망 소스 ZIP 만들기

~~~powershell
.\create-source-package.ps1
# 기존 ZIP을 교체할 때만 -Force
~~~

결과: `artifacts/DDSClient-Source-Build-windows-x64.zip`과 `.sha256`.

소스·스크립트·오프라인 도구·이미지를 묶고 Git 기록과 기존 빌드 결과는 제외합니다.
반입 후 체크섬을 확인하고 압축을 푼 저장소 루트에서 다시 진단·빌드하세요.
실제 라이선스 파일과 RTI 설치본은 별도로 반입합니다.

## 문제가 생기면

| 증상 | 확인할 것 |
|---|---|
| cmake / python / dotnet 없음 | 설치 후 새 PowerShell 7 창을 열었는지 확인 |
| Docker 준비 실패 | Linux 컨테이너 모드인지 확인. Windows 빌드에는 불필요 |
| RTI 도구·라이브러리 없음 | `NDDSHOME`과 해당 운영체제 대상 라이브러리 확인 |
| 이전 PC 경로가 캐시에 남음 | Windows는 자동 재구성. 필요하면 `-Clean` |
| 출력 파일이 이미 있음 | 필요한 결과를 보관한 뒤 `-Force` |
| 한글이 깨짐 | PowerShell 7 사용. 새로 생성한 UTF-8 로그를 UTF-8로 열기 |

스크립트는 UTF-8 출력과 한국어 안내를 사용합니다. .NET/MSBuild에는 한국어 출력을 요청합니다.
CMake·RTI·Docker 등 외부 도구가 한국어를 제공하지 않는 메시지는 원문을 보존합니다.
기존에 깨진 로그나 이미 만든 ZIP은 소스 수정만으로 복구되지 않습니다.
Linux 빌드는 동봉 이미지의 도구를 사용하되 실행 스크립트는 현재 소스에서 읽기 전용으로 전달합니다.
이미지 전체와 Dockerfile의 체크섬은 계속 검사합니다. 이 경로의 수동 검사에는
`update-builder-image.ps1 -VerifyOnly -UseSourceBuildScript`를 사용합니다.

## 개발자용 검증

~~~powershell
# 빌드 스크립트·경로 필터 회귀 테스트
.\tools\build\tests\test-orchestration.ps1

# C# 실제 RTI 테스트: 준비된 Docker 이미지 재사용
.\tools\build\test-docker.ps1 -RockyVersions 9.7,10.0 -SkipImageBuild

# C#만 생성·빌드·검증·패키징
cmake -S DDS_Nuget -B DDS_Nuget/build -DDDS_GENERATE=ON
cmake --build DDS_Nuget/build --config Release

# C# CLI 배포 폴더 생성
cmake --build DDS_Nuget/build --config Release --target dds_publish_cli
~~~

Docker 테스트는 별도 내부 네트워크를 사용하고 소스·라이선스를 읽기 전용으로 전달합니다.
TRX 결과는 `artifacts/docker-csharp/`에 남습니다. 실제 RTI 테스트가 건너뛰어지면 실패로 처리합니다.

기존 코어를 유지한 새 모듈 검증은 C++ 설치 후 실행합니다.

~~~powershell
.\tools\build\test-module-addition.ps1 `
  -CoreAssembly DDS_Nuget/build/dotnet/DdsAmbassador.DDSClient.Core/bin/Release/net9.0/DdsAmbassador.DDSClient.Core.dll `
  -CppPrefix DDSCPP/artifacts/install
~~~

검사 중 코어를 다른 빌드로 교체하지 마세요.
같은 API/ABI의 코어에 모듈을 추가하는 검증이며 임의의 과거 코어와의 호환 보증은 아닙니다.

## 산출물 관리

소스는 `docs/`, `definitions/`, `cli/`, `tools/`, `DDS_Nuget/`, `DDSCPP/`에서 관리합니다.
`tools/build/`는 실행 스크립트이므로 빌드 캐시로 취급해 삭제하면 안 됩니다.
`bin/`, `obj/`, 각 프로젝트의 `build/`는 재생성 가능한 캐시입니다.
`offline-tools/`와 언어별 `generated/`는 폐쇄망 빌드용 소스 패키지에 포함합니다. `generated/`는 자동 생성물이고, 사람이 관리하는 코드는 `core/`에 있습니다.

배포 ZIP은 `artifacts/releases/`, 검증 로그는 `artifacts/logs/`에 보관합니다.
지난 검증 산출물은 `artifacts/archive/`로 옮겨 활성 작업 폴더와 구분합니다.
압축 해제한 배포본과 빌드 캐시는 최신 ZIP·체크섬 검증 뒤 정리할 수 있습니다.
`create-release-bundles.ps1`은 ZIP 내부 파일의 체크섬까지 확인한 뒤 임시 복사본을 지웁니다.
직접 검사할 복사본이 필요할 때만 `-KeepStaging`을 지정하세요.
