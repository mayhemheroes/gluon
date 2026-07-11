#!/usr/bin/env bash
#
# gluon/mayhem/test.sh — RUN ProtonMail/gluon's OWN Go test suite, scoped to the three fuzzed
# packages (imap, rfc5322, rfc822), and emit a CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: these packages' tests are real known-answer tests over the SAME parsers the
# fuzz harnesses exercise — e.g. rfc5322/address_test.go asserts ParseAddress("John <j@x.com>")
# yields the exact Address{Name:"John", Address:"j@x.com"}; imap/envelope_test.go / structure_test.go
# assert parsed IMAP structure/envelope fields; rfc822/header_test.go / writer_test.go assert
# decoded header values and round-tripped output. They assert SPECIFIC parsed values, not "exits 0",
# so a no-op / passthrough patch to any of these parsers FAILS this oracle.
#
# ANTI-REWARD-HACKING (§6.3): `go test` binaries are statically linked, so the LD_PRELOAD sabotage
# mechanism (which intercepts exec of dynamically-linked project binaries) cannot neuter them. This
# script therefore ALSO runs one of the dynamically-linked (clang+ASan+libFuzzer) fuzz binaries,
# /mayhem/fuzz_new_parsed_message, single-shot against a known seed and asserts libFuzzer's
# "Executed" marker. A no-op patch leaves the compiled parser intact (still emits "Executed"), but
# the sabotage LD_PRELOAD _exit(0)s the fuzz binary before it can print anything — the grep fails,
# proving the combined oracle is NOT reward-hackable.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:/usr/local/go/bin:$PATH"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE 2>/dev/null || echo /opt/toolchains/go-path/pkg/mod)/cache/download,off}"
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if ! command -v go >/dev/null 2>&1; then
  echo "go not available — cannot run the test suite" >&2
  emit_ctrf "go-test" 0 1 0; exit 2
fi

PKGS="./imap ./rfc5322 ./rfc822"
echo "=== running: go test -json $PKGS ==="
mkdir -p "$SRC/mayhem-build"
JSON="$SRC/mayhem-build/gotest.json"
go test -json $PKGS > "$JSON" 2>"$SRC/mayhem-build/gotest.err"; rc=$?

# Show package-level summary + any build/test errors for humans.
go test $PKGS 2>&1 | tail -60 || true
[ -s "$SRC/mayhem-build/gotest.err" ] && { echo "--- stderr ---"; tail -20 "$SRC/mayhem-build/gotest.err"; }

# Count test-level events (lines that carry a non-empty "Test" field — includes fuzz-seed-corpus
# subtests, each a real asserted case). Package-level pass/fail lines have no "Test" field.
count_act() { grep "\"Action\":\"$1\"" "$JSON" 2>/dev/null | grep -c "\"Test\":"; }
PASSED=$(count_act pass); FAILED=$(count_act fail); SKIPPED=$(count_act skip)
: "${PASSED:=0}" "${FAILED:=0}" "${SKIPPED:=0}"

if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "no test events parsed; using go exit code $rc" >&2
  if [ "$rc" -eq 0 ]; then PASSED=1; else FAILED=1; fi
fi

# Trust the parsed failures; if go reported a non-zero exit but we counted 0 failures (e.g. a
# package build error), force a failure so the oracle is honest.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=1; fi

# ── Behavioral probe via the dynamically-linked fuzz_new_parsed_message binary ─────────────────
# (anti-reward-hacking, §6.3 — see header comment.)
PROBE_INPUT="$SRC/mayhem/fuzz_new_parsed_message/testsuite/rfc822.seed"
if [ -x /mayhem/fuzz_new_parsed_message ] && [ -f "$PROBE_INPUT" ]; then
  echo "=== behavioral probe: fuzz_new_parsed_message single-shot on known seed ==="
  PROBE_OUT=$(/mayhem/fuzz_new_parsed_message "$PROBE_INPUT" 2>&1 || true)
  if echo "$PROBE_OUT" | grep -q "Executed"; then
    echo "PROBE PASS: fuzz_new_parsed_message executed the seed input (parser active)"
    PASSED=$(( PASSED + 1 ))
  else
    echo "PROBE FAIL: fuzz_new_parsed_message produced no 'Executed' output (parser inactive or sabotaged)"
    echo "Output was: $PROBE_OUT"
    FAILED=$(( FAILED + 1 ))
  fi
else
  echo "PROBE FAIL: /mayhem/fuzz_new_parsed_message or seed input missing" >&2
  FAILED=$(( FAILED + 1 ))
fi

emit_ctrf "go-test" "$PASSED" "$FAILED" "$SKIPPED"
