# Windows에서 Linux C++ 라이브러리 빌드

이 절차는 Windows PC에서 현재 `DDSSim.xml`과 `topics.xml`을 반영한 Linux x64
정적·공유 라이브러리를 만듭니다.

## 필요한 항목

- Docker Desktop의 Linux container engine
- RTI Connext DDS host tools와 `x64Linux*` target library
- CMake 3.20 이상

Visual Studio는 Windows 전체 빌드에는 필요하지만 Linux 패키지 빌드 자체는
컨테이너의 GCC를 사용합니다. CMake가 없다면 동봉된 설치 도구를 먼저 실행합니다.

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\offline-tools\windows-x64\install-tools.ps1
```

Docker Desktop은 라이선스 및 조직별 설치 정책 때문에 이 패키지에 포함되지
않습니다. 설치 후 Linux containers가 실행 중인지 다음 명령으로 확인합니다.

```powershell
docker info
```

## 빌드

먼저 환경을 진단할 수 있습니다. 경고는 가능한 대안을 안내하며 무조건 빌드를
막지는 않습니다.

```powershell
.\build.ps1 -Doctor
```

저장소 루트에서 Linux C++만 빌드합니다.

```powershell
.\build-linux.ps1
```

Windows C#·C++까지 한 번에 빌드하려면 다음 명령을 사용합니다.

```powershell
.\build.ps1 -Target All -StartDocker -Force
```

스크립트는 다음 작업을 자동 수행합니다.

1. RTI의 `rtiddsgen`과 Linux x64 target 검사
2. 현재 XML에서 C++ 타입과 topic registry 재생성
3. 동봉된 Rocky Linux 9 builder image의 체크섬 검증 및 로드
4. GCC로 `libdds_cpp.a`, `libdds_cpp.so`, `ddsclient` 빌드
5. 프로젝트 테스트와 설치 패키지 테스트 실행
6. 공유·정적 라이브러리를 각각 별도 소비자 프로젝트에 링크하여 실행
7. ELF header, 동적 의존성, RPATH 검사
8. `tar.gz`와 SHA-256 파일 생성

기존 결과를 교체하려면 다음과 같이 실행합니다.

```powershell
.\build-linux.ps1 -Force
```

새 빌드와 체크섬 검증이 완료되기 전에는 기존 결과를 삭제하지 않습니다. 같은 출력
디렉터리에서 중복 실행하면 한쪽 실행만 명확한 메시지와 함께 중단됩니다.

RTI가 기본 설치 경로에 없다면 직접 지정합니다.

```powershell
.\build-linux.ps1 -RtiHome 'D:\RTI\rti_connext_dds-7.3.1'
```

여러 Linux target이 설치되어 있으면 호환되는 최신 x64 target을 선택합니다.
특정 target을 선택할 수도 있습니다.

```powershell
.\build-linux.ps1 -RtiPlatform 'x64Linux4gcc7.3.0' -Force
```

RTI 7.3.1 제품에 `x64Linux4gcc7.3.0` target 폴더가 포함되는 것은 정상입니다.
생성 패키지는 제품 버전과 target 이름을 각각 기록합니다. 소비자 PC에 동일 target이
없으면 호환 후보를 선택하고 경고하며 자동으로 즉시 중단하지는 않습니다.

소스 ZIP에는 Rocky Linux 9의 GCC/CMake builder image가 동봉되므로 Docker
Desktop과 RTI가 설치되어 있으면 기본 명령이 인터넷 없이 동작합니다. 이미 로드된
이미지만 사용하려면 다음과 같이 실행합니다.

```powershell
.\build-linux.ps1 -SkipImageBuild -Force
```

Dockerfile이나 Linux 빌드 스크립트를 변경한 개발자는 builder image도 갱신한 뒤
소스 ZIP을 다시 만들어야 합니다.

```powershell
.\offline-tools\linux-x64\update-builder-image.ps1
.\create-source-package.ps1 -Force
```

온라인 저장소에서 builder image를 강제로 다시 생성해 바로 빌드하려면
`.\build-linux.ps1 -RebuildImage -Force`를 사용합니다.

## Rocky Linux 10 빌드

`-RockyVersion`으로 다른 Rocky 버전을 대상으로 빌드할 수 있습니다.

```powershell
.\build-linux.ps1 -RockyVersion 10.0 -Force
```

이미지 태그와 패키지 이름은 Rocky major 버전을 따라갑니다. 위 명령은
`ddsclient-rocky10-builder:latest` 이미지를 만들고
`DDSClient-CPP-rocky10-x64.tar.gz`를 생성하므로 Rocky 9 이미지나 산출물을
덮어쓰지 않습니다. 두 버전을 나란히 보관할 수 있습니다.

소스 ZIP에는 **Rocky 9와 Rocky 10 builder image가 모두 동봉**되므로, 위 명령은
폐쇄망에서도 인터넷 없이 그대로 동작합니다. `build-linux.ps1`은 요청한 Rocky
major 버전에 맞는 `ddsclient-rocky<major>-builder.tar`를 체크섬 검증 후
자동으로 로드합니다.

builder image를 갱신할 때는 두 버전이 함께 다시 만들어집니다.

```powershell
.\offline-tools\linux-x64\update-builder-image.ps1              # 기본값: 9.7, 10.0
.\offline-tools\linux-x64\update-builder-image.ps1 -RockyVersions 10.0   # 특정 버전만
```

이 작업에는 인터넷(레지스트리 접근)이 필요하므로 반출 PC에서 수행한 뒤
`create-source-package.ps1`로 ZIP을 다시 만들어 반입합니다.


## 결과

```text
artifacts/linux/DDSClient-CPP-rocky9-x64/
artifacts/linux/DDSClient-CPP-rocky9-x64.tar.gz
artifacts/linux/DDSClient-CPP-rocky9-x64.tar.gz.sha256
```

기본 패키지는 RTI의 `.so` 파일을 복사하지 않습니다. 실행 PC의 RTI 설치 경로를
사용하도록 `NDDSHOME`과 `LD_LIBRARY_PATH`를 지정합니다.

```bash
export NDDSHOME=/opt/rti_connext_dds-7.3.1
export LD_LIBRARY_PATH="$NDDSHOME/lib/x64Linux4gcc7.3.0:$LD_LIBRARY_PATH"
```

RTI 라이선스 및 재배포 조건을 확인했고 독립 실행 패키지가 필요한 경우에만 다음
옵션을 사용합니다.

```powershell
.\build-linux.ps1 -IncludeRtiRuntime -Force
```

## CMake 소비자 예제

```cmake
set(DDSClient_RTI_HOME "/opt/rti_connext_dds-7.3.1")
find_package(DDSClient CONFIG REQUIRED)
target_link_libraries(my_app PRIVATE DDSClient::dds_cpp)
```

정적 라이브러리를 선택하려면 `find_package` 전에 설정합니다.

```cmake
set(DDSClient_USE_STATIC_LIBS ON)
```

현재 설치에 ARM64 Linux target이 없으면 ARM64 산출물은 만들 수 없습니다. ARM64
빌드는 RTI의 `arm64Linux*` target package와 ARM64 builder를 별도로 준비해야 합니다.
