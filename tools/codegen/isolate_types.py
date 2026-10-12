"""DDS 통신 메타데이터를 유지하면서 생성된 언어 심볼만 격리한다.

문자열·주석 밖의 네임스페이스 선언과 식별자만 변경한다.
TypeCode와 직렬화 TypeObject의 이름은 XML 원문을 유지한다.
XML 수정이 아니라 생성 코드 후처리 단계다.
"""
import re
import hashlib
import xml.etree.ElementTree as ET

LITERALS = re.compile(r'("(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|//[^\n]*|/\*[\s\S]*?\*/)')


def isolate_text(text, roots, module, language, globals=()):
    prefix = "DdsModules_" + module
    parts = LITERALS.split(text)
    depth = 0
    # RTI의 중첩 네임스페이스에서는 최상위 선언에만 접두사를 붙인다.
    # 같은 이름의 내부 네임스페이스에 접두사가 중복으로 붙지 않도록 한다.
    declarations = re.compile(r'\bnamespace\s+(@?[A-Za-z_]\w*)|[{}]')
    def declaration(match):
        nonlocal depth
        name = match.group(1)
        if name:
            if depth == 0 and name.lstrip('@') in roots:
                return "namespace " + prefix + ("." if language == "c#" else "::") + name
        elif match.group() == "{":
            depth += 1
        else:
            depth -= 1
        return match.group()
    for index in range(0, len(parts), 2):
        code = declarations.sub(declaration, parts[index])
        for root in roots:
            if language == "c#":
                code = re.sub(r'\bglobal::(@?' + re.escape(root) + r')\.',
                              lambda m: "global::" + prefix + "." + m[1] + ".", code)
            else:
                scoped = prefix + "::" + root
                code = re.sub(r'(?<![\w:])::' + re.escape(root) + r'::', "::" + scoped + "::", code)
                code = re.sub(r'(?<![\w:])' + re.escape(root) + r'::', scoped + "::", code)
        # 전역 보조 타입은 네임스페이스 블록이 없으므로 별도의 접두사를 부여한다.
        # RTI 플러그인 보조 심볼도 XML별 고유 접두사로 격리한다.
        # 문자열과 TypeObject의 실제 DDS 통신 이름은 유지한다.
        for name in globals:
            code = re.sub(r'(?<![\w@])@?' + re.escape(name) + r'(?:Plugin\w*|Support|Unmanaged)?\b',
                          lambda m: prefix + "_" + m[0].lstrip('@'), code)
        parts[index] = code
    return "".join(parts)


def schema_sha256(xml):
    return hashlib.sha256(xml.read_text(encoding="utf-8-sig").replace("\r\n", "\n").encode("utf-8")).hexdigest().upper()


def isolate_directory(xml, directory, language):
    types = ET.parse(xml).getroot().find("types")
    roots = [m.get("name") for m in types.findall("module")]
    globals = [m.get("name") for m in types if m.tag != "module" and m.get("name")]
    suffixes = [".cs", "Plugin.cs"] if language == "c#" else [".hpp", ".cxx", "Plugin.hpp", "Plugin.cxx"]
    for suffix in suffixes:
        path = directory / (xml.stem + suffix)
        content = isolate_text(path.read_text(encoding="utf-8"), roots, xml.stem, language, globals)
        with path.open("w", encoding="utf-8", newline="\n") as stream:
            stream.write(content)
    digest = schema_sha256(xml)
    if language == "c#":
        contract = f'// 메시지 타입과 함께 자동 생성된 확인 정보입니다. 직접 수정하지 마세요.\nnamespace DdsModules_{xml.stem};\npublic static class ModuleContract {{ public const string SchemaSha256 = "{digest}"; }}\n'
        path = directory / "ModuleContract.g.cs"
    else:
        contract = f'// 메시지 타입과 함께 자동 생성된 확인 정보입니다. 직접 수정하지 마세요.\n#pragma once\nnamespace DdsModules_{xml.stem} {{ inline constexpr const char* SchemaSha256 = "{digest}"; }}\n'
        path = directory / (xml.stem + "_contract.hpp")
    path.write_text(contract, encoding="utf-8", newline="\n")

if __name__ == "__main__":
    import argparse
    from pathlib import Path
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xml", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--language", choices=["c#", "C++11"], required=True)
    args = parser.parse_args()
    isolate_directory(args.xml, args.output, args.language)
