#!/usr/bin/env bash
# Text processing standard library exercise driver.
# Runs the text exercise in plain and release mode, checks every section
# reported, and proves the checks can fail by patching copies of std/text.iyi.
#
#     bash bench/std_text_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across
# character inspection, case conversion, base conversion, chomp line-ending
# removal, string splitting, substitution, UTF-8 reverse preservation, and
# multi-byte character encoding.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_text_exercise.iyi" \
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

echo "== the text exercise, plain build"
run_case "plain" text-plain
if ! grep -q "all std/text checks passed" "$WORK/text-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every text section reported"
for phrase in "char inspection:" "case conversion:" "base conversion:" "strip and chomp:" "split and partition:" "search and index:" "substitution:" "transformations:" "utf8 awareness:"; do
  grep -q "$phrase" "$WORK/text-plain.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  char inspection, case, base, strip/chomp, split/partition, search/index, substitution, transformations, and utf8 all reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" text-release --release
if ! grep -q "all std/text checks passed" "$WORK/text-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving the checks can fail when text operations are broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" sed_script="$4"
  mkdir -p "$WORK/$dir/std"
  sed -e "$sed_script" "$REPO/src/std/text.iyi" > "$WORK/$dir/std/text.iyi"
  # A patch that matches nothing leaves the library intact, and an intact
  # library passes, which reads as "this check cannot fail" when the truth is
  # that nothing was broken to test it. Line-anchored patches drift.
  if cmp -s "$REPO/src/std/text.iyi" "$WORK/$dir/std/text.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_text_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched text library did not build"
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

# 1. ASCII letter predicate broken
prove_fails "ascii letter predicate broken" no_letter "char: ascii_letter lowercase" \
  's/def ascii_letter[?] : Bool/def ascii_letter? : Bool; return false/'

# 2. String capitalize broken
prove_fails "string capitalize broken" no_capitalize "string: capitalize standard" \
  's/b0 - 32_u8/b0/'

# 3. Base parsing broken (base 16 returns zero)
prove_fails "base parsing broken" no_base "string: to_i base 16" \
  's/value \* base + digit/0/'

# 4. Chomp CRLF broken
prove_fails "chomp crlf broken" no_chomp "string: chomp crlf" \
  's/return byte_slice(0, bytesize - 2)/return self/'

# 5. String split broken
prove_fails "string split broken" no_split "string: split str" \
  's/byte_slice(start, idx - start)/"broken"/'

# 6. String substitution broken
prove_fails "string substitution broken" no_sub "string: sub str" \
  's/byte_slice(0, idx) + replacement/byte_slice(0, idx) + "wrong"/'

# 7. UTF-8 reverse broken
prove_fails "utf8 reverse broken" no_reverse "utf8: reverse content" \
  's/def reverse : String/def reverse : String; return "broken"/'

# 8. Multi-byte char to_s encoding broken
prove_fails "char utf8 encoding broken" no_encode "utf8: char to_s" \
  's/String\.new(2) do |b|/String.new(1) do |b|/'

echo
if [ "$status" -eq 0 ]; then
  echo "Text standard library: inspection, cases, conversions, strip, chomp, split,"
  echo "search, sub, transformations, and UTF-8 handling all pass plain and optimised,"
  echo "and each check is proven to fail when its mechanism is broken."
else
  echo "Text standard library: something above failed."
fi
exit "$status"
