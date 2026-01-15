# Build stage
FROM golang:1.22-alpine AS builder

WORKDIR /app
COPY go.mod ./
# If you have go.sum, copy it too:
# COPY go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o orders-api ./...

# Runtime stage
FROM alpine:3.20

RUN adduser -D -g '' appuser && \
    apk add --no-cache ca-certificates

USER appuser
WORKDIR /app

COPY --from=builder /app/orders-api /app/orders-api

EXPOSE 8080
ENTRYPOINT ["/app/orders-api"]
