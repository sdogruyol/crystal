#!/usr/bin/env bash
# Exercises protocol negotiation through the public std/http_client surface.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
status=0

run_case() {
  local label="$1" name="$2"; shift 2
  if ! IYI_PATH="$REPO/src" "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_http_client_exercise.iyi" >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    sed -n '1,12p' "$WORK/$name.build.log"
    status=1
    return
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -ne 0 ]; then
    echo "$label: run exited $code"
    sed -n '1,20p' "$WORK/$name.out"
    status=1
    return
  fi
  if ! grep -q "all std/http_client checks passed" "$WORK/$name.out"; then
    echo "$label: did not reach the end"
    status=1
    return
  fi
  echo "$label: pass"
}

echo "== the protocol-negotiating HTTP client, plain build"
run_case plain plain

echo
echo "== every negotiation section reported"
for section in client-api alpn alt-svc proxy protocol-neutral; do
  if ! grep -q "$section:" "$WORK/plain.out" 2>/dev/null; then
    echo "  missing section: $section"
    status=1
  fi
done

echo
echo "== the same program with optimisation on (--release)"
run_case release release --release

prove_fails() {
  local label="$1" dir="$2" phrase="$3" sed_script="$4"
  mkdir -p "$WORK/$dir/std"
  sed -e "$sed_script" "$REPO/src/std/http_client.iyi" >"$WORK/$dir/std/http_client.iyi"
  if cmp -s "$REPO/src/std/http_client.iyi" "$WORK/$dir/std/http_client.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build -o "$WORK/$dir/program" "$REPO/bench/std_http_client_exercise.iyi" >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched client did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -ne 1 ]; then
    echo "  $label: expected exit 1, got $exit_code"
    status=1
    return
  fi
  if ! grep -q "$phrase" "$WORK/$dir/out"; then
    echo "  $label: failed away from '$phrase'"
    sed -n '$p' "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits 1 at "%s"\n' "$label" "$(grep -m1 "$phrase" "$WORK/$dir/out")"
}

echo
echo "== proving negotiation decisions are load-bearing"
prove_fails "ALPN h2 offer removed" no_h2 \
  "assertion failed: origin selected unoffered protocol h2" \
  's/offers = scheme == "https" [?] \[Protocol::HTTP2, Protocol::HTTP1\] : \[Protocol::HTTP1\]/offers = [Protocol::HTTP1]/'
prove_fails "Alt-Svc h3 route ignored" no_h3 \
  "assertion failed: second request uses learned HTTP\/3 transport" \
  's/if http3 = @http3/if http3 = nil.as(Upstream?)/'
prove_fails "proxy precedence bypassed" no_proxy \
  "assertion failed: proxy response returned" \
  's/if proxy = @proxy/if proxy = nil.as(Upstream?)/'
prove_fails "Alt-Svc ma zero accepted" stale_h3 \
  "assertion failed: ma=0 clears HTTP\/3 route" \
  's/max_age = parsed$/max_age = parsed == 0_i64 ? 60_i64 : parsed/'

echo
if [ "$status" -eq 0 ]; then
  echo "HTTP client negotiation: one Request and Response surface, TLS ALPN h2/http1," 
  echo "Alt-Svc h3, and upstream proxy selection all pass plain and release, and each"
  echo "decision is proven to fail when bypassed."
else
  echo "HTTP client negotiation: something above failed."
fi
exit "$status"
