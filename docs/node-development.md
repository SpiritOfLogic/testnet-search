# Node Development Guide

This guide explains how to build a service (node) for the agent testnet. It covers the testnet architecture, control plane API, TLS integration, and how to structure your project.

## What is the agent testnet?

The agent testnet is a sandboxed internet environment for AI agents. AI agents (LLMs that can browse the web, write code, call APIs) run inside isolated microVMs with no access to the real internet. Instead, all their network traffic is routed through a controlled testnet where operator-declared services impersonate real websites.

The testnet has three roles:

- **Server** -- The central control plane. Runs DNS, a certificate authority (CA), WireGuard VPN hub, and iptables routing. All traffic flows through it.
- **Client** -- Runs agent VMs (Firecracker microVMs). Each VM is network-isolated: it can only reach testnet services, never the real internet. Connects to the server via a WireGuard tunnel.
- **Node** -- Any service that agents can interact with. A node is a regular HTTPS server running on its own host, registered with the control plane. This is what you build.

```
                    +-----------------+
                    |  testnet-server |
                    |  Control plane  |
                    |  DNS + CA + NAT |
                    +--------+--------+
                             |
                      WireGuard tunnel
                             |
          +------------------+------------------+
          |                                     |
+---------+----------+              +-----------+--------+
| testnet-client     |              | your node          |
| Agent VMs (isolated|              | (any service)      |
| microVMs)          |              | TLS via testnet CA |
+--------------------+              +--------------------+
```

### How agent traffic flows

When an agent inside a VM tries to visit `github.com`:

1. The VM's DNS resolver queries the testnet DNS server (there is no other DNS available)
2. If `github.com` is a declared testnet domain, DNS returns a Virtual IP (VIP) in `10.100.0.0/16`; otherwise it returns NXDOMAIN (domain not found)
3. The VM sends HTTPS traffic to the VIP, which travels through the WireGuard tunnel to the server
4. The server uses iptables DNAT (Destination NAT) to rewrite the VIP to your node's real public IP address and forwards the traffic
5. Your node receives the request, processes it, and sends the response back along the same path

The agent never knows it's on a testnet. From its perspective, it resolved a domain and got an HTTPS response -- just like the real internet.

### Testnet DNS

The testnet runs its own authoritative DNS server. Key behaviors:

- Domains declared in `nodes.yaml` resolve to their assigned VIP
- Every node also gets an auto-name: `{node-name}.testnet` (e.g. `search.testnet`)
- All undeclared domains return **NXDOMAIN** -- agents cannot discover or reach anything outside the testnet
- There is no recursion or forwarding to public DNS

### Testnet CA

The server runs a private certificate authority (CA). Nodes fetch TLS certificates signed by this CA. The CA certificate is injected into every agent VM, so agents trust HTTPS connections to testnet nodes. System CAs from the real internet are **not** trusted inside agent VMs.

## What is a node?

A node is any service that agents can interact with on the testnet. From an agent's perspective, nodes look like regular websites -- they resolve via DNS and serve HTTPS. Under the hood, each node:

1. Is declared in the server's `nodes.yaml` with a name, address, secret, and list of domains
2. Receives a Virtual IP (VIP) in `10.100.0.0/16` for each of its domains
3. Fetches TLS certificates from the testnet CA so agents trust its HTTPS
4. Serves traffic on a real host:port that the server DNATs to from the VIP

```
Agent VM                    Server                         Node
  |                           |                              |
  |-- DNS: github.com ------->|                              |
  |<-- A 10.100.0.5 ---------|                              |
  |                           |                              |
  |-- HTTPS 10.100.0.5:443 ->|-- DNAT to 203.0.113.1:443 ->|
  |<-- response --------------|<-- response -----------------|
```

## Project structure

Each node should live in its own repository. This keeps the core testnet infrastructure separate from services and provides a clean reference for third-party developers.

```
# Core infrastructure (this repo)
agent-testnet/
  cmd/testnet-server/       # control plane, DNS, WG, routing
  cmd/testnet-client/       # agent VM management
  cmd/testnet-node/         # minimal stub node (hello world)
  pkg/api/                  # shared types + HTTP client (your dependency)

# Nodes (separate repos, one per service)
testnet-search/             # search engine for discovering testnet sites
testnet-forum/              # Reddit-like forum
testnet-git/                # GitHub-like code hosting
testnet-hosting/            # static web hosting + domain registration
testnet-messenger/          # Telegram-like messaging
```

Every node repo imports `github.com/agent-testnet/agent-testnet/pkg/api` for the control plane client and shared types.

## Minimal node example

The `cmd/testnet-node` in the agent-testnet repo is a ~70-line reference implementation. It demonstrates the full lifecycle:

