"""C++ 독립 메시지 모듈을 생성한다."""
from codegen_io import write


def generate(name, entries, output, generated, core=None):
    for suffix in [".hpp", ".cxx", "Plugin.hpp", "Plugin.cxx"]:
        if not (generated / (name + suffix)).is_file():
            raise ValueError(f"사전 생성된 모듈 파일이 없습니다: {generated / (name + suffix)}")
    write(output / f"{name}Messages.hpp", f'''// 자동 생성 파일입니다. 직접 수정하지 마세요.
#pragma once
#include "dds_cpp/transport/RtiHeaders.hpp"
#include "{name}.hpp"
#include "dds_cpp/api/DdsMessageModule.hpp"
namespace dds_cpp {{ std::shared_ptr<const DdsMessageModule> {name}Messages(); }}
''')
    registrations = ",\n".join(f'        RtiMessageType<DdsModules_{name}::{"::".join(full)}>("{short}")' for short, full in entries)
    write(output / f"{name}_messages.hpp", f'// 이전 include 경로의 호환 헤더입니다.\n#pragma once\n#include "{name}Messages.hpp"\n')
    write(output / f"{name}Messages.cpp", f'''// 자동 생성 파일입니다. 직접 수정하지 마세요.
#include "{name}Messages.hpp"
#include "dds_cpp/transport/RtiMessageType.hpp"
#include "{name}_contract.hpp"
namespace dds_cpp {{
// C#의 {name}Messages.Module에 대응하는 명시적 모듈 접근자다.
std::shared_ptr<const DdsMessageModule> {name}Messages() {{
    static const auto module = std::make_shared<const DdsMessageModule>(DdsMessageModule{{"{name}", "1", {{
{registrations}
    }}, DdsModules_{name}::SchemaSha256}});
    return module;
}}
}}
''')
