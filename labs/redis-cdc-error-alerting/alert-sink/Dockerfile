FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 go build -o /alert-sink .

FROM alpine:3.20
RUN apk add --no-cache wget
COPY --from=build /alert-sink /alert-sink
EXPOSE 9099
ENTRYPOINT ["/alert-sink"]
