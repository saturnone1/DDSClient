# 설계 요약

## 구성

소스 폴더의 역할은 다음과 같습니다.

~~~text
definitions/                  XML 입력
DDS_Nuget/core/               사람이 관리하는 C# Core
  api/                        공개 타입·클라이언트 API
  configuration/              설정·QoS 해석
  transport/                  RTI 전송·수명 관리
  diagnostics/                로그
  testing/                    기존 내부 테스트 지원 구현
DDSCPP/core/include/dds_cpp/  C++ 공개 헤더(사용자 include 이름 유지)
DDSCPP/core/src/              API·설정·전송·내부 지원 구현
DDS_Nuget/generated/<XML>/    자동 생성 C# 타입·등록부·프로젝트·스탬프
DDSCPP/generated/<XML>/       자동 생성 C++ 타입·등록부·스탬프
build/                       언어별 컴파일 캐시·중간 파일
artifacts/                   언어별 또는 루트 배포 산출물
cli/                         선택적으로 빌드하는 소비자
docs/                        수동 문서
~~~

`generated/` 안에는 수동 소스를 두지 않습니다. 내부 `Generated/` 하위 폴더도 없으며, XML 한 개의 생성물은 같은 폴더에서 관리합니다.
Git에서는 생성물을 제외하지만 폐쇄망 소스 번들에는 현재 생성물을 포함할 수 있습니다.

| 구성요소 | 책임 |
|---|---|
| 공통 코어 | 연결·발행·구독·오류 통지·종료 |
| 메시지 모듈 | XML에서 생성한 타입과 등록 정보 |
| DdsNetwork | 사용할 모듈·Domain·QoS 파일·프로파일 묶음 |
| 애플리케이션 | 망별 연결 생성, 토픽 선택, 수신 데이터 처리 |
| CLI | 라이브러리를 사용하는 수동 통신 도구 |

코어는 특정 메시지에 의존하지 않습니다.
DDSSim·Telemetry·NetworkA·NetworkB 모두 `generated/<XML 이름>`에 생성되는 동등한 모듈입니다. 타입·등록부·프로젝트·스탬프는 모두 자동 생성물이므로 별도 `modules/Generated` 구분 없이 같은 폴더에 둡니다.
일반 라이브러리 빌드·검증·패키징도 특정 메시지 XML을 필수로 요구하지 않습니다. CLI·테스트·Signal Forge는 각각 명시적으로 선택한 모듈에 의존하는 소비자입니다.
Signal Forge의 기본 모듈 목록은 생성된 `generated/BuiltModules.props`를 사용하며, 별도 선택 파일로 사용할 모듈을 제한할 수 있습니다.
모듈 생성은 잠금 아래 임시 출력에서 타입·등록부·프로젝트·스탬프를 준비한 뒤 게시합니다. 실패 시 이전 파일을 복원하며, 복원 자체가 실패하면 원본 백업을 남깁니다.
새 XML을 빌드해 만든 모듈은 **동일한 코어 API/ABI·RTI 환경**이면 기존 코어를 유지하고 추가할 수 있습니다.
앱이 새 타입을 직접 사용하면 앱도 다시 빌드해야 합니다. 실행 중 DLL/so 교체·언로드는 지원하지 않습니다.

## 빌드와 실행의 차이

- 빌드: `definitions/*.xml` → RTI 코드 생성 → 언어별 타입·등록부 → 메시지 패키지.
- 실행: 앱의 설정 → 망별 `DdsClient` → RTI Participant → Writer/Reader.
- 메시지 XML은 빌드 입력입니다. 실행 중 새 타입을 만드는 설정 파일이 아닙니다.
- 실행 시 XML은 QoS 설정만 필요합니다. `topics.xml`과 `dds_client.xml`은 사용하지 않습니다.

## 다중 망 격리

독립 XML에는 `DdsModules_<파일명>` 네임스페이스를 붙입니다.
같은 구조체·토픽 이름도 다른 모듈과 연결에서는 사용할 수 있습니다.
같은 연결의 토픽 이름은 유일해야 하며, 같은 Domain에서 통신하는 토픽은 타입과 QoS가 호환되어야 합니다.

각 연결은 모듈·Domain·QoS 제공자·프로파일·수신 주소·종료 제한을 소유합니다.
Domain 구분만으로 물리적 망이 격리되지는 않습니다.
NIC·라우팅·방화벽과 Participant QoS의 인터페이스·Discovery 설정을 함께 구성하세요.
NetworkA/B 예제는 로컬 루프백 테스트용입니다.

## C#·C++ 대응

