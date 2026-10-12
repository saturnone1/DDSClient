#!/usr/bin/env bash
set -euo pipefail
export LANG=C.UTF-8
export PYTHONIOENCODING=utf-8
export DOTNET_CLI_UI_LANGUAGE=ko-KR
# 소스는 읽기 전용으로 마운트하고 생성물과 NuGet 캐시는 컨테이너 내부에 둔다.
root=$(mktemp -d /tmp/ddsclient-csharp-XXXXXX)
tar -C /workspace --exclude=build --exclude='build-*' --exclude=bin --exclude=obj --exclude=artifacts \
    -cf - DDS_Nuget definitions global.json | tar -C "$root" -xf -
ln -s /workspace/offline-tools "$root/offline-tools"
cd "$root"
dotnet restore DDS_Nuget/tests/DdsAmbassador.DDSClient.Tests.csproj \
    --configfile DDS_Nuget/NuGet.config --packages "$root/packages"
dotnet test DDS_Nuget/tests/DdsAmbassador.DDSClient.Tests.csproj -c Release --no-restore \
    --logger 'trx;LogFileName=csharp.trx' --results-directory /out --blame-hang-timeout 90s
# 라이선스나 네이티브 런타임이 없으면 실제 RTI 검증은 건너뛰기로 성공 처리하지 않는다.
python3 -c 'import xml.etree.ElementTree as E; r=E.parse("/out/csharp.trx").getroot(); c=r.find(".//{*}Counters"); assert c is not None and int(c.get("passed")) == int(c.get("total")), E.tostring(c)'
