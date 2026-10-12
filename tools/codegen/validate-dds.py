#!/usr/bin/env python3
"""모듈 목록 기반 정적 검증. 특정 메시지 XML·QoS 이름·CLI에 의존하지 않는다."""
import argparse
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from schema_modules import discover, schema


def source_text(paths, root):
    ignored = {"bin", "obj", "build", "artifacts"}
    return "\n".join(path.read_text(encoding="utf-8", errors="ignore")
                     for path in paths if path.is_file()
                     and not ignored.intersection(path.relative_to(root).parts))


def main():
    workspace = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--definitions", type=Path, default=workspace / "definitions")
    parser.add_argument("--csharp-modules", type=Path, default=workspace / "DDS_Nuget/generated")
    parser.add_argument("--cpp-root", type=Path, default=workspace / "DDSCPP")
    parser.add_argument("--cpp-registry", type=Path)
    parser.add_argument("--require-cpp-generated", action="store_true")
    # 이전 CLI 호출의 명시적 선택 인수만 호환한다. 기본 XML은 지정하지 않는다.
    parser.add_argument("--dds-sim", type=Path)
    parser.add_argument("--generated", type=Path)
    args = parser.parse_args()
    try:
        inputs = [args.dds_sim] if args.dds_sim else discover(args.definitions)
        for xml in inputs:
            entries = schema(xml)
            if entries is None:
                raise ValueError(f"메시지 XML이 아닙니다: {xml}")
            name = xml.stem
            module = args.csharp_modules / name
            generated = args.generated if args.generated and args.dds_sim else module / (name + ".cs")
            required = [generated, module / f"DdsAmbassador.Messages.{name}.csproj",
                        module / f"{name}Messages.cs", module / "ModuleContract.g.cs"]
            for path in required:
                if not path.is_file():
                    raise ValueError(f"모듈 생성물이 없습니다: {path}")
            # XML 지문은 생성기가 검증한다. 여기서는 필수 생성물과 타입 등록만 확인한다.
            registrations = required[2].read_text(encoding="utf-8")
            names = set(re.findall(r'\["([^"]+)"\]\s*=\s*typeof\(', registrations))
            if names != {short for short, _ in entries}:
                raise ValueError(f"모듈 등록부가 XML과 다릅니다: {name}")
        qos = args.definitions / "qos_profiles.xml"
        if qos.is_file() and ET.parse(qos).getroot().tag.rsplit("}", 1)[-1] != "dds":
            raise ValueError("QoS XML의 최상위 요소는 <dds>여야 합니다.")
        if args.require_cpp_generated and (not args.cpp_registry or not args.cpp_registry.is_file()):
            raise ValueError("명시적으로 선택한 CLI의 C++ 등록부가 없습니다.")
        for obsolete in [*args.definitions.glob("topics.xml"), *args.definitions.glob("dds_client*.xml")]:
            raise ValueError(f"폐기된 설정 XML입니다: {obsolete}")
    except (ValueError, OSError, ET.ParseError) as error:
        print(f"오류: {error}", file=sys.stderr)
        return 1
    print(f"모듈 정적 검증 완료: {len(inputs)}개. 예제 XML과 QoS 이름을 필수로 요구하지 않습니다.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
