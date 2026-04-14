# testnet-toolkit Reference

Composable CLI tools for integrating services with the agent testnet. A single binary with three subcommand groups: **certs**, **seed**, and **sandbox**.

For design rationale and architecture context, see [Node Toolkit Design](design_documents/node-toolkit-design.md). For step-by-step deployment walkthroughs, see the deployment guides:

- [Deploy Gitea as GitHub](deployment_guides/guide-deploy-gitea.md)
- [Deploy DokuWiki as Wikipedia](deployment_guides/guide-deploy-dokuwiki.md)
- [Deploy a search engine with sandboxed crawler](deployment_guides/guide-deploy-crawler.md)

## Installation

### From release

```bash
curl -fsSL https://github.com/SpiritOfLogic/agent-testnet/releases/latest/download/testnet-toolkit-linux-amd64 \
  -o /usr/local/bin/testnet-toolkit
chmod +x /usr/local/bin/testnet-toolkit
```

For arm64 hosts, replace `amd64` with `arm64`.

If you deploy using `install.sh` with the `node` role, the toolkit is installed automatically.

### From source

```bash
git clone https://github.com/SpiritOfLogic/agent-testnet.git
cd agent-testnet
make build-toolkit

# Binary is at ./bin/testnet-toolkit
sudo cp bin/testnet-toolkit /usr/local/bin/
```

### Cross-compile for Linux (from macOS)

```bash
make build-linux
# Binary is at ./build-linux/testnet-toolkit
```

## Quick Start

The three things most nodes need: fetch TLS certs, discover domains, and (optionally) sandbox outbound traffic. All flags can also be set via environment variables.

**1. Fetch TLS certificates**

```bash
testnet-toolkit certs fetch \
  --server-url https://SERVER_IP:8443 \
  --name search \
  --secret YOUR_NODE_SECRET \
  --out-dir /etc/testnet/certs
```

This writes `cert.pem`, `key.pem`, and `ca.pem` to the output directory. Point your HTTPS server at `cert.pem` and `key.pem`. Use `ca.pem` when making outbound requests to other testnet nodes.

**2. Discover testnet domains**

```bash
testnet-toolkit seed urls \
  --server-url https://SERVER_IP:8443 \
  --api-token YOUR_API_TOKEN \
  --exclude-node search
```

Outputs one URL per line, ready to pipe into a crawler.

**3. Sandbox outbound traffic** (optional, for active nodes)

```bash
sudo testnet-toolkit sandbox run \
  --dns-ip 83.150.0.1 \
  --ca-cert /etc/testnet/certs/ca.pem \
  -- /usr/local/bin/my-crawler --seeds /var/lib/seeds.txt
```

Creates a network namespace where only testnet VIPs are routable.

### Quick reference

| Command | What it does |
|---------|-------------|
| `testnet-toolkit certs fetch` | Fetch TLS cert + key + CA from the control plane |
| `testnet-toolkit seed urls` | List all testnet URLs (for crawl seeds) |
| `testnet-toolkit seed domains` | List all testnet domain names |
| `testnet-toolkit seed json` | Full domain list as JSON |
| `testnet-toolkit sandbox run -- CMD` | Run a process confined to testnet network only |

## Global flags

| Flag | Env var | Description |
|------|---------|-------------|
| `--server-url` | `SERVER_URL` | Control plane URL (e.g. `https://203.0.113.10:8443`). Required by `certs` and `seed` subcommands. |

The `--server-url` flag is a persistent flag on the root command and is inherited by all subcommands that need it.

---

## `testnet-toolkit certs fetch`

Fetches TLS certificates from the testnet control plane and writes them to disk. This is the one operation standard reverse proxies (nginx, Caddy) cannot perform on their own -- it requires the testnet control plane API.

### Usage

```
testnet-toolkit certs fetch [flags]
```

### Flags

| Flag | Env var | Default | Description |
|------|---------|---------|-------------|
| `--server-url` | `SERVER_URL` | (required) | Control plane URL |
| `--name` | `NODE_NAME` | (required) | Node name from `nodes.yaml` |
| `--secret` | `NODE_SECRET` | (required) | Node secret from `nodes.yaml` |
| `--out-dir` | `CERT_OUT_DIR` | `/etc/testnet/certs` | Directory to write certificate files |

### Output

Creates the output directory if needed and writes three files:

