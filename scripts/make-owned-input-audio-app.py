#!/usr/bin/env python3
"""Package only the prebuilt owned input/audio check; never build or launch."""
import argparse
import importlib.util
from pathlib import Path

# Absolute sibling loading also works with python -I. No sys.path mutation.
MODULE = Path(__file__).resolve().with_name('make-owned-ocr-app.py')
spec = importlib.util.spec_from_file_location('owned_input_packager', MODULE)
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact-root', type=Path, required=True)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        print(packager.package(args.artifact_root, args.binary, args.output, product='input-check'))
    except packager.Canceled as error:
        parser.exit(128 + error.signum, str(error) + '\n')
    except (packager.PackageError, OSError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