```go
package main

import (
    "crypto/tls"
    "flag"
    "log"
    "net/http"

    "github.com/agent-testnet/agent-testnet/pkg/api"
)

func main() {
    serverURL := flag.String("server-url", "", "testnet server URL (https://...)")
    name := flag.String("name", "", "node name from nodes.yaml")
    secret := flag.String("secret", "", "per-node secret from nodes.yaml")
    flag.Parse()

    // 1. Fetch TLS certs from the control plane.
    //    Pass nil for caCert -- the control plane's own TLS cert is self-signed,
    //    so the first connection skips verification (bootstrap only).
    client := api.NewServerClient(*serverURL, nil)
    certs, err := client.FetchNodeCerts(*name, *secret)
    if err != nil {
        log.Fatal(err)
    }

    // 2. Parse the certificate
    tlsCert, err := tls.X509KeyPair([]byte(certs.CertPEM), []byte(certs.KeyPEM))
    if err != nil {
        log.Fatal(err)
    }

    // 3. Serve HTTPS with the testnet CA-signed cert
    mux := http.NewServeMux()
    mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
        w.Write([]byte("Hello from the testnet!"))
    })

    srv := &http.Server{
        Addr:    ":443",
        Handler: mux,
        TLSConfig: &tls.Config{
            Certificates: []tls.Certificate{tlsCert},
        },
    }
    log.Fatal(srv.ListenAndServeTLS("", ""))
}
```

**Note on the bootstrap TLS call**: `api.NewServerClient(url, nil)` disables TLS verification for the initial connection to the control plane. This is safe because the control plane uses a self-signed certificate (not issued by a public CA). After fetching the CA cert, you can create a new client with `api.NewServerClient(url, caCert)` to verify all subsequent calls. For simple passive nodes that only fetch certs at startup, the nil-CA bootstrap is sufficient.

## The `pkg/api` Go package

Your node imports `github.com/agent-testnet/agent-testnet/pkg/api`. This package provides:

**`api.ServerClient`** -- HTTP client for the control plane API:

```go
type ServerClient struct {
    BaseURL    string
    HTTPClient *http.Client
    APIToken   string       // set this after registration for authenticated calls
}

// Create a client. Pass caCert (PEM bytes) to verify the server's TLS cert,
// or nil to skip verification (safe only for the initial bootstrap call).
func NewServerClient(baseURL string, caCert []byte) *ServerClient

func (c *ServerClient) GetCACert() ([]byte, error)
func (c *ServerClient) FetchNodeCerts(nodeName, nodeSecret string) (*CertResponse, error)
func (c *ServerClient) Register(joinToken string, req *RegisterRequest) (*RegisterResponse, error)
func (c *ServerClient) ListNodes() ([]NodeInfo, error)
func (c *ServerClient) ListDomains() ([]DomainMapping, error)
```

**Key types:**

```go
type CertResponse struct {
    CertPEM string `json:"cert_pem"`  // node TLS certificate (PEM)
    KeyPEM  string `json:"key_pem"`   // node TLS private key (PEM)
    CAPEM   string `json:"ca_pem"`    // testnet root CA certificate (PEM)
}

type RegisterRequest struct {
    WGPublicKey string `json:"wg_public_key"` // base64 WireGuard public key
}

type RegisterResponse struct {
    ClientID     string `json:"client_id"`
    APIToken     string `json:"api_token"`            // for authenticated API calls
    TunnelCIDR   string `json:"tunnel_cidr"`           // your WireGuard address (e.g. "10.99.1.0/24")
    ServerWGKey  string `json:"server_wg_public_key"`  // server's WireGuard public key
    ServerWGAddr string `json:"server_wg_addr"`        // server's tunnel address (e.g. "10.99.0.1/16")
    DNSIP        string `json:"dns_ip"`                // testnet DNS VIP (e.g. "10.100.0.1")
    CACert       string `json:"ca_cert"`               // testnet root CA cert (PEM)
}

type NodeInfo struct {
    Name    string   `json:"name"`
    VIP     string   `json:"vip"`
    Domains []string `json:"domains,omitempty"`
}

type DomainMapping struct {
    Domain string `json:"domain"` // e.g. "google.com" or "search.testnet"
    VIP    string `json:"vip"`    // e.g. "10.100.0.2"
    Node   string `json:"node"`   // owning node name
}
```

## Control plane API

All endpoints are served over HTTPS on port 8443. The base URL is the server's public address (e.g. `https://203.0.113.10:8443`). The control plane uses a self-signed TLS certificate, so the initial connection requires skipping TLS verification (see bootstrap note above).

### Authentication

There are three auth contexts:

