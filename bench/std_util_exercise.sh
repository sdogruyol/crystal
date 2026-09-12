#!/usr/bin/env bash
# Utility standard library exercise driver.
# Runs the util exercise (std/csv, std/log, std/option_parser) in plain and
# release mode, checks every section reported, and proves the checks can fail
# by patching copies of the libraries via IYI_PATH.
#
#     bash bench/std_util_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across:
#   * CSV quoted comma delimiter recognition
#   * CSV embedded newline preservation inside quotes
#   * CSV escaped quote ("") unescaping
#   * CSV CRLF line endings
#   * Log severity level threshold filtering
#   * Log named logger hierarchy source naming
#   * OptionParser double-dash (--) parsing termination
#   * OptionParser missing required argument detection
#   * OptionParser help text banner generation
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_util_exercise.iyi" \
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

echo "== the util exercise, plain build"
run_case "plain" util-plain
if ! grep -q "all std/util checks passed" "$WORK/util-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every util section reported"
for phrase in "std/csv:" "quoted field with comma" "embedded newline" "escaped quote" "empty field" "CRLF line endings" "round trip" "headers access" "IO streaming" "std/log:" "output at each level" "level threshold filtering" "block evaluation suppression" "hierarchical logger" "std/option_parser:" "realistic argv parse" "missing required argument" "optional argument" "unknown option" "generated help text"; do
  grep -qi "$phrase" "$WORK/util-plain.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  CSV, Log, and OptionParser sections all reported cleanly"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" util-release --release
if ! grep -q "all std/util checks passed" "$WORK/util-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving the checks can fail when utility operations are broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" file="$4" sed_script="$5"
  mkdir -p "$WORK/$dir/std"
  # Copy unmodified siblings so include resolves everything
  cp "$REPO/src/std/"*.iyi "$WORK/$dir/std/" 2>/dev/null || true
  # Patch the targeted file
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
       -o "$WORK/$dir/program" "$REPO/bench/std_util_exercise.iyi" \
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

# The CSV library was rewritten as a lexer, so these four patches name the
# lexer's branches. Each one makes the parser answer a wrong value rather than
# refuse the input, because a library that raises proves only that it noticed,
# and what these checks are for is the case where nobody notices. The patterns
# avoid quote characters, which cannot appear inside a single-quoted script,
# and `\r` escapes, which GNU and BSD sed read differently.

# 1. A separator inside a quoted cell stops being part of the cell
prove_fails "csv quoted field recognition broken" no_csv_comma "csv: comma field 0" "csv.iyi" \
  's/parts << ch[.]ord[.]to_u8$/parts << ch.ord.to_u8 unless ch == @separator/'

# 2. A newline inside a quoted cell stops being part of the cell
prove_fails "csv newline in quotes broken" no_csv_nl "csv: newline" "csv.iyi" \
  's/parts << ch[.]ord[.]to_u8$/parts << ch.ord.to_u8 unless ch.ord == 10 || ch.ord == 13/'

# 3. A doubled quote unescapes to the wrong character
prove_fails "csv escaped quote broken" no_csv_esc "csv: escaped quote" "csv.iyi" \
  's/parts << quote_byte$/parts << 88_u8/'

# 4. The line feed after a carriage return is no longer consumed with it
prove_fails "csv crlf line endings broken" no_csv_crlf "csv: crlf" "csv.iyi" \
  's/if current_char == ..n./if false/'
# 5. Log severity level threshold filtering broken
prove_fails "log level threshold broken" no_log_thresh "log: filtered" "log.iyi" \
  's/return if severity < level/# return if severity < level/'

# 6. Log hierarchy source naming broken
prove_fails "log hierarchy source broken" no_log_hier "log: hierarchy" "log.iyi" \
  's/"#{@source}.#{name}"/name/'

# 7. OptionParser double-dash terminating parsing broken
prove_fails "option_parser double-dash broken" no_opt_dash "opt: double-dash" "option_parser.iyi" \
  's/if arg == "--"/if false/'

# 8. OptionParser missing required argument detection broken
prove_fails "option_parser missing argument broken" no_opt_miss "opt: missing argument" "option_parser.iyi" \
  's/cb\.call(flag)/val = ""/'

# 9. OptionParser help text banner broken
prove_fails "option_parser help banner broken" no_opt_help "opt: help banner" "option_parser.iyi" \
  's/lines << b/# lines << b/'

echo
if [ "$status" -eq 0 ]; then
  echo "All std/util checks pass plain and release, and every check"
  echo "is proven load-bearing by failing when its mechanism is broken."
fi

exit "$status"
