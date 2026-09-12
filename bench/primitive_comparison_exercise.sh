#!/usr/bin/env bash
# Drives bench/primitive_comparison_exercise.iyi.
#
#     bash bench/primitive_comparison_exercise.sh
#
# Four steps, the last one a failure proof:
#   1. The program holds, plain build.
#   2. Every section reported.
#   3. The same program with optimisation on.
#   4. Failure proof: the four type names are dropped from the prelude's list
#      again, and the program stops answering `true` for values that are equal.
#
# The proof checks that its patch changed the file before it believes the
# failure, because a patch that matched nothing would otherwise read as a pass.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
PRIMITIVES="$REPO/src/iyi/primitives.iyi"
EXERCISE="$REPO/bench/primitive_comparison_exercise.iyi"
WORK="$(mktemp -d)"
status=0

restore() {
  [ -f "$PRIMITIVES.orig" ] || return 0
  mv -f "$PRIMITIVES.orig" "$PRIMITIVES"
  touch "$PRIMITIVES"
}
cleanup() { restore; rm -rf "$WORK"; }
trap cleanup EXIT

step() { echo "== $1"; }

step "the primitive comparison exercise, plain build"
if ! "$IYI" run "$EXERCISE" >"$WORK/plain.txt" 2>&1; then
  echo "FAIL: the exercise did not run"
  sed -n '1,20p' "$WORK/plain.txt"
  exit 1
fi
sed 's/^/  /' "$WORK/plain.txt"
grep -q "all primitive comparison checks passed" "$WORK/plain.txt" || {
  echo "FAIL: the exercise did not report passing"; exit 1; }

step "every section reported"
for section in "eight integer types compare equal" "unequal values are reported" \
               "orderings hold on Int8" "boundary values compare equal"; do
  grep -q "$section" "$WORK/plain.txt" || {
    echo "FAIL: missing section: $section"; status=1; }
done
[ "$status" -eq 0 ] && echo "  four sections reported"

step "the same program with optimisation on (--release)"
if ! "$IYI" run --release "$EXERCISE" >"$WORK/release.txt" 2>&1; then
  echo "FAIL: the optimised build did not run"
  sed -n '1,20p' "$WORK/release.txt"
  exit 1
fi
grep -q "all primitive comparison checks passed" "$WORK/release.txt" || {
  echo "FAIL: the optimised build did not report passing"; exit 1; }
echo "  release: all primitive comparison checks passed"

step "failure proof: the narrow integer types leave the prelude's list again"
cp "$PRIMITIVES" "$PRIMITIVES.orig"
python3 - "$PRIMITIVES" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
wide_ints = "%w(Int32 Int64 UInt8 UInt64)"
wide_nums = "%w(Int32 Int64 UInt8 UInt64 Float64)"
ints = "%w(Int8 Int16 Int32 Int64 UInt8 UInt16 UInt32 UInt64)"
nums = "%w(Int8 Int16 Int32 Int64 UInt8 UInt16 UInt32 UInt64 Float64)"
assert ints in text and nums in text, "the prelude's lists are not in the shape this proof patches"
text = text.replace(nums, wide_nums, 1).replace(ints, wide_ints, 1)
open(path, "w").write(text)
PY
if cmp -s "$PRIMITIVES" "$PRIMITIVES.orig"; then
  echo "FAIL: the patch changed nothing, so it proves nothing"
  exit 1
fi
if "$IYI" run "$EXERCISE" >"$WORK/mutated.txt" 2>&1; then
  echo "FAIL: the exercise still passed with the narrow types dropped"
  status=1
else
  echo "  exits non-zero at \"$(grep -m1 'ASSERTION FAILED' "$WORK/mutated.txt" || echo 'a comparison failure')\""
fi
restore

if [ "$status" -eq 0 ]; then
  echo
  echo "primitive comparisons: eight integer types agree with themselves,"
  echo "and dropping four of them from the prelude's list is proven to break it."
fi
exit "$status"