| Context | Token | How to obtain |
|---------|-------|---------------|
| Bootstrap (CA cert) | None | `GET /api/v1/ca/root` is unauthenticated |
| Node operations | Per-node secret | Set in `nodes.yaml` by the testnet operator |
| Client operations | API token | Returned by `POST /api/v1/clients/register` |

All authenticated endpoints use `Authorization: Bearer <token>`.

### Endpoints

#### `GET /api/v1/ca/root`

Returns the testnet root CA certificate in PEM format. No authentication required.

Use this to bootstrap trust -- once you have the CA cert, use it to verify all subsequent TLS connections to the control plane and to other nodes.

#### `GET /api/v1/nodes/{name}/certs`

Returns TLS certificates for your node. Auth: node secret.

```json
{
  "cert_pem": "-----BEGIN CERTIFICATE-----\n...",
  "key_pem": "-----BEGIN EC PRIVATE KEY-----\n...",
  "ca_pem": "-----BEGIN CERTIFICATE-----\n..."
}
```

The certificate includes SANs for `{name}.testnet` plus all domains declared in `nodes.yaml`. Use these to terminate HTTPS so agents trust your service.

#### `POST /api/v1/clients/register`

Registers as a client to get WireGuard tunnel access. Auth: join token.

Request:
```json
{ "wg_public_key": "<base64 WireGuard public key>" }
```

Response:
```json
{
  "client_id": "client-1",
  "api_token": "<hex token for authenticated API calls>",
  "tunnel_cidr": "10.99.1.0/24",
  "server_wg_public_key": "<base64>",
  "server_wg_addr": "10.99.0.1/16",
  "dns_ip": "10.100.0.1",
  "ca_cert": "-----BEGIN CERTIFICATE-----\n..."
}
```

Use the returned `api_token` for subsequent API calls. Use the WireGuard parameters to establish a tunnel to the testnet.

#### `GET /api/v1/nodes`

Lists all nodes with their VIPs and domains. Auth: API token.

```json
[
  {
    "name": "example-node",
    "vip": "10.100.0.2",
    "domains": ["google.com", "www.google.com"]
  }
]
```

#### `GET /api/v1/domains`

Lists all domain-to-VIP mappings (including auto-names like `{name}.testnet`). Auth: API token.

```json
[
  { "domain": "google.com",           "vip": "10.100.0.2", "node": "example-node" },
  { "domain": "example-node.testnet", "vip": "10.100.0.2", "node": "example-node" }
]
```

## Node types

### Passive node (serve only)

The simplest case. Your node serves HTTPS and agents connect to it. This is what the stub `testnet-node` demonstrates.

Requirements:
- A host with a public IP and an open port (typically 443)
- Declared in the server's `nodes.yaml`
- Fetches TLS certs from the control plane at startup

### Active node (serve + consume other nodes)

Some nodes need to reach other testnet services. A search engine needs to crawl other nodes. A code hosting service might need to verify URLs on other nodes.

An active node is both a **node** (serves traffic to agents) and a **client** (connects to the testnet via WireGuard to reach other nodes through VIPs).

```
                     +-----------+
                     |  Server   |
                     | DNS + VIP |
                     +-----+-----+
                           |
                    WireGuard tunnel
                           |
    +----------------------+----------------------+
    |                      |                      |
+---+---+           +------+-------+         +----+----+
| Agent |           | Active Node  |         |  Node B |
|  VM   |           | (e.g.search) |         | (forum) |
+-------+           +--------------+         +---------+
    |                 serves ^ crawls             |
    |                        |                    |
    +--- queries search -----+                    |
                             +--- crawls forum ---+
                                  (via VIP)
```

An active node must:

1. **Register as a node** -- declared in `nodes.yaml`, fetches TLS certs to serve agents
2. **Register as a client** -- calls `POST /api/v1/clients/register` with a WireGuard public key to get tunnel access
3. **Establish a WireGuard tunnel** -- so it can resolve testnet DNS and reach other nodes via VIPs
4. **Discover domains** -- calls `GET /api/v1/domains` to learn what's available
5. **Trust the testnet CA** -- uses the CA cert when making HTTPS requests to other nodes

### WireGuard tunnel setup

The WireGuard tunnel connects your node to the testnet's VIP network. Without it, your node can serve agents (via DNAT) but cannot reach other nodes.

The tunnel topology:
- Server's tunnel address: `10.99.0.1/16` (the WireGuard hub)
- Each client gets a `/24` slice (e.g. `10.99.1.0/24`)
- Through the tunnel, your node can reach the VIP range `10.100.0.0/16` and the testnet DNS at `10.100.0.1`

After registering as a client via `POST /api/v1/clients/register`, you receive the parameters to build a WireGuard config. Example `wg0.conf`:

