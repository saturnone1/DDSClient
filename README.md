# DDSClient

C#·C++ DDS 라이브러리와 CLI를 함께 빌드하는 저장소입니다.
공통 코어와 메시지 모듈(DDSSim·Telemetry)을 분리하고, 연결마다 모듈·토픽·Domain·QoS를 선택합니다.
`definitions/`에 메시지 XML을 추가하면 C#·C++ 모듈과 패키지를 자동 생성합니다([입력 규칙](docs/build.md#xml-추가로-메시지-패키지-만들기)).
한 프로세스에서 여러 연결을 독립적으로 사용할 수 있으며 새 메시지 모듈 때문에 코어를 재빌드할 필요는 없습니다.
문서는 **이 README에서 시작하고, 상세 내용은 `docs/` 한 곳에서 관리**합니다.

## 문서

- [빌드·폐쇄망 배포](docs/build.md): Windows, Rocky 9.7·10.0, 도구 설치, 소스 ZIP
- [연결·송수신 설정](docs/configuration.md): 코드 API, 메시지 선택, QoS, 환경변수
- [C# 사용법·API](docs/csharp.md): NuGet 설치, 송수신, 수명 관리
- [C++ 사용법·API](docs/cpp.md): CMake 연동, 송수신, 수명 관리
- [CLI·Kubernetes](docs/cli.md): 명령행 도구와 수동 통신 확인
- [구조·API 대응](docs/architecture.md): 내부 동작과 C#·C++ 대응
- [외부 구성요소 고지](THIRD-PARTY-NOTICES.md)

## 빠른 시작

Windows에서는 PowerShell 7(`pwsh`)에서 실행하세요. `build.ps1`의 기본 대상은 Windows입니다.

```powershell
git clone --recurse-submodules https://github.com/saturnone1/DDSClient.git
cd DDSClient
.\build.ps1 -Doctor
.\build.ps1 -Target Windows
.\build.ps1 -Target Linux -RockyVersion 9.7
.\build.ps1 -Target Linux -RockyVersion 10.0
```

이미 clone했다면 `git submodule update --init --recursive`로 하위 저장소를 받으세요.
폐쇄망에는 소스 ZIP을 사용합니다. 설치 파일·builder image는 Git에 포함하지 않으므로
Git checkout만 복사해서는 폐쇄망 빌드에 충분하지 않습니다.
Visual Studio, RTI 설치·라이선스, Linux 빌드용 Docker는 별도로 준비합니다.
`-Doctor`는 선택한 대상의 준비 상태를 검사하며 필수 조건이 없으면 실패합니다.
CMake 등이 PATH에 없으면 `offline-tools/windows-x64/install-tools.ps1`을 관리자 권한으로
실행한 뒤 새 PowerShell 7 창을 여세요. 기존 `build-all.ps1`은 Windows 전용 호환 진입점입니다.

## 저장소 구조

- `definitions/`: 메시지 스키마 `DDSSim.xml`·`Telemetry.xml`, 공통 `qos_profiles.xml`
- `DDS_Nuget/`: C# 라이브러리·테스트
- `DDS_Nuget/core/`: Core 구현·프로젝트. 메시지별 프로젝트·생성 코드는 `modules/`에서 관리합니다.
- `DDSCPP/`: C++ 라이브러리·테스트
- `cli/csharp/`, `cli/cpp/`, `cli/tests/`: CLI와 상호 송수신 검증
- `docs/`: 모든 상세 안내서
- `tools/codegen/`: C#·C++ 공통 XML 탐색·검증·코드 생성 도구
- `tools/build/`, `tools/docker/`: 빌드 구현과 Docker 검증. 루트 PowerShell 진입 명령은 유지합니다.
- `offline-tools/`: 폐쇄망 설치·이미지 도구와 공통 `nuget/` 의존성
- `artifacts/`: 빌드·패키지 결과 (Git 제외)

하위 모듈은 공통 definitions와 CLI를 참조하므로 이 최상위 저장소에서 작업하세요.
연결과 송수신 메시지는 코드 옵션으로 지정하며 기본 연결은 domain 0의 실제 RTI입니다.
Discovery는 QoS XML에서 설정합니다. DDSSim.xml은 타입·레지스트리 생성용 빌드 입력이며
실행 시에는 qos_profiles.xml만 필요합니다.

소스 ZIP 생성: `./create-source-package.ps1`.
NuGet 표시용 README는 패키지에 포함해야 하므로 해당 프로젝트에 짧은 소개만 유지합니다.
