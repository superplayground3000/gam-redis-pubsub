# --- build stage ---
FROM golang:1.23-alpine AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download

COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/client .

# --- runtime stage ---
FROM alpine:3.20

RUN addgroup -S app && adduser -S -G app app
USER app

COPY --from=build /out/client /usr/local/bin/client

ENTRYPOINT ["/usr/local/bin/client"]
