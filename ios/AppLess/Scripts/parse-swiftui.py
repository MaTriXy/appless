#!/usr/bin/env python3
"""Syntax-check the SwiftUI half with its `#if canImport(SwiftUI)` guard FORCED ON.

Linux has no SwiftUI SDK, so `canImport(SwiftUI)` is false and the compiler
skips every guarded body - which makes a green `swift build` on Linux say
nothing at all about the shell's syntax. This script copies each file with the
OUTER guard removed and runs `swiftc -parse` over the copies, so a typo in a
view is caught on the cheap CI tier too.

WHAT A GREEN RUN PROVES, EXACTLY
--------------------------------
`swiftc -parse` builds a syntax tree and stops. It therefore catches:

  * malformed expressions, unbalanced braces/parens, bad `switch` bodies;
  * syntax errors inside INACTIVE `#if` branches too - Swift requires those to
    parse even when their condition is false, so the `#if os(iOS)` and
    `#if canImport(MapKit)` arms are covered without a second pass.

It does NOT catch anything a type checker would: an unknown symbol, a wrong
argument label, a `ViewBuilder` that does not compose, a modifier applied to
the wrong type. Only macOS CI
(`xcodebuild -scheme AppLessUI -destination 'generic/platform=iOS'`) proves the
SwiftUI actually compiles. Do NOT report a green run here as "AppLessUI
compiles" or "type-checks".

The complementary Linux checks are also TEXT-level, and live in
`Tests/AppLessCoreTests/RendererSourceGateTests.swift`: which components are
registered and under which contract name, which props a body reads, which icon
names it hard-codes, and the same guard-shape invariant this script relies on.

    python3 ios/AppLess/Scripts/parse-swiftui.py [--swiftc /path/to/swiftc]
    python3 ios/AppLess/Scripts/parse-swiftui.py --check-only   # no toolchain
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


def significant_lines(text):
    """(line number, text) for every line that is neither blank nor a comment."""
    out = []
    for number, raw in enumerate(text.split("\n"), start=1):
        line = raw.strip()
        if line and not line.startswith("//"):
            out.append((number, line))
    return out


def check_guard_shape(text, path):
    """Fail unless the file is ONE outermost `#if canImport(SwiftUI)` block.

    `strip_guard` deletes the first line equal to the guard and the last line
    equal to `#endif`. That rewrite is only sound if those two really are the
    outer pair; otherwise the script would parse a file whose structure differs
    from the one it reports on - and, worse, real code could be sitting outside
    the guard and getting compiled into the Linux build. Returns the 1-based
    line numbers of the outer pair.
    """
    lines = significant_lines(text)
    if not lines:
        raise SystemExit(f"{path}: file has no code")
    if lines[0][1] != GUARD:
        raise SystemExit(
            f"{path}:{lines[0][0]}: first non-comment line must be `{GUARD}`, "
            f"found `{lines[0][1]}`"
        )
    if lines[-1][1] != "#endif":
        raise SystemExit(
            f"{path}:{lines[-1][0]}: last non-comment line must be `#endif`, "
            f"found `{lines[-1][1]}`"
        )

    depth = 0
    for index, (number, line) in enumerate(lines):
        if line.startswith("#if"):
            depth += 1
        elif line == "#endif":
            depth -= 1
        if depth < 0:
            raise SystemExit(f"{path}:{number}: unbalanced `#endif`")
        # Anywhere before the final line the outer guard must still be open.
        if depth == 0 and index != len(lines) - 1:
            raise SystemExit(
                f"{path}:{number}: code after this line escapes the `{GUARD}` guard, "
                "so it would be compiled on Linux"
            )
    if depth != 0:
        raise SystemExit(f"{path}: {depth} unclosed `#if`")
    return lines[0][0], lines[-1][0]


def strip_guard(text, path):
    opening, closing = check_guard_shape(text, path)
    return "\n".join(
        line
        for n, line in enumerate(text.split("\n"), start=1)
        if n not in (opening, closing)
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--swiftc", default="swiftc")
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="verify the guard shape only; do not invoke swiftc",
    )
    args = parser.parse_args()

    sources = sorted(
        path
        for directory in DIRECTORIES
        if directory.is_dir()
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

        if args.check_only:
            print(f"guard shape OK for {len(staged)} SwiftUI files (swiftc not run)")
            return 0

        result = subprocess.run(
            [args.swiftc, "-parse", *staged], capture_output=True, text=True
        )
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        # `swiftc -parse` can exit 0 while still emitting warnings, so treat
        # any diagnostic as a failure.
        #
        # Honesty note: no input has been found that makes `-parse` emit a
        # WARNING - even a `#warning("…")` directive is silent at this stage,
        # because it is raised later - so this branch is defensive and has only
        # been exercised through the error path. It is here so that a future
        # toolchain which does warn at parse time cannot slip past the gate.
        diagnostics = [
            line
            for line in (result.stdout + result.stderr).split("\n")
            if ": warning:" in line or ": error:" in line
        ]
        if diagnostics:
            print(
                f"parse gate: {len(diagnostics)} diagnostic(s) - treating as failure",
                file=sys.stderr,
            )
            return result.returncode or 1
        print(
            f"parsed {len(staged)} SwiftUI files with guards forced on "
            "(SYNTAX only - NOT a type check)"
        )
        return result.returncode
    finally:
        shutil.rmtree(staging, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
