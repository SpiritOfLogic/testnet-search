# AWS Deploy Script Conventions

Reference for all testnet repos (`agent-testnet`, `testnet-forum`, `testnet-mail`, `testnet-search`, and future nodes). The canonical implementation lives in `agent-testnet/deploy/aws-deploy.sh`.

## 1. File Layout

```
<repo>/
  deploy/
    aws-deploy.sh           # the deploy script
    .aws-state.json          # state file (gitignored)
    .aws-<prefix>-key.pem   # SSH key (gitignored)
    install.sh               # optional on-instance setup script
```

All three runtime files (state, key, any temp artifacts) live under `deploy/` and must be `.gitignore`d. The script itself is committed.

## 2. Required Actions

Every deploy script must support at least these seven actions:

| Action | Description |
|--------|-------------|
| `deploy` | Provision AWS resources and deploy the service. Detect existing deployment and refuse (or offer redeploy). |
| `teardown` | Soft teardown: terminate instance, delete VPC/SG/key, but preserve EIP + data volume. |
| `teardown --full` | Full teardown: also release EIP, delete data volume, remove state file entirely. |
| `status` | Print instance state, IP, and a service-specific health check. |
| `ssh` | Open interactive SSH session. Accept `-- <command>` for non-interactive use. |
| `redeploy` | Re-upload code/config and restart services on the running instance (no infra changes). |
| `restart` | Restart services without re-uploading code. |
| `logs` | Tail service logs (`journalctl` or `docker compose logs`). |

Scripts may add domain-specific actions (`test`, `reload`, `reindex`, etc.) as needed.

### Dispatch

```bash
ACTION="${1:-}"
case "$ACTION" in
    deploy)   do_deploy ;;
    teardown) do_teardown "${2:-}" ;;
    status)   do_status ;;
    ssh)      shift; do_ssh "$@" ;;
    redeploy) do_redeploy ;;
    restart)  do_restart ;;
    logs)     do_logs ;;
    "")       err "Usage: $0 <deploy|teardown [--full]|status|ssh|redeploy|restart|logs>" ;;
    *)        err "Unknown action: $ACTION" ;;
esac
```

## 3. Persistence: Elastic IP + EBS Data Volume

Every node must follow the same persistence scheme so that teardown+deploy cycles preserve identity and state.

### Elastic IP

- Allocate on first deploy, associate with the instance.
- On soft teardown, keep the EIP. On `--full`, release it.
- On re-deploy, reuse the existing EIP from state.
- State keys: `eip_alloc_id`, `eip_public_ip`.
- Benefit: the node's IP never changes, so `nodes.yaml` on the server never needs updating.

### EBS Data Volume

- Create a GP3 volume on first deploy, attach and mount at the node's data directory.
- On soft teardown, detach but keep. On `--full`, delete it.
- On re-deploy, reattach the existing volume (skip formatting -- data persists).
- State keys: `vol_<role>`, `az`.
- Mount point and size are node-specific:

| Node | Mount point | Size | What persists |
|------|-------------|------|---------------|
| agent-testnet server | `/opt/testnet/data` | 5 GiB | CA keys, WG key, TLS certs, join token, traffic logs |
| agent-testnet client | `/root/.testnet` | 20 GiB | Daemon state, WG keys, VM rootfs, OpenClaw workspace |
| agent-testnet node | `/opt/testnet` | 10 GiB | TLS certs, working directory |
| testnet-forum | `/opt/testnet-forum` | 15 GiB | Lemmy DB, nginx config, Docker volumes |
| testnet-mail | `/opt/testnet-mail` | 10 GiB | Mailboxes, Docker volumes, TLS certs |
| testnet-search | `/var/lib/testnet-search` | 10 GiB | Search index, crawl data, TLS certs |

### Required Helper Functions

These should be copied from agent-testnet or kept in sync:

```bash
ensure_eip()
# Allocate or reuse EIP. Sets EIP_ALLOC and EIP_PUBLIC.
# Reads/writes state keys: eip_alloc_id, eip_public_ip

associate_eip() { local instance_id="$1"; ... }
# Associate EIP_ALLOC with the given instance.

ensure_volume() { local role="$1" size="$2" az="$3"; ... }
# Create or reuse a GP3 data volume. Echoes the volume ID.
# Reads/writes state key: vol_<role>

attach_and_mount_volume() { local vol_id="$1" instance_id="$2" ip="$3" key="$4" mount_point="$5"; ... }
# Attach volume, wait, format if new (blkid check), mount.
# Handles both /dev/xvdf (Xen) and /dev/nvme1n1 (Nitro).

detach_volume() { local role="$1"; ... }
# Detach volume if in-use. Called before instance termination.

delete_volume() { local role="$1"; ... }
# Delete volume. Called only during --full teardown.
```

