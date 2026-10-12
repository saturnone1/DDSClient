# DdsAmbassador.Messages.DDSSim

.NET 9용 DDSSim 메시지 패키지입니다. 공통 DdsAmbassador.DDSClient.Core와 RTI 런타임·라이선스가 필요합니다.
상세 문서는 DDSClient 최상위 저장소의 `docs/csharp.md`와 `docs/configuration.md`에서 관리합니다.

```csharp
using DdsAmbassador.DDSClient;
using DdsAmbassador.Messages;
using DdsModules_DDSSim.MSG;

using var client = DdsClient.Connect(new DdsClientOptions
{
    MessageModules = [DDSSimMessages.Module],
    DomainId = 0,
    ParticipantName = "MyService",
    QosProfilesXmlPath = "definitions/qos_profiles.xml",
    Topics = [Topic.Both<TimeTickInformation>()]
});
using var subscription = client.Subscribe<TimeTickInformation>(sample => { });
client.Publish(new TimeTickInformation()); // 실제 Header/payload는 호출자가 설정
```

기본 `Connect()`는 domain 0의 실제 RTI 연결이며, 모듈을 지정하지 않으면 메시지는 등록되지 않습니다.
Discovery는 QoS XML에서 설정하며 DDSSim.xml은 런타임에 필요하지 않습니다.
구독 핸들은 필요한 기간 동안 보관하고, 종료 시 클라이언트를 dispose합니다.
소비 프로젝트의 NuGet feed에는 이 패키지와 RTI 의존 패키지가 모두 있어야 합니다.
RTI 런타임·라이선스 재배포 조건은 별도로 확인하세요.

