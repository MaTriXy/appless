#!/usr/bin/env python3
"""Syntax-check the SwiftUI half with its `#if canImport(SwiftUI)` guard FORCED ON.

Linux has no SwiftUI SDK, so `canImport(SwiftUI)` is false and the compiler
skips every guarded body - which makes a green `swift build` on Linux say
nothing at all about the shell's syntax. This script copies each file with the
OUTER guard removed and runs `swiftc -parse` over the copies, so a typo in a
view is caught on the cheap CI tier too.

It is a SYNTAX check, not a type check: only macOS CI
(`xcodebuild -scheme AppLessUI -destination 'generic/platform=iOS'`) proves the
SwiftUI actually compiles.

    python3 ios/AppLess/Scripts/parse-swiftui.py [--swiftc /path/to/swiftc]
"""

import argparse
import pathlib
import shutil
import subprocess
import sys
import tempfile

GUARD = "#if canImport(SwiftUI)"
ROOT = pathlib.Path(__file__).resolve().parents[1]
DIRECTORIES = [ROOT / "Sources" / "AppLessUI", ROOT / "Tests" / "AppLessUITests"]


def strip_guard(text: str, path: pathlib.Path) -> str:
    lines = text.split("\n")
    try:
        opening = next(i for i, line in enumerate(lines) if line.strip() == GUARD)
    except StopIteration:
        raise SystemExit(f"{path}: missing `{GUARD}` guard")
    try:
        closing = len(lines) - 1 - next(
            i for i, line in enumerate(reversed(lines)) if line.strip() == "#endif"
        )
    except StopIteration:
        raise SystemExit(f"{path}: guard is never closed")
    return "\n".join(line for n, line in enumerate(lines) if n not in (opening, closing))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--swiftc", default="swiftc")
    args = parser.parse_args()

    sources = sorted(
        path for directory in DIRECTORIES if directory.is_dir()
        for path in directory.glob("*.swift")
    )
    if not sources:
        raise SystemExit("no SwiftUI sources found")

    staging = pathlib.Path(tempfile.mkdtemp(prefix="appless-parse-"))
    try:
        staged = []
        for path in sources:
            destination = staging / path.name
            destination.write_text(strip_guard(path.read_text(), path))
            staged.append(str(destination))
        result = subprocess.run(
            [args.swiftc, "-parse", *staged], capture_output=True, text=True
        )
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        print(f"parsed {len(staged)} SwiftUI files with guards forced on")
        return result.returncode
    finally:
        shutil.rmtree(staging, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
