#!/usr/bin/env bash
# Exercises all twelve standard library utility types modules:
#   std/annotations, std/docs_pseudo_methods, std/base64, std/bit_array,
#   std/colorize, std/static_array, std/tuple, std/named_tuple,
#   std/benchmark, std/random, std/semantic_version, std/uuid.
#
#   bash bench/std_utility_types_exercise.sh
#
# Verifies:
#   1. Annotations: @[Flags], @[Deprecated], @[Experimental], @[Link], @[TargetFeature].
#   2. Docs pseudo methods: compiler documentation hooks.
#   3. Base64: RFC 4648 / RFC 2045 standard, strict, urlsafe encode/decode and roundtrip.
#   4. BitArray: popcount, indexed access, toggle, invert, fill, each.
#   5. Colorize: ANSI 16/256/RGB colors, text decorations, global and local toggle.
#   6. StaticArray: stack-allocated fixed array, indexing, slice bridges, mapping.
#   7. Tuple: heterogeneous compile-time sequences, indexing, equality, mapping.
#   8. NamedTuple: keyword indexing, keys, values, merging, reverse_merging.
#   9. Benchmark: real/CPU measurement, realtime, memory block, and IPS throughput.
#  10. Random: PCG32 deterministic sequence, next_*, Secure entropy, array sample/shuffle, ISAAC.
#  11. SemanticVersion: SemVer 2.0.0 parsing, precedence comparison, version bumping.
#  12. UUID: RFC 4122 / RFC 9562 v1-v8, namespaces, parsing, validation, and empty.
#      Note: Crystal v1!..v8! are impossible because '!' is an iyi operator;
#      explicit checked names validate_v1..v8, check_v1..v8, ensure_v1..v8 are verified.
#  13. Plain and release build optimization.
#  14. Failure proofs: panic probes for bounds and format errors.
#  15. Guarded mutation proofs: tests fail when library logic is broken,
#      with cmp guard guaranteeing the patch changed the source.
#
# Exits non-zero if any check fails.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0

export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"
export LIBRARY_PATH="/opt/homebrew/opt/bdw-gc/lib:${LIBRARY_PATH:-}"
export IYI_PATH="$REPO/src:$REPO/samples/iyi"

echo "== the utility types exercise, plain build"
if ! "$IYI" build -o "$WORK/exercise" "$REPO/bench/std_utility_types_exercise.iyi" \
     >"$WORK/exercise.build.log" 2>&1; then
  echo "  build failed"
  sed -n '1,12p' "$WORK/exercise.build.log"
  exit 1
fi

"$WORK/exercise" >"$WORK/exercise.out" 2>&1
exit_code=$?
sed 's/^/  /' "$WORK/exercise.out"
if [ "$exit_code" -ne 0 ]; then
  echo "  exercise exited $exit_code"
  status=1
fi

if ! grep -q "all utility types checks passed" "$WORK/exercise.out" 2>/dev/null; then
  echo "  MISSING: exercise did not complete successfully"
  status=1
fi

echo
echo "== every utility types section reported"
for section in "annotations: all passed" \
               "docs_pseudo_methods: all passed" \
               "base64: all passed" \
               "bit_array: all passed" \
               "colorize: all passed" \
               "static_array: all passed" \
               "tuple: all passed" \
               "named_tuple: all passed" \
               "benchmark: all passed" \
               "random: all passed" \
               "semantic_version: all passed" \
               "uuid: all passed"; do
  if ! grep -q "$section" "$WORK/exercise.out" 2>/dev/null; then
    echo "  MISSING: $section"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  all twelve lane modules successfully verified"

echo
echo "== the same program with release optimisation"
if ! "$IYI" build --release -o "$WORK/exercise-release" "$REPO/bench/std_utility_types_exercise.iyi" \
     >"$WORK/exercise-release.build.log" 2>&1; then
  echo "  optimised build failed"
  sed -n '1,12p' "$WORK/exercise-release.build.log"
  status=1
