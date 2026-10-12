"""독립 DDS XML 메시지 패키지의 공통 탐색과 생성.

모든 XML은 같은 규칙의 독립 패키지로 생성하며 Core에는 등록하지 않습니다.
"""
import argparse
import tempfile
import shutil
import uuid
import sys
from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET
from backends import csharp, cpp
from codegen_io import write, reference_path
from isolate_types import isolate_directory, schema_sha256

WORKSPACE_ROOT = Path(__file__).resolve().parents[2]
IDENTIFIER = re.compile(r"[A-Za-z][A-Za-z0-9_]*\Z")


def schema(path):
    """XML에서 발행·구독 가능한 최상위 타입을 읽는다.

    QoS 전용 XML은 None을 반환하여 탐색에서 제외한다. 보조 타입은 topLevel=false로 제외한다.
    반환 목록은 짧은 이름과 전체 네임스페이스 경로의 쌍이며, 실제 언어 심볼 격리는 별도 단계에서 수행한다.
    """
    root = ET.parse(path).getroot()
    types = root.find("types")
    if types is None:
        return None  # QoS/configuration, 메시지 스키마가 아닙니다.
    if root.tag != "dds" or not IDENTIFIER.fullmatch(path.stem):
        raise ValueError(f"{path}: <dds><types> 구조와 식별자 형식의 파일명이 필요합니다")
    if root.findall(".//include"):
        raise ValueError(f"{path}: 외부 파일 포함은 지원하지 않습니다. 독립 스키마를 사용하세요")
    entries = []
    def walk(node, scopes):
        for item in node:
            if item.tag == "module":
                name = item.get("name", "")
                if not IDENTIFIER.fullmatch(name):
                    raise ValueError(f"{path}: 잘못된 모듈 이름 {name!r}")
                walk(item, scopes + [name])
            elif item.tag in {"struct", "union"}:
                name = item.get("name", "")
                if not scopes or not IDENTIFIER.fullmatch(name):
                    raise ValueError(f"{path}: 메시지 타입은 모듈 안에 유효한 이름으로 정의해야 합니다")
                if item.get("topLevel", "true").lower() not in {"false", "0"}:
                    entries.append((name, scopes + [name]))
    walk(types, [])
    if not entries or len({name for name, _ in entries}) != len(entries):
        raise ValueError(f"{path}: 최상위 타입이 하나 이상 필요하며 짧은 타입 이름은 고유해야 합니다")
    return entries


def discover(directory):
    """정의 폴더의 독립 메시지 XML을 파일명 순서로 찾고 모듈명 충돌을 생성 전에 차단한다."""
    result = []
    names = set()
    for path in sorted(directory.glob("*.xml")):
        entries = schema(path)
        if entries is None:
            continue
        key = path.stem.lower()
        if key in names or key in {"simulation", "cpp", "core", "dds_cpp", "dds_cpp_static", "dds_cpp_shared", "rti"}:
            raise ValueError(f"{path}: 중복되거나 예약된 모듈 파일명")
        names.add(key)
        result.append(path)
    return result



@contextmanager
def generation_lock(output):
    """한 모듈 출력 폴더에 동시에 게시하는 것을 막는다.

    잠금 파일에는 소유 프로세스 번호를 남긴다. 비정상 종료의 잠금을 임의 삭제하지 않고
    실제 생성 작업이 살아 있는지 확인하도록 오류를 반환한다.
    """
    output.mkdir(parents=True, exist_ok=True)
    lock = output / ".generation.lock"
    try:
        descriptor = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError as error:
        raise ValueError(f"{output}: 다른 생성 작업의 잠금 파일이 있습니다. 중단된 작업인지 확인 후 잠금을 정리하세요") from error
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(str(os.getpid()))
        yield
    finally:
        lock.unlink(missing_ok=True)


def generate(xml, output, language, rti_home, core=None, pregenerated=None, force=False):
    """모듈별 잠금 아래 타입·등록부·프로젝트를 생성한다. 실패하면 기존 출력은 보존한다."""
    with generation_lock(output):
        _generate(xml, output, language, rti_home, core, pregenerated, force)


