#!/usr/bin/env bash
#
# Deploy testnet-search to AWS -- one command, fully running service.
#
# Usage:
#   NODE_SECRET=mysecret JOIN_TOKEN=xxx SERVER_IP=1.2.3.4 bash deploy/deploy.sh deploy
#   bash deploy/deploy.sh test [--quick]
#   bash deploy/deploy.sh restart
#   bash deploy/deploy.sh teardown
#   bash deploy/deploy.sh status
#   bash deploy/deploy.sh ssh [-- <remote command>]
#
# Prerequisites:
#   - AWS CLI configured (aws sts get-caller-identity)
#   - Existing agent-testnet deployed (deploy/.aws-state.json in agent-testnet repo)
#   - Join token and server IP obtained from the testnet server operator
#
# After deploy, ask the server operator to add the following to nodes.yaml
# and reload the server (SIGHUP). The deploy command prints the exact YAML.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STATE_FILE="${SCRIPT_DIR}/.aws-state.json"

TESTNET_DIR="${PROJECT_DIR}/../agent-testnet"
TESTNET_STATE="${TESTNET_DIR}/deploy/.aws-state.json"

REGION="eu-west-1"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
NODE_NAME="search"
NODE_SECRET="${NODE_SECRET:-}"
JOIN_TOKEN="${JOIN_TOKEN:-}"
SERVER_IP="${SERVER_IP:-}"

TOOLKIT_VERSION="${TOOLKIT_VERSION:-latest}"

# ---- helpers ----

