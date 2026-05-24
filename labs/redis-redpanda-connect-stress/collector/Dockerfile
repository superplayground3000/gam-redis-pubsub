# syntax=docker/dockerfile:1.7
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/collector .

FROM alpine:3.20
RUN apk add --no-cache wget ca-certificates \
 && adduser -D -u 10001 app
USER app
COPY --from=build /out/collector /usr/local/bin/collector
ENTRYPOINT ["/usr/local/bin/collector"]
