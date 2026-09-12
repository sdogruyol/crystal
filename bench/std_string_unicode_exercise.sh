#!/usr/bin/env bash
# String and Unicode primitives standard library exercise driver.
# Runs the exercise in plain and release mode, checks every section
# reported, and proves the checks can fail by patching copies of the libraries.
#
#     bash bench/std_string_unicode_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across
# unicode validation, levenshtein distance, string pool deduplication,
# string scanner matching, pretty print formatting, text primitives,
# and format strings.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_string_unicode_exercise.iyi" \
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

echo "== the string & unicode exercise, plain build"
run_case "plain" exercise-plain
if ! grep -q "all std/string_unicode checks passed" "$WORK/exercise-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every exercise section reported"
for phrase in "unicode:" "scanner:" "string_pool:" "levenshtein:" "pretty_print:" "text:" "format:"; do
  grep -q "$phrase" "$WORK/exercise-plain.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  unicode, scanner, string_pool, levenshtein, pretty_print, text, and format all reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" exercise-release --release
if ! grep -q "all std/string_unicode checks passed" "$WORK/exercise-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving the checks can fail when operations are broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" file="$4" sed_script="$5"
  mkdir -p "$WORK/$dir/std"
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
       -o "$WORK/$dir/program" "$REPO/bench/std_string_unicode_exercise.iyi" \
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

# 1. Unicode validation broken
prove_fails "unicode validation broken" no_valid "unicode: valid ascii" "unicode.iyi" \
  's/def self\.valid[?](bytes : Bytes) : Bool/def self.valid?(bytes : Bytes) : Bool; return false/'

# 2. Levenshtein distance broken
prove_fails "levenshtein distance broken" no_dist "levenshtein: kitten to sitting" "levenshtein.iyi" \
  's/last_cost = cost/last_cost = 999/'

# 3. StringPool get broken
prove_fails "string_pool get broken" no_pool "pool: deduplication reuses same instance" "string_pool.iyi" \
  's/return existing/return "broken"/'

# 4. StringScanner scan broken
prove_fails "string_scanner scan broken" no_scan "scanner: scan string match" "string_scanner.iyi" \
  's/match_string(pattern, advance: true, anchored: true)/nil/'

# 5. PrettyPrint format broken
prove_fails "pretty_print format broken" no_pp "pretty_print: compact array" "pretty_print.iyi" \
  's/PrettyPrint\.format(self/PrettyPrint.format("broken"/'

# 6. Text single_byte_optimizable broken
prove_fails "text single_byte broken" no_sbo "text: single_byte_optimizable" "text.iyi" \
  's/def single_byte_optimizable[?] : Bool/def single_byte_optimizable? : Bool; return false/'

# 7. Format sprintf broken
prove_fails "format sprintf broken" no_sprintf "format: sprintf decimal" "format.iyi" \
  's/val\.to_i64, 10/val.to_i64, 16/'

echo
if [ "$status" -eq 0 ]; then
  echo "String & Unicode: plain and release pass, and all mutation proofs fail as expected."
else
  echo "String & Unicode: some checks failed."
fi

exit "$status"