info()  { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33mWARN:\033[0m %s\n" "$*"; }
err()   { printf "\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }

save_state() {
    local key="$1" value="$2"
    [ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"
    local tmp="${STATE_FILE}.tmp"
    python3 -c "
import json, sys
with open('$STATE_FILE') as f: state = json.load(f)
state['$key'] = '$value'
with open('$tmp', 'w') as f: json.dump(state, f, indent=2)
"
    mv "$tmp" "$STATE_FILE"
}

load_state() {
    local key="$1" file="${2:-$STATE_FILE}"
    [ -f "$file" ] || { echo ""; return; }
    python3 -c "
import json
with open('$file') as f: state = json.load(f)
print(state.get('$key', ''))
"
}

find_key_file() {
    if [ -n "${SSH_KEY:-}" ] && [ -f "$SSH_KEY" ]; then
        echo "$SSH_KEY"; return
    fi
    local candidate
    candidate=$(load_state "key_file" 2>/dev/null)
    [ -n "$candidate" ] && [ -f "$candidate" ] && { echo "$candidate"; return; }
    candidate=$(load_state "key_file" "$TESTNET_STATE" 2>/dev/null)
    [ -n "$candidate" ] && [ -f "$candidate" ] && { echo "$candidate"; return; }
    for f in ~/.ssh/testnet-key.pem ~/.ssh/testnet-deploy-key.pem; do
        [ -f "$f" ] && { echo "$f"; return; }
    done
    echo ""
}

push_key() {
    local instance_id="$1"
    aws ec2-instance-connect send-ssh-public-key \
        --region "$REGION" \
        --instance-id "$instance_id" \
        --instance-os-user ubuntu \
        --ssh-public-key "$(ssh-keygen -y -f "$KEY_FILE" 2>/dev/null)" \
        >/dev/null 2>&1
}

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o IdentitiesOnly=yes"

remote() {
    local inst_id="$1" ip="$2"; shift 2
    push_key "$inst_id"
    ssh $SSH_OPTS -i "$KEY_FILE" "ubuntu@${ip}" "$@"
}

remote_copy() {
    local inst_id="$1" src="$2" dest="$3"
    push_key "$inst_id"
    scp $SSH_OPTS -i "$KEY_FILE" "$src" "$dest"
}

wait_for_ssh() {
    local inst_id="$1" ip="$2" max_attempts=40 attempt=0
    info "Waiting for SSH on ${ip}..."
    while [ $attempt -lt $max_attempts ]; do
        if push_key "$inst_id" 2>/dev/null && \
           ssh $SSH_OPTS -o ConnectTimeout=5 -i "$KEY_FILE" "ubuntu@${ip}" "echo ready" >/dev/null 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 5
    done
    err "SSH to ${ip} timed out after $((max_attempts * 5))s"
}

require_state() {
    [ -f "$STATE_FILE" ] || err "No state file found. Run 'deploy' first."
}

resolve_key() {
    KEY_FILE=$(find_key_file)
    [ -n "$KEY_FILE" ] || err "SSH key not found. Set SSH_KEY=/path/to/key.pem or run deploy first."
}

# ---- deploy ----

do_deploy() {
    info "Deploying testnet-search to AWS (${REGION})"

    # Validate inputs
    [ -n "$NODE_SECRET" ] || err "NODE_SECRET is required"
    [ -n "$JOIN_TOKEN" ]  || err "JOIN_TOKEN is required (obtain from the testnet server operator)"
    [ -n "$SERVER_IP" ]   || err "SERVER_IP is required (public IP of the testnet server)"
    [ -f "$TESTNET_STATE" ] || err "Agent-testnet state not found at ${TESTNET_STATE}. Deploy agent-testnet first."
    aws sts get-caller-identity >/dev/null 2>&1 || err "AWS CLI not configured"

    # Load infra from testnet state (VPC/subnet/SG -- not the server itself)
    KEY_FILE=$(load_state "key_file" "$TESTNET_STATE")
    SUBNET_ID=$(load_state "subnet_id" "$TESTNET_STATE")
    SG_NODE=$(load_state "sg_node" "$TESTNET_STATE")

    [ -f "$KEY_FILE" ] || err "SSH key not found: ${KEY_FILE}"
    [ -n "$SUBNET_ID" ] || err "No subnet_id in testnet state"
    [ -n "$SG_NODE" ]   || err "No sg_node in testnet state"
    save_state "key_file" "$KEY_FILE"
    save_state "server_ip" "$SERVER_IP"

    info "Testnet server at ${SERVER_IP}"

    # Teardown old search instance if re-deploying
    OLD_INST=$(load_state "instance_id" 2>/dev/null || echo "")
    if [ -n "$OLD_INST" ]; then
        OLD_STATE=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$OLD_INST" \
            --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "terminated")
        if [ "$OLD_STATE" = "running" ]; then
            info "Terminating old search instance ${OLD_INST}..."
            aws ec2 terminate-instances --region "$REGION" --instance-ids "$OLD_INST" >/dev/null 2>&1 || true
            aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$OLD_INST" 2>/dev/null || true
        fi
    fi

    # Find AMI
    info "Finding Ubuntu 24.04 AMI..."
    AMI_ID=$(aws ec2 describe-images \
        --region "$REGION" --owners 099720109477 \
        --filters \
            "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
            "Name=state,Values=available" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text)
    [ "$AMI_ID" != "None" ] && [ -n "$AMI_ID" ] || err "Could not find Ubuntu 24.04 AMI"
    info "Using AMI: ${AMI_ID}"

    # Launch instance with cloud-init that installs deps + testnet-toolkit
    USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y golang-go gcc libsqlite3-dev wireguard-tools jq curl dnsutils

# Install testnet-toolkit
ARCH=$(dpkg --print-architecture)
TOOLKIT_URL="https://github.com/SpiritOfLogic/agent-testnet/releases/latest/download/testnet-toolkit-linux-${ARCH}"
curl -fsSL -o /usr/local/bin/testnet-toolkit "$TOOLKIT_URL"
chmod +x /usr/local/bin/testnet-toolkit
USERDATA
)

    info "Launching ${INSTANCE_TYPE} instance..."
    INSTANCE_ID=$(aws ec2 run-instances \
        --region "$REGION" \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "testnet-deploy-key" \
        --subnet-id "$SUBNET_ID" \
        --security-group-ids "$SG_NODE" \
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":20,"VolumeType":"gp3"}}]' \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=testnet-search},{Key=testnet-stack,Value=agent-testnet}]" \
        --user-data "$USER_DATA" \
        --query 'Instances[0].InstanceId' --output text)
    save_state "instance_id" "$INSTANCE_ID"
    info "Instance: ${INSTANCE_ID}"

    info "Waiting for instance to be running..."
    aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

    IP_SEARCH=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
    save_state "ip_search" "$IP_SEARCH"
    info "Search instance IP: ${IP_SEARCH}"

    # Wait for SSH + cloud-init
    wait_for_ssh "$INSTANCE_ID" "$IP_SEARCH"

    info "Waiting for package installation (cloud-init)..."
    for _ in $(seq 1 60); do
        if remote "$INSTANCE_ID" "$IP_SEARCH" "test -f /var/lib/cloud/instance/boot-finished" 2>/dev/null; then
            break
        fi
        sleep 5
    done
    info "Cloud-init finished"

    remote "$INSTANCE_ID" "$IP_SEARCH" "go version" || err "Go not installed on instance"
    remote "$INSTANCE_ID" "$IP_SEARCH" "testnet-toolkit --help >/dev/null 2>&1" || err "testnet-toolkit not installed on instance"

    # Copy source + build (no agent-testnet dependency needed)
    info "Packaging source code..."
    STAGING=$(mktemp -d)
    trap "rm -rf '$STAGING'" EXIT
    mkdir -p "${STAGING}/testnet-search"
    rsync -a --exclude='.DS_Store' --exclude='testnet-search' \
        --exclude='deploy/.aws-state.json' --exclude='data/' \
        "$PROJECT_DIR/" "${STAGING}/testnet-search/"
    tar -C "$STAGING" -czf /tmp/testnet-search-src.tar.gz .

    info "Copying source to instance..."
    remote_copy "$INSTANCE_ID" /tmp/testnet-search-src.tar.gz "ubuntu@${IP_SEARCH}:/tmp/"

    info "Building testnet-search on instance..."
    remote "$INSTANCE_ID" "$IP_SEARCH" "
        set -e
        mkdir -p ~/build && cd ~/build
        tar xzf /tmp/testnet-search-src.tar.gz
        cd testnet-search
        CGO_ENABLED=1 go build -tags fts5 -o testnet-search . 2>&1
        sudo mv testnet-search /usr/local/bin/
        sudo chmod +x /usr/local/bin/testnet-search
    "
    info "Binary built and installed"

    # Register WG client + set up tunnel
    info "Setting up WireGuard tunnel..."
    remote "$INSTANCE_ID" "$IP_SEARCH" "
        set -e

        WG_PRIVKEY=\$(wg genkey)
        WG_PUBKEY=\$(echo \"\${WG_PRIVKEY}\" | wg pubkey)

        RESPONSE=\$(curl -sk -X POST https://${SERVER_IP}:8443/api/v1/clients/register \
            -H @- \
            -H 'Content-Type: application/json' \
            -d \"{\\\"wg_public_key\\\": \\\"\${WG_PUBKEY}\\\"}\" <<AUTHEOF
Authorization: Bearer ${JOIN_TOKEN}
AUTHEOF
        )

        API_TOKEN=\$(echo \"\${RESPONSE}\" | jq -r '.api_token')
        TUNNEL_CIDR=\$(echo \"\${RESPONSE}\" | jq -r '.tunnel_cidr')
        SERVER_WG_KEY=\$(echo \"\${RESPONSE}\" | jq -r '.server_wg_public_key')
        DNS_IP=\$(echo \"\${RESPONSE}\" | jq -r '.dns_ip')

        [ \"\${API_TOKEN}\" != \"null\" ] && [ -n \"\${API_TOKEN}\" ] || { echo 'ERROR: client registration failed'; echo \"Response: \${RESPONSE}\"; exit 1; }
        echo \"Registered: client tunnel=\${TUNNEL_CIDR} dns=\${DNS_IP}\"

        TUNNEL_IP=\$(python3 -c \"
import ipaddress, sys
net = ipaddress.ip_network('\${TUNNEL_CIDR}', strict=False)
print(str(net.network_address + 1) + '/' + str(net.prefixlen))
\")

        sudo tee /etc/wireguard/wg0.conf > /dev/null <<WGEOF
[Interface]
PrivateKey = \${WG_PRIVKEY}
Address = \${TUNNEL_IP}

[Peer]
PublicKey = \${SERVER_WG_KEY}
Endpoint = ${SERVER_IP}:51820
AllowedIPs = 10.99.0.0/16, 10.100.0.0/16
PersistentKeepalive = 25
WGEOF
        sudo chmod 600 /etc/wireguard/wg0.conf

        sudo systemctl enable wg-quick@wg0
        sudo systemctl start wg-quick@wg0

        echo 'Waiting for WireGuard handshake...'
        for i in \$(seq 1 15); do
            if sudo wg show wg0 | grep -q 'latest handshake'; then
                echo 'WireGuard handshake established'
                break
            fi
            sleep 2
        done
        sudo wg show wg0

        echo 'Testing DNS through tunnel...'
        dig @\${DNS_IP} +short +timeout=5 google.com || echo '(DNS not resolving yet -- will work after node is registered on the server)'

        # Create dirs and env file for toolkit + services
        sudo mkdir -p /etc/testnet-search /etc/testnet/certs /var/lib/testnet-search
        sudo tee /etc/testnet-search/env > /dev/null <<ENVEOF
SERVER_URL=https://${SERVER_IP}:8443
NODE_SECRET=${NODE_SECRET}
API_TOKEN=\${API_TOKEN}
DNS_IP=\${DNS_IP}
ENVEOF
        sudo chmod 600 /etc/testnet-search/env
    "
    info "WireGuard tunnel established"

    # Install systemd units
    info "Installing systemd units..."
    for unit in testnet-search-server.service testnet-search-crawler.service testnet-search-seeds.service testnet-search-seeds.timer; do
        remote_copy "$INSTANCE_ID" "${SCRIPT_DIR}/${unit}" "ubuntu@${IP_SEARCH}:/tmp/"
    done
    remote "$INSTANCE_ID" "$IP_SEARCH" "
        sudo mv /tmp/testnet-search-server.service /etc/systemd/system/
        sudo mv /tmp/testnet-search-crawler.service /etc/systemd/system/
        sudo mv /tmp/testnet-search-seeds.service /etc/systemd/system/
        sudo mv /tmp/testnet-search-seeds.timer /etc/systemd/system/
        sudo systemctl daemon-reload
        sudo systemctl enable testnet-search-server testnet-search-crawler testnet-search-seeds.timer
    "

    # Print operator instructions (node registration must be done by the server operator)
    echo ""
    echo "============================================"
    echo "  Instance ready -- node registration needed"
    echo "============================================"
    echo ""
    echo "  Instance:  ${INSTANCE_ID} (${INSTANCE_TYPE})"
    echo "  Public IP: ${IP_SEARCH}"
    echo ""
    echo "  Ask the testnet server operator to add the following"
    echo "  entry to nodes.yaml and reload (kill -HUP <pid>):"
    echo ""
    echo "    - name: \"search\""
    echo "      address: \"${IP_SEARCH}:443\""
    echo "      secret: \"${NODE_SECRET}\""
    echo "      domains:"
    echo "        - \"search.testnet\""
    echo "        - \"google.com\""
    echo ""
    echo "  Once the operator confirms the node is registered,"
    echo "  start the service:"
    echo ""
    echo "    bash deploy/deploy.sh restart"
    echo ""
    echo "  Or if you know the node is already registered:"
    echo ""

    # Start services
    info "Starting testnet-search services..."
    sleep 3
    remote "$INSTANCE_ID" "$IP_SEARCH" "
        sudo systemctl start testnet-search-server
        sleep 3
        sudo systemctl start testnet-search-crawler
        sudo systemctl start testnet-search-seeds.timer
        sleep 4

        echo '=== Server service status ==='
        sudo systemctl is-active testnet-search-server || true

        echo '=== Crawler service status ==='
        sudo systemctl is-active testnet-search-crawler || true

        echo '=== Seeds timer status ==='
        sudo systemctl is-active testnet-search-seeds.timer || true

        echo '=== Health check ==='
        curl -sk https://localhost/health && echo '' || echo 'WARN: health check failed (node may not be registered on the server yet)'

        echo '=== Recent server logs ==='
        sudo journalctl -u testnet-search-server --since '10 sec ago' --no-pager -n 20

        echo '=== Recent crawler logs ==='
        sudo journalctl -u testnet-search-crawler --since '10 sec ago' --no-pager -n 20
    "

    echo ""
    echo "  Commands:"
    echo "    bash deploy/deploy.sh test       # verify everything works"
    echo "    bash deploy/deploy.sh restart     # restart + refetch certs"
    echo "    bash deploy/deploy.sh ssh         # shell into the instance"
    echo "    bash deploy/deploy.sh teardown    # terminate the instance"
    echo ""
}

# ---- test ----

do_test() {
    require_state
    resolve_key

    local quick=false
    [ "${1:-}" = "--quick" ] && quick=true

    local PASS=0 FAIL=0 SKIP=0
    t_pass() { PASS=$((PASS + 1)); printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
    t_fail() { FAIL=$((FAIL + 1)); printf "  \033[1;31m✗\033[0m %s\n" "$*"; }
    t_skip() { SKIP=$((SKIP + 1)); printf "  \033[1;33m–\033[0m %s (skipped)\n" "$*"; }
    t_section() { printf "\n\033[1;36m── %s ──\033[0m\n" "$*"; }
    t_val() { echo "$CHECK_OUTPUT" | grep "^${1}=" | head -1 | cut -d= -f2-; }

    local INSTANCE_ID IP_SEARCH
    INSTANCE_ID=$(load_state "instance_id")
    IP_SEARCH=$(load_state "ip_search")

    [ -n "$INSTANCE_ID" ] || err "instance_id missing from state"
    [ -n "$IP_SEARCH" ]   || err "ip_search missing from state"

    echo ""
    echo "Testing testnet-search deployment"
    echo "  Instance: ${INSTANCE_ID}"
    echo "  IP:       ${IP_SEARCH}"
    echo "  Key:      ${KEY_FILE}"

    local ssh_ok=false
    if ! $quick; then ssh_ok=true; fi

    # -- EC2 instance --

    t_section "EC2 Instance"

    local inst_state
    inst_state=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "error")
    [ "$inst_state" = "running" ] && t_pass "Instance is running" || t_fail "Instance state: ${inst_state}"

    local status_ok system_ok
    status_ok=$(aws ec2 describe-instance-status --region "$REGION" --instance-ids "$INSTANCE_ID" \
        --query 'InstanceStatuses[0].InstanceStatus.Status' --output text 2>/dev/null || echo "unknown")
    system_ok=$(aws ec2 describe-instance-status --region "$REGION" --instance-ids "$INSTANCE_ID" \
        --query 'InstanceStatuses[0].SystemStatus.Status' --output text 2>/dev/null || echo "unknown")
    if [ "$status_ok" = "ok" ] && [ "$system_ok" = "ok" ]; then
        t_pass "Instance status checks: OK"
    else
        t_fail "Instance status checks: instance=${status_ok} system=${system_ok}"
    fi

    # -- On-instance checks (single batched SSH call) --

    t_section "On-Instance Checks"

    if ! $ssh_ok; then
        t_skip "SSH connectivity"
        t_skip "systemd services"
        t_skip "WireGuard tunnel"
        t_skip "HTTPS endpoints"
        t_skip "JSON API"
        t_skip "Process health"
    else
        local CHECK_OUTPUT
        CHECK_OUTPUT=$(remote "$INSTANCE_ID" "$IP_SEARCH" "
            echo 'MARKER_SSH_OK'

            echo \"wg_active=\$(systemctl is-active wg-quick@wg0 2>/dev/null || echo inactive)\"
            echo \"server_active=\$(systemctl is-active testnet-search-server 2>/dev/null || echo inactive)\"
            echo \"server_enabled=\$(systemctl is-enabled testnet-search-server 2>/dev/null || echo disabled)\"
            echo \"crawler_active=\$(systemctl is-active testnet-search-crawler 2>/dev/null || echo inactive)\"
            echo \"crawler_enabled=\$(systemctl is-enabled testnet-search-crawler 2>/dev/null || echo disabled)\"
            echo \"seeds_timer_active=\$(systemctl is-active testnet-search-seeds.timer 2>/dev/null || echo inactive)\"

            WG_INFO=\$(sudo wg show wg0 2>/dev/null || echo '')
            if echo \"\${WG_INFO}\" | grep -q 'latest handshake'; then
                echo 'wg_handshake=yes'
            else
                echo 'wg_handshake=no'
            fi
            DNS_IP=\$(sudo grep DNS_IP /etc/testnet-search/env 2>/dev/null | cut -d= -f2 || echo '10.100.0.1')
            DNS_RESULT=\$(dig @\${DNS_IP} search.testnet +short +timeout=3 2>/dev/null || echo '')
            echo \"dns_result=\${DNS_RESULT}\"

            echo \"health=\$(curl -sk --connect-timeout 5 https://localhost/health 2>/dev/null || echo '')\"
            echo \"home_status=\$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 5 https://localhost/ 2>/dev/null || echo '000')\"
            HOME_BODY=\$(curl -sk --connect-timeout 5 https://localhost/ 2>/dev/null || echo '')
            if echo \"\${HOME_BODY}\" | grep -qi 'search'; then
                echo 'home_has_search=yes'
            else
                echo 'home_has_search=no'
            fi
            echo \"search_status=\$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 5 'https://localhost/search?q=test' 2>/dev/null || echo '000')\"
            echo \"browse_status=\$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 5 https://localhost/browse 2>/dev/null || echo '000')\"

            API_SEARCH=\$(curl -sk --connect-timeout 5 'https://localhost/api/search?q=test' 2>/dev/null || echo '{}')
            if echo \"\${API_SEARCH}\" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert \"query\" in d and \"results\" in d and \"pagination\" in d' 2>/dev/null; then
                echo 'api_search_valid=yes'
            else
                echo 'api_search_valid=no'
            fi
            API_BROWSE=\$(curl -sk --connect-timeout 5 https://localhost/api/browse 2>/dev/null || echo '')
            if echo \"\${API_BROWSE}\" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d, list)' 2>/dev/null; then
                echo 'api_browse_valid=yes'
            else
                echo 'api_browse_valid=no'
            fi
            echo \"api_no_q_status=\$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 5 'https://localhost/api/search' 2>/dev/null || echo '000')\"
            echo \"notfound_status=\$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 5 'https://localhost/nonexistent' 2>/dev/null || echo '000')\"

            echo \"proc_count=\$(pgrep -c testnet-search 2>/dev/null || echo 0)\"
            LISTEN=\$(sudo ss -tlnp 2>/dev/null | grep ':443 ' | head -1 || echo '')
            if echo \"\${LISTEN}\" | grep -q 'testnet-search'; then
                echo 'listen_443=yes'
            elif [ -n \"\${LISTEN}\" ]; then
                echo 'listen_443=other'
            else
                echo 'listen_443=no'
            fi
            echo \"disk_pct=\$(df / --output=pcent | tail -1 | tr -dc '0-9')\"

            echo \"toolkit_installed=\$(testnet-toolkit --help >/dev/null 2>&1 && echo yes || echo no)\"

            echo \"certs_exist=\$([ -f /etc/testnet/certs/cert.pem ] && [ -f /etc/testnet/certs/key.pem ] && [ -f /etc/testnet/certs/ca.pem ] && echo yes || echo no)\"
            echo \"seeds_exist=\$([ -f /var/lib/testnet-search/seeds.txt ] && echo yes || echo no)\"

            SRV_ERR=\$(sudo journalctl -u testnet-search-server --since '5 min ago' --no-pager -p err 2>/dev/null | grep -c '' || echo 0)
            CRL_ERR=\$(sudo journalctl -u testnet-search-crawler --since '5 min ago' --no-pager -p err 2>/dev/null | grep -c '' || echo 0)
            echo \"server_errors=\${SRV_ERR}\"
            echo \"crawler_errors=\${CRL_ERR}\"
        " 2>/dev/null || echo "SSH_FAILED")

        if echo "$CHECK_OUTPUT" | grep -qF 'MARKER_SSH_OK'; then
            t_pass "SSH reachable"
        else
            t_fail "SSH unreachable"
            t_skip "systemd services"; t_skip "WireGuard tunnel"; t_skip "HTTPS endpoints"
            t_skip "JSON API"; t_skip "Process health"
            ssh_ok=false
        fi

        if $ssh_ok; then
            # Services
            t_section "Services"
            [ "$(t_val wg_active)" = "active" ]           && t_pass "wg-quick@wg0 is active"                   || t_fail "wg-quick@wg0 is $(t_val wg_active)"
            [ "$(t_val server_active)" = "active" ]        && t_pass "testnet-search-server is active"          || t_fail "testnet-search-server is $(t_val server_active)"
            [ "$(t_val server_enabled)" = "enabled" ]      && t_pass "testnet-search-server is enabled (reboot)"|| t_fail "testnet-search-server is not enabled"
            [ "$(t_val crawler_active)" = "active" ]       && t_pass "testnet-search-crawler is active"         || t_fail "testnet-search-crawler is $(t_val crawler_active)"
            [ "$(t_val crawler_enabled)" = "enabled" ]     && t_pass "testnet-search-crawler is enabled (reboot)"|| t_fail "testnet-search-crawler is not enabled"
            [ "$(t_val seeds_timer_active)" = "active" ]   && t_pass "testnet-search-seeds.timer is active"     || t_fail "testnet-search-seeds.timer is $(t_val seeds_timer_active)"

            # Toolkit + files
            t_section "Toolkit & Files"
            [ "$(t_val toolkit_installed)" = "yes" ] && t_pass "testnet-toolkit installed" || t_fail "testnet-toolkit not installed"
            [ "$(t_val certs_exist)" = "yes" ]       && t_pass "TLS certs present in /etc/testnet/certs" || t_fail "TLS certs missing from /etc/testnet/certs"
            [ "$(t_val seeds_exist)" = "yes" ]       && t_pass "seeds.txt present" || t_fail "seeds.txt missing"

            # WireGuard
            t_section "WireGuard Tunnel"
            [ "$(t_val wg_handshake)" = "yes" ] && t_pass "WireGuard handshake present" || t_fail "No WireGuard handshake"
            local dns_result; dns_result=$(t_val dns_result)
            [ -n "$dns_result" ] && t_pass "DNS resolves search.testnet -> ${dns_result}" || t_fail "DNS cannot resolve search.testnet"

            # HTTPS endpoints
            t_section "HTTPS Endpoints"
            [ "$(t_val health)" = "OK" ]            && t_pass "/health returns OK"            || t_fail "/health returned: '$(t_val health)'"
            [ "$(t_val home_status)" = "200" ]       && t_pass "/ returns 200"                || t_fail "/ returned HTTP $(t_val home_status)"
            [ "$(t_val home_has_search)" = "yes" ]   && t_pass "/ contains search form"       || t_fail "/ does not contain search form"
            [ "$(t_val search_status)" = "200" ]     && t_pass "/search?q=test returns 200"   || t_fail "/search?q=test returned HTTP $(t_val search_status)"
            [ "$(t_val browse_status)" = "200" ]     && t_pass "/browse returns 200"          || t_fail "/browse returned HTTP $(t_val browse_status)"

            # JSON API
            t_section "JSON API"
            [ "$(t_val api_search_valid)" = "yes" ]  && t_pass "/api/search returns valid JSON (query, results, pagination)" || t_fail "/api/search JSON structure invalid"
            [ "$(t_val api_browse_valid)" = "yes" ]  && t_pass "/api/browse returns JSON array"                              || t_fail "/api/browse JSON structure invalid"
            local api_no_q; api_no_q=$(t_val api_no_q_status)
            [ "$api_no_q" = "400" ] && t_pass "/api/search without ?q returns 400" || t_fail "/api/search without ?q returned HTTP ${api_no_q} (expected 400)"
            local notfound; notfound=$(t_val notfound_status)
            [ "$notfound" = "404" ] && t_pass "/nonexistent returns 404" || t_fail "/nonexistent returned HTTP ${notfound} (expected 404)"

            # Process health
            t_section "Process Health"
            local proc_count; proc_count=$(t_val proc_count)
            if [ "$proc_count" = "2" ]; then t_pass "2 testnet-search processes running (server + crawler)"
            elif [ "$proc_count" = "1" ]; then t_fail "Only 1 testnet-search process (expected 2: server + crawler)"
            elif [ "$proc_count" = "0" ]; then t_fail "No testnet-search process found"
            else t_fail "${proc_count} testnet-search processes (expected 2)"; fi

            [ "$(t_val listen_443)" = "yes" ] && t_pass "testnet-search listening on :443" || t_fail "Port :443 not owned by testnet-search"

            local disk; disk=$(t_val disk_pct)
            [ "${disk:-0}" -lt 80 ] 2>/dev/null && t_pass "Disk usage: ${disk}%" || t_fail "Disk usage: ${disk}%"

            local srv_errs; srv_errs=$(t_val server_errors)
            [ "${srv_errs:-0}" -le 1 ] 2>/dev/null && t_pass "No recent server error-level log entries" || t_fail "${srv_errs} server error-level log entries in last 5 min"
            local crl_errs; crl_errs=$(t_val crawler_errors)
            [ "${crl_errs:-0}" -le 1 ] 2>/dev/null && t_pass "No recent crawler error-level log entries" || t_fail "${crl_errs} crawler error-level log entries in last 5 min"
        fi
    fi

    # -- Summary --

    local total=$((PASS + FAIL + SKIP))
    echo ""
    echo "======================================="
    printf "  \033[1;32m%d passed\033[0m  \033[1;31m%d failed\033[0m  \033[1;33m%d skipped\033[0m  (%d total)\n" "$PASS" "$FAIL" "$SKIP" "$total"
    echo "======================================="
    echo ""

    if [ "$FAIL" -gt 0 ]; then
        echo "Some checks failed. Inspect logs:"
        echo "  bash deploy/deploy.sh ssh -- sudo journalctl -u testnet-search-server --no-pager -n 50"
        echo "  bash deploy/deploy.sh ssh -- sudo journalctl -u testnet-search-crawler --no-pager -n 50"
        echo ""
        return 1
    fi
}

# ---- restart ----

do_restart() {
    require_state
    resolve_key

    local INSTANCE_ID IP_SEARCH
    INSTANCE_ID=$(load_state "instance_id")
    IP_SEARCH=$(load_state "ip_search")
    [ -n "$INSTANCE_ID" ] || err "instance_id missing from state"
    [ -n "$IP_SEARCH" ]   || err "ip_search missing from state"

    info "Restarting testnet-search services on ${IP_SEARCH}..."

    remote "$INSTANCE_ID" "$IP_SEARCH" "
        set -e

        echo 'Stopping services...'
        sudo systemctl stop testnet-search-crawler || true
        sudo systemctl stop testnet-search-server || true
        sudo systemctl stop testnet-search-seeds.timer || true

        echo 'Clearing cached TLS certificates (will be refetched on start)...'
        sudo rm -f /etc/testnet/certs/cert.pem /etc/testnet/certs/key.pem /etc/testnet/certs/ca.pem

        echo 'Starting server (will fetch fresh certs via ExecStartPre)...'
        sudo systemctl start testnet-search-server
        sleep 3

        echo 'Starting crawler (will fetch fresh seeds via ExecStartPre)...'
        sudo systemctl start testnet-search-crawler

        echo 'Starting seeds timer...'
        sudo systemctl start testnet-search-seeds.timer
        sleep 4

        echo '=== Server service status ==='
        sudo systemctl is-active testnet-search-server || true

        echo '=== Crawler service status ==='
        sudo systemctl is-active testnet-search-crawler || true

        echo '=== Health check ==='
        curl -sk --connect-timeout 5 https://localhost/health && echo '' || echo 'WARN: health check not passing yet'

        echo '=== Recent server logs ==='
        sudo journalctl -u testnet-search-server --since '15 sec ago' --no-pager -n 20

        echo '=== Recent crawler logs ==='
        sudo journalctl -u testnet-search-crawler --since '15 sec ago' --no-pager -n 20
    "

    info "Restart complete"
}

# ---- status ----

do_status() {
    require_state
    local inst_id ip state_name
    inst_id=$(load_state "instance_id")
    ip=$(load_state "ip_search")
    state_name=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$inst_id" \
        --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "unknown")

    echo ""
    echo "testnet-search Status"
    echo "====================="
    printf "  Instance:  %-22s  %s\n" "$inst_id" "$state_name"
    printf "  Public IP: %s\n" "$ip"
    echo ""
    echo "  SSH:     bash deploy/deploy.sh ssh"
    echo "  Test:    bash deploy/deploy.sh test"
    echo "  Restart: bash deploy/deploy.sh restart"
    echo ""
}

# ---- ssh ----

do_ssh() {
    require_state
    resolve_key
    local ip inst_id
    ip=$(load_state "ip_search")
    inst_id=$(load_state "instance_id")
    [ -n "$ip" ] || err "No IP in state file"
    push_key "$inst_id"
    if [ $# -gt 0 ]; then
        ssh $SSH_OPTS -i "$KEY_FILE" "ubuntu@${ip}" "$@"
    else
        exec ssh -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -i "$KEY_FILE" "ubuntu@${ip}"
    fi
}

# ---- teardown ----

do_teardown() {
    require_state
    info "Tearing down testnet-search..."

    local inst_id ip_search
    inst_id=$(load_state "instance_id")
    ip_search=$(load_state "ip_search")

    if [ -n "$inst_id" ]; then
        info "Terminating instance: ${inst_id}..."
        aws ec2 terminate-instances --region "$REGION" --instance-ids "$inst_id" >/dev/null 2>&1 || true
        info "Waiting for termination..."
        aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$inst_id" 2>/dev/null || true
    fi

    rm -f "$STATE_FILE"
    info "Teardown complete."

    echo ""
    echo "  Ask the testnet server operator to remove the \"search\""
    echo "  node from nodes.yaml and reload the server."
    echo ""
}

# ---- reindex ----

do_reindex() {
    require_state
    resolve_key

    local INSTANCE_ID IP_SEARCH
    INSTANCE_ID=$(load_state "instance_id")
    IP_SEARCH=$(load_state "ip_search")
    [ -n "$INSTANCE_ID" ] || err "instance_id missing from state"
    [ -n "$IP_SEARCH" ]   || err "ip_search missing from state"

    info "Triggering re-index on ${IP_SEARCH}..."

    # Refresh seeds, then restart the crawler (initial crawl runs immediately on start)
    remote "$INSTANCE_ID" "$IP_SEARCH" "
        set -e

        echo 'Refreshing seed domains...'
        sudo systemctl start testnet-search-seeds.service
        echo \"Seeds: \$(cat /var/lib/testnet-search/seeds.txt | wc -l) domains\"
        cat /var/lib/testnet-search/seeds.txt

        echo ''
        echo 'Restarting crawler (triggers immediate crawl)...'
        sudo systemctl restart testnet-search-crawler

        DOMAIN_COUNT=\$(cat /var/lib/testnet-search/seeds.txt | wc -l)
        echo \"Waiting for crawl to finish (\${DOMAIN_COUNT} domains)...\"
        for i in \$(seq 1 120); do
            FINISHED=\$(sudo journalctl -u testnet-search-crawler --since '5 min ago' --no-pager 2>/dev/null | grep -c 'finished.*pages indexed' || true)
            if [ \"\${FINISHED}\" -ge \"\${DOMAIN_COUNT}\" ]; then
                echo \"All \${DOMAIN_COUNT} domains crawled.\"
                break
            fi
            if [ \$((i % 10)) -eq 0 ]; then
                echo \"  ... \${FINISHED}/\${DOMAIN_COUNT} domains done, waiting...\"
            fi
            sleep 3
        done

        echo ''
        echo '=== Crawler status ==='
        sudo systemctl is-active testnet-search-crawler || true

        echo ''
        echo '=== Crawler logs (last 30 lines) ==='
        sudo journalctl -u testnet-search-crawler --since '10 min ago' --no-pager -n 30

        echo ''
        echo '=== Index stats ==='
        curl -sk https://localhost/api/browse 2>/dev/null | python3 -m json.tool 2>/dev/null || curl -sk https://localhost/api/browse 2>/dev/null || echo '(could not query index)'
    "

    info "Re-index complete"
}

# ---- main ----

ACTION="${1:-}"
case "$ACTION" in
    deploy)   do_deploy ;;
    test)     shift; do_test "$@" ;;
    restart)  do_restart ;;
    reindex)  do_reindex ;;
    teardown) do_teardown ;;
    status)   do_status ;;
    ssh)      shift; do_ssh "$@" ;;
    "")       err "Usage: $0 <deploy|test|restart|reindex|teardown|status|ssh>" ;;
    *)        err "Unknown action: $ACTION. Use: deploy, test, restart, reindex, teardown, status, ssh" ;;
esac
