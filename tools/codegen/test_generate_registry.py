import importlib.util
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

spec = importlib.util.spec_from_file_location("registry", Path(__file__).resolve().parents[2] / "cli/codegen/generate-registry.py")
registry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(registry)


class RegistryTests(unittest.TestCase):
    def test_only_direct_msg_structs_are_registered(self):
        root = ET.fromstring('''<dds><types>
          <module name="OTHER"><struct name="Other"/></module>
          <module name="MSG"><!-- <struct name="Commented"/> -->
            <module name="Nested"><struct name="NotAMessage"/></module>
            <struct name="Tick"><member name="Time"/></struct>
            <struct name="Fire"/>
          </module></types></dds>''')
        result, names = registry.generate(root)
        self.assertEqual(2, result.count("DDSCPP_REGISTER_RTI_TYPE"))
        self.assertIn("MSG::Tick", result)
        self.assertIn("MSG::Fire", result)
        self.assertNotIn("NotAMessage", result)
        self.assertIn('DDSCPP_JSON_NAME("Time")', names)

    def test_invalid_definitions_fail(self):
        for xml in ('<wrong/>', '<dds/>', '<dds><module name="MSG"/></dds>',
                    '<dds><module name="MSG"><struct name="A"/><struct name="A"/></module></dds>',
                    '<dds><module name="MSG"><struct name="bad-name"/></module></dds>'):
            with self.subTest(xml=xml), self.assertRaises(ValueError):
                registry.generate(ET.fromstring(xml))


if __name__ == "__main__":
    unittest.main()
