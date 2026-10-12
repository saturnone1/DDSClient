# 연결과 망 설정

## 먼저 알아둘 것

- 공개 연결은 실제 RTI DDS를 사용합니다. RTI가 없을 때 모의 전송으로 바뀌지 않습니다.
- 망 하나마다 연결을 만듭니다. 한 앱에 여러 연결을 유지할 수 있습니다.
- 메시지는 빌드된 모듈에서 선택합니다. `topics.xml`과 `dds_client.xml`은 사용하지 않습니다.
- `Connect`가 반환되어도 상대 구독자의 발견이 끝났다는 뜻은 아닙니다.

## 권장: DdsNetwork로 망 정의

~~~csharp
var network = new DdsNetwork(
    "NetworkA", NetworkAMessages.Module, 96,
    "definitions/networks/NetworkA.qos.xml",
    "Network::Participant", "Network::Data");

using var client = DdsClient.Connect(network.CreateClientOptions());
~~~

C++도 같은 구성의 `DdsNetwork`와 `CreateClientOptions()`를 제공합니다.
모듈·Domain·QoS 파일·Participant 프로파일·기본 토픽 프로파일을 망별로 지정합니다.
기본 토픽 QoS는 해당 망의 프로파일을 사용하며, 다른 QoS 라이브러리의 프로파일을 섞으면 거부합니다.

## 세부 옵션

| 옵션 | 역할 | 기본값 |
|---|---|---|
| `MessageModules` | 사용할 메시지 모듈 | 빈 목록 |
| `DomainId` | DDS Domain | 0 |
| `ParticipantName` | 연결 식별 이름 | 미지정 |
| `Topics` | 허용 토픽·방향·QoS | 선택 모듈의 전체 타입 |
| `QosProfilesXmlPath` | QoS 파일 | 실행 위치 주변에서 탐색 |
| `ParticipantQosProfile` | Participant 프로파일 | AmbassadorProfiles::ReliableRealtime |
| `MulticastReceiveAddress` | 선택한 Reader의 수신 주소 변경 | 미지정 |
| `ShutdownTimeout` | 종료 대기 제한 | 10초 |
| `LogLevel` | None / Error / Info / Debug | None |

상대 경로는 작업 디렉터리 기준입니다. 배포 시에는 절대 경로를 권장합니다.
기본 탐색은 작업 디렉터리 자체, 실행 파일 디렉터리와 상위 16단계 순서입니다.
C++ 설치 패키지는 `share/dds_cpp/definitions`도 탐색합니다.

## 토픽 선택

~~~csharp
using var client = DdsClient.Connect(new DdsClientOptions
{
    MessageModules = [DDSSimMessages.Module],
    DomainId = 0,
    QosProfilesXmlPath = "definitions/qos_profiles.xml",
    Topics =
    [
        Topic.Publish<TimeTickInformation>(),
        Topic.Subscribe<WeaponFire>(),
        Topic.Both<SimulatorStatus>()
    ]
});
~~~

| Topics 설정 | 동작 |
|---|---|
| C# null / C++ std::nullopt | 모듈의 전체 타입을 송수신용으로 등록 |
| 빈 목록 | 사용할 메시지 없음 |
| 명시 목록 | 나열한 토픽만 허용 |

토픽 이름을 바꾸려면 `Topic.Named<T>("Clock")` / `Topic::Named<T>("Clock")`을 사용합니다.
같은 타입을 여러 토픽에 등록했다면 송수신할 때 토픽 이름을 지정하세요.

QoS 인수를 생략하면 `DdsNetwork`의 기본 프로파일을 사용합니다.
저수준 `DdsClientOptions`에서는 `ReliableRealtime`을 사용합니다.
명시적으로 지정한 프로파일은 그대로 유지합니다.

중복 토픽·미등록 타입·없는 QoS·잘못된 방향은 거부합니다.
연결 후 옵션 목록을 수정해도 기존 연결은 바뀌지 않습니다.
Writer/Reader는 실제 발행·구독 API를 호출할 때 생성됩니다.

## Discovery와 물리적 망

NIC 허용 목록, 상대 주소, Discovery 멀티캐스트, UDP/공유 메모리 선택은
**각 망의 Participant QoS**에서 설정합니다. `InitialPeers` API는 없습니다.

아래는 로컬 유니캐스트 예입니다. 실제 배포 주소로 바꿔 사용하세요.

~~~xml
<domain_participant_qos>
  <discovery>
    <initial_peers>
      <element>builtin.udpv4://127.0.0.1</element>
    </initial_peers>
    <multicast_receive_addresses/>
  </discovery>
</domain_participant_qos>
~~~

Domain이나 수신 멀티캐스트 주소만 다르게 지정해도 물리적 망이 격리되는 것은 아닙니다.
Pod의 NIC·라우팅·방화벽도 구성해야 합니다. NetworkA/B 예제는 루프백 테스트용입니다.

`MulticastReceiveAddress`는 선택한 Reader QoS의 수신 주소 설정이 정확히 하나일 때만 적용됩니다.
원본 XML과 다른 프로파일은 수정하지 않습니다.

## 전달과 종료 주의사항

- 기본 QoS는 RELIABLE / VOLATILE / KEEP_ALL입니다. 늦게 연결한 구독자에게 과거 메시지를 재생하지 않습니다.
- KEEP_ALL의 메모리 상한 정책은 별도로 설계해야 합니다.
- 송신 전 필요한 구독자 수를 기다리고, 송신 후 DDS ACK를 확인하세요.
- ACK는 앱 처리 완료가 아닙니다. 처리 완료 보장이 필요하면 메시지 ID와 응답 규약을 추가하세요.
- 종료 시간 초과는 콜백 강제 중단이 아닙니다. 실행 중인 콜백이 쓰는 자원을 즉시 해제하지 마세요.

## 환경변수와 이전 API

라이브러리는 연결 옵션을 받습니다. 환경변수 해석은 앱/CLI의 책임입니다.
CLI는 `DDS_DOMAIN_ID`, `DDS_PARTICIPANT_NAME`, `DDS_LOG_LEVEL`,
`DDS_QOS_PROFILES_XML_PATH`, 멀티캐스트 및 종료 제한 환경변수를 읽습니다.
명령행 인수가 우선합니다.

| 이전 설정 | 현재 방식 |
|---|---|
| UseRtiTransport / --transport | 제거. 항상 실제 RTI |
| InitialPeers / --peer | Participant QoS |
| DdsSimXmlPath / --types | 빌드된 메시지 모듈 |
| FromEnvironment | 앱/CLI에서 옵션 구성 |
| CreateSubscriber | Subscribe |
| C++ Dispose / close | Close 또는 소멸자 |
| topics.xml / dds_client.xml / --config | 코드 등록 |

이전 API/ABI에서 변경한 앱은 코어·모듈·앱을 함께 다시 빌드하세요.
이후 동일 코어 계약으로 만든 추가 모듈은 기존 코어를 유지하고 연결할 수 있습니다.
