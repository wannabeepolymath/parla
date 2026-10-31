"""Inert packaging checks: no Mach-O edits, signing, app execution or UI."""
import contextlib
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

MODULE = Path(__file__).resolve().parents[1] / 'make-owned-ocr-app.py'
spec = importlib.util.spec_from_file_location('owned_packager', MODULE)
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


class FakeCommands:
    def __init__(self, directory):
        directory.mkdir()
        self.calls = []
        self.settled = True
        self.cancel_signal = None
        self.fail_at = None
        self.rpath_present = False
        self.extra_dependency = None

    @contextlib.contextmanager
    def cancellation(self):
        yield

    def check_cancel(self):
        if self.cancel_signal:
            raise p.Canceled(self.cancel_signal)

    def run(self, argv):
        self.calls.append([str(v) for v in argv])
        if self.fail_at == len(self.calls):
            raise p.PackageError('injected tool failure')
        tool, *args = self.calls[-1]
        if tool == 'otool' and args[0] == '-L':
            deps = ['/usr/lib/libSystem.B.dylib']
            if self.whisper:
                deps.append(p.WHISPER)
            if self.extra_dependency:
                deps.append(self.extra_dependency)
            return args[1] + ':\n' + ''.join('\t' + d + ' (compatibility version 1.0.0, current version 1.0.0)\n' for d in deps)
        if tool == 'otool' and args[0] == '-l':
            is_executable = Path(args[1]).name in ('parla-owned-ocr-check', 'parla-owned-input-audio-check')
            if is_executable and self.rpath_present:
                return f'Load command 0\n cmd LC_RPATH\n cmdsize 48\n path {p.RPATH} (offset 12)\n'
            return 'Load command 0\n cmd LC_UUID\n'
        if tool == 'install_name_tool':
            self.rpath_present = True
        return ''


