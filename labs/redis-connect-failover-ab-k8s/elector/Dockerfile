# syntax=docker/dockerfile:1.7
ARG BASE_REGISTRY=""
FROM ${BASE_REGISTRY}golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/elector .

ARG BASE_REGISTRY=""
FROM ${BASE_REGISTRY}alpine:3.20
RUN apk add --no-cache tini ca-certificates \
 && adduser -D -u 10001 app
USER app
COPY --from=build /out/elector /usr/local/bin/elector
# tini is PID 1; elector is a child PID so SIGSTOP/SIGCONT (Proof B1) act on it.
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/elector"]
