"""SYNTHETIC G3 actual-entry tests. No real Swift/signing/native/SDK payload IO.

The two exact pinned manifest TEXT fixtures exercise the strict overlay. Other
SDK/source/resources/tools/Mach-O/signatures are tiny, deliberately inert doubles.
Only selected-tool discovery and command/IO bottoms are injected.
"""
import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import select
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import zlib

from test_build_app_intents import NativeFixture, Fixture
import test_build_app_intents as b19fixtures

SCRIPT = Path(__file__).resolve().parents[1] / "build-parakeet-app.py"
spec = importlib.util.spec_from_file_location("g3_fixture_producer", SCRIPT)
g3 = importlib.util.module_from_spec(spec); spec.loader.exec_module(g3)
b = g3.b19
m = b.metadata

# Exact upstream manifest TEXT, compressed solely to keep the fixture readable.
MANIFESTS = {
    'Package.swift': 'eJydVltv4kYUfs+vOKIvIIEdCAGUtlLT3U27arJFgdU+VJH2eHwMU8Yz1sw4mP31PTaQmFsu9YNlzsy5zjffRxiCW8rEd7wxynUeyTpp9BUMgvMzmWbGehijWOCMPpITVmael7crNybXMVaWM0UesvVO+HXr0zwDfjSmdAWNG5XL+DqPpWm0K3um0CfGpu4K/qkM5ROkKP6eNIPHbr/VfrbKtW1Ytz3KstZqobexP2wiWxPnwu8GVjKyaFfNJ8tLtW0fj3ZGVaD6noenPfV6qCCRe4wUHc2RlP5Y+gsl35Lmw+3nw0ybDmPKSMekhaTSa2N9DvNc1dr2vq73ou+slU/jBp3/oHLnyX6zmGVk9yJUu+5QzKfoFhNSyeltYQjTOfGZUZRL5aEQieX6lsYuYI4OtIHtSYNTUlBwEGLb5KavL5SaKRV+bI0g56SeNdogjI6lr8AdLOekm3X4rVHXrnDWrjD4AT2qlfMPrdZuyQ+7PzP0c045MbnlXOHJkVIhVB5TecLXk/twjBYXRD78qmUiKQ4jnvY8RbsI0rixl8OSW4c/dhY8vr+IMgiydbfcnjDZCkwCCPdbz045mhhiaUl4Y1cQWcKFg+ssU8SziQmcnGkeFRgNPIUjQ94kaDam00l4mxdT78I/eln4lKTR2p3UsVvC5f6+8tShAoWHL3RnwPNR8SnbFJX8UdEJNG8mUyA9k5ragErBEBTqWc6c4lpBPdj4GGwSa1KojuKzTsjyaCkss3SyJ0R0rIPH8+Ai6NajNTc4kJsXTGSaM06MBdQxMKBhC4w1FvequVZLXDlQUi942txIRavwC/Np7+ctK/62Zlw2BdUXYyMzjhxID+jq4TzfC5P5jsk9fD9E9XfwFtmp+dNodN4Gfo9q5QSR1Mx309P3/9g92dmXW3V1eK3n3mfuKgxn0s/ziNGWhq/OOrSkCLnJMDZLrQzG4Xr64WERQe0ogx8y2ytKzEksXJ5yA5cJjkT3PO6T6A1EN4p6/e5Ft3eZXFx2cdjr9bAvBiPsXUTDfn84GIzOkwhjHFJvkIgBYuMoj7/EmK/x3j4dvLo/jxhGfxLGrLzjtbPUFVW8u7jX6Xavujc4vLe8Zw18AXe7Evei9Oyo7huZ9zBojXzvP11/vPv0XpJ95r6vXioXMjUp6ebBv87ot7Be4Mn5N01kyhvdu+X4lOrsrR5O5v8NoSYANfI/TL3rMTZiQb78upGFz+1xH6a9e0LFpQhjY6YDB03B3GGZUFmuN5CEDZ9AtKpY0mUsZ2Rb1RY2HAvrPGteWkpcwsyoOkupmYw40syWxGM0U75zOTGRXl4e0b9SVpu76j1RsizxWxXpZFun/sSJorjdqNrEs76gjUv1Loru8Kx19h9/QTM4',
    'Package@swift-6.2.swift': 'eJydV9tyIjcQfecrusgLVGDGYAwuJ/vg3Y2Trdhel2GzqUq5yhpNDygIaUrScNmHVD4iX5gvSUsD9nDxLfNAgUY6fTt9WsQx2IXIXNtpLW17jsYKrc6gH3VrYpZr4+CG8Skb40e03Ijc0evNmwtdqJSFlVocw8hD+JPfw4wpkaF1ZyBSVE5wJsHpDVQUTEIuCwtugnB/jTM9wqW7MZqjtUKN7z2gM0y4CH5FzMM+t9AgFNiV4j/sYFk0cyQ0coFPmFAWfvSetGAxEXziwZhcsJUFKdQ0gKEaC4URNIYe4OaKtneAcY65K70K1r0xx5aQFPTVCSk9lMewwModba5VKnwSMIVEKGZW4JgZo4N///4HKKMiE/RKK/id6xSh04964ZXV3o4H1Llra7IgLIyZo83Mee+jZq0mCScvQ4V3m6AbNaBHsRmeQf1CFiI9L1Kh662wnkvmMm1m9gz+CAv+iWaMfx42onmn12w9ropybVBdmwvPgfCiu16/WyMbnRbcbQNLkRgKuvGw8pxvm6fMkAeq7rl72FP1B5fIC8cSiQdtZP488+e5FK8x8+Hy076ldYShpFvxUXk+5w58eXQWiHGNV1Q5omtbUZaZFN9CD6wZBY2/TuHqPeRowErBsUVMyQ0mhZCuinpbWM8pOkt+J02gksH58Db+7fxjnApm1rBtreQKWJ7bFtCOxQRV8IJWqmglJ8l30AtVYpuCOm9GDn13enrUAvo8bZ5Vz1Bu19RqFEaeQRRFrccM3DWre0ejIWRGK4cqJe6rFO59x16vM4Dm3nuliKvWhuTQT6OL8QQKRR2pxphW4TyAwaAi98JeU6RzPJ8zIX2Z4d07yJi0eB89siD4dZAA++qxw4L0Ubpo++VGARJSL0nN9lI9t0JvwafRdTOqH2RqihkrpGug8mGko00qD7l4t028FHOCR8UFhuSv6fjA30oiwtrb2m0Hfeudf+oXzLoPpMcOzVdD1EKzgxB2XTE+GTE7HaLMnt7m2ULp3XAeljwz5N9CmylMmAWlYSMxZYdEexAHg3xr2TfPg0ATw337NKoCWepiKyhhK6jkB+aYXFl3V+mFwwXcs9bcduBu+2fO3IT8HurCEEb8ZLFwyWWRojfr9eCGGTZFdPEXFSZJnFAdJzNmptEsre/YMGhL+ENVpsKEWRrlZRSUD67zldc1Brebk22f3xRSYZA7TdMsMchIW87znFozjDArxopS4Gcape1A+dYGGnXqnfiyWI6cjX/u5vGDkfp28g4KP7n7fuWwjUvG3WOXwnaXNi6Go3WrktJKCQOQJDcFqZptRlWwm0OEpMaeQSjFJ5WhodRiHLQgf6h021iYH0XHUaeK1lgTR6w/YChmBRGLNNqLG7UKbJhUsrzqTVReFEZPt/KL7PaKvd+hE+dyexbHY+EmRULlncUvBhcblMgsUTKl2SE1S+My3HjfiaiSu+ibyHec4hPkU1vMKICTjJ3yzlHaQ97t806SdHud4073JDs+6bBBt9tlPd4/Zd3jZNDrDfr906MsYSkbYLef8T5jhxX2OfF7ScJ2++/F/UVCdfsFWUq34pvysFChN9/s3MvKuePdKw681b3He9QzvNu+Jj07RbZubq+Uun3Qitrd/nT+8eqnt6rao9h8oQu6jUkLpLCT6E+r1WtkJnL0R+VVGRnRRvvmyfqUzO+83c/M/0tCRXErartvevvEjeZTdP7bhVi6whw+42+tSH/laDJok5IcWGhw0g5D88JfX0tKwlpPIFmFe5bNaX6gKW+4/h/PAVjraMjM/EzJSBlleyEUiREhjY0XHq1IY60tkG6xJycHBo6fY43tcTmUwrv4NSA9GdZTfwT4cnm5HiNDR4LOTOrH5XLZGdSatf8AWCBQzA==',
}


