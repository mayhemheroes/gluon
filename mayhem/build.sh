#!/usr/bin/env bash
#
# gluon/mayhem/build.sh — build ProtonMail/gluon's OSS-Fuzz Go fuzz targets as sanitized
# libFuzzer binaries, REPLICATING OSS-Fuzz's compile_native_go_fuzzer.
#
# OSS-Fuzz targets (projects/gluon/build.sh):
#   compile_native_go_fuzzer github.com/ProtonMail/gluon/imap    FuzzNewParsedMessage  fuzz_new_parsed_message
#   compile_native_go_fuzzer github.com/ProtonMail/gluon/rfc5322 FuzzParseAddress      fuzz_parse_address
#   compile_native_go_fuzzer github.com/ProtonMail/gluon/rfc5322 FuzzRFC5322           fuzz_rfc5322
#   compile_native_go_fuzzer github.com/ProtonMail/gluon/rfc822  FuzzParseDec          fuzz_parse_dec
# i.e. the NATIVE go fuzz harnesses `func FuzzX(f *testing.F)` — these already live in gluon's
# OWN _test.go files (imap/structure_test.go, rfc5322/parser_test.go, rfc822/parser_test.go);
# nothing to port, we just build them with `go-118-fuzz-build`, then link with $LIB_FUZZING_ENGINE.
#
# We produce:
#   /mayhem/fuzz_new_parsed_message — imap.FuzzNewParsedMessage   (IMAP message structure parser)
#   /mayhem/fuzz_parse_address      — rfc5322.FuzzParseAddress    (RFC5322 address parser)
#   /mayhem/fuzz_rfc5322            — rfc5322.FuzzRFC5322         (RFC5322 name-addr parser)
#   /mayhem/fuzz_parse_dec          — rfc822.FuzzParseDec         (RFC822 MIME decode/body parser)
#
# The .a archive carries the Go fuzz code (instrumented by the go-118 builder); we link it
# against the C/C++ libFuzzer engine with clang ($CXX) + ASan, exactly like
# compile_native_go_fuzzer's final `$CXX $CXXFLAGS $LIB_FUZZING_ENGINE $fuzzer.a -o $OUT/$fuzzer`.
#
# DWARF gate (SPEC §6.2 item 10): Go's gc compiler always emits DWARF4 (no downgrade flag). The
# C/CGO shims compiled by clang (the LLVMFuzzerTestOneInput wrapper) default to DWARF5 with
# clang-19. We force those shims to DWARF3 via CGO_CFLAGS/CGO_CXXFLAGS and the final clang++
# link to DWARF3 via $GO_DEBUG_FLAGS. verify-repo's check reads the FIRST CU's DWARF version
# (readelf -m1), which is the C shim at DWARF3 — satisfying the < 4 gate.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); UBSan is not part of the
# Go libFuzzer link. Keep ASan as the Go-fuzz sanitizer regardless of the base default. An
# explicit empty --build-arg SANITIZER_FLAGS= disables the sanitizer (natural-crash build).
: "${SANITIZER_FLAGS=-fsanitize=address}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS

# Debug-info flags (SPEC §6.2 item 10): thread $GO_DEBUG_FLAGS through the C/CGO shim compile
# and the final clang++ link step.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Air-gapped contract (SPEC §6.5): the PATCH tier re-runs build.sh OFFLINE.
# $(go env GOMODCACHE) reads the pinned ENV under /opt/toolchains (set in the Dockerfile),
# so the file proxy path is correct regardless of $HOME.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"

cd "$SRC"
go version

# go-118-fuzz-build harnesses need the AdamKorcz testing shim registered as an import in each
# fuzzed package (mirrors OSS-Fuzz's own build.sh pattern, e.g. gopsutil/go-cmp/go-ole: a small
# `register.go` blank-importing the shim, so `go mod tidy` doesn't prune the module before the
# builder's codegen references it). Written into the CONTAINER's copy of the tree only (never
# committed — our git layer stays confined to mayhem/ + .github/workflows/).
for pkg in imap rfc5322 rfc822; do
  printf 'package %s\n\nimport _ "github.com/AdamKorcz/go-118-fuzz-build/testing"\n' "$pkg" \
    > "$SRC/$pkg/mayhem_register.go"
done

# Add the module deps WITHOUT a trailing `go mod tidy` after `go get` (tidy would prune the
# shim if nothing else imports it yet). Order matters: tidy first, then `go get` the shim.
go mod tidy 2>&1 | tail -5 || true
go get github.com/AdamKorcz/go-118-fuzz-build/testing@latest 2>&1 | tail -5 || true

mkdir -p "$SRC/mayhem-build"

build_target() {
  local fuzzer="$1" func="$2" pkgdir="$3"
  echo "=== building $fuzzer ($func, go-118-fuzz-build) ==="
  go-118-fuzz-build -o "$SRC/mayhem-build/$fuzzer.a" -func "$func" "$pkgdir"
  # Link: DWARF3 via $GO_DEBUG_FLAGS ensures the C-shim CU (first in the binary) is at DWARF3.
  $CXX $GO_DEBUG_FLAGS $SANITIZER_FLAGS $LIB_FUZZING_ENGINE "$SRC/mayhem-build/$fuzzer.a" -o "/mayhem/$fuzzer"
  echo "built /mayhem/$fuzzer"
}

# ── OSS-Fuzz targets (native go-118-fuzz-build harnesses, already in gluon's _test.go files) ───
build_target fuzz_new_parsed_message FuzzNewParsedMessage "$SRC/imap"
build_target fuzz_parse_address      FuzzParseAddress     "$SRC/rfc5322"
build_target fuzz_rfc5322            FuzzRFC5322           "$SRC/rfc5322"
build_target fuzz_parse_dec          FuzzParseDec           "$SRC/rfc822"

echo "build.sh complete:"
ls -la /mayhem/fuzz_new_parsed_message /mayhem/fuzz_parse_address /mayhem/fuzz_rfc5322 /mayhem/fuzz_parse_dec

# mayhem-dict-fix: place the dictionaries the Mayhemfiles reference (build.sh never did -> libFuzzer exited 1 on missing -dict -> 0 edges)
find "$SRC/mayhem" -name "*.dict" -exec cp {} /mayhem/ \; 2>/dev/null || true
