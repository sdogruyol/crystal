#!/usr/bin/env bash
# Native JSON standard library exercise driver.
# Runs the JSON exercise in plain and release mode, checks every section
# reported, proves the checks can fail by patching copies of std/json.iyi,
# and executes dedicated boundary-failure probes against invalid JSON shapes.
#
#     bash bench/std_json_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across
# number parsing, surrogate pair decoding, dynamic traversal, compact serialization,
# and streaming pull parsing, and validates that every invalid JSON shape is rejected
# with a precise message naming what and where.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_json_exercise.iyi" \
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

echo "== the json exercise, plain build"
run_case "plain" json-plain
if ! grep -q "all std/json checks passed" "$WORK/json-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every json section reported"
for phrase in "number parsing:" "string parsing:" "dynamic traversal:" "builder & serializer:" "streaming pull parser:" "JSONTestSuite acceptance:" "depth limiting:" "round-trip:"; do
  grep -q "$phrase" "$WORK/json-plain.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  numbers, strings, traversal, builder, pull parser, acceptance, depth, and round-trip all reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" json-release --release
if ! grep -q "all std/json checks passed" "$WORK/json-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving the checks can fail when json operations are broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" sed_script="$4"
  mkdir -p "$WORK/$dir/std"
  sed -e "$sed_script" "$REPO/src/std/json.iyi" > "$WORK/$dir/std/json.iyi"
  # A patch that matches nothing leaves the library intact, and an intact
  # library passes, which reads as "this check cannot fail" when the truth is
  # that nothing was broken to test it. Line-anchored patches drift.
  if cmp -s "$REPO/src/std/json.iyi" "$WORK/$dir/std/json.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_json_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched json library did not build"
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

# 1. Number parsing broken (beyond Int64 fallback broken)
prove_fails "huge number fallback broken" no_huge "num: huge beyond Int64 is float" \
  's/raw_num\.to_f/0.0/'

# 2. Surrogate pair decoding broken
prove_fails "surrogate pair decoding broken" no_surrogate "str: surrogate pair emoji" \
  's/codepoint = 0x10000 + ((hex1 - 0xD800) << 10) + (hex2 - 0xDC00)/codepoint = 63/'

# 3. Negative zero detection broken
prove_fails "negative zero broken" no_neg_zero "num: negative zero sign bit" \
  's/raw_num == "-0"/false/'

# 4. Dynamic traversal as_i broken
prove_fails "as_i conversion broken" no_as_i "num: i32 value" \
  's/r\.to_i32/0/'

# 5. Builder compact output broken (inserts wrong separator)
prove_fails "builder compact output broken" no_compact "builder: compact output" \
  's/@buffer\.append(58_u8)/@buffer.append(61_u8)/'

# 6. Streaming pull parser broken (read_int returns 0)
prove_fails "pull parser read_int broken" no_pull_int "pull: v_val" \
  's/val = @int_value/val = 0_i64/'

echo
echo "== dedicated boundary failure probes (invalid JSONTestSuite shapes)"

prove_panic() {
  local label="$1" code="$2" expected_phrase="$3"
  local probe_file="$WORK/probe_${label}.iyi"
  local bin_file="$WORK/probe_${label}"

  cat <<EOF > "$probe_file"
module bench/probe_${label}

import std/json

$code
EOF

  if ! IYI_PATH="$REPO/src" "$IYI" build -o "$bin_file" "$probe_file" > "$WORK/${label}.build.log" 2>&1; then
    echo "  probe $label: build failed unexpectedly"
    sed -n '1,12p' "$WORK/${label}.build.log"
    status=1
    return
  fi

  "$bin_file" > "$WORK/${label}.out" 2>&1
  local exit_code=$?

  if [ "$exit_code" -ne 1 ]; then
    echo "  probe $label: succeeded unexpectedly (should have panicked with exit 1, got $exit_code)"
    status=1
    return
  fi

  if ! grep -q "$expected_phrase" "$WORK/${label}.out"; then
    echo "  probe $label: failed but with wrong message (expected '$expected_phrase'):"
    sed -n '1,5p' "$WORK/${label}.out"
    status=1
    return
  fi

  echo "  probe $label: panicked as expected ($expected_phrase)"
}

prove_panic "trailing_comma_array" \
  'JSON.parse("[1, 2,]")' \
  "trailing comma in array at line 1, column 6"

prove_panic "trailing_comma_object" \
  'JSON.parse("{\"a\": 1,}")' \
  "trailing comma in object at line 1, column 8"

prove_panic "unterminated_string" \
  'JSON.parse("\"hello")' \
  "unterminated string at line 1, column 1"

prove_panic "bare_identifier_truefoo" \
  'JSON.parse("truefoo")' \
  "bare identifier 'foo' at line 1, column 1"

prove_panic "bare_identifier_undefined" \
  'JSON.parse("undefined")' \
  "bare identifier 'undefined' at line 1, column 1"

prove_panic "duplicate_key" \
  'JSON.parse("{\"k\": 1, \"k\": 2}")' \
  "duplicate key 'k' at line 1, column 10"

prove_panic "lone_high_surrogate" \
  'JSON.parse("[\"\\ud83d \"]")' \
  "lone high surrogate"

prove_panic "lone_low_surrogate" \
  'JSON.parse("[\"\\ude00\"]")' \
  "lone low surrogate"

prove_panic "invalid_escape" \
  'JSON.parse("[\"\\a\"]")' \
  "invalid escape sequence" 

prove_panic "leading_zero_number" \
  'JSON.parse("012")' \
  "leading zero not allowed in number at line 1, column 2"

prove_panic "leading_plus" \
  'JSON.parse("+42")' \
  "unexpected character '+' at line 1, column 1"

prove_panic "trailing_decimal" \
  'JSON.parse("42.")' \
  "expected at least one digit after decimal point at line 1, column 1"

prove_panic "lone_minus" \
  'JSON.parse("-")' \
  "expected digit after minus sign in number at line 1, column 1"

prove_panic "depth_limit" \
  'p = JSON::Parser.new("[[[[[[1]]]]]]"); p.max_nesting = 4; p.parse' \
  "nesting depth of 5 exceeds maximum depth 4 at line 1, column 5"

prove_panic "extra_token_root" \
  'JSON.parse("123 456")' \
  "unexpected token after JSON root value at line 1, column 5"

prove_panic "empty_input" \
  'JSON.parse("   ")' \
  "empty JSON input at line 1, column 1"

echo
if [ "$status" -eq 0 ]; then
  echo "Native JSON standard library: numbers, strings, dynamic traversal, builder, streaming"
  echo "pull parser, JSONTestSuite acceptance and rejections all pass plain and release, and"
  echo "each check is proven to fail when its mechanism is broken."
else
  echo "Native JSON standard library: something above failed."
fi
exit "$status"