def publish_generated_set(output, pairs):
    """원본은 별도 백업에 보관하고 타입·등록부·프로젝트·스탬프를 함께 교체한다."""
    # 동일한 결과는 교체하지 않는다. 등록부만 다시 생성해도 모듈 전체가 재컴파일되는 것을 방지한다.
    pairs = [(source, target) for source, target in pairs
             if not target.is_file() or source.read_bytes() != target.read_bytes()]
    if not pairs:
        return
    backup = output / (".generated-backup-" + uuid.uuid4().hex)
    backup.mkdir()
    saved, published = [], []
    try:
        for source, target in pairs:
            if target.exists():
                previous = backup / target.name
                target.rename(previous)
                saved.append((previous, target))
        for source, target in pairs:
            source.rename(target)
            published.append((source, target))
    except BaseException as error:
        restoration_errors = []
        for source, target in reversed(published):
            try:
                target.rename(source)
            except OSError as recovery:
                restoration_errors.append(recovery)
        for previous, target in reversed(saved):
            try:
                previous.rename(target)
            except OSError as recovery:
                restoration_errors.append(recovery)
        if restoration_errors:
            raise RuntimeError(f"생성물 복원에 실패했습니다. 원본 백업을 보존했습니다: {backup}") from error
        backup.rmdir()
        raise
    else:
        try:
            shutil.rmtree(backup)
        except OSError:
            print(f"경고: 이전 생성물 백업을 보존했습니다: {backup}", file=sys.stderr)


def _generate(xml, output, language, rti_home, core=None, pregenerated=None, force=False):
    """사전 생성물의 XML 일치를 확인하거나 RTI 생성 캐시를 판단한 뒤 임시 결과를 일괄 게시한다.

    캐시는 XML뿐 아니라 후처리기·언어별 생성기·SDK 정보가 바뀌어도 무효화한다.
    RTI 실행과 후처리 성공 전에는 실제 출력 파일을 덮어쓰지 않는다.
    """
    entries = schema(xml)
    if entries is None:
        raise ValueError(f"{xml}: 메시지 스키마가 아닙니다")
    name = xml.stem
    output.mkdir(parents=True, exist_ok=True)
    generated = pregenerated or output
    fingerprint = None
    regenerate = False
    if pregenerated:
        contract = generated / ("ModuleContract.g.cs" if language == "c#" else name + "_contract.hpp")
        if not contract.is_file() or f'"{schema_sha256(xml)}"' not in contract.read_text(encoding="utf-8"):
            raise ValueError(f"{xml}: 사전 생성 스키마 확인 정보가 없거나 오래되었습니다")
    else:
        generator = rti_home / "bin" / ("rtiddsgen.bat" if os.name == "nt" else "rtiddsgen")
        if not generator.is_file():
            raise ValueError(f"RTI 생성기가 없습니다: {generator}")
        fingerprint_inputs = [xml, Path(__file__), Path(__file__).with_name("isolate_types.py"),
                              Path(__file__).with_name("codegen_io.py"),
                              Path(__file__).parent / "backends" / ("csharp.py" if language == "c#" else "cpp.py")]
        versions = rti_home / "rti_versions.xml"
        if versions.is_file():
            fingerprint_inputs.append(versions)
        digest = hashlib.sha256()
        for path in fingerprint_inputs:
            data = path.read_bytes()
            digest.update(len(data).to_bytes(8, "big"))
            digest.update(data)
        digest.update(str(rti_home.resolve()).encode())
        digest.update(language.encode())
        fingerprint = digest.hexdigest()
        stamp = output / "generation.sha256"
        suffixes = [".cs", "Plugin.cs"] if language == "c#" else [".hpp", ".cxx", "Plugin.hpp", "Plugin.cxx"]
        expected = [generated / (name + suffix) for suffix in suffixes]
        contract = generated / ("ModuleContract.g.cs" if language == "c#" else name + "_contract.hpp")
        regenerate = (force or not stamp.exists() or stamp.read_text() != fingerprint
                      or not all(path.is_file() for path in expected) or not contract.is_file())
    with tempfile.TemporaryDirectory(prefix=".generation-", dir=output) as temporary:
        stage = Path(temporary)
        pairs = []
        backend_types = generated
        if regenerate:
            candidate = stage / "Generated"
            candidate.mkdir()
            subprocess.run([str(generator), "-language", language, "-inputXml", "-replace", "-d",
                            str(candidate.resolve()), str(xml.resolve())],
                           cwd=rti_home / "resource/schema", check=True)
            if not all((candidate / path.name).is_file() for path in expected):
                raise ValueError(f"{xml}: RTI가 필수 파일을 모두 생성하지 못했습니다")
            isolate_directory(xml, candidate, language)
            backend_types = candidate
            pairs.extend((path, output / path.name) for path in candidate.iterdir() if path.is_file())
            write(stage / "generation.sha256", fingerprint)
            pairs.append((stage / "generation.sha256", output / "generation.sha256"))
        if language == "c#":
            csharp.generate(name, entries, stage, generated, core, reference_base=output)
            metadata = [f"{name}Messages.cs", f"DdsAmbassador.Messages.{name}.csproj"]
        else:
            cpp.generate(name, entries, stage, backend_types, core)
            metadata = [f"{name}Messages.hpp", f"{name}Messages.cpp", f"{name}_messages.hpp"]
        pairs.extend((stage / filename, output / filename) for filename in metadata)
        # 스테이징 중 어느 단계에서든 실패하면 기존 게시물은 그대로 남는다.
        publish_generated_set(output, pairs)
        # 이전 버전에서 생성한 구현 파일은 더 이상 빌드하지 않는다. 수동 파일은 절대 삭제하지 않는다.
        if language != "c#":
            legacy = output / f"{name}_messages.cpp"
            if legacy.is_file() and legacy.read_text(encoding="utf-8").startswith("// 자동 생성 파일입니다. 직접 수정하지 마세요."):
                legacy.unlink()


