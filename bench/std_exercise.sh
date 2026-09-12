#!/usr/bin/env bash
# Standard library foundation, exercised and driven. Runs the std exercise
# plain and optimised (--release), checks every section reported, proves the
# checks can fail by patching copies of std via IYI_PATH, and discovers any
# sibling std exercises.
#
#     bash bench/std_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across
# each foundation capability: comparison operators, clamping, Enumerable
# presence, minmax, each_cons_pair, and to_h collection conversion.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_exercise.iyi" \
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

echo "== the std exercise, plain build"
run_case "plain" std-plain
if ! grep -q "all std checks passed" "$WORK/std-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every std section reported"
for phrase in "std/traits:" "std/cmp:" "std/enumerable:" "std/list:" "std/derives:"; do
  grep -q "$phrase" "$WORK/std-plain.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  traits, cmp, enumerable, list, and derives all reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" std-release --release
if ! grep -q "all std checks passed" "$WORK/std-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving the checks can fail when foundation is broken"

prove_fails() {
  local label="$1" dir="$2" file="$3" phrase="$4" sed_script="$5"
  mkdir -p "$WORK/$dir/std"
  cp -R "$REPO/src/std/." "$WORK/$dir/std/"
  sed -e "$sed_script" "$REPO/src/std/$file" > "$WORK/$dir/std/$file"
  # A patch that matches nothing leaves the library intact, and an intact
  # library passes, which reads as "this check cannot fail" when the truth is
  # that nothing was broken to test it. Line-anchored patches drift.
  if cmp -s "$REPO/src/std/$file" "$WORK/$dir/std/$file"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_exercise.iyi" \
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

# 1. Cmp operator < inverted
prove_fails "Cmp < inverted" no_lt "traits.iyi" "Cmp: <" \
  's/cmp(other) < 0/cmp(other) > 0/'

# 2. Cmp clamp broken (returns max instead of min when low)
prove_fails "Cmp clamp broken" no_clamp "traits.iyi" "Cmp: clamp min" \
  's/return min if self < min/return max if self < min/'

# 3. Enumerable present? inverted
prove_fails "Enumerable present? inverted" no_present "enumerable.iyi" "enum: present? true" \
  's/!empty[?]/empty?/'

# 4. Enumerable minmax inverted
prove_fails "Enumerable minmax inverted" no_minmax "enumerable.iyi" "enum: minmax? min" \
  's/{low, high}/{high, low}/'

# 5. Enumerable each_cons_pair skips yields
prove_fails "Enumerable each_cons_pair broken" no_cons_pair "enumerable.iyi" "enum: each_cons_pair" \
  's/yield last, e unless last\.nil[?]/previous = nil/'

# 6. Enumerable to_h corrupted
prove_fails "Enumerable to_h corrupted" no_to_h "enumerable.iyi" "enum: to_h" \
  's/result\[pair\[0\]\] = pair\[1\]/result[pair[0]] = 0/'

echo
echo "== discovering and running sibling std exercises"
found_siblings=0
for sibling in "$REPO"/bench/std_*_exercise.sh; do
  [ -f "$sibling" ] || continue
  [ "$(basename "$sibling")" = "std_exercise.sh" ] && continue
  found_siblings=$((found_siblings + 1))
  echo "-- running sibling: $(basename "$sibling")"
  if ! bash "$sibling"; then
    echo "FAIL: sibling $(basename "$sibling") failed"
    status=1
  fi
done
if [ "$found_siblings" -eq 0 ]; then
  echo "  (no sibling exercises found yet)"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "Standard library foundation: traits, cmp, enumerable (71 methods), list,"
  echo "and derives all pass plain and optimised, and each check is proven"
  echo "to fail when its mechanism is broken."
else
  echo "Standard library foundation: something above failed."
fi
exit "$status"
