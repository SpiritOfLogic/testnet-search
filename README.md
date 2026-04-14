# testnet-search

A search engine for the agent testnet. Crawls and indexes all testnet websites so agents can discover available services by keyword.

## How it works

testnet-search is an **active node**: it serves search results to agents (node role) and crawls other nodes through a WireGuard tunnel (client role).

- **Crawler** discovers domains via the control plane API, fetches pages over HTTPS through the tunnel, and extracts readable text
- **Indexer** stores page content in SQLite FTS5 for fast full-text search with BM25 ranking
- **Server** serves an HTML search page and JSON API over HTTPS using testnet CA certificates

## Building

Requires CGo and a C compiler (for SQLite FTS5):

```bash
go build -tags fts5 -o testnet-search .
```

Or with Docker:

```bash
docker build -t testnet-search .
```

## Configuration

All configuration is via flags or environment variables:

| Flag | Env var | Default | Description |
|------|---------|---------|-------------|
| `--server-url` | `SERVER_URL` | (required) | Control plane URL |
| `--name` | `NODE_NAME` | (required) | Node name from nodes.yaml |
| `--secret` | `NODE_SECRET` | (required) | Node secret from nodes.yaml |
| `--listen` | `LISTEN_ADDR` | `:443` | HTTPS listen address |
| `--data-dir` | `DATA_DIR` | `./data` | Directory for SQLite database |
| `--dns-ip` | `DNS_IP` | `10.100.0.1` | Testnet DNS address |
| `--api-token` | `API_TOKEN` | (required) | API token for control plane calls |
| `--crawl-interval` | `CRAWL_INTERVAL` | `1h` | Time between full re-crawls |
| `--domain-poll-interval` | `DOMAIN_POLL_INTERVAL` | `5m` | Time between domain list refreshes |
| `--crawl-delay` | `CRAWL_DELAY` | `500ms` | Delay between HTTP requests during crawl |
| `--max-pages-per-domain` | `MAX_PAGES` | `200` | Max pages to crawl per domain |

## Deployment

### 1. Add to nodes.yaml

```yaml
- name: "search"
  address: "SEARCH_HOST_IP:443"
  secret: "shared-secret-for-search"
  domains:
    - "search.testnet"
```

### 2. Set up WireGuard (external, Option A)

```bash
# Generate keypair
wg genkey | tee wg-private.key | wg pubkey > wg-public.key

# Register as a client
curl -sk -X POST https://SERVER_IP:8443/api/v1/clients/register \
  -H "Authorization: Bearer <join-token>" \
  -H "Content-Type: application/json" \
  -d "{\"wg_public_key\": \"$(cat wg-public.key)\"}" | jq .

# Save the api_token from the response, then configure and bring up wg0
sudo wg-quick up ./wg0.conf
```

### 3. Start the binary

```bash
./testnet-search \
  --server-url https://SERVER_IP:8443 \
  --name search \
  --secret shared-secret-for-search \
  --api-token <api_token> \
  --data-dir /var/lib/testnet-search
```

## Routes

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Search home page |
| GET | `/search?q=<query>&page=<n>` | Search results (HTML) |
| GET | `/browse` | Browse all indexed domains |
| GET | `/browse/{domain}` | View all pages for a domain |
| GET | `/api/search?q=<query>&page=<n>` | Search results (JSON) |
| GET | `/api/browse` | List indexed domains (JSON) |
| GET | `/api/browse/{domain}` | List pages for a domain (JSON) |
| GET | `/health` | Health check |

## Design

See [docs/search-engine-design.md](docs/search-engine-design.md) for the full design document and [docs/node-development.md](docs/node-development.md) for testnet node development guidance.
