"""SYNTHETIC producer/packager entry tests. No native tool runs or real metadata.

Only bottom command execution and selected-tool resolution are replaced. Tests
exercise production source/map/receipt validation, assembly, rollback and entry.
"""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shlex
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from test_app_intents_metadata import Fixture, schema_actions

SCRIPT = Path(__file__).resolve().parents[1] / "build-app-intents.py"
spec = importlib.util.spec_from_file_location("parla_producer", SCRIPT)
producer = importlib.util.module_from_spec(spec); spec.loader.exec_module(producer)
m = producer.metadata


class NativeFixture:
    def __init__(self, directory):
        self.repo = directory / "repo with spaces ' $ ;"
        self.output = directory / "output with spaces ' $ ;"
        self.calls, self.mode, self.hook = [], "valid", lambda name: None
        self.write(self.repo / "Package.swift", "// TEST ONLY local package")
        self.write(self.repo / "Sources/Parla/Intents.swift", "\n".join("struct " + name + " {}" for name in sorted(m.DECLARATIONS)))
        self.write(self.repo / "Sources/ParlaCore/Core.swift", "struct Core {}")
        for name in ("AppIcon.icns", "menubar.png", "Parla.entitlements"):
            self.write(self.repo / "Resources" / name, "SYNTHETIC " + name)
        framework = self.repo / "Frameworks/whisper.xcframework/macos-arm64_x86_64/whisper.framework"
        self.write(framework / "Versions/A/whisper", b"SYNTHETIC framework")
        (framework / "Versions/Current").symlink_to("A")
        (framework / "whisper").symlink_to("Versions/Current/whisper")
        for name in ("build-app-intents.py", "app-intents-metadata.py", "make-app.sh"):
            self.write(self.repo / "scripts" / name, (SCRIPT.parent / name).read_bytes())
        toolchain, sdk = directory / "Toolchain", directory / "SDK"
        names = ("swift", "swiftc", "swift-frontend", "appintentsmetadataprocessor", "ld", "clang", "lipo", "install_name_tool", "otool", "codesign", "plutil", "git")
        paths = {name: self.write(toolchain / "usr/bin" / name, "SYNTHETIC " + name) for name in names}
        # swiftc resolves to the selected frontend just as the real multiplexer.
        paths["swiftc"].unlink(); paths["swiftc"].symlink_to("swift-frontend")
        for p in paths.values(): p.chmod(0o700)
        self.write(sdk / "SDKSettings.json", '{"testOnly":true}')
        version = self.write(directory / "version.plist", plistlib.dumps({"ProductBuildVersion": m.KNOWN_XCODE}))
        discovery = self.write(toolchain / "usr/share/swift/SwiftConstantValues/AppIntents.json", json.dumps({"version": 1, "constValueProtocols": ["AppIntent", "AppEntity", "EntityQuery", "AppShortcutsProvider"]}))
        self.tools = {"paths": paths, "toolchain": str(toolchain), "sdk": str(sdk), "xcode_version": m.KNOWN_XCODE,
                      "compiler": producer.record(paths["swift-frontend"]), "processor": producer.record(paths["appintentsmetadataprocessor"]),
                      "sdk_settings": producer.record(sdk / "SDKSettings.json"), "xcode_version_file": producer.record(version), "discovery": producer.record(discovery)}

    write = staticmethod(Fixture.write)

    def command(self, commands, argv, name):
        argv = [str(a) for a in argv]; self.calls.append((name, argv))
        start = time.time_ns(); stdout = b""; stderr = b""; driver_outputs = {}
        if name.startswith("build-") and name != "build-number":
            arch = producer.option(argv, "--arch"); directory = Path(producer.option(argv, "--scratch-path")).parent
            binary_dir = directory / "build" / (arch + "-apple-macosx/release")
            if self.mode == "build-fail": raise m.MetadataError("SYNTHETIC build failure")
            actual = []
            objects = []
            for module in ("ParlaCore", "Parla"):
                sources = m.swift_sources(self.repo / "Sources" / module)
                module_dir = binary_dir / (module + ".build")
                listing = self.write(module_dir / "sources", "\n".join(shlex.quote(str(p)) for p in sources))
                module_objects = [self.write(module_dir / (p.name + ".o"), "SYNTHETIC root object " + p.name) for p in sources]
                objects.extend(module_objects)
                mapping = self.write(module_dir / "output-file-map.json", json.dumps({"": {"swift-dependencies": str(module_dir / "primary.swiftdeps")}, **{str(p): {"object": str(o)} for p, o in zip(sources, module_objects)}}))
                const = self.write(module_dir / (module + ".swiftconstvalues"), json.dumps([] if module == "ParlaCore" else [{"typeName": "Parla." + n} for n in sorted(m.DECLARATIONS)]))
                if self.mode == "empty-constants" and module == "Parla": const.write_text("[]")
                if self.mode == "dependent-metadata" and module == "ParlaCore": const.write_text('[{"typeName":"ParlaCore.FutureIntent"}]')
                protocols = argv[argv.index("-const-gather-protocols-file") + 4]
                driver = [str(self.tools["paths"]["swiftc"]), "-c", "-module-name", module, "-output-file-map", str(mapping), "@" + str(listing), "-emit-const-values"]
                frontend = [str(self.tools["paths"]["swift-frontend"]), "-frontend", "-c", *map(str, sources), "-module-name", module,
                    "-target", arch + "-apple-macosx13.3", "-sdk", self.tools["sdk"], "-num-threads", "2", "-const-gather-protocols-file", protocols,
                    "-emit-const-values-path", str(const)]
                original = commands.root / "tooltmp" / ("TemporaryDirectory." + arch + module) / "supplementaryOutputs-1"
                retained = self.write(commands.root / "driver-outputs" / (arch + module) / "supplementaryOutputs-1", json.dumps({str(sources[0]): {"const-values": str(const)}}))
                driver_outputs[str(original)] = str(retained)
                frontend[-2:] = ["-supplementary-output-file-map", str(original)]
                if self.mode == "wrong-supplementary" and module == "Parla": retained.write_text('{}')
                if self.mode == "wrong-target": frontend[frontend.index("-target") + 1] = "other-apple-macosx13.3"
                if self.mode == "wrong-map" and module == "Parla": mapping.write_text('{"":{}}')
                if self.mode == "repeated-compile" and module == "Parla": actual.append(frontend)
                actual.extend([driver, frontend])
            dependency = Path(argv[argv.index("-dependency_info") + 2]); self.write(dependency, "SYNTHETIC dependency")
            binary = self.write(binary_dir / "Parla", Fixture.macho((arch,)))
            link_list = self.write(binary_dir / "Parla.product/Objects.LinkFileList", shlex.join(list(map(str, objects))))
            actual.append([str(self.tools["paths"]["swiftc"]), "-emit-executable", "-o", str(binary), "-dependency_info", str(dependency), "@" + str(link_list)])
            self.write(binary_dir / "description.json", json.dumps({"targetDependencyMap": {"Parla": ["ParlaCore", "whisper"], "ParlaCore": ["whisper"]}}))
            stdout = ("\n".join(shlex.join(a) for a in actual) + "\n").encode()
        elif name.startswith("bin-path-"):
            arch = producer.option(argv, "--arch")
            stdout = str(Path(producer.option(argv, "--scratch-path")) / (arch + "-apple-macosx/release")).encode() + b"\n"
        elif name == "lipo": self.write(Path(producer.option(argv, "-output")), Fixture.macho(("arm64", "x86_64")))
        elif name == "version": stdout = b"v1.2.3\n"
        elif name == "build-number": stdout = b"123\n"
        elif name == "extract":
            if self.mode == "extract-fail": raise m.MetadataError("SYNTHETIC extraction failure")
            output = Path(producer.option(argv, "--output"))
            self.write(output / "Metadata.appintents/version.json", json.dumps({"toolsVersion": m.KNOWN_XCODE, "version": "3.0"}))
            self.write(output / "Metadata.appintents/extract.actionsdata", json.dumps(schema_actions()))
            self.write(output / "en.lproj/AppShortcuts.strings", "SYNTHETIC full localization")
            if "--stringsdata-file" in argv: self.write(Path(producer.option(argv, "--stringsdata-file")), "SYNTHETIC auxiliary")
        elif name == "rpath":
            # Model a controlled binary mutation while preserving valid headers.
            with Path(argv[-1]).open("ab") as stream: stream.write(b"SYNTHETIC rpath")
        elif name.startswith("sign-"):
            if self.mode == "sign-fail": raise m.MetadataError("SYNTHETIC signing failure")
            app = Path(argv[-1])
            if name == "sign-app": self.write(app / "Contents/_CodeSignature/CodeResources", "SYNTHETIC seal")
        elif name == "verify-app" and self.mode == "verify-fail": raise m.MetadataError("SYNTHETIC seal failure")
        self.hook(name)
        end = time.time_ns()
        command = {"synthetic": True, "argv": argv, "pid": 0, "exit": 0, "started_ns": start, "completed_ns": end}
        path = commands.directory / (str(len(self.calls)) + "-" + name + ".json")
        producer.write_json(path, command)
        return {**command, "stdout": stdout, "stderr": stderr, "record": producer.record(path), "driver_outputs": driver_outputs}

    @contextlib.contextmanager
    def injected(self):
        fixture = self
        def run(commands, argv, name): return fixture.command(commands, argv, name)
        with patch.object(producer.Commands, "run", run), patch.object(producer, "resolve_tools", lambda commands: self.tools), \
             patch.object(m, "KNOWN_PROCESSOR_SHA", self.tools["processor"]["sha256"]), \
             patch.object(producer, "__file__", str(self.repo / "scripts/build-app-intents.py")), \
             patch.dict(os.environ, {"PARLA_SIGN_IDENTITY": "", "PARLA_APPINTENTS_INPUTS": ""}):
            yield

    def entry(self, architectures="host", package=True):
        args = ["--output-root", str(self.output), "--architectures", architectures]
        if package: args.append("--package")
        with self.injected(), contextlib.redirect_stdout(io.StringIO()): producer.main(args)
        return json.loads((self.output / ("package-result.json" if package else "receipt.json")).read_text())