def manifest(directory):
    """발견한 모든 메시지 XML을 같은 규칙과 정렬 순서로 기록한다."""
    return ";".join(path.stem for path in discover(directory)) + "\n"


def signal_forge_props(directory, destination):
    """빌드 시 사용할 참조 목록만 만든다. 실행 중 어셈블리를 탐색하지 않는다."""
    root = ET.Element("Project")
    ET.SubElement(ET.SubElement(root, "PropertyGroup"), "DdsUseDefaultModules").text = "false"
    group = ET.SubElement(root, "ItemGroup")
    for name in (p.stem for p in discover(directory)):
        module_dir = WORKSPACE_ROOT / "DDS_Nuget/generated" / name
        project = f"DdsAmbassador.Messages.{name}.csproj"
        accessor = f"DdsAmbassador.Messages.{name}Messages.Module"
        def relative(path):
            return reference_path(path, destination.parent, "$(MSBuildThisFileDirectory)")
        ET.SubElement(group, "DdsBuiltModule", Include=name, ProjectPath=relative(module_dir / project),
                      Accessor=accessor, Contract=relative(directory / f"{name}.xml"))
    ET.indent(root)
    write(destination, ET.tostring(root, encoding="unicode") + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--definitions", type=Path, default=WORKSPACE_ROOT / "definitions")
    parser.add_argument("--manifest", type=Path, help="사용 가능한 공통 모듈 목록 저장")
    parser.add_argument("--signal-forge-props", type=Path, help="빌드에서 선택한 Signal Forge 모듈 참조 생성")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--xml", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--language", choices=["c#", "C++11"])
    parser.add_argument("--rti-home", type=Path, default=Path(os.environ.get("NDDSHOME", ".")))
    parser.add_argument("--core", type=Path,
                        default=WORKSPACE_ROOT / "DDS_Nuget/core/DdsAmbassador.DDSClient.Core.csproj")
    parser.add_argument("--pregenerated", type=Path)
    parser.add_argument("--force", action="store_true", help="캐시를 사용하지 않고 타입을 다시 생성합니다")
    args = parser.parse_args()
    if args.manifest:
        write(args.manifest, manifest(args.definitions))
    if args.signal_forge_props:
        signal_forge_props(args.definitions, args.signal_forge_props)
    if args.list:
        print(";".join(path.stem for path in discover(args.definitions)))
    elif args.xml:
        generate(args.xml, args.output, args.language, args.rti_home, args.core, args.pregenerated, args.force)
    elif not args.manifest and not args.signal_forge_props:
        for path in discover(args.definitions):
            generate(path, args.output / path.stem, args.language, args.rti_home, args.core, force=args.force)
        if args.language == "c#" and args.output.resolve() == (WORKSPACE_ROOT / "DDS_Nuget/generated").resolve():
            signal_forge_props(args.definitions, args.output / "BuiltModules.props")


if __name__ == "__main__":
    main()
