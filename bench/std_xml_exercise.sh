#!/usr/bin/env bash
# XML standard library exercise driver.
# Runs the XML exercise in plain and release mode, checks every section
# reported, proves the checks can fail by patching copies of std/xml.iyi,
# and verifies adversarial security defenses (XXE refusal, billion-laughs
# bounding, depth limiting, and well-formedness error diagnostics).
#
#     bash bench/std_xml_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across
# XML declaration, element hierarchy, attribute indexing, content extraction,
# namespace scoping, CDATA unescaped sections, entity references, tree navigation,
# and serialization. In addition, it directly tests and proves:
#   * XXE attack attempts are refused by default (SYSTEM and PUBLIC entities)
#   * Billion laughs nested entity expansion attacks are strictly bounded
#   * Adversarial tree nesting depth attacks are halted at the depth limit
#   * Well-formedness errors name what and where (mismatched tags, duplicate
#     attributes, multiple roots, unclosed tags)
#   * Security defenses can fail if their enforcement guards are removed
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_xml_exercise.iyi" \
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

echo "== the xml exercise, plain build"
run_case "plain" xml-plain
if ! grep -q "all std/xml checks passed" "$WORK/xml-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every xml section reported"
for phrase in "xml declaration:" "element hierarchy:" "content extraction:" "namespaces:" "cdata sections:" "entity references:" "comments and processing instructions:" "tree navigation:" "tree mutation:" "serialization:"; do
  grep -q "$phrase" "$WORK/xml-plain.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  declaration, hierarchy, content, namespaces, cdata, entities, comments/PI, navigation, mutation, and serialization all reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" xml-release --release
if ! grep -q "all std/xml checks passed" "$WORK/xml-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving the checks can fail when xml operations are broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" sed_script="$4"
  mkdir -p "$WORK/$dir/std"
  sed -e "$sed_script" "$REPO/src/std/xml.iyi" > "$WORK/$dir/std/xml.iyi"
  # A patch that matches nothing leaves the library intact, and an intact
  # library passes, which reads as "this check cannot fail" when the truth is
  # that nothing was broken to test it. Line-anchored patches drift.
  if cmp -s "$REPO/src/std/xml.iyi" "$WORK/$dir/std/xml.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_xml_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched xml library did not build"
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

# 1. XML declaration encoding corrupted
prove_fails "xml declaration encoding corrupted" no_encoding "xml: doc encoding" \
  's/doc\.encoding = attr_val/doc.encoding = "corrupted"/'

# 2. Attribute value lookup returns empty string
prove_fails "attribute lookup broken" no_attr "xml: store attribute name" \
  's/return @attributes\[i\]\.value/return "wrong"/'

# 3. Content extraction returns empty string
prove_fails "content extraction broken" no_content "xml: title content" \
  's/def content : String/def content : String; return "broken"/'

# 4. Namespace prefix resolution broken
prove_fails "namespace prefix resolution broken" no_ns "xml: table resolved namespace" \
  's/def resolve_namespace_prefix(prefix : String) : Namespace[?]/def resolve_namespace_prefix(prefix : String) : Namespace?; return nil/'

# 5. CDATA content empty
prove_fails "cdata content broken" no_cdata "xml: raw cdata content" \
  's/Node\.new_cdata(parts\.join(""))/Node.new_cdata("")/'

# 6. Predefined entity decoding broken
prove_fails "entity decoding broken" no_entity "xml: predefined entities decoded" \
  's/val = @entries\[name\][?]/val = "broken"/'

# 7. Path calculation broken
prove_fails "canonical path calculation broken" no_path "xml: page 2 canonical path" \
  's/"#{parent_path}\/#{@name}\[#{index}\]"/"\/"/'

# 8. Serialization broken
prove_fails "xml serialization broken" no_ser "xml: serialized declaration" \
  's/buf\.join("")/""/'

echo
echo "== testing security defenses and well-formedness requirements"

run_adversarial_test() {
  local label="$1" code_file="$2" expected_phrase="$3"
  if ! "$IYI" build -o "$WORK/$code_file" "$WORK/$code_file.iyi" \
       >"$WORK/$code_file.build.log" 2>&1; then
    echo "  $label: test harness failed to build"
    sed -n '1,12p' "$WORK/$code_file.build.log"
    status=1
    return
  fi
  "$WORK/$code_file" >"$WORK/$code_file.out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  $label: attack succeeded (exited 0), security check was bypassed!"
    status=1
    return
  fi
  if ! grep -q "$expected_phrase" "$WORK/$code_file.out"; then
    echo "  $label: failed with wrong error (expected '$expected_phrase')"
    sed -n '$p' "$WORK/$code_file.out"
    status=1
    return
  fi
  printf '  %s: correctly refused (exits %s with "%s")\n' "$label" "$exit_code" \
    "$(grep -m1 "$expected_phrase" "$WORK/$code_file.out" | sed 's/^iyi: panic: //')"
}

# A. XXE attempt with external SYSTEM entity in DOCTYPE: must be refused
cat << 'EOF' > "$WORK/sec_xxe.iyi"
import std/xml
using std/xml::{parse}