class ProducerTests(unittest.TestCase):
    def fixture(self):
        owned = tempfile.TemporaryDirectory(prefix="wave3d31-producer-", dir="/tmp/parla-implementation-2026-10-28")
        self.addCleanup(owned.cleanup)
        return NativeFixture(Path(owned.name).resolve())

    def test_host_architectures_and_universal_build_once_exact_receipt_and_one_extraction(self):
        for host, choice, arches in (("arm64", "host", ["arm64"]), ("x86_64", "host", ["x86_64"]), ("arm64", "universal", ["arm64", "x86_64"])):
            with self.subTest(host=host, choice=choice), patch.object(producer.platform, "machine", return_value=host):
                f = self.fixture(); result = f.entry(choice)
                receipt = json.loads((f.output / "receipt.json").read_text())
                names = [name for name, _ in f.calls]
                self.assertEqual([name for name in names if name.startswith("build-") and name != "build-number"], ["build-" + a for a in arches])
                self.assertEqual([name for name in names if name.startswith("bin-path-")], ["bin-path-" + a for a in arches])
                self.assertEqual(names.count("extract"), 1); self.assertEqual(names.count("lipo"), len(arches) - 1)
                extract = next(argv for name, argv in f.calls if name == "extract")
                self.assertEqual(producer.option(extract, "--binary-file"), receipt["binary"]["path"])
                self.assertEqual(extract.count("--target-triple"), len(arches)); self.assertEqual(extract.count("--stringsdata-file"), 1)
                for name, argv in f.calls:
                    if name.startswith("build-") and name != "build-number":
                        self.assertEqual(producer.option(argv, "--jobs"), "2")
                        self.assertIn("-emit-const-values", argv); self.assertNotIn("-supplementary-output-file-map", argv)
                        self.assertIn("--disable-automatic-resolution", argv)
                self.assertEqual(result["architectures"], arches)
                self.assertNotEqual(result["signed_binary_sha256"], receipt["binary"]["sha256"])
                self.assertEqual(producer.record(f.output / "Parla"), receipt["binary"])
                app = f.output / "Parla.app"
                self.assertTrue((app / "Contents/Resources/en.lproj/AppShortcuts.strings").exists())
                self.assertFalse(list((app / "Contents/Resources").rglob("*.stringsdata")))
                self.assertTrue((app / "Contents/Frameworks/whisper.framework/whisper").is_symlink())
                self.assertLess(names.index("rpath"), names.index("sign-framework")); self.assertLess(names.index("sign-framework"), names.index("sign-app"))
                self.assertFalse(list(f.output.rglob("*.running.json")))

    def test_build_contract_failures_emit_no_receipt(self):
        for mode in ("build-fail", "empty-constants", "dependent-metadata", "wrong-target", "wrong-map", "wrong-supplementary", "repeated-compile"):
            with self.subTest(mode=mode):
                f = self.fixture(); f.mode = mode
                with self.assertRaises(SystemExit): f.entry(package=False)
                self.assertFalse((f.output / "receipt.json").exists()); self.assertFalse((f.output / "Parla.app").exists())
                self.assertNotIn("extract", [name for name, _ in f.calls])

    def test_source_package_resource_tool_sdk_mutation_addition_removal_before_receipt(self):
        for change in ("source-add", "source-remove", "source-change", "package", "resource", "tool", "sdk", "discovery"):
            with self.subTest(change=change):
                f = self.fixture()
                def mutate(name):
                    if name != "bin-path-arm64": return
                    if change == "source-add": f.write(f.repo / "Sources/Parla/Added.swift", "struct Added {}")
                    elif change == "source-remove": (f.repo / "Sources/Parla/Intents.swift").unlink()
                    else:
                        path = {"source-change": f.repo / "Sources/Parla/Intents.swift", "package": f.repo / "Package.swift", "resource": f.repo / "Resources/AppIcon.icns",
                                "tool": f.tools["paths"]["ld"], "sdk": Path(f.tools["sdk_settings"]["path"]), "discovery": Path(f.tools["discovery"]["path"])}[change]
                        path.write_text("changed")
                f.hook = mutate
                with self.assertRaises(SystemExit): f.entry(package=False)
                self.assertFalse((f.output / "receipt.json").exists())

    def test_extraction_copy_sign_verify_failure_never_publishes_and_prior_bundle_survives(self):
        for mode in ("extract-fail", "copy-fail", "sign-fail", "verify-fail"):
            f = self.fixture(); f.mode = mode
            marker = f.write(f.repo / "Parla.app/prior", "prior protected bundle")
            with self.subTest(mode=mode):
                if mode == "copy-fail":
                    def fail_copy(source, target, **options):
                        shutil.copytree(source, target, **options); raise OSError("SYNTHETIC copy failure")
                    with patch.object(producer, "package", wraps=producer.package) as wrapped:
                        real = wrapped._mock_wraps
                        wrapped.side_effect = lambda *args: real(*args, copier=fail_copy)
                        with self.assertRaises(SystemExit): f.entry()
                else:
                    with self.assertRaises(SystemExit): f.entry()
                self.assertEqual(marker.read_text(), "prior protected bundle")
                self.assertFalse((f.output / "Parla.app").exists()); self.assertFalse((f.output / "package-result.json").exists())
                self.assertFalse((f.output / "staging/Parla.app").exists())
                if mode in ("extract-fail", "copy-fail"): self.assertNotIn("sign-app", [n for n, _ in f.calls])

    def test_input_changes_during_extraction_rpath_and_sign_refuse_publication(self):
        for phase in ("extract", "rpath", "sign-framework", "sign-app"):
            for change in ("source-add", "transitive", "tool", "binary", "constants", "link", "receipt"):
                with self.subTest(phase=phase, change=change):
                    f = self.fixture()
                    def mutate(name):
                        if name != phase: return
                        if change == "source-add": f.write(f.repo / "Sources/Parla/Added.swift", "struct Added {}")
                        else:
                            receipt = json.loads((f.output / "receipt.json").read_text())
                            path = {"transitive": f.repo / "Sources/ParlaCore/Core.swift", "tool": f.tools["paths"]["ld"],
                                "binary": f.output / "Parla", "constants": Path(receipt["slices"][0]["constants"][0]["path"]),
                                "link": Path(receipt["slices"][0]["link_dependency"]["path"]), "receipt": f.output / "receipt.json"}[change]
                            path.write_text("changed")
                    f.hook = mutate
                    with self.assertRaises(SystemExit): f.entry()
                    self.assertIn(phase, [n for n, _ in f.calls])
                    self.assertFalse((f.output / "Parla.app").exists()); self.assertFalse((f.output / "package-result.json").exists())

    def test_signed_bundle_mutation_during_verify_refuses(self):
        f = self.fixture()
        def mutate(name):
            if name == "verify-app": (f.output / "staging/Parla.app/Contents/Resources/menubar.png").write_text("changed")
        f.hook = mutate
        with self.assertRaises(SystemExit): f.entry()
        self.assertFalse((f.output / "Parla.app").exists())

    def test_existing_output_or_symlink_and_external_receipt_refuse_before_build(self):
        for mode in ("existing", "symlink", "external"):
            f = self.fixture()
            if mode == "existing": marker = f.write(f.output / "prior", "preserve")
            elif mode == "symlink": f.output.symlink_to(f.repo)
            with f.injected(), patch.dict(os.environ, {"PARLA_APPINTENTS_INPUTS": "handwritten.json" if mode == "external" else ""}):
                with self.assertRaises(SystemExit): producer.main(["--output-root", str(f.output), "--package"])
            self.assertEqual(f.calls, [])
            if mode == "existing": self.assertEqual(marker.read_text(), "preserve")

    def test_receipt_expiration_future_and_cross_architecture_fail_actual_validator(self):
        for change in ("expired", "future", "cross-arch"):
            f = self.fixture(); f.entry("universal", package=False)
            path = f.output / "receipt.json"; receipt = json.loads(path.read_text())
            if change == "expired": receipt["started_ns"] -= 3601 * 10**9
            elif change == "future": receipt["completed_ns"] += 3601 * 10**9
            else: receipt["slices"][1]["constants"] = receipt["slices"][0]["constants"]
            with f.injected(), self.assertRaises(m.MetadataError):
                m.validate_inputs(receipt, f.output / "Parla", f.repo / "Sources/Parla", ("arm64", "x86_64"), time.time_ns())

    def test_developer_id_policy_is_argument_only_no_identity_use(self):
        f = self.fixture(); app = f.output / "Parla.app"
        framework, application = producer.sign_arguments(app, f.repo, "TEST ONLY Developer ID")
        for args in (framework, application):
            self.assertIn("--timestamp", args); self.assertIn("runtime", args); self.assertIn("TEST ONLY Developer ID", args)
        self.assertIn("--entitlements", application); self.assertNotIn("--entitlements", framework)
        # Intercept the producer at entry to inspect architecture selection only.
        with f.injected(), patch.dict(os.environ, {"PARLA_SIGN_IDENTITY": "TEST ONLY Developer ID"}), patch.object(producer, "produce", side_effect=m.MetadataError("argument spy")) as spy:
            with self.assertRaises(SystemExit): producer.main(["--output-root", str(f.output), "--architectures", "host"])
            self.assertEqual(spy.call_args.args[2], ("arm64", "x86_64"))
        self.assertEqual(f.calls, [])

    def test_command_runner_retains_actual_temporary_driver_map_and_records_pid(self):
        f = self.fixture(); root = producer.fresh_root(f.output)
        commands = producer.Commands(root, f.repo)
        original = root / "tooltmp/TemporaryDirectory.SYNTHETIC/supplementaryOutputs-1"
        program = "from pathlib import Path; import time; p=Path(" + repr(str(original)) + "); p.parent.mkdir(); p.write_text('SYNTHETIC driver map'); time.sleep(0.8); p.unlink()"
        result = commands.run([sys.executable, "-c", program], "synthetic-map-lifecycle")
        self.assertEqual(result["exit"], 0); self.assertGreater(result["pid"], 0)
        retained = Path(result["driver_outputs"][str(original)])
        self.assertEqual(retained.read_text(), "SYNTHETIC driver map"); self.assertFalse(original.exists())
        self.assertLessEqual(result["started_ns"], retained.stat().st_mtime_ns)
        self.assertLessEqual(retained.stat().st_mtime_ns, result["completed_ns"])

    def test_unknown_tool_contract_refuses_without_compile(self):
        f = self.fixture(); f.tools["xcode_version"] = "UNKNOWN"
        with self.assertRaises(SystemExit): f.entry()
        self.assertFalse((f.output / "receipt.json").exists()); self.assertEqual(f.calls, [])

    def test_cooperative_signals_join_owned_tool_and_remove_only_app_stage(self):
        program = '''import os,signal,sys,time
from pathlib import Path
sys.path.insert(0,sys.argv[1])
from test_build_app_intents import NativeFixture,producer
from unittest.mock import patch
f=NativeFixture(Path(sys.argv[2])); phase=sys.argv[3]; mode=sys.argv[4]; signum=int(sys.argv[5])
marker=f.repo/'Parla.app/prior';f.write(marker,'prior protected bundle')
pidfile=f.repo.parent/'tool.pid'; original=f.command; run=producer.Commands.run; popen=producer.subprocess.Popen
def command(commands,argv,name):
    if name!=phase:return original(commands,argv,name)
    child="from pathlib import Path;import os,time;p=Path("+repr(str(pidfile))+");q=p.with_suffix('.child-pending');q.write_text(str(os.getpid()));q.rename(p);time.sleep(30)"
    def spawn(*args,**kwargs):
        process=popen(*args,**kwargs)
        pending=pidfile.with_suffix('.parent-pending');pending.write_text(str(process.pid));pending.rename(pidfile)
        os.kill(os.getpid(),signum)
        return process
    with patch.object(producer.subprocess,'Popen',spawn) if mode=='spawn' else patch.object(producer.subprocess,'Popen',popen):
        return run(commands,[sys.executable,'-c',child],name)
f.command=command
f.entry()
'''
        for phase in ("extract", "sign-app"):
            for signum in (signal.SIGINT, signal.SIGTERM):
                for mode in ("running", "spawn"):
                    with self.subTest(phase=phase, signum=signum, mode=mode):
                        owned = tempfile.TemporaryDirectory(prefix="wave3d31-signal-", dir="/tmp/parla-implementation-2026-10-28")
                        self.addCleanup(owned.cleanup)
                        root = Path(owned.name).resolve(); pidfile = root / "tool.pid"
                        output = root / "output with spaces ' $ ;"; repo = root / "repo with spaces ' $ ;"
                        with (root / "signal.log").open("wb") as log:
                            process = subprocess.Popen([sys.executable, "-c", program, str(Path(__file__).parent),
                                str(root), phase, mode, str(signum)], stdout=log, stderr=log)
                            tool = None
                            try:
                                deadline = time.monotonic() + 10
                                while not pidfile.exists() and process.poll() is None and time.monotonic() < deadline:
                                    time.sleep(0.02)
                                self.assertTrue(pidfile.exists(), "inert tool did not start")
                                tool = int(pidfile.read_text())
                                if mode == "running": process.send_signal(signum)
                                code = process.wait(timeout=15)
                                if manifest := os.environ.get("PARLA_PACKAGING_TEST_MANIFEST"):
                                    with open(manifest, "a") as records:
                                        records.write(json.dumps({"root": str(root), "parent_pid": process.pid,
                                            "tool_pid": tool, "signal": signum, "phase": phase, "mode": mode,
                                            "exit": code, "stage_left": (output / "staging/Parla.app").exists()}) + "\n")
                                self.assertFalse((output / "staging/Parla.app").exists())
                                with self.assertRaises(ProcessLookupError): os.kill(tool, 0)
                                self.assertEqual(code, 128 + signum)
                                self.assertFalse((output / "Parla.app").exists())
                                self.assertFalse((output / "package-result.json").exists())
                                self.assertFalse(list(output.rglob("*.running.json")))
                                self.assertEqual((repo / "Parla.app/prior").read_text(), "prior protected bundle")
                            finally:
                                if process.poll() is None: process.kill(); process.wait()
                                if tool is not None:
                                    try:
                                        if os.getpgid(tool) == tool: os.killpg(tool, signal.SIGKILL)
                                    except ProcessLookupError: pass


