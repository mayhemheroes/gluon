# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) — builds ON TOP of the org C/C++ base image
# (ghcr.io/mayhemheroes/base). The base provides debian + clang/llvm + libFuzzer + the
# identities + the build-contract ENV. ProtonMail/gluon is a pure-Go project, so the base
# (C/C++ only — NO Go toolchain) needs Go added here as a USER root step, then the OSS-Fuzz
# Go fuzzing tooling (go-118-fuzz-build) that turns gluon's NATIVE go fuzz harnesses
# (func FuzzX(f *testing.F), already shipped in gluon's own _test.go files) into
# libFuzzer-instrumented binaries linked with $LIB_FUZZING_ENGINE.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t gluon-commit:test .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never bake it as ENV — an empty value
# breaks clang. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# NOTE: the OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); the Go fuzz
# binary is built with ASan and links the libFuzzer engine. build.sh handles the Go specifics.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# Pin the Go toolchain version + tarball sha256. gluon's go.mod requires `go 1.26.1` and pins
# `toolchain go1.26.4` — with GOTOOLCHAIN=local we must install >= that exact toolchain so the
# offline re-run never needs to fetch a newer one.
ARG GO_VERSION=1.26.4
ARG GO_SHA256=1153d3d50e0ac764b447adfe05c2bcf08e889d42a02e0fe0259bd47f6733ad7f

# ── Go toolchain @ a FIXED, lockable, $HOME-independent prefix ──────────────────────────────────
# SPEC §6.2 item 8 + §6.5: the commit build and the offline PATCH re-run run under different
# $HOMEs. Pinning GOROOT/GOPATH/GOMODCACHE/GOCACHE under /opt/toolchains ensures the module
# cache populated during the first (online) image build is found again when build.sh re-runs
# offline (--network none).
ENV GOROOT=/opt/toolchains/go \
    GOPATH=/opt/toolchains/go-path \
    GOMODCACHE=/opt/toolchains/go-path/pkg/mod \
    GOCACHE=/opt/toolchains/go-path/build-cache \
    GOTOOLCHAIN=local \
    GOFLAGS=-mod=mod \
    PATH=/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:/usr/local/bin:/usr/bin:/bin

# ── Install Go + the OSS-Fuzz Go fuzzing build tool (root step) ────────────────────────────────
# Replicates OSS-Fuzz base-builder-go's install_go.sh:
#   * official go tarball -> /opt/toolchains/go (PATH'd), sha256-verified
#   * go-118-fuzz-build — builds the NATIVE `func FuzzX(f *testing.F)` harness (gluon's OSS-Fuzz
#     targets: imap.FuzzNewParsedMessage, rfc5322.FuzzParseAddress, rfc5322.FuzzRFC5322,
#     rfc822.FuzzParseDec — all already in gluon's own _test.go files, compile_native_go_fuzzer)
USER root
RUN install -d /opt/toolchains/go-path \
    && wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tgz \
    && echo "${GO_SHA256}  /tmp/go.tgz" | sha256sum -c - \
    && tar -C /opt/toolchains -xzf /tmp/go.tgz && rm /tmp/go.tgz \
    && go version \
    && go install github.com/AdamKorcz/go-118-fuzz-build@latest \
    && ls -la "$(go env GOPATH)/bin" \
    && chmod -R a+rX /opt/toolchains/go \
    && chown -R 2000:2000 /opt/toolchains/go-path \
    && go clean -cache 2>/dev/null || true

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history)
# is copied to /mayhem as `mayhem`; build.sh builds in place.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run gluon's own Go test suite (scoped to the fuzzed packages) at build time — a failing
# suite fails the image build.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
