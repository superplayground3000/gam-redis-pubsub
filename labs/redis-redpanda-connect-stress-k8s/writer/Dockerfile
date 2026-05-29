# syntax=docker/dockerfile:1.7
ARG BASE_REGISTRY=""
FROM ${BASE_REGISTRY}golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/writer .

ARG BASE_REGISTRY=""
FROM ${BASE_REGISTRY}alpine:3.20
RUN apk add --no-cache wget ca-certificates \
 && adduser -D -u 10001 app
USER app
COPY --from=build /out/writer /usr/local/bin/writer
ENTRYPOINT ["/usr/local/bin/writer"]
