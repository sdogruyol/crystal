#!/usr/bin/env bash
# Exercises the standard library collections (Deque, Set, and Tuple)
# and proves its checks can fail.
#
#   bash bench/std_collections_exercise.sh
#
# Verifies:
#   1. Complete Deque surface: double-ended operations, bounds checks, bulk pops.
#   2. Deque ring-buffer wraparound across both wrap branches.
#   3. Deque growth-while-wrapped with contiguous element preservation.
#   4. Deque rotate, insert, delete_at with element shifting.
#   5. Deque Indexable integration (fetch, bsearch, values_at, join, etc.).
#   6. Complete Set algebra: union, intersection, difference, symmetric difference.
#   7. Set mathematical identities: inclusion-exclusion, self-difference, self-symmetric difference, De Morgan.
#   8. Set relations: subset_of?, superset_of?, disjoint?, proper subsets, equality.
#   9. Set Enumerable integration: all?, any?, none?, reduce, map.
#  10. Tuple and NamedTuple: compile-time indexing, size, empty?, ==, map, to_a, keys, values, has_key?.
#  11. Failure proofs: panic probes and patched library copies via IYI_PATH.
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

echo "== the collections exercise, plain build"
if ! "$IYI" build -o "$WORK/exercise" "$REPO/bench/std_collections_exercise.iyi" \
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

if ! grep -q "all collections checks passed" "$WORK/exercise.out" 2>/dev/null; then
  echo "  MISSING: exercise did not complete successfully"
  status=1
fi

echo
echo "== every collections section reported"
for section in "deque surface: all passed" \
               "deque wraparound: all passed" \
               "deque manipulation: all passed" \
               "set algebra: all passed" \
               "tuple and named_tuple: all passed"; do
  if ! grep -q "$section" "$WORK/exercise.out" 2>/dev/null; then
    echo "  MISSING: $section"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  deque surface, wraparound, manipulation, set algebra, and tuple all reported"

echo
echo "== the same program with release optimisation"
if ! "$IYI" build --release -o "$WORK/exercise-release" "$REPO/bench/std_collections_exercise.iyi" \
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
  elif ! grep -q "all collections checks passed" "$WORK/exercise-release.out" 2>/dev/null; then
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
  if ! grep -q "$expected_phrase" "$WORK/probe-$mode.out" 2>/dev/null; then
    echo "  $label: failed with code $code, but missing expected phrase '$expected_phrase'"
    tail -n 4 "$WORK/probe-$mode.out" | sed 's/^/    /'
    status=1
    return 1
  fi
  printf '  %s: correctly raised panic matching "%s" (exit %s)\n' \
    "$label" "$expected_phrase" "$code"
  return 0
}

run_probe "deque out of range" probe_deque_out_of_range "out of range"
run_probe "deque empty pop" probe_deque_empty_pop "empty deque"
run_probe "deque empty shift" probe_deque_empty_shift "empty deque"
run_probe "deque negative capacity" probe_deque_negative_capacity "negative capacity"

echo
echo "== failure proofs: checks fail when collections are broken"
prove_fails() {
  local label="$1" dir="$2" file="$3" expected_phrase="$4" sed_script="$5"
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

  if ! IYI_PATH="$WORK/$dir:$REPO/src:$REPO/samples/iyi" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_collections_exercise.iyi" \
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

# 1. Break Deque index calculation in wrapped buffer
prove_fails "Deque wraparound calculation" broken_wrap "deque.iyi" "wrapped w1[2]" \
  '1,100s/idx = idx - @capacity if idx >= @capacity/idx = idx + 1 if idx >= @capacity/'

# 2. Break Deque growth-while-wrapped element copy
prove_fails "Deque growth while wrapped" broken_growth "deque.iyi" "post-growth" \
  's/while i < wrapped_count/while i < wrapped_count - 1/'

# 3. Break Set union
prove_fails "Set union operation" broken_union "set.iyi" "union size is 8" \
  's/other\.each { |v| result\.add(v) }/# broken union/'

# 4. Break Set difference
prove_fails "Set difference operation" broken_diff "set.iyi" "s1 - s2" \
  's/unless other\.includes[?](v)/if other.includes?(v)/'

# 5. Break Tuple equality
prove_fails "Tuple equality" broken_tuple_eq "tuple.iyi" "tuple equality" \
  's/self\[{{i}}\] == other\[{{i}}\]/false/'

echo
if [ "$status" -eq 0 ]; then
  echo "Collections: Deque, Set, and Tuple verified plain and release,"
  echo "ring-buffer wraparound and growth-while-wrapped exercised,"
  echo "set algebra identities proven, and checks confirmed load-bearing."
else
  echo "Collections: one or more checks failed."
fi

exit "$status"