### Teardown State Split

On soft teardown, the state file is pruned to keep only persistent keys:

```
eip_alloc_id, eip_public_ip, vol_<role>, az
```

Everything else (instance IDs, VPC, SG, key name, IPs) is removed. On `--full`, the state file is deleted entirely.

## 4. State File Format

JSON object at `deploy/.aws-state.json`, managed via `save_state`/`load_state` using python3:

```bash
save_state() {
    local key="$1" value="$2"
    [ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"
    local tmp="${STATE_FILE}.tmp"
    python3 -c "
import json
with open('$STATE_FILE') as f: state = json.load(f)
state['$key'] = '$value'
with open('$tmp', 'w') as f: json.dump(state, f, indent=2)
"
    mv "$tmp" "$STATE_FILE"
}

load_state() {
    local key="$1"
    [ -f "$STATE_FILE" ] || { echo ""; return; }
    python3 -c "
import json
with open('$STATE_FILE') as f: state = json.load(f)
print(state.get('$key', ''))
"
}
```

State keys are `snake_case`. Common keys across all scripts:

| Key | Description |
|-----|-------------|
| `eip_alloc_id` | Elastic IP allocation ID |
| `eip_public_ip` | Elastic IP address |
| `vol_<role>` | EBS data volume ID |
| `az` | Availability zone (volumes must match instance AZ) |
| `instance_<role>` | EC2 instance ID |
| `ip_<role>` | Instance public IP |
| `vpc_id` | VPC ID (agent-testnet only, others use default VPC) |
| `key_name` | SSH key pair name |
| `key_file` | Path to local SSH key file |

## 5. Shell Conventions

### Header

```bash
#!/usr/bin/env bash
set -euo pipefail
```

### Log Helpers

```bash
info()  { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33mWARN:\033[0m %s\n" "$*"; }
err()   { printf "\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }
```

### SSH Helpers

```bash
wait_for_ssh() {
    local ip="$1" key="$2" max_attempts=40 attempt=0
    info "Waiting for SSH on ${ip}..."
    while [ $attempt -lt $max_attempts ]; do
        if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes \
            -i "$key" "ubuntu@${ip}" "echo ready" >/dev/null 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 5
    done
    err "SSH to ${ip} timed out after $((max_attempts * 5))s"
}

remote_exec() {
    local ip="$1" key="$2"; shift 2
    ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -i "$key" "ubuntu@${ip}" "$@"
}

remote_copy() {
    local key="$1" src="$2" dest="$3"
    scp -o StrictHostKeyChecking=accept-new -o BatchMode=yes -i "$key" "$src" "$dest"
}
```

### Region

```bash
REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo "eu-west-1")}"
```

### Directory Variables

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STATE_FILE="${STATE_FILE:-${SCRIPT_DIR}/.aws-state.json}"
```

## 6. Resource Tagging

All AWS resources (instances, volumes, EIPs, security groups, VPCs) must be tagged:

| Tag | Value |
|-----|-------|
| `testnet-stack` | `agent-testnet` (or repo-specific value via `STACK_VALUE`) |
| `Name` | `<prefix>-<resource>` (e.g. `testnet-server`, `testnet-forum`) |

Use a `tag_spec` helper:

```bash
STACK_TAG="testnet-stack"
STACK_VALUE="${STACK_VALUE:-agent-testnet}"
STACK_PREFIX="${STACK_PREFIX:-testnet}"

tag_spec() {
    echo "ResourceType=$1,Tags=[{Key=${STACK_TAG},Value=${STACK_VALUE}},{Key=Name,Value=${STACK_PREFIX}-$2}]"
}
```

## 7. Usage Header

Every script must start with a comment block listing all supported actions, required env vars, and prerequisites:

```bash
#!/usr/bin/env bash
#
# Deploy <service-name> to AWS.
#
# Usage:
#   bash deploy/aws-deploy.sh deploy          # Provision + deploy
#   bash deploy/aws-deploy.sh teardown        # Soft teardown (keeps EIP + data volume)
#   bash deploy/aws-deploy.sh teardown --full # Full teardown (destroys everything)
#   bash deploy/aws-deploy.sh status          # Instance state + health check
#   bash deploy/aws-deploy.sh ssh             # Interactive SSH session
#   bash deploy/aws-deploy.sh redeploy        # Re-upload code + restart
#   bash deploy/aws-deploy.sh restart         # Restart services only
#   bash deploy/aws-deploy.sh logs            # Tail service logs
#
# Required env vars (deploy only):
#   SERVER_URL    Testnet control plane URL
#   NODE_NAME     Node name in nodes.yaml
#   NODE_SECRET   Shared secret from nodes.yaml
#
# Prerequisites:
#   - AWS CLI configured (aws sts get-caller-identity)
#
```