class PackagingTests(unittest.TestCase):
    def setUp(self):
        # Only this test's TemporaryDirectory is cleaned by its owner.
        self.temp = tempfile.TemporaryDirectory(prefix='owned-ocr-fake-')
        ledger = os.environ.get('OWNED_OCR_FAKE_LEDGER')

        def finish():
            if ledger:
                archive = Path(ledger).parent / 'fake-test-artifacts' / Path(self.temp.name).name
                shutil.copytree(self.temp.name, archive, symlinks=True)
            self.temp.cleanup()

        self.addCleanup(finish)
        if ledger:
            with Path(ledger).open('a') as stream:
                stream.write(json.dumps({'test': self.id(), 'temporary_directory': self.temp.name, 'cleanup': 'TemporaryDirectory owner only'}) + '\n')
        self.root = Path(self.temp.name).resolve()
        self.binary = self.root / 'build/arm64-apple-macosx/debug/parla-owned-ocr-check'
        self.binary.parent.mkdir(parents=True)
        self.binary.write_bytes(b'inert dedicated binary\n')
        self.binary.chmod(0o755)
        self.framework = self.binary.parent / 'whisper.framework'
        (self.framework / 'Versions/A/Resources').mkdir(parents=True)
        (self.framework / 'Versions/A/whisper').write_bytes(b'inert library\n')
        (self.framework / 'Versions/A/Resources/Info.plist').write_bytes(b'inert framework resource\n')
        (self.framework / 'Versions/A/Headers').mkdir()
        (self.framework / 'Versions/A/Headers/unused.h').write_bytes(b'not a runtime resource')
        (self.framework / 'Headers').symlink_to('Versions/Current/Headers')
        (self.framework / 'Versions/Current').symlink_to('A')
        (self.framework / 'whisper').symlink_to('Versions/Current/whisper')
        (self.framework / 'Resources').symlink_to('Versions/Current/Resources')
        self.output = self.root / 'candidate'
        self.options = dict(whisper=True)
        self.commands = None
        self.before = (p.inventory(self.binary), p.inventory(self.framework))

    def factory(self, directory):
        self.commands = FakeCommands(directory)
        for key, value in self.options.items():
            setattr(self.commands, key, value)
        return self.commands

    def package(self, product='ocr'):
        return p.package(self.root, self.binary, self.output,
                         product=product, tools={name: name for name in p.TOOLS}, commands_factory=self.factory)

    def assert_sources_unchanged(self):
        self.assertEqual(self.before, (p.inventory(self.binary), p.inventory(self.framework)))

    def test_required_framework_resources_copy_and_mutation_arguments(self):
        app = self.package()
        copied = app / 'Contents/MacOS' / self.binary.name
        framework = app / 'Contents/Frameworks/whisper.framework'
        self.assertEqual((framework / 'Resources/Info.plist').read_bytes(), b'inert framework resource\n')
        self.assertTrue((framework / 'Versions/Current').is_symlink())
        self.assertFalse((framework / 'Headers').exists())
        self.assertFalse((framework / 'Versions/A/Headers').exists())
        receipt = json.loads((self.output / 'inventory.json').read_text())
        self.assertEqual(receipt['app'], p.inventory(app))
        identity = receipt['identity']
        mutations = [a for a in self.commands.calls if a[0] != 'otool' and '--verify' not in a and '-d' not in a]
        self.assertEqual(mutations, [
            ['install_name_tool', '-add_rpath', p.RPATH, str(copied)],
            ['codesign', '--force', '-s', '-', str(framework)],
            ['codesign', '--force', '-s', '-', '--identifier', identity, str(app)]])
        self.assertIn(['codesign', '--verify', '--all-architectures', '--deep', '--strict', str(app)], self.commands.calls)
        self.assert_sources_unchanged()

    def test_no_framework_is_copied_when_not_linked(self):
        self.options['whisper'] = False
        app = self.package()
        self.assertFalse((app / 'Contents/Frameworks').exists())
        self.assertFalse(any(c[0] == 'install_name_tool' for c in self.commands.calls))
        self.assert_sources_unchanged()

    def test_existing_rpath_does_not_get_added_twice(self):
        self.options['rpath_present'] = True
        self.package()
        self.assertFalse(any(c[0] == 'install_name_tool' for c in self.commands.calls))

    def test_existing_output_is_preserved_without_tools(self):
        self.output.mkdir()
        (self.output / 'keep').write_bytes(b'prior output')
        before = p.inventory(self.output)
        with self.assertRaises(p.PackageError):
            self.package()
        self.assertEqual(before, p.inventory(self.output))
        self.assertIsNone(self.commands)

    def test_dangling_output_symlink_is_preserved(self):
        self.output.symlink_to(self.root / 'absent')
        with self.assertRaises(p.PackageError):
            self.package()
        self.assertTrue(self.output.is_symlink())
        self.assertIsNone(self.commands)

    def test_wrong_product_is_rejected_before_tools(self):
        other = self.binary.with_name('Parla')
        other.write_bytes(self.binary.read_bytes())
        other.chmod(0o755)
        self.binary = other
        with self.assertRaises(p.PackageError):
            self.package()
        self.assertFalse(self.output.exists())

    def test_external_framework_symlink_refuses_before_mutation(self):
        external = self.root / 'private-file'
        external.write_bytes(b'do not copy')
        (self.framework / 'escape').symlink_to(external)
        with self.assertRaisesRegex(p.PackageError, 'external input symlink'):
            self.package()
        self.assertFalse(any(c[0] != 'otool' for c in self.commands.calls))

    def test_unexpected_dependency_refuses_before_copy(self):
        self.options['extra_dependency'] = '/unowned/library.dylib'
        with self.assertRaisesRegex(p.PackageError, 'unexpected executable dependency'):
            self.package()
        self.assertFalse((self.output / 'Owned OCR.app').exists())
        self.assert_sources_unchanged()

    def test_tool_failure_preserves_partial_output_and_sources(self):
        self.options['fail_at'] = 6  # framework signing, after binary copy/rpath
        with self.assertRaisesRegex(p.PackageError, 'injected tool failure'):
            self.package()
        self.assertEqual(len(self.commands.calls), 6)
        self.assertTrue((self.output / 'Owned OCR.app/Contents/MacOS' / self.binary.name).exists())
        self.assertTrue((self.output / 'failure.json').exists())
        self.assertFalse((self.output / 'inventory.json').exists())
        self.assert_sources_unchanged()
        previous = p.inventory(self.output)
        with self.assertRaises(p.PackageError):
            self.package()
        self.assertEqual(previous, p.inventory(self.output))

    def test_cancellation_before_tools_is_propagated(self):
        self.options['cancel_signal'] = signal.SIGTERM
        with self.assertRaises(p.Canceled) as caught:
            self.package()
        self.assertEqual(caught.exception.signum, signal.SIGTERM)
        self.assertEqual(self.commands.calls, [])
        self.assert_sources_unchanged()

    def test_source_change_is_detected(self):
        factory = self.factory

        def changed(directory):
            commands = factory(directory)
            original = commands.run

            def run(argv):
                result = original(argv)
                if str(argv[0]) == 'codesign' and '--force' in argv:
                    self.binary.write_bytes(b'changed input')
                return result
            commands.run = run
            return commands

        self.factory = changed
        with self.assertRaisesRegex(p.PackageError, 'source binary changed'):
            self.package()
        self.assertFalse((self.output / 'inventory.json').exists())


    def input_binary(self):
        binary = self.binary.with_name('parla-owned-input-audio-check')
        binary.write_bytes(b'inert input-check binary\n')
        binary.chmod(0o755)
        return binary

    def test_ocr_default_still_rejects_input_binary_before_tools(self):
        self.binary = self.input_binary()
        with self.assertRaisesRegex(p.PackageError, 'binary must be exact dedicated debug product'):
            self.package()
        self.assertIsNone(self.commands)
        self.assertFalse(self.output.exists())

    def test_ocr_cli_still_refuses_input_binary_without_product_option(self):
        binary = self.input_binary()
        argv = [str(MODULE), '--artifact-root', str(self.root), '--binary', str(binary), '--output', str(self.output)]
        with mock.patch.object(sys, 'argv', argv), mock.patch.object(p, 'Commands') as commands:
            with self.assertRaises(SystemExit) as caught:
                p.main()
        self.assertEqual(caught.exception.code, 1)
        commands.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_ocr_default_plist_bytes_are_unchanged_and_have_no_mic_key(self):
        with mock.patch.object(p.uuid, 'uuid4', return_value=mock.Mock(hex='0' * 32)):
            app = self.package()
        expected = dict(CFBundleIdentifier='local.parla.owned-ocr-test.' + '0' * 32,
                        CFBundleName='Owned OCR', CFBundleExecutable='parla-owned-ocr-check',
                        CFBundlePackageType='APPL', CFBundleShortVersionString='1.0',
                        CFBundleVersion='1', LSMinimumSystemVersion='13.3')
        self.assertEqual((app / 'Contents/Info.plist').read_bytes(), plistlib.dumps(expected))
        self.assertNotIn('NSMicrophoneUsageDescription', plistlib.loads((app / 'Contents/Info.plist').read_bytes()))

    def test_input_product_has_exact_identity_plist_and_inert_signing_arguments(self):
        self.binary = self.input_binary()
        with mock.patch.object(p.uuid, 'uuid4', return_value=mock.Mock(hex='1' * 32)):
            app = self.package('input-check')
        self.assertEqual(app.name, 'Parla Input Check.app')
        expected = dict(CFBundleIdentifier='local.parla.owned-input-check.' + '1' * 32,
                        CFBundleName='Parla Input Check', CFBundleExecutable='parla-owned-input-audio-check',
                        CFBundlePackageType='APPL', CFBundleShortVersionString='1.0',
                        CFBundleVersion='1', LSMinimumSystemVersion='13.3',
                        NSMicrophoneUsageDescription='Parla Input Check records up to 10 seconds from your microphone into memory when you press Start, so you can play it back. Nothing is saved, sent or transcribed.')
        self.assertEqual((app / 'Contents/Info.plist').read_bytes(), plistlib.dumps(expected))
        self.assertTrue((app / 'Contents/Frameworks/whisper.framework/Resources/Info.plist').exists())
        self.assertTrue(all(call[0] in ('otool', 'codesign', 'install_name_tool') for call in self.commands.calls))
        self.assertFalse(any('--options' in call or '--entitlements' in call for call in self.commands.calls))

    def test_unknown_product_is_rejected_without_output_or_tools(self):
        with self.assertRaises(KeyError):
            self.package('arbitrary')
        self.assertFalse(self.output.exists())
        self.assertIsNone(self.commands)

    def test_input_product_refuses_ocr_binary(self):
        with self.assertRaisesRegex(p.PackageError, 'binary must be exact dedicated debug product'):
            self.package('input-check')
        self.assertFalse(self.output.exists())
        self.assertIsNone(self.commands)

    def test_input_product_failure_and_cancellation_preserve_owned_sources(self):
        self.binary = self.input_binary()
        original = p.inventory(self.binary)
        self.options['fail_at'] = 6
        with self.assertRaises(p.PackageError):
            self.package('input-check')
        self.assertEqual(p.inventory(self.binary), original)
        self.assertTrue((self.output / 'failure.json').exists())
        self.output = self.root / 'canceled-input'
        self.options = dict(whisper=False, cancel_signal=signal.SIGTERM)
        with self.assertRaises(p.Canceled):
            self.package('input-check')
        self.assertEqual(self.commands.calls, [])
        self.assertEqual(p.inventory(self.binary), original)

    def test_input_cli_pins_product_with_absolute_sibling_import(self):
        path = MODULE.with_name('make-owned-input-audio-app.py')
        spec = importlib.util.spec_from_file_location('input_cli_test', path)
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        self.assertTrue(cli.MODULE.is_absolute())
        self.assertEqual(cli.MODULE, MODULE)
        binary = self.input_binary()
        argv = [str(path), '--artifact-root', str(self.root), '--binary', str(binary), '--output', str(self.output)]
        with mock.patch.object(sys, 'argv', argv), mock.patch.object(cli.packager, 'package', return_value=Path('/inert/app')) as package, mock.patch('builtins.print'):
            cli.main()
        package.assert_called_once_with(self.root, binary, self.output, product='input-check')
        with mock.patch.object(sys, 'argv', argv + ['--product', 'ocr']), mock.patch.object(cli.packager, 'package') as package:
            with self.assertRaises(SystemExit) as caught:
                cli.main()
        self.assertEqual(caught.exception.code, 2)
        package.assert_not_called()


