# Testnet Search Engine -- Design Document

A search engine for the agent testnet that crawls and indexes all testnet websites, allowing agents to discover available services by keyword.

Prerequisite reading: [Node Development Guide](node-development.md) -- explains the testnet architecture, what agents are, how DNS/VIP/TLS work, and the control plane API.

## Motivation

Agents on the testnet have no way to discover what services exist. They can visit a domain if they already know the name, but there is no directory or search. A search engine solves this by crawling every testnet website, building a full-text index, and serving search results over HTTPS -- exactly like a real search engine on the real internet.

## Scope

This is a purpose-built search engine for a small, closed network. The testnet will have tens to low hundreds of pages across a handful of nodes. The design prioritizes simplicity over scale.

In scope:
- Web crawling of all testnet domains
- Full-text indexing with SQLite FTS5
- Search results page (HTML) usable by agents via a browser or curl
- JSON API for programmatic search
- Dynamic domain discovery via the control plane API
- Periodic re-crawling to pick up content changes and new nodes

Out of scope:
- PageRank or link-based ranking (not useful at this scale)
- Image/video indexing
- JavaScript rendering (SPA support)
- Distributed crawling or sharding
- User accounts or personalization

## Architecture

The search engine is an **active node**: it serves search results to agents (node role) and crawls other nodes through the WireGuard tunnel (client role).

```
                        +------------------+
                        |  Testnet Server  |
                        |  DNS + VIP + CA  |
                        +--------+---------+
                                 |
                          WireGuard tunnel
                                 |
          +----------------------+-------------------------+
          |                      |                         |
   +------+------+     +---------+----------+     +--------+-------+
   |   Agent VM  |     |   testnet-search   |     |   Other Nodes  |
   |             |     |                    |     |  (forum, git,  |
   |             |     |  HTTPS server (:443)     |   hosting...)  |
   |             |     |  Crawler           |     |                |
   |             |     |  SQLite FTS5 index |     |                |
   +------+------+     +---------+----------+     +--------+-------+
          |                      |                         |
          |   GET /search?q=... |                         |
          +--------------------->|                         |
          |<-- search results ---|                         |
          |                      |                         |
          |                      |  GET https://forum.com/ |
          |                      +------------------------>|
          |                      |<-- HTML content --------|
```

### Components

The binary has four internal components:

```
main
 +-- bootstrap       Fetches CA cert, node TLS certs, registers as client,
 |                    sets up WireGuard tunnel
 |
 +-- crawler          Fetches pages over HTTPS through the tunnel,
 |                    extracts text content, respects allowedDomains
 |
 +-- indexer          Stores page content in SQLite FTS5, handles
 |                    inserts/updates/deletes
 |
 +-- server           HTTPS server with search results page and JSON API
```

## Bootstrap sequence

At startup, the search engine must establish two identities: a node (to serve agents) and a client (to crawl through the WireGuard tunnel).

There are two deployment modes depending on how WireGuard is managed (see WireGuard section below). The bootstrap differs slightly:

### With external WireGuard (Option A -- recommended for MVP)

The operator sets up WireGuard and client registration outside the binary. The binary only needs node credentials and an API token:

```
1.  Fetch CA cert          GET /api/v1/ca/root (unauthenticated, via server's public URL)
2.  Fetch node TLS certs   GET /api/v1/nodes/{name}/certs (auth: node secret)
3.  Start HTTPS server     Using node TLS certs, listen on :443
4.  Discover domains       GET /api/v1/domains (auth: API token, via tunnel)
5.  Start crawler          Begin crawling discovered domains through the tunnel
```

The API token is provided to the binary via `--api-token` / `API_TOKEN` (obtained during operator setup).

### With built-in WireGuard (Option B)

The binary handles everything:

```
1.  Fetch CA cert          GET /api/v1/ca/root (unauthenticated, via server's public URL)
2.  Fetch node TLS certs   GET /api/v1/nodes/{name}/certs (auth: node secret)
3.  Register as client     POST /api/v1/clients/register (auth: join token)
4.  Configure WireGuard    Using returned tunnel_cidr, server_wg_public_key, etc.
5.  Start HTTPS server     Using node TLS certs, listen on :443
6.  Discover domains       GET /api/v1/domains (auth: API token from step 3)
7.  Start crawler          Begin crawling discovered domains through the tunnel
```

Steps 1-3 use the server's public address (e.g. `https://203.0.113.10:8443`) over the real internet. Steps 4-7 use the WireGuard tunnel.

The API token from step 3 should be persisted to disk so the search engine can resume after a restart without re-registering.

## Crawler

### Domain discovery

The crawler gets its domain list from the control plane API, not from a static config file.

