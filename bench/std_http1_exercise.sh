#!/usr/bin/env bash
# HTTP/1.1 standard library exercise driver.
# Runs the HTTP/1.1 exercise in plain and release mode, tests live round-trip
# with curl (including Expect: 100-continue), checks every section reported,
# and proves the checks can fail by patching copies of std/http1.iyi.
#
#     bash bench/std_http1_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across:
#   1. Request smuggling dual CL-TE rejection (bypassed -> must fail)
#   2. Request smuggling conflicting CL rejection (bypassed -> must fail)
#   3. Bare LF rejection in request line (bypassed -> must fail)
#   4. Non-canonical chunk size rejection (bypassed -> must fail)
#   5. Whitespace before header colon rejection (bypassed -> must fail)
#   6. Chunk data missing CRLF delimiter rejection (bypassed -> must fail)
#   7. 100-continue exchange handling (broken -> must fail)
#   8. Chunked trailer extraction (broken -> must fail)
#   9. Content-Length 64-bit integer truncation (bypassed -> must fail)
#  10. Forbidden trailer Host rejection (bypassed -> must fail)
#  11. Missing mandatory Host header in HTTP/1.1 (bypassed -> must fail)
#  12. Obsolete line folding in trailer (bypassed -> must fail)
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_http1_exercise.iyi" \
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

echo "== the HTTP/1.1 exercise, plain build"
run_case "plain" http1-plain
if ! grep -q "all std/http1 checks passed" "$WORK/http1-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every HTTP/1.1 section reported"
for phrase in "smuggling suite:" "100-continue exchange:" "chunked with trailers:" "keep-alive and pipelining:" "redirects:" "content encoding:" "socket roundtrip:" "connect tunnel:" "crlf injection:" "real network page fetch (HTTP):" "real network page fetch (HTTPS):"; do
  grep -q "$phrase" "$WORK/http1-plain.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  smuggling suite, 100-continue, chunked with trailers, keep-alive, pipelining, redirects, compression, socket roundtrip, connect tunnel, crlf injection, HTTP fetch, and HTTPS (TLS 1.3, verify_peer: true) fetch all reported"

echo
echo "== testing live server with curl"
if command -v curl >/dev/null 2>&1; then
  cat << 'EOF' > "$WORK/curl_server.iyi"
import std/http
import std/http1

using std/http::{Response}
using std/http1::{Server}

server = Server.new("127.0.0.1", 0) do |req|
  case req.target
  when "/hello"
    Response.new(200, body: "Hello from curl test!")
  when "/post-echo"
    Response.new(200, body: "curl-echo:" + req.body)
  else
    Response.new(404, body: "Not Found")
  end
end

server.listen
port = server.port
puts "PORT:#{port}"

# Accept three requests (GET, POST, and POST with Expect: 100-continue)
server.accept_one
server.accept_one
server.accept_one
server.stop
EOF

  if ! IYI_PATH="$REPO/src" "$IYI" build -o "$WORK/curl_server" "$WORK/curl_server.iyi" >"$WORK/curl_server.build.log" 2>&1; then
    echo "  curl test: server build failed"
    sed -n '1,12p' "$WORK/curl_server.build.log"
    status=1
  else
    # Start server in background
    "$WORK/curl_server" > "$WORK/curl_server.out" 2>&1 &
    SERVER_PID=$!

    # Wait for PORT line
    port=""
    for _ in $(seq 1 50); do
      if grep -q "PORT:" "$WORK/curl_server.out" 2>/dev/null; then
        port=$(grep "PORT:" "$WORK/curl_server.out" | head -n1 | cut -d: -f2)
        break
      fi
      sleep 0.1
    done

    if [ -z "$port" ]; then
      echo "  curl test: server did not output port"
      kill "$SERVER_PID" 2>/dev/null || true
      status=1
    else
      # 1. Test curl GET
      curl_get=$(curl -s -i "http://127.0.0.1:$port/hello" 2>&1)
      if echo "$curl_get" | grep -q "200 OK" && echo "$curl_get" | grep -q "Hello from curl test!"; then
        echo "  curl GET /hello: HTTP 200 OK verified"
      else
        echo "  curl GET /hello failed:"
        echo "$curl_get"
        status=1
      fi

      # 2. Test curl POST
      curl_post=$(curl -s -i -X POST -d "payload from curl" "http://127.0.0.1:$port/post-echo" 2>&1)
      if echo "$curl_post" | grep -q "200 OK" && echo "$curl_post" | grep -q "curl-echo:payload from curl"; then
        echo "  curl POST /post-echo: HTTP 200 OK verified"
      else
        echo "  curl POST /post-echo failed:"
        echo "$curl_post"
        status=1
      fi

      # 3. Test curl Expect: 100-continue live TCP exchange
      curl_100=$(curl -s -i -H "Expect: 100-continue" -X POST -d "payload with expect continue" "http://127.0.0.1:$port/post-echo" 2>&1)
      if echo "$curl_100" | grep -q "200 OK" && echo "$curl_100" | grep -q "curl-echo:payload with expect continue"; then
        echo "  curl POST with Expect: 100-continue live TCP exchange verified"
      else
        echo "  curl POST with Expect: 100-continue failed:"
        echo "$curl_100"
        status=1
      fi

      wait "$SERVER_PID" 2>/dev/null || true
    fi
  fi
