#!/usr/bin/env bash
# Standard library regular expression engine, exercised and driven.
# Runs the regex exercise plain and optimised (--release), checks every section
# reported, and proves the checks can fail by patching copies of std via IYI_PATH.
#
#     bash bench/std_regex_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across
# core regex capabilities: character matching, anchors, alternation priority,
# greedy quantifiers, and lookaround assertions.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_regex_exercise.iyi" \
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

echo "== the regex exercise, plain build"
run_case "plain" regex-plain
if ! grep -q "all std regex checks passed" "$WORK/regex-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every regex section reported"
for phrase in "literals, escapes" "character classes" "shorthand escapes" "anchors and word" "groups, numbered" "match data extents" "alternation and leftmost" "greedy and lazy" "lookaround assertions" "scan, split" "String integration" "published corpus traps" "linear-time pathological"; do
  grep -q "$phrase" "$WORK/regex-plain.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  all 13 regex sections reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" regex-release --release
if ! grep -q "all std regex checks passed" "$WORK/regex-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving the checks can fail when regex engine is broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" sed_script="$4"
  mkdir -p "$WORK/$dir/std"
  cp -R "$REPO/src/std/." "$WORK/$dir/std/"
  sed -e "$sed_script" "$REPO/src/std/regex.iyi" > "$WORK/$dir/std/regex.iyi"
  # A patch that matches nothing leaves the library intact, and an intact
  # library passes, which reads as "this check cannot fail" when the truth is
  # that nothing was broken to test it. Line-anchored patches drift.
  if cmp -s "$REPO/src/std/regex.iyi" "$WORK/$dir/std/regex.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_regex_exercise.iyi" \
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

# 1. Literal matching broken (invert char_eq?)
prove_fails "Char match broken" no_char "literal match?" \
  's/return true if got == want/return false if got == want/'

# 2. Line start anchor ^ broken
prove_fails "Anchor ^ broken" no_bol "line start match" \
  's/pos == 0/pos != 0/'

# 3. Alternation priority broken (invert split order in alternation)
prove_fails "Alternation order broken" no_alt "alt prefers leftmost branch" \
  '1674s/set_a/set_b/; 1677s/set_b/set_a/'

# 4. Greedy quantifier broken (invert preference in star)
prove_fails "Greedy quantifier broken" no_greedy "greedy takes longest match" \
  '1823s/set_a/set_b/; 1826s/set_b/set_a/'

# 5. Lookahead assertion broken (invert look_holds?)
prove_fails "Lookahead broken" no_look "positive lookahead success" \
  's/inst\.b == 1 [?] !held : held/inst.b == 1 ? held : !held/'

echo
if [ "$status" -eq 0 ]; then
  echo "Standard library regex: Thompson NFA with Pike VM and lookaround assertions"
  echo "passes plain and optimised, and each check is proven to fail when"
  echo "its mechanism is broken."
else
  echo "Standard library regex: something above failed."
fi
exit "$status"
