#!/usr/bin/env bash
# HTTP/1.1 standard library exercise driver.
# Runs the HTTP exercise in plain and release mode, checks every section
# reported, and proves the checks can fail by patching copies of std/http.iyi.
#
#     bash bench/std_http_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across
# request smuggling (dual CL/TE in request and response, conflicting CL in request
# and response), header injection (CR/LF in value and invalid chars in name),
# bounds enforcement (request line, header count, 32-bit Content-Length bound),
# chunked parsing (hex validation, final zero chunk), repetition rules, cookie
# attributes, strict CRLF enforcement, obs-fold, whitespace before colon,
# mandatory and unique Host header, final chunked coding, forbidden trailers,
# and persistent response framing.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_http_exercise.iyi" \
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

echo "== the HTTP exercise, plain build"
run_case "plain" http-plain
if ! grep -q "all std/http checks passed" "$WORK/http-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every HTTP section reported"
for phrase in "status codes:" "headers:" "repetition rules:" "header injection:" "request smuggling:" "bounds:" "chunked parsing:" "roundtrip: full request" "roundtrip: Content-Length" "keep-alive:" "cookie parsing:" "params:" "strict CRLF:" "RFC 9112 Section 5.1/5.2:" "Host header:" "Transfer-Encoding:" "forbidden trailers:" "Content-Length:" "persistent response framing:"; do
  grep -q "$phrase" "$WORK/http-plain.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  status, headers, repetition, injection, smuggling, bounds, chunked, roundtrips, keep-alive, cookies, params, CRLF, obs-fold, Host, TE, trailers, CL bounds, and persistent framing all reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" http-release --release
if ! grep -q "all std/http checks passed" "$WORK/http-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving the checks can fail when HTTP security and protocol invariants are broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" sed_script="$4"
  mkdir -p "$WORK/$dir/std"
  sed -e "$sed_script" "$REPO/src/std/http.iyi" > "$WORK/$dir/std/http.iyi"
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_http_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched HTTP library did not build"
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

# 1. Request smuggling: dual CL and TE in Request
prove_fails "request smuggling dual CL/TE in request broken" no_smuggle_cl_te_req "smuggling with both CL and TE in request was not rejected" \
  '/# GUARD: request dual CL\/TE/{n;s/if has_cl && has_te/if false/;}'

# 2. Request smuggling: dual CL and TE in Response
prove_fails "request smuggling dual CL/TE in response broken" no_smuggle_cl_te_resp "smuggling with both CL and TE in response was not rejected" \
  '/# GUARD: response dual CL\/TE/{n;s/if has_cl && has_te/if false/;}'

# 3. Request smuggling: conflicting CL in Request
prove_fails "request smuggling conflicting CL in request broken" no_smuggle_cl_req "smuggling with conflicting CL in request was not rejected" \
  '/# GUARD: request conflicting CL/{n;s/if has_cl/if false/;}
   /# GUARD: headers conflicting CL/{n;s/if lower == "content-length"/if false/;}'

# 4. Request smuggling: conflicting CL in Response
prove_fails "request smuggling conflicting CL in response broken" no_smuggle_cl_resp "smuggling with conflicting CL in response was not rejected" \
  '/# GUARD: response conflicting CL/{n;s/if has_cl/if false/;}
   /# GUARD: headers conflicting CL/{n;s/if lower == "content-length"/if false/;}'

# 5. Header injection: CR in header value
prove_fails "header injection CR in value broken" no_inj_cr "CR header injection was not rejected" \
  's/b == 13_u8 || b == 10_u8/false/'

# 6. Header injection: invalid char in header name
prove_fails "header injection invalid name char broken" no_inj_name "bad name injection was not rejected" \
  's/b <= 32_u8 || b >= 127_u8 || b == 58_u8/false/'

# 7. Bounds: request line length limit
prove_fails "request line length bounds broken" no_line_bound "oversized request line was not rejected" \
  's/req_line.bytesize > MAX_REQUEST_LINE_SIZE/false/'

# 8. Bounds: header count limit
prove_fails "header count bounds broken" no_count_bound "oversized header count was not rejected" \
  's/header_count > MAX_HEADER_COUNT/false/'

# 9. Chunked parsing: non-hex chunk size check
prove_fails "chunked non-hex size check broken" no_hex_check "bad hex chunk was not rejected" \
  '/# GUARD: chunk hex validation/,+7{s/if !valid_hex/if false/; s/if chunk_size_raw\.nil[?]/chunk_size_raw = chunk_size_raw || 5_i64; if chunk_size_raw.nil?/;}'