class G3Fixture(NativeFixture):
    def __init__(self, directory):
        super().__init__(directory)
        self.sdk = directory / "SYNTHETIC sdk source ' $ ;"
        self.policy_path = directory / "owner source tool policy.json"
        self.g3mode = "valid"
        self.helper_binary = None
        for name in g3.SCRIPTS:
            self.write(self.repo / name, (SCRIPT.parent.parent / name).read_bytes())
        self.write(self.repo / g3.EXPECTED, (SCRIPT.parent.parent / g3.EXPECTED).read_bytes())
        self.write(self.repo / "Package.resolved", '{"SYNTHETIC":true}')
        self.write(self.repo / "Resources/Parla.entitlements", plistlib.dumps({}))
        optional = self.repo / "Optional/Parakeet"
        for name in ("Package.swift", "Package.resolved"):
            self.write(optional / name, (SCRIPT.parent.parent / "Optional/Parakeet" / name).read_bytes())
        for name in ("Sources/ParakeetHelper/Helper.swift", "Sources/ParlaParakeetHelper/main.swift"):
            self.write(optional / name, "// SYNTHETIC source; never compiled\n")
        self.write(optional / "Tests/ParakeetHelperTests/HelperTests.swift", "// SYNTHETIC retained test source; never compiled\n")
        for name, data in MANIFESTS.items(): self.write(self.sdk / name, zlib.decompress(base64.b64decode(data)))
        for name in ("LICENSE", "ThirdPartyLicenses/fastcluster-LICENSE.md", "ThirdPartyLicenses/NemoTextProcessing-LICENSE.md"):
            self.write(self.sdk / name, "SYNTHETIC tiny notice; no legal conclusion")
        for name in ("Sources/FluidAudio/Nemotron.swift", "Sources/FluidAudio/NemoTextNormalizer.swift"):
            self.write(self.sdk / name, "// SYNTHETIC full target source name positive control\n")
        for name in g3.RUNTIME: self.write(self.sdk / g3.RESOURCE_DIR / name, "SYNTHETIC tiny runtime resource " + name)
        for wrapper in ("FastClusterWrapper", "MachTaskSelfWrapper"):
            self.write(self.sdk / "Sources" / wrapper / "wrapper.cpp", "// SYNTHETIC wrapper\n")
            self.write(self.sdk / "Sources" / wrapper / "include/module.modulemap", "// SYNTHETIC module map\n")
        self.write(self.sdk / "Tests/FluidAudioTests/FixtureTests.swift", "// SYNTHETIC retained SDK test source; never compiled\n")
        for directory in ("TTS/LuxTts/Resources", "TTS/PocketTTS/Fixtures", "ASR/Parakeet/SlidingWindow/Fixtures"):
            self.write(self.sdk / "Tests/FluidAudioTests" / directory / "tiny-fixture.txt", "SYNTHETIC inert test resource; never shipped")
        self.tools["paths"]["nm"] = self.write(Path(self.tools["toolchain"]) / "usr/bin/nm", "SYNTHETIC nm")
        self.write(Path(self.tools["sdk"]) / "SDKSettings.json", '{"Version":"26.5","testOnly":true}')
        self.tools["sdk_settings"] = b.record(Path(self.tools["sdk"]) / "SDKSettings.json")
        self.swift_version = b"Apple Swift version 6.3.3 (SYNTHETIC ONLY)\n"
        self.policy = {"schema": 1, "sdkRevision": g3.PIN, "sdkFiles": {}, "sdkTreeSHA256": "",
                       "optionalFiles": {}, "mainFiles": {}, "toolFiles": {}, "swiftVersionSHA256": g3.sha(self.swift_version), "sdkVersion": "26.5",
                       "signing": {"team": "SYNTHETICTEAM", "helperIdentifier": g3.HELPER_ID, "parentIdentifier": m.BUNDLE_ID,
                                   "category": "Developer ID Application", "hardenedRuntime": True, "helperEntitlements": {}, "parentEntitlements": {}}}
        self.refresh_policy()

    def refresh_policy(self):
        for source, roots, name, links in ((self.sdk, g3.SDK_ROOTS, "sdkFiles", False),
                                          (self.repo / "Optional/Parakeet", g3.OPTIONAL_ROOTS, "optionalFiles", False),
                                          (self.repo, g3.MAIN_ROOTS, "mainFiles", True)):
            self.policy[name] = g3.identities(g3.bounded_inventory(source, roots, framework_links=links))
        self.policy["sdkTreeSHA256"] = g3.sha(g3.canonical(self.policy["sdkFiles"]))
        records = {name: b.record(path) for name, path in self.tools["paths"].items()}
        records.update({name: self.tools[name] for name in ("sdk_settings", "xcode_version_file", "discovery")})
        self.policy["toolFiles"] = {name: item["sha256"] for name, item in records.items()}
        self.save_policy()

    def save_policy(self): self.policy_path.write_bytes(g3.canonical(self.policy))

    def helper_build(self, commands, argv):
        directory = Path(b.option(argv, "--scratch-path")).parent
        binary_dir = directory / "scratch/arm64-apple-macosx/release"
        stage = commands.repo; sdk = stage / "Dependencies/FluidAudio"
        actual, swift_commands, linked = [], {}, []
        manifest = sdk / ("Package.swift" if self.g3mode == "base-manifest" else "Package@swift-6.2.swift")
        actual.append([str(self.tools["paths"]["swift-frontend"]), "-frontend", "-c", "-primary-file", str(manifest), "-package-description-version", "6.2.0"])
        for module, root in (("FluidAudio", sdk / "Sources/FluidAudio"), ("ParakeetHelper", stage / "Sources/ParakeetHelper"), (g3.HELPER, stage / "Sources/ParlaParakeetHelper")):
            sources = m.swift_sources(root)
            outputs = []
            for source in sources:
                outputs.append(self.write(binary_dir / (module + ".build") / (source.name + ".o"), "SYNTHETIC object " + source.name))
            linked.extend(outputs)
            listing = self.write(binary_dir / (module + ".build/sources"), shlex.join(list(map(str, sources))))
            mapping = self.write(binary_dir / (module + ".build/output-file-map.json"), json.dumps({"": {}, **{str(p): {"object": str(o)} for p, o in zip(sources, outputs)}}))
            driver = [str(self.tools["paths"]["swiftc"]), "-c", "-module-name", module, "@" + str(listing), "-output-file-map", str(mapping)]
            frontend = [str(self.tools["paths"]["swift-frontend"]), "-c", *map(str, sources), "-module-name", module,
                        "-target", "arm64-apple-macosx14.0", "-sdk", self.tools["sdk"], "-num-threads", "2"]
            if self.g3mode == "helper-target": frontend[frontend.index("-target") + 1] = "arm64-apple-macosx13.3"
            if self.g3mode == "helper-map": mapping.write_text('{}')
            if self.g3mode == "helper-repeat": actual.append(frontend)
            if self.g3mode == "engine-module": frontend.extend(["-I", "/SYNTHETIC/CNemo"])
            actual.extend([driver, frontend])
            swift_commands[module] = {"moduleName": module, "sources": list(map(str, sources)), "objects": list(map(str, outputs)), "otherArguments": frontend}
        for wrapper in ("FastClusterWrapper", "MachTaskSelfWrapper"):
            source = sdk / "Sources" / wrapper / "wrapper.cpp"
            obj = self.write(binary_dir / (wrapper + ".build/wrapper.cpp.o"), "SYNTHETIC wrapper object")
            linked.append(obj)
            actual.append([str(self.tools["paths"]["clang"]), "-c", str(source), "-o", str(obj), "-target", "arm64-apple-macosx14.0", "-isysroot", self.tools["sdk"], "-std=c++17"])
        if self.g3mode == "engine-object": linked.append(self.write(binary_dir / "CNemo.build/native.o", "SYNTHETIC forbidden object"))
        listing = self.write(binary_dir / "ParlaParakeetHelper.product/Objects.LinkFileList", shlex.join(list(map(str, linked))))
        self.helper_binary = self.write(binary_dir / g3.HELPER, self.helper_macho())
        if self.g3mode == "helper-arch": self.helper_binary.write_bytes(Fixture.macho(("x86_64",)))
        if self.g3mode == "helper-minos": self.helper_binary.write_bytes(self.helper_macho(minos=0xF0000))
        if self.g3mode == "helper-sdk": self.helper_binary.write_bytes(self.helper_macho(sdk=0x1A0400))
        actual.append([str(self.tools["paths"]["swiftc"]), "-emit-executable", "-o", str(self.helper_binary), "@" + str(listing)])
        graph = {"FluidAudio": ["FastClusterWrapper", "MachTaskSelfWrapper"], "ParakeetHelper": ["FluidAudio", "FastClusterWrapper", "MachTaskSelfWrapper"], g3.HELPER: ["ParakeetHelper", "FluidAudio", "FastClusterWrapper", "MachTaskSelfWrapper"], "FastClusterWrapper": [], "MachTaskSelfWrapper": []}
        if self.g3mode == "engine-graph": graph["FluidAudio"].append("NemoTextProcessing")
        description = {"traitConfiguration": {"default": {}}, "targetDependencyMap": graph, "swiftCommands": swift_commands, "pluginDescriptions": [], "generatedSourceTargetSet": [], "copyCommands": {}}
        if self.g3mode == "helper-traits": description["traitConfiguration"] = {"default": {"NemoTextProcessing": True}}
        if self.g3mode == "stock-resources": description["copyCommands"] = {"FluidAudio_FluidAudio.bundle/test": {}}
        self.write(binary_dir / "description.json", json.dumps(description))
        return ("\n".join(shlex.join(a) for a in actual) + "\n").encode()

    @staticmethod
    def helper_macho(minos=0xE0000, sdk=0x1A0500):
        return struct.pack("<8I", 0xFEEDFACF, 0x100000C, 0, 2, 1, 24, 0, 0) + struct.pack("<6I", 0x32, 24, 1, minos, sdk, 0)

    def command(self, commands, argv, name):
        argv = list(map(str, argv))
        special = name.startswith(("helper-", "policy-", "sdk-")) or name in ("find-nm", "sign-helper")
        if not special:
            original_repo = self.repo
            original_hook = self.hook
            if name.startswith(("build-", "bin-path-")) and name != "build-number": self.repo = commands.repo
            try:
                self.hook = lambda name: None
                try: result = super().command(commands, argv, name)
                except b19fixtures.m.MetadataError as error: raise m.MetadataError(str(error)) from error
                # Preserve actual bottom query stdout, used by owned VersionRecords.
                Path(result["record"]["path"]).with_suffix(".stdout").write_bytes(result["stdout"])
                result["cwd"] = str(commands.repo)
            finally:
                self.repo = original_repo
                self.hook = original_hook
            self.hook(name)
            return result
        start = time.time_ns(); self.calls.append((name, argv)); out = b""
        if name == "helper-build":
            if self.g3mode == "helper-fail": raise m.MetadataError("SYNTHETIC helper compile failure")
            out = self.helper_build(commands, argv)
        elif name == "helper-bin-path": out = str(Path(b.option(argv, "--scratch-path")) / "arm64-apple-macosx/release").encode()
        elif name == "find-nm": out = str(self.tools["paths"]["nm"]).encode()
        elif name == "helper-swift-version": out = self.swift_version
        elif name == "sdk-head": out = (("0" * 40) if self.g3mode == "git-pin" else g3.PIN).encode() + b"\n"
        elif name == "sdk-source-tree":
            entries = []
            for path in self.policy["sdkFiles"]:
                data = (self.sdk / path).read_bytes()
                blob = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
                if self.g3mode == "git-blob": blob = "0" * 40
                entries.append(b"100644 blob " + blob.encode() + b"\t" + path.encode() + b"\0")
            out = b"".join(entries)
        elif name.startswith("helper-nm-"): out = b"SYNTHETIC harmless Nemotron NemoTextNormalizer symbols\n" if self.g3mode != "engine-symbol" else b"_nemo_normalize\n"
        elif name == "helper-loads": out = b"SYNTHETIC /usr/lib/libSystem.B.dylib\n" if self.g3mode != "engine-load" else b"/SYNTHETIC/text_processing_rs.dylib\n"
        elif name == "sign-helper":
            if self.g3mode == "sign-helper-fail": raise m.MetadataError("SYNTHETIC signer refused")
            path = Path(argv[-1]); code = path / "Contents/MacOS" / g3.HELPER
            with code.open("ab") as stream: stream.write(b"SYNTHETIC signature changes final code bytes")
            self.write(path / "Contents/_CodeSignature/CodeResources", "SYNTHETIC signed seal")
            if self.g3mode == "sign-resource": self.write(path / "Contents/Resources/extra", "SYNTHETIC unexpected signing output")
            if self.g3mode == "extra-code": self.write(path / "Contents/MacOS/extra.dylib", "SYNTHETIC unexpected code")
            if self.g3mode == "sign-resource-change": self.write(path / "Contents/Resources/FluidAudio_FluidAudio.bundle" / g3.RUNTIME[0], "SYNTHETIC changed resource bytes")
            if self.g3mode == "resource-count":
                for i in range(513): self.write(path / "Contents/Resources" / ('extra-' + str(i)), "SYNTHETIC")
        elif name.startswith("policy-info-"):
            parent = name.endswith("parent")
            team = "WRONGTEAM" if self.g3mode == "wrong-team" else self.policy["signing"]["team"]
            identifier = m.BUNDLE_ID if parent else g3.HELPER_ID
            out = ("Identifier=" + identifier + "\nTeamIdentifier=" + team + "\nAuthority=Developer ID Application: SYNTHETIC (" + team + ")\nAuthority=Developer ID Certification Authority\nAuthority=Apple Root CA\nCodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=1\n").encode()
            if self.g3mode == "adhoc": out = out.replace(b"CodeDirectory", b"Signature=adhoc\nCodeDirectory")
            if self.g3mode == "no-runtime": out = out.replace(b"(runtime)", b"(none)")
            if self.g3mode == "wrong-identifier": out = out.replace(identifier.encode(), b"SYNTHETIC.wrong.identifier")
            if self.g3mode == "wrong-category": out = out.replace(b"Authority=Developer ID Application:", b"Authority=Apple Development:")
            if self.g3mode == "missing-signature": out = b"SYNTHETIC unsigned"
        elif name.startswith("policy-entitlements-"):
            out = plistlib.dumps({"com.apple.security.get-task-allow": True} if self.g3mode == "wrong-entitlements" else {})
        self.hook(name)
        command = {"synthetic": True, "argv": argv, "cwd": str(commands.repo), "pid": 0, "exit": 0, "started_ns": start, "completed_ns": time.time_ns()}
        path = commands.directory / (str(len(self.calls)) + "-" + name + ".json")
        b.write_json(path, command)
        path.with_suffix(".stdout").write_bytes(out)
        return {**command, "stdout": out, "stderr": b"", "record": b.record(path), "driver_outputs": {}}

    @contextlib.contextmanager
    def injected(self):
        fixture = self
        def run(commands, argv, name):
            commands.revalidate()
            result = fixture.command(commands, argv, name)
            commands.revalidate()
            return result
        with patch.object(b.Commands, "run", run), patch.object(b, "resolve_tools", lambda commands: self.tools), \
             patch.object(m, "KNOWN_PROCESSOR_SHA", self.tools["processor"]["sha256"]), \
             patch.object(g3, "__file__", str(self.repo / "scripts/build-parakeet-app.py")), \
             patch.dict(os.environ, {"PARLA_APPINTENTS_INPUTS": ""}):
            yield

    def entry(self, metadata=True):
        with self.injected(), contextlib.redirect_stdout(io.StringIO()):
            g3.main(["--output-root", str(self.output), "--policy", str(self.policy_path), "--sdk-source", str(self.sdk),
                     "--signing-identity", "SYNTHETIC ONLY signer never invoked", "--native-metadata", "1" if metadata else "0"])
        return json.loads((self.output / "package-result.json").read_text())


