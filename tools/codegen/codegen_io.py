"""코드 생성 결과를 일관되게 기록하고 파일 단위로 교체한다."""
import os
import tempfile


def reference_path(path, base, prefix=""):
    """같은 볼륨은 재배치 가능한 상대 경로, 다른 볼륨은 절대 경로를 사용한다."""
    target = str(path.resolve())
    try:
        return prefix + os.path.relpath(target, str(base.resolve())).replace("\\", "/")
    except ValueError:
        return target.replace("\\", "/")

def write(path, content):
    """내용이 달라질 때만 같은 폴더의 임시 파일을 원자적으로 교체한다.

    기존 내용이 같으면 수정 시각을 유지하여 불필요한 재빌드를 줄인다.
    임시 파일을 대상과 같은 볼륨에 만들어 교체 중 부분 기록 파일이 노출되지 않게 한다.
    여러 파일의 일괄 게시·롤백은 schema_modules의 상위 생성 단계가 담당한다.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() or path.read_text(encoding="utf-8") != content:
        descriptor, temporary = tempfile.mkstemp(prefix=".codegen-", dir=path.parent)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
                stream.write(content)
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
