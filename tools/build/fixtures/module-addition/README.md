# 코어 재빌드 없이 메시지 모듈 추가 검증

이미 빌드한 C# 코어 DLL과 C++ 설치 패키지에 새 모듈만 연결하는 Windows RTI 테스트입니다. 같은 코어 API/ABI·컴파일러·RTI 버전끼리 검증하며, 임의의 과거 버전과 호환된다는 의미는 아닙니다.

코어 빌드와 C++ 설치가 끝난 뒤 저장소 루트에서 실행하세요.

```powershell
.\tools\build\test-module-addition.ps1 `
  -CoreAssembly .\DDS_Nuget\build\dotnet\DdsAmbassador.DDSClient.Core\bin\Release\net9.0\DdsAmbassador.DDSClient.Core.dll `
  -CppPrefix .\DDSCPP\artifacts\install `
  -RtiHome 'C:/Program Files/rti_connext_dds-7.3.1'
```

`-CppPrefix`는 코어 라이브러리·공개 헤더·`DDSClientConfig.cmake`가 일치하는 설치 폴더여야 합니다. 이 테스트는 코어를 다시 빌드하거나 설치하지 않습니다.

기본값은 Release, RTI 대상 `x64Win64VS2017`, C++ 정적·공유 링크 모두입니다. 기존 빌드에 맞춰 `-Configuration`, `-RtiPlatform`, 필요하면 `-CMakeGenerator`를 지정하세요. 한 종류만 설치했다면 `-CppLinkage Static` 또는 `Shared`를 선택하세요.

라이선스는 `-LicenseFile` → `RTI_LICENSE_FILE` → `<RtiHome>/rti_license.dat` 순서로 찾습니다. 실제 RTI 송수신이 필수이며 인메모리 대체나 건너뛰기는 없습니다. 기본 도메인은 186이고 토픽 이름은 실행마다 고유합니다.

검증 내용:

1. 코어 바이너리의 해시를 기록하고 별도 폴더에 복사·고정합니다.
2. `AddedAfterFreeze.xml`에서 C#·C++ 메시지 모듈만 새로 생성합니다.
3. 고정한 코어와 새 모듈을 연결해 C#·C++ 소비자를 빌드합니다.
4. 소비자별로 메시지 4개의 순서와 내용, 실제 연결된 코어를 확인합니다.
5. 성공·실패 모두 원본과 복사본의 해시·수정 시간을 재검사합니다.

결과는 `artifacts/module-addition/<실행 ID>/`에 남습니다. `-OutputDirectory`로 위치를 변경할 수 있으며 이전 결과는 삭제하지 않습니다.

- `MODULE-ADDITION-REPORT.json`: 해시, 수신 건수, 연결된 코어, 무결성 결과
- `module-addition.log`: 실행 명령과 빌드 로그

기본 실행의 성공 기준은 소비자 3개가 각각 메시지 4개를 수신하고 코어 변경이 없는 것입니다.
