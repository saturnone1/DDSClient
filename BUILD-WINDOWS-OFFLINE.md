# Windows 오프라인 전체 빌드 안내

이 안내서는 인터넷이 연결되지 않은 Windows x64 PC에서 `DDSSim.xml`을 수정하고
C# 및 C++ DDS 타입을 다시 생성하여 빌드하는 절차입니다.

## 대상 PC에 미리 있어야 하는 것

- Visual Studio 2022와 **Desktop development with C++** 워크로드
- RTI Connext DDS 7.3.1 또는 호환 버전(Windows x64 target library 포함)
- 유효한 `rti_license.dat`

.NET SDK, CMake, Python 설치 파일은 저장소의
`offline-tools/windows-x64/installers`에 포함돼 있습니다.

## 1. 빌드 도구 설치

관리자 권한으로 PowerShell을 열고 저장소 루트에서 실행합니다.

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\offline-tools\windows-x64\install-tools.ps1
```

스크립트는 설치 파일의 공식 체크섬을 먼저 검사하고 다음 도구를 설치합니다.

| 도구 | 동봉 버전 |
|---|---:|
| .NET SDK | 9.0.316 |
| CMake | 4.4.0 |
| Python | 3.13.14 |

설치하지 않고 동봉 파일의 무결성만 확인하려면 일반 PowerShell에서 실행합니다.

```powershell
.\offline-tools\windows-x64\install-tools.ps1 -VerifyOnly
```

설치가 끝나면 PowerShell을 닫고 새 PowerShell을 여세요. 다음 명령으로 설치를
확인할 수 있습니다.

```powershell
dotnet --version
cmake --version
python --version
```

## 2. RTI 경로 확인

RTI가 기본 위치인 `C:\Program Files\rti_connext_dds-*`에 설치돼 있으면 빌드
스크립트가 자동으로 찾습니다. 다른 위치라면 현재 PowerShell에서 지정합니다.

```powershell
$env:NDDSHOME = 'D:\RTI\rti_connext_dds-7.3.1'
```

`NDDSHOME\bin\rtiddsgen.bat` 또는 `rtiddsgen.exe`가 있어야 합니다. RTI
Launcher만 있고 host development tools나 Windows x64 target library가 없으면
전체 빌드를 할 수 없습니다.

## 3. 메시지 정의 수정

원본은 다음 한 곳만 수정합니다.

```text
DDS_Nuget/definitions/DDSSim.xml
```

메시지 struct를 topic으로 추가하거나 삭제했다면 다음 파일도 함께 수정합니다.

```text
DDS_Nuget/definitions/topics.xml
```

`topics.xml`의 `name`은 `DDSSim.xml`의 `MSG` module 안 struct 이름과 같아야
합니다. Developer Package 아래에 있는 XML은 배포용 복사본이므로 원본으로
사용하지 않습니다.

## 4. C# 및 C++ 전체 빌드

설치 상태를 먼저 확인하려면 다음 통합 진단을 실행합니다.

```powershell
.\build.ps1 -Doctor
```

저장소 루트에서 다음 명령 하나를 실행합니다.

```powershell
.\build-all.ps1
```

Windows C#·C++, Linux C++까지 한 번에 실행하려면 Docker Desktop을 실행하고
다음 명령을 사용합니다.

```powershell
.\build.ps1 -Target All -StartDocker -Force
```

통합 스크립트는 `artifacts/logs`에 실행 로그를, `artifacts/BUILD-REPORT.json`에
성공 여부와 산출물 목록을 기록합니다.

스크립트는 순서대로 다음 작업을 수행합니다.

1. CMake, .NET, Python, RTI와 `rtiddsgen` 확인
2. `DDSSim.xml`에서 C# 타입 재생성
3. XML 및 생성된 C# 타입 일치 여부 검증
4. C# 라이브러리·CLI·테스트 빌드와 NuGet 패키지 생성
5. `DDSSim.xml`에서 C++ 타입 및 topic registry 재생성
6. C++ 라이브러리·CLI·테스트 빌드

기존 build 디렉터리를 지우고 완전히 다시 만들려면 다음과 같이 실행합니다.

```powershell
.\build-all.ps1 -Clean
```

다른 PC에서 복사해 온 build cache에 이전 PC의 절대 경로가 들어 있으면 스크립트가
자동으로 해당 cache를 삭제하고 다시 구성합니다.

RTI가 자동으로 검색되지 않으면 경로를 직접 전달합니다.

```powershell
.\build-all.ps1 -RtiHome 'D:\RTI\rti_connext_dds-7.3.1'
```

빠른 확인을 위해 테스트를 제외하려면 `-SkipTests`를 사용할 수 있지만, 배포본을
만들 때는 테스트를 생략하지 않는 것을 권장합니다.

## 5. 결과 위치

```text
DDS_Nuget/artifacts/packages     C# NuGet 패키지
DDS_Nuget/artifacts/ddsclient    C# CLI publish 결과(별도 target 실행 시)
DDSCPP/build                     C++ 빌드 결과
```

송신자와 수신자에는 반드시 동일한 `DDSSim.xml`에서 생성한 C# 또는 C++
라이브러리를 함께 배포해야 합니다.

## 6. 다른 PC에 전달할 ZIP 만들기

저장소 전체를 직접 복사하면 기존 PC의 build cache와 불필요한 산출물도 함께
전달됩니다. 다음 명령으로 오프라인 전체 빌드에 필요한 파일만 묶습니다.

```powershell
.\create-source-package.ps1
```

결과:

```text
artifacts/DDSClient-Source-Build-windows-x64.zip
artifacts/DDSClient-Source-Build-windows-x64.zip.sha256
```

이 ZIP에는 C#·C++ 원본, 공통 XML, 로컬 NuGet 패키지, 세 가지 설치 파일,
Windows 빌드 절차, Linux 빌드 스크립트와 Rocky 9 builder image가 포함됩니다.
Linux 빌드는 Docker Desktop 및 RTI의 `x64Linux*` target이 추가로 필요하며 `BUILD-LINUX.md`를
따릅니다. `.git`, `build`, `bin`, `obj`, 기존 artifacts와 Developer Package
바이너리는 제외됩니다. 기존 ZIP을 교체하려면 `-Force`를 지정합니다.

## 7. 설치 파일 출처와 재배포 확인

동봉 파일은 Microsoft, Kitware, Python Software Foundation의 공식 배포본입니다.
URL과 체크섬은 `offline-tools/windows-x64/checksums.txt`에 기록돼 있습니다.
프로젝트를 조직 외부에 전달할 때는 각 제품의 라이선스와 조직의 소프트웨어
재배포 정책을 별도로 확인하세요.
