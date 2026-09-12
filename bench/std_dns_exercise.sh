#!/usr/bin/env bash
# DNS standard library exercise driver.
# Runs the DNS exercise in plain and release mode, checks every section
# reported, and proves the checks can fail by patching copies of std/dns.iyi.
#
#     bash bench/std_dns_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across
# anti-spoofing transaction ID verification, compression pointer loop bounding,
# forward pointer rejection, 255-octet domain name ceilings, malformed RDLENGTH
# boundary enforcement, DNSSEC digest extraction, exact casing preservation,
# and CNAME target resolution.
#
# Exits non-zero if any check fails.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0

# The compile cache is inherited rather than named here, the way every other
# driver in this directory does it. Naming one puts the other language's
# environment variable into the tree, which the identity floor refuses.
export PATH="/opt/homebrew/bin:/usr/bin:/bin"
export LIBRARY_PATH="/opt/homebrew/opt/bdw-gc/lib"

run_case() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_dns_exercise.iyi" \
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

echo "== the dns exercise, plain build"
run_case "plain" dns-plain
if ! grep -q "all std/dns checks passed" "$WORK/dns-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every dns section reported"
for phrase in \
  "message encoding:" \
  "captured wire bytes:" \
  "captured CNAME:" \
  "MX and TXT records:" \
  "SOA records:" \
  "DNSSEC records:" \
  "wire preservation:" \
  "unknown types:" \
  "pointer loops:" \
  "pointer boundaries:" \
  "name limit:" \
  "malformed packets:" \
  "anti-spoofing:" \
  "truncated response:" \
  "nameserver discovery:" \
  "cache operations:" \
  "transport seam:" \
  "live resolution:"; do
  grep -q "$phrase" "$WORK/dns-plain.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  encoding, captured wire, CNAME, MX/TXT, SOA, DNSSEC, casing, unknown types, pointer loops, pointer bounds, name limits, malformed truncation, anti-spoofing, TC bit, discovery, cache, transport seam, and live resolution all reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" dns-release --release
if ! grep -q "all std/dns checks passed" "$WORK/dns-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving the checks can fail when dns operations are broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" sed_script="$4"
  mkdir -p "$WORK/$dir/std"
  sed -e "$sed_script" "$REPO/src/std/dns.iyi" > "$WORK/$dir/std/dns.iyi"
  # A patch that matches nothing leaves the library intact, and an intact
  # library passes, which reads as "this check cannot fail" when the truth is
  # that nothing was broken to test it. Line-anchored patches drift.
  if cmp -s "$REPO/src/std/dns.iyi" "$WORK/$dir/std/dns.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_dns_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched dns library did not build"
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

# 1. Anti-spoofing transaction ID check broken
prove_fails "anti-spoofing transaction ID check broken" no_txid "anti-spoofing: mismatched transaction ID was not rejected" \
  's/if msg && msg\.id == expected_id/if msg/'

# 2. Pointer loop detection broken
prove_fails "pointer loop detection broken" no_loop "pointer loop: mutual loop not rejected" \
  's/return nil if hops > max_hops/return {".", start_pos + 2} if hops > max_hops/'
# 3. Forward pointer check broken
prove_fails "forward pointer check broken" no_fwd "forward pointer: not rejected" \
  's/ptr_offset >= pos && hops == 1/false/'

# 4. Domain name 255-octet ceiling broken
prove_fails "domain name 255-octet ceiling broken" no_ceiling "name length: names exceeding 255 octets not rejected" \
  's/return nil if total_length > 255/return {".", 0} if total_length > 255/'

# 5. Malformed packet RDLENGTH boundary check broken
prove_fails "malformed packet RDLENGTH check broken" no_rdlen "malformed: RDLENGTH past EOF not rejected" \
  's/return nil if pos + rdlength > bytes\.size/return target.size if pos + rdlength > bytes\.size/'
prove_fails "dnssec ds record digest parsing broken" no_ds "captured DS: digest hex" \
  's/DSRecord\.new(key_tag, algo, digest_type, digest)/DSRecord.new(key_tag, algo, digest_type, Bytes.empty)/'

# 7. Exact owner-name casing preservation broken
prove_fails "owner-name casing preservation broken" no_casing "casing: question casing" \
  's/name = labels\.empty[?] [?] "[.]" : labels\.join("[.]")/name = labels.empty? ? "." : labels.join(".").downcase/'
prove_fails "cname target parsing broken" no_cname "captured CNAME: ans1 cname target" \
  's/CNameRecord\.new(target_res\[0\])/CNameRecord.new("wrong.domain")/'

echo
if [ "$status" -eq 0 ]; then
  echo "all std/dns exercise checks passed and failure proofs verified"
else
  echo "std/dns exercise failed"
fi
exit "$status"