```ini
[Interface]
PrivateKey = <your-wg-private-key>
Address = 10.99.1.1/24          # first usable IP in your tunnel_cidr

[Peer]
PublicKey = <server_wg_public_key from registration response>
Endpoint = SERVER_PUBLIC_IP:51820
AllowedIPs = 10.99.0.0/16, 10.100.0.0/16
PersistentKeepalive = 25
```

The `AllowedIPs` routes both the tunnel network (`10.99.0.0/16`) and the VIP network (`10.100.0.0/16`) through the tunnel. Bring it up with:

```bash
sudo wg-quick up ./wg0.conf
```

Once the tunnel is up, you can resolve testnet domains and make HTTPS requests to other nodes via their VIPs.

### Example: active node bootstrap in Go

```go
// 1. Fetch CA cert (bootstrap -- skips TLS verification)
bootstrapClient := api.NewServerClient(serverURL, nil)
caCert, _ := bootstrapClient.GetCACert()

// 2. Create a trusted client
client := api.NewServerClient(serverURL, caCert)

// 3. Fetch node TLS certs (for serving agents)
certs, _ := client.FetchNodeCerts(nodeName, nodeSecret)

// 4. Register as a client (for tunnel access)
reg, _ := client.Register(joinToken, &api.RegisterRequest{
    WGPublicKey: wgPubKey,
})
// reg.APIToken     -- use for authenticated API calls going forward
// reg.TunnelCIDR   -- your WireGuard address range
// reg.ServerWGKey  -- server's WireGuard public key
// reg.DNSIP        -- testnet DNS address (e.g. "10.100.0.1")
// reg.CACert       -- testnet root CA (PEM)

// 5. Set up WireGuard (externally or programmatically)

// 6. Discover domains (requires tunnel to be up for API calls via VIP,
//    or use the server's public URL)
client.APIToken = reg.APIToken
domains, _ := client.ListDomains()

// 7. Make requests to other nodes using an HTTP client that:
//    - Resolves DNS via reg.DNSIP (testnet DNS through tunnel)
//    - Trusts the testnet CA cert from reg.CACert
```

## Deployment

### Server-side setup

The testnet operator adds your node to `nodes.yaml`:

```yaml
nodes:
  - name: "search"
    address: "203.0.113.50:443"
    secret: "your-shared-secret"
    domains:
      - "search.testnet"
```

After updating, send `SIGHUP` to the server to reload without downtime.

### Node-side setup

The agent-testnet repo includes a universal `install.sh` that can bootstrap a node host (install deps, write config, set up systemd). If the operator has it available:

```bash
SERVER_URL=https://SERVER_IP:8443 NODE_NAME=search NODE_SECRET=your-shared-secret \
  sudo -E bash install.sh node
```

This installs the stub `testnet-node` binary. For custom nodes (your own binary), run directly instead:

```bash
./testnet-search \
  --server-url https://SERVER_IP:8443 \
  --name search \
  --secret your-shared-secret \
  --listen :443
```

For active nodes that also need tunnel access, provide the join token:

```bash
./testnet-search \
  --server-url https://SERVER_IP:8443 \
  --name search \
  --secret your-shared-secret \
  --join-token <token> \
  --listen :443
```

## Network requirements

| Role | Inbound | Outbound |
|------|---------|----------|
| Passive node | TCP 443 (from server DNAT) | TCP 8443 to server (cert fetch at startup) |
| Active node | TCP 443 (from server DNAT) | TCP 8443 to server + UDP 51820 (WireGuard tunnel) |

## Tips

- **Domain choice**: You can claim real-world domain names (e.g. `google.com`) since testnet DNS is authoritative and isolated. Agents will believe they're talking to the real service.
- **Auto-names**: Every node automatically gets `{name}.testnet` as a domain, even if no explicit domains are declared. This is useful for infrastructure services like `search.testnet`.
- **CA cert for outbound requests**: When making HTTPS requests to other testnet nodes, build a custom `tls.Config` with the testnet CA cert in the root pool. The standard system CA store won't trust testnet certificates.
- **DNS resolution**: Inside the WireGuard tunnel, configure your resolver to use the testnet DNS. The DNS VIP address (typically `10.100.0.1`) is returned in the `dns_ip` field of the client registration response. Use a custom `net.Resolver` with a dialer pointed at `{dns_ip}:53`, or configure the system resolver.
- **Health checks**: Implement a `/health` endpoint. While not required by the control plane today, it's good practice and may be used for monitoring in the future.
- **Graceful reload**: Poll `GET /api/v1/domains` periodically to discover new nodes without restarting. The server supports live reload of `nodes.yaml` via `SIGHUP`.
