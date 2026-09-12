#!/usr/bin/env bash
# RFC 5849 (OAuth 1.0) and RFC 6749 (OAuth 2.0) standard library parity exercise driver.
# Runs the OAuth parity exercise in plain and release mode, checks every section
# reported, and proves the checks can fail by patching copies of std/{oauth,oauth2}.iyi.
#
#     bash bench/std_oauth_parity_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across:
#   1. RFC 5849 Section 1.2 initiate vector (HMAC-SHA1 signature mismatch detected)
#   2. RFC 5849 Section 3.4.1.1 base string construction (separator corruption detected)
#   3. draft-ietf-oauth-v2-http-mac Section 3.1 MAC vector (normalization corruption detected)
#   4. RFC 6750 Bearer token authorization header format (Bearer prefix mismatch detected)
#   5. OAuth2::Session auto-refresh expiration logic (expired token bypass detected)
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
  if ! IYI_PATH="$REPO/src" "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_oauth_parity_exercise.iyi" \
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

echo "== std/oauth and std/oauth2 parity exercise, plain build"
run_case "plain" oauth-plain
if ! grep -q "all std/oauth and std/oauth2 checks passed" "$WORK/oauth-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every parity section reported"
for phrase in "rfc5849_section1_2:" "rfc5849_section3_4:" "rfc6749_vectors:" "mac_vectors:" "oauth1_flow:" "oauth2_client_grants:" "oauth2_session_refresh:" "error_shapes:"; do
  grep -q "$phrase" "$WORK/oauth-plain.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  rfc5849_section1_2, rfc5849_section3_4, rfc6749_vectors, mac_vectors, oauth1_flow, oauth2_client_grants, oauth2_session_refresh, and error_shapes all reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" oauth-release --release
if ! grep -q "all std/oauth and std/oauth2 checks passed" "$WORK/oauth-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving the checks can fail when OAuth protocol protections are broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" target_file="$4" sed_script="$5"
  mkdir -p "$WORK/$dir/std"
  # Copy sibling files so all standard modules are reachable
  cp "$REPO/src/std/"*.iyi "$WORK/$dir/std/"
  sed -e "$sed_script" "$REPO/src/std/$target_file" > "$WORK/$dir/std/$target_file"
  if cmp -s "$REPO/src/std/$target_file" "$WORK/$dir/std/$target_file"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_oauth_parity_exercise.iyi" \
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

# 1. RFC 5849 Section 1.2 initiate vector corrupted (HMAC-SHA1 replaced with corrupted constant)
prove_fails "RFC 5849 initiate vector mismatch" rfc5849_initiate_corrupt \
  "assertion failed: RFC 5849 Section 1.2 initiate vector" "oauth.iyi" \
  's/HMAC\.digest(:sha1,/HMAC.digest(:sha256,/'

# 2. RFC 5849 Section 3.4.1.1 base string form body parameter gathering corrupted
prove_fails "RFC 5849 form body parameter gathering" rfc5849_base_corrupt \
  "assertion failed: RFC 5849 Section 3.4.1.1 base string construction" "oauth.iyi" \
  's/form_p = request\.form_params/form_p = Params.new/'

# 3. draft-ietf-oauth-v2-http-mac Section 3.1 MAC vector corrupted (separator changed from \n to space)
prove_fails "MAC vector corrupted" mac_vector_corrupt \
  "assertion failed: draft-ietf-oauth-v2-http-mac HMAC-SHA-1 vector" "oauth2.iyi" \
  's/ts [+] "\\n" [+] nonce/ts + " " + nonce/'

# 4. RFC 6750 Bearer token authorization header corrupted (Bearer prefix changed)
prove_fails "Bearer prefix corrupted" bearer_prefix_corrupt \
  "assertion failed: RFC 6750 Section 2.1 Bearer token authorization header" "oauth2.iyi" \
  's/"Bearer " [+] @access_token/"Token " + @access_token/'

# 5. OAuth2::Session auto-refresh expiration logic corrupted (stale token reported not expired)
prove_fails "Session auto-refresh bypass" session_refresh_corrupt \
  "assertion failed: Session refresh callback was invoked on expired token" "oauth2.iyi" \
  's/Time\.utc >= exp/false/'

echo
if [ "$status" -eq 0 ]; then
  echo "== all OAuth and OAuth2 parity checks and failure proofs passed"
else
  echo "== one or more OAuth parity checks failed"
fi

exit "$status"