class InspectionTests(unittest.TestCase):
    def test_universal_otool_format_keeps_both_architectures(self):
        binary = Path('/owned/whisper')
        output = ''.join(f'{binary} (architecture {arch}):\n\t{p.WHISPER} (compatibility version 0.0.0, current version 0.0.0)\n'
                         for arch in ('x86_64', 'arm64'))
        commands = mock.Mock()
        commands.run.return_value = output
        self.assertEqual(p.dependencies(commands, {'otool': 'otool'}, binary), [p.WHISPER, p.WHISPER])
        commands.run.assert_called_once_with(['otool', '-L', binary])

    def test_empty_or_unknown_architecture_refuses(self):
        commands = mock.Mock()
        for output in ('', '/owned/lib (architecture unknown):\n',
                       '/owned/lib (architecture arm64):\n/owned/lib (architecture x86_64):\n'):
            commands.run.return_value = output
            with self.assertRaises(p.PackageError):
                p.dependencies(commands, {'otool': 'otool'}, Path('/owned/lib'))


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='owned-ocr-command-')
        ledger = os.environ.get('OWNED_OCR_FAKE_LEDGER')

        def finish():
            if ledger:
                archive = Path(ledger).parent / 'fake-test-artifacts' / Path(self.temp.name).name
                shutil.copytree(self.temp.name, archive, symlinks=True)
            self.temp.cleanup()

        self.addCleanup(finish)
        if ledger:
            with Path(ledger).open('a') as stream:
                stream.write(json.dumps({'test': self.id(), 'temporary_directory': self.temp.name, 'cleanup': 'TemporaryDirectory owner only'}) + '\n')
        self.root = Path(self.temp.name)

    def test_exact_argv_and_waited_raw_failure(self):
        commands = p.Commands(self.root / 'commands')
        argv = [sys.executable, '-B', '-c', 'import sys; print(sys.argv[1:]); sys.exit(7)', 'space $ argument']
        with self.assertRaisesRegex(p.PackageError, 'tool failed \\(7\\)'):
            commands.run(argv)
        record = json.loads((commands.directory / '01.json').read_text())
        self.assertEqual(record['argv'], argv)
        self.assertEqual(record['raw_exit'], 7)
        self.assertTrue(record['waited'] and record['io_closed'] and record['group_gone'])
        self.assertIn('space $ argument', (commands.directory / '01.stdout').read_text())

    def test_timeout_joins_owned_child(self):
        commands = p.Commands(self.root / 'commands', timeout=0.1)
        with self.assertRaisesRegex(p.PackageError, 'timed out'):
            commands.run([sys.executable, '-B', '-c', 'import time; time.sleep(30)'])
        record = json.loads((commands.directory / '01.json').read_text())
        self.assertEqual(record['raw_exit'], -signal.SIGTERM)
        self.assertTrue(record['settled'])

    def test_real_signal_cancellation_during_spawn_joins_child(self):
        commands = p.Commands(self.root / 'commands')
        original = subprocess.Popen

        def spawn(*args, **kwargs):
            child = original(*args, **kwargs)
            os.kill(os.getpid(), signal.SIGTERM)
            return child

        with commands.cancellation(), mock.patch.object(p.subprocess, 'Popen', side_effect=spawn):
            with self.assertRaises(p.Canceled) as caught:
                commands.run([sys.executable, '-B', '-c', 'import time; time.sleep(30)'])
        self.assertEqual(caught.exception.signum, signal.SIGTERM)
        record = json.loads((commands.directory / '01.json').read_text())
        self.assertEqual(record['raw_exit'], -signal.SIGTERM)
        self.assertTrue(record['settled'])


if __name__ == '__main__':
    unittest.main()
