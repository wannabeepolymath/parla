#!/usr/bin/env python3
"""Explicit-input validator for the experimental static native metadata preview.

A handwritten receipt is not compiler provenance. Production packaging invokes
build-app-intents.py itself. Discovery and runtime remain unqualified.
"""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import time

DECLARATIONS = {
    "StartParlaDictationIntent", "StopParlaDictationIntent",
    "CancelParlaDictationIntent", "GetLastParlaResultIntent",
    "ParlaAppShortcuts", "ParlaAutomationResultEntity", "ParlaAutomationResultQuery",
}
KNOWN_XCODE = "17F113"
KNOWN_PROCESSOR_SHA = "e7122197c7960c363ead21eef931017eba3c992473625964cdfdeff584c4c2d0"
BUNDLE_ID = "io.github.wannabeepolymath.parla"


class MetadataError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise MetadataError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def checked_file(record):
    path = Path(record["path"])
    require(path.is_absolute() and path.is_file() and not path.is_symlink(), "missing input file")
    require(digest(path) == record["sha256"], "input identity changed")
    return path.resolve()


def file_list(record, records):
    path = checked_file(record)
    # Swift/Xcode auxiliary lists use one absolute path per line. Spaces are
    # literal; no shell parsing, expansions, quote removal or arbitrary flags.
    lines = path.read_text().splitlines()
    require(all(Path(line).is_absolute() for line in lines), "relative input list path")
    listed = [str(Path(line).resolve()) for line in lines]
    expected = [str(checked_file(item)) for item in records]
    require(listed == expected and len(set(listed)) == len(listed), "input list mismatch")
    return path


def load_json(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "duplicate JSON key")
            result[key] = value
        return result
    return json.loads(path.read_text(), object_pairs_hook=unique)


def swift_sources(root):
    require(root.is_dir() and not root.is_symlink(), "invalid source root")
    paths = list(root.rglob("*"))
    require(all(not p.is_symlink() for p in paths), "source symlink refused")
    return sorted(p.resolve() for p in paths if p.is_file() and p.suffix == ".swift")


def known_tool(receipt):
    require(receipt["xcode_version"] == KNOWN_XCODE and
            receipt["processor"]["sha256"] == KNOWN_PROCESSOR_SHA,
            "unsupported native metadata tool; experimental preview requires Xcode 17F113 / observed processor")


def declarations(value):
    if isinstance(value, dict):
        name = value.get("typeName", "")
        found = {name.removeprefix("Parla.")} if isinstance(name, str) else set()
        for child in value.values():
            found |= declarations(child)
        return found & DECLARATIONS
    if isinstance(value, list):
        return set().union(*(declarations(child) for child in value)) if value else set()
    return set()


