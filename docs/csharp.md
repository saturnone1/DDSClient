# C# 사용법

.NET 9와 RTI Connext DDS 실행 환경·라이선스가 필요합니다.

## 1. 패키지 연결

앱에서 다음 로컬 NuGet 저장소를 등록합니다.

- `DDS_Nuget/artifacts/packages`: 코어와 메시지 패키지
- `offline-tools/nuget/rti`: RTI 의존 패키지
- `offline-tools/nuget/third-party`: 기타 의존 패키지

~~~powershell
dotnet add package DdsAmbassador.Messages.DDSSim --version 0.1.0
~~~

`DdsAmbassador.Messages.DDSSim`은 DDSSim 메시지 패키지이며 `DdsAmbassador.DDSClient.Core`에 의존합니다.
Telemetry는 `DdsAmbassador.Messages.Telemetry`를 추가합니다.
앱 배포 방식에 따라 .NET 실행 환경 패키지도 필요합니다.

## 2. 송수신

~~~csharp
using DdsAmbassador.DDSClient;
using DdsAmbassador.Messages;
using DdsModules_DDSSim.MSG;
using DdsModules_DDSSim.ENUM;

using var client = DdsClient.Connect(new DdsClientOptions
{
    MessageModules = [DDSSimMessages.Module],
    DomainId = 0,
    QosProfilesXmlPath = "definitions/qos_profiles.xml",
    Topics = [Topic.Both<TimeTickInformation>()]
});

using var subscription = client.Subscribe<TimeTickInformation>(sample =>
{
    Console.WriteLine(sample.TimeTickMessage.TimeTick);
});

var publisher = client.CreatePublisher<TimeTickInformation>();
var message = new TimeTickInformation();
message.Header.MsgID = MessageID.TimeTickInformation;
message.Header.SrcSimID = SimulatorID.TCC;
message.Header.DstSimID = SimulatorID.TDS;
message.Header.TimeStamp = (ulong)DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
message.TimeTickMessage.TimeTick = 1;

publisher.Publish(message);
publisher.WaitForAcknowledgments(TimeSpan.FromSeconds(10));
~~~

헤더와 업무 데이터는 앱이 설정합니다. 실제 서비스에서는 필요한 기간 동안 연결과 구독을 유지하세요.
예제의 구독자 수 1에는 같은 연결의 Reader도 포함됩니다. 상대 구독자가 3개라면 실제 필요한 수를 지정하세요.

## 자주 쓰는 API

| API | 용도 |
|---|---|
| `DdsClient.Connect(options)` | 연결 생성 |
| `CreatePublisher<T>(topicName)` | 반복 발행용 객체 |
| `Publish(sample, topicName)` | 단건 발행 |
| `Subscribe<T>(handler, topicName, onError)` | 구독과 오류 관찰 |
| `SubscribeBorrowed<T>(handler, topicName, onError)` | 콜백 안에서만 처리하는 무복사 수신. 보관·수정 금지 |
| `Options / Configuration` | 연결 옵션·등록 정보 조회 |
| `IsOpen` | 신규 작업을 허용하는 로컬 연결 상태 |
| `ObserveSubscriptionErrors(handler)` | 기존 관찰자를 유지하며 추가. 반환 핸들 Dispose 시 해제 |
| `Close()` | 종료 요청과 제한시간 대기. 실패는 상태에 보존 |
| `Dispose()` | 종료 요청과 제한시간 대기 |
| `WaitForShutdown(timeout)` | 실제 정리 완료 대기 |

선택 인수는 생략할 수 있습니다. 방향은 `Topic.Publish<T>()`, `Subscribe<T>()`, `Both<T>()`로 등록합니다.

반복 발행은 `CreatePublisher`의 반환 객체를 재사용하세요. Writer를 바인딩하여 매번 캐시 잠금을 잡지 않습니다.
일반 `Subscribe`는 독립 복사본을 전달합니다. `SubscribeBorrowed`는 JSON 변환 등 콜백 안에서 처리를 끝낼 때만 사용하며,
샘플 또는 그 내부 배열·시퀀스를 저장하거나 수정하면 안 됩니다. 나중에 사용할 데이터는 콜백 안에서 복사해야 합니다.
망별 설정은 [연결 설정](configuration.md)을 참고하세요.

## 오류 확인

~~~csharp
client.SubscriptionError += error =>
    Console.Error.WriteLine(
        $"구독 {error.SubscriptionId}, 토픽 {error.TopicName}, 치명적 오류={error.IsFatal}: {error.Exception}");

var lastError = client.LastSubscriptionError;
~~~

- 오류 알림은 `LogLevel=None`에서도 동작합니다.
- `IsFatal=false`: 사용자 핸들러 오류. 이후 수신은 계속됩니다.
- `IsFatal=true`: 해당 수신 루프 종료. 구독을 해제하고 재생성해야 합니다.
- 연결 전체 이벤트 외에 구독의 `onError`로 생성 직후 오류부터 관찰할 수 있습니다.
- 오류 콜백도 수신 스레드에서 실행됩니다. 오래 대기하지 마세요.

## 안전하게 사용하기

| 항목 | 지킬 것 |
|---|---|
| 연결 수명 | 메시지마다 연결을 재생성하지 말고 서비스 동안 재사용 |
| 구독 수명 | 반환된 IDisposable을 보관하고 해제 |
| 수신 데이터 | 독립 복사본이므로 콜백 이후 보관 가능. 동시 수정은 앱에서 동기화 |
| 무거운 처리 | 콜백에서 대기하지 말고 작업 큐로 전달 |
| 첫 송신 | 구독자 대기 없이 발행. 발견 이전 데이터는 VOLATILE 정책상 이후 재전송되지 않음 |
| 송신 후 종료 | `WaitForAcknowledgments` 확인. 업무 처리 완료와는 다름 |
| 재연결 | 기존 연결을 종료한 뒤 새 연결 생성 |

종료 제한은 연결의 `ShutdownTimeout`으로 설정합니다.
시간 초과 후에도 백그라운드 정리는 계속되며 실행 중인 콜백을 강제로 중단하지 않습니다.
정리 실패는 완료 대기 호출자에게 전달됩니다. 복수 실패는 AggregateException에 보존됩니다.

구성 오류는 `DdsConfigurationException`, 작업 위반은 `DdsOperationException`,
종료 후 사용은 `ObjectDisposedException`입니다. 파일·XML·RTI 오류도 발생할 수 있습니다.
Debug 로그에는 메시지 내용이 포함될 수 있습니다.

기본 VOLATILE QoS는 늦게 연결한 구독자에게 과거 메시지를 재생하지 않습니다.
전달 계약과 종료 상태는 [설계 요약](architecture.md)을 참고하세요.