| C# | C++ | 역할 |
|---|---|---|
| `DdsClient.Connect(options)` | `DdsClient::Connect(options)` | 연결 생성 |
| `Topic.Publish/Subscribe/Both<T>()` | `Topic::Publish/Subscribe/Both<T>()` | 토픽 방향 등록 |
| `CreatePublisher<T>()` | `CreatePublisher<T>()` | 반복 발행용 객체 |
| `Subscribe<T>()` | `Subscribe<T>()` | 구독 생성 |
| `IDisposable` | `unique_ptr<Subscription>` | 구독 수명 |
| `Dispose()/using` | `Close()/소멸자` | 종료 |
| `SubscriptionError` | `SetSubscriptionErrorHandler` | 오류 관찰 |
| `LastSubscriptionError` | `LastSubscriptionError()` | 최근 오류 조회 |

## 수신과 종료에서 보장하는 것

- RTI 알림과 사용자 처리를 분리합니다. 구독별 작업자가 순서대로 콜백을 실행합니다.
- C# 콜백은 독립 복사본을 받습니다. C++ 콜백의 참조는 콜백 밖으로 넘길 때 복사해야 합니다.
- 핸들러 예외와 치명적 수신 오류를 구분하며 오류 관찰자의 예외는 격리합니다.
- 구독 ID로 같은 토픽의 여러 구독을 구분합니다. 재구독 시 새 ID가 생깁니다.
- 종료 정리는 백그라운드에서 진행합니다. 시간 초과는 호출자의 대기를 끝낼 뿐 콜백을 강제 중단하지 않습니다.
- 정리 실패는 `Faulted`와 오류로 알립니다. 정리가 끝나기 전에 자원을 해제했다고 보고하지 않습니다.
- 구독자 수 대기는 현재 매칭된 Reader 수를 확인합니다. 이후의 연결 끊김까지 방지하지 않습니다.
- DDS ACK는 수신 확인이지 UI 표시나 업무 처리 완료 확인이 아닙니다.

종료 상태는 `Open → Closing → Closed`이며 정리 실패 시 `Faulted`입니다.
`WaitForShutdown(timeout)`은 미시작·시간 초과에 false, 정리 실패에 예외를 반환합니다.
자기 수신 콜백에서는 종료 완료를 기다리지 않습니다.

C++ 최종 네이티브 정리도 앱 스레드와 분리합니다.
정리 스레드를 생성하지 못한 예외 상황에서는 자원을 프로세스 종료까지 보유할 수 있으므로 운영 조치가 필요합니다.

## 내부 구현 위치

| 구성요소 | 역할 |
|---|---|
| C# `SubscriptionDispatcher<T>` | 수신 루프·콜백·종료 대기 |
| C# `RtiSubscriptionSource<T>` | Reader·WaitSet·대여 버퍼·메시지 복사 |
| C# `BackgroundCleanupTask` | 한 번만 시작하는 정리와 완료·실패 상태 |
| C++ `transport/SubscriptionDispatcher.hpp` | 수신 실행·콜백·종료 대기 |
| C++ `transport/RtiSubscriptionSource.hpp` | Reader·Topic·대여 샘플의 수명 |
| C++ `RtiTransportResources.hpp` | Participant·QoS·Publisher·Subscriber 소유 |
| C++ `RtiDdsTransport.cpp` | 타입별 캐시·전체 종료 |
| `tools/codegen/` | XML 탐색·격리·등록부·계약 생성 |

내부 InMemory 전송은 단위 테스트용이며 실제 RTI 통신의 대체 검증이 아닙니다.
C#의 RTI 실행 환경 공유 참조는 마지막 연결의 실제 정리까지 유지됩니다.

## C#·C++ 대응 규칙

관리 소스의 파일명은 `DdsClient`, `DdsNetwork`, `DdsMessageModule`, `RtiWriter`처럼 역할·클래스 이름에 맞춥니다.
C++의 공개 선언은 `core/include/dds_cpp`, 구현은 C#과 같은 `api`·`configuration`·`transport`·`testing`으로 나눕니다.
양쪽 모두 `api`·`configuration`·`transport`·`diagnostics`·`testing`의 같은 역할 구분을 사용합니다.
C++은 헤더를 `core/include/dds_cpp/<역할>`, 비템플릿 구현을 `core/src/<역할>`에 둡니다.
C#은 선언과 구현을 같은 `.cs` 파일에 둘 수 있으므로 `core/<역할>`에 둡니다.
구형 소문자 Core 호환 헤더와 한 줄짜리 예외 구현 파일은 `artifacts/archive/20261007-parity-cleanup`으로 옮겼습니다.
구형 include 대신 역할별 정식 경로를 사용하세요. 예: `dds_cpp/api/DdsClient.hpp`, `dds_cpp/configuration/DdsNetwork.hpp`.
전체 API는 `dds_cpp/DdsCpp.hpp`로 포함할 수 있습니다. 테스트 전용 헤더는 설치 패키지에서 제외합니다.