class ShellEntryTests(unittest.TestCase):
    def run_fixture(self, native, identity="", fail=False, optional=0, architecture="universal"):
        owned = tempfile.TemporaryDirectory(prefix="wave3d31-shell-", dir="/tmp/parla-implementation-2026-10-28")
        self.addCleanup(owned.cleanup); root = Path(owned.name).resolve()
        scripts = root / "scripts"; scripts.mkdir(); shutil.copy2(SCRIPT.parent / "make-app.sh", scripts / "make-app.sh")
        shutil.copy2(SCRIPT.parent / "make-dmg.sh", scripts / "make-dmg.sh")
        tools = root / "stub-tools"; tools.mkdir()
        fakebin = root / "fake-build"; fakebin.mkdir()
        Fixture.write(fakebin / "Parla", "SYNTHETIC never executed")
        Fixture.write(fakebin / "whisper.framework/whisper", "SYNTHETIC framework")
        for name in ("AppIcon.icns", "menubar.png"): Fixture.write(root / "Resources" / name, "SYNTHETIC icon")
        program = "#!" + sys.executable + "\n" + '''import json,os,sys
from pathlib import Path
name=Path(sys.argv[0]).name;root=Path(os.environ['FIXTURE_ROOT'])
with (root/'events.jsonl').open('a') as f:f.write(json.dumps([name,*sys.argv[1:]])+'\\n')
if name=='git': print('v1.0.0' if 'describe' in sys.argv else '1')
if name=='swift' and '--show-bin-path' in sys.argv: print(root/'fake-build')
if name=='python3': sys.exit(33 if os.environ.get('FAIL_FIXTURE')=='1' else 0)
'''
        for name in ("swift", "git", "python3", "install_name_tool", "codesign"):
            p = Fixture.write(tools / name, program); p.chmod(0o700)
        env = {**os.environ, "PATH": str(tools) + ":/usr/bin:/bin:/usr/sbin:/sbin", "FIXTURE_ROOT": str(root),
               "PARLA_NATIVE_INTENTS": str(native), "PARLA_NATIVE_OUTPUT_ROOT": str(root / "new output $ ;"),
               "PARLA_PARAKEET_PRODUCT": str(optional), "PARLA_PARAKEET_OUTPUT_ROOT": str(root / "optional output ' $ ;"),
               "PARLA_PARAKEET_POLICY": str(root / "owner policy ' $ ;.json"), "PARLA_PARAKEET_SDK_SOURCE": str(root / "sdk source ' $ ;"),
               "PARLA_NATIVE_ARCHITECTURES": architecture,
               "PARLA_SIGN_IDENTITY": identity, "PARLA_APPINTENTS_INPUTS": "", "FAIL_FIXTURE": "1" if fail else "0"}
        result = subprocess.run(["/bin/bash", str(scripts / "make-app.sh")], cwd=root, env=env, capture_output=True)
        events = [json.loads(line) for line in (root / "events.jsonl").read_text().splitlines()] if (root / "events.jsonl").exists() else []
        return result, events

    def test_native_off_keeps_existing_host_and_developer_id_flags_without_producer(self):
        for identity in ("", "SYNTHETIC Developer ID"):
            result, events = self.run_fixture(0, identity)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(any(e[0] == "python3" for e in events))
            compiles = [e for e in events if e[0] == "swift" and "--show-bin-path" not in e]
            self.assertEqual(len(compiles), 1)
            self.assertEqual(compiles[0].count("--arch"), 2 if identity else 0)
            signs = [e for e in events if e[0] == "codesign"]; self.assertEqual(len(signs), 2)
            if identity:
                self.assertIn("--timestamp", signs[0]); self.assertIn("runtime", signs[1]); self.assertIn("--entitlements", signs[1])

    def test_native_exec_propagates_failure_and_never_falls_back_to_another_build(self):
        for fail in (False, True):
            result, events = self.run_fixture(1, fail=fail)
            self.assertEqual(result.returncode, 33 if fail else 0)
            native = [e for e in events if e[0] == "python3"]; self.assertEqual(len(native), 1)
            self.assertIn("--package", native[0]); self.assertIn("--output-root", native[0])
            self.assertFalse(any(e[0] in {"swift", "codesign"} for e in events))


if __name__ == "__main__": unittest.main(verbosity=2)
