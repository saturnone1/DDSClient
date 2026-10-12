# C++ 사용법

C++20, RTI Connext DDS 7.3.1 개발·실행 라이브러리와 라이선스가 필요합니다.

## 1. 코어와 메시지 모듈 연결

소스와 함께 빌드하는 예:

~~~cmake
cmake_minimum_required(VERSION 3.20)
project(MyDdsApp LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(DDSCPP_RTI_HOME "C:/Program Files/rti_connext_dds-7.3.1" CACHE PATH "")
add_subdirectory(../DDSClient/DDSCPP DDSCPP-build)
add_executable(my_app main.cpp)
target_link_libraries(my_app PRIVATE dds_cpp_shared dds_module_DDSSim)
~~~

- 정적 코어는 `dds_cpp_static`, DDSSim 모듈은 `dds_module_DDSSim`입니다.
- 설치 패키지는 `find_package(DDSClient CONFIG REQUIRED)`로 찾습니다.
- 설치 타깃 `DDSClient::DDSSim`, `DDSClient::Telemetry`는 코어 연결을 포함합니다.
- 패키지 경로는 `CMAKE_PREFIX_PATH`, RTI 경로는 `DDSClient_RTI_HOME`으로 지정합니다.
- 예제 프로젝트는 `DDSCPP/tests/consumer`에 있습니다.

Windows는 DLL·링크용 LIB·정적 LIB, Linux는 SO·A를 제공합니다.
정적 링크도 RTI 의존성을 제거하지는 않습니다.
Linux에서는 RTI 실행 라이브러리 경로를 동적 로더에 등록해야 합니다.

## 2. 송수신

~~~cpp
#include <dds_cpp/DdsCpp.hpp>
#include <DDSSimMessages.hpp>
#include <iostream>
namespace MSG = DdsModules_DDSSim::MSG;

dds_cpp::DdsClientOptions options;
options.MessageModules() = {dds_cpp::DDSSimMessages()};
options.DomainId() = 0;
options.Topics() = std::vector<dds_cpp::TopicDefinition>{
    dds_cpp::Topic::Both<MSG::TimeTickInformation>()};

auto client = dds_cpp::DdsClient::Connect(options);
auto subscription = client.Subscribe<MSG::TimeTickInformation>(
    [](const MSG::TimeTickInformation& sample) {
        std::cout << sample.TimeTickMessage().TimeTick() << '\n';
    });

auto publisher = client.CreatePublisher<MSG::TimeTickInformation>();
MSG::TimeTickInformation sample;
sample.Header().MsgID(ENUM::MessageID::TimeTickInformation);
sample.Header().SrcSimID(ENUM::SimulatorID::TCC);
sample.Header().DstSimID(ENUM::SimulatorID::TDS);
sample.TimeTickMessage().TimeTick(1);
publisher.Publish(sample);
publisher.WaitForAcknowledgments(std::chrono::seconds(10));
~~~

타임스탬프와 나머지 업무 데이터도 앱에서 설정하세요.
실제 서비스에서는 필요한 기간 동안 연결·구독·프로세스를 유지합니다.

## 자주 쓰는 API

| API | 역할 |
|---|---|
| `DdsClient::Connect(options)` | 연결 생성 |
| `CreatePublisher<T>()` | 반복 발행용 객체 |
| `Publish(sample)` | 발행 |
| `Subscribe<T>(handler)` | 구독 생성 |
| `Subscribe<T>(handler, topicName, onError)` | 수신 시작 전 구독별 오류 관찰자 등록 |
| `ObserveSubscriptionErrors(handler)` | 기존 관찰자를 유지하며 추가. 반환 핸들 파괴 시 해제 |
| `Configuration().Topics()/GetTopic()/TryGetTopic()` | 등록 정보 조회 |
| `Options()` | 옵션 읽기 전용 참조 |
| `IsOpen()` | 로컬 연결 수명 상태. 상대 발견 여부가 아님 |
| `Close()` | 종료 요청과 제한시간 대기 |
| `WaitForShutdown(timeout)` | 실제 정리 완료 대기 |

연결은 복사할 수 없으며 이동할 수 있습니다. 다른 작업 중인 연결을 동시에 이동·대입하지 마세요.
같은 타입을 여러 토픽에 등록했다면 송수신할 때 이름을 지정하세요.

## 수명과 오류

- 구독은 `subscription.reset()` 또는 스코프 종료로 해제합니다.
- 콜백의 `const T&`는 콜백 밖에 보관하지 마세요. 큐로 넘길 때 메시지를 복사합니다.
- 콜백은 구독별 작업자에서 순차 실행됩니다. 무거운 처리는 별도 큐로 넘기세요.
- `SetSubscriptionErrorHandler`와 `LastSubscriptionError()`로 오류를 확인합니다.
- `SubscriptionId`는 같은 토픽의 여러 구독을 구분합니다. 재구독하면 새 ID가 생깁니다.
- 구성 오류는 `DdsConfigurationException`, 작업 오류는 `DdsOperationException`입니다.
- RTI·표준 라이브러리 예외도 발생할 수 있습니다.

`Close()`는 모든 구독자에게 먼저 정지를 요청한 뒤 공통 마감 시각까지 기다립니다.
기본 제한은 10초이며 연결의 `ShutdownTimeout()`으로 지정합니다.
콜백 안에서 종료하면 자기 콜백이 끝나기를 기다리지 않고 비동기 정리합니다.

시간 초과는 강제 취소가 아닙니다. 백그라운드 작업이 RTI 자원을 계속 소유하므로
실행 중인 핸들러가 사용하는 앱 자원을 즉시 해제하지 마세요.

## 전달 확인과 망 추가

발행 전에 구독자를 기다릴 필요는 없습니다. VOLATILE 정책에서는 나중에 발견된 Reader에게 이전 샘플을 재전송하지 않습니다.
`WaitForSubscribers`는 명시적으로 준비 상태를 확인하려는 진단용 API이며 발행의 필수 단계가 아닙니다.
Reader 수에는 자기 프로세스의 구독도 포함됩니다. ACK는 UI·업무 처리 완료 확인이 아닙니다.
수신 콜백 안에서 ACK를 기다리지 마세요.

새 메시지 모듈은 같은 컴파일러·코어 API/ABI·RTI 버전으로 빌드해 링크합니다.
실행 중 라이브러리 교체·언로드는 지원하지 않습니다.
망 설정은 [연결 설정](configuration.md), 생성·설치는 [빌드 안내](build.md)를 참고하세요.
