import tempfile
import unittest
from pathlib import Path
from schema_modules import discover, schema, manifest, generate, signal_forge_props
from isolate_types import isolate_text, isolate_directory, schema_sha256
import xml.etree.ElementTree as ET
from unittest.mock import patch
from codegen_io import reference_path


class SchemaModulesTests(unittest.TestCase):
    def test_cross_volume_reference_uses_absolute_path_without_msbuild_prefix(self):
        path = Path(__file__)
        with patch("codegen_io.os.path.relpath", side_effect=ValueError("different mounts")):
            self.assertEqual(reference_path(path, path.parent, "$(MSBuildThisFileDirectory)"), path.resolve().as_posix())

    def test_generation_stamp_tracks_schema_and_normalizes_line_endings(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            xml = root / "Example.xml"
            xml.write_text('<dds>\n<types><module name="Common"><struct name="Status"/></module></types></dds>', encoding="utf-8", newline="\n")
            for suffix in [".cs", "Plugin.cs"]:
                (root / ("Example" + suffix)).write_text("namespace Common { }", encoding="utf-8")
            isolate_directory(xml, root, "c#")
            first = (root / "ModuleContract.g.cs").read_text()
            xml.write_bytes(xml.read_bytes().replace(b"\n", b"\r\n"))
            isolate_directory(xml, root, "c#")
            self.assertEqual(first, (root / "ModuleContract.g.cs").read_text())
            xml.write_text(xml.read_text().replace('name="Status"', 'name="Changed"'), encoding="utf-8")
            isolate_directory(xml, root, "c#")
            self.assertNotEqual(first, (root / "ModuleContract.g.cs").read_text())

    def test_signal_forge_selection_contains_optional_module_without_absolute_paths(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "Extra.xml").write_text('<dds><types><module name="Common"><struct name="Status"/></module></types></dds>')
            target = root / "build/selected.props"
            signal_forge_props(root, target)
            content = target.read_text()
            self.assertIn('Include="Extra"', content)
            self.assertIn('DdsAmbassador.Messages.ExtraMessages.Module', content)
            self.assertIn('$(MSBuildThisFileDirectory)', content)
            self.assertNotIn(str(root.resolve()), content)

    def test_nested_namespace_matching_root_is_not_prefixed_twice(self):
        source = 'namespace Outer { namespace Common { struct S {}; } } namespace Common { struct T {}; } ::Outer::Common::S value;'
        result = isolate_text(source, ['Outer', 'Common'], 'Nested', 'C++11')
        self.assertIn('namespace DdsModules_Nested::Outer { namespace Common {', result)
        self.assertIn('::DdsModules_Nested::Outer::Common::S value', result)
        self.assertEqual(result, isolate_text(result, ['Outer', 'Common'], 'Nested', 'C++11'))

    def test_escaped_csharp_namespace(self):
        result = isolate_text('namespace @event { global::@event.Status x; }', ['event'], 'Keyword', 'c#')
        self.assertIn('namespace DdsModules_Keyword.@event', result)
        self.assertIn('global::DdsModules_Keyword.@event.Status', result)

    def test_global_enum_and_plugin_symbols_are_isolated(self):
        source = 'enum class Mode { Idle }; ::Mode x; ModePlugin_get(); const char* name = "Mode";'
        a = isolate_text(source, [], 'A', 'C++11', ['Mode'])
        b = isolate_text(source, [], 'B', 'C++11', ['Mode'])
        self.assertIn('enum class DdsModules_A_Mode', a)
        self.assertIn('DdsModules_A_ModePlugin_get()', a)
        self.assertIn('"Mode"', a)
        self.assertNotEqual(a, b)
        self.assertEqual(a, isolate_text(a, [], 'A', 'C++11', ['Mode']))

    def test_braces_in_metadata_do_not_change_namespace_depth(self):
        result = isolate_text('const char* s = "{{"; /* { */ namespace Common { }', ['Common'], 'A', 'C++11')
        self.assertIn('namespace DdsModules_A::Common', result)

    def test_isolation_preserves_wire_metadata_and_is_idempotent(self):
        text = 'namespace Common { ::Common::Status value; const char* wire = "Common::Status"; /* Common::Status */ }'
        result = isolate_text(text, ["Common"], "NetworkA", "C++11")
        self.assertIn('namespace DdsModules_NetworkA::Common', result)
        self.assertIn('::DdsModules_NetworkA::Common::Status value', result)
        self.assertIn('"Common::Status"', result)
        self.assertEqual(result, isolate_text(result, ["Common"], "NetworkA", "C++11"))

    def test_csharp_isolation_preserves_strings(self):
        result = isolate_text('namespace Common { global::Common.Status x; string s = "Common::Status"; }', ["Common"], "NetworkB", "c#")
        self.assertIn('global::DdsModules_NetworkB.Common.Status', result)
        self.assertIn('"Common::Status"', result)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def xml(self, name, text):
        path = self.root / (name + ".xml")
        path.write_text(text)
        return path

    def test_qos_is_not_a_module_and_new_files_are_discovered(self):
        self.xml("qos_profiles", "<dds><qos_library/></dds>")
        path = self.xml("Radar", '<dds><types><module name="Radar"><struct name="Track"/></module></types></dds>')
        self.assertEqual([path], discover(self.root))
        path.unlink()
        self.assertEqual([], discover(self.root))

    def test_nested_namespace_and_non_topic_struct(self):
        path = self.xml("Radar", '<dds><types><module name="A"><module name="B"><struct name="Helper" topLevel="false"/><struct name="Track"/></module></module></types></dds>')
        self.assertEqual([("Track", ["A", "B", "Track"])], schema(path))

    def test_manifest_preserves_builtins_and_sorted_optional_modules(self):
        text = '<dds><types><module name="A"><struct name="Track"/></module></types></dds>'
        for name in ("Telemetry", "Zulu", "DDSSim", "Alpha"):
            self.xml(name, text)
        self.xml("qos_profiles", "<dds><qos_library/></dds>")
        self.assertEqual("Alpha;DDSSim;Telemetry;Zulu\n", manifest(self.root))

    def test_manifest_without_optional_modules_preserves_format(self):
        self.assertEqual("\n", manifest(self.root))

    def test_backends_use_pregenerated_types_without_running_rti(self):
        xml = self.xml("Radar", '<dds><types><module name="A"><struct name="Track"/></module></types></dds>')
        generated = self.root / "offline"
        generated.mkdir()
        for suffix in (".cs", "Plugin.cs", ".hpp", ".cxx", "Plugin.hpp", "Plugin.cxx"):
            (generated / ("Radar" + suffix)).write_text("// preserved offline input\n")
        for filename in ("ModuleContract.g.cs", "Radar_contract.hpp"):
            (generated / filename).write_text(f'// pre-generated stamp "{schema_sha256(xml)}"\n')
        before = {p.name: p.read_bytes() for p in generated.iterdir()}
        core = self.root / "DDS_Nuget/core/DdsAmbassador.DDSClient.Core.csproj"
        csharp = self.root / "csharp"
        cpp = self.root / "cpp"
        generate(xml, csharp, "c#", self.root / "missing-rti", core, generated)
        generate(xml, cpp, "C++11", self.root / "missing-rti", pregenerated=generated)
        self.assertIn("global::DdsModules_Radar.@A.@Track", (csharp / "RadarMessages.cs").read_text())
        project = (csharp / "DdsAmbassador.Messages.Radar.csproj").read_text()
        self.assertIn("<AssemblyName>DdsAmbassador.Messages.Radar</AssemblyName>", project)
        reference = ET.fromstring(project).find(".//ProjectReference").get("Include")
        self.assertEqual(core.resolve(), (csharp / reference).resolve())
        self.assertIn('RtiMessageType<DdsModules_Radar::A::Track>("Track")', (cpp / "RadarMessages.cpp").read_text())
        self.assertEqual(before, {p.name: p.read_bytes() for p in generated.iterdir()})

    def test_cpp_backend_rejects_incomplete_offline_types(self):
        xml = self.xml("Radar", '<dds><types><module name="A"><struct name="Track"/></module></types></dds>')
        (self.root / "Radar_contract.hpp").write_text(f'// stamp "{schema_sha256(xml)}"\n')
        with self.assertRaisesRegex(ValueError, "사전 생성된 모듈 파일"):
            generate(xml, self.root / "cpp", "C++11", self.root, pregenerated=self.root)

    def test_stale_offline_schema_stamp_is_rejected(self):
        xml = self.xml("Radar", '<dds><types><module name="A"><struct name="Track"/></module></types></dds>')
        (self.root / "Radar_contract.hpp").write_text('// stale stamp "0000"\n')
        with self.assertRaisesRegex(ValueError, "사전 생성 스키마 확인 정보"):
            generate(xml, self.root / "cpp", "C++11", self.root, pregenerated=self.root)

    def test_case_collisions_rejected(self):
        text = '<dds><types><module name="A"><struct name="Track"/></module></types></dds>'
        self.xml("Radar", text)
        # 플랫폼과 무관하게 예약 타깃에 대응하는 이름도 거부한다.
        self.xml("Simulation", text)
        with self.assertRaisesRegex(ValueError, "예약된"):
            discover(self.root)

    def test_ambiguous_default_topic_rejected(self):
        path = self.xml("Radar", '<dds><types><module name="A"><struct name="Track"/></module><module name="B"><struct name="Track"/></module></types></dds>')
        with self.assertRaisesRegex(ValueError, "고유"):
            schema(path)

    def test_include_rejected(self):
        path = self.xml("Radar", '<dds><include file="Other.xml"/><types><module name="A"><struct name="Track"/></module></types></dds>')
        with self.assertRaisesRegex(ValueError, "외부 파일 포함"):
            schema(path)

    def test_invalid_filename_rejected(self):
        path = self.xml("bad-name", '<dds><types/></dds>')
        with self.assertRaisesRegex(ValueError, "파일명"):
            schema(path)


if __name__ == "__main__":
    unittest.main()
