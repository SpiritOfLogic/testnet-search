FROM golang:1.25 AS build
RUN apt-get update && apt-get install -y libsqlite3-dev
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN go build -tags fts5 -o /testnet-search .

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates libsqlite3-0 && rm -rf /var/lib/apt/lists/*
COPY --from=build /testnet-search /usr/local/bin/
ENTRYPOINT ["testnet-search"]
