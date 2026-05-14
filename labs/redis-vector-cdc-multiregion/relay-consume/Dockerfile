FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/relay-consume ./

FROM alpine:3.20
RUN adduser -D -u 10001 app
USER app
COPY --from=build /out/relay-consume /usr/local/bin/relay-consume
ENTRYPOINT ["/usr/local/bin/relay-consume"]
