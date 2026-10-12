#!/usr/bin/env python3
"""DDSSim 예제 CLI용 C++ 타입 등록부와 JSON 필드 이름을 생성한다."""

import argparse
import re
import xml.etree.ElementTree as ET
from pathlib import Path


def generate(root):
    if root.tag != "dds":
        raise ValueError("DDSSim.xml의 최상위 요소는 <dds>여야 합니다.")
    module = next((element for element in root.iter("module")
                   if element.get("name") == "MSG"), None)
    if module is None:
        raise ValueError("DDSSim.xml에 MSG 모듈이 필요합니다.")
    names = [element.get("name", "") for element in module.findall("struct")]
    if not names:
        raise ValueError("DDSSim.xml의 MSG 모듈에는 구조체가 하나 이상 필요합니다.")
    if len(names) != len(set(names)):
        raise ValueError("DDSSim.xml의 MSG 구조체 이름은 고유해야 합니다.")
    spellings = sorted({element.get("name", "") for element in root.iter()
                        if element.tag in {"member", "enumerator"}})
    for name in names + spellings:
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
            raise ValueError(f"잘못된 생성 식별자: {name!r}")
    header = "// DDSSim 예제 CLI용 자동 생성 파일입니다. 직접 수정하지 마세요.\n"
    registry = header + "".join(
        f'DDSCPP_REGISTER_RTI_TYPE(MSG::{name}, {name}, "{name}")\n'
        for name in sorted(names))
    json_names = header + "".join(f'DDSCPP_JSON_NAME("{name}")\n' for name in spellings)
    return registry, json_names


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dds-sim", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    registry, json_names = generate(ET.parse(args.dds_sim).getroot())
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for filename, content in (("dds_cpp_rti_type_registry.inc", registry),
                              ("dds_cpp_json_names.inc", json_names)):
        with (args.output_dir / filename).open("w", encoding="utf-8", newline="\n") as stream:
            stream.write(content)


if __name__ == "__main__":
    main()
