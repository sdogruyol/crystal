#!/usr/bin/env bash
# Standard specification and testing framework exercise driver.
# Runs the spec framework exercise in plain and release mode,
# checks every section reported, and proves the checks can fail
# by patching copies of the libraries via IYI_PATH.
#
#     bash bench/std_spec_framework_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across:
#   * EqualExpectation equality matcher
#   * Relational Be matcher (<, <=, >, >=)
#   * ContainExpectation string and collection containment
#   * Focus filtering isolation
#   * Tag filtering inclusion
#   * PCG32 randomization seed parsing
#   * CLI runner exit code on spec failure
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_spec_framework_exercise.iyi" \
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

echo "== the spec framework exercise, plain build"
run_case "plain" spec-plain
if ! grep -q "all std/spec framework checks passed" "$WORK/spec-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every spec framework section reported"
for phrase in \
  "std/spec: describe, context, and it structure" \
  "std/spec: hooks (before/after/around each and all)" \
  "std/spec: expectations and matchers" \
  "std/spec: pending examples" \
  "std/spec: tags and focus filtering" \
  "std/spec: formatters" \
  "std/spec: randomization" \
  "std/spec: CLI runner and exit codes"; do
  grep -qi "$phrase" "$WORK/spec-plain.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  All 8 Spec framework sections reported cleanly"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" spec-release --release
if ! grep -q "all std/spec framework checks passed" "$WORK/spec-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving the checks can fail when spec framework operations are broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" file="$4" sed_script="$5"
  mkdir -p "$WORK/$dir/std"
  # Copy unmodified siblings so include resolves everything
  cp "$REPO/src/std/"*.iyi "$WORK/$dir/std/" 2>/dev/null || true
  # Patch the targeted file
  sed -e "$sed_script" "$REPO/src/std/$file" > "$WORK/$dir/std/$file"
  # A patch that matches nothing leaves the library intact, and an intact
  # library passes, which reads as 'this check cannot fail' when the truth is
  # that nothing was broken to test it. Line-anchored patches drift.
  if cmp -s "$REPO/src/std/$file" "$WORK/$dir/std/$file"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi

  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_spec_framework_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched library did not build"
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

# 1. Equality matcher broken
prove_fails "equality matcher broken" no_eq "Spec run failed: structure" "spec.iyi" \
  's/actual_value == @expected_value/actual_value != @expected_value/'

# 2. Relational Be matcher broken
prove_fails "relational be matcher broken" no_be_rel "Spec run failed: matchers" "spec.iyi" \
  's/actual_value < @expected_value/actual_value > @expected_value/'

# 3. Containment matcher broken
prove_fails "containment matcher broken" no_contain "Spec run failed: matchers" "spec.iyi" \
  's/actual_value[.]includes[?](@expected)/false/'

# 4. Focus filtering broken
prove_fails "focus filtering broken" no_focus "Expected 1 focused example" "spec.iyi" \
  's/focus_filter = @focus ? true : nil/focus_filter = nil/'

# 5. Tag filtering broken
prove_fails "tag filtering broken" no_tags "Expected 1 tagged example" "spec.iyi" \
  's/tag_filter = @tags[.]empty[?] ? nil : @tags/tag_filter = nil/'

# 6. Randomization seed parsing broken
prove_fails "randomization seed broken" no_rand_seed "Expected seed 12345" "spec.iyi" \
  's/seed = parsed\.to_u64/seed = 0_u64/'

# 7. Runner exit code on failure broken
prove_fails "runner failure exit code broken" no_exit_code "Expected fail file to exit 1" "spec.iyi" \
  's/[(]raw >> 8[)] & 0xFF/0/'

exit "$status"
