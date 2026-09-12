#!/usr/bin/env bash
# Exercises the complete standard library template and text parity suite
# (CSV, HTML, MIME, OptionParser, INI, ECR) and proves its checks can fail.
#
#   bash bench/std_template_text_parity_exercise.sh
#
# Verifies:
#   1. Plain and release compilation of the template/text parity exercise.
#   2. All 6 template/text parity sections report complete success.
#   3. Mutation proofs verifying checks are load-bearing across std modules.
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

# The ECR section compiles a template from a fixed path at compile time.
# Provide it deterministically instead of depending on leftover state.
cat > /tmp/my_test_template.ecr <<'TEMPLATE'
Hello <%= name %>!
<%- if count > 1 -%>
Count is <%= count %>
<%- else -%>
Single
<%- end -%>
TEMPLATE

echo "== the template and text parity exercise, plain build"
if ! "$IYI" build -o "$WORK/exercise" "$REPO/bench/std_template_text_parity_exercise.iyi" \
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

if ! grep -q "all std/template_text_parity checks passed" "$WORK/exercise.out" 2>/dev/null; then
  echo "  MISSING: exercise did not complete successfully"
  status=1
fi

echo
echo "== every template and text parity section reported"
for section in "std/html: escaping (string & IO), unescaping (named, decimal, hex), and entity tables verified" \
               "std/ini: section parsing, top-level keys, spacing formats, and parse exceptions verified" \
               "std/ecr: lexer, process_string, embed, render, def_to_s without shelling out verified" \
               "std/option_parser: flags, required/optional arguments, subcommands, help formatting verified" \
               "std/mime: MediaType, default registry, custom types, and Multipart builder/parser verified" \
               "std/csv: RFC 4180 parsing, headers, row accessors, builder quoting, and lexer tokens verified"; do
  if grep -qF "$section" "$WORK/exercise.out" 2>/dev/null; then
    printf '  %s\n' "$section"
  else
    echo "  MISSING SECTION: $section"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  all 6 template and text parity sections verified and reported"

echo
echo "== the same program with release optimisation"
if ! "$IYI" build --release -o "$WORK/exercise-release" "$REPO/bench/std_template_text_parity_exercise.iyi" \
     >"$WORK/exercise-release.build.log" 2>&1; then
  echo "  release build failed"
  sed -n '1,12p' "$WORK/exercise-release.build.log"
  exit 1
fi

"$WORK/exercise-release" >"$WORK/exercise-release.out" 2>&1
exit_code=$?
sed 's/^/  /' "$WORK/exercise-release.out"
if [ "$exit_code" -ne 0 ]; then
  echo "  release exercise exited $exit_code"
  status=1
fi

if ! grep -q "all std/template_text_parity checks passed" "$WORK/exercise-release.out" 2>/dev/null; then
  echo "  MISSING: release exercise did not complete successfully"
  status=1
fi

echo
echo "== failure proofs: checks fail when template and text libraries are broken"
prove_fails() {
  local label="$1" dir="$2" file="$3" expected_phrase="$4" sed_script="$5"
  mkdir -p "$WORK/$dir/std"
  cp -R "$REPO/src/std/." "$WORK/$dir/std/"
  sed -e "$sed_script" "$REPO/src/std/$file" > "$WORK/$dir/std/$file"
  if cmp -s "$REPO/src/std/$file" "$WORK/$dir/std/$file"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi

  if ! IYI_PATH="$WORK/$dir:$REPO/src:$REPO/samples/iyi" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_template_text_parity_exercise.iyi" \
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

# 1. Break CSV header population: keep the raw first row instead of the
#    stripped mapping, so header lookups by name cannot resolve.
prove_fails "CSV header population" broken_csv_headers "csv.iyi" "Missing header: First Name" \
  's/@headers = first[.]map { [|]h[|] h[.]strip }/@headers = first/'

# 2. Break HTML escaping of the ampersand in the string fast path.
prove_fails "HTML ampersand escape" broken_html_amp "html.iyi" "html: escape ampersand" \
  's/bytes << 38_u8; bytes << 97_u8; bytes << 109_u8/bytes << 38_u8; bytes << 98_u8; bytes << 109_u8/'

# 3. Break MIME registry defaults so .html no longer maps to its full type.
prove_fails "MIME registry defaults" broken_mime_registry "mime.iyi" "mime: html default" \
  's|register("[.]html", "text/html; charset=utf-8")|register(".html", "text/html")|'

# 4. Break OptionParser inline long-option values (--name=NAME).
prove_fails "OptionParser inline value" broken_opt_inline "option_parser.iyi" \
  "Invalid option: --name=iyi_test" \
  "s/eq = arg[.]index('=')/eq = arg.index('?')/"

# 5. Break INI key/value splitting on '='.
prove_fails "INI key/value split" broken_ini_split "ini.iyi" "Expected declaration" \
  's/raw\[i\] == 61_u8/raw[i] == 62_u8/'

# 6. Break ECR tag detection so templates lex as plain strings.
prove_fails "ECR tag detection" broken_ecr_tags "ecr.iyi" "ecr: tok1 string" \
  's/b == 60_u8 && peek_byte == 37_u8/b == 60_u8 \&\& peek_byte == 38_u8/'

echo
if [ "$status" -eq 0 ]; then
  echo "SUCCESS: template and text parity exercise verified with plain and release"
  echo "builds, and every mutation proof caught its intended failure."
else
  echo "FAILURE: template and text parity exercise reported failures above."
fi

exit "$status"