else
  "$WORK/exercise-release" >"$WORK/exercise-release.out" 2>&1
  rel_code=$?
  if [ "$rel_code" -ne 0 ]; then
    echo "  optimised exercise exited $rel_code"
    status=1
  elif ! grep -q "all utility types checks passed" "$WORK/exercise-release.out" 2>/dev/null; then
    echo "  MISSING: optimised run did not reach the end"
    status=1
  else
    echo "  optimised build passed all checks"
  fi
fi

echo
echo "== failure proofs: panic probes"
run_probe() {
  local label="$1" mode="$2" expected_phrase="$3"
  "$WORK/exercise" "$mode" >"$WORK/probe-$mode.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: probe unexpectedly succeeded"
    status=1
    return 1
  fi
  if ! grep -F -q "$expected_phrase" "$WORK/probe-$mode.out" 2>/dev/null; then
    echo "  $label: failed with code $code, but missing expected phrase '$expected_phrase'"
    tail -n 4 "$WORK/probe-$mode.out" | sed 's/^/    /'
    status=1
    return 1
  fi
  printf '  %s: correctly raised panic matching "%s" (exit %s)\n' \
    "$label" "$expected_phrase" "$code"
  return 0
}

run_probe "BitArray index out of bounds" probe_bit_array_bounds "Index out of bounds"
run_probe "BitArray negative size" probe_bit_array_negative "Negative bit array size"
run_probe "StaticArray index out of bounds" probe_static_array_bounds "Index out of bounds"
run_probe "UUID invalid string format" probe_uuid_invalid_string "Invalid UUID string format"
run_probe "UUID version mismatch validation" probe_uuid_mismatched_version "Invalid UUID variant"
run_probe "SemanticVersion invalid parse" probe_semver_invalid "Not a semantic version"

echo
echo "== guarded failure proofs: checks fail when library is broken"
prove_fails() {
  local label="$1" dir="$2" file="$3" expected_phrase="$4" sed_script="$5"
  mkdir -p "$WORK/$dir/std"
  cp -R "$REPO/src/std/." "$WORK/$dir/std/"
  sed -e "$sed_script" "$REPO/src/std/$file" > "$WORK/$dir/std/$file"

  # Guarded check: a patch that matches nothing leaves the library intact,
  # which would falsely report a pass or invalid test.
  if cmp -s "$REPO/src/std/$file" "$WORK/$dir/std/$file"; then
    echo "  $label: GUARD FAILED: the patch changed nothing, test invalid"
    status=1
    return
  fi

  if ! IYI_PATH="$WORK/$dir:$REPO/src:$REPO/samples/iyi" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_utility_types_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched library did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi

  "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: exercise passed despite broken code: check does not test this"
    status=1
  elif grep -F -q "$expected_phrase" "$WORK/$dir/out" 2>/dev/null; then
    printf '  %s: caught expected failure matching "%s" (exit %s)\n' \
      "$label" "$expected_phrase" "$code"
  else
    echo "  $label: failed (exit $code) but did not match '$expected_phrase'"
    tail -n 4 "$WORK/$dir/out" | sed 's/^/    /'
    status=1
  fi
}

# 1. Break BitArray count
prove_fails "BitArray count calculation" broken_bit_array "bit_array.iyi" "count is 3" \
  's/ones += 1 if unsafe_fetch(i)/ones += 2 if unsafe_fetch(i)/'

# 2. Break StaticArray element access
prove_fails "StaticArray element access" broken_static_array "static_array.iyi" "first element is 10" \
  's/to_unsafe\[0\]/to_unsafe[0] + 1/'

# 3. Break SemanticVersion precedence comparison
prove_fails "SemanticVersion precedence" broken_semver "semantic_version.iyi" "1.2.3 < 1.2.4" \
  's/@patch < other.patch ? -1 : 1/@patch < other.patch ? 1 : -1/'

# 4. Break UUID v4 version generation
prove_fails "UUID v4 version generation" broken_uuid "uuid.iyi" "UUID.v4 is v4" \
  's/version : Version = Version::V4/version : Version = Version::V1/'
echo
if [ "$status" -eq 0 ]; then
  echo "UtilityTypes: all twelve modules verified plain and release,"
  echo "panic probes confirmed, and guarded failure proofs confirmed load-bearing."
else
  echo "UtilityTypes: one or more checks failed."
fi

exit "$status"
