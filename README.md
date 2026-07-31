# DDSClient source build

## 저장소 받기

이 상위 저장소는 C#과 C++ 저장소를 submodule로 관리합니다.

```powershell
git clone --recurse-submodules https://github.com/saturnone1/DDSClient.git
```

이미 clone했다면 다음 명령으로 하위 저장소를 받습니다.

```powershell
git submodule update --init --recursive
```

GitHub의 파일 크기 제한 때문에 .NET/CMake/Python 설치 파일, Rocky Linux builder
image 및 완성된 배포 패키지는 Git 커밋에 포함하지 않고 이 저장소의 GitHub
Release 자산으로 제공합니다. 완전한 오프라인 빌드가 필요하면 Release의
`DDSClient-Source-Build-windows-x64.zip`을 사용하세요.

이 저장소에서 `DDSSim.xml`을 수정하고 C# 및 C++ 라이브러리를 다시 빌드하려는
Windows 개발자는 [Windows 오프라인 전체 빌드 안내](BUILD-WINDOWS-OFFLINE.md)를
따르세요.

대상 PC에 Visual Studio와 RTI Connext DDS가 설치돼 있다면 먼저 통합 진단을
실행할 수 있습니다.

```powershell
.\build.ps1 -Doctor
```

동봉된 .NET SDK, CMake, Python 설치 파일을 설치한 후 Windows C#·C++와 Linux
C++ 전체 타입 재생성 및 빌드는 다음 명령으로 수행합니다.

```powershell
.\build.ps1 -Target All -StartDocker -Force
```

Windows 또는 Linux C++만 선택할 수도 있습니다.

```powershell
.\build.ps1 -Target Windows
.\build.ps1 -Target Linux -Force
```

다른 PC에 전달할 오프라인 소스 빌드 ZIP은 다음 명령으로 만듭니다.

```powershell
.\create-source-package.ps1
```

Windows에서 Rocky Linux 9 x64용 C++ 정적·공유 라이브러리를 만들려면 Docker
Desktop의 Linux container engine을 실행한 뒤 다음 명령을 사용하세요.

```powershell
.\build-linux.ps1
```

결과에는 `libdds_cpp.a`, `libdds_cpp.so`, CMake 소비자 패키지와 검증 체크섬이
포함됩니다. 상세 절차는 [BUILD-LINUX.md](BUILD-LINUX.md)를 참고하세요. 위 소스
빌드 ZIP에도 이 Linux 빌드 스크립트와 Docker 설정이 함께 포함됩니다.

RTI 제품 버전과 target 이름은 별도로 표시됩니다. 예를 들어 RTI 제품은 7.3.1인
동시에 Linux target 폴더 이름은 `x64Linux4gcc7.3.0`일 수 있습니다.

빌드된 라이브러리만 사용하고 메시지 정의를 변경하지 않는 개발자는
`DDSClient-Developer-Package/README.md`를 참고하세요.
