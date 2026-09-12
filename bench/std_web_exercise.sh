#!/usr/bin/env bash
# Web standard library exercise driver.
# Runs the web exercise in plain and release mode, checks every section
# reported, and proves the checks can fail by patching copies of std/uri.iyi,
# std/mime.iyi, and std/html.iyi.
#
#     bash bench/std_web_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across
# percent-encoding double-encode prevention, truncated percent escape rejection,
# relative URI reference resolution, dot segment removal, HTML entity escaping,
# HTML named entity unescaping, and MIME media type parameter parsing.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_web_exercise.iyi" \
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

echo "== the web exercise, plain build"
run_case "plain" web-plain
if ! grep -q "all std/web checks passed" "$WORK/web-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every web section reported"
for phrase in "percent-encoding:" "uri and params:" "dot segments and normalisation:" "RFC 3986 section 5.4:" "media types and mime registry:" "html escaping:"; do
  grep -q "$phrase" "$WORK/web-plain.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  percent-encoding, uri, params, dot segments, RFC 3986, mime, and html all reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" web-release --release
if ! grep -q "all std/web checks passed" "$WORK/web-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving the checks can fail when web operations are broken"

prove_fails() {
  local label="$1" dir="$2" file="$3" phrase="$4" sed_script="$5"
  mkdir -p "$WORK/$dir/std"
  # Copy all std files first
  cp -r "$REPO/src/std/"* "$WORK/$dir/std/"
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
       -o "$WORK/$dir/program" "$REPO/bench/std_web_exercise.iyi" \
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

# 1. Percent-encoding double-encode check broken
prove_fails "percent double encoding broken" no_double_enc "uri.iyi" \
  "percent: double-encoded already encoded string" \
  's/if i + 2 < len && hex_digit[?](raw\[i + 1\])/if false/'

# 2. Percent-decoding truncated check broken
prove_fails "percent truncated escape check broken" no_truncated_reject "uri.iyi" \
  "trap: truncated % not rejected" \
  's/return nil/return "not_nil"/'

# 3. Relative reference resolution broken
prove_fails "relative resolution broken" no_resolve "uri.iyi" \
  "RFC 3986 resolution failure" \
  's/def resolve(ref : URI | String) : URI/def resolve(ref : URI | String) : URI; return self/'

# 4. Dot segment removal broken
prove_fails "dot segment removal broken" no_dot_seg "uri.iyi" \
  "dots: /a/b/../c" \
  's/def self\.remove_dot_segments(path : String) : String/def self.remove_dot_segments(path : String) : String; return path/'

# 5. HTML escape broken
prove_fails "html escape broken" no_html_escape "html.iyi" \
  "html: escape mismatch" \
  's/bytes << 38_u8; bytes << 97_u8; bytes << 109_u8; bytes << 112_u8; bytes << 59_u8/bytes << 38_u8/'

# 6. HTML unescape broken
prove_fails "html unescape broken" no_html_unescape "html.iyi" \
  "html: unescape named mismatch" \
  's/def self\.named_entity_codepoint(name : String) : Int32/def self.named_entity_codepoint(name : String) : Int32; return -1/'

# 7. MIME media type parameter parsing broken
prove_fails "mime parameter parsing broken" no_mime_params "mime.iyi" \
  "missing media type parameter: charset" \
  's/params\[key_str\] = val_str/nil/'

echo
if [ "$status" -eq 0 ]; then
  echo "Web standard library: RFC 3986 URI parsing and resolution, percent encoding,"
  echo "MIME media types with parameters, and HTML escaping all pass plain and optimised,"
  echo "and each check is proven to fail when its mechanism is broken."
else
  echo "Web standard library: something above failed."
fi
exit "$status"
