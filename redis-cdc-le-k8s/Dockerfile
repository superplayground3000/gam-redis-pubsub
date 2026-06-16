# syntax=docker/dockerfile:1.7
# Single image for ALL lab Go programs. Default entrypoint idles on `sleep
# infinity`; each k8s manifest overrides `command:` to run a specific binary.
ARG BASE_REGISTRY=""
FROM ${BASE_REGISTRY}golang:1.25-alpine AS build
WORKDIR /src
# Single module → single binary. go.sum is gitignored and never copied in, so we
# regenerate the full module graph's checksums in-layer with `go mod download all`
# (the module-mode analog of the old `go work sync`; a plain `go build` or no-arg
# `go mod download` fails on missing go.sum entries). Download is its own layer so
# source-only edits don't re-resolve deps. BuildKit cache mounts reuse caches.
COPY go.mod ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download all
COPY main.go ./
COPY internal/ ./internal/
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/app .

ARG BASE_REGISTRY=""
FROM ${BASE_REGISTRY}alpine:3.20
# Union of the runtime deps the separate images needed: tini (elector PID1),
# wget (writer/initContainer probes), ca-certificates (all).
RUN apk add --no-cache ca-certificates tini wget \
 && adduser -D -u 10001 app
USER app
COPY --from=build /out/app /usr/local/bin/app
# Idle by default; manifests MUST set `command:` to run a real binary.
ENTRYPOINT ["sleep", "infinity"]