def binary_architectures(path):
    """Read only Mach-O headers/load commands, never execute the supplied file."""
    data = path.read_bytes()
    cpus = {0x100000C: "arm64", 0x1000007: "x86_64"}

    def thin(offset, size):
        require(size >= 32 and offset + size <= len(data), "invalid binary slice")
        magic, cpu, _, kind, count, commands_size, _, _ = struct.unpack_from("<8I", data, offset)
        require(magic == 0xFEEDFACF and cpu in cpus and kind == 2, "expected macOS executable")
        cursor, limit = offset + 32, offset + 32 + commands_size
        require(limit <= offset + size and count <= commands_size // 8, "invalid load commands")
        deployment = None
        for _ in range(count):
            require(cursor + 8 <= limit, "invalid load command")
            command, length = struct.unpack_from("<2I", data, cursor)
            require(length >= 8 and cursor + length <= limit, "invalid load command length")
            if command == 0x32:
                require(length >= 24, "invalid build version")
                platform, deployment = struct.unpack_from("<2I", data, cursor + 8)
                require(platform == 1, "expected macOS platform")
            elif command == 0x24:
                require(length >= 16, "invalid minimum version")
                deployment = struct.unpack_from("<I", data, cursor + 8)[0]
            cursor += length
        require(cursor == limit and deployment == 0x000D0300, "expected deployment 13.3")
        return cpus[cpu]

    require(len(data) >= 8, "invalid executable")
    magic, count = struct.unpack_from(">2I", data)
    if magic not in (0xCAFEBABE, 0xCAFEBABF):
        return {thin(0, len(data))}
    require(count == 2, "expected two universal slices")
    stride = 20 if magic == 0xCAFEBABE else 32
    require(8 + count * stride <= len(data), "invalid universal header")
    architectures, ranges = set(), []
    for i in range(count):
        values = struct.unpack_from(">5I" if stride == 20 else ">2I2Q2I", data, 8 + i * stride)
        cpu, _, offset, size = values[:4]
        require(offset >= 8 + count * stride, "invalid universal offset")
        require(all(offset + size <= start or offset >= end for start, end in ranges), "overlapping slices")
        arch = thin(offset, size)
        require(cpus.get(cpu) == arch and arch not in architectures, "architecture mismatch")
        architectures.add(arch); ranges.append((offset, offset + size))
    return architectures


def validate_inputs(receipt, binary, source_root, architectures, now_ns):
    require(receipt["schema"] == 1 and receipt["module"] == "Parla" and receipt["deployment"] == "13.3", "wrong module/deployment")
    start, end = receipt["started_ns"], receipt["completed_ns"]
    require(isinstance(start, int) and isinstance(end, int) and 0 < start <= end <= now_ns,
            "invalid build interval")
    require(now_ns - start <= 3600 * 1_000_000_000, "stale build receipt")
    require(checked_file(receipt["binary"]) == binary.resolve(), "wrong executable")
    require(binary_architectures(binary) == set(architectures), "wrong binary architectures")
    require(start <= binary.stat().st_mtime_ns <= end, "binary outside build interval")
    sources = receipt["sources"]
    source_paths = [checked_file(item) for item in sources]
    require(set(source_paths) == set(swift_sources(source_root)) and len(set(source_paths)) == len(source_paths),
            "wrong module source set")
    require(bool(source_paths) and all(p.stat().st_mtime_ns <= binary.stat().st_mtime_ns for p in source_paths), "sources newer than binary")
    source_text = "\n".join(p.read_text() for p in source_paths)
    require(all("struct " + name in source_text for name in DECLARATIONS), "missing intended declarations")
    toolchain, sdk = Path(receipt["toolchain"]), Path(receipt["sdk"])
    require(toolchain.is_absolute() and toolchain.is_dir() and sdk.is_absolute() and sdk.is_dir(), "missing toolchain/SDK")
    processor = checked_file(receipt["processor"])
    require(processor == (toolchain / "usr/bin/appintentsmetadataprocessor").resolve() and os.access(processor, os.X_OK), "wrong metadata tool")
    compiler = checked_file(receipt["compiler"])
    sdk_settings = checked_file(receipt["sdk_settings"])
    require(compiler == (toolchain / "usr/bin/swift-frontend").resolve(), "wrong compiler")
    require(sdk_settings == (sdk / "SDKSettings.json").resolve(), "wrong SDK identity")
    version_file = checked_file(receipt["xcode_version_file"])
    version = plistlib.loads(version_file.read_bytes())["ProductBuildVersion"]
    require(version == receipt["xcode_version"] and isinstance(version, str) and bool(version), "wrong Xcode version")
    known_tool(receipt)
    slices = receipt["slices"]
    require(set(architectures) <= {"arm64", "x86_64"} and len(set(architectures)) == len(architectures), "unsupported architectures")
    require(len(slices) == len(architectures) and {s["arch"] for s in slices} == set(architectures), "wrong input architectures")
    args = [str(processor), "--toolchain-dir", str(toolchain), "--module-name", "Parla",
            "--sdk-root", str(sdk), "--xcode-version", version, "--platform-family", "macOS",
            "--deployment-target", "13.3", "--bundle-identifier", BUNDLE_ID]
    input_paths = set(source_paths + [binary.resolve(), processor, compiler, sdk_settings, version_file])
    const_paths = set()
    for item in slices:
        require(item["triple"] == item["arch"] + "-apple-macos13.3", "wrong target triple")
        source_list = file_list(item["source_list"], sources)
        constants = item["constants"]
        require(bool(constants), "missing constants")
        const_list = file_list(item["constant_list"], constants)
        found = set()
        for record in constants:
            path = checked_file(record)
            require(path not in const_paths, "shared architecture constants")
            const_paths.add(path)
            require(start <= path.stat().st_mtime_ns <= binary.stat().st_mtime_ns, "stale constants")
            value = load_json(path)
            require(isinstance(value, list) and bool(value), "empty constants")
            names = [entry.get("typeName") for entry in value if isinstance(entry, dict)]
            require(len(value) == len(DECLARATIONS) and set(names) == {"Parla." + n for n in DECLARATIONS}, "unexpected constant declarations")
            found |= declarations(value)
        require(found == DECLARATIONS, "constants missing intended declarations")
        dependency = checked_file(item["link_dependency"])
        require(start <= dependency.stat().st_mtime_ns <= binary.stat().st_mtime_ns, "stale link dependency")
        require(dependency.stat().st_size > 0, "empty link dependency")
        args += ["--target-triple", item["triple"], "--source-file-list", str(source_list),
                 "--swift-const-vals-list", str(const_list), "--dependency-file", str(dependency)]
        input_paths.update([source_list, const_list, dependency, *const_paths])
        require(isinstance(item.get("stringsdata", False), bool), "stringsdata must be an output request")
    for key, flag in [("metadata", "--metadata-file-list"), ("static_metadata", "--static-metadata-file-list")]:
        group = receipt[key]  # Explicit empty lists are valid; omission is not.
        path = file_list(group["list"], group["files"])
        args += [flag, str(path)]; input_paths.add(path)
        input_paths.update(checked_file(record) for record in group["files"])
    args += ["--binary-file", str(binary.resolve()), "--compile-time-extraction", "--deployment-aware-processing"]
    # Detect changes during runner execution/copy as well as stale receipt hashes.
    return args, {path: digest(path) for path in input_paths}


def validate_output(root, receipt):
    known_tool(receipt)
    require(root.is_dir() and not root.is_symlink(), "invalid generated root")
    paths = list(root.rglob("*"))
    require(all(not p.is_symlink() and (p.is_file() or p.is_dir()) for p in paths), "generated symlink/special file refused")
    require(all(p.stat().st_uid == os.getuid() for p in [root, *paths]), "unowned generated output")
    metadata = root / "Metadata.appintents"
    for name in ["extract.actionsdata", "version.json"]:
        path = metadata / name
        require(path.is_file() and path.stat().st_size > 0, "missing/empty generated metadata")
    # Installed/upstream xcspec still lists this opaque output. Its absence is
    # accepted ONLY for this observed static preview, never discovery proof.
    manifest = metadata / "objects.appintentsmanifest"
    if manifest.exists():
        require(manifest.is_file() and manifest.stat().st_size > 0, "invalid/empty generated manifest")
    require(load_json(metadata / "version.json") == {"toolsVersion": KNOWN_XCODE, "version": "3.0"}, "unsupported metadata schema/version")
    value = load_json(metadata / "extract.actionsdata")
    require(value["version"] == 1 and value["generator"] == {"name": "xcode-tools", "version": KNOWN_XCODE}, "wrong action generator/version")
    actions = value["actions"]
    expected = {
        "StartParlaDictationIntent": ("5Parla05StartA15DictationIntentV", "Start dictation with ${applicationName}"),
        "StopParlaDictationIntent": ("5Parla04StopA15DictationIntentV", "Stop dictation with ${applicationName}"),
        "CancelParlaDictationIntent": ("5Parla06CancelA15DictationIntentV", "Cancel dictation with ${applicationName}"),
        "GetLastParlaResultIntent": ("5Parla07GetLastA12ResultIntentV", "Get last result from ${applicationName}"),
    }
    primitive = {"primitive": {"wrapper": {"typeIdentifier": 0}}}
    entity_type = {"entity": {"wrapper": {"typeName": "ParlaAutomationResultEntity"}}}
    require(isinstance(actions, dict) and set(actions) == set(expected), "wrong action identities")
    for name, (mangled, _) in expected.items():
        action = actions[name]
        require(action["identifier"] == name and action["fullyQualifiedTypeName"] == "Parla." + name and
                action["mangledTypeName"] == mangled and action["mangledTypeNameV2"] == mangled, "wrong action type")
        require(action["openAppWhenRun"] is True and action["authenticationPolicy"] == 2 and
                action["isAuthPolExplicit"] is True, "wrong action policy")
        require(action["outputType"] == (entity_type if name in {"StopParlaDictationIntent", "GetLastParlaResultIntent"} else primitive), "wrong action result type")
        parameters = action["parameters"]
        if name in {"StopParlaDictationIntent", "CancelParlaDictationIntent"}:
            require(len(parameters) == 1 and parameters[0]["name"] == "controlSession" and
                    parameters[0]["valueType"] == primitive and parameters[0]["isOptional"] is False, "wrong control parameter")
        else:
            require(parameters == [], "unexpected action parameters")
    require(value["autoShortcutProviderMangledName"] == "5Parla0A12AppShortcutsV", "wrong shortcut provider")
    shortcuts = value["autoShortcuts"]
    require(len(shortcuts) == 4 and {s["actionIdentifier"] for s in shortcuts} == set(expected), "wrong shortcut references")
    for shortcut in shortcuts:
        require(shortcut["phraseTemplates"] == [{"alternatives": [], "key": expected[shortcut["actionIdentifier"]][1]}], "wrong shortcut phrase")
    require(set(value["entities"]) == {"ParlaAutomationResultEntity"} and set(value["queries"]) == {"ParlaAutomationResultQuery"}, "wrong entity/query identities")
    entity = value["entities"]["ParlaAutomationResultEntity"]
    require(entity["typeName"] == "ParlaAutomationResultEntity" and entity["fullyQualifiedTypeName"] == "Parla.ParlaAutomationResultEntity" and
            entity["mangledTypeName"] == "5Parla0A22AutomationResultEntityV" and
            entity["defaultQueryIdentifier"] == "Parla.ParlaAutomationResultQuery", "wrong entity/query reference")
    properties = entity["properties"]
    require(len(properties) == 2 and {p["identifier"] for p in properties} == {"text", "outcome"}, "wrong result properties")
    for prop in properties:
        require(prop["title"] == {"alternatives": [], "key": {"text": "Text", "outcome": "Outcome"}[prop["identifier"]]} and
                prop["valueType"] == primitive and prop["isOptional"] is False, "wrong result property type/title")
    query = value["queries"]["ParlaAutomationResultQuery"]
    require(query["identifier"] == query["queryType"] == "ParlaAutomationResultQuery" and
            query["fullyQualifiedIdentifier"] == "Parla.ParlaAutomationResultQuery" and
            query["mangledTypeName"] == "5Parla0A21AutomationResultQueryV" and
            query["entityType"] == "ParlaAutomationResultEntity" and query["defaultQueryForEntity"] is True and
            query["resultValueType"] == entity_type and query["parameters"] == [], "wrong result query")
    return {str(p.relative_to(root)): digest(p) for p in paths if p.is_file()}


@contextlib.contextmanager
def extraction_scratch(runner):
    owner = tempfile.TemporaryDirectory(prefix="parla-appintents-")
    try:
        yield owner.name
    finally:
        if getattr(runner, "settled", True): owner.cleanup()
        else: owner._finalizer.detach() # Unproven writer still owns this scratch; retain evidence.


def install_metadata(inputs, binary, resources, source_root, architectures, runner=subprocess.run, now_ns=None, copier=shutil.copytree):
    require(inputs is not None and inputs.is_file() and not inputs.is_symlink(), "native-enabled packaging requires explicit fresh inputs")
    receipt_digest = digest(inputs)
    receipt = load_json(inputs)
    args, identities = validate_inputs(receipt, binary, source_root, architectures, now_ns or time.time_ns())
    identities[inputs.resolve()] = receipt_digest
    source_set = {Path(record["path"]).resolve() for record in receipt["sources"]}
    def inputs_unchanged():
        return source_set == set(swift_sources(source_root)) and all(
            digest(path) == expected for path, expected in identities.items())
    require(resources.is_dir() and not resources.is_symlink(), "missing resources directory")
    # Never merge with a stale prior extraction. The app assembler owns a fresh
    # bundle; collisions are errors, including localizations/icon names.
    with extraction_scratch(runner) as directory:
        output = Path(directory) / "output"; output.mkdir()
        # These are extractor outputs, separate from installable resources and
        # immutable build inputs. The receipt never chooses their filesystem paths.
        if any(item.get("stringsdata", False) for item in receipt["slices"]):
            path = Path(directory) / "stringsdata" / "ExtractedAppShortcutsMetadata.stringsdata"
            path.parent.mkdir()
            args += ["--stringsdata-file", str(path)]
        result = runner(args + ["--output", str(output)], check=True, capture_output=True)
        require(result.returncode == 0, "extractor failed")
        inventory = validate_output(output, receipt)
        require(inputs_unchanged(), "inputs changed during extraction")
        children = list(output.iterdir())
        require(all(not (resources / p.name).exists() and not (resources / p.name).is_symlink() for p in children), "stale resource collision")
        installed = []
        try:
            for child in children:
                target = resources / child.name
                installed.append(target)
                if child.is_dir(): copier(child, target)
                else: shutil.copy2(child, target)
            require({str(p.relative_to(resources)): digest(p) for child in installed
                     for p in ([child] if child.is_file() else child.rglob("*")) if p.is_file()} == inventory and
                    all(not p.is_symlink() for child in installed for p in [child, *child.rglob("*")]), "resource copy mismatch")
            require(inputs_unchanged(), "inputs changed during copy")
        except Exception:
            for path in installed:
                if path.is_dir(): shutil.rmtree(path)
                elif path.exists(): path.unlink()
            raise
    return inventory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", required=True, type=Path)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--resources", required=True, type=Path)
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--architectures", required=True, nargs="+")
    options = parser.parse_args()
    try:
        inventory = install_metadata(options.inputs, options.binary, options.resources, options.source_root, options.architectures)
    except (MetadataError, OSError, ValueError, KeyError, TypeError, struct.error, plistlib.InvalidFileException, subprocess.SubprocessError):
        parser.exit(1, "Parla native metadata packaging failed; no native support qualified.\n")
    print(f"Installed native metadata resources ({len(inventory)} files); discovery/runtime remain unqualified.")


if __name__ == "__main__":
    main()
