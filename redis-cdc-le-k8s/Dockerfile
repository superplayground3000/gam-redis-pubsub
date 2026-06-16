# syntax=docker/dockerfile:1.7
# Single image for ALL lab Go programs. Default entrypoint idles on `sleep
# infinity`; each k8s manifest overrides `command:` to run a specific binary.
ARG BASE_REGISTRY=""
FROM ${BASE_REGISTRY}golang:1.25-alpine AS build
WORKDIR /src
# go.sum / go.work.sum are gitignored repo-wide and never copied in. In workspace
# mode `-mod=mod` is illegal, so `go work sync` (re)generates go.work.sum in-layer
# before the readonly workspace build, mirroring how the old per-module Dockerfiles
# relied on `go mod download` to regenerate go.sum.
# Workspace + all module sources (BuildKit cache mounts handle module/build cache).
COPY go.work ./
COPY writer/ ./writer/
COPY verifier/ ./verifier/
COPY elector/ ./elector/
COPY dashboard/ ./dashboard/
COPY latency-calculator/ ./latency-calculator/
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    set -eux; \
    go work sync; \
    for app in writer verifier elector dashboard latency-calculator; do \
      CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/$app ./$app; \
    done

ARG BASE_REGISTRY=""
FROM ${BASE_REGISTRY}alpine:3.20
# Union of the runtime deps the separate images needed: tini (elector PID1),
# wget (writer/initContainer probes), ca-certificates (all).
RUN apk add --no-cache ca-certificates tini wget \
 && adduser -D -u 10001 app
USER app
COPY --from=build /out/ /usr/local/bin/
# Idle by default; manifests MUST set `command:` to run a real binary.
ENTRYPOINT ["sleep", "infinity"]