class G3Tests(unittest.TestCase):
    def fixture(self):
        owned = tempfile.TemporaryDirectory(prefix="wave4g3-synthetic-", dir="/tmp/parla-implementation-2026-10-28")
        self.addCleanup(owned.cleanup)
        return G3Fixture(Path(owned.name).resolve())

    def test_actual_entry_both_metadata_modes_post_sign_identity_generated_before_b19(self):
        for native in (False, True):
            with self.subTest(native=native):
                f = self.fixture(); original = g3.bounded_inventory(f.repo, g3.MAIN_ROOTS, framework_links=True)
                result = f.entry(native)
                names = [name for name, _ in f.calls]
                self.assertEqual(names.count("helper-build"), 1)
                self.assertEqual(names.count("build-arm64"), 1); self.assertEqual(names.count("build-x86_64"), 1)
                self.assertEqual(names.count("lipo"), 1); self.assertEqual(names.count("extract"), int(native))
                self.assertLess(names.index("sign-helper"), names.index("build-arm64"))
                self.assertLess(names.index("version"), names.index("helper-build"))
                self.assertLess(names.index("sign-framework"), names.index("sign-app"))
                identity = json.loads((f.output / "helper-identity.json").read_text())
                binary = f.output / "Parla.app" / g3.BUNDLE / "Contents/MacOS" / g3.HELPER
                self.assertEqual(identity["helperSHA256"], m.digest(binary))
                self.assertNotEqual(identity["helperSHA256"], m.digest(f.helper_binary))
                embedded = (f.output / "main-input" / g3.EXPECTED).read_text()
                self.assertIn(g3.canonical(identity).decode().strip(), embedded)
                receipt = json.loads((f.output / "main-build/receipt.json").read_text())
                self.assertIn(str(f.output / "main-input" / g3.EXPECTED), [r["path"] for r in receipt["sources"]])
                for arch in receipt["slices"]: self.assertIn(g3.EXPECTED.split('/')[-1], Path(arch["source_list"]["path"]).read_text())
                self.assertEqual(result["architectures"], ["arm64", "x86_64"])
                self.assertNotEqual(receipt["binary"]["sha256"], result["signed_binary_sha256"])
                self.assertEqual(g3.bounded_inventory(f.repo, g3.MAIN_ROOTS, framework_links=True), original)
                source = (f.output / "helper-source.json").read_bytes()
                self.assertNotIn(str(f.repo).encode(), source); self.assertNotIn(str(f.sdk).encode(), source)
                self.assertEqual(g3.sha(source), identity["sourceSHA256"])
                for name, argv in f.calls:
                    if name in ("sign-app", "sign-helper"): self.assertNotIn("--deep", argv)

    def test_absent_root_lockfile_is_valid_and_its_later_appearance_refuses(self):
        for native in (False, True):
            f = self.fixture()
            (f.repo / "Package.resolved").unlink()
            del f.policy['mainFiles']['Package.resolved']; f.save_policy()
            result = f.entry(native)
            self.assertEqual(result['architectures'], ['arm64', 'x86_64'])
            self.assertFalse((f.output / 'main-input/Package.resolved').exists())
        f = self.fixture()
        (f.repo / 'Package.resolved').unlink()
        del f.policy['mainFiles']['Package.resolved']; f.save_policy()
        def appearance(name):
            if name == 'helper-build': f.write(f.repo / 'Package.resolved', 'SYNTHETIC unexpected new input')
        f.hook = appearance
        with self.assertRaises(SystemExit): f.entry(False)
        self.assertIn('helper-build', [name for name, _ in f.calls])
        self.assertNotIn('sign-helper', [name for name, _ in f.calls])
        self.assertFalse((f.output / 'Parla.app').exists())

    def test_parent_resources_cannot_drift_before_signing_baseline(self):
        for native, phase in ((False, 'rpath'), (True, 'extract'), (True, 'rpath')):
            for relative in ('Contents/Resources/menubar.png', 'Contents/Info.plist'):
                with self.subTest(native=native, phase=phase, path=relative):
                    f = self.fixture()
                    def drift(name):
                        if name == phase:
                            path = f.output / 'staging/Parla.app' / relative
                            if path.suffix == '.plist':
                                value = plistlib.loads(path.read_bytes()); value['CFBundleDisplayName'] = 'SYNTHETIC unapproved mutation'
                                path.write_bytes(plistlib.dumps(value))
                            else: f.write(path, b'SYNTHETIC unapproved mutation')
                    f.hook = drift
                    with self.assertRaises(SystemExit): f.entry(native)
                    self.assertNotIn('sign-framework', [name for name, _ in f.calls])
                    self.assertNotIn('sign-app', [name for name, _ in f.calls])
                    self.assertFalse((f.output / 'package-result.json').exists())

    def test_unapproved_copy_resource_cannot_become_initial_baseline(self):
        for native in (False, True):
            with self.subTest(native=native):
                f = self.fixture(); package, copy = b.package, shutil.copytree
                def copier(source, target, **options):
                    result = copy(source, target, **options)
                    if Path(target).name == 'whisper.framework':
                        f.write(f.output / 'staging/Parla.app/Contents/Resources/unapproved.bin', b'SYNTHETIC unapproved extra')
                    return result
                def entry(*args, **options): return package(*args, **options, copier=copier)
                with patch.object(b, 'package', entry), self.assertRaises(SystemExit): f.entry(native)
                self.assertNotIn('sign-framework', [name for name, _ in f.calls])
                self.assertNotIn('sign-app', [name for name, _ in f.calls])
                self.assertFalse((f.output / 'package-result.json').exists())

    def test_policy_pin_maps_owner_and_input_refusals_before_compile(self):
        for mode in ("missing-signing", "pin", "tree", "duplicate", "oversize", "source-change", "source-add", "hardlink", "symlink", "default-traits", "unexpected-resource", "accessor-collision", "manifest-change", "existing-root"):
            with self.subTest(mode=mode):
                f = self.fixture()
                if mode == "missing-signing": del f.policy["signing"]
                elif mode == "pin": f.policy["sdkRevision"] = "0" * 40
                elif mode == "tree": f.policy["sdkTreeSHA256"] = "0" * 64
                elif mode == "source-change": (f.sdk / "Sources/FluidAudio/Nemotron.swift").write_text("changed")
                elif mode == "source-add": f.write(f.sdk / "Sources/FluidAudio/Unexpected.swift", "changed")
                elif mode == "hardlink": os.link(f.sdk / "LICENSE", f.sdk / "Sources/hardlink")
                elif mode == "symlink": (f.sdk / "Sources/alias").symlink_to(f.sdk / "LICENSE")
                elif mode == "default-traits":
                    p = f.repo / "Optional/Parakeet/Package.swift"; p.write_text(p.read_text().replace('traits: []', 'traits: ["NemoTextProcessing"]')); f.refresh_policy()
                elif mode == "unexpected-resource": f.write(f.sdk / g3.RESOURCE_DIR / "extra", "SYNTHETIC"); f.refresh_policy()
                elif mode == "accessor-collision": f.write(f.sdk / g3.ACCESSOR, "SYNTHETIC"); f.refresh_policy()
                elif mode == "manifest-change":
                    p = f.sdk / "Package@swift-6.2.swift"; p.write_text(p.read_text() + "// unexpected\n"); f.refresh_policy()
                elif mode == "existing-root": f.write(f.output / "winner", "preserved")
                f.save_policy()
                if mode == "duplicate": f.policy_path.write_text('{"schema":1,"schema":1}')
                if mode == "oversize": f.policy_path.write_bytes(b" " * (4 * 1024 * 1024 + 1))
                with self.assertRaises(SystemExit): f.entry()
                self.assertNotIn("helper-build", [name for name, _ in f.calls])
                self.assertFalse((f.output / "Parla.app").exists())
                if mode == "existing-root": self.assertEqual((f.output / "winner").read_text(), "preserved")

    def test_actual_helper_graph_compile_maps_objects_resource_and_signature_gates(self):
        modes = ("git-pin", "git-blob", "base-manifest", "helper-fail", "helper-target", "helper-map", "helper-repeat", "helper-arch", "helper-minos", "helper-sdk", "helper-traits", "stock-resources",
                 "engine-module", "engine-graph", "engine-object", "engine-symbol", "engine-load", "wrong-team", "adhoc", "no-runtime", "wrong-entitlements", "wrong-identifier", "wrong-category", "missing-signature", "sign-helper-fail", "sign-resource", "sign-resource-change", "resource-count", "extra-code")
        for mode in modes:
            with self.subTest(mode=mode):
                f = self.fixture(); f.g3mode = mode
                with self.assertRaises(SystemExit): f.entry()
                self.assertNotIn("build-arm64", [name for name, _ in f.calls])
                self.assertFalse((f.output / "helper-identity.json").exists())

    def test_source_tool_receipt_identity_mutations_across_actual_boundaries(self):
        for phase in ("helper-bin-path", "sign-helper", "build-arm64", "extract", "rpath", "sign-framework", "sign-app", "verify-app", "policy-info-parent"):
            changes = ("sdk", "tool", "original", "helper", "expected", "receipt")
            for change in changes:
                if phase in ("helper-bin-path", "sign-helper") and change in ("helper", "expected", "receipt"): continue
                if phase == "build-arm64" and change == "receipt": continue
                with self.subTest(phase=phase, change=change):
                    f = self.fixture()
                    def mutate(name):
                        if name != phase: return
                        candidates = {"sdk": f.sdk / "LICENSE", "tool": f.tools["paths"]["ld"], "original": f.repo / "Sources/Parla/Intents.swift",
                                      "helper": f.output / "helper-product/ParlaParakeetHelper.bundle/Contents/MacOS" / g3.HELPER,
                                      "expected": f.output / "main-input" / g3.EXPECTED, "receipt": f.output / "main-build/receipt.json"}
                        path = candidates[change]
                        self.assertTrue(path.exists(), (phase, change)); path.write_bytes(b"SYNTHETIC mutation")
                    f.hook = mutate
                    with self.assertRaises(SystemExit): f.entry()
                    self.assertFalse((f.output / "Parla.app").exists()); self.assertFalse((f.output / "package-result.json").exists())

    def test_exact_overlay_all_bytes_notices_no_remote_duplicate_or_stock_accessor(self):
        f = self.fixture(); f.entry(False)
        stage = f.output / "helper-input"
        self.assertNotIn('https://github.com', (stage / "Package.swift").read_text())
        self.assertIn('traits: []', (stage / "Package.swift").read_text())
        self.assertFalse((stage / "Package.resolved").exists())
        derived = stage / "Dependencies/FluidAudio"
        for path in f.policy["sdkFiles"]:
            if path == "Package@swift-6.2.swift": continue
            self.assertEqual((derived / path).read_bytes(), (f.sdk / path).read_bytes())
        self.assertEqual((derived / g3.ACCESSOR).read_bytes(), (SCRIPT.parent / "parakeet-resource-accessor.swift.in").read_bytes())
        manifest = json.loads((f.output / "helper-source.json").read_text())
        self.assertEqual(len(manifest["transformations"]), 4)
        self.assertNotIn("sourceSHA256", manifest)
        self.assertNotIn("helperSHA256", manifest)
        self.assertNotIn(".git", manifest["derived"])
        product = f.output / "Parla.app" / g3.BUNDLE
        for name in g3.RUNTIME:
            self.assertEqual((product / "Contents/Resources/FluidAudio_FluidAudio.bundle" / name).read_bytes(), (f.sdk / g3.RESOURCE_DIR / name).read_bytes())
        self.assertFalse(any('FixtureTests' in name or 'tiny-fixture' in name for name in json.loads((f.output / 'helper-identity.json').read_text())['resources']))

    def test_receipt_and_object_metadata_cannot_be_refreshed_after_freeze(self):
        for change in ('receipt', 'object'):
            with self.subTest(change=change):
                f = self.fixture()
                def mutate(name):
                    if name != 'sign-framework': return
                    path = f.output / 'main-build/receipt.json'
                    if change == 'object': path = next((f.output / 'main-build/arm64').rglob('*.o'))
                    state = path.stat(); os.utime(path, ns=(state.st_atime_ns, state.st_mtime_ns + 1))
                f.hook = mutate
                with self.assertRaises(SystemExit): f.entry(False)
                self.assertNotIn('sign-app', [name for name, _ in f.calls])
                self.assertFalse((f.output / 'Parla.app').exists())

    def test_fixed_path_contract_and_bounded_macho_failures(self):
        # Extract the shared suffix/layout literals. No native Bundle is created.
        text = (SCRIPT.parent / "parakeet-resource-accessor.swift.in").read_text()
        suffix = text.split('let suffix = "', 1)[1].split('"', 1)[0]
        def resolve(path):
            if len(path.encode()) > 16384 or not path.startswith('/') or not path.endswith(suffix) or '\0' in path or any(p in ('', '.', '..') for p in path[1:].split('/')): return None
            return path[:-len('MacOS/ParlaParakeetHelper')] + 'Resources/FluidAudio_FluidAudio.bundle'
        good = '/relocated quoted $ ;/ParlaParakeetHelper.bundle/Contents/MacOS/ParlaParakeetHelper'
        self.assertEqual(resolve(good), '/relocated quoted $ ;/ParlaParakeetHelper.bundle/Contents/Resources/FluidAudio_FluidAudio.bundle')
        for bad in ('relative' + good, good + '/x', good.replace('/Contents/', '/../Contents/'), good.replace('/Contents/', '//Contents/'), '/' + 'x' * 16384 + good): self.assertIsNone(resolve(bad))
        for forbidden in ('Bundle.main', 'ProcessInfo', 'CommandLine', 'getenv', '#file', 'currentDirectoryPath', '.build'):
            self.assertNotIn(forbidden, text)
        f = self.fixture(); path = f.write(f.repo.parent / 'SYNTHETIC-non-runnable', f.helper_macho())
        g3.macho(path, minimum='14.0', arches=('arm64',), sdk='26.5')
        for data in (b'x', f.helper_macho(minos=0xD0300), f.helper_macho(sdk=0), Fixture.macho(('arm64','x86_64'))):
            path.write_bytes(data)
            with self.assertRaises(m.MetadataError): g3.macho(path, minimum='14.0', arches=('arm64',), sdk='26.5')

    def test_adapter_schema_copy_and_exclusive_publication_failures_use_real_entry(self):
        for fault in ("extract-fail", "schema", "actions", "duplicate", "manifest", "helper-copy", "collision", "result-write", "unknown-stage"):
            with self.subTest(fault=fault):
                f = self.fixture(); prior = f.write(f.repo / "Parla.app/prior", "protected")
                if fault == "extract-fail": f.mode = fault
                def mutate(name):
                    if name == "extract" and fault in ("schema", "actions", "duplicate", "manifest"):
                        argv = f.calls[-1][1]; directory = Path(b.option(argv, "--output")) / "Metadata.appintents"
                        if fault == "schema": (directory / "version.json").write_text('{"toolsVersion":"unknown","version":"3.0"}')
                        if fault == "actions": (directory / "extract.actionsdata").write_text('{}')
                        if fault == "duplicate": (directory / "extract.actionsdata").write_text('{"version":1,"version":1}')
                        if fault == "manifest": (directory / "objects.appintentsmanifest").mkdir()
                    if name == "sign-framework" and fault == "helper-copy":
                        (f.output / "staging/Parla.app" / g3.BUNDLE / "Contents/MacOS" / g3.HELPER).write_text("SYNTHETIC mutation")
                    if name == "sign-app" and fault == "unknown-stage":
                        app = f.output / "staging/Parla.app"; app.rename(app.with_name("preserved-own-candidate")); app.mkdir()
                        f.write(app / "stranger", "unknown replacement")
                f.hook = mutate
                real_write, real_promote = b.write_json, b.promote
                def write(path, value):
                    if fault == "result-write" and path.name == "package-result.pending.json": raise OSError("SYNTHETIC result write fault")
                    return real_write(path, value)
                def promote(source, target):
                    if fault == "collision": f.write(target / "winner", "collision winner")
                    return real_promote(source, target)
                with patch.object(b, "write_json", write), patch.object(b, "promote", promote):
                    with self.assertRaises(SystemExit): f.entry()
                self.assertFalse((f.output / "package-result.json").exists())
                self.assertEqual(prior.read_text(), "protected")
                if fault == "collision": self.assertEqual((f.output / "Parla.app/winner").read_text(), "collision winner")
                else: self.assertFalse((f.output / "Parla.app").exists())
                if fault == "unknown-stage": self.assertEqual((f.output / "staging/Parla.app/stranger").read_text(), "unknown replacement")

    def test_identical_foreign_stage_before_or_during_promotion_is_preserved_without_result(self):
        for boundary in ('before-promotion', 'inside-promotion'):
            with self.subTest(boundary=boundary):
                f = self.fixture(); replaced = []
                def replace_stage(app):
                    app.rename(app.with_name('retained-owned-stage'))
                    shutil.copytree(app.with_name('retained-owned-stage'), app, symlinks=True)
                    replaced.append((app.stat().st_dev, app.stat().st_ino))
                def hook(name):
                    if boundary == 'before-promotion' and name == 'policy-entitlements-parent': replace_stage(f.output / 'staging/Parla.app')
                f.hook = hook
                real_promote = b.promote
                def promote(source, target):
                    if boundary == 'inside-promotion' and source.name == 'Parla.app': replace_stage(source)
                    return real_promote(source, target)
                with patch.object(b, 'promote', promote):
                    with self.assertRaises(SystemExit): f.entry(False)
                self.assertFalse((f.output / 'package-result.json').exists())
                stranger = f.output / ('staging/Parla.app' if boundary == 'before-promotion' else 'Parla.app')
                self.assertEqual((stranger.stat().st_dev, stranger.stat().st_ino), replaced[0])
                self.assertTrue((f.output / 'staging/retained-owned-stage').exists())


