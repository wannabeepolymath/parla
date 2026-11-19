"""SYNTHETIC download-model.sh tests: temp dirs and a file:// source, never the network."""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "download-model.sh"
CATALOG = ROOT / "Sources" / "ParlaCore" / "ModelCatalog.swift"
PAYLOAD = b"lmgg synthetic test payload, not a model\n" * 8
GOOD_SHA = hashlib.sha256(PAYLOAD).hexdigest()
ID = "test-model"


class DownloadModelTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.src = Path(tmp.name) / "src"
        self.dest = Path(tmp.name) / "dest"
        self.src.mkdir()
        (self.src / f"ggml-{ID}.bin").write_bytes(PAYLOAD)
        self.final = self.dest / f"ggml-{ID}.bin"
        self.part = self.dest / f"ggml-{ID}.bin.part"

    def run_script(self, *args, base=None):
        env = dict(os.environ, PARLA_MODEL_BASE_URL=(base or self.src).as_uri())
        return subprocess.run(["bash", str(SCRIPT), *args, "--dir", str(self.dest)],
                              env=env, capture_output=True, text=True)

    def pinned(self, sha=GOOD_SHA, base=None):
        return self.run_script(ID, "--sha256", sha, "--bytes", str(len(PAYLOAD)), base=base)

    def test_good_download_is_promoted(self):
        r = self.pinned()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.final.read_bytes(), PAYLOAD)
        self.assertFalse(self.part.exists())

    def test_wrong_digest_never_reaches_final_name(self):
        r = self.pinned(sha="0" * 64)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("sha256", r.stderr)
        self.assertFalse(self.final.exists())
        self.assertFalse(self.part.exists())

    def test_html_payload_is_rejected(self):
        page = b"  <!DOCTYPE html><title>404</title>"
        (self.src / f"ggml-{ID}.bin").write_bytes(page)
        r = self.run_script(ID, "--sha256", hashlib.sha256(page).hexdigest(), "--bytes", str(len(page)))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("web page", r.stderr)
        self.assertFalse(self.final.exists())
        self.assertFalse(self.part.exists())

    def test_truncated_existing_file_is_not_accepted(self):
        self.dest.mkdir()
        self.final.write_bytes(PAYLOAD[:10])
        r = self.pinned()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(hashlib.sha256(self.final.read_bytes()).hexdigest(), GOOD_SHA)
        self.assertEqual(Path(f"{self.final}.rejected").read_bytes(), PAYLOAD[:10])

    def test_verified_existing_file_is_a_noop(self):
        self.assertEqual(self.pinned().returncode, 0)
        r = self.pinned(base=self.src / "missing")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("verified:", r.stdout)
        self.assertEqual(self.final.read_bytes(), PAYLOAD)

    def test_unknown_id_without_pin_is_refused(self):
        r = self.run_script("tiny.en")
        self.assertNotEqual(r.returncode, 0)
        for known in ("base.en", "small.en-q5_1", "large-v3-turbo-q5_0"):
            self.assertIn(known, r.stderr)
        self.assertFalse((self.dest / "ggml-tiny.en.bin").exists())

    def test_pin_table_matches_catalog(self):
        catalog = re.findall(r'Model\(id: "([^"]+)".*?bytes: ([\d_]+).*?sha256: "([0-9a-f]{64})"',
                             CATALOG.read_text(), re.S)
        catalog = [(i, b.replace("_", ""), s) for i, b, s in catalog]
        script = re.findall(r"^([\w.-]+) (\d+) ([0-9a-f]{64})$", SCRIPT.read_text(), re.M)
        self.assertEqual(len(catalog), 3)
        self.assertEqual(script, catalog)


if __name__ == "__main__":
    unittest.main()
