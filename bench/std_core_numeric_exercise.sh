#!/usr/bin/env bash
# Standard scalar and core numeric library exercise driver.
# Runs the core numeric exercise in plain and release mode, checks every section
# reported, and proves the checks can fail by patching copies of std modules.
#
#     bash bench/std_core_numeric_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across
# boolean logic, nil semantics, symbol ordering, comparable bounds, steppable
# iteration, enum values and bitmasks, character casing, number arithmetic,
# integer gcd, float predicates, math functions, and complex addition.
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
  if ! PATH=/opt/homebrew/bin:/usr/bin:/bin LIBRARY_PATH=/opt/homebrew/opt/bdw-gc/lib \
       IYI_PATH="$REPO/src" "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_core_numeric_exercise.iyi" \
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

echo "== the core numeric exercise, plain build"
run_case "plain" numeric-plain
if ! grep -q "all core numeric checks passed" "$WORK/numeric-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every core numeric section reported"
for phrase in \
  "bool surface: all passed" \
  "nil surface: all passed" \
  "symbol surface: all passed" \
  "comparable surface: all passed" \
  "steppable and iterable surface: all passed" \
  "enum surface: all passed" \
  "char surface: all passed" \
  "number surface: all passed" \
  "int surface: all passed" \
  "float surface: all passed" \
  "math surface: all passed" \
  "complex surface: all passed"; do
  if ! grep -q "$phrase" "$WORK/numeric-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  bool, nil, symbol, comparable, steppable, iterable, enum, char, number, int, float, math, and complex all reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" numeric-release --release
if ! grep -q "all core numeric checks passed" "$WORK/numeric-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when scalar and numeric operations are broken"

prove_fails() {
  local label="$1" mod_file="$2" dir="$3" phrase="$4" sed_script="$5"
  mkdir -p "$WORK/$dir/std"
  sed -e "$sed_script" "$REPO/src/std/$mod_file" > "$WORK/$dir/std/$mod_file"
  # A patch that matches nothing leaves the library intact, and an intact
  # library passes, which reads as "this check cannot fail" when the truth is
  # that nothing was broken to test it. Line-anchored patches drift.
  if cmp -s "$REPO/src/std/$mod_file" "$WORK/$dir/std/$mod_file"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! PATH=/opt/homebrew/bin:/usr/bin:/bin LIBRARY_PATH=/opt/homebrew/opt/bdw-gc/lib \
       IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_core_numeric_exercise.iyi" \
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

# 1. Bool bitwise AND broken
prove_fails "bool & broken" bool.iyi no_bool_and "bool and true" \
  's/self ? other : false/false/'

# 2. Nil object_id broken
prove_fails "nil object_id broken" nil.iyi no_nil_id "nil object_id" \
  's/0_u64/1_u64/'

# 3. Symbol ordering broken
prove_fails "symbol <=> broken" symbol.iyi no_sym_cmp "symbol <=>" \
  's/s1 < s2 ? -1 : 1/0/'

# 4. Comparable less-than broken
prove_fails "comparable < broken" comparable.iyi no_comp_lt "comparable <" \
  's/cmp ? cmp < 0 : false/false/'

# 5. Steppable step advance broken
prove_fails "steppable step broken" steppable.iyi no_step "steppable step block" \
  's/next_val = @current + @step/next_val = @current + @step + 1/'

# 6. Enum bitmask includes? broken
prove_fails "enum includes? broken" enum.iyi no_enum_inc "enum includes? red" \
  's/(value & other.value) == other.value/false/'

# 7. Char downcase broken
prove_fails "char downcase broken" char.iyi no_char_down "char downcase" \
  's/(ord + 32).unsafe_chr/self/'

# 8. Number abs2 broken
prove_fails "number abs2 broken" number.iyi no_num_abs2 "number abs2" \
  's/self \* self/self/'

# 9. Integer gcd broken
prove_fails "int gcd broken" int.iyi no_int_gcd "int gcd" \
  's/a = self.abs/a = self.abs + 1/'

# 10. Float nan? predicate broken
prove_fails "float nan? broken" float.iyi no_flt_nan "float nan? true" \
  's/!(self == self)/false/'

# 11. Math hypot broken
prove_fails "math hypot broken" math.iyi no_math_hypot "math hypot" \
  's/sqrt(x \* x + y \* y)/0.0/'

# 12. Complex addition broken
prove_fails "complex + broken" complex.iyi no_cplx_add "complex +" \
  's/@real + other.real/@real/'

echo
if [ "$status" -eq 0 ]; then
  echo "Core numeric standard library: bool, nil, symbol, comparable, steppable,"
  echo "iterable, enum, char, number, int, float, math, and complex all pass"
  echo "plain and optimised, and each check is proven to fail when its mechanism is broken."
else
  echo "std/core_numeric exercise driver: failures encountered"
fi
exit "$status"