```
GET /api/v1/domains
Authorization: Bearer <api_token>

Response:
[
  { "domain": "google.com",      "vip": "10.100.0.2", "node": "example-node" },
  { "domain": "www.google.com",  "vip": "10.100.0.2", "node": "example-node" },
  { "domain": "forum.testnet",   "vip": "10.100.0.3", "node": "forum" },
  { "domain": "search.testnet",  "vip": "10.100.0.4", "node": "search" }
]
```

The crawler must:

1. **Filter out its own domains** (no point crawling itself -- match on `node == self`).
2. **Build an allowed-domains set** from the remaining entries. This is used to restrict link-following: only links pointing to domains in this set are followed.
3. **Build a seed URL list** for the initial crawl. Multiple domains can point to the same node (e.g. `google.com` and `www.google.com` both belong to `example-node`). Seed with `https://{domain}/` for each unique domain -- the same server may present different content per `Host` header.
4. **Re-poll this endpoint periodically** (e.g. every 5 minutes) to discover new nodes without restart. When new domains appear, add them to the allowed set and queue them for crawling. When domains disappear, remove their pages from the index.

### HTTP client configuration

The crawler's HTTP client must be configured for the testnet environment. It cannot use the system's default DNS or CA trust store -- it must use the testnet's.

- **TLS**: Trust only the testnet root CA. Build a `tls.Config` with a `RootCAs` pool containing the CA cert from bootstrap. Do not fall back to the system CA store.
- **DNS**: Resolve domains through the testnet DNS, reachable via the WireGuard tunnel. The DNS VIP address comes from the client registration response (`dns_ip` field, typically `10.100.0.1`). Use a custom `net.Resolver` with a `Dialer` pointed at `{dns_ip}:53`, and wire it into the HTTP transport's `DialContext`.
- **Timeouts**: Set reasonable timeouts (e.g. 10s connect, 30s total) since all nodes are on a low-latency network.

```go
// dnsIP comes from RegisterResponse.DNSIP or is provided via config
// caCertPEM comes from GetCACert() or RegisterResponse.CACert

caPool := x509.NewCertPool()
caPool.AppendCertsFromPEM(caCertPEM)

resolver := &net.Resolver{
    PreferGo: true,
    Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
        d := net.Dialer{Timeout: 5 * time.Second}
        return d.DialContext(ctx, "udp", dnsIP+":53")
    },
}

dialer := &net.Dialer{
    Timeout:  10 * time.Second,
    Resolver: resolver,
}

transport := &http.Transport{
    DialContext:     dialer.DialContext,
    TLSClientConfig: &tls.Config{RootCAs: caPool},
}

crawlClient := &http.Client{
    Transport: transport,
    Timeout:   30 * time.Second,
}
```

### Crawl algorithm

Simple breadth-first crawl, one domain at a time:

```
for each domain in allowedDomains:
    queue = [https://{domain}/]
    visited = {}

    while queue is not empty:
        url = queue.pop()
        if url in visited: continue
        visited.add(url)

        page = fetch(url)
        text = extractReadableText(page)
        links = extractLinks(page)

        indexer.upsert(url, page.title, page.description, text)

        for link in links:
            if link.hostname in allowedDomains and link not in visited:
                queue.append(link)
```

Key behaviors:

- **Domain restriction**: Only follow links whose hostname is in the allowed set (from the domains API, minus self). Never follow links to domains outside the testnet.
- **Depth limit**: Cap at a configurable maximum (e.g. 50 pages per domain) to bound crawl time.
- **Rate limiting**: Insert a delay between requests (e.g. 500ms) to be a polite crawler. Nodes are lightweight services; don't overload them.
- **Deduplication**: Track visited URLs to avoid loops. Normalize URLs before comparison (lowercase hostname, remove trailing slash, remove fragment).
- **Content extraction**: Use a readability library (e.g. `go-shiori/go-readability`) to extract the main text content from HTML. Fall back to stripping tags if readability fails.
- **Robots.txt**: Optional. These are testnet services, not public websites, so strict robots.txt compliance is not required. But respecting it is good practice if nodes choose to use it.

### Crawl scheduling

- **Initial crawl**: Run immediately after bootstrap completes.
- **Periodic re-crawl**: Re-crawl all domains on a configurable interval (e.g. every 1 hour).
- **Domain refresh**: When the domain list changes (detected via polling), crawl new domains immediately. Remove pages from deleted domains from the index.

## Indexer

### Storage

SQLite with the FTS5 extension. Single file, no external database server.

```sql
CREATE VIRTUAL TABLE pages USING fts5(
    url,
    domain,
    title,
    description,
    content,
    tokenize='porter unicode61'
);

CREATE TABLE page_meta (
    url         TEXT PRIMARY KEY,
    domain      TEXT NOT NULL,
    title       TEXT,
    description TEXT,
    crawled_at  TEXT NOT NULL
);
```

