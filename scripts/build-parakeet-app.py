#!/usr/bin/env python3
"""Inactive G3 source producer. Real build/sign/resource/runtime qualification is separate.

The policy is an independently supplied owner/source/tool contract, not a receipt
import. No production test override, ad-hoc route, resume, or fallback build exists.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shlex
import shutil
import stat
import struct
import sys
import time

sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location("parla_b19", Path(__file__).with_name("build-app-intents.py"))
b19 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(b19)
m = b19.metadata
require = m.require
PIN = "503b4bd1bbf7220882de39fe8ae6716aae4132da"
HELPER_ID = "com.parla.ParlaParakeetHelper"
HELPER = "ParlaParakeetHelper"
BUNDLE = "Contents/Helpers/ParlaParakeetHelper.bundle"
EXPECTED = "Sources/Parla/ParakeetProductBuildInput.swift"
TEMPLATE = "scripts/parakeet-resource-accessor.swift.in"
ACCESSOR = "Sources/FluidAudio/ParakeetResourceAccessor.swift"
RESOURCE_DIR = "Sources/FluidAudio/TTS/LuxTts/G2p/Resources"
RUNTIME = ("luxtts_en_us_g2p_aux.json", "luxtts_en_us_lexicon.tsv.zz")
SDK_MANIFESTS = {"Package.swift": "db1e00a656844ed3615ef3a68d21bd391856451b5a8f7b29891ac72e5c7c0bfb",
                 "Package@swift-6.2.swift": "104ee8f45822de0e631f0443e64fdafb9e6354c859990b4c8d1af04f7c2b8a4c"}
SCRIPTS = ("scripts/build-app-intents.py", "scripts/app-intents-metadata.py", "scripts/make-app.sh",
           "scripts/build-parakeet-app.py", TEMPLATE)
MAIN_ROOTS = ("Package.swift", "Package.resolved", "Sources", "Resources", "Frameworks", *SCRIPTS)
SDK_ROOTS = ("Package.swift", "Package@swift-6.2.swift", "Sources", "Tests", "LICENSE", "ThirdPartyLicenses")
OPTIONAL_ROOTS = ("Package.swift", "Package.resolved", "Sources", "Tests")
MAX_FILE = 128 * 1024 * 1024
MAX_TOTAL = 512 * 1024 * 1024
MAX_FILES = 20000


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False).encode() + b"\n"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def hash_shape(value):
    return isinstance(value, str) and re.fullmatch("[0-9a-f]{64}", value) is not None


def relative(value):
    require(isinstance(value, str) and 0 < len(value.encode()) <= 1024 and "\0" not in value,
            "invalid logical input path")
    path = PurePosixPath(value)
    require(not path.is_absolute() and str(path) == value and all(p not in ("", ".", "..", ".git", ".build", "node_modules", "android") for p in value.split("/")),
            "unapproved input path")
    return value


def regular(path, maximum=MAX_FILE):
    require(path.is_absolute() and path.resolve() == path, "noncanonical file or symlink ancestor")
    s = path.lstat()
    require(stat.S_ISREG(s.st_mode) and s.st_uid == os.getuid() and s.st_nlink == 1 and 0 < s.st_size <= maximum,
            "input must be bounded, regular, singly linked and owned")
    return s


def read_policy(path):
    regular(path, 4 * 1024 * 1024)
    policy = m.load_json(path)
    require(set(policy) == {"schema", "sdkRevision", "sdkTreeSHA256", "sdkFiles", "optionalFiles", "mainFiles",
                            "toolFiles", "swiftVersionSHA256", "sdkVersion", "signing"}, "unsupported policy schema")
    require(policy["schema"] == 1 and policy["sdkRevision"] == PIN, "unsupported SDK revision")
    for name in ("sdkFiles", "optionalFiles", "mainFiles"):
        value = policy[name]
        require(isinstance(value, dict) and 0 < len(value) <= MAX_FILES, "invalid source contract")
        for key, item in value.items():
            relative(key)
            require(isinstance(item, dict) and set(item) in ({"sha256"}, {"link"}), "invalid input identity")
            if "sha256" in item: require(hash_shape(item["sha256"]), "invalid input digest")
            else: require(name == "mainFiles" and key.startswith("Frameworks/") and isinstance(item["link"], str), "unapproved source alias")
    require(hash_shape(policy["sdkTreeSHA256"]) and sha(canonical(policy["sdkFiles"])) == policy["sdkTreeSHA256"], "SDK tree contract mismatch")
    require(set(policy["sdkFiles"]) >= {*SDK_MANIFESTS, "LICENSE"} and
            any(p.startswith("ThirdPartyLicenses/") for p in policy["sdkFiles"]), "complete source notices required")
    require(set(policy["toolFiles"]) == {"swift", "swiftc", "swift-frontend", "appintentsmetadataprocessor", "ld", "clang", "lipo", "install_name_tool", "otool", "codesign", "plutil", "git", "nm", "sdk_settings", "xcode_version_file", "discovery"} and
            all(hash_shape(v) for v in policy["toolFiles"].values()) and hash_shape(policy["swiftVersionSHA256"]), "explicit supported tool contract required")
    version_number(policy["sdkVersion"])
    signing = policy["signing"]
    require(set(signing) == {"team", "helperIdentifier", "parentIdentifier", "category", "hardenedRuntime", "helperEntitlements", "parentEntitlements"}, "explicit signing-owner policy required")
    require(re.fullmatch("[A-Z0-9]{1,32}", signing["team"]) and signing["helperIdentifier"] == HELPER_ID and
            signing["parentIdentifier"] == m.BUNDLE_ID and signing["category"] == "Developer ID Application" and
            signing["hardenedRuntime"] is True and signing["helperEntitlements"] == {} and
            isinstance(signing["parentEntitlements"], dict) and
            not signing["parentEntitlements"].get("com.apple.security.cs.disable-library-validation", False) and
            not signing["parentEntitlements"].get("com.apple.security.get-task-allow", False), "unsupported signing-owner policy")
    return policy


def bounded_inventory(root, roots, *, framework_links=False, optional_roots=()):
    """Only named input roots; excluded names are refused BEFORE traversal."""
    require(root.is_absolute() and root.resolve() == root and root.is_dir(), "canonical input root required")
    require(set(optional_roots) <= {"Package.resolved"} and set(optional_roots) <= set(roots), "unsupported optional input")
    rows, total, visited = {}, 0, 0
    def visit(path):
        nonlocal total, visited
        visited += 1
        require(visited <= MAX_FILES * 2 and len(rows) <= MAX_FILES, "input membership budget exceeded")
        key = relative(path.relative_to(root).as_posix())
        state = path.lstat()
        require(state.st_uid == os.getuid(), "foreign input owner")
        if stat.S_ISDIR(state.st_mode):
            require(not path.is_symlink(), "source alias")
            for child in sorted(path.iterdir()):
                relative(child.relative_to(root).as_posix())
                visit(child)
        elif stat.S_ISLNK(state.st_mode):
            link = os.readlink(path)
            framework = root / "Frameworks/whisper.xcframework/macos-arm64_x86_64/whisper.framework"
            require(framework_links and path.is_relative_to(framework) and not Path(link).is_absolute() and path.resolve().is_relative_to(framework), "source symlink refused")
            rows[key] = {"link": link, "mode": state.st_mode, "mtime_ns": state.st_mtime_ns, "inode": state.st_ino}
        else:
            regular(path)
            total += state.st_size
            require(total <= MAX_TOTAL and len(rows) < MAX_FILES, "input copy budget exceeded")
            rows[key] = {"sha256": m.digest(path), "size": state.st_size, "mode": state.st_mode,
                         "mtime_ns": state.st_mtime_ns, "inode": state.st_ino}
    for name in roots:
        path = root / name
        if name in optional_roots and not path.exists() and not path.is_symlink(): rows[name] = {"absent": True}
        else: visit(path)
    return rows


def identities(rows):
    return {p: {k: row[k]} for p, row in rows.items() if "absent" not in row for k in ("sha256" if "sha256" in row else "link",)}


def copy_inputs(source, destination, rows):
    require(not destination.exists(), "input stage collision")
    destination.mkdir(parents=True, mode=0o700)
    for key, value in rows.items():
        if "absent" in value: continue
        target = destination / key; target.parent.mkdir(parents=True, exist_ok=True)
        if "link" in value: target.symlink_to(value["link"])
        else:
            regular(source / key)
            shutil.copy2(source / key, target)
            require(m.digest(target) == value["sha256"], "staged copy changed")


class Inputs:
    def __init__(self, repo, sdk, root, policy, policy_path):
        self.repo, self.sdk, self.root, self.policy = repo, sdk, root, policy
        state = root.lstat()
        self.root_identity = (state.st_dev, state.st_ino, state.st_uid)
        self.marker = b19.record(root / "ownership.json")
        self.policy_path, self.policy_record = policy_path, b19.record(policy_path)
        self.original = {}
        for label, source, roots, contract, links in (
            ("main", repo, MAIN_ROOTS, "mainFiles", True),
            ("optional", repo / "Optional/Parakeet", OPTIONAL_ROOTS, "optionalFiles", False),
            ("sdk", sdk, SDK_ROOTS, "sdkFiles", False)):
            rows = bounded_inventory(source, roots, framework_links=links, optional_roots=("Package.resolved",) if label == "main" else ())
            require(identities(rows) == policy[contract], "authenticated " + label + " input membership/bytes mismatch")
            self.original[label] = (source, roots, rows, links)
        require(all(policy["sdkFiles"][name] == {"sha256": digest} for name, digest in SDK_MANIFESTS.items()), "unsupported pinned SDK manifest")
        optional = repo / "Optional/Parakeet"
        manifest = (optional / "Package.swift").read_text()
        old = '.package(url: "https://github.com/FluidInference/FluidAudio.git",\n                 revision: "' + PIN + '", traits: [])'
        require(manifest.count(old) == 1 and manifest.startswith("// swift-tools-version: 6.2\n") and
                "platforms: [.macOS(.v14)]" in manifest and manifest.count(".package(") == 1, "unsupported optional manifest")
        resolved = m.load_json(optional / "Package.resolved")
        require(resolved["version"] == 3 and len(resolved["pins"]) == 1 and resolved["pins"][0] == {
            "identity": "fluidaudio", "kind": "remoteSourceControl", "location": "https://github.com/FluidInference/FluidAudio.git", "state": {"revision": PIN}}, "wrong optional lock/traits contract")
        copy_inputs(optional, root / "helper-input", self.original["optional"][2])
        self.helper = root / "helper-input"
        self.derived = self.helper / "Dependencies/FluidAudio"
        copy_inputs(sdk, self.derived, self.original["sdk"][2])
        changes = []
        def transform(path, data, reason):
            previous = path.read_bytes() if path.exists() else None
            path.write_bytes(data)
            changes.append({"path": path.relative_to(self.helper).as_posix(), "originalSHA256": sha(previous) if previous is not None else None,
                            "derivedSHA256": sha(data), "reason": reason})
        transform(self.helper / "Package.swift", manifest.replace(old, '.package(path: "Dependencies/FluidAudio", traits: [])').encode(), "one local pinned derivative; traits remain empty")
        # Local dependency has no remote pins. Retain original lock as provenance,
        # without presenting its obsolete remote pin as the staged resolution.
        (self.helper / "Package.resolved").unlink()
        changes.append({"path": "Package.resolved", "originalSHA256": policy["optionalFiles"]["Package.resolved"]["sha256"], "derivedSHA256": None, "reason": "local-only dependency; original lock retained in source provenance"})
        path = self.derived / "Package@swift-6.2.swift"
        text = path.read_text()
        old_resource = '''exclude: ["ASR/Parakeet/Unified/benchmark.md"],
            resources: [
                // Keep .process: .copy of a Resources-named directory breaks Apple code signing on iOS.
                .process("TTS/LuxTts/G2p/Resources")
            ]'''
        require(text.count(old_resource) == 1, "unexpected runtime resource processing contract")
        transform(path, text.replace(old_resource, 'exclude: ["ASR/Parakeet/Unified/benchmark.md", "TTS/LuxTts/G2p/Resources"]').encode(), "explicit accessor and byte-exact complete runtime resource copy")
        require(not (self.derived / ACCESSOR).exists(), "explicit accessor collision")
        transform(self.derived / ACCESSOR, (repo / TEMPLATE).read_bytes(), "audited bounded executable-location template")
        runtime = {p for p in policy["sdkFiles"] if p.startswith(RESOURCE_DIR + "/")}
        require(runtime == {RESOURCE_DIR + "/" + name for name in RUNTIME}, "unsupported runtime resource membership")
        self.staged_roots = ("Package.swift", "Sources", "Tests", "Dependencies")
        self.frozen = bounded_inventory(self.helper, self.staged_roots)
        self.manifest = {"schema": 1, "sdkRevision": PIN, "sdkTreeSHA256": policy["sdkTreeSHA256"],
                         "original": {label: identities(v[2]) for label, v in self.original.items() if label != "main"},
                         "template": {TEMPLATE: policy["mainFiles"][TEMPLATE]}, "transformations": changes,
                         "derived": identities(self.frozen), "traits": [], "runtimeResources": sorted(runtime)}
        self.manifest["producerInputs"] = {name: policy["mainFiles"][name] for name in SCRIPTS}
        self.manifest["tools"] = policy["toolFiles"]
        # Logical input identities only: no output/descriptor/receipt/self hash.
        self.source = canonical(self.manifest)
        require(len(self.source) <= 16 * 1024 * 1024, "source manifest too large")
        self.source_hash = sha(self.source)
        (root / "helper-source.json").write_bytes(self.source)
        self.authentication_records = None

    def authenticate(self, commands, tools):
        head = commands.run([tools["paths"]["git"], "-C", self.sdk, "rev-parse", "--verify", "HEAD"], "sdk-head")
        require(head["stdout"].decode().strip() == PIN, "SDK checkout is not the exact upstream pin")
        tree = commands.run([tools["paths"]["git"], "-C", self.sdk, "ls-tree", "-rz", "--full-tree", PIN, "--", *SDK_ROOTS], "sdk-source-tree")
        require(len(tree["stdout"]) <= 4 * 1024 * 1024 and tree["stdout"].endswith(b"\0"), "invalid bounded Git source tree")
        found = {}
        for row in tree["stdout"].split(b"\0")[:-1]:
            header, path = row.split(b"\t", 1); mode, kind, blob = header.decode().split(" ")
            path = relative(path.decode())
            require(path not in found and mode in ("100644", "100755") and kind == "blob" and re.fullmatch("[0-9a-f]{40}", blob), "unsupported Git source entry")
            require(path in self.policy["sdkFiles"], "unexpected pinned Git source member")
            regular(self.sdk / path)
            data = (self.sdk / path).read_bytes()
            require(hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest() == blob, "SDK bytes differ from pinned Git blob")
            found[path] = {"sha256": sha(data)}
        require(found == self.policy["sdkFiles"], "pinned SDK source tree membership mismatch")
        self.authentication_records = [head["record"], tree["record"],
            b19.record(Path(head["record"]["path"]).with_suffix(".stdout")), b19.record(Path(tree["record"]["path"]).with_suffix(".stdout"))]

    def validate(self):
        require(self.root_owned(), "producer root ownership changed")
        m.checked_file(self.marker)
        if self.authentication_records is not None:
            for record in self.authentication_records: m.checked_file(record)
        m.checked_file(self.policy_record)
        for label, (source, roots, rows, links) in self.original.items():
            require(bounded_inventory(source, roots, framework_links=links, optional_roots=("Package.resolved",) if label == "main" else ()) == rows, "original " + label + " inputs changed")
        require(bounded_inventory(self.helper, self.staged_roots) == self.frozen, "derived helper inputs changed")
        require((self.root / "helper-source.json").read_bytes() == self.source, "source manifest changed")

    def root_owned(self):
        try:
            state = self.root.lstat()
            return stat.S_ISDIR(state.st_mode) and self.root.resolve() == self.root and (state.st_dev, state.st_ino, state.st_uid) == self.root_identity
        except OSError: return False


def version_number(value):
    require(isinstance(value, str) and re.fullmatch(r"\d{1,3}\.\d{1,3}(?:\.\d{1,3})?", value), "unsupported SDK version")
    parts = [int(p) for p in value.split(".")]
    require(all(p < 256 for p in parts[1:]), "invalid SDK version")
    return (parts[0] << 16) | (parts[1] << 8) | (parts[2] if len(parts) == 3 else 0)


def macho(path, *, minimum, arches, sdk):
    """Bounded static parser; synthetic headers are deliberately non-runnable."""
    regular(path)
    data = path.read_bytes(); result = []; ranges = []
    require(len(data) >= 32, "short executable")
    fat = struct.unpack_from(">I", data)[0]
    if fat in (0xCAFEBABE, 0xCAFEBABF):
        count = struct.unpack_from(">I", data, 4)[0]; stride = 20 if fat == 0xCAFEBABE else 32
        require(count == 2 and len(data) >= 8 + stride * count, "unsupported universal executable")
        for i in range(count):
            values = struct.unpack_from(">5I" if stride == 20 else ">2I2Q2I", data, 8 + stride * i)
            cpu, _, offset, size = values[:4]
            require(offset >= 8 + stride * count and all(offset + size <= a or offset >= b for a, b, _ in ranges), "overlapping binary slices")
            ranges.append((offset, offset + size, cpu))
    else: ranges = [(0, len(data), None)]
    for offset, end, expected_cpu in ranges:
        require(end <= len(data) and end - offset >= 32, "truncated binary slice")
        magic, cpu, _, kind, count, length, _, _ = struct.unpack_from("<8I", data, offset)
        require(magic == 0xFEEDFACF and kind == 2 and cpu in (0x100000C, 0x1000007) and (expected_cpu is None or cpu == expected_cpu), "wrong executable architecture/type")
        limit = offset + 32 + length; cursor = offset + 32; versions = 0
        require(limit <= end and count <= 4096, "invalid load commands")
        for _ in range(count):
            require(cursor + 8 <= limit, "short load command")
            command, size = struct.unpack_from("<2I", data, cursor)
            require(size >= 8 and cursor + size <= limit, "invalid load command size")
            if command == 0x32:
                require(size >= 24, "short build version")
                platform, minos, stamp = struct.unpack_from("<3I", data, cursor + 8)
                require(platform == 1 and minos == version_number(minimum) and stamp == version_number(sdk), "wrong platform/minOS/SDK stamp")
                versions += 1
            require(command != 0x24, "legacy deployment command unsupported")
            if command in (0xC, 0x18 | 0x80000000, 0x1F | 0x80000000, 0x23 | 0x80000000):
                require(size >= 24, "short dylib command")
                name_offset = struct.unpack_from("<I", data, cursor + 8)[0]
                require(24 <= name_offset < size, "invalid dylib name")
                name = data[cursor + name_offset:cursor + size].split(b"\0", 1)[0].decode()
                no_engine(name)
                if minimum == "13.3": require(not re.search(r"FluidAudio|ParakeetHelper|ParlaParakeetHelper", name), "optional root load edge")
            cursor += size
        require(cursor == limit and versions == 1, "missing/duplicate build version")
        result.append("arm64" if cpu == 0x100000C else "x86_64")
    require(len(result) == len(arches) and set(result) == set(arches), "wrong product architecture")


def no_engine(value):
    # Nemotron and NemoTextNormalizer.swift are intentional trait-off sources.
    require(re.search(r"CNemo|NemoTextProcessing|text_processing_rs|(?:^|[^A-Za-z])_?nemo_|libnemo", value, re.I) is None,
            "selected native normalization engine edge")


def selected_tools(commands, policy):
    tools = b19.resolve_tools(commands)
    found = commands.run(["/usr/bin/xcrun", "--find", "nm"], "find-nm")["stdout"].decode().strip()
    tools["paths"]["nm"] = Path(found)
    require(Path(found).resolve().is_relative_to(Path(tools["toolchain"])), "mixed nm toolchain")
    records = {name: b19.record(path) for name, path in tools["paths"].items()}
    records.update({name: tools[name] for name in ("sdk_settings", "xcode_version_file", "discovery")})
    require({k: v["sha256"] for k, v in records.items()} == policy["toolFiles"], "selected tool contract mismatch")
    version = commands.run([tools["paths"]["swift"], "--version"], "helper-swift-version")
    compiler_version = re.search(rb"Swift version (\d+)\.(\d+)(?:\.\d+)?(?:\s|$)", version["stdout"])
    require(sha(version["stdout"]) == policy["swiftVersionSHA256"] and compiler_version is not None and
            tuple(map(int, compiler_version.groups())) >= (6, 2), "explicit supported compiler and tools 6.2+ contract required")
    settings = m.load_json(Path(tools["sdk_settings"]["path"]))
    require(settings["Version"] == policy["sdkVersion"], "wrong selected SDK")
    def validate():
        for record in records.values(): m.checked_file(record)
        b19.metadata.known_tool(tools)
    return tools, records, validate


def actual_commands(invocation, tools):
    lines = (invocation["stdout"] + b"\n" + invocation["stderr"]).decode().splitlines()
    prefix = str(Path(tools["toolchain"]) / "usr/bin/")
    result = []
    for line in lines:
        if line.startswith("warning: '") and "': " in line: line = line.split("': ", 1)[1]
        if line.startswith((prefix, '"' + prefix)): result.append(shlex.split(line))
    return result


def validate_helper(inputs, root, invocation, binary_dir, tools):
    start, end = invocation["started_ns"], invocation["completed_ns"]
    proof = []
    def output(path):
        regular(path)
        item = b19.owned_file(path, root, start, end); proof.append(item)
        return path
    description = m.load_json(output(binary_dir / "description.json"))
    require(description["traitConfiguration"] == {"default": {}}, "unexpected selected traits")
    expected_graph = {"FluidAudio": {"FastClusterWrapper", "MachTaskSelfWrapper"},
                      "ParakeetHelper": {"FluidAudio", "FastClusterWrapper", "MachTaskSelfWrapper"},
                      HELPER: {"ParakeetHelper", "FluidAudio", "FastClusterWrapper", "MachTaskSelfWrapper"},
                      "FastClusterWrapper": set(), "MachTaskSelfWrapper": set()}
    graph = description["targetDependencyMap"]
    for name, deps in expected_graph.items(): require(set(graph[name]) == deps, "wrong selected helper dependency graph")
    require(not description["pluginDescriptions"] and not description["generatedSourceTargetSet"], "unexpected generated helper source/plugin")
    require(not any("FluidAudio_FluidAudio.bundle" in name for name in description["copyCommands"]), "automatic runtime resource processing still selected")
    actual = actual_commands(invocation, tools); selected_objects = set()
    manifest = inputs.derived / "Package@swift-6.2.swift"
    manifests = [args for args in actual if str(manifest) in args and "-package-description-version" in args]
    require(len(manifests) == 1 and b19.option(manifests[0], "-package-description-version") == "6.2.0", "selected SDK tools 6.2 manifest proof required")
    require(not any(str(inputs.derived / "Package.swift") in args for args in actual), "base SDK manifest selected")
    actual_modules = [b19.option(a, "-module-name") for a in actual if Path(a[0]).name == "swiftc" and "-c" in a]
    require(sorted(actual_modules) == sorted(("FluidAudio", "ParakeetHelper", HELPER)), "unexpected helper product compilation")
    permitted = [root, inputs.helper, Path(tools["toolchain"]), Path(tools["sdk"])]
    developer = Path(tools["toolchain"]).parents[1]
    permitted.extend([developer / "Platforms/MacOSX.platform/Developer/Library/Frameworks", developer / "Platforms/MacOSX.platform/Developer/usr/lib"])
    permitted.append(developer / "Platforms/MacOSX.platform/Developer/usr/bin")
    for args in actual:
        for arg in args:
            candidate = arg.removeprefix("@")
            if "=/" in candidate: candidate = candidate.split("=", 1)[1]
            if candidate.startswith("/"):
                require(all(any(Path(part).resolve().is_relative_to(base.resolve()) for base in permitted) for part in candidate.split("#")), "unapproved helper input/import/tool path")
    for module, source_root in (("FluidAudio", inputs.derived / "Sources/FluidAudio"),
                                ("ParakeetHelper", inputs.helper / "Sources/ParakeetHelper"),
                                (HELPER, inputs.helper / "Sources/ParlaParakeetHelper")):
        drivers = [a for a in actual if Path(a[0]).name == "swiftc" and "-c" in a and "-module-name" in a and b19.option(a, "-module-name") == module]
        frontends = [a for a in actual if Path(a[0]).name == "swift-frontend" and "-c" in a and "-module-name" in a and b19.option(a, "-module-name") == module]
        require(len(drivers) == len(frontends) == 1, "one fresh helper module compile required")
        driver, frontend = drivers[0], frontends[0]
        require(Path(driver[0]).resolve() == Path(tools["compiler"]["path"]) and Path(frontend[0]).resolve() == Path(tools["compiler"]["path"]), "wrong actual helper compiler")
        require(b19.option(frontend, "-target") == "arm64-apple-macosx14.0" and
                Path(b19.option(frontend, "-sdk")) == Path(tools["sdk"]) and b19.option(frontend, "-num-threads") == "2", "wrong helper target/SDK/threads")
        for arg in [*driver, *frontend]: no_engine(arg)
        sources = m.swift_sources(source_root)
        listings = [Path(a[1:]) for a in driver if a.startswith("@")]
        require(len(listings) == 1 and [Path(a) for a in shlex.split(output(listings[0]).read_text())] == sources, "wrong complete helper source list")
        require([Path(a) for a in frontend if a.endswith(".swift")] == sources, "wrong helper frontend sources")
        mapping = m.load_json(output(Path(b19.option(driver, "-output-file-map"))))
        require(set(mapping) == {"", *map(str, sources)}, "helper output map membership")
        entries = [v["object"] for v in mapping.values() if "object" in v]
        require(entries and len(entries) == len(set(entries)), "helper object map missing/duplicate")
        for entry in entries: selected_objects.add(output(Path(entry)))
        commands = [v for v in description["swiftCommands"].values() if v["moduleName"] == module]
        require(len(commands) == 1 and commands[0]["sources"] == list(map(str, sources)) and set(commands[0]["objects"]) == set(entries), "selected helper description/source/object mismatch")
        no_engine(json.dumps(commands[0]))
    links = [a for a in actual if Path(a[0]).name == "swiftc" and "-emit-executable" in a]
    require(len(links) == 1 and Path(b19.option(links[0], "-o")) == binary_dir / HELPER, "wrong helper link")
    link = links[0]
    no_engine(" ".join(link))
    response_files = [Path(a[1:]) for a in link if a.startswith("@")]
    require(len(response_files) == 1, "helper object response required")
    objects = [Path(a) for a in shlex.split(output(response_files[0]).read_text())]
    require(len(objects) == len(set(objects)) and set(objects) >= selected_objects, "helper linker object membership")
    wrappers = set()
    for obj in objects:
        no_engine(str(obj)); output(obj)
        if obj not in selected_objects:
            wrapper = next((n for n in ("FastClusterWrapper", "MachTaskSelfWrapper") if (n + ".build") in obj.parts), None)
            require(wrapper is not None, "unexpected helper linked object")
            wrappers.add(wrapper)
    require(wrappers == {"FastClusterWrapper", "MachTaskSelfWrapper"}, "both source wrappers required")
    clangs = [a for a in actual if Path(a[0]).name == "clang" and "-c" in a]
    require(all(Path(b19.option(a, "-c")).is_relative_to(inputs.derived / "Sources") for a in clangs), "unapproved wrapper input")
    for wrapper in wrappers:
        wrapper_sources = sorted(p for p in (inputs.derived / "Sources" / wrapper).rglob("*") if p.suffix in (".cpp", ".c", ".mm"))
        selected = [a for a in clangs if Path(b19.option(a, "-c")) in wrapper_sources]
        require(wrapper_sources and sorted(Path(b19.option(a, "-c")) for a in selected) == wrapper_sources, "wrapper compile source membership")
        for args in selected:
            require(Path(args[0]).resolve() == tools["paths"]["clang"].resolve() and b19.option(args, "-target") == "arm64-apple-macosx14.0" and
                    Path(b19.option(args, "-isysroot")) == Path(tools["sdk"]) and Path(b19.option(args, "-o")) in objects,
                    "wrong wrapper compiler/target/SDK/object")
            no_engine(" ".join(args))
            if Path(b19.option(args, "-c")).suffix == ".cpp": require("-std=c++17" in args or "-std=gnu++17" in args, "wrapper C++17 contract required")
    binary = output(binary_dir / HELPER)
    macho(binary, minimum="14.0", arches=("arm64",), sdk=inputs.policy["sdkVersion"])
    return binary, proof, actual, objects


def signed_policy(commands, tools, path, signing, *, parent=False):
    identifier = signing["parentIdentifier" if parent else "helperIdentifier"]
    requirement = 'anchor apple generic and identifier "' + identifier + '" and certificate leaf[subject.OU] = "' + signing["team"] + '" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
    commands.run([tools["paths"]["codesign"], "--verify", "--all-architectures", "--strict", "-R=" + requirement, path], "policy-verify-parent" if parent else "policy-verify-helper")
    info = commands.run([tools["paths"]["codesign"], "-d", "--verbose=4", path], "policy-info-parent" if parent else "policy-info-helper")
    text = (info["stdout"] + info["stderr"]).decode()
    require(len(text) <= 65536, "signature metadata limit")
    def field(key):
        found = re.findall(r"^" + re.escape(key) + r"=(.*)$", text, re.M)
        require(len(found) == 1, "missing/duplicate signature field: " + key)
        return found[0]
    require(field("Identifier") == identifier and field("TeamIdentifier") == signing["team"] and
            re.search(r"^Authority=" + re.escape(signing["category"]) + r": .+ \(" + re.escape(signing["team"]) + r"\)$", text, re.M) and
            "Authority=Developer ID Certification Authority\n" in text and "Authority=Apple Root CA" in text and
            re.search(r"^CodeDirectory .*flags=0x[0-9a-f]+\([^\n)]*runtime[^\n)]*\)", text, re.M) and
            "Signature=adhoc" not in text, "observed signer/identifier/team/runtime policy mismatch")
    entitlements = commands.run([tools["paths"]["codesign"], "-d", "--entitlements", ":-", path], "policy-entitlements-parent" if parent else "policy-entitlements-helper")
    data = entitlements["stdout"]
    require(len(data) <= 131072, "entitlements limit")
    observed = plistlib.loads(data) if data.strip() else {}
    require(observed == signing["parentEntitlements" if parent else "helperEntitlements"], "observed entitlement policy mismatch")


def product_identity(bundle, inputs):
    rows = bounded_inventory(bundle, ("Contents",))
    require({p.name for p in bundle.iterdir()} == {"Contents"} and
            all(p.startswith("Contents/Resources/") or p in ("Contents/MacOS/" + HELPER, "Contents/Info.plist", "Contents/_CodeSignature/CodeResources") for p in rows) and
            {"Contents/MacOS/" + HELPER, "Contents/Info.plist", "Contents/_CodeSignature/CodeResources"} <= set(rows), "unexpected helper code/layout or missing signed seal")
    resources = {p: v["sha256"] for p, v in rows.items() if p.startswith("Contents/Resources/")}
    require(0 < len(resources) <= 512, "resource inventory limit")
    for p in resources:
        require(rows[p]["size"] <= 16 * 1024 * 1024, "resource file limit")
        require("parakeet-product" not in p and not p.endswith("receipt.json"), "cyclic product resource")
    identity = {"protocolVersion": 1, "adapterRevision": 1, "sdk": PIN,
                "helperSHA256": m.digest(bundle / "Contents/MacOS" / HELPER), "sourceSHA256": inputs.source_hash,
                "resources": resources, "team": inputs.policy["signing"]["team"]}
    require(len(canonical(identity)) <= 131072, "descriptor limit")
    return identity


class Product:
    def __init__(self, bundle, inputs, commands, tools, validate_inputs):
        self.bundle, self.inputs, self.commands, self.tools = bundle, inputs, commands, tools
        self.validate_inputs = validate_inputs
        self.identity = product_identity(bundle, inputs)
        self.seal = bounded_inventory(bundle, ("Contents",))
        self.complete = self.inventory(bundle)

    @staticmethod
    def inventory(bundle):
        return {Path(path).relative_to(bundle).as_posix(): row for path, row in b19.inventory([bundle]).items()}

    def validate(self, app=None):
        self.validate_inputs()
        require(bounded_inventory(self.bundle, ("Contents",)) == self.seal and product_identity(self.bundle, self.inputs) == self.identity and self.inventory(self.bundle) == self.complete, "post-sign helper changed")
        if app is not None:
            copied = app / BUNDLE
            require(identities(bounded_inventory(copied, ("Contents",))) == identities(self.seal), "copied final helper changed")
            require(self.inventory(copied) == self.complete, "copied helper membership/mode/mtime changed")
            regular(app / "Contents/Resources/parakeet-product.json", 131072)
            require((app / "Contents/Resources/parakeet-product.json").read_bytes() == canonical(self.identity), "observed descriptor changed")

    def assemble(self, app):
        self.validate()
        destination = app / BUNDLE
        destination.parent.mkdir()
        shutil.copytree(self.bundle, destination)
        descriptor = app / "Contents/Resources/parakeet-product.json"
        with descriptor.open("xb") as out: out.write(canonical(self.identity))
        self.validate(app)

    def verify_parent(self, app):
        self.validate(app)
        macho(app / "Contents/MacOS/Parla", minimum="13.3", arches=("arm64", "x86_64"), sdk=self.inputs.policy["sdkVersion"])
        signed_policy(self.commands, self.tools, app, self.inputs.policy["signing"], parent=True)
        self.validate(app)


def produce_helper(inputs, root, commands, tools, identity, validate_tools):
    require(inputs.authentication_records is not None, "pinned source authentication required before helper compile")
    directory = root / "helper-build"; directory.mkdir()
    original_cwd = commands.repo; commands.repo = inputs.helper
    try:
        argv = [tools["paths"]["swift"], "build", "-c", "release", "--product", HELPER, "--arch", "arm64", "--jobs", "2",
                "--scratch-path", directory / "scratch", "--cache-path", directory / "cache", "--disable-automatic-resolution", "--skip-update",
                "-Xswiftc", "-num-threads", "-Xswiftc", "2", "-v"]
        invocation = commands.run(argv, "helper-build")
        query = commands.run([*argv, "--show-bin-path"], "helper-bin-path")
    finally: commands.repo = original_cwd
    binary_dir = Path(query["stdout"].decode().strip())
    require(binary_dir.is_absolute() and binary_dir.resolve() == binary_dir and binary_dir.is_relative_to(directory), "unowned helper binary path")
    binary, proof, actual, objects = validate_helper(inputs, directory, invocation, binary_dir, tools)
    for index, path in enumerate([binary, *objects]):
        symbol = commands.run([tools["paths"]["nm"], "-demangle", path], "helper-nm-" + str(index))
        no_engine((symbol["stdout"] + symbol["stderr"]).decode())
        proof.append(symbol["record"])
    loads = commands.run([tools["paths"]["otool"], "-L", binary], "helper-loads")
    no_engine((loads["stdout"] + loads["stderr"]).decode())
    proof.append(loads["record"])
    b19.write_json(root / "helper-build-proof.json", {"invocation": invocation["record"], "outputs": proof, "actualCommands": actual})
    proof.append(b19.record(root / "helper-build-proof.json"))
    proof_frozen = b19.inventory([Path(p["path"]) for p in [*proof, invocation["record"]]])
    bundle = root / "helper-product/ParlaParakeetHelper.bundle"
    mac, resources = bundle / "Contents/MacOS", bundle / "Contents/Resources"
    mac.mkdir(parents=True); resources.mkdir()
    shutil.copy2(binary, mac / HELPER)
    expected_resources = {}
    def resource(source, name):
        regular(source, 16 * 1024 * 1024)
        target = resources / name; target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        require(m.digest(source) == m.digest(target), "helper resource copy changed")
        expected_resources["Contents/Resources/" + name] = m.digest(source)
    for name in RUNTIME: resource(inputs.derived / RESOURCE_DIR / name, "FluidAudio_FluidAudio.bundle/" + name)
    resource(inputs.sdk / "LICENSE", "Notices/FluidAudio-LICENSE")
    for name in inputs.policy["sdkFiles"]:
        if name.startswith("ThirdPartyLicenses/"): resource(inputs.sdk / name, "Notices/" + name)
    source = resources / "parakeet-source.json"; source.write_bytes(inputs.source)
    expected_resources["Contents/Resources/parakeet-source.json"] = inputs.source_hash
    context = resources / "Notices/provenance.json"
    context.write_bytes(canonical({"sdkRevision": PIN, "sourceSHA256": inputs.source_hash, "noticePolicy": "complete selected-source notice tree; applicability remains release review", "NemoTextProcessing": "trait disabled; native engine not selected or distributed"}))
    expected_resources["Contents/Resources/Notices/provenance.json"] = m.digest(context)
    info = {"CFBundleIdentifier": HELPER_ID, "CFBundleExecutable": HELPER, "CFBundlePackageType": "BNDL", "CFBundleVersion": "1", "LSMinimumSystemVersion": "14.0"}
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info, sort_keys=True))
    entitlements = root / "helper-entitlements.plist"; entitlements.write_bytes(plistlib.dumps(inputs.policy["signing"]["helperEntitlements"]))
    inputs.validate(); validate_tools()
    commands.run([tools["paths"]["codesign"], "--force", "--timestamp", "--options", "runtime", "--identifier", HELPER_ID,
                  "--entitlements", entitlements, "-s", identity, bundle], "sign-helper")
    signed_policy(commands, tools, bundle, inputs.policy["signing"])
    # Signing may change code bytes; resource processing is fixed byte-exact.
    macho(mac / HELPER, minimum="14.0", arches=("arm64",), sdk=inputs.policy["sdkVersion"])
    def validate_inputs():
        inputs.validate(); validate_tools()
        for record in proof: m.checked_file(record)
        m.checked_file(invocation["record"])
        require(b19.inventory([Path(p["path"]) for p in [*proof, invocation["record"]]]) == proof_frozen, "helper build evidence/output metadata changed")
    validate_inputs()
    product = Product(bundle, inputs, commands, tools, validate_inputs)
    require(product.identity["resources"] == expected_resources, "post-sign resource membership/bytes changed")
    product.validate()
    b19.write_json(root / "helper-identity.json", product.identity)
    return product


class VersionRecords:
    def __init__(self, commands, tools, repo):
        self.records = []
        for args, name in ((["describe", "--tags", "--abbrev=0", "--always"], "version"), (["rev-list", "--count", "HEAD"], "build-number")):
            result = commands.run([tools["paths"]["git"], *args], name)
            self.records.append((result, result["stdout"]))
            require(result["exit"] == 0 and result.get("cwd", str(repo)) == str(repo), "version query must originate in original repo")
        self.values()

    def values(self):
        for record, output in self.records:
            m.checked_file(record["record"])
            value = m.load_json(Path(record["record"]["path"]))
            require(value["argv"] == record["argv"] and value["exit"] == 0, "version command record changed")
            # Commands log stdout is immutable evidence, not an environment value.
            path = Path(record["record"]["path"]).with_suffix(".stdout")
            require(path.read_bytes() == output, "version stdout record changed")
        version, build = (data.decode().strip() for _, data in self.records)
        version = version.removeprefix("v")
        require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}", version) and re.fullmatch(r"[0-9]{1,12}", build), "unsupported actual version/build output")
        return version, build


def materialize_main_inputs(inputs, product, root):
    destination = root / "main-input"
    copy_inputs(inputs.repo, destination, inputs.original["main"][2])
    text = canonical(product.identity).decode().strip()
    require(len(text.encode()) <= 131072 and "#" not in text and '\\' not in text, "unsupported embedded product identity")
    generated = ('import Foundation\nimport ParlaCore\n\n// Generated from the final signed helper, before B19 source freeze.\n'
                 'enum ParakeetProductBuildInput {\n    static let expected: ParakeetProductIdentity? = {\n'
                 '        let bytes = Data(#"' + text + '"#.utf8)\n'
                 '        guard bytes.count <= 131_072 else { return nil }\n'
                 '        return try? JSONDecoder().decode(ParakeetProductIdentity.self, from: bytes)\n    }()\n}\n').encode()
    (destination / EXPECTED).write_bytes(generated)
    frozen = bounded_inventory(destination, MAIN_ROOTS, framework_links=True, optional_roots=("Package.resolved",))
    expected = identities(inputs.original["main"][2]); expected[EXPECTED] = {"sha256": sha(generated)}
    require(identities(frozen) == expected, "unexpected main staging transformation")
    mapping = {"schema": 1, "original": identities(inputs.original["main"][2]), "derived": expected,
               "absentOptionalInputs": [p for p, row in inputs.original["main"][2].items() if "absent" in row],
               "generated": {EXPECTED: {"sha256": sha(generated), "productSHA256": sha(canonical(product.identity))}}}
    path = root / "main-source-map.json"; b19.write_json(path, mapping); recorded = b19.record(path)
    def validate():
        product.validate(); m.checked_file(recorded)
        require(bounded_inventory(destination, MAIN_ROOTS, framework_links=True, optional_roots=("Package.resolved",)) == frozen, "staged main inputs changed")
    validate()
    return destination, validate


def validate_root_graph(produced, commands, tools, policy):
    # B19's complete module/source/map/receipt gate runs first and stays intact.
    produced["validate"]()
    records = []
    for item in produced["data"]["slices"]:
        macho(Path(item["thin_binary"]["path"]), minimum="13.3", arches=(item["arch"],), sdk=policy["sdkVersion"])
        proof = next(p for p in item["generated_proof"] if p["path"].endswith("actual-commands.json"))
        actual = m.load_json(m.checked_file(proof))
        for args in actual:
            no_engine(" ".join(args))
            require(not re.search(r"FluidAudio|ParakeetHelper|ParlaParakeetHelper", " ".join(args)), "root optional compile/link edge")
        object_set = set()
        for proof in item["generated_proof"]:
            if not proof["path"].endswith("output-file-map.json"): continue
            mapping = m.load_json(m.checked_file(proof))
            for row in mapping.values():
                if "object" in row: object_set.add(Path(row["object"]))
        links = [args for args in actual if "-emit-executable" in args]
        require(len(links) == 1, "one root link required")
        responses = [Path(arg[1:]) for arg in links[0] if arg.startswith("@")]
        require(len(responses) == 1, "root object response required")
        # The owning slice directory is established by the B19 source list.
        root = Path(item["source_list"]["path"]).parent
        start, end = produced["data"]["started_ns"], produced["data"]["completed_ns"]
        records.append(b19.owned_file(responses[0], root, start, end))
        objects = [Path(p) for p in shlex.split(responses[0].read_text())]
        require(object_set and set(objects) == object_set and len(objects) == len(object_set), "root object membership mismatch")
        for index, obj in enumerate(objects):
            regular(obj)
            require(not re.search(r"FluidAudio|ParakeetHelper|ParlaParakeetHelper", str(obj)), "root optional object edge")
            no_engine(str(obj)); records.append(b19.owned_file(obj, root, start, end))
            symbols = commands.run([tools["paths"]["nm"], "-demangle", obj], "root-nm-" + item["arch"] + "-" + str(index))
            no_engine(symbols["stdout"].decode())
            require(not re.search(r"FluidAudio|NativeLocalSession|ParakeetHelper", symbols["stdout"].decode()), "root optional native symbol edge")
        loads = commands.run([tools["paths"]["otool"], "-L", item["thin_binary"]["path"]], "root-loads-" + item["arch"])
        no_engine(loads["stdout"].decode())
        require(not re.search(r"FluidAudio|ParakeetHelper|ParlaParakeetHelper", loads["stdout"].decode()), "root optional library load edge")
    macho(produced["binary"], minimum="13.3", arches=("arm64", "x86_64"), sdk=policy["sdkVersion"])
    for item in records: m.checked_file(item)
    return records


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--sdk-source", type=Path, required=True)
    parser.add_argument("--signing-identity", required=True)
    parser.add_argument("--architectures", choices=("universal",), default="universal")
    parser.add_argument("--native-metadata", choices=("0", "1"), required=True)
    options = parser.parse_args(argv)
    try:
        require(options.signing_identity.strip() not in ("", "-") and len(options.signing_identity.encode()) <= 512 and "\0" not in options.signing_identity, "explicit real signing identity required")
        require(not os.environ.get("PARLA_APPINTENTS_INPUTS"), "external build receipts refused")
        policy = read_policy(options.policy)
        repo = Path(__file__).resolve().parents[1]
        # Cheap owner/source-policy rejection precedes tool discovery/compilation.
        require(plistlib.loads((repo / "Resources/Parla.entitlements").read_bytes()) == policy["signing"]["parentEntitlements"], "parent entitlement policy mismatch")
        with b19.cancellation_scope() as scope:
            root = b19.fresh_root(options.output_root)
            commands = b19.Commands(root, repo); scope["commands"] = commands
            inputs = Inputs(repo, options.sdk_source, root, policy, options.policy)
            tools, records, validate_tools = selected_tools(commands, policy)
            tool_roots = b19.build_roots(inputs.helper, tools)
            tool_roots.append(Path(tools["toolchain"]).parents[1] / "Platforms/MacOSX.platform/Developer/usr/bin")
            tool_frozen = b19.inventory(tool_roots, source_root=inputs.helper / "Sources")
            b19.write_json(root / "helper-tool-inputs.json", tool_frozen)
            tool_record = b19.record(root / "helper-tool-inputs.json")
            validate_selected_tools = validate_tools
            def validate_tools():
                validate_selected_tools(); m.checked_file(tool_record)
                require(b19.inventory(tool_roots, source_root=inputs.helper / "Sources") == tool_frozen, "helper tool/SDK/platform inputs changed")
            def validate_inputs(): inputs.validate(); validate_tools()
            commands.revalidate = validate_inputs
            inputs.authenticate(commands, tools)
            versions = VersionRecords(commands, tools, repo)
            product = produce_helper(inputs, root, commands, tools, options.signing_identity, validate_tools)
            staged, validate_staged = materialize_main_inputs(inputs, product, root)
            main_root = root / "main-build"; main_root.mkdir()
            # Same B19 runner and signal scope; a fresh log/scratch namespace.
            # No previous tool is running at this transition.
            require(commands.settled, "helper tools incomplete")
            commands = b19.Commands(main_root, staged); scope["commands"] = commands
            product.commands = commands
            commands.revalidate = lambda: (validate_staged(), versions.values())
            produced = b19.produce(staged, main_root, ("arm64", "x86_64"), commands, tools)
            original_validate = produced["validate"]
            def validate_all():
                validate_staged(); versions.values(); original_validate()
            produced["validate"] = validate_all
            commands.revalidate = validate_all
            static_records = validate_root_graph(produced, commands, tools, policy)
            b19.write_json(root / "root-static-proof.json", static_records)
            static_records.append(b19.record(root / "root-static-proof.json"))
            immutable = [Path(item["path"]) for item in static_records]
            immutable.extend([produced["binary"], produced["receipt"], Path(produced["data"]["build_inputs"]["path"])])
            for item in produced["data"]["slices"]:
                immutable.extend(Path(p["path"]) for p in [item["source_list"], item["constant_list"], item["link_dependency"], item["thin_binary"], item["invocation"], *item["constants"], *item["generated_proof"]])
            immutable_frozen = b19.inventory(immutable)
            def validate_final():
                validate_all()
                for item in static_records: m.checked_file(item)
                require(b19.inventory(immutable) == immutable_frozen, "immutable main/receipt/output metadata changed")
            produced["validate"] = validate_final
            commands.revalidate = validate_final
            result = b19.package(staged, root, produced, commands, tools, options.signing_identity,
                                 native_metadata=options.native_metadata == "1", optional_product=product, version_records=versions)
            print(json.dumps(result))
    except b19.BuildCanceled as error:
        parser.exit(128 + error.signum, "Parla G3 source producer canceled.\n")
    except b19.ToolIncomplete as error:
        parser.exit(128 + error.signum if error.signum is not None else 1, str(error) + "; stage retained, no product qualified.\n")
    except (m.MetadataError, OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"Parla G3 source producer failed: {error}. No product qualified.\n")


if __name__ == "__main__": main()
