"""C# 독립 메시지 모듈과 패키지 프로젝트를 생성한다."""
from xml.sax.saxutils import escape
import os
from codegen_io import write, reference_path


def generate(name, entries, output, generated, core, reference_base=None):
    reference_base = reference_base or output
    generated_reference = reference_path(generated, reference_base)
    registry_compile = f'<Compile Include="{name}Messages.cs"/>' if generated.resolve() != reference_base.resolve() else ""
    registrations = "\n".join(f'            ["{short}"] = typeof(global::DdsModules_{name}.{".".join("@" + p for p in full)}),' for short, full in entries)
    write(output / f"{name}Messages.cs", f'''// 자동 생성 파일입니다. 직접 수정하지 마세요.
namespace DdsAmbassador.Messages;
public static class {name}Messages
{{
    public static DdsAmbassador.DDSClient.DdsMessageModule Module {{ get; }} =
        new("{name}", "1", new System.Collections.Generic.Dictionary<string, System.Type>
        {{
{registrations}
        }}, global::DdsModules_{name}.ModuleContract.SchemaSha256);
}}
''')
    write(output / f"DdsAmbassador.Messages.{name}.csproj", f'''<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net9.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings>
    <Nullable>disable</Nullable><LangVersion>latest</LangVersion><EnableDefaultCompileItems>false</EnableDefaultCompileItems>
    <Version>0.1.0</Version><PackageId>DdsAmbassador.Messages.{name}</PackageId>
    <AssemblyName>DdsAmbassador.Messages.{name}</AssemblyName>
  </PropertyGroup>
  <ItemGroup>
    <Compile Include="{escape(generated_reference, {'"': '&quot;'})}/*.cs"/>
    {registry_compile}
    <ProjectReference Include="{escape(reference_path(core, reference_base), {'"': '&quot;'})}"/>
  </ItemGroup>
</Project>
''')