# 10. Chunked parsing: missing final zero chunk check
prove_fails "chunked missing final zero check broken" no_zero_check "missing final zero chunk was not rejected" \
  '/# GUARD: chunk final zero/{n;s/return HttpError\.new("Incomplete chunked body: missing final zero chunk") unless nl/return {"", trailers} unless nl/;}'

# 11. Header repetition rules: single-value header replaced
prove_fails "header repetition rules broken" no_repetition "Content-Type should not repeat" \
  's/if Headers\.can_repeat[?](name)/if true/'

# 12. Cookie SameSite parsing
prove_fails "cookie SameSite parsing broken" no_samesite "parsed cookie samesite" \
  's/samesite = SameSite\.parse[?](attr_val)/samesite = nil.as(SameSite?)/'

# 13. Strict CRLF: bare LF in request line
prove_fails "strict CRLF request line check broken" no_crlf_req "bare LF in request line was not rejected" \
  '/# GUARD: request line bare LF/{n;s/if line_end == 0 || raw\.to_unsafe\[line_end - 1\] != 13_u8/if false/;}'

# 14. Strict CRLF: bare LF in status line
prove_fails "strict CRLF status line check broken" no_crlf_status "bare LF in status line was not rejected" \
  '/# GUARD: response status line bare LF/{n;s/if line_end == 0 || raw\.to_unsafe\[line_end - 1\] != 13_u8/if false/;}'

# 15. RFC 9112 Section 5.2: obs-fold in header
prove_fails "obs-fold in header check broken" no_obs_fold "obs-fold in header was not rejected" \
  's/return HttpError\.new("Request smuggling: obsolete line folding (obs-fold) rejected")/next/'

# 16. RFC 9112 Section 5.1: whitespace before colon in header
prove_fails "whitespace before colon check broken" no_ws_colon "whitespace before colon was not rejected" \
  '/# GUARD: request whitespace before colon/,+4s/return HttpError\.new("Request smuggling: whitespace between header name and colon")/line[0, colon].strip/'
prove_fails "mandatory Host header check broken" no_mandatory_host "missing Host header was not rejected" \
  '/# GUARD: request mandatory host/{n;s/if version == "HTTP\/1\.1"/if false/;}
   s/host_val\.nil[?] || host_val\.empty[?]/false/'

# 18. RFC 9112 Section 3.2: multiple Host headers in HTTP/1.1
prove_fails "multiple Host headers check broken" no_multi_host "multiple Host headers was not rejected" \
  '/# GUARD: request multiple host/{n;s/if has_host/if false/;}'

# 19. RFC 9112 Section 6.1: Transfer-Encoding final chunked coding
prove_fails "Transfer-Encoding final chunked check broken" no_final_te "non-final chunked was not rejected" \
  's/if codings\[codings\.size - 1\] != "chunked"/if false/; s/if c != "chunked"/if false/'
# 20. RFC 9112 Section 7.1.2: forbidden trailer header
prove_fails "forbidden trailer header check broken" no_forbid_trailer "forbidden trailer Host was not rejected" \
  '/# GUARD: trailer forbidden headers/{n;s/if Std::Http\.is_forbidden_trailer[?](t_k)/if false/;}'

# 21. Content-Length 32-bit bound enforcement before conversion
prove_fails "Content-Length 32-bit bound check broken" no_cl_bound "oversized Content-Length was not rejected" \
  's/if cl_num > 2147483647_i64/if false/'
# 22. RFC 9112 Section 6.3: persistent response framing
prove_fails "persistent response framing check broken" no_unframed_resp "unframed persistent response was not rejected" \
  '/# GUARD: response persistent framing/{n;s/if is_persistent && !body_forbidden && !has_cl && !has_te/if false/;}
   /# GUARD: parse_body persistent framing/{n;s/if is_persistent_response/if false/;}'

echo
if [ "$status" -eq 0 ]; then
  echo "HTTP standard library: Status, Headers, Request, Response, wire format, chunked encoding,"
  echo "smuggling guards, injection guards, bounds limits, keep-alive, cookies, and params all pass plain"
  echo "and optimised, and each check is proven to fail when its mechanism is broken."
else
  echo "HTTP standard library exercise: one or more checks failed" 1>&2
fi
exit "$status"