The `pages` FTS5 table handles full-text search. The `page_meta` table tracks crawl metadata for cache invalidation and domain pruning.

The `porter` tokenizer enables stemming (e.g. "searching" matches "search"). The `unicode61` tokenizer handles Unicode normalization.

### Operations

- **Upsert**: After crawling a page, insert or replace its entry in both tables.
- **Delete by domain**: When a domain is removed from the testnet, delete all its pages from both tables.
- **Search**: Query the FTS5 table using the `MATCH` operator with `bm25()` ranking.

```sql
SELECT url, domain, title,
       snippet(pages, 4, '<b>', '</b>', '...', 30) AS snippet,
       bm25(pages) AS rank
FROM pages
WHERE pages MATCH ?
ORDER BY rank
LIMIT ? OFFSET ?;
```

### CGo dependency

SQLite FTS5 requires `github.com/mattn/go-sqlite3` with the `fts5` build tag:

```bash
go build -tags fts5 -o testnet-search .
```

This requires CGo and a C compiler. The build instructions and Dockerfile should account for this (install `libsqlite3-dev` or equivalent).

## Search server

### HTTPS

Serve on `:443` (or a configurable port) using the node TLS certificate from bootstrap. This is the same pattern as any testnet node.

### Routes

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Search home page (HTML form) |
| GET | `/search?q=<query>&page=<n>` | Search results page (HTML) |
| GET | `/api/search?q=<query>&page=<n>` | Search results (JSON) |
| GET | `/health` | Health check (200 OK) |

### HTML search page

The search page must work without JavaScript since agents typically use curl or simple HTTP clients, not full browsers. Serve a plain HTML page with a `<form>` that GETs `/search`.

The results page should display:
- The search query
- Total number of results
- For each result: page title (linked), URL, and a text snippet with matching terms highlighted
- Pagination links (previous/next)

Keep the HTML simple and semantic. No CSS frameworks or JavaScript required.

### JSON API

```
GET /api/search?q=github&page=1

{
  "query": "github",
  "results": [
    {
      "url": "https://github.com/",
      "domain": "github.com",
      "title": "GitHub - Code Hosting",
      "snippet": "...collaborate on code with <b>GitHub</b>...",
      "rank": -3.65
    }
  ],
  "pagination": {
    "page": 1,
    "page_size": 10,
    "total": 1
  },
  "crawl_status": {
    "last_crawl": "2026-04-11T10:30:00Z",
    "indexed_pages": 47,
    "indexed_domains": 5
  }
}
```

The `crawl_status` field gives agents visibility into index freshness.

## Configuration

The binary should accept all configuration via command-line flags and/or environment variables. No config file required (keeps deployment simple).

| Flag | Env var | Default | Description |
|------|---------|---------|-------------|
| `--server-url` | `SERVER_URL` | (required) | Control plane URL (e.g. `https://203.0.113.10:8443`) |
| `--name` | `NODE_NAME` | (required) | Node name from nodes.yaml |
| `--secret` | `NODE_SECRET` | (required) | Node secret from nodes.yaml |
| `--listen` | `LISTEN_ADDR` | `:443` | HTTPS listen address |
| `--data-dir` | `DATA_DIR` | `./data` | Directory for SQLite database and persisted state |
| `--dns-ip` | `DNS_IP` | `10.100.0.1` | Testnet DNS address (used for crawl resolution) |
| `--api-token` | `API_TOKEN` | (see below) | API token for authenticated control plane calls |
| `--join-token` | `JOIN_TOKEN` | (see below) | Client join token for WireGuard registration |
| `--crawl-interval` | `CRAWL_INTERVAL` | `1h` | Time between full re-crawls |
| `--domain-poll-interval` | `DOMAIN_POLL_INTERVAL` | `5m` | Time between domain list refreshes |
| `--crawl-delay` | `CRAWL_DELAY` | `500ms` | Delay between HTTP requests during crawl |
| `--max-pages-per-domain` | `MAX_PAGES` | `200` | Maximum pages to crawl per domain |

**Option A (external WireGuard)**: `--api-token` is required (obtained during operator setup). `--join-token` is not needed.

**Option B (built-in WireGuard)**: `--join-token` is required. `--api-token` is not needed (obtained automatically during registration and persisted to `--data-dir`).

## WireGuard setup

The search engine needs a WireGuard tunnel to reach other nodes via VIPs. There are two approaches:

### Option A: External WireGuard (recommended for MVP)

Let the operator set up WireGuard outside the binary using standard tools (`wg-quick`). The search engine just uses the tunnel that's already up. This is simpler and avoids requiring root privileges or netlink operations in the binary.

