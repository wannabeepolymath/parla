#!/usr/bin/env python3
"""Build once and optionally package Parla's experimental static native preview.

Only the observed Xcode 17F113 processor/schema is supported. No launch,
registration or runtime qualification is performed. All outputs must be new.
"""
import argparse
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import shlex
import signal
import selectors
import shutil
import stat
import subprocess
import sys
import time

sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location("parla_metadata", Path(__file__).with_name("app-intents-metadata.py"))
metadata = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(metadata)
require = metadata.require


class BuildCanceled(BaseException):
    def __init__(self, signum):
        self.signum = signum


class ToolIncomplete(BaseException):
    """The known child exited but inherited log writers have not closed."""
    def __init__(self, message, signum=None):
        super().__init__(message)
        self.signum = signum


@contextlib.contextmanager
def cancellation_scope():
    """Shared B19/G3 handle-install and cooperative unwind scope."""
    scope = {"commands": None}
    previous = {n: signal.getsignal(n) for n in (signal.SIGINT, signal.SIGTERM)}
    def cancel(signum, frame):
        for number in previous: signal.signal(number, signal.SIG_IGN)
        commands = scope["commands"]
        if commands is not None and commands.spawning:
            commands.cancel_signal = signum
            return
        raise BuildCanceled(signum)
    for number in previous: signal.signal(number, cancel)
    try: yield scope
    finally:
        for number, handler in previous.items(): signal.signal(number, handler)


def record(path):
    path = path.resolve(strict=True)
    require(path.is_file(), "expected file")
    return {"path": str(path), "sha256": metadata.digest(path)}


def write_json(path, value):
    with path.open("x") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")


def fresh_root(path):
    require(path.is_absolute(), "output root must be absolute")
    # Canonical parents avoid aliases; never accept an existing root or symlink.
    require(path.parent.is_dir() and path.parent.resolve() == path.parent, "output parent must exist and be canonical")
    require(not path.exists() and not path.is_symlink(), "output collision; choose a new isolated root")
    path.mkdir(mode=0o700)
    write_json(path / "ownership.json", {"purpose": "Parla experimental native static preview", "pid": os.getpid(), "created_ns": time.time_ns()})
    return path


def inventory(roots, *, source_root=None):
    """Complete membership/bytes/modes/mtimes, without traversing symlink dirs."""
    result = {}
    def visit(path):
        state = path.lstat()
        row = {"mode": state.st_mode}
        if stat.S_ISLNK(state.st_mode):
            require(source_root is None or not path.is_relative_to(source_root), "source symlink refused")
            row["link"] = os.readlink(path)
        elif stat.S_ISREG(state.st_mode):
            row.update(size=state.st_size, mtime_ns=state.st_mtime_ns, sha256=metadata.digest(path))
        elif stat.S_ISDIR(state.st_mode):
            for child in sorted(path.iterdir()): visit(child)
        else:
            require(False, "special build input refused")
        result[str(path)] = row
    for root in roots:
        if root.exists() or root.is_symlink(): visit(root)
        else: result[str(root)] = {"absent": True}
    return result


