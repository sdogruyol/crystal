#!/usr/bin/env bash
# Standard YAML 1.2 Core Schema library exercise driver.
# Runs the YAML exercise in plain and release mode, checks every section
# reported, proves failure against invalid YAML inputs (tab indentation,
# cyclic anchors, billion-laughs alias bomb), and proves checks can fail
# by patching copies of std/yaml.iyi.
#
#     bash bench/std_yaml_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across:
#   * Tab indentation forbidden in YAML (immediate syntax error)
#   * Anchor cycles refused (detection of self-referencing anchor loops)
#   * Billion-laughs alias bombs bounded (expansion limit enforced)
#   * Norway problem resolution (NO as boolean fails 1.2 core requirement)
#   * Block scalar strip chomping mechanism
#   * Sequence nested at same indentation level mechanism
#
# Exits non-zero if any check fails.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0

run_case() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_yaml_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    sed -n '1,12p' "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the yaml exercise, plain build"
run_case "plain" yaml-plain
if ! grep -q "all std/yaml checks passed" "$WORK/yaml-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every yaml section reported"
for phrase in \
  "block mapping and sequence:" \
  "sequence nested at same indent:" \
  "norway problem and scalar resolution:" \
  "sexagesimal, version, leading zeros and underscores:" \
  "block scalars and chomping:" \
  "flow collections and nesting:" \
  "anchors, aliases, and merge keys:" \
  "multi-document streams and empty documents:" \
  "emitter round-trip:"; do
  grep -q "$phrase" "$WORK/yaml-plain.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  all standard YAML 1.2 sections verified"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" yaml-release --release
if ! grep -q "all std/yaml checks passed" "$WORK/yaml-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving failures on invalid inputs and security bounds"

prove_input_fails() {
  local label="$1" name="$2" phrase="$3" code="$4"
  local src="$WORK/$name.iyi"
  cat > "$src" <<EOF
import std/yaml
using std/yaml::{YAML}

$code
EOF
  if ! "$IYI" build -o "$WORK/$name" "$src" >"$WORK/$name.build.log" 2>&1; then
    echo "  $label: build failed"
    sed -n '1,12p' "$WORK/$name.build.log"
    status=1
    return
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  $label: program exited 0, expected failure"
    status=1
    return
  fi
  if ! grep -q "$phrase" "$WORK/$name.out"; then
    echo "  $label: failed, but missing expected phrase '$phrase'"
    sed -n '$p' "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits %s with "%s"\n' "$label" "$exit_code" \
    "$(grep -m1 "$phrase" "$WORK/$name.out" | sed 's/^iyi: panic: //')"
}

# 1. Tab indentation forbidden
prove_input_fails "Tab indentation rejected" tab_fail \
  "tabs are forbidden as indentation" \
  'YAML.parse("server:\n\thost: localhost")'

# 2. Anchor cycle rejected
prove_input_fails "Anchor cycle rejected" cycle_fail \
  "cyclic anchor reference" \
  'YAML.parse("a: &loop\n  item: *loop")'

# 3. Billion-laughs bomb bounded
prove_input_fails "Billion-laughs bomb bounded" bomb_fail \
  "alias expansion limit exceeded" \
  'YAML.parse("a: &a [\"lol\",\"lol\",\"lol\",\"lol\",\"lol\",\"lol\",\"lol\",\"lol\",\"lol\"]\nb: &b [*a,*a,*a,*a,*a,*a,*a,*a,*a]\nc: &c [*b,*b,*b,*b,*b,*b,*b,*b,*b]\nd: &d [*c,*c,*c,*c,*c,*c,*c,*c,*c]\ne: &e [*d,*d,*d,*d,*d,*d,*d,*d,*d]\n")'

echo
echo "== proving the checks can fail when yaml mechanisms are broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" sed_script="$4"
  mkdir -p "$WORK/$dir/std"
  cp -R "$REPO/src/std/." "$WORK/$dir/std/"
  sed -e "$sed_script" "$REPO/src/std/yaml.iyi" > "$WORK/$dir/std/yaml.iyi"
  # A patch that matches nothing leaves the library intact, and an intact
  # library passes, which reads as "this check cannot fail" when the truth is
  # that nothing was broken to test it. Line-anchored patches drift.
  if cmp -s "$REPO/src/std/yaml.iyi" "$WORK/$dir/std/yaml.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_yaml_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched std library did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
    return
  fi
  if ! grep -q "$phrase" "$WORK/$dir/out"; then
    echo "  $label: failed, but not at expected check (expected '$phrase')"
    sed -n '$p' "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$exit_code" \
    "$(grep -m1 "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //')"
}

# 4. Norway regression: NO treated as boolean false
prove_fails "Norway regression (NO treated as bool)" no_norway \
  "norway: country NO must be String" \
  's/when "false", "False", "FALSE"/when "false", "False", "FALSE", "NO", "no"/'

# 5. Literal strip chomping broken
prove_fails "Chomping regression (strip broken)" no_strip \
  "block: literal strip" \
  's/while result\.ends_with[?]("\\n") || result\.ends_with[?]("\\r")/while false/'

# 6. Sequence at same indent level broken
prove_fails "Sequence at same indent broken" no_same_indent \
  "same indent: fruits size" \
  's/if nxt\.text\.starts_with[?]("- ") || nxt\.text == "-"/if false/'


echo
if [ "$status" -eq 0 ]; then
  echo "Standard YAML 1.2 library: parser, core schema, security bounds,"
  echo "block and flow collections, and emitter all pass plain and optimised,"
  echo "and each check is proven to fail when its mechanism is broken."
else
  echo "Standard YAML 1.2 library: something above failed."
fi
exit "$status"
