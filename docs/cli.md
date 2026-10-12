# CLI로 송수신 확인

CLI는 **DDSSim 메시지용 수동 테스트 도구**입니다. 임의 모듈 자동 탐색기는 아닙니다.
소스는 `cli/csharp`, `cli/cpp`에 있으며 Windows 기본 빌드에 포함됩니다.

## 로컬 실행

~~~powershell
dotnet run --project cli/csharp/DdsAmbassador.DDSClient.Cli.csproj -- list
.\DDSCPP\build\Release\ddsclient.exe list
~~~

`list`는 Participant를 만들지 않습니다.
연결을 유지하면서 여러 명령을 실행하려면 `shell`을 사용하세요.

| 명령 | 역할 |
|---|---|
| list | 등록 토픽 목록 |
| status | 현재 연결 상태 |
| subscribe / listen | 수신 시작 |
| publish / send | 발행 |
| unsubscribe / unsub | 구독 해제 |
| help | 도움말 |
| exit | 프로세스 종료 |

~~~text
subscribe TimeTickInformation
publish TimeTickInformation
publish SetSimulation --json /tmp/set-simulation.json
unsubscribe all
~~~

## 여러 구독자에게 보내기

~~~text
ddsclient subscribe TimeTickInformation --count 4 --timeout-ms 20000
ddsclient publish TimeTickInformation --repeat 4
~~~

C#·C++ CLI 모두 같은 옵션을 사용합니다.

구독 명령과 발행 명령은 서로 다른 터미널에서 실행합니다. 현재 VOLATILE 정책에서는 발행 시점에 아직 발견되지 않은 Reader에게 과거 메시지를 재전송하지 않습니다.

- 기본 발행은 구독자·ACK 대기 없이 Write를 호출합니다.
- 기존 매칭 Reader의 DDS ACK를 확인한 뒤 종료하려면 `--wait-for-acks`를 명시합니다. 제한 시간은 `--wait-timeout-ms`로 지정합니다.
- 단발 CLI를 ACK 확인 없이 종료하면 종료 이후의 재전송은 보장되지 않습니다. 장기 실행 앱의 신뢰성 QoS는 그대로 유지됩니다.
- `--wait-for-subscribers`는 기본 0(대기 없음)입니다. 진단·동기화 작업에서 명시적으로 양수를 지정할 때만 대기합니다.
- `--count` 수신 완료는 종료 코드 0, 제한시간 초과는 1입니다.
- ACK는 DDS 수신 확인이며 UI 표시·핸들러 처리 완료 확인이 아닙니다.
- 단독 publish/subscribe 명령은 실행할 때마다 새 연결을 만듭니다.

## 연결 설정

| 명령행 | 환경변수 |
|---|---|
| --domain | DDS_DOMAIN_ID |
| --participant | DDS_PARTICIPANT_NAME |
| --qos | DDS_QOS_PROFILES_XML_PATH |
| 로그 설정 | DDS_LOG_LEVEL |

명령행 인수가 환경변수보다 우선합니다.
`--transport`, `--peer`, `--types`, `--config`는 제거되었습니다.
상대 주소와 Discovery 설정은 [QoS 파일](configuration.md)에서 지정합니다.

## Docker·Kubernetes

이미지 생성 명령은 저장소 루트에서 실행합니다.

~~~powershell
docker build -f cli/csharp/Dockerfile -t ddsclient:local .
~~~

Linux 코드 생성기가 없고 생성 코드를 이미 갱신했다면
`--build-arg SKIP_DDSGEN=true`를 추가할 수 있습니다.
원격 클러스터에서는 이미지를 사설 저장소에 올리고
[배포 YAML](../cli/k8s-ddsclient.yaml)의 이미지 주소를 바꾸세요.

~~~powershell
kubectl create namespace dds-test
kubectl -n dds-test create configmap ddsclient-qos --from-file=qos_profiles.xml=definitions/qos_profiles.xml
kubectl apply -f cli/k8s-ddsclient.yaml
kubectl -n dds-test get pods
kubectl -n dds-test attach -it deploy/ddsclient-cli
~~~

Pod의 기본 실행 모드는 shell입니다. `attach`로 연결해야 기존 Participant에서 명령을 실행합니다.
`kubectl exec ... publish`는 별도 프로세스와 Participant를 만듭니다.
`exit`를 입력하면 Pod가 재시작될 수 있습니다.

QoS는 `/app/definitions/qos_profiles.xml`에 마운트합니다.
ConfigMap 수정 후 새 설정을 반영하려면 Pod를 재시작하세요.
RTI 실행 환경·라이선스와 실제 네트워크 경로는 배포 환경에서 별도로 준비해야 합니다.
