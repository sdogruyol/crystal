#!/usr/bin/env python3
"""Every mutation proof's patch has to still match the line it names.

    python3 bench/mutation_anchors.py            # check
    python3 bench/mutation_anchors.py --list     # print every anchor it found

A failure proof works by breaking the library and requiring the exercise to
notice. When the library is rewritten underneath it, the patch stops matching,
and a patch that matches nothing breaks nothing: the exercise passes, and the
proof reads as a pass while proving nothing at all. The drivers each catch this
at run time with `cmp -s`, but only for the platform and the exercise that ran,
and only after the minutes it takes to build and run them. This reads the
anchors directly, in a second, for all of them.

It checks two things per anchor:

  1. The pattern matches its target file at least once, under this platform's
     own sed. That is the rot the drivers catch late.
  2. The pattern avoids the BRE escapes GNU and BSD sed disagree about. `\\?`,
     `\\+` and `\\|` are quantifiers and alternation to GNU and literal
     characters to BSD, so a pattern using one matches on the machine it was
     written on and silently matches nothing on the other. Both proofs lost to
     this in September 2026 were written and verified on macOS and matched
     nothing in Linux CI.

Anchors are found by reading each driver's `prove_fails`-style calls rather
than by running them, so a driver that needs a network, a container or another
architecture is still checked here.
"""

import glob
import os
import re
import shlex
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The escapes whose meaning changes between GNU and BSD sed, and what to write
# instead. A bracket expression means the same thing to both.
UNPORTABLE = {
    r"\?": "[?]",
    r"\+": "[+]",
    r"\|": "[|]",
}

# Drivers name their targets by basename and resolve them against their own
# library root, so the check does the same rather than parsing shell variables.
SEARCH_ROOTS = ("src/std", "src/iyi", "src/compiler", "bench", "samples/iyi")


def driver_calls(text):
    """Yield the argument list of every proof call in one driver."""
    # Join continuations first: these calls are written across several lines.
    joined = re.sub(r"\\\n\s*", " ", text)
    for line in joined.splitlines():
        stripped = line.strip()
        if not re.match(r"^prove_fail\w*\s+\S", stripped):
            continue
        if stripped.endswith("() {"):
            continue
        try:
            yield shlex.split(stripped)
        except ValueError:
            # An unbalanced quote is the shell's problem to report, not ours.
            continue


def resolve(name):
    for root in SEARCH_ROOTS:
        candidate = os.path.join(REPO, root, name)
        if os.path.isfile(candidate):
            return candidate
    matches = glob.glob(os.path.join(REPO, "src", "**", name), recursive=True)
    return matches[0] if matches else None


def scripts_in(args):
    """The patch programs in one call: sed scripts, or an awk program.

    The drivers write these four shapes, and each appears somewhere different
    in the argument list, so every argument is examined rather than a position
    trusted:

        s/a/b/                        a plain substitution
        1,100s/a/b/                   one addressed to a line range
        /from/{n;s/a/b/;}             one addressed to a context, a line on
        { if ($0 ~ /a/) ... print }   an awk program rewriting a whole line
    """
    found = []
    for arg in args:
        text = arg.lstrip()
        if text.startswith("{") and ("$0" in text or "sub(" in text):
            found.append(("awk", arg))
        elif re.match(
            r"^(?:\d+(?:,(?:\+?\d+))?"
            r"|/(?:[^/\\]|\\.)*/(?:,(?:\+?\d+|/(?:[^/\\]|\\.)*/))?)?"
            r"\{?\s*(?:\w+;\s*)*s[/|,]",
            text,
        ):
            found.append(("sed", arg))
    return found


