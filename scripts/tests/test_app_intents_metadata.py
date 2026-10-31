"""Owned TEST-ONLY fixtures. No real build, executable, extractor or signer."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "app-intents-metadata.py"
spec = importlib.util.spec_from_file_location("parla_metadata", SCRIPT)
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)
ARTIFACTS = Path("/tmp/parla-implementation-2026-10-28")


def schema_actions():
    """SYNTHETIC values with the retained actual schema-3 shape, never bundled."""
    primitive = {"primitive": {"wrapper": {"typeIdentifier": 0}}}
    entity = {"entity": {"wrapper": {"typeName": "ParlaAutomationResultEntity"}}}
    identities = {
        "StartParlaDictationIntent": ("5Parla05StartA15DictationIntentV", "Start dictation with ${applicationName}"),
        "StopParlaDictationIntent": ("5Parla04StopA15DictationIntentV", "Stop dictation with ${applicationName}"),
        "CancelParlaDictationIntent": ("5Parla06CancelA15DictationIntentV", "Cancel dictation with ${applicationName}"),
        "GetLastParlaResultIntent": ("5Parla07GetLastA12ResultIntentV", "Get last result from ${applicationName}"),
    }
    return {
        "testOnly": True, "version": 1, "generator": {"name": "xcode-tools", "version": metadata.KNOWN_XCODE},
        "actions": {name: {"identifier": name, "fullyQualifiedTypeName": "Parla." + name,
            "mangledTypeName": mangled, "mangledTypeNameV2": mangled, "openAppWhenRun": True,
            "authenticationPolicy": 2, "isAuthPolExplicit": True,
            "outputType": entity if name in {"StopParlaDictationIntent", "GetLastParlaResultIntent"} else primitive,
            "parameters": [{"name": "controlSession", "valueType": primitive, "isOptional": False}]
                if name in {"StopParlaDictationIntent", "CancelParlaDictationIntent"} else []}
            for name, (mangled, _) in identities.items()},
        "autoShortcutProviderMangledName": "5Parla0A12AppShortcutsV",
        "autoShortcuts": [{"actionIdentifier": name, "phraseTemplates": [{"alternatives": [], "key": phrase}]} for name, (_, phrase) in identities.items()],
        "entities": {"ParlaAutomationResultEntity": {"typeName": "ParlaAutomationResultEntity", "fullyQualifiedTypeName": "Parla.ParlaAutomationResultEntity",
            "mangledTypeName": "5Parla0A22AutomationResultEntityV", "defaultQueryIdentifier": "Parla.ParlaAutomationResultQuery",
            "properties": [{"identifier": name, "title": {"alternatives": [], "key": title}, "valueType": primitive, "isOptional": False}
                           for name, title in (("text", "Text"), ("outcome", "Outcome"))]}},
        "queries": {"ParlaAutomationResultQuery": {"identifier": "ParlaAutomationResultQuery", "queryType": "ParlaAutomationResultQuery",
            "fullyQualifiedIdentifier": "Parla.ParlaAutomationResultQuery", "mangledTypeName": "5Parla0A21AutomationResultQueryV",
            "entityType": "ParlaAutomationResultEntity", "defaultQueryForEntity": True, "resultValueType": entity, "parameters": []}},
    }


class Fixture:
    def __init__(self, root, architectures=("arm64",)):
        self.root = root
        self.architectures = architectures
        self.now = time.time_ns()
        self.source_root = root / "Sources with spaces ' $ ;" / "Parla"
        self.resources = root / "Parla.app/Contents/Resources"
        self.resources.mkdir(parents=True)
        self.binary = root / "linked Parla"
        self.inputs = root / "build receipt.json"
        self.calls = []
        self.strings_outputs = []
        self.mode = "valid"
        self.source = self.write(self.source_root / "Intents.swift", "\n".join("struct " + n + " {}" for n in sorted(metadata.DECLARATIONS)))
        os.utime(self.source, ns=(self.now - 20_000_000_000,) * 2)
        toolchain, sdk = root / "Toolchain with spaces", root / "MacOSX SDK"
        processor = self.write(toolchain / "usr/bin/appintentsmetadataprocessor", "TEST ONLY; never executable as a program")
        processor.chmod(0o700)
        compiler = self.write(toolchain / "usr/bin/swift-frontend", "TEST ONLY compiler identity")
        settings = self.write(sdk / "SDKSettings.json", '{"testOnly": true}')
        version = self.write(root / "Xcode-version.plist", plistlib.dumps({"ProductBuildVersion": metadata.KNOWN_XCODE}))
        self.receipt = {
            "schema": 1, "module": "Parla", "deployment": "13.3",
            "started_ns": self.now - 10_000_000_000, "completed_ns": self.now,
            "toolchain": str(toolchain), "sdk": str(sdk), "xcode_version": metadata.KNOWN_XCODE,
            "processor": self.record(processor), "compiler": self.record(compiler),
            "sdk_settings": self.record(settings), "xcode_version_file": self.record(version),
            "sources": [self.record(self.source)], "slices": [],
        }
        for arch in architectures:
            directory = root / (arch + " inputs")
            const = self.write(directory / "Parla.swiftconstvalues", json.dumps([
                {"typeName": "Parla." + name, "testOnly": True} for name in sorted(metadata.DECLARATIONS)]))
            dependency = self.write(directory / "link_dependency_info.dat", "TEST ONLY link dependency")
            for path in [const, dependency]:
                os.utime(path, ns=(self.now - 5_000_000_000,) * 2)
            source_list = self.write(directory / "sources.list", str(self.source) + "\n")
            const_list = self.write(directory / "constants.list", str(const) + "\n")
            self.receipt["slices"].append({
                "arch": arch, "triple": arch + "-apple-macos13.3", "source_list": self.record(source_list),
                "constants": [self.record(const)], "constant_list": self.record(const_list),
                "link_dependency": self.record(dependency), "stringsdata": True,
            })
        for key in ["metadata", "static_metadata"]:
            dep = self.write(root / (key + " dependent extract.actionsdata"), '{"testOnly": true}')
            listing = self.write(root / (key + ".list"), str(dep) + "\n")
            self.receipt[key] = {"list": self.record(listing), "files": [self.record(dep)]}
        self.write(self.binary, self.macho(architectures))
        os.utime(self.binary, ns=(self.now - 1_000_000_000,) * 2)
        self.receipt["binary"] = self.record(self.binary)
        self.save()

    @staticmethod
    def write(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(value if isinstance(value, bytes) else value.encode())
        return path

    @staticmethod
    def record(path):
        return {"path": str(path), "sha256": metadata.digest(path)}

    @staticmethod
    def macho(architectures):
        # Deliberately synthetic, non-runnable headers: sufficient for the pure
        # header reader only. Never shipped or called actual compiler output.
        cpus = {"arm64": 0x100000C, "x86_64": 0x1000007}
        slices = [struct.pack("<8I", 0xFEEDFACF, cpus[a], 0, 2, 1, 24, 0, 0) +
                  struct.pack("<6I", 0x32, 24, 1, 0xD0300, 0x1A0500, 0) for a in architectures]
        if len(slices) == 1:
            return slices[0]
        offset = 8 + 20 * len(slices)
        headers = []
        for arch, body in zip(architectures, slices):
            headers.append(struct.pack(">5I", cpus[arch], 0, offset, len(body), 0))
            offset += len(body)
        return struct.pack(">2I", 0xCAFEBABE, len(slices)) + b"".join(headers + slices)

    def save(self):
        self.inputs.write_text(json.dumps(self.receipt))

    def runner(self, args, **options):
        self.calls.append(args)
        assert options == {"check": True, "capture_output": True}
        output = Path(args[args.index("--output") + 1])
        if self.mode == "failure":
            raise subprocess.CalledProcessError(1, args)
        if self.mode == "empty":
            return subprocess.CompletedProcess(args, 0)
        for index, argument in enumerate(args):
            if argument == "--stringsdata-file":
                path = Path(args[index + 1])
                self.strings_outputs.append((path, path.exists()))
                self.write(path, "TEST ONLY extracted stringsdata output")
        generated = output / "Metadata.appintents"
        self.write(generated / "version.json", json.dumps({"toolsVersion": metadata.KNOWN_XCODE, "version": "3.0"}))
        self.write(generated / "objects.appintentsmanifest", "TEST ONLY opaque manifest fixture")
        actions = schema_actions()
        self.write(generated / "extract.actionsdata", json.dumps(actions))
        self.write(output / "en.lproj/AppShortcuts.strings", "TEST ONLY localization")
        self.write(output / "Extra resource.dat", "TEST ONLY resource")
        if self.mode == "invalid-json":
            (generated / "extract.actionsdata").write_text("{invalid")
        if self.mode == "missing-action":
            del actions["actions"]["StartParlaDictationIntent"]
            (generated / "extract.actionsdata").write_text(json.dumps(actions))
        if self.mode == "empty-version":
            (generated / "version.json").write_text("{}")
        if self.mode == "missing-manifest":
            (generated / "objects.appintentsmanifest").unlink()
        if self.mode == "symlink":
            (output / "unsafe").symlink_to(self.source)
        if self.mode == "input-race":
            self.source.write_text("changed during fake extraction")
        return subprocess.CompletedProcess(args, 0)

    def install(self, runner=None, **options):
        self.save()
        return metadata.install_metadata(self.inputs, self.binary, self.resources, self.source_root,
                                         self.architectures, runner=runner or self.runner, now_ns=self.now, **options)


class MetadataTests(unittest.TestCase):
    def setUp(self):
        # Test-only replacement of the bottom identity resolver, no production
        # CLI/environment can admit synthetic tool bytes.
        import hashlib
        self.fake_sha = hashlib.sha256(b"TEST ONLY; never executable as a program").hexdigest()
        self.patch = patch.object(metadata, "KNOWN_PROCESSOR_SHA", self.fake_sha)
        self.patch.start(); self.addCleanup(self.patch.stop)

    def fixture(self, architectures=("arm64",)):
        owned = tempfile.TemporaryDirectory(prefix="wave3d31-metadata-", dir=ARTIFACTS)
        self.addCleanup(owned.cleanup)
        return Fixture(Path(owned.name).resolve(), architectures)

    def assert_refused(self, fixture):
        with self.assertRaises((metadata.MetadataError, ValueError, OSError, subprocess.SubprocessError)):
            fixture.install()
        self.assertEqual(fixture.calls, [])
        self.assertEqual(list(fixture.resources.iterdir()), [])

    def test_host_and_universal_extract_once_with_exact_paths_and_all_resources(self):
        for architectures in [("arm64",), ("x86_64",), ("arm64", "x86_64")]:
            with self.subTest(architectures=architectures):
                f = self.fixture(architectures)
                inventory = f.install()
                self.assertEqual(len(f.calls), 1)
                args = f.calls[0]
                self.assertEqual(args.count("--target-triple"), len(architectures))
                self.assertEqual(args[args.index("--binary-file") + 1], str(f.binary))
                self.assertEqual(args[0], f.receipt["processor"]["path"])
                for item in f.receipt["slices"]:
                    self.assertIn(item["triple"], args)
                    self.assertIn(item["source_list"]["path"], args)
                    self.assertIn(item["constant_list"]["path"], args)
                    self.assertIn(item["link_dependency"]["path"], args)
                self.assertEqual(args.count("--stringsdata-file"), 1)
                self.assertIn("--compile-time-extraction", args)
                self.assertIn("--deployment-aware-processing", args)
                self.assertNotIn("--force", args)
                self.assertNotIn("--force-metadata-output", args)
                self.assertEqual(set(inventory), {
                    "Metadata.appintents/version.json", "Metadata.appintents/extract.actionsdata",
                    "Metadata.appintents/objects.appintentsmanifest", "en.lproj/AppShortcuts.strings", "Extra resource.dat"})
                self.assertEqual({str(p.relative_to(f.resources)) for p in f.resources.rglob("*") if p.is_file()}, set(inventory))
                self.assertFalse(Path(args[-1]).exists(), "owned extraction staging must self-clean")
                self.assertTrue((f.resources / "en.lproj/AppShortcuts.strings").read_text().startswith("TEST ONLY"))

    def test_stringsdata_outputs_are_fresh_owned_auxiliary_files_not_installed_resources(self):
        for architectures in [("arm64",), ("arm64", "x86_64")]:
            with self.subTest(architectures=architectures):
                f = self.fixture(architectures)
                inventory = f.install()
                output = Path(f.calls[0][-1])
                self.assertEqual(len(f.strings_outputs), 1)
                self.assertEqual(len({path for path, _ in f.strings_outputs}), 1)
                for path, existed in f.strings_outputs:
                    self.assertFalse(existed, "extractor output must not require a preexisting file")
                    self.assertTrue(path.is_relative_to(output.parent / "stringsdata"))
                    self.assertFalse(path.is_relative_to(output))
                    self.assertFalse(path.exists(), "auxiliary output staging must self-clean")
                self.assertFalse(any(name.endswith(".stringsdata") for name in inventory))
                self.assertFalse(any(f.resources.rglob("*.stringsdata")))

    def test_stringsdata_output_request_is_optional_and_rejects_caller_paths(self):
        for omitted in [True, False]:
            f = self.fixture()
            if omitted: f.receipt["slices"][0].pop("stringsdata")
            else: f.receipt["slices"][0]["stringsdata"] = False
            f.install()
            self.assertEqual(f.strings_outputs, [])
            self.assertNotIn("--stringsdata-file", f.calls[0])
        for value in [[], {}, "/caller/chosen/output.stringsdata", 1]:
            f = self.fixture(); f.receipt["slices"][0]["stringsdata"] = value
            self.assert_refused(f)

    def test_source_addition_during_extraction_or_copy_refuses_and_rolls_back(self):
        for phase in ["extraction", "copy"]:
            with self.subTest(phase=phase):
                f = self.fixture()
                for item in f.receipt["slices"]: item.pop("stringsdata")
                marker = f.write(f.resources / "AppIcon.icns", "owned icon")
                def add_source():
                    f.write(f.source_root / "AddedDuringPackaging.swift", "struct AddedDuringPackaging {}")
                def runner(args, **options):
                    result = f.runner(args, **options)
                    if phase == "extraction": add_source()
                    return result
                def copier(source, destination):
                    shutil.copytree(source, destination)
                    if phase == "copy": add_source()
                with self.assertRaisesRegex(metadata.MetadataError, "inputs changed"):
                    f.install(runner=runner, copier=copier)
                self.assertEqual(list(f.resources.iterdir()), [marker])
                self.assertEqual(marker.read_text(), "owned icon")
                self.assertFalse(Path(f.calls[0][-1]).exists())

    def test_missing_inputs_and_missing_files_refuse_before_runner(self):
        f = self.fixture()
        with self.assertRaises(metadata.MetadataError):
            metadata.install_metadata(None, f.binary, f.resources, f.source_root, f.architectures, runner=f.runner)
        for key in ["binary", "processor", "compiler", "sdk_settings", "xcode_version_file"]:
            with self.subTest(key=key):
                f = self.fixture(); Path(f.receipt[key]["path"]).unlink(); self.assert_refused(f)
        for key in ["source_list", "constant_list", "link_dependency"]:
            f = self.fixture(); Path(f.receipt["slices"][0][key]["path"]).unlink(); self.assert_refused(f)

    def test_wrong_module_deployment_toolchain_sdk_and_architecture(self):
        for key, value in [("module", "ParlaCore"), ("deployment", "14.0"), ("schema", 2),
                           ("xcode_version", "wrong"), ("toolchain", "/not/a/toolchain"), ("sdk", "/not/an/sdk")]:
            with self.subTest(key=key):
                f = self.fixture(); f.receipt[key] = value; self.assert_refused(f)
        for triple in ["arm64-apple-macos14.0", "x86_64-apple-macos13.3", "arm64-apple-ios13.3"]:
            f = self.fixture(); f.receipt["slices"][0]["triple"] = triple; self.assert_refused(f)
        f = self.fixture(); f.architectures = ("arm64", "x86_64"); self.assert_refused(f)
        f = self.fixture(("arm64", "x86_64")); f.receipt["slices"].pop(); self.assert_refused(f)

    def test_source_and_binary_identity_and_freshness(self):
        for key in ["binary", "processor", "compiler", "sdk_settings"]:
            f = self.fixture(); Path(f.receipt[key]["path"]).write_text("identity mismatch"); self.assert_refused(f)
        f = self.fixture(); f.source.write_text("changed source"); self.assert_refused(f)
        f = self.fixture(); f.receipt["sources"] = []; self.assert_refused(f)
        f = self.fixture(); f.write(f.source_root / "extra.swift", "struct Extra {}"); self.assert_refused(f)
        f = self.fixture(); os.utime(f.source, ns=(f.now,) * 2); self.assert_refused(f)
        f = self.fixture(); f.receipt["started_ns"] -= 3601 * 1_000_000_000; self.assert_refused(f)
        f = self.fixture(); f.receipt["completed_ns"] = f.now + 1; self.assert_refused(f)
        f = self.fixture(); os.utime(f.binary, ns=(f.now - 11_000_000_000,) * 2); self.assert_refused(f)

    def test_constants_nonempty_current_declarations_and_no_shared_arch_output(self):
        for content in ["[]", "{}", "invalid", '[{"typeName":"ParlaCore.StartParlaDictationIntent"}]']:
            f = self.fixture(); item = f.receipt["slices"][0]
            path = Path(item["constants"][0]["path"]); path.write_text(content)
            os.utime(path, ns=(f.now - 5_000_000_000,) * 2)
            item["constants"][0] = f.record(path); self.assert_refused(f)
        f = self.fixture(); path = Path(f.receipt["slices"][0]["constants"][0]["path"])
        os.utime(path, ns=(f.now - 11_000_000_000,) * 2); self.assert_refused(f)
        f = self.fixture(("arm64", "x86_64")); a, b = f.receipt["slices"]
        b["constants"], b["constant_list"] = a["constants"], a["constant_list"]; self.assert_refused(f)
        f = self.fixture(); item = f.receipt["slices"][0]
        listing = Path(item["source_list"]["path"]); listing.write_text(str(f.source) + "\n/extra.swift\n")
        item["source_list"] = f.record(listing); self.assert_refused(f)

    def test_macho_platform_deployment_and_universal_headers(self):
        for offset, value in [(0, 0), (12, 6), (40, 2), (44, 0xE0000)]:
            f = self.fixture(); data = bytearray(f.binary.read_bytes()); struct.pack_into("<I", data, offset, value)
            f.binary.write_bytes(data); os.utime(f.binary, ns=(f.now - 1_000_000_000,) * 2)
            f.receipt["binary"] = f.record(f.binary); self.assert_refused(f)
        f = self.fixture(("arm64", "x86_64")); data = bytearray(f.binary.read_bytes()); struct.pack_into(">I", data, 36, 48)
        f.binary.write_bytes(data); os.utime(f.binary, ns=(f.now - 1_000_000_000,) * 2)
        f.receipt["binary"] = f.record(f.binary); self.assert_refused(f)

    def test_failed_empty_invalid_and_changed_input_outputs_never_install_or_sign(self):
        for mode in ["failure", "empty", "invalid-json", "missing-action", "empty-version", "symlink", "input-race"]:
            with self.subTest(mode=mode):
                f = self.fixture(); f.mode = mode; events = []
                with self.assertRaises((metadata.MetadataError, ValueError, subprocess.SubprocessError)):
                    f.install()
                    events.append("sign")  # Inert ordering witness, never a signer.
                self.assertEqual(events, [])
                self.assertEqual(list(f.resources.iterdir()), [])
                self.assertEqual(len(f.calls), 1)
                self.assertFalse(Path(f.calls[0][-1]).exists())

    def test_partial_copy_failure_rolls_back_and_existing_resources_are_preserved(self):
        f = self.fixture(); marker = f.write(f.resources / "AppIcon.icns", "owned icon")
        def fail_copy(source, destination):
            shutil.copytree(source, destination)
            raise OSError("test-only copy failure")
        with self.assertRaises(OSError): f.install(copier=fail_copy)
        self.assertEqual(list(f.resources.iterdir()), [marker])
        f = self.fixture(); stale = f.write(f.resources / "Metadata.appintents/version.json", "stale fixture")
        with self.assertRaises(metadata.MetadataError): f.install()
        self.assertEqual(stale.read_text(), "stale fixture")
        self.assertFalse((f.resources / "en.lproj").exists())

    def test_empty_dependency_lists_are_explicit_and_missing_group_refuses(self):
        f = self.fixture()
        for key in ["metadata", "static_metadata"]:
            path = Path(f.receipt[key]["list"]["path"]); path.write_text("")
            f.receipt[key] = {"list": f.record(path), "files": []}
        self.assertTrue(f.install())
        f = self.fixture(); del f.receipt["metadata"]
        with self.assertRaises(KeyError): f.install()
        self.assertEqual(f.calls, [])

    def test_known_two_file_preview_and_opaque_manifest_when_present(self):
        f = self.fixture(); f.mode = "missing-manifest"
        self.assertNotIn("Metadata.appintents/objects.appintentsmanifest", f.install())
        for content in (b"", None):
            f = self.fixture()
            def runner(args, **options):
                result = f.runner(args, **options)
                path = Path(args[-1]) / "Metadata.appintents/objects.appintentsmanifest"
                if content is None:
                    path.unlink(); path.mkdir()
                else: path.write_bytes(content)
                return result
            with self.assertRaises(metadata.MetadataError): f.install(runner=runner)
            self.assertEqual(list(f.resources.iterdir()), [])

    def test_present_manifest_symlink_or_unowned_file_refuses(self):
        for mode in ("symlink", "unowned"):
            f = self.fixture()
            def runner(args, **options):
                result = f.runner(args, **options)
                manifest = Path(args[-1]) / "Metadata.appintents/objects.appintentsmanifest"
                if mode == "symlink":
                    manifest.unlink(); manifest.symlink_to(f.source)
                return result
            real_stat = Path.stat
            def output_stat(path, *args, **options):
                value = real_stat(path, *args, **options)
                if mode == "unowned" and path.name == "objects.appintentsmanifest":
                    fields = list(value); fields[4] = value.st_uid + 1
                    return os.stat_result(fields)
                return value
            with patch.object(Path, "stat", output_stat), self.assertRaises(metadata.MetadataError):
                f.install(runner=runner)
            self.assertEqual(list(f.resources.iterdir()), [])

    def test_unknown_tool_and_structured_schema_references_refuse(self):
        f = self.fixture(); tool = Path(f.receipt["processor"]["path"])
        tool.write_text("different tool"); f.receipt["processor"] = f.record(tool); self.assert_refused(f)
        mutations = [
            lambda v: v.update(version=2),
            lambda v: v["generator"].update(version="other"),
            lambda v: v["actions"]["StartParlaDictationIntent"].update(identifier="other"),
            lambda v: v["actions"]["StartParlaDictationIntent"].update(fullyQualifiedTypeName="Other.StartParlaDictationIntent"),
            lambda v: v["actions"]["StopParlaDictationIntent"].update(outputType={}),
            lambda v: v.update(autoShortcutProviderMangledName="other"),
            lambda v: v["autoShortcuts"][0].update(actionIdentifier="StopParlaDictationIntent"),
            lambda v: v["autoShortcuts"][0].update(phraseTemplates=[]),
            lambda v: v["entities"]["ParlaAutomationResultEntity"].update(defaultQueryIdentifier="other"),
            lambda v: v["entities"]["ParlaAutomationResultEntity"]["properties"][0].update(valueType={}),
            lambda v: v["entities"]["ParlaAutomationResultEntity"]["properties"][0].update(title={"key": "Other"}),
            lambda v: v["queries"]["ParlaAutomationResultQuery"].update(entityType="other"),
            lambda v: v["queries"]["ParlaAutomationResultQuery"].update(resultValueType={}),
        ]
        for mutation in mutations:
            f = self.fixture()
            def runner(args, **options):
                result = f.runner(args, **options)
                path = Path(args[-1]) / "Metadata.appintents/extract.actionsdata"
                value = json.loads(path.read_text()); mutation(value); path.write_text(json.dumps(value))
                return result
            with self.assertRaises(metadata.MetadataError): f.install(runner=runner)
            self.assertEqual(list(f.resources.iterdir()), [])
        for version in ({"toolsVersion": metadata.KNOWN_XCODE, "version": "4.0"}, {"toolsVersion": "other", "version": "3.0"}):
            f = self.fixture()
            def runner(args, **options):
                result = f.runner(args, **options)
                (Path(args[-1]) / "Metadata.appintents/version.json").write_text(json.dumps(version))
                return result
            with self.assertRaises(metadata.MetadataError): f.install(runner=runner)

    def test_duplicate_json_key_cannot_hide_an_action(self):
        f = self.fixture()
        def runner(args, **options):
            result = f.runner(args, **options)
            path = Path(args[-1]) / "Metadata.appintents/extract.actionsdata"
            path.write_text(path.read_text().replace('"actions": {', '"actions": {}, "actions": {', 1))
            return result
        with self.assertRaisesRegex(metadata.MetadataError, "duplicate"): f.install(runner=runner)

    def test_real_packaging_hook_has_no_native_fallback_or_external_receipt(self):
        script = (SCRIPT.parent / "make-app.sh").read_text()
        hook = script.index("    exec python3 scripts/build-app-intents.py")
        self.assertLess(script.index("PARLA_NATIVE_INTENTS:-0"), hook)
        self.assertLess(hook, script.index("swift build"))
        self.assertIn('--output-root "$PARLA_NATIVE_OUTPUT_ROOT" --architectures "${PARLA_NATIVE_ARCHITECTURES:-host}"', script)
        self.assertIn("External native receipts are not accepted", script)
        self.assertNotIn("app-intents-metadata.py", script)
        self.assertIn('[ -n "$SIGN_ID" ] && ARCHS="--arch arm64 --arch x86_64"', script)
        self.assertIn('Native intents metadata omitted; Shortcuts support remains unqualified.', script)
        after_sign = script[script.index("  codesign "):]
        for mutation in ["cp ", "install_name_tool", "app-intents-metadata.py", "cat >"]:
            self.assertNotIn(mutation, after_sign)
        self.assertIn("set -euo pipefail", script)


if __name__ == "__main__":
    unittest.main(verbosity=2)
