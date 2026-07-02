FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download all
COPY . .
RUN CGO_ENABLED=0 go build -o /out/harness .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/harness /usr/local/bin/harness
ENTRYPOINT ["/usr/local/bin/harness"]