class G3ShellTests(unittest.TestCase):
    run_fixture = b19fixtures.ShellEntryTests.run_fixture
    def test_all_four_modes_and_failure_have_one_dispatch_no_fallback(self):
        for native, optional in ((0, 0), (1, 0), (0, 1), (1, 1)):
            for fail in (False, True):
                with self.subTest(native=native, optional=optional, fail=fail):
                    result, events = self.run_fixture(native, identity="SYNTHETIC signer" if optional else "", fail=fail, optional=optional)
                    self.assertEqual(result.returncode, 33 if fail and (native or optional) else 0, result.stderr)
                    dispatch = [e for e in events if e[0] == "python3"]
                    self.assertEqual(len(dispatch), int(bool(native or optional)))
                    if optional:
                        self.assertIn("scripts/build-parakeet-app.py", dispatch[0]); self.assertIn("--policy", dispatch[0])
                        self.assertEqual(dispatch[0][dispatch[0].index("--native-metadata") + 1], str(native))
                        self.assertFalse(any(e[0] in ("swift", "codesign", "git") for e in events))
                    elif native: self.assertIn("scripts/build-app-intents.py", dispatch[0])

    def test_optional_missing_identity_incompatible_architecture_and_dmg_guard(self):
        for identity, arch in (("", "universal"), ("SYNTHETIC signer", "host"), ("SYNTHETIC signer", "x86_64")):
            result, events = self.run_fixture(0, optional=1, identity=identity, architecture=arch)
            self.assertEqual(result.returncode, 1); self.assertEqual(events, [])
        with tempfile.TemporaryDirectory(prefix="wave4g3-dmg-", dir="/tmp/parla-implementation-2026-10-28") as directory:
            script = Path(directory) / "make-dmg.sh"; shutil.copy2(SCRIPT.parent / "make-dmg.sh", script)
            result = subprocess.run(["/bin/bash", str(script)], env={**os.environ, "PARLA_PARAKEET_PRODUCT": "1", "PATH": "/SYNTHETIC/no-tools"}, capture_output=True)
            self.assertEqual(result.returncode, 1); self.assertIn(b"before legacy", result.stderr)


