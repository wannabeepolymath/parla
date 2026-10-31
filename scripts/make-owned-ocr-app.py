#!/usr/bin/env python3
"""Package one prebuilt owned fixture. Never build, launch, install or register it."""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
import uuid


class PackageError(Exception):
    pass


class Canceled(PackageError):
    def __init__(self, signum):
        self.signum = signum
        super().__init__(f"canceled by signal {signum}; output retained")


def require(condition, message):
    if not condition:
        raise PackageError(message)


def write_json(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')


def inventory(root):
    """Record files and internal links only; refuse escapes and special files."""
    result = {}

    def visit(path):
        info = path.lstat()
        row = {'mode': stat.S_IMODE(info.st_mode)}
        if stat.S_ISLNK(info.st_mode):
            require(path.resolve(strict=True).is_relative_to(root), 'external input symlink')
            row['link'] = os.readlink(path)
        elif stat.S_ISREG(info.st_mode):
            row.update(size=info.st_size, sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        elif stat.S_ISDIR(info.st_mode):
            for child in sorted(path.iterdir()):
                visit(child)
        else:
            raise PackageError('special input file')
        result[str(path.relative_to(root))] = row

    require(not root.is_symlink(), 'input root symlink')
    visit(root)
    return result


class Commands:
    """Tools have owned process groups; cancellation waits for exit and pipe EOF."""
    def __init__(self, directory, timeout=30):
        self.directory, self.timeout = directory, timeout
        directory.mkdir()
        self.count = 0
        self.cancel_signal = None
        self.settled = True

    @contextlib.contextmanager
    def cancellation(self):
        previous = {s: signal.getsignal(s) for s in (signal.SIGINT, signal.SIGTERM)}

        def cancel(signum, frame):
            self.cancel_signal = self.cancel_signal or signum

        try:
            for s in previous:
                signal.signal(s, cancel)
            yield
        finally:
            for s, handler in previous.items():
                signal.signal(s, handler)

    def check_cancel(self):
        if self.cancel_signal:
            raise Canceled(self.cancel_signal)

    def run(self, argv):
        self.check_cancel()
        self.count += 1
        prefix = self.directory / f'{self.count:02d}'
        argv = [str(value) for value in argv]
        row = dict(argv=argv, started_ns=time.time_ns(), pid=None, raw_exit=None,
                   waited=False, io_closed=False, group_gone=False)
        process = None
        output = error = b''
        failure = None
        self.settled = False
        try:
            process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       start_new_session=True,
                                       env={**os.environ, 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'})
            row['pid'] = process.pid
            write_json(prefix.with_suffix('.running.json'), row)
            deadline = time.monotonic() + self.timeout
            while True:
                if self.cancel_signal or time.monotonic() >= deadline:
                    failure = Canceled(self.cancel_signal) if self.cancel_signal else PackageError('tool timed out')
                    break
                try:
                    output, error = process.communicate(timeout=0.1)
                    row['io_closed'] = True
                    break
                except subprocess.TimeoutExpired:
                    continue
        except BaseException as caught:
            failure = caught
        finally:
            if process is not None:
                if not row['io_closed']:
                    # Only this command's newly created group is signaled.
                    for sig in (signal.SIGTERM, signal.SIGKILL):
                        try:
                            os.killpg(process.pid, sig)
                        except ProcessLookupError:
                            pass
                        try:
                            output, error = process.communicate(timeout=3)
                            row['io_closed'] = True
                            break
                        except subprocess.TimeoutExpired:
                            continue
                row.update(raw_exit=process.poll(), waited=process.returncode is not None)
                try:
                    os.killpg(process.pid, 0)
                except ProcessLookupError:
                    row['group_gone'] = True
            else:
                row.update(waited=True, io_closed=True, group_gone=True)
            self.settled = row['waited'] and row['io_closed'] and row['group_gone']
            row.update(completed_ns=time.time_ns(), settled=self.settled)
            prefix.with_suffix('.stdout').write_bytes(output)
            prefix.with_suffix('.stderr').write_bytes(error)
            write_json(prefix.with_suffix('.json'), row)
            prefix.with_suffix('.running.json').unlink(missing_ok=True)
        require(self.settled, 'owned workers/IO pending; preserve all output and stop')
        if failure:
            raise failure
        self.check_cancel()
        require(row['raw_exit'] == 0, f'tool failed ({row["raw_exit"]}); see {prefix}.stderr')
        require(len(output) + len(error) <= 4 * 1024 * 1024, 'tool output exceeded inspection limit')
        return output.decode('utf-8', errors='strict')


TOOLS = {name: Path('/usr/bin') / name for name in ('otool', 'install_name_tool', 'codesign')}
PRODUCTS = {
    'ocr': dict(binary='parla-owned-ocr-check', app='Owned OCR.app', name='Owned OCR',
                identity='local.parla.owned-ocr-test.', extra_plist={}),
    'input-check': dict(binary='parla-owned-input-audio-check', app='Parla Input Check.app',
                        name='Parla Input Check', identity='local.parla.owned-input-check.',
                        extra_plist={'NSMicrophoneUsageDescription':
                            'Parla Input Check records up to 10 seconds from your microphone into memory when you press Start, so you can play it back. Nothing is saved, sent or transcribed.'}),
}
RPATH = '@executable_path/../Frameworks'
WHISPER = '@rpath/whisper.framework/Versions/Current/whisper'


def dependencies(commands, tools, binary):
    lines = commands.run([tools['otool'], '-L', binary]).splitlines()
    values = []
    section_count = None
    for line in lines:
        if line == f'{binary}:' or line in (f'{binary} (architecture arm64):', f'{binary} (architecture x86_64):'):
            require(section_count is None or section_count > 0, 'empty Mach-O architecture')
            section_count = 0
        else:
            require(section_count is not None and line.startswith('\t') and ' (compatibility version ' in line,
                    'unreadable Mach-O dependencies')
            values.append(line.strip().split(' (compatibility version ', 1)[0])
            section_count += 1
    require(section_count is not None and section_count > 0, 'missing Mach-O dependencies')
    return values


def rpaths(commands, tools, binary):
    lines = commands.run([tools['otool'], '-l', binary]).splitlines()
    result = []
    for i, line in enumerate(lines):
        if line.strip() == 'cmd LC_RPATH':
            require(i + 2 < len(lines) and lines[i + 2].strip().startswith('path '), 'unreadable rpath')
            result.append(lines[i + 2].strip()[5:].split(' (offset ', 1)[0])
    return result


def system_dependency(value):
    return value.startswith('/System/Library/') or value.startswith('/usr/lib/')


def package(artifact_root, binary, output, *, product='ocr', tools=None, commands_factory=Commands):
    selected = PRODUCTS[product]
    tools = TOOLS if tools is None else tools  # Tests inject inert tools in-process only.
    require(artifact_root.is_absolute() and artifact_root.resolve(strict=True) == artifact_root,
            'artifact root must be canonical')
    build = artifact_root / 'build'
    require(binary.is_absolute() and binary.resolve(strict=True) == binary and binary.is_file(), 'canonical prebuilt binary required')
    require(binary.name == selected['binary'] and binary.parent.name == 'debug'
            and binary.parent.parent.parent == build
            and binary.parent.parent.name in ('arm64-apple-macosx', 'x86_64-apple-macosx'),
            'binary must be exact dedicated debug product in owned build')
    require(os.access(binary, os.X_OK), 'binary is not executable')
    require(output.parent == artifact_root and not output.exists() and not output.is_symlink(),
            'output must be an exclusive new direct child of artifact root')
    source = {binary.name: inventory(binary)}
    output.mkdir(mode=0o700)  # Atomic collision refusal; nothing is ever removed.
    commands = commands_factory(output / 'commands')
    with commands.cancellation():
        try:
            commands.check_cancel()
            deps = dependencies(commands, tools, binary)
            require(all(system_dependency(d) or d == WHISPER for d in deps), 'unexpected executable dependency')
            needs_whisper = WHISPER in deps
            framework = binary.parent / 'whisper.framework'
            if needs_whisper:
                require(framework.is_dir() and not framework.is_symlink(), 'owned framework required')
                source[framework.name] = inventory(framework)
                library = framework / 'Versions/A/whisper'
                require(library.is_file() and not library.is_symlink(), 'framework Mach-O required')
                framework_deps = dependencies(commands, tools, library)
                require(WHISPER in framework_deps and all(d == WHISPER or system_dependency(d) for d in framework_deps),
                        'unexpected framework dependency')
                require(not rpaths(commands, tools, library), 'unexpected framework rpath')
            write_json(output / 'inputs.json', dict(binary=str(binary), source=source))
            original_rpaths = rpaths(commands, tools, binary)
            require(all(value in (RPATH, '@loader_path', '/usr/lib/swift', str(binary.parent))
                        or re.fullmatch(r'/Applications/Xcode\.app/Contents/Developer/Toolchains/XcodeDefault\.xctoolchain/usr/lib/swift(?:-[0-9.]+)?/macosx', value)
                        for value in original_rpaths), 'unexpected executable rpath')
            app = output / selected['app']
            mac = app / 'Contents/MacOS'
            mac.mkdir(parents=True)
            copied = mac / binary.name
            shutil.copy2(binary, copied)
            require(inventory(copied) == source[binary.name], 'binary copy mismatch')
            copied_framework = app / 'Contents/Frameworks/whisper.framework'
            if needs_whisper:
                copied_framework.parent.mkdir()
                # Runtime framework only: its embedded Metal code needs no external assets.
                shutil.copytree(framework, copied_framework, symlinks=True,
                                ignore=shutil.ignore_patterns('Headers', 'Modules'))
                runtime = {key: value for key, value in source[framework.name].items()
                           if not {'Headers', 'Modules'}.intersection(Path(key).parts)}
                require(inventory(copied_framework) == runtime, 'framework copy mismatch')
            identity = selected['identity'] + uuid.uuid4().hex
            plist = dict(CFBundleIdentifier=identity, CFBundleName=selected['name'],
                         CFBundleExecutable=binary.name, CFBundlePackageType='APPL',
                         CFBundleShortVersionString='1.0', CFBundleVersion='1', LSMinimumSystemVersion='13.3')
            plist.update(selected['extra_plist'])
            with (app / 'Contents/Info.plist').open('xb') as stream:
                plistlib.dump(plist, stream)
            if needs_whisper and RPATH not in original_rpaths:
                commands.run([tools['install_name_tool'], '-add_rpath', RPATH, copied])
            if needs_whisper:
                commands.run([tools['codesign'], '--force', '-s', '-', copied_framework])
            commands.run([tools['codesign'], '--force', '-s', '-', '--identifier', identity, app])
            if needs_whisper:
                commands.run([tools['codesign'], '--verify', '--all-architectures', '--strict', copied_framework])
            commands.run([tools['codesign'], '--verify', '--all-architectures', '--deep', '--strict', app])
            commands.run([tools['codesign'], '-d', '--verbose=4', app])
            # codesign writes display details to stderr, retained in command logs.
            require(dependencies(commands, tools, copied) == deps, 'packaged executable dependencies changed')
            expected_rpaths = original_rpaths + ([RPATH] if needs_whisper and RPATH not in original_rpaths else [])
            require(rpaths(commands, tools, copied) == expected_rpaths, 'packaged executable rpaths mismatch')
            if needs_whisper:
                require(dependencies(commands, tools, copied_framework / 'Versions/A/whisper') == framework_deps,
                        'packaged framework dependencies changed')
                require(not rpaths(commands, tools, copied_framework / 'Versions/A/whisper'), 'packaged framework rpath changed')
            require(plistlib.loads((app / 'Contents/Info.plist').read_bytes()) == plist, 'plist mismatch')
            require(inventory(binary) == source[binary.name], 'source binary changed')
            if needs_whisper:
                require(inventory(framework) == source[framework.name], 'source framework changed')
            commands.check_cancel()
            write_json(output / 'inventory.json', dict(source=source, app=inventory(app), identity=identity,
                                                       binary=str(binary), app_path=str(app), workers_settled=commands.settled))
            return app
        except BaseException as error:
            write_json(output / 'failure.json', dict(error=type(error).__name__, detail=str(error), workers_settled=commands.settled))
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact-root', type=Path, required=True)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        print(package(args.artifact_root, args.binary, args.output))
    except Canceled as error:
        parser.exit(128 + error.signum, str(error) + '\n')
    except (PackageError, OSError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