class Commands:
    """The sole bottom tool runner; tests replace this method, never a CLI flag."""
    def __init__(self, root, repo):
        self.root, self.repo = root, repo
        self.directory = root / "commands"; self.directory.mkdir()
        temp = root / "tooltmp"; temp.mkdir()
        self.env = {key: os.environ[key] for key in ("HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "__CF_USER_TEXT_ENCODING") if key in os.environ}
        self.env.update(PATH="/usr/bin:/bin:/usr/sbin:/sbin", TMPDIR=str(temp))
        self.env.update(GIT_OPTIONAL_LOCKS="0", GIT_NO_LAZY_FETCH="1", GIT_TERMINAL_PROMPT="0")
        self.count = 0
        self.spawning = False
        self.cancel_signal = None
        self.settled = True
        self.revalidate = lambda: None

    def run(self, argv, name):
        self.revalidate()
        self.count += 1
        prefix = self.directory / f"{self.count:02d}-{name}"
        argv = [str(arg) for arg in argv]
        started = time.time_ns()
        with prefix.with_suffix(".stdout").open("xb") as out, prefix.with_suffix(".stderr").open("xb") as err, selectors.DefaultSelector() as streams:
            process = None
            command = {"argv": argv, "cwd": str(self.repo), "pid": None, "started_ns": started}
            driver_outputs = {}
            failure = None
            log_capped = False
            try:
                self.spawning = True
                try:
                    process = subprocess.Popen(argv, cwd=self.repo, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                    command["pid"] = process.pid
                    self.settled = False
                    for source, destination in ((process.stdout, out), (process.stderr, err)):
                        os.set_blocking(source.fileno(), False)
                        streams.register(source, selectors.EVENT_READ, destination)
                finally:
                    self.spawning = False
                write_json(prefix.with_suffix(".running.json"), command)
                if self.cancel_signal is not None:
                    raise BuildCanceled(self.cancel_signal)
                exited_at = None
                while True:
                    self._drain(streams)
                    # Retain actual driver maps before Swift deletes them. They
                    # are never constructed or supplied as compiler inputs.
                    for source in (self.root / "tooltmp").glob("TemporaryDirectory.*/supplementaryOutputs-*"):
                        require(not source.is_symlink() and source.resolve().is_relative_to(self.root / "tooltmp"), "unowned driver output")
                        destination = self.root / "driver-outputs" / source.parent.name / source.name
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        try:
                            shutil.copy2(source, destination)
                            driver_outputs[str(source)] = str(destination)
                        except FileNotFoundError:
                            pass  # The driver can remove a map between scans.
                    code = process.poll()
                    if code is not None:
                        process.wait()
                        if not streams.get_map():
                            self.settled = True
                            break
                        if exited_at is None: exited_at = time.monotonic()
                        require(time.monotonic() - exited_at < 2, "tool exited with inherited IO still open")
            except BaseException as error:
                failure = error
                if process is not None and process.poll() is None:
                    try: os.killpg(process.pid, signal.SIGTERM)
                    except ProcessLookupError: pass
                    try: process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        try: os.killpg(process.pid, signal.SIGKILL)
                        except ProcessLookupError: pass
                        process.wait()
                code = process.returncode if process is not None else None
                # Reaping the leader alone does not prove descendant/log closure.
                deadline = time.monotonic() + 2
                while streams.get_map() and time.monotonic() < deadline:
                    # A bounded-log failure must still drain EOF and finalize
                    # the waited child record; discard only excess failed IO.
                    try: Commands._drain(streams, discard=log_capped)
                    except metadata.MetadataError: log_capped = True
                self.settled = not streams.get_map()
            finally:
                for key in list(streams.get_map().values()): key.fileobj.close()
        command.update(exit=code, completed_ns=time.time_ns())
        command["io_closed"] = self.settled
        command["log_capped"] = log_capped
        write_json(prefix.with_suffix(".json"), command)
        prefix.with_suffix(".running.json").unlink(missing_ok=True)
        print(f"{name}: pid {command['pid']}, exit {code}", file=sys.stderr, flush=True)
        command.update(driver_outputs=driver_outputs, stdout=prefix.with_suffix(".stdout").read_bytes(), stderr=prefix.with_suffix(".stderr").read_bytes(), record=record(prefix.with_suffix(".json")))
        if not self.settled:
            signum = failure.signum if isinstance(failure, BuildCanceled) else self.cancel_signal
            raise ToolIncomplete("owned command IO incomplete; preserve stage and evidence", signum) from failure
        if failure is not None: raise failure
        if code:
            raise metadata.MetadataError(f"{name} failed ({code}); see {prefix}.stderr")
        self.revalidate()
        return command

    @staticmethod
    def _drain(streams, *, discard=False):
        for key, _ in streams.select(timeout=0.05):
            data = os.read(key.fd, 65536)
            if data:
                if discard: continue
                require(key.data.tell() + len(data) <= 128 * 1024 * 1024, "tool log limit exceeded")
                key.data.write(data)
            else:
                streams.unregister(key.fileobj)
                key.fileobj.close()

    def __call__(self, argv, **options):
        require(options == {"check": True, "capture_output": True}, "unexpected processor runner options")
        result = self.run(argv, "extract")
        return subprocess.CompletedProcess(argv, result["exit"], result["stdout"], result["stderr"])


def resolve_tools(commands):
    def query(args, name): return commands.run(args, name)["stdout"].decode().strip()
    developer = Path(query(["/usr/bin/xcode-select", "-p"], "developer")).resolve(strict=True)
    commands.env["DEVELOPER_DIR"] = str(developer)
    tools = {name: Path(query(["/usr/bin/xcrun", "--find", name], "find-" + name)) for name in (
        "swift", "swiftc", "swift-frontend", "appintentsmetadataprocessor", "ld", "clang", "lipo", "install_name_tool", "otool")}
    toolchain = tools["swift-frontend"].parent.parent.parent.resolve(strict=True)
    require(all(path.resolve().is_relative_to(toolchain) for path in tools.values()), "mixed selected toolchains")
    sdk = Path(query(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk")).resolve(strict=True)
    version_file = developer.parent / "version.plist"
    version = plistlib.loads(version_file.read_bytes())["ProductBuildVersion"]
    tools.update(codesign=Path("/usr/bin/codesign"), plutil=Path("/usr/bin/plutil"), git=Path("/usr/bin/git"))
    commands.env.update(PATH=str(toolchain / "usr/bin") + ":/usr/bin:/bin:/usr/sbin:/sbin", SDKROOT=str(sdk))
    commands.run([tools["swift"], "--version"], "swift-version")
    commands.run([developer / "usr/bin/xcodebuild", "-version"], "xcode-version")
    result = {"paths": tools, "toolchain": str(toolchain), "sdk": str(sdk), "xcode_version": version,
              "xcode_version_file": record(version_file), "compiler": record(tools["swift-frontend"]),
              "processor": record(tools["appintentsmetadataprocessor"]), "sdk_settings": record(sdk / "SDKSettings.json"),
              "discovery": record(toolchain / "usr/share/swift/SwiftConstantValues/AppIntents.json")}
    metadata.known_tool(result)
    return result


def build_roots(repo, tools):
    developer = Path(tools["toolchain"]).parents[1]
    return [repo / name for name in ("Package.swift", "Package.resolved", "Sources", "Frameworks", "Resources",
            "scripts/build-app-intents.py", "scripts/app-intents-metadata.py", "scripts/make-app.sh",
            "scripts/build-parakeet-app.py", "scripts/parakeet-resource-accessor.swift.in")] + [
        Path(tools["toolchain"]), Path(tools["sdk"]), Path(tools["xcode_version_file"]["path"]),
        developer / "Platforms/MacOSX.platform/Developer/Library/Frameworks",
        developer / "Platforms/MacOSX.platform/Developer/usr/lib",
        *[path.resolve() for path in tools["paths"].values()]]


def option(argv, name):
    require(name in argv and argv.index(name) + 1 < len(argv), "missing actual driver option: " + name)
    return argv[argv.index(name) + 1]


def owned_file(path, root, start, end):
    require(path.is_absolute() and path.is_relative_to(root) and path.resolve() == path and not path.is_symlink() and path.is_file(), "unowned generated build input")
    require(start <= path.stat().st_mtime_ns <= end, "generated output outside invocation interval")
    return record(path)


def read_build(commands, invocation, directory, bin_dir, repo, arch, tools, protocols):
    start, end = invocation["started_ns"], invocation["completed_ns"]
    log = (invocation["stdout"] + b"\n" + invocation["stderr"]).decode()
    actual = []
    for line in log.splitlines():
        # Verbose output contains real driver/frontend/link commands, not replay.
        if line.startswith((str(Path(tools["toolchain"]) / "usr/bin/"), '"' + str(Path(tools["toolchain"]) / "usr/bin/"))):
            actual.append(shlex.split(line))
    proof = []
    constants, source_records = None, None
    for module in ("ParlaCore", "Parla"):
        drivers = [a for a in actual if Path(a[0]).name == "swiftc" and "-c" in a and "-module-name" in a and option(a, "-module-name") == module]
        frontends = [a for a in actual if Path(a[0]).name == "swift-frontend" and "-c" in a and "-module-name" in a and option(a, "-module-name") == module]
        require(len(drivers) == len(frontends) == 1, "expected one actual compile per module/architecture")
        driver, frontend = drivers[0], frontends[0]
        require(Path(driver[0]).resolve() == Path(tools["compiler"]["path"]) and Path(frontend[0]).resolve() == Path(tools["compiler"]["path"]), "wrong actual compiler")
        require(option(frontend, "-target") == arch + "-apple-macosx13.3" and
                Path(option(frontend, "-sdk")).resolve() == Path(tools["sdk"]) and option(frontend, "-num-threads") == "2", "wrong actual frontend target/SDK/threads")
        require("-emit-const-values" in driver and option(frontend, "-const-gather-protocols-file") == str(protocols), "missing constant emission input")
        source_lists = [Path(arg[1:]) for arg in driver if arg.startswith("@")]
        require(len(source_lists) == 1, "unexpected driver source list")
        listing = source_lists[0]; proof.append(owned_file(listing, directory, start, end))
        # SwiftPM response files quote paths with spaces; receipt lists are literal.
        sources = [Path(arg).resolve() for arg in shlex.split(listing.read_text())]
        require(sources == metadata.swift_sources(repo / "Sources" / module), "actual source list differs from complete module")
        require([Path(a).resolve() for a in frontend if a.endswith(".swift")] == sources, "frontend source set mismatch")
        mapping = Path(option(driver, "-output-file-map")); proof.append(owned_file(mapping, directory, start, end))
        value = metadata.load_json(mapping)
        require(set(value) == {"", *[str(p) for p in sources]}, "actual output map source mismatch")
        derived = Path(value[""]["swift-dependencies"]).parent / (module + ".swiftconstvalues")
        if "-supplementary-output-file-map" in frontend:
            original = option(frontend, "-supplementary-output-file-map")
            require(Path(original).is_relative_to(directory.parent / "tooltmp"), "unowned supplementary output map")
            retained = Path(invocation["driver_outputs"][original])
            proof.append(owned_file(retained, directory.parent, start, end))
            supplementary = metadata.load_json(retained)
            require(set(supplementary) <= {"", *[str(p) for p in sources]} and
                    [entry["const-values"] for entry in supplementary.values() if "const-values" in entry] == [str(derived)],
                    "unsupported driver constant derivation")
        else:
            require(Path(option(frontend, "-emit-const-values-path")) == derived, "unsupported driver constant derivation")
        const = owned_file(derived, directory, start, end); proof.append(const)
        declarations = metadata.load_json(derived)
        if module == "ParlaCore":
            require(declarations == [], "metadata-bearing dependency unsupported; do not omit dependent metadata")
        else:
            require(isinstance(declarations, list) and len(declarations) == len(metadata.DECLARATIONS) and
                    {entry.get("typeName") for entry in declarations} == {"Parla." + n for n in metadata.DECLARATIONS}, "wrong/empty Parla declarations")
            constants = const; source_records = [record(p) for p in sources]
    links = [a for a in actual if Path(a[0]).name == "swiftc" and "-emit-executable" in a]
    require(len(links) == 1 and Path(option(links[0], "-o")) == bin_dir / "Parla", "wrong actual link output")
    dependency = directory / "Parla_dependency_info.dat"
    require(str(dependency) in links[0] and "-dependency_info" in links[0], "wrong actual link dependency output")
    owned_file(dependency, directory, start, end)
    binary = bin_dir / "Parla"; owned_file(binary, directory, start, end)
    require(Path(constants["path"]).stat().st_mtime_ns <= dependency.stat().st_mtime_ns <= binary.stat().st_mtime_ns, "constant/link/binary ordering mismatch")
    require(metadata.binary_architectures(binary) == {arch}, "wrong produced architecture")
    # Empty metadata lists are evidenced only for the current dependency graph.
    description = bin_dir / "description.json"; proof.append(owned_file(description, directory, start, end))
    graph = metadata.load_json(description)["targetDependencyMap"]
    require(set(graph["Parla"]) == {"ParlaCore", "whisper"} and graph["ParlaCore"] == ["whisper"] and graph.get("whisper", []) == [], "unsupported executable dependencies")
    require(not list(directory.rglob("*.actionsdata")) and not list(directory.rglob("*.appintents")), "dependent metadata requires unsupported input contract")
    evidence = directory / "actual-commands.json"; write_json(evidence, actual); proof.append(record(evidence))
    source_list = directory / "sources.list"; source_list.write_text("".join(item["path"] + "\n" for item in source_records))
    constant_list = directory / "constants.list"; constant_list.write_text(constants["path"] + "\n")
    return {"arch": arch, "triple": arch + "-apple-macos13.3", "source_list": record(source_list),
            "constants": [constants], "constant_list": record(constant_list), "link_dependency": record(dependency), "stringsdata": True,
            "thin_binary": record(binary), "invocation": invocation["record"], "generated_proof": proof}, source_records


def produce(repo, root, architectures, commands, tools):
    require(architectures in [("arm64",), ("x86_64",), ("arm64", "x86_64")], "unsupported architecture choice")
    metadata.known_tool(tools)
    roots = build_roots(repo, tools)
    frozen = inventory(roots, source_root=repo / "Sources")
    frozen_path = root / "build-inputs.json"; write_json(frozen_path, frozen)
    def inputs_unchanged():
        require(inventory(roots, source_root=repo / "Sources") == frozen, "build input set/identity changed")
    discovery = metadata.load_json(Path(tools["discovery"]["path"]))
    require(discovery["version"] == 1 and isinstance(discovery["constValueProtocols"], list) and
            all(isinstance(x, str) and x for x in discovery["constValueProtocols"]) and
            {"AppIntent", "AppEntity", "EntityQuery", "AppShortcutsProvider"} <= set(discovery["constValueProtocols"]), "unsupported protocol discovery input")
    slices, sources, starts, ends = [], None, [], []
    for arch in architectures:
        directory = root / arch; directory.mkdir()
        protocols = directory / "protocols.json"; write_json(protocols, discovery["constValueProtocols"])
        argv = [tools["paths"]["swift"], "build", "-c", "release", "--product", "Parla", "--arch", arch, "--jobs", "2",
                "--scratch-path", directory / "build", "--cache-path", root / "cache", "--disable-automatic-resolution", "--skip-update",
                "-Xswiftc", "-num-threads", "-Xswiftc", "2", "-Xswiftc", "-emit-const-values",
                "-Xswiftc", "-Xfrontend", "-Xswiftc", "-const-gather-protocols-file", "-Xswiftc", "-Xfrontend", "-Xswiftc", protocols,
                "-Xlinker", "-dependency_info", "-Xlinker", directory / "Parla_dependency_info.dat", "-v"]
        invocation = commands.run(argv, "build-" + arch)
        query = commands.run([*argv, "--show-bin-path"], "bin-path-" + arch)
        bin_dir = Path(query["stdout"].decode().strip())
        require(bin_dir.is_absolute() and bin_dir.is_relative_to(directory) and bin_dir.resolve() == bin_dir, "unowned SwiftPM binary path")
        item, current_sources = read_build(commands, invocation, directory, bin_dir, repo, arch, tools, protocols)
        item["generated_proof"].append(record(protocols))
        require(sources is None or sources == current_sources, "cross-architecture source mismatch")
        sources = current_sources; slices.append(item); starts.append(invocation["started_ns"]); ends.append(invocation["completed_ns"])
        inputs_unchanged()
    binary = root / "Parla"
    if len(slices) == 2:
        commands.run([tools["paths"]["lipo"], "-create", *[s["thin_binary"]["path"] for s in slices], "-output", binary], "lipo")
    else:
        shutil.copy2(Path(slices[0]["thin_binary"]["path"]), binary)
    receipt = {key: tools[key] for key in ("toolchain", "sdk", "xcode_version", "xcode_version_file", "compiler", "processor", "sdk_settings", "discovery")}
    receipt.update(schema=1, module="Parla", deployment="13.3", started_ns=min(starts), completed_ns=time.time_ns(),
                   binary=record(binary), sources=sources, slices=slices, build_inputs=record(frozen_path),
                   selected_tools={name: record(path) for name, path in tools["paths"].items()})
    for key in ("metadata", "static_metadata"):
        path = root / (key + ".list"); path.write_text("")
        receipt[key] = {"list": record(path), "files": []}
    receipt_path = root / "receipt.json"
    # Never publish a fresh-looking receipt until the actual invocation and every
    # immutable generated input have passed, including the final lipo input.
    def validate():
        inputs_unchanged()
        metadata.validate_inputs(receipt, binary, repo / "Sources/Parla", architectures, time.time_ns())
        metadata.checked_file(receipt["build_inputs"])
        for item in slices:
            for proof in [item["thin_binary"], item["invocation"], *item["generated_proof"]]: metadata.checked_file(proof)
        if receipt_path.exists(): require(metadata.load_json(receipt_path) == receipt, "producer receipt changed")
    validate(); write_json(receipt_path, receipt)
    return {"binary": binary, "receipt": receipt_path, "data": receipt, "validate": validate}


def sign_arguments(app, repo, identity):
    framework = app / "Contents/Frameworks/whisper.framework"
    if identity:
        return [["--force", "--timestamp", "--options", "runtime", "-s", identity, str(framework)],
                ["--force", "--timestamp", "--options", "runtime", "-s", identity, "--entitlements", str(repo / "Resources/Parla.entitlements"), str(app)]]
    return [["--force", "--timestamp=none", "-s", "-", str(framework)],
            ["--force", "--timestamp=none", "-s", "-", "--identifier", metadata.BUNDLE_ID,
             '-r=designated => identifier "' + metadata.BUNDLE_ID + '"', str(app)]]


def package(repo, root, produced, commands, tools, identity, *, copier=shutil.copytree,
            native_metadata=True, optional_product=None, version_records=None):
    app = root / "staging/Parla.app"; target = root / "Parla.app"
    require(not target.exists() and not target.is_symlink(), "bundle output collision")
    app.parent.mkdir(); app.mkdir()
    stage_identity = (app.stat().st_dev, app.stat().st_ino)
    promoted_identity = None
    pending_identity = None
    result_identity = None
    assembled = {}
    resource_inventory = None
    def validate():
        produced["validate"]()
        if optional_product is not None: optional_product.validate(app if (app / "Contents/Helpers").exists() else None)
        require(all(inventory([Path(path)]) == {path: row} for path, row in assembled.items()), "assembled resource changed")
        if resource_inventory is not None:
            require(inventory([resources, app / "Contents/Info.plist"]) == resource_inventory, "assembled resource inventory changed")
    previous_validation = commands.revalidate
    commands.revalidate = validate
    try:
        mac, resources, frameworks = [app / "Contents" / name for name in ("MacOS", "Resources", "Frameworks")]
        for path in (mac, resources, frameworks): path.mkdir(parents=True)
        produced["validate"]()
        shutil.copy2(produced["binary"], mac / "Parla")
        require(metadata.digest(mac / "Parla") == produced["data"]["binary"]["sha256"], "copied executable mismatch")
        for name in ("AppIcon.icns", "menubar.png"):
            shutil.copy2(repo / "Resources" / name, resources / name)
            require(metadata.digest(resources / name) == metadata.digest(repo / "Resources" / name), "resource copy mismatch")
            assembled.update(inventory([resources / name]))
        framework = repo / "Frameworks/whisper.xcframework/macos-arm64_x86_64/whisper.framework"
        require(all(not p.is_symlink() or (not Path(os.readlink(p)).is_absolute() and p.resolve().is_relative_to(framework))
                    for p in framework.rglob("*")), "external framework symlink refused")
        copier(framework, frameworks / "whisper.framework", symlinks=True)
        require(inventory([framework]) == {str(framework / Path(p).relative_to(frameworks / "whisper.framework")): v
                for p, v in inventory([frameworks / "whisper.framework"]).items()}, "framework copy mismatch")
        if version_records is None:
            version_result = commands.run([tools["paths"]["git"], "describe", "--tags", "--abbrev=0", "--always"], "version")
            version = version_result["stdout"].decode().strip().removeprefix("v")
            build = commands.run([tools["paths"]["git"], "rev-list", "--count", "HEAD"], "build-number")["stdout"].decode().strip()
        else:
            version, build = version_records.values()
        validate()
        # Consume the existing plist literal; never evaluate shell or JSON paths.
        template = (repo / "scripts/make-app.sh").read_text().split('<<EOF\n', 1)[1].split('\nEOF', 1)[0]
        for old, new in (("$BUNDLE_ID", metadata.BUNDLE_ID), ("$VERSION", version), ("$BUILD", build)):
            template = template.replace(old, new)
        require("$" not in template, "unsupported plist substitution")
        plist = plistlib.loads(template.encode())
        require(plist["LSMinimumSystemVersion"] == "13.3" and plist["CFBundleExecutable"] == "Parla", "wrong bundle plist")
        (app / "Contents/Info.plist").write_bytes(template.encode() + b"\n")
        assembled.update(inventory([app / "Contents/Info.plist"]))
        if optional_product is not None:
            optional_product.assemble(app)
            validate()
        initial_resources = inventory([resources, app / "Contents/Info.plist"])
        initial_paths = {str(resources), str(app / "Contents/Info.plist"),
                         *(str(resources / name) for name in ("AppIcon.icns", "menubar.png"))}
        if optional_product is not None:
            initial_paths.add(str(resources / "parakeet-product.json"))
        require(set(initial_resources) == initial_paths, "unexpected initial resources")
        assembled.update({path: row for path, row in initial_resources.items() if "sha256" in row})
        # TemporaryDirectory lives in the owned output; retain actual extractor
        # command/output receipts outside the app. Auxiliary stringsdata is not a translation.
        old_temp = metadata.tempfile.tempdir
        metadata.tempfile.tempdir = str(root / "tooltmp")
        try:
            generated = metadata.install_metadata(produced["receipt"], produced["binary"], resources, repo / "Sources/Parla",
                [s["arch"] for s in produced["data"]["slices"]], runner=commands, copier=copier) if native_metadata else []
        finally:
            metadata.tempfile.tempdir = old_temp
        validate()
        expected_paths = set(initial_resources)
        for relative, digest in (generated.items() if isinstance(generated, dict) else ()):
            path = resources / relative
            require(metadata.digest(path) == digest, "extracted resource changed")
            while path != resources:
                expected_paths.add(str(path)); path = path.parent
        resource_inventory = inventory([resources, app / "Contents/Info.plist"])
        require(set(resource_inventory) == expected_paths, "unexpected assembled resources")
        commands.run([tools["paths"]["install_name_tool"], "-add_rpath", "@executable_path/../Frameworks", mac / "Parla"], "rpath")
        validate()
        for args, name in zip(sign_arguments(app, repo, identity), ("sign-framework", "sign-app")):
            commands.run([tools["paths"]["codesign"], *args], name)
            validate()
        signed = inventory([app])
        commands.run([tools["paths"]["codesign"], "--verify", "--all-architectures", "--strict", "--verbose=4", frameworks / "whisper.framework"], "verify-framework")
        commands.run([tools["paths"]["codesign"], "--verify", "--all-architectures", "--deep", "--strict", "--verbose=4", app], "verify-app")
        commands.run([tools["paths"]["codesign"], "-d", "--verbose=4", "-r-", app], "signature")
        commands.run([tools["paths"]["plutil"], "-lint", app / "Contents/Info.plist"], "plist")
        commands.run([tools["paths"]["otool"], "-arch", "all", "-l", mac / "Parla"], "loadcommands")
        if optional_product is not None: optional_product.verify_parent(app)
        require(metadata.binary_architectures(mac / "Parla") == {s["arch"] for s in produced["data"]["slices"]}, "signed architecture mismatch")
        require(inventory([resources, app / "Contents/Info.plist"]) == resource_inventory and inventory([app]) == signed, "signed bundle changed")
        validate()
        require(inventory([app]) == signed, "signed bundle changed before promotion")
        write_json(root / "signed-bundle.json", signed)
        result = {"status": "EXPERIMENTAL STATIC PREVIEW; B19 PARTIAL; discovery/runtime unqualified", "app": str(target),
                  "producer_binary": record(produced["binary"]), "producer_receipt": record(produced["receipt"]),
                  "signed_binary_sha256": metadata.digest(mac / "Parla"), "metadata": generated, "architectures": [s["arch"] for s in produced["data"]["slices"]]}
        # renamex_np(RENAME_EXCL) is the macOS no-replace directory promotion.
        # os.rename alone can replace an empty directory created concurrently.
        pending = root / "package-result.pending.json"
        write_json(pending, result)
        pending_identity = (pending.stat().st_dev, pending.stat().st_ino)
        app_identity = (app.stat().st_dev, app.stat().st_ino)
        require(app_identity == stage_identity and not app.is_symlink(), "app stage ownership changed")
        validate()
        require(inventory([app]) == signed, "signed bundle changed at promotion")
        promoted_identity = app_identity
        promote(app, target)
        require(target.is_dir() and not target.is_symlink() and (target.stat().st_dev, target.stat().st_ino) == stage_identity,
                "promoted app ownership changed")
        produced["validate"]()
        if optional_product is not None: optional_product.validate(target)
        rebased = {str(target / Path(path).relative_to(app)): row for path, row in signed.items()}
        require(inventory([target]) == rebased, "promoted signed bundle changed")
        result_identity = pending_identity
        promote(pending, root / "package-result.json")
        return result
    except BaseException:
        # Only the stage created in this call is owned for rollback. Build inputs
        # and failed command evidence stay outside it for review.
        if not commands.settled: raise
        if optional_product is not None and not optional_product.inputs.root_owned(): raise
        if app.is_dir() and not app.is_symlink() and (app.stat().st_dev, app.stat().st_ino) == stage_identity: shutil.rmtree(app)
        if promoted_identity is not None and target.is_dir() and not target.is_symlink() and (target.stat().st_dev, target.stat().st_ino) == promoted_identity:
            shutil.rmtree(target)
        pending = root / "package-result.pending.json"
        if pending_identity is not None and pending.is_file() and not pending.is_symlink() and (pending.stat().st_dev, pending.stat().st_ino) == pending_identity:
            pending.unlink()
        final_result = root / "package-result.json"
        if result_identity is not None and final_result.is_file() and not final_result.is_symlink() and (final_result.stat().st_dev, final_result.stat().st_ino) == result_identity:
            final_result.unlink()
        raise
    finally:
        commands.revalidate = previous_validation


def promote(source, destination):
    import ctypes
    libc = ctypes.CDLL(None, use_errno=True)
    call = libc.renamex_np
    call.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    call.restype = ctypes.c_int
    if call(os.fsencode(source), os.fsencode(destination), 4) != 0:  # RENAME_EXCL
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(destination))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", type=Path, required=True, help="new absolute isolated root; existing paths refuse")
    parser.add_argument("--architectures", choices=("host", "universal"), default="host")
    parser.add_argument("--package", action="store_true")
    options = parser.parse_args(argv)
    try:
        with cancellation_scope() as scope:
            require(not os.environ.get("PARLA_APPINTENTS_INPUTS"), "external receipts cannot replace the trusted producer; unset PARLA_APPINTENTS_INPUTS")
            identity = os.environ.get("PARLA_SIGN_IDENTITY", "")
            architectures = ("arm64", "x86_64") if identity or options.architectures == "universal" else (platform.machine(),)
            root = fresh_root(options.output_root)
            repo = Path(__file__).resolve().parents[1]
            commands = Commands(root, repo); scope["commands"] = commands
            tools = resolve_tools(commands)
            produced = produce(repo, root, architectures, commands, tools)
            result = package(repo, root, produced, commands, tools, identity) if options.package else {
                "binary": str(produced["binary"]), "receipt": str(produced["receipt"]), "status": "EXPERIMENTAL STATIC PREVIEW; runtime unqualified"}
            print(json.dumps(result))
    except BuildCanceled as error:
        parser.exit(128 + error.signum, "Parla native static preview canceled.\n")
    except ToolIncomplete as error:
        parser.exit(128 + error.signum if error.signum is not None else 1, str(error) + "; preserve owned stage.\n")
    except KeyboardInterrupt:
        parser.exit(130, "Parla native static preview canceled.\n")
    except (metadata.MetadataError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Parla native static preview failed: {error}. No native support qualified.\n")


if __name__ == "__main__":
    main()