def driver_roots(text):
    """Per proof function, the library paths and default file it reads.

    A driver patches either the prelude in `src/iyi` or a module in `src/std`,
    and names are shared across them (`io.iyi`, `float.iyi`), so resolving by
    basename alone picks the wrong file and reports a live anchor as dead.
    A driver may also define one proof function per file it patches, as the
    capsule driver does for `capsule.iyi` and `webtransport.iyi`, so the
    default is keyed by the function the call actually uses rather than taken
    from whichever definition happens to come first.
    """
    table = {}
    for match in re.finditer(r"(prove_fail\w*)\(\)\s*\{(.*?)\n\}", text, re.S):
        body = match.group(2)
        roots, named = [], None
        pattern = r"\$REPO/(src/[\w/]+?)/(?:([\w.$]*?[\w.]+\.iyi)|[.])"
        for path in re.finditer(pattern, body):
            if path.group(1) not in roots:
                roots.append(path.group(1))
        # The file the patch command reads, not the first path in the body:
        # a function that copies one library before patching another names
        # both, and only the patched one is what the anchors are about.
        for line in body.splitlines():
            if not re.search(r"^\s*(sed|awk)\b", line):
                continue
            found = re.search(pattern, line)
            if found and found.group(2) and "$" not in found.group(2):
                named = found.group(2)
                break
            if found and re.match(r"^\s*awk\b", line) and "src/iyi" in roots:
                named = "prelude.iyi"
                break
        if named is None:
            # `local file="${5:-prelude.iyi}"`: the driver states its own
            # default in the shell rather than in the path it patches.
            stated = re.search(r"\$\{\d+:-([\w.]+\.iyi)\}", body)
            if stated:
                named = stated.group(1)
        table[match.group(1)] = (roots, named)
    return table


def resolve(name, roots):
    for root in list(roots) + list(SEARCH_ROOTS):
        candidate = os.path.join(REPO, root, name)
        if os.path.isfile(candidate):
            return candidate
    return None


def anchors():
    """Every (driver, target, path, kind, script) this repository asserts.

    A call this cannot read is yielded too, with no script, because a checker
    that quietly skips what it does not understand reports a clean run over
    the anchors it happened to parse. That is the same failure as a patch that
    matches nothing, one level up.
    """
    for driver in sorted(glob.glob(os.path.join(REPO, "bench", "*.sh"))):
        text = open(driver, errors="ignore").read()
        table = driver_roots(text)
        for args in driver_calls(text):
            roots, fallback = table.get(args[0], ([], None))
            name = next((a for a in args if a.endswith(".iyi")), None) or fallback
            if name is None:
                # Some drivers take the module by bare name, as `channel`, and
                # add the extension themselves.
                name = next(
                    (
                        a + ".iyi"
                        for a in args
                        if re.fullmatch(r"[a-z][a-z0-9_]*", a)
                        and resolve(a + ".iyi", roots)
                    ),
                    None,
                )
            found = scripts_in(args)
            if not found or name is None:
                yield os.path.relpath(driver, REPO), name, None, None, None
                continue
            path = resolve(os.path.basename(name), roots)
            for kind, script in found:
                yield os.path.relpath(driver, REPO), name, path, kind, script


def patches(path, kind, script):
    """True when this patch program changes the file, using the real tool."""
    original = open(path, "rb").read()
    argv = ["sed", "-e", script] if kind == "sed" else ["awk", script]
    result = subprocess.run(argv, input=original, capture_output=True)
    if result.returncode != 0:
        return None
    return result.stdout != original


def main():
    listing = "--list" in sys.argv
    checked = failures = 0

    for driver, target, path, kind, script in anchors():
        if script is None:
            print(f"UNREADABLE  {driver}")
            print(
                "  A proof call here names no patch program this checker can "
                "read, so nothing about it is being checked. Teach "
                "bench/mutation_anchors.py its shape rather than leaving it "
                "outside the count."
            )
            failures += 1
            continue

        checked += 1
        if listing:
            print(f"{driver}  {target}  {kind}  {script}")

        unportable = next((b for b in UNPORTABLE if kind == "sed" and b in script), None)
        if unportable:
            print(f"UNPORTABLE  {driver}")
            print(f"  {script}")
            print(
                f"  `{unportable}` means one thing to GNU sed and another to BSD "
                f"sed, so this matches on one platform and nothing on the other. "
                f"Write `{UNPORTABLE[unportable]}`."
            )
            failures += 1
            continue

        if path is None:
            print(f"MISSING     {driver}: no file named {target} under src/")
            failures += 1
            continue

        changed = patches(path, kind, script)
        if changed is None:
            print(f"REJECTED    {driver}: {kind} would not accept {script}")
            failures += 1
        elif not changed:
            print(f"MATCHES NOTHING  {driver}")
            print(f"  {script}")
            print(f"  against {os.path.relpath(path, REPO)}")
            print(
                "  The line this proof patches is gone, so the proof breaks "
                "nothing and the exercise passes without testing anything. "
                "Point it at the code that answers this question now."
            )
            failures += 1

    if failures:
        print()
        print(f"{failures} mutation anchors do not patch what they name.")
        return 1

    print(f"all {checked} mutation anchors still patch the code they name")
    return 0


if __name__ == "__main__":
    sys.exit(main())