The operator would:
1. Register as a client (using curl or a helper script) to get tunnel parameters
2. Write a `wg0.conf` and bring up the interface
3. Start the search engine binary (which only needs node credentials, not client credentials)

In this mode, `--join-token` is not needed. The binary only acts as a node. The tunnel is infrastructure managed separately.

### Option B: Built-in WireGuard

The binary manages WireGuard itself using `golang.zx2c4.com/wireguard` (userspace WireGuard) or by shelling out to `wg` and `ip`. This is more self-contained but adds complexity and may require root.

Recommendation: start with Option A. Move to Option B later if self-contained deployment becomes important.

## Project layout

```
testnet-search/
  main.go              Entry point, flag parsing, bootstrap, start server + crawler
  crawler/
    crawler.go         Breadth-first crawl loop, domain filtering, rate limiting
    extractor.go       HTML parsing, text extraction (go-readability), link extraction
  index/
    index.go           SQLite FTS5 wrapper: upsert, delete, search, stats
    schema.go          Table creation and migration
  server/
    server.go          HTTPS server setup, route registration
    handlers.go        Search page, JSON API, health check handlers
    templates/
      home.html        Search form
      results.html     Search results page
  go.mod
  go.sum
  Dockerfile
  README.md
```

## Dependencies

| Package | Purpose |
|---------|---------|
| `github.com/agent-testnet/agent-testnet/pkg/api` | Control plane client and types |
| `github.com/mattn/go-sqlite3` | SQLite driver with FTS5 support (CGo) |
| `github.com/go-shiori/go-readability` | Extract readable text from HTML |
| `golang.org/x/net/html` | HTML tokenizer for link extraction |

No web framework needed. The standard library `net/http` and `html/template` are sufficient.

## Deployment

### nodes.yaml entry

The testnet operator adds:

```yaml
- name: "search"
  address: "SEARCH_HOST_IP:443"
  secret: "shared-secret-for-search"
  domains:
    - "search.testnet"
```

The domain `search.testnet` is deliberate -- agents will learn to go to `search.testnet` to find things, just as they'd go to `google.com` on the real internet.

### WireGuard setup (Option A)

On the search engine host, the operator performs a one-time setup:

```bash
# 1. Generate a WireGuard keypair
wg genkey | tee wg-private.key | wg pubkey > wg-public.key

# 2. Register as a client with the testnet server
curl -sk -X POST https://SERVER_IP:8443/api/v1/clients/register \
  -H "Authorization: Bearer <join-token>" \
  -H "Content-Type: application/json" \
  -d "{\"wg_public_key\": \"$(cat wg-public.key)\"}" | jq .

# Response includes: client_id, api_token, tunnel_cidr, server_wg_public_key, server_wg_addr, dns_ip
# Save the api_token -- the binary needs it.
```

Write `wg0.conf` using the returned values:

```ini
[Interface]
PrivateKey = <contents of wg-private.key>
Address = 10.99.X.1/24              # first usable IP in tunnel_cidr (e.g. if tunnel_cidr is 10.99.2.0/24, use 10.99.2.1)

[Peer]
PublicKey = <server_wg_public_key from response>
Endpoint = SERVER_PUBLIC_IP:51820    # server's real public IP, WireGuard port
AllowedIPs = 10.99.0.0/16, 10.100.0.0/16
PersistentKeepalive = 25
```

Bring up the tunnel:

```bash
sudo wg-quick up ./wg0.conf
```

Verify connectivity:

```bash
# Should resolve testnet domains
dig @10.100.0.1 google.com
```

### Start the binary

```bash
./testnet-search \
  --server-url https://SERVER_IP:8443 \
  --name search \
  --secret shared-secret-for-search \
  --api-token <api_token from registration> \
  --data-dir /var/lib/testnet-search
```

### Docker

```dockerfile
FROM golang:1.25 AS build
RUN apt-get update && apt-get install -y libsqlite3-dev
WORKDIR /src
COPY . .
RUN go build -tags fts5 -o /testnet-search .

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates libsqlite3-0 && rm -rf /var/lib/apt/lists/*
COPY --from=build /testnet-search /usr/local/bin/
ENTRYPOINT ["testnet-search"]
```

## Future extensions

These are explicitly out of scope for the initial implementation but noted for future consideration:

- **Autocomplete / suggest**: Return suggestions as the agent types a query
- **Spelling correction**: "Did you mean..." for typos
- **Crawl status page**: An HTML page showing which domains have been crawled, when, and how many pages
- **Vector search**: Semantic similarity using embeddings (would require an embedding model or API)
- **Indexing non-HTML content**: PDFs, API documentation (JSON/OpenAPI specs), README files
- **Favicon/screenshot capture**: Visual previews in search results