xxe_payload = "<!DOCTYPE data SYSTEM \"file:///etc/passwd\"><data>safe</data>"
parse(xxe_payload)
EOF
run_adversarial_test "xxe external DOCTYPE refused" sec_xxe "external entity expansion is disabled: refused SYSTEM/PUBLIC DOCTYPE"

# B. XXE attempt with external SYSTEM entity in internal subset: must be refused
cat << 'EOF' > "$WORK/sec_xxe_entity.iyi"
import std/xml
using std/xml::{parse}

xxe_payload = "<!DOCTYPE test [ <!ENTITY xxe SYSTEM \"file:///etc/passwd\"> ]><test>&xxe;</test>"
parse(xxe_payload)
EOF
run_adversarial_test "xxe external entity definition refused" sec_xxe_entity "external entity expansion is disabled: refused SYSTEM/PUBLIC entity 'xxe'"

# C. Billion laughs internal nested entity expansion attack: must be bounded
cat << 'EOF' > "$WORK/sec_billion_laughs.iyi"
import std/xml
using std/xml::{parse}

lol_payload = "<!DOCTYPE lolz [ <!ENTITY lol \"lol\"> <!ENTITY lol1 \"&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;\"> <!ENTITY lol2 \"&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;\"> ]><lolz>&lol2;</lolz>"
parse(lol_payload, max_entity_expansions: 15)
EOF
run_adversarial_test "billion laughs attack bounded" sec_billion_laughs "entity expansion limit exceeded (billion laughs attack detected"

# D. Element nesting depth limit attack: must be halted
cat << 'EOF' > "$WORK/sec_depth.iyi"
import std/xml
using std/xml::{parse}

deep_payload = "<a><b><c><d><e><f/></e></d></c></b></a>"
parse(deep_payload, max_depth: 4)
EOF
run_adversarial_test "max depth limit enforced" sec_depth "maximum element depth exceeded (depth: 5, limit: 4)"

# E. Well-formedness error: mismatched closing tag
cat << 'EOF' > "$WORK/wf_mismatch.iyi"
import std/xml
using std/xml::{parse}

bad_xml = "<user><name>Alice</age></user>"
parse(bad_xml)
EOF
run_adversarial_test "mismatched closing tag detected" wf_mismatch "mismatched closing tag: expected </name>, got </age>"

# F. Well-formedness error: duplicate attribute in same start tag
cat << 'EOF' > "$WORK/wf_dup_attr.iyi"
import std/xml
using std/xml::{parse}

bad_xml = "<user id=\"1\" role=\"admin\" id=\"2\"/>"
parse(bad_xml)
EOF
run_adversarial_test "duplicate attribute detected" wf_dup_attr "duplicate attribute: 'id'"

# G. Well-formedness error: multiple root elements
cat << 'EOF' > "$WORK/wf_multiple_roots.iyi"
import std/xml
using std/xml::{parse}

bad_xml = "<first/><second/>"
parse(bad_xml)
EOF
run_adversarial_test "multiple root elements detected" wf_multiple_roots "multiple root elements: unexpected <second>"

# H. Well-formedness error: unclosed element tag
cat << 'EOF' > "$WORK/wf_unclosed.iyi"
import std/xml
using std/xml::{parse}

bad_xml = "<root><unclosed></root>"
parse(bad_xml)
EOF
run_adversarial_test "unclosed tag detected" wf_unclosed "mismatched closing tag: expected </unclosed>, got </root>"

echo
echo "== proving well-formedness and security checks can fail when bypassed"

prove_security_guard_can_fail() {
  local label="$1" dir="$2" harness_iyi="$3" sed_script="$4"
  mkdir -p "$WORK/$dir/std"
  sed -e "$sed_script" "$REPO/src/std/xml.iyi" > "$WORK/$dir/std/xml.iyi"
  # A patch that matches nothing leaves the library intact, and an intact
  # library passes, which reads as "this check cannot fail" when the truth is
  # that nothing was broken to test it. Line-anchored patches drift.
  if cmp -s "$REPO/src/std/xml.iyi" "$WORK/$dir/std/xml.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$WORK/$harness_iyi.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched xml library did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    echo "  $label: the security test still caught the violation even when guard was removed (did not prove failure)"
    status=1
    return
  fi
  echo "  $label: verified guard is load-bearing (bypassing guard allows attack to pass with exit 0)"
}

# 1. Proving the duplicate attribute check can fail if the check is bypassed
prove_security_guard_can_fail "duplicate attribute check can fail" bypass_dup wf_dup_attr \
  's/seen_attrs\[attr_name\] = true/# bypassed/'

# 2. Proving the mismatched closing tag check can fail if the check is bypassed
prove_security_guard_can_fail "mismatched tag check can fail" bypass_mismatch wf_mismatch \
  's/if closing_name != elem_name/if false/'

# 3. Proving the XXE refusal check can fail if external entities are allowed
prove_security_guard_can_fail "xxe refusal check can fail" bypass_xxe sec_xxe \
  's/if @refuse_external_entities/if false/'

echo
if [ "$status" -eq 0 ]; then
  echo "all std/xml checks and security proofs passed"
else
  echo "some std/xml checks failed"
fi
exit "$status"
