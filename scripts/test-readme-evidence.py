"""Regression checks for bounded generation and fail-before-write behavior."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("sync", ROOT / "scripts/sync-readme-evidence.py")
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.config = json.loads((ROOT / "docs/readme-evidence.json").read_text())
        self.data = json.loads((ROOT / "docs/readme-evidence.snapshot.json").read_text())

    def test_growth_keeps_three_rows_and_updates_latest(self):
        new = copy.deepcopy(self.data["worlds"][0])
        new.update(slug="future-case", id="GW-999999", title="Future case",
                   date="2030-01-01", url="https://genesis.evox.group/evidence/future-case")
        self.data["worlds"].append(new)
        self.data["count"] += 1
        block = sync.render(self.config, sync.normalize(self.data))
        self.assertEqual(sum(line.startswith("| [") for line in block.splitlines()), 3)
        self.assertIn("Latest evidence: [Future case]", block)

    def test_order_does_not_affect_output(self):
        expected = sync.render(self.config, sync.normalize(self.data))
        self.data["worlds"].reverse()
        self.assertEqual(expected, sync.render(self.config, sync.normalize(self.data)))

    def test_missing_result_fails(self):
        self.config["featured"][0]["verification"] = "renamed metric"
        with self.assertRaises(ValueError):
            sync.render(self.config, self.data)

    def test_duplicate_selection_and_unsafe_url_fail(self):
        self.config["featured"][1] = self.config["featured"][0]
        with self.assertRaises(ValueError):
            sync.render(self.config, self.data)
        self.data["worlds"][0]["url"] = "https://other.example/case"
        with self.assertRaises(ValueError):
            sync.normalize(self.data)

    def test_cli_preserves_surrounding_content_and_check_is_read_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scripts").mkdir()
            (root / "docs").mkdir()
            script = root / "scripts/sync-readme-evidence.py"
            script.write_bytes((ROOT / "scripts/sync-readme-evidence.py").read_bytes())
            config = root / "docs/readme-evidence.json"
            config.write_text(json.dumps(self.config))
            (root / "docs/readme-evidence.snapshot.json").write_text(json.dumps(self.data))
            readme = root / "README.md"
            before = f"KEEP BEFORE\n{sync.START}\nstale\n{sync.END}\nKEEP AFTER\n"
            readme.write_text(before)
            def run(*args):
                return subprocess.run([sys.executable, str(script), *args], capture_output=True)
            self.assertNotEqual(run("--check").returncode, 0)
            self.assertEqual(readme.read_text(), before)
            self.assertEqual(run().returncode, 0)
            generated = readme.read_text()
            self.assertTrue(generated.startswith("KEEP BEFORE\n"))
            self.assertTrue(generated.endswith("\nKEEP AFTER\n"))
            self.assertEqual(run("--check").returncode, 0)
            config.write_text(json.dumps({**self.config, "featured": []}))
            self.assertNotEqual(run().returncode, 0)
            self.assertEqual(readme.read_text(), generated)


if __name__ == "__main__":
    unittest.main()