class G3RunnerTests(unittest.TestCase):
    def root(self):
        owned = tempfile.TemporaryDirectory(prefix="wave4g3-inert-", dir="/tmp/parla-implementation-2026-10-28")
        self.addCleanup(owned.cleanup)
        return Path(owned.name).resolve()

    def record(self, value):
        path = os.environ.get("PARLA_PACKAGING_TEST_MANIFEST")
        self.assertIsNotNone(path)
        with open(path, 'a') as stream: stream.write(json.dumps(value) + '\n')

    def test_partial_root_and_resource_materialization_cancellation_keep_evidence(self):
        for phase in ('partial-root', 'resource-materialization'):
            for signum in (signal.SIGINT, signal.SIGTERM):
                with self.subTest(phase=phase, signal=signum):
                    f = G3Fixture(self.root())
                    original_init, original_copy = b.Commands.__init__, shutil.copy2
                    def initialize(commands, root, repo):
                        original_init(commands, root, repo)
                        if phase == 'partial-root': os.kill(os.getpid(), signum)
                    def copy(source, destination, **options):
                        result = original_copy(source, destination, **options)
                        if phase == 'resource-materialization' and 'helper-product' in str(destination) and Path(destination).name == g3.RUNTIME[0]: os.kill(os.getpid(), signum)
                        return result
                    before = {n: signal.getsignal(n) for n in (signal.SIGINT, signal.SIGTERM)}
                    with patch.object(b.Commands, '__init__', initialize), patch.object(shutil, 'copy2', copy):
                        with self.assertRaises(SystemExit) as error: f.entry()
                    self.assertEqual(error.exception.code, 128 + signum)
                    self.assertEqual({n: signal.getsignal(n) for n in before}, before)
                    self.assertTrue((f.output / 'ownership.json').is_file())
                    self.assertFalse((f.output / 'Parla.app').exists()); self.assertFalse((f.output / 'package-result.json').exists())
                    self.record(dict(root=str(f.output), phase=phase, signal=signum, pid=os.getpid(), exit=error.exception.code, tool=None))

    def test_actual_runner_waits_for_child_and_log_eof_and_preserves_incomplete_stage(self):
        for canceled in (False, True):
            with self.subTest(canceled=canceled): self.held_io_case(canceled)

    def test_extractor_scratch_survives_unsettled_io_and_normal_extraction_cleans(self):
        for canceled in (False, True):
            with self.subTest(canceled=canceled): self.held_io_case(canceled, phase='extract')
        f = G3Fixture(self.root()); f.entry(True)
        self.assertEqual(list((f.output / 'main-build/tooltmp').glob('parla-appintents-*')), [])

    def held_io_case(self, canceled, phase='sign-app'):
        root = self.root(); f = G3Fixture(root)
        run, popen = b.Commands.run, b.subprocess.Popen
        holders = []
        # The fixture owns the IO holder's Popen handle directly, so it can join
        # it even after the production runner correctly reports ambiguous IO.
        read_gate, write_gate = os.pipe()
        ready_read, ready_write = os.pipe()
        scratch = []
        def spawn(argv, **options):
            r, w = os.pipe()
            options['stdout'] = w
            process = popen(argv, **options)
            process.stdout = os.fdopen(r, 'rb', buffering=0)
            holder = popen([sys.executable, '-c', 'import os,sys;os.write(int(sys.argv[2]),b"R");os.read(int(sys.argv[1]),1)', str(read_gate), str(ready_write)],
                           pass_fds=(read_gate, ready_write), stdout=w, stderr=subprocess.DEVNULL,
                           cwd=scratch[0] if scratch else root)
            holders.append(holder); os.close(w)
            self.assertTrue(select.select([ready_read], [], [], 10)[0], 'owned IO holder did not become ready')
            self.assertEqual(os.read(ready_read, 1), b'R')
            if canceled: os.kill(os.getpid(), signal.SIGINT)
            return process
        original = f.command
        def command(commands, argv, name):
            if name != phase: return original(commands, argv, name)
            if phase == 'extract':
                scratch.append(Path(b.option(argv, '--output')).parent)
                state = scratch[0].lstat()
                self.record(dict(root=str(root), scratch=str(scratch[0]), identity=[state.st_dev, state.st_ino, state.st_uid], phase='owned-extractor-scratch'))
            with patch.object(b.subprocess, 'Popen', spawn): return run(commands, [sys.executable, '-c', 'print("SYNTHETIC leader exited")'], name)
        f.command = command
        try:
            # Exercise production stdlib cleanup itself, without an outer task
            # audit wrapper masking the adapter's retention responsibility.
            raw_temporary = next(cls for cls in tempfile.TemporaryDirectory.__mro__
                                 if cls.__module__ == 'tempfile' and cls.__name__ == 'TemporaryDirectory')
            context = patch.object(m.tempfile, 'TemporaryDirectory', raw_temporary) if phase == 'extract' else contextlib.nullcontext()
            with context, self.assertRaises(SystemExit) as error: f.entry(phase == 'extract')
            self.assertEqual(error.exception.code, 130 if canceled else 1)
            self.assertTrue((f.output / 'staging/Parla.app').is_dir())
            self.assertFalse((f.output / 'Parla.app').exists())
            self.assertFalse((f.output / 'package-result.json').exists())
            if scratch: self.assertTrue(scratch[0].is_dir(), 'scratch deleted while an owned writer remains unjoined')
            records = [json.loads(p.read_text()) for p in (f.output / 'main-build/commands').glob('*-' + phase + '.json')]
            self.assertEqual(len(records), 1); self.assertFalse(records[0]['io_closed'])
            self.assertIn(records[0]['exit'], (0, -signal.SIGTERM) if canceled else (0,))
        finally:
            os.write(write_gate, b'x'); os.close(write_gate); os.close(read_gate)
            os.close(ready_read); os.close(ready_write)
            for holder in holders:
                code = holder.wait(timeout=10); self.assertEqual(code, 0)
                self.record(dict(root=str(root), phase='held-io', canceled=canceled, holder_pid=holder.pid, exit=code, group=os.getpgrp()))

    def test_g3_entry_cooperative_signals_join_known_grandchild_and_restore_handlers(self):
        program = '''import json,os,signal,sys
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,sys.argv[1])
from test_build_parakeet_app import G3Fixture,b
root=Path(sys.argv[2]);phase=sys.argv[3];mode=sys.argv[4];number=int(sys.argv[5]);f=G3Fixture(root)
original=f.command;run=b.Commands.run;popen=b.subprocess.Popen
f.write(f.repo/'Parla.app/prior','preserve')
def command(commands,argv,name):
 if name!=phase:return original(commands,argv,name)
 if mode=='spawn':
  child='import signal;signal.pause()'
 else:
  grand="import os,signal,sys;sys.stdin.buffer.read(1);f=open(sys.argv[1],'w');f.write(str(os.getpid())+' '+str(os.getpgrp()));f.close();signal.pause()"
  child="import os,signal,subprocess,sys;from pathlib import Path;g=None\\ndef end(*a):\\n if g is not None:g.wait()\\n sys.exit(0)\\nsignal.signal(signal.SIGTERM,end);g=subprocess.Popen([sys.executable,'-c',"+repr(grand)+","+repr(str(root/'ready'))+"],stdin=subprocess.PIPE);g.stdin.write(b'x');g.stdin.flush();signal.pause()"
 def spawn(*a,**kw):
  process=popen(*a,**kw)
  if mode=='spawn':os.kill(os.getpid(),number);os.kill(os.getpid(),number)
  return process
 with patch.object(b.subprocess,'Popen',spawn):return run(commands,[sys.executable,'-c',child],name)
f.command=command
before={n:signal.getsignal(n) for n in (signal.SIGINT,signal.SIGTERM)}
try:f.entry()
finally:
 assert all(signal.getsignal(n)==v for n,v in before.items())
 (root/'handlers-restored').write_text('yes')
'''
        for phase in ('helper-build', 'sign-helper', 'build-arm64', 'extract', 'sign-app'):
            for signum in (signal.SIGINT, signal.SIGTERM):
                for mode in ('running', 'spawn'):
                    with self.subTest(phase=phase, signum=signum, mode=mode):
                        root = self.root(); ready = root / 'ready'; os.mkfifo(ready)
                        fd = os.open(ready, os.O_RDONLY | os.O_NONBLOCK)
                        grand = None
                        with (root / 'entry.log').open('wb') as log:
                            process = subprocess.Popen([sys.executable, '-c', program, str(Path(__file__).parent), str(root), phase, mode, str(signum)], stdout=log, stderr=log)
                            try:
                                if mode == 'running':
                                    readable, _, _ = select.select([fd], [], [], 15)
                                    self.assertTrue(readable, (root / 'entry.log').read_text())
                                    data = os.read(fd, 1024).decode().split()
                                    self.assertEqual(len(data), 2); grand, group = map(int, data)
                                    self.assertGreater(group, 0)
                                    process.send_signal(signum)
                                    # A repeated cooperative signal must not interrupt unwind.
                                code = process.wait(timeout=20)
                                self.assertEqual(code, 128 + signum, (root / 'entry.log').read_text())
                                self.assertTrue((root / 'handlers-restored').exists())
                                output = root / "output with spaces ' $ ;"
                                self.assertFalse((output / 'Parla.app').exists()); self.assertFalse((output / 'staging/Parla.app').exists())
                                self.assertEqual((root / "repo with spaces ' $ ;/Parla.app/prior").read_text(), 'preserve')
                                records = [json.loads(p.read_text()) for p in output.rglob('*-' + phase + '.json') if p.parent.name == 'commands' and not p.name.endswith('.running.json')]
                                actual = [r for r in records if r.get('pid', 0)]
                                self.assertEqual(len(actual), 1); self.assertTrue(actual[0]['io_closed'])
                                if mode == 'running': self.assertEqual(actual[0]['exit'], 0)
                                with self.assertRaises(ProcessLookupError): os.kill(actual[0]['pid'], 0)
                                if grand is not None:
                                    with self.assertRaises(ProcessLookupError): os.kill(grand, 0)
                                self.record(dict(root=str(root), phase=phase, mode=mode, signal=signum, parent_pid=process.pid, tool_pid=actual[0]['pid'], grandchild_pid=grand, exit=code, command_exit=actual[0]['exit'], io_closed=actual[0]['io_closed']))
                            finally:
                                os.close(fd)
                                if process.poll() is None:
                                    process.send_signal(signal.SIGTERM)
                                    process.wait(timeout=20)

    def test_actual_runner_term_to_kill_and_spawn_failure_finalize_records(self):
        root = self.root(); repo = root / 'repo'; repo.mkdir()
        owned = b.fresh_root(root / 'output'); commands = b.Commands(owned, repo)
        # Inject cancellation at wait only after the child acknowledges its TERM
        # handler through the actual stdout pipe. No timer proves readiness.
        original_drain = commands._drain
        requested = False
        def drain(streams):
            nonlocal requested
            original_drain(streams)
            if not requested and any(p.stat().st_size for p in commands.directory.glob('*.stdout')):
                requested = True; raise b.BuildCanceled(signal.SIGTERM)
        commands._drain = drain
        child = 'import signal;signal.signal(signal.SIGTERM,signal.SIG_IGN);print("SYNTHETIC ready",flush=True);signal.pause()'
        # Unbuffered log visibility is deliberately flushed by this bottom hook.
        def flushed(streams):
            for key in streams.get_map().values(): key.data.flush()
            drain(streams)
            for key in streams.get_map().values(): key.data.flush()
        commands._drain = flushed
        with self.assertRaises(b.BuildCanceled): commands.run([sys.executable, '-c', child], 'term-kill')
        record = json.loads(next(commands.directory.glob('*-term-kill.json')).read_text())
        self.assertEqual(record['exit'], -signal.SIGKILL); self.assertTrue(record['io_closed'])
        self.record(dict(root=str(root), phase='term-kill', tool_pid=record['pid'], exit=record['exit'], io_closed=record['io_closed']))
        commands._drain = original_drain
        with self.assertRaises(FileNotFoundError): commands.run(['/SYNTHETIC/nonexistent-executable'], 'spawn-fail')
        record = json.loads(next(commands.directory.glob('*-spawn-fail.json')).read_text())
        self.assertIsNone(record['pid']); self.assertIsNone(record['exit']); self.assertTrue(record['io_closed'])


if __name__ == "__main__": unittest.main(verbosity=2)