else
  echo "  curl not installed, skipping curl live test"
fi

echo
echo "== the same program with optimisation on (--release)"
run_case "release" http1-release --release
if ! grep -q "all std/http1 checks passed" "$WORK/http1-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving the checks can fail when HTTP/1.1 protections and mechanisms are broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" sed_script="$4"
  mkdir -p "$WORK/$dir/std"
  # Copy sibling standard library files
  cp "$REPO/src/std/"*.iyi "$WORK/$dir/std/"
  sed -e "$sed_script" "$REPO/src/std/http1.iyi" > "$WORK/$dir/std/http1.iyi"
  # Anchor validation guard: a patch that changes nothing proves nothing
  if cmp -s "$REPO/src/std/http1.iyi" "$WORK/$dir/std/http1.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_http1_exercise.iyi" \
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

# 1. Dual CL-TE smuggling bypass (must fail: dual CL-TE accepted)
prove_fails "smuggling dual CL/TE broken" dual_cl_te \
  "dual CL-TE was not rejected" \
  's/if has_cl && has_te/if false/'

# 2. Conflicting Content-Length smuggling bypass (must fail: conflicting CL check broken)
prove_fails "smuggling conflicting CL broken" conflict_cl \
  "wrong error for conflicting CL" \
  's/if first_cl_val != h_val/if false/'

# 3. Bare LF in request line bypass (must fail: bare LF accepted)
prove_fails "bare LF line ending broken" bare_lf \
  "bare LF in request line was not rejected" \
  's/if nl_idx == @pos || raw_ptr\[nl_idx - 1\] != 13_u8/if false/'

# 4. Non-canonical chunk size hex check bypass (must fail: non-hex chunk size accepted)
prove_fails "non-canonical chunk size broken" non_canon_chunk \
  "non-canonical chunk size was not rejected" \
  's/return HttpError\.new("Invalid chunk size: not valid hex")/chunk_size_opt = 5_i64/g'

# 5. Whitespace before header colon check bypass (must fail: whitespace colon accepted)
prove_fails "whitespace before header colon broken" ws_colon \
  "wrong error for whitespace before colon" \
  's/if colon > 0 && (line\[colon - 1\] == '\'' '\'' || line\[colon - 1\] == '\''\\t'\'')/if false/'

# 6. Chunk data missing CRLF delimiter check bypass (must fail: missing CRLF accepted)
prove_fails "chunk CRLF delimiter check broken" chunk_crlf \
  "wrong error for missing CRLF after chunk" \
  's/if crlf != "\\r\\n"/if false/'

# 7. 100-continue exchange broken (server does not emit 100 Continue)
prove_fails "100-continue server emission broken" continue_broken \
  "100-continue missing in output" \
  's/@transport\.write("HTTP\/1\.1 100 Continue\\r\\n\\r\\n")/# bypass 100/'

# 8. Chunked trailer extraction broken (server drops trailers)
prove_fails "chunked trailer extraction broken" trailer_broken \
  "server failed chunked request with trailers" \
  's/trailers = chunked_res\[1\]/trailers = Headers.new/'

# 9. Content-Length 64-bit integer truncation bypass (must fail: overflow occurs)
prove_fails "content-length 64-bit truncation broken" cl_trunc \
  "arithmetic overflow" \
  's/if cl > MAX_CHUNK_SIZE\.to_i64 || cl > 2147483647_i64/if false/'

# 10. Forbidden trailer Host bypass (must fail: forbidden trailer Host accepted)
prove_fails "forbidden trailer Host broken" trailer_host \
  "forbidden trailer Host was not rejected" \
  's/if t_lower == "host"/if false \&\& t_lower == "host"/'

# 11. Missing mandatory Host header bypass (must fail: missing Host accepted)
prove_fails "missing mandatory Host header broken" missing_host \
  "missing Host header was not rejected" \
  's/if version == "HTTP\/1\.1" && !has_host/if false/'

# 12. Obsolete line folding in trailer bypass (must fail: obs-fold in trailer accepted)
prove_fails "obs-fold in trailer broken" obs_fold_trailer \
  "obs-fold in trailer was not rejected" \
  's/if t_line\.starts_with[?]('\'' '\'') || t_line\.starts_with[?]('\''\\t'\'')/if false/'

echo
if [ "$status" -eq 0 ]; then
  echo "HTTP/1.1 standard library: client, server, wire protocol, smuggling suite,"
  echo "100-continue, chunked with trailers, keep-alive, pipelining, redirects,"
  echo "compression, live curl roundtrip, and real network fetch all pass plain"
  echo "and optimised, and each check is proven to fail when its mechanism is broken."
else
  echo "HTTP/1.1 standard library: something above failed."
fi
exit "$status"