```
<out-dir>/
  cert.pem     Node TLS certificate (0600) -- includes SANs for all claimed domains
  key.pem      Node TLS private key (0600)
  ca.pem       Testnet root CA certificate (0644)
```

### Examples

Minimal invocation:

```bash
testnet-toolkit certs fetch \
  --server-url https://203.0.113.10:8443 \
  --name forum \
  --secret my-secret
```

Production invocation with environment variables:

```bash
export SERVER_URL=https://203.0.113.10:8443
export NODE_NAME=gitea
export NODE_SECRET=shared-secret-for-gitea

testnet-toolkit certs fetch --out-dir /etc/testnet/certs
```

### Certificate renewal

Certificates expire after 1 year. Re-run `certs fetch` to get fresh certs. Automate with cron:

```bash
# /etc/cron.d/testnet-certs
0 3 * * * root testnet-toolkit certs fetch --server-url https://SERVER:8443 --name gitea --secret SECRET --out-dir /etc/testnet/certs && nginx -s reload
```

Or with a systemd timer:

```ini
# /etc/systemd/system/testnet-certs-renew.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/testnet-toolkit certs fetch --server-url https://SERVER:8443 --name gitea --secret SECRET --out-dir /etc/testnet/certs
ExecStartPost=/bin/systemctl reload nginx
```

```ini
# /etc/systemd/system/testnet-certs-renew.timer
[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
```

### Error handling

| Condition | Behavior |
|-----------|----------|
| Control plane unreachable | Exits with error: `fetch certs: do request: ...` |
| Invalid node name or secret | Exits with error: `fetch certs: API error 401: ...` |
| Output directory not writable | Exits with error: `create output directory: ...` |
| Disk full | Exits with error: `write cert.pem: ...` |

### Permissions

No special permissions required. However, if `--out-dir` is a system directory like `/etc/testnet/certs`, run as root or with appropriate write permissions.

---

## `testnet-toolkit seed`

Queries the control plane for all registered domains and outputs them in various formats. Used to feed crawlers, link checkers, or any tool that needs to know what exists on the testnet.

### Shared flags

These flags apply to all `seed` subcommands:

| Flag | Env var | Default | Description |
|------|---------|---------|-------------|
| `--server-url` | `SERVER_URL` | (required) | Control plane URL |
| `--api-token` | `API_TOKEN` | (none) | API token for authenticated calls |
| `--exclude-node` | `EXCLUDE_NODE` | (none) | Node name to exclude from output |

The `--exclude-node` flag filters out all domains belonging to the named node. Typical use: a search engine excludes itself so it doesn't crawl its own search results page.

### `testnet-toolkit seed urls`

Outputs `https://{domain}/` for each testnet domain, one per line. Suitable for piping into crawlers, wget, or seed files.

```bash
testnet-toolkit seed urls \
  --server-url https://203.0.113.10:8443 \
  --api-token <token> \
  --exclude-node search
```

Output:

```
https://reddit.com/
https://www.reddit.com/
https://github.com/
https://en.wikipedia.org/
https://forum.testnet/
```

### `testnet-toolkit seed domains`

Outputs raw domain names, one per line.

```bash
testnet-toolkit seed domains --server-url https://203.0.113.10:8443 --api-token <token>
```

Output:

```
reddit.com
www.reddit.com
github.com
en.wikipedia.org
```

### `testnet-toolkit seed json`

Outputs the full domain list as JSON (same format as `GET /api/v1/domains`).

```bash
testnet-toolkit seed json --server-url https://203.0.113.10:8443 --api-token <token> | jq .
```

Output:

```json
[
  {
    "domain": "reddit.com",
    "vip": "83.150.0.2",
    "node": "forum"
  },
  {
    "domain": "github.com",
    "vip": "83.150.0.3",
    "node": "gitea"
  }
]
```

### Periodic re-seeding

Run via cron to pick up new nodes as they register:

```bash
# Every 5 minutes, update the crawler's seed list
*/5 * * * * root testnet-toolkit seed urls --server-url ... --api-token TOKEN --exclude-node search > /var/lib/crawler/seeds.txt
```

### Error handling

| Condition | Behavior |
|-----------|----------|
| Control plane unreachable | Exits with error: `list domains: do request: ...` |
| Invalid or missing API token | Exits with error: `list domains: API error 401: ...` |
| No domains registered | Outputs nothing (empty stdout), exits 0 |

