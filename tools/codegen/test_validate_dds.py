"""Regression checks for source filtering in relocated/offline checkouts."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "validate_dds", Path(__file__).with_name("validate-dds.py"))
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class SourceFilteringTests(unittest.TestCase):
    def test_checkout_parent_names_do_not_hide_sources(self):
        with tempfile.TemporaryDirectory() as temporary:
            for parent in ("artifacts", "build", "bin", "obj"):
                with self.subTest(parent=parent):
                    root = Path(temporary) / parent / "DDSClient"
                    source = root / "src" / "Library.cs"
                    source.parent.mkdir(parents=True)
                    source.write_text("public class Library {}", encoding="utf-8")
                    self.assertIn("Library", validator.source_text([source], root))

    def test_generated_output_inside_checkout_is_still_excluded(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ("artifacts", "build", "bin", "obj"):
                source = root / "src" / name / "Generated.cs"
                source.parent.mkdir(parents=True)
                source.write_text("must not be scanned", encoding="utf-8")
                self.assertEqual("", validator.source_text([source], root))


if __name__ == "__main__":
    unittest.main()