| 계약 | 공통 동작 |
|---|---|
| `Topic.Both/Publish/Subscribe` | 기본 이름은 선택 모듈의 타입 등록 이름으로 결정 |
| `DdsNetwork.CreateClientOptions` | 전체 타입·빈 목록 선택, 망별 QoS·멀티캐스트·종료 시간 반영 |
| `ObserveSubscriptionErrors` | 관찰자를 추가하고 해제 핸들을 반환. 기존 관찰자를 교체하지 않음 |
| 구독별 오류 콜백 | Reader 수신 시작 전에 등록하며 다른 관찰자와 독립적으로 호출 |
| `Close` | 신규 작업 차단·제한 시간 대기·종료 실패 보존 |
| `WaitForShutdown` | 완료는 true, 시간 초과·자기 대기는 false, 정리 실패는 예외 전달 |

구독자·ACK 대기 시간 초과는 양쪽 모두 `DdsTimeoutException`으로 전달합니다.
C#은 기존 `TimeoutException`, C++은 기존 `DdsOperationException` catch와 호환됩니다.
개별 구독의 네이티브 정리 실패는 연결 전체를 `Faulted`로 만들고 신규 발행·구독을 차단합니다.
사용 중이거나 정리에 실패한 네이티브 객체는 강제 파괴하지 않습니다.
C# 구독 생성 실패의 부분 자원 정리는 부모 종료 작업이 추적하며, 호출 스레드에서 네이티브 해제를 기다리지 않습니다.
C++ 스레드 분리 실패의 핸들은 Core 회수 소유자가 추적하고 종료 후 비동기로 join·해제합니다.
수신 콜백 격리 때문에 전용 수신 스레드 수 자체는 유지합니다. 스레드 풀 통합은 이번 변경에 포함하지 않습니다.

C#의 기존 `Dispose` 예외 전달과 C++의 비예외 소멸자는 언어별 호환 계약으로 유지합니다.
C#은 샘플 복사본을 전달하며 C++은 콜백 동안 유효한 참조를 전달합니다. C++에서 외부 보관할 때는 복사해야 합니다.
고빈도 즉시 처리에는 양쪽 모두 `SubscribeBorrowed`를 제공합니다. C# 일반 구독의 복사본 계약은 바꾸지 않습니다.
Signal Forge는 대여 콜백 안에서 JSON 문자열을 완성하여 원본 샘플을 외부에 보관하지 않습니다.
발행 핸들은 Writer를 미리 바인딩하며, C# 원자적 진행 작업 수와 C++ 작업 중 공유 소유권으로 동시 종료를 보호합니다.
C# 수신 스레드는 유휴 폴링을 기본 500ms에서 5초로 줄이고, 정상 종료는 GuardCondition으로 즉시 깨웁니다.
신호 실패 대비 제한 대기는 유지합니다. 전용 수신 스레드는 느린 콜백이 다른 구독을 막지 않도록 유지합니다.
C++ 설정값 타입은 C# record와 달리 값으로 수정할 수 있지만 연결 생성 시 스냅샷으로 분리합니다.
QoS의 정책 해석은 각 언어의 RTI SDK를 사용하므로 구현 문법까지 억지로 통일하지 않습니다.
내부 구조·헤더가 변경된 릴리스에서는 Core·메시지 모듈·소비 앱을 함께 다시 빌드하세요. 기존 바이너리 ABI 호환성을 보장하지 않습니다.

## Signal Forge 연결

Signal Forge는 **빌드된 메시지 모듈만** 사용합니다. 실행 중 임의 XML 업로드로 타입을 만들지 않습니다.

1. DDSClient 빌드가 `signal-forge-modules.props`를 생성합니다.
2. 앱의 `DdsModuleSelectionFile`에서 선택 파일을 지정합니다.
3. 앱 빌드 시 참조·리소스·등록부를 생성하고 XML 존재 여부와 모듈 이름을 검사합니다. 생성 지문 파일의 중복 검사는 하지 않습니다.
4. 실행 시에도 모듈의 스키마 해시를 확인합니다.

스키마 해시는 BOM과 줄바꿈 차이를 제외한 XML 텍스트 기준입니다.
다른 PC로 옮길 때는 절대 경로가 남은 선택 파일을 재사용하지 말고 해당 소스 트리에서 다시 생성하세요.

세션은 연결 생성·호스트·종료 작업을 함께 소유합니다.
종료 중 새 생성을 차단하고, 뒤늦게 생성된 호스트도 회수합니다.
치명적 수신 오류는 해당 구독에 표시하며 자동 재구독·과거 메시지 재생은 하지 않습니다.

## 검증 범위

정적 검사는 스키마·등록부·심볼을 확인합니다. 통신 동작은 실제 RTI 테스트가 확인합니다.
다중 망 테스트는 각 망의 구독자 3개에 메시지 4개씩 발행하고 재연결 후 다시 검증합니다.
로컬 UDP 테스트 결과가 서로 다른 NIC·서브넷·Pod 환경까지 보장하지는 않습니다.

구체적인 명령은 [빌드 안내](build.md), 설정은 [연결 설정](configuration.md)을 참고하세요.
