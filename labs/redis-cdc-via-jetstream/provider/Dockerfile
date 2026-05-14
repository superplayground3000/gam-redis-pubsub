FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /out/provider .

FROM alpine:3.20
RUN adduser -D -u 10001 app
USER app
COPY --from=build /out/provider /usr/local/bin/provider
ENTRYPOINT ["/usr/local/bin/provider"]