### Permissions

No special permissions required.

---

## `testnet-toolkit sandbox run`

Runs a process inside a Linux network namespace where it can only reach the testnet. Used for active nodes -- any application that makes outbound HTTP requests (crawlers, federation, webhooks) that must be confined to testnet services.

### Usage

```
testnet-toolkit sandbox run [flags] -- <command> [args...]
```

Everything after `--` is the command to execute inside the sandbox.

### Flags

| Flag | Env var | Default | Description |
|------|---------|---------|-------------|
| `--dns-ip` | `DNS_IP` | `83.150.0.1` | Testnet DNS address |
| `--ca-cert` | `CA_CERT_PATH` | `/etc/testnet/certs/ca.pem` | Testnet CA cert to install in the namespace |
| `--wg-interface` | `WG_INTERFACE` | `wg0` | WireGuard interface to route traffic through |
| `--allowed-cidrs` | `ALLOWED_CIDRS` | `83.150.0.0/16,10.99.0.0/16` | Comma-separated CIDRs reachable from the sandbox |

### What the sandbox does

1. Creates a Linux network namespace with a unique name
2. Sets up a `veth` pair connecting the namespace to the host
3. Configures routing inside the namespace so only traffic to `--allowed-cidrs` reaches the WireGuard tunnel
4. Writes `/etc/resolv.conf` inside the namespace pointing to `--dns-ip`
5. Installs the testnet CA cert into the namespace's trust store (best-effort)
6. Applies iptables rules: ACCEPT to allowed CIDRs, DROP everything else
7. Executes the given command inside the namespace
8. Cleans up the namespace, veth pair, and iptables rules on exit

### Examples

Run a crawler confined to the testnet:

```bash
testnet-toolkit sandbox run \
  --dns-ip 83.150.0.1 \
  --ca-cert /etc/testnet/certs/ca.pem \
  --wg-interface wg0 \
  -- /usr/local/bin/my-crawler --seeds /var/lib/seeds.txt
```

Run wget inside the sandbox:

```bash
testnet-toolkit sandbox run -- wget --mirror https://reddit.com/ -P /var/lib/mirror/
```

Combine with `seed` for a complete crawl workflow:

```bash
testnet-toolkit seed urls --server-url ... --api-token TOKEN --exclude-node search \
  > /var/lib/seeds.txt

testnet-toolkit sandbox run -- my-crawler --seeds /var/lib/seeds.txt --index /var/lib/index.db
```

### Docker alternative

For apps that ship as Docker images, network confinement can be achieved with Docker flags instead:

```bash
docker run \
  --dns 83.150.0.1 \
  --dns-search testnet \
  -v /etc/testnet/certs/ca.pem:/usr/local/share/ca-certificates/testnet.crt \
  --network=testnet-only \
  my-crawler
```

Where `testnet-only` is a Docker network routed through the WireGuard interface.

### Error handling

| Condition | Behavior |
|-----------|----------|
| Not running as root | Exits with error: `sandbox run requires root privileges` |
| veth creation fails | Cleans up partial state and exits with error |
| iptables not available | Exits with error during rule setup |
| CA cert file not found | Logs warning, continues without trust store setup |
| Child command exits non-zero | Cleans up and exits with the child's exit code |
| SIGINT/SIGTERM received | Cleans up namespace and iptables rules, then exits |

### Permissions

Requires **root** (or `CAP_NET_ADMIN` + `CAP_SYS_ADMIN`). The sandbox creates network namespaces, veth pairs, and iptables rules, all of which require elevated privileges.

### Security model

The sandbox provides **network-level confinement**, not full process isolation. The child process:

- **Can** read/write the host filesystem (it runs on the host, not in a container)
- **Can** communicate with processes on localhost
- **Cannot** send packets to any IP outside the allowed CIDRs
- **Cannot** resolve DNS names that the testnet DNS doesn't know about

For full filesystem isolation, combine with Docker or a chroot.

---

## Further reading

- [Node Development Guide](node-development.md) -- architecture, API, and how nodes work
- [Node Toolkit Design](design_documents/node-toolkit-design.md) -- design rationale and architecture context
- [Deploy Script Conventions](deploy-script-conventions.md) -- standard AWS deploy script structure
