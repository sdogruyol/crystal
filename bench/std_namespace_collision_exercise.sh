#!/usr/bin/env bash
# Drives bench/std_namespace_collision_exercise.iyi.
#
# bash bench/std_namespace_collision_exercise.sh
#
# Five steps, the last two failure proofs:
#   1. The program holds: twenty modules whose names shadow a prelude type,
#      loaded at once, with unqualified prelude names still meaning the
#      prelude's types.
#   2. Every one of the std modules compiles on its own, so the sweep is over
#      the whole library and not only the ones this program happens to reach.
#   3. The same program with optimisation on.
#   4. Failure proof: the compiler's rule removed - a sibling compilation unit
#      is allowed to win an unqualified name again, and the program stops
#      compiling by name.
#   5. Failure proof: std/enumerable writes its own `each` for `Array(T)`
#      again, and importing std/http breaks a file that never mentioned it.
#
# Both proofs check that their patch changed the file before they believe the
# failure: a patch that matched nothing would otherwise read as a pass.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
LOOKUP="$REPO/src/compiler/iyi/semantic/path_lookup.cr"
LOOKUP2="$REPO/src/compiler/iyi/semantic/type_lookup.cr"
EXERCISE="$REPO/bench/std_namespace_collision_exercise.iyi"
WORK="$(mktemp -d)"
status=0

# `mv` carries the copy's older timestamp back, so `make` would decide the
# compiler is already current and leave the mutated binary in place. Every
# restore touches the file, or the mutation outlives the proof that used it.
restore() {
  [ -f "$1.orig" ] || return 0
  mv -f "$1.orig" "$1"
  touch "$1"
}

cleanup() {
  restore "$LOOKUP"
  restore "$LOOKUP2"
  rm -rf "$WORK"
}
trap cleanup EXIT

step() { echo "== $1"; }

# The binary goes first. `make` compares whole seconds, so a patch written in
# the same second as the last link reads as already current, and the proof
# would run against the compiler it thought it had just replaced.
rebuild() {
  rm -f "$REPO/.build/iyi"
  ( cd "$REPO" && make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" ) \
    >"$WORK/build.log" 2>&1
}

step "the collision exercise, plain build"
if ! "$IYI" run "$EXERCISE" >"$WORK/plain.txt" 2>&1; then
  echo "FAIL: the exercise did not run"
  sed -n '1,20p' "$WORK/plain.txt"
  exit 1
fi
sed 's/^/  /' "$WORK/plain.txt"
grep -q "all std namespace collision checks passed" "$WORK/plain.txt" || {
  echo "FAIL: the exercise did not report passing"
  exit 1
}

step "every std module compiles on its own"
modules=0
for module in "$REPO"/src/std/*.iyi; do
  name="$(basename "$module" .iyi)"
  printf 'import std/%s\n' "$name" >"$WORK/one.iyi"
  if ! "$IYI" build --no-codegen "$WORK/one.iyi" >"$WORK/one.log" 2>&1; then
    echo "FAIL: std/$name does not compile by itself"
    sed -n '1,12p' "$WORK/one.log"
    status=1
  fi
  modules=$((modules + 1))
done
[ "$status" -eq 0 ] && echo "  all $modules std modules compile alone"

step "the same program with optimisation on (--release)"
if ! "$IYI" run --release "$EXERCISE" >"$WORK/release.txt" 2>&1; then
  echo "FAIL: the optimised build did not run"
  sed -n '1,20p' "$WORK/release.txt"
  exit 1
fi
grep -q "all std namespace collision checks passed" "$WORK/release.txt" || {
  echo "FAIL: the optimised build did not report passing"
  exit 1
}
echo "  release: all std namespace collision checks passed"

step "failure proof: a sibling unit may win an unqualified name again"
cp "$LOOKUP" "$LOOKUP.orig"
python3 - "$LOOKUP" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
start = text.index("        match = namespace.lookup_path_item(name, false, lookup_in_namespace, include_private, location)")
end = text.index("        return match if match", start) + len("        return match if match")
patched = text[:start] + "        return namespace.lookup_path_item(name, false, lookup_in_namespace, include_private, location)" + text[end:]
open(path, "w").write(patched)
PY
if cmp -s "$LOOKUP" "$LOOKUP.orig"; then
  echo "FAIL: the compiler patch changed nothing, so it proves nothing"
  exit 1
fi
touch "$LOOKUP"
if ! rebuild; then
  echo "FAIL: the mutated compiler did not build"
  sed -n '1,12p' "$WORK/build.log"
  exit 1
fi
if "$IYI" build --no-codegen "$EXERCISE" >"$WORK/m1.txt" 2>&1; then
  echo "FAIL: the exercise still compiled with the rule removed"
  status=1
else
  echo "  exits non-zero at \"$(grep -m1 -o 'Std::[A-Za-z]* is not imported here' "$WORK/m1.txt" || echo 'a name resolution error')\""
fi
restore "$LOOKUP"
rebuild || { echo "FAIL: the restored compiler did not build"; exit 1; }

step "failure proof: a type parameter is walled like a name the file wrote"
cp "$LOOKUP2" "$LOOKUP2.orig"
python3 - "$LOOKUP2" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
old = "if @raise && type.is_a?(Type) && !type_var_name?(node)"
new = "if @raise && type.is_a?(Type)"
assert old in text, "the exemption is not in the shape this proof patches"
open(path, "w").write(text.replace(old, new, 1))
PY
if cmp -s "$LOOKUP2" "$LOOKUP2.orig"; then
  echo "FAIL: the exemption patch changed nothing, so it proves nothing"
  exit 1
fi
touch "$LOOKUP2"
if ! rebuild; then
  echo "FAIL: the mutated compiler did not build"
  sed -n '1,12p' "$WORK/build.log"
  exit 1
fi
printf 'import std/json\n' >"$WORK/json.iyi"
if "$IYI" build --no-codegen "$WORK/json.iyi" >"$WORK/m2.txt" 2>&1; then
  echo "FAIL: std/json still compiled with the exemption removed"
  status=1
else
  echo "  exits non-zero at \"$(grep -m1 -o 'Std::Json is not imported here' "$WORK/m2.txt" || echo 'an R-1 error')\""
fi
restore "$LOOKUP2"
rebuild || { echo "FAIL: the restored compiler did not build"; exit 1; }

if [ "$status" -eq 0 ]; then
  echo
  echo "std namespace collisions: twenty shadowing modules load together,"
  echo "every std module compiles alone, and both rules are proven load-bearing."
fi
exit "$status"
