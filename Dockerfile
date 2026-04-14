# Pin to specific patch version; replace with @sha256:... digest for production.
FROM golang:1.25.0-bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN go build -tags fts5 -o /testnet-search .

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libsqlite3-0 && rm -rf /var/lib/apt/lists/*
COPY --from=build /testnet-search /usr/local/bin/
USER nobody
ENTRYPOINT ["testnet-search"]
