#!/usr/bin/env bash
# OSAC-5529 lab flow: boot/reuse SNO, build/push the updated AAP execution
# environment, install/upgrade OSAC, prepare the workspace Containerlab
# network node, then run the VirtualNetwork CLI/AAP E2E.
# Existing clusters and OSAC releases are reused; this script never destroys
# the SNO or Containerlab topology.
set -euo pipefail
umask 077

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AAP_DIR="${REPO_ROOT}/osac-aap"
INSTALLER_DIR="${REPO_ROOT}/osac-installer"
WORKSPACE_DIR="${REPO_ROOT}/../osac-workspace"
CONTAINERLAB_TOPOLOGY="${WORKSPACE_DIR}/agentless-net-lab.clab.yml"
CONTAINERLAB_INVENTORY="${WORKSPACE_DIR}/ansible/inventory.yml"
CONTAINERLAB_NAME="agentless-net-lab"
CONTAINERLAB_PREFIX="clab-${CONTAINERLAB_NAME}"
CONTAINERLAB_NET_NODE="${CONTAINERLAB_PREFIX}-net-node"
    CONTAINERLAB="${CONTAINERLAB:-containerlab}"
MGMT_CLONE_NAME="${MGMT_CLONE_NAME:-agentless-lab-mgmt}"
MGMT_VM_NAME="test-infra-cluster-${MGMT_CLONE_NAME}-master-0"
MGMT_LIBVIRT_NET="test-infra-net-${MGMT_CLONE_NAME}"
SNO_FLAVOR="${SNO_FLAVOR:-sno-4-22}"
SNO_IMAGE="${SNO_IMAGE:-quay.io/osac-project/cluster-flavors:sno-4-22}"
PULL_SECRET="${PULL_SECRET:-${OSAC_PULL_SECRET_PATH:-${INSTALLER_DIR}/values/caas-ci/pull-secret.json}}"
AAP_LICENSE_FILE="${AAP_LICENSE_FILE:-${INSTALLER_DIR}/values/caas-ci/license.zip}"
OSAC_PROFILE="${OSAC_PROFILE:-caas-ci}"
OSAC_INSTALL_MODE="${OSAC_INSTALL_MODE:-auto}"
KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/${MGMT_CLONE_NAME}.kubeconfig}"
export KUBECONFIG

CONTAINER_TOOL="${CONTAINER_TOOL:-podman}"
CURRENT_BRANCH="$(git -C "$REPO_ROOT" branch --show-current)"
CURRENT_COMMIT="$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD)"
AAP_IMAGE="${AAP_IMAGE:-quay.io/ybettan/osac-aap:osac-5529-${CURRENT_COMMIT}}"
AAP_PROJECT_GIT_URI="${AAP_PROJECT_GIT_URI:-https://github.com/ybettan/osac}"
AAP_PROJECT_GIT_BRANCH="${AAP_PROJECT_GIT_BRANCH:-${CURRENT_BRANCH}}"

OSAC_NAMESPACE="${OSAC_NAMESPACE:-osac-e2e-ci}"
OSAC_TENANT="${OSAC_TENANT:-osac-e2e-ci}"
OSAC_SERVICE_ACCOUNT="${OSAC_SERVICE_ACCOUNT:-osac-operator}"
NETWORKING_NAMESPACE="${OSAC_NETWORKING_NAMESPACE:-${OSAC_NAMESPACE}}"
AGENTLESS_NET_STATE_FILE="${AGENTLESS_NET_STATE_FILE:-/etc/osac/agentless_network_state.json}"
AGENTLESS_NET_HOST=""
AGENTLESS_NET_USER=""
MGMT_BRIDGE=""
MGMT_PREFIX=""
MGMT_CIDR=""
MGMT_GW=""
MGMT_DHCP_RANGES=""
AAP_NETWORKING_SECRET="network-fulfillment-ig"
AAP_EXECUTION_ENVIRONMENT_NAME="${AAP_EXECUTION_ENVIRONMENT_NAME:-osac-ee}"
AAP_SSH_KEY_SECRET_KEY="AGENTLESS_NET_SSH_PRIVATE_KEY"
AAP_SSH_KEY_SECRET_ANNOTATION="osac.openshift.io/agentless-vn-ssh"
VIRTUAL_NETWORK_NAME="${VIRTUAL_NETWORK_NAME:-agentless-smoke-vn-$(date -u +%Y%m%d%H%M%S)}"
PEER_VIRTUAL_NETWORK_NAME="${PEER_VIRTUAL_NETWORK_NAME:-${VIRTUAL_NETWORK_NAME}-peer}"
VIRTUAL_NETWORK_IPV4_CIDR="${VIRTUAL_NETWORK_IPV4_CIDR:-10.250.0.0/16}"

CLI_BIN="${OSAC_CLI_BIN:-}"
CLI_CONFIG_DIR="${OSAC_CLI_CONFIG_DIR:-}"
CLI_CA_FILE=""
TEMP_DIR=""
GENERATED_CLI_BIN=false
GENERATED_CLI_CONFIG=false
CREATED_IDS=()
BASELINE_STATE_FILE=""
CURRENT_STATE_FILE=""
SSH_PRIVATE_KEY_FILE=""
SSH_PUBLIC_KEY_FILE=""
SSH_KEY_CREATED_BY_RUN=false
SSH_KEY_EXPECTED_BASE64=""
SSH_PUBLIC_KEY_INSTALLED_BY_RUN=false
SSH_AUTHORIZED_KEYS_EXISTED=false
CONTAINERLAB_ACCESS_CONFIGURED=false
NETNODE_SUDOERS_CREATED_BY_RUN=false
NETNODE_SSHD_CREATED_BY_RUN=false
AAP_NETWORK_IG_ID=""
AAP_NETWORK_IG_CHANGED=false
AAP_NETWORK_IG_BACKUP=""
AAP_API_ROUTE=""
UPGRADE_VALUES_FILE=""

info() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

label_selector() { printf 'osac.openshift.io/virtualnetwork-uuid=%s' "$1"; }

resolve_mgmt_network() {
    local network_xml network_info
    MGMT_BRIDGE="$(virsh net-info "$MGMT_LIBVIRT_NET" | awk '/^Bridge:/{print $2}')" \
        || die "Could not find the libvirt bridge for $MGMT_LIBVIRT_NET"
    network_xml="$(virsh net-dumpxml "$MGMT_LIBVIRT_NET")" \
        || die "Could not read the libvirt network for $MGMT_LIBVIRT_NET"
    network_info="$(python3 -c '
import ipaddress, sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
node = root.find("ip")
if node is None:
    raise SystemExit("libvirt network has no IPv4 address")
gateway = ipaddress.IPv4Address(node.attrib["address"])
network_prefix = node.attrib.get("prefix", node.attrib.get("netmask", "24"))
network = ipaddress.IPv4Network(str(gateway) + "/" + network_prefix, strict=False)
if network.prefixlen != 24:
    raise SystemExit("the workspace Containerlab management network requires an IPv4 /24")
prefix = ".".join(str(gateway).split(".")[:3])
dhcp = node.find("dhcp")
ranges = [] if dhcp is None else [item.attrib["start"] + "-" + item.attrib["end"] for item in dhcp.findall("range")]
print(gateway, network, prefix, ",".join(ranges))
' <<<"$network_xml")" || die "Could not parse the SNO libvirt management network"
    read -r MGMT_GW MGMT_CIDR MGMT_PREFIX MGMT_DHCP_RANGES <<<"$network_info"
    [[ -n "$MGMT_BRIDGE" && -n "$MGMT_PREFIX" ]] \
        || die "The SNO libvirt management bridge configuration is incomplete"
}

ensure_aap_ssh_key() {
    local secret_json key_file annotation patch_file
    secret_json="$(oc get secret "$AAP_NETWORKING_SECRET" -n "$OSAC_NAMESPACE" -o json)" \
        || die "AAP networking Secret is missing after OSAC installation"
    key_file="$TEMP_DIR/agentless-net-id_ed25519"
    SSH_PUBLIC_KEY_FILE="$TEMP_DIR/agentless-net-id_ed25519.pub"
    if jq -e --arg key "$AAP_SSH_KEY_SECRET_KEY" '.data | has($key)' \
        <<<"$secret_json" >/dev/null; then
        jq -r --arg key "$AAP_SSH_KEY_SECRET_KEY" '.data[$key]' <<<"$secret_json" \
            | base64 -d >"$key_file"
        chmod 0600 "$key_file"
        annotation="$(jq -r --arg key "$AAP_SSH_KEY_SECRET_ANNOTATION" \
            '.metadata.annotations[$key] // ""' <<<"$secret_json")"
        if [[ "$annotation" == OSAC-5529 ]]; then
            SSH_KEY_CREATED_BY_RUN=true
            SSH_KEY_EXPECTED_BASE64="$(base64 -w0 "$key_file")"
        fi
    else
        annotation="$(jq -r --arg key "$AAP_SSH_KEY_SECRET_ANNOTATION" \
            '.metadata.annotations[$key] // ""' <<<"$secret_json")"
        [[ -z "$annotation" ]] \
            || die "Refusing to replace pre-existing AAP SSH-key ownership metadata"
        info "Creating an ephemeral SSH key for the Containerlab network node..."
        ssh-keygen -q -t ed25519 -N '' -C osac-5529-netnode -f "$key_file"
        patch_file="$TEMP_DIR/aap-networking-key-patch.json"
        python3 - "$key_file" "$AAP_SSH_KEY_SECRET_KEY" \
            "$AAP_SSH_KEY_SECRET_ANNOTATION" "$patch_file" <<'PY'
import base64
import json
import pathlib
import sys

key_path, data_key, annotation_key, patch_path = sys.argv[1:]
key = pathlib.Path(key_path).read_bytes()
payload = {
    "data": {data_key: base64.b64encode(key).decode("ascii")},
    "metadata": {"annotations": {annotation_key: "OSAC-5529"}},
}
pathlib.Path(patch_path).write_text(json.dumps(payload))
PY
        SSH_KEY_EXPECTED_BASE64="$(base64 -w0 "$key_file")"
        SSH_KEY_CREATED_BY_RUN=true
        oc patch secret "$AAP_NETWORKING_SECRET" -n "$OSAC_NAMESPACE" \
            --type=merge --patch-file="$patch_file" >/dev/null
    fi
    ssh-keygen -y -f "$key_file" >"$SSH_PUBLIC_KEY_FILE"
    chmod 0600 "$key_file" "$SSH_PUBLIC_KEY_FILE"
    SSH_PRIVATE_KEY_FILE="$key_file"
}

ensure_containerlab_net_node() {
    local node_state existing_names
    [[ -f "$CONTAINERLAB_TOPOLOGY" && -f "$CONTAINERLAB_INVENTORY" ]] \
        || die "The osac-workspace Containerlab topology or inventory is missing"
    resolve_mgmt_network
    if docker inspect "$CONTAINERLAB_NET_NODE" >/dev/null 2>&1; then
        node_state="$(docker inspect -f '{{.State.Running}}' "$CONTAINERLAB_NET_NODE")"
        [[ "$node_state" == true ]] \
            || die "The Containerlab network node exists but is stopped; refusing to modify a partial lab"
        info "Reusing the running Containerlab network node."
        return 0
    fi
    existing_names="$(docker ps -a --format '{{.Names}}' | awk -v prefix="$CONTAINERLAB_PREFIX-" 'index($0, prefix) == 1')"
    [[ -z "$existing_names" ]] \
        || die "A partial Containerlab topology exists without its network node; refusing to redeploy it"
    info "Deploying the osac-workspace Containerlab topology on the existing SNO management bridge..."
    sudo env \
        "MGMT_BRIDGE=$MGMT_BRIDGE" \
        "MGMT_CIDR=$MGMT_CIDR" \
        "MGMT_GW=$MGMT_GW" \
        "MGMT_PREFIX=$MGMT_PREFIX" \
        "$CONTAINERLAB" deploy -t "$CONTAINERLAB_TOPOLOGY"
    for ((attempt = 1; attempt <= 60; attempt++)); do
        if docker inspect "$CONTAINERLAB_NET_NODE" >/dev/null 2>&1; then
            node_state="$(docker inspect -f '{{.State.Running}}' "$CONTAINERLAB_NET_NODE")"
            [[ "$node_state" == true ]] && return 0
        fi
        sleep 2
    done
    die "Containerlab deployment did not start the network node"
}

prepare_containerlab_net_node() {
    local public_key authorized_exists
    ensure_aap_ssh_key
    info "Installing provider tools and key-only SSH access on the Containerlab network node..."
    if ! docker exec "$CONTAINERLAB_NET_NODE" apk add --no-cache \
        iptables iproute2 python3 openssh sudo conntrack-tools procps iputils >/dev/null; then
        die "Could not install the AgentlessNet provider prerequisites on the Containerlab network node"
    fi
    CONTAINERLAB_ACCESS_CONFIGURED=true
    if docker exec "$CONTAINERLAB_NET_NODE" test -f /etc/sudoers.d/osac-agentless-net; then
        if docker exec "$CONTAINERLAB_NET_NODE" grep -Fxq '# OSAC-5529 temporary provider access' /etc/sudoers.d/osac-agentless-net; then
            NETNODE_SUDOERS_CREATED_BY_RUN=true
        else
            die "The Containerlab network node already has an unrelated sudoers file at the task path"
        fi
    else
        NETNODE_SUDOERS_CREATED_BY_RUN=true
        docker exec -i "$CONTAINERLAB_NET_NODE" sh -s <<'SH'
set -eu
printf '%s\n' '# OSAC-5529 temporary provider access' 'root ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/osac-agentless-net
chmod 0440 /etc/sudoers.d/osac-agentless-net
visudo -cf /etc/sudoers.d/osac-agentless-net >/dev/null
SH
    fi
    NETNODE_SSHD_CREATED_BY_RUN=true
    docker exec -i "$CONTAINERLAB_NET_NODE" sh -s <<'SH'
set -eu
mkdir -p /root/.ssh
chmod 0700 /root/.ssh
ssh-keygen -A >/dev/null 2>&1
if [ -s /run/sshd-osac-5529.pid ]; then
    kill "$(cat /run/sshd-osac-5529.pid)" >/dev/null 2>&1 || true
    rm -f /run/sshd-osac-5529.pid
fi
/usr/sbin/sshd -t -p 2222 \
    -o PermitRootLogin=prohibit-password \
    -o PasswordAuthentication=no \
    -o PubkeyAuthentication=yes \
    -o AuthorizedKeysFile=/root/.ssh/authorized_keys \
    -o PidFile=/run/sshd-osac-5529.pid
/usr/sbin/sshd -p 2222 \
    -o PermitRootLogin=prohibit-password \
    -o PasswordAuthentication=no \
    -o PubkeyAuthentication=yes \
    -o AuthorizedKeysFile=/root/.ssh/authorized_keys \
    -o PidFile=/run/sshd-osac-5529.pid
SH
    public_key="$(<"$SSH_PUBLIC_KEY_FILE")"
    if docker exec "$CONTAINERLAB_NET_NODE" sh -c 'test -f /root/.ssh/authorized_keys'; then
        SSH_AUTHORIZED_KEYS_EXISTED=true
    fi
    authorized_exists=false
    if docker exec "$CONTAINERLAB_NET_NODE" sh -c \
        'test -f /root/.ssh/authorized_keys && grep -Fxq "$1" /root/.ssh/authorized_keys' \
        sh "$public_key"; then
        authorized_exists=true
    else
        SSH_PUBLIC_KEY_INSTALLED_BY_RUN=true
        docker exec -i "$CONTAINERLAB_NET_NODE" sh -c \
            'cat >>/root/.ssh/authorized_keys' <"$SSH_PUBLIC_KEY_FILE"
    fi
    docker exec "$CONTAINERLAB_NET_NODE" chmod 0600 /root/.ssh/authorized_keys
    if [[ "$SSH_KEY_CREATED_BY_RUN" == true && "$authorized_exists" == true ]]; then
        SSH_PUBLIC_KEY_INSTALLED_BY_RUN=true
    fi
    chmod 0600 "$SSH_PUBLIC_KEY_FILE"
    if ! ssh -i "$SSH_PRIVATE_KEY_FILE" \
        -o BatchMode=yes \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=accept-new \
        -o "UserKnownHostsFile=$TEMP_DIR/known_hosts" \
        -o ConnectTimeout=5 \
        -p 2222 \
        "$AGENTLESS_NET_USER@$AGENTLESS_NET_HOST" \
        'sudo -n true && python3 --version >/dev/null && ip -Version >/dev/null && iptables --version >/dev/null && conntrack --version >/dev/null 2>&1' \
        >/dev/null 2>&1; then
        die "Key-based SSH or required provider tools are unavailable on the Containerlab network node"
    fi
    info "Containerlab network node is reachable with the isolated provider SSH key."
}

write_provider_inventory() {
    local inventory_file="$TEMP_DIR/inventory.yml"
    local host_file="$TEMP_DIR/inventory-host"
    local user_file="$TEMP_DIR/inventory-user"
    local existing configmap_json expected_inventory
    MGMT_BRIDGE="$MGMT_BRIDGE" MGMT_GW="$MGMT_GW" \
        MGMT_PREFIX="$MGMT_PREFIX" MGMT_CIDR="$MGMT_CIDR" \
        MGMT_DHCP_RANGES="$MGMT_DHCP_RANGES" \
        "$AAP_DIR/.venv/bin/python" - "$CONTAINERLAB_INVENTORY" \
        "$CONTAINERLAB_TOPOLOGY" "$inventory_file" "$host_file" "$user_file" <<'PY'
import ipaddress
import os
import pathlib
import re
import sys
import yaml

source_path, topology_path, output_path, host_path, user_path = map(pathlib.Path, sys.argv[1:])
inventory = yaml.safe_load(source_path.read_text())
topology = yaml.safe_load(topology_path.read_text())
if not isinstance(inventory, dict):
    raise SystemExit("workspace inventory must be a mapping")
mgmt = topology.get("mgmt", {}) if isinstance(topology, dict) else {}
if not isinstance(mgmt, dict):
    raise SystemExit("Containerlab topology management network must be a mapping")
for key, env_name in (("bridge", "MGMT_BRIDGE"), ("ipv4-subnet", "MGMT_CIDR"), ("ipv4-gw", "MGMT_GW")):
    value = str(mgmt.get(key, ""))
    expected = os.environ[env_name]
    if env_name not in value and value != expected:
        raise SystemExit("Containerlab management network does not use the existing SNO libvirt network")
all_group = inventory.get("all", {})
children = all_group.get("children", {}) if isinstance(all_group, dict) else {}
net_nodes = children.get("net_nodes", {}) if isinstance(children, dict) else {}
hosts = net_nodes.get("hosts", {}) if isinstance(net_nodes, dict) else {}
if not isinstance(hosts, dict) or len(hosts) != 1:
    raise SystemExit("workspace inventory must define exactly one authoritative net node")
name, vars = next(iter(hosts.items()))
if not isinstance(vars, dict):
    raise SystemExit("workspace net-node inventory variables must be a mapping")
host = vars.get("ansible_host")
user = vars.get("ansible_user")
prefix = os.environ["MGMT_PREFIX"]
cidr = ipaddress.IPv4Network(os.environ["MGMT_CIDR"], strict=False)
if not isinstance(host, str) or not isinstance(user, str):
    raise SystemExit("workspace net-node inventory requires ansible_host and ansible_user")
host = host.replace("$" + "{MGMT_PREFIX}", prefix).replace("$MGMT_PREFIX", prefix)
if "$" in host or "{{" in host or "}}" in host:
    raise SystemExit("workspace net-node address contains an unresolved variable")
try:
    address = ipaddress.IPv4Address(host)
except ipaddress.AddressValueError as error:
    raise SystemExit("workspace net-node address is not an IPv4 address") from error
if address not in cidr:
    raise SystemExit("workspace net-node address is outside the SNO management network")
for item in filter(None, os.environ.get("MGMT_DHCP_RANGES", "").split(",")):
    start, end = (ipaddress.IPv4Address(part) for part in item.split("-", 1))
    if start <= address <= end:
        raise SystemExit("workspace net-node address conflicts with the SNO DHCP pool")
if user != "root":
    raise SystemExit("the Containerlab net-node must use its root SSH account")
if not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
    raise SystemExit("workspace net-node inventory name contains unsupported characters")
output = {
    "all": {
        "vars": {
            "ansible_ssh_common_args": "-o StrictHostKeyChecking=accept-new",
        },
        "children": {
            "net_nodes": {
                "hosts": {
                    name: {
                        "ansible_host": str(address),
                        "ansible_user": user,
                        "ansible_port": 2222,
                    }
                }
            }
        },
    }
}
output_path.write_text(yaml.safe_dump(output, sort_keys=False))
output_path.chmod(0o600)
host_path.write_text(str(address) + "\n")
host_path.chmod(0o600)
user_path.write_text(user + "\n")
user_path.chmod(0o600)
PY
    AGENTLESS_NET_HOST="$(<"$host_file")"
    AGENTLESS_NET_USER="$(<"$user_file")"
    expected_inventory="$(<"$inventory_file")"
    if configmap_json="$(oc get configmap agentless-net-inventory -n "$OSAC_NAMESPACE" -o json 2>/dev/null)"; then
        jq -e --arg expected "$expected_inventory" \
            '(.data | keys == ["inventory.yml"]) and .data["inventory.yml"] == $expected' \
            <<<"$configmap_json" >/dev/null \
            || die "Existing agentless-net-inventory is not the expected sanitized workspace inventory; refusing to overwrite it"
        info "Verified the existing password-free AgentlessNet inventory ConfigMap."
    else
        oc create configmap agentless-net-inventory -n "$OSAC_NAMESPACE" \
            --from-file=inventory.yml="$inventory_file" >/dev/null
        info "Created the password-free AgentlessNet inventory ConfigMap from osac-workspace."
    fi
}

sync_aap_project_revision() {
    local token route
    route="$(oc get route osac-aap -n "$OSAC_NAMESPACE" -o jsonpath='{.spec.host}')" \
        || die "Could not read the AAP Controller route"
    token="$(oc exec deployment/osac-operator -n "$OSAC_NAMESPACE" -- \
        sh -c 'printf %s "$OSAC_AAP_TOKEN"' 2>/dev/null)" \
        || die "Could not obtain the existing AAP API token from the operator environment"
    [[ -n "$route" && -n "$token" ]] || die "AAP Controller API route or token is unavailable"
    AAP_API_ROUTE="https://$route"
    AAP_API_TOKEN="$token" AAP_API_ROUTE="$AAP_API_ROUTE" \
        python3 - "$AAP_PROJECT_GIT_URI" "$AAP_PROJECT_GIT_BRANCH" \
        "$(git -C "$REPO_ROOT" rev-parse HEAD)" <<'PY'
import json
import os
import ssl
import sys
import time
import urllib.parse
import urllib.request

base = os.environ["AAP_API_ROUTE"].rstrip("/") + "/api/controller/v2"
token = os.environ["AAP_API_TOKEN"]
expected_url, expected_branch, expected_revision = sys.argv[1:]
context = ssl._create_unverified_context()

def request(url, data=None, method=None):
    headers = {"Authorization": f"Bearer {token}"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, context=context, timeout=20) as response:
        payload = response.read()
        return json.loads(payload) if payload else {}

def normalize(url):
    return (url or "").removesuffix(".git").rstrip("/").lower()

url = base + "/projects/?page_size=200"
projects = []
while url:
    payload = request(url)
    projects.extend(payload.get("results", []))
    url = urllib.parse.urljoin(base + "/", payload["next"]) if payload.get("next") else ""
matches = [
    item for item in projects
    if normalize(item.get("scm_url")) == normalize(expected_url)
    and item.get("scm_branch") == expected_branch
]
if len(matches) != 1:
    raise SystemExit("AAP project lookup did not find exactly one project for the configured source and branch")
project = request(base + f"/projects/{matches[0]['id']}/")
if project.get("scm_revision") != expected_revision:
    update = request(
        base + f"/projects/{project['id']}/update/",
        data=b"{}",
        method="POST",
    )
    update_id = update.get("id")
    for _ in range(120):
        time.sleep(5)
        if update_id is not None:
            update_state = request(base + f"/project_updates/{update_id}/").get("status")
            if update_state in ("failed", "error", "canceled"):
                raise SystemExit(f"AAP project synchronization ended in {update_state}")
        project = request(base + f"/projects/{project['id']}/")
        if project.get("scm_revision") == expected_revision:
            break
        if project.get("status") in ("failed", "error"):
            raise SystemExit(f"AAP project synchronization ended in {project['status']}")
    else:
        raise SystemExit("AAP project did not synchronize to the current OSAC-5529 commit")
if project.get("scm_revision") != expected_revision:
    raise SystemExit("AAP project SCM revision does not match the current OSAC-5529 commit")
print(f"AAP project SCM revision verified: {expected_revision}")
PY
    unset token
}

configure_aap_execution_environment() {
    local token route
    route="$(oc get route osac-aap -n "$OSAC_NAMESPACE" -o jsonpath='{.spec.host}')" \
        || die "Could not read the AAP Controller route"
    token="$(oc exec deployment/osac-operator -n "$OSAC_NAMESPACE" -- \
        sh -c 'printf %s "$OSAC_AAP_TOKEN"' 2>/dev/null)" \
        || die "Could not obtain the existing AAP API token from the operator environment"
    [[ -n "$route" && -n "$token" ]] || die "AAP Controller API route or token is unavailable"
    AAP_API_ROUTE="https://$route"
    AAP_API_TOKEN="$token" AAP_API_ROUTE="$AAP_API_ROUTE" \
        AAP_EXECUTION_ENVIRONMENT_NAME="$AAP_EXECUTION_ENVIRONMENT_NAME" \
        AAP_IMAGE="$AAP_IMAGE" python3 - <<'PY'
import json
import os
import ssl
import urllib.parse
import urllib.request

base = os.environ["AAP_API_ROUTE"].rstrip("/") + "/api/controller/v2"
token = os.environ["AAP_API_TOKEN"]
expected_name = os.environ["AAP_EXECUTION_ENVIRONMENT_NAME"]
expected_image = os.environ["AAP_IMAGE"]
expected_pull = "always"
context = ssl._create_unverified_context()

def request(url, data=None, method=None):
    headers = {"Authorization": f"Bearer {token}"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, context=context, timeout=20) as response:
        payload = response.read()
        return json.loads(payload) if payload else {}

url = base + "/execution_environments/?page_size=200"
items = []
while url:
    payload = request(url)
    items.extend(payload.get("results", []))
    url = urllib.parse.urljoin(base + "/", payload["next"]) if payload.get("next") else ""
matches = [item for item in items if item.get("name") == expected_name]
if len(matches) != 1:
    raise SystemExit(f"AAP did not return exactly one execution environment named {expected_name}")

endpoint = base + f"/execution_environments/{matches[0]['id']}/"
environment = request(endpoint)
if environment.get("image") == expected_image and environment.get("pull") == expected_pull:
    print(f"AAP execution environment {expected_name} already uses the requested image.")
else:
    request(
        endpoint,
        data=json.dumps({"image": expected_image, "pull": expected_pull}).encode(),
        method="PATCH",
    )
    environment = request(endpoint)
    if environment.get("image") != expected_image or environment.get("pull") != expected_pull:
        raise SystemExit(f"AAP did not retain the requested image for {expected_name}")
    print(f"Updated AAP execution environment {expected_name} to the requested image.")
PY
    unset token
}

prepare_aap_networking_instance_group() {
    local token route
    AAP_NETWORK_IG_BACKUP="$TEMP_DIR/aap-networking-ig-backup.json"
    route="$(oc get route osac-aap -n "$OSAC_NAMESPACE" -o jsonpath='{.spec.host}')" \
        || die "Could not read the AAP Controller route"
    token="$(oc exec deployment/osac-operator -n "$OSAC_NAMESPACE" -- \
        sh -c 'printf %s "$OSAC_AAP_TOKEN"' 2>/dev/null)" \
        || die "Could not obtain the existing AAP API token from the operator environment"
    [[ -n "$route" && -n "$token" ]] || die "AAP Controller API route or token is unavailable"
    AAP_API_ROUTE="https://$route"
    AAP_API_TOKEN="$token" AAP_API_ROUTE="$AAP_API_ROUTE" \
        AAP_NETWORK_IG_BACKUP="$AAP_NETWORK_IG_BACKUP" \
        AAP_NETWORKING_SECRET="$AAP_NETWORKING_SECRET" \
        python3 - <<'PY'
import json
import os
import ssl
import urllib.parse
import urllib.request
import yaml

base = os.environ["AAP_API_ROUTE"].rstrip("/") + "/api/controller/v2"
token = os.environ["AAP_API_TOKEN"]
backup_path = os.environ["AAP_NETWORK_IG_BACKUP"]
secret_name = os.environ["AAP_NETWORKING_SECRET"]
context = ssl._create_unverified_context()

def request(url, data=None, method=None):
    headers = {"Authorization": f"Bearer {token}"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, context=context, timeout=20) as response:
        payload = response.read()
        return json.loads(payload) if payload else {}

url = base + "/instance_groups/?page_size=200"
groups = []
while url:
    payload = request(url)
    groups.extend(payload.get("results", []))
    url = urllib.parse.urljoin(base + "/", payload["next"]) if payload.get("next") else ""
matches = [item for item in groups if item.get("name", "").endswith("networking-operations-ig")]
if len(matches) != 1:
    raise SystemExit("AAP did not return exactly one networking-operations instance group")
instance_group = request(base + f"/instance_groups/{matches[0]['id']}/")
original = instance_group.get("pod_spec_override", "")
spec = yaml.safe_load(original) if original else None
if not isinstance(spec, dict) or not isinstance(spec.get("spec"), dict):
    raise SystemExit("AAP networking-operations instance group has no valid worker Pod specification")
original_spec = yaml.safe_load(original)
pod_spec = spec["spec"]
containers = pod_spec.get("containers", [])
workers = [container for container in containers if container.get("name") == "worker"]
if len(workers) != 1:
    raise SystemExit("AAP networking-operations instance group must contain exactly one worker container")
worker = workers[0]
mounts = worker.setdefault("volumeMounts", [])
if not any(mount.get("name") == "agentless-net-inventory" for mount in mounts):
    mounts.append({
        "name": "agentless-net-inventory",
        "mountPath": "/var/config/agentless-net",
        "readOnly": True,
    })
volumes = pod_spec.setdefault("volumes", [])
if not any(volume.get("name") == "agentless-net-inventory" for volume in volumes):
    volumes.append({
        "name": "agentless-net-inventory",
        "configMap": {"name": "agentless-net-inventory", "optional": True},
    })
env_from = worker.setdefault("envFrom", [])
if not any(item.get("secretRef", {}).get("name") == secret_name for item in env_from):
    env_from.append({"secretRef": {"name": secret_name}})
pod_spec["hostNetwork"] = True
pod_spec["dnsPolicy"] = "ClusterFirstWithHostNet"
updated = yaml.safe_dump(spec, sort_keys=False)
changed = spec != original_spec
backup = {
    "id": instance_group["id"],
    "changed": changed,
    "original": original,
    "expected": updated if changed else original,
}
with open(backup_path, "w", encoding="utf-8") as stream:
    json.dump(backup, stream)
os.chmod(backup_path, 0o600)
if changed:
    body = json.dumps({"pod_spec_override": updated}).encode()
    request(
        base + f"/instance_groups/{instance_group['id']}/",
        data=body,
        method="PATCH",
    )
    current = request(base + f"/instance_groups/{instance_group['id']}/")
    if yaml.safe_load(current.get("pod_spec_override", "")) != spec:
        raise SystemExit("AAP did not retain the requested networking worker Pod configuration")
print("changed" if changed else "unchanged")
PY
    unset token
    AAP_NETWORK_IG_ID="$(jq -r '.id' "$AAP_NETWORK_IG_BACKUP")"
    AAP_NETWORK_IG_CHANGED="$(jq -r '.changed' "$AAP_NETWORK_IG_BACKUP")"
    info "AAP networking-operations instance group is prepared for the Containerlab node (temporary host-network access: $AAP_NETWORK_IG_CHANGED)."
}

restore_aap_networking_instance_group() {
    local token route changed
    [[ -f "$AAP_NETWORK_IG_BACKUP" ]] || return 0
    changed="$(jq -r '.changed' "$AAP_NETWORK_IG_BACKUP")"
    [[ "$changed" == true ]] || return 0
    route="$(oc get route osac-aap -n "$OSAC_NAMESPACE" -o jsonpath='{.spec.host}')" \
        || { printf 'ERROR: cannot read the AAP route while restoring its networking instance group\n' >&2; return 1; }
    token="$(oc exec deployment/osac-operator -n "$OSAC_NAMESPACE" -- \
        sh -c 'printf %s "$OSAC_AAP_TOKEN"' 2>/dev/null)" \
        || { printf 'ERROR: cannot obtain the AAP token while restoring its networking instance group\n' >&2; return 1; }
    [[ -n "$route" && -n "$token" ]] || { printf 'ERROR: AAP API access is unavailable during instance-group cleanup\n' >&2; return 1; }
    AAP_API_ROUTE="https://$route"
    AAP_API_TOKEN="$token" AAP_API_ROUTE="$AAP_API_ROUTE" \
        AAP_NETWORK_IG_BACKUP="$AAP_NETWORK_IG_BACKUP" \
        python3 - <<'PY'
import json
import os
import ssl
import urllib.request
import yaml

base = os.environ["AAP_API_ROUTE"].rstrip("/") + "/api/controller/v2"
token = os.environ["AAP_API_TOKEN"]
with open(os.environ["AAP_NETWORK_IG_BACKUP"], encoding="utf-8") as stream:
    backup = json.load(stream)
context = ssl._create_unverified_context()

def request(url, data=None, method=None):
    headers = {"Authorization": f"Bearer {token}"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, context=context, timeout=20) as response:
        payload = response.read()
        return json.loads(payload) if payload else {}

url = base + f"/instance_groups/{backup['id']}/"
current = request(url)
current_override = current.get("pod_spec_override", "")
if current_override == backup["original"]:
    print("AAP networking instance group was already restored.")
    raise SystemExit(0)
if yaml.safe_load(current_override) != yaml.safe_load(backup["expected"]):
    raise SystemExit("AAP networking instance group changed during the E2E; preserving the current Pod configuration")
request(url, data=json.dumps({"pod_spec_override": backup["original"]}).encode(), method="PATCH")
restored = request(url)
if restored.get("pod_spec_override") != backup["original"]:
    raise SystemExit("AAP networking instance group did not return to its original Pod configuration")
print("Restored the original AAP networking-operations Pod configuration.")
PY
    unset token
    AAP_NETWORK_IG_CHANGED=false
}

remove_netnode_public_key() {
    local public_key
    [[ "$SSH_PUBLIC_KEY_INSTALLED_BY_RUN" == true && -f "$SSH_PUBLIC_KEY_FILE" ]] || return 0
    public_key="$(<"$SSH_PUBLIC_KEY_FILE")"
    docker exec "$CONTAINERLAB_NET_NODE" sh -c '
        set -eu
        public_key=$1
        keep_empty=$2
        authorized=/root/.ssh/authorized_keys
        [ -f "$authorized" ] || exit 0
        temporary=/root/.ssh/authorized_keys.osac-5529
        awk -v key="$public_key" "$0 != key" "$authorized" >"$temporary"
        if [ -s "$temporary" ] || [ "$keep_empty" = true ]; then
            chmod 0600 "$temporary"
            mv "$temporary" "$authorized"
        else
            rm -f "$temporary" "$authorized"
        fi
    ' sh "$public_key" "$SSH_AUTHORIZED_KEYS_EXISTED"
    SSH_PUBLIC_KEY_INSTALLED_BY_RUN=false
}

restore_containerlab_netnode_access() {
    [[ "$CONTAINERLAB_ACCESS_CONFIGURED" == true ]] || return 0
    if [[ "$NETNODE_SSHD_CREATED_BY_RUN" == true || "$NETNODE_SUDOERS_CREATED_BY_RUN" == true ]]; then
        docker exec "$CONTAINERLAB_NET_NODE" sh -c '
            set -eu
            if [ "$1" = true ] && [ -s /run/sshd-osac-5529.pid ]; then
                kill "$(cat /run/sshd-osac-5529.pid)" >/dev/null 2>&1 || true
                rm -f /run/sshd-osac-5529.pid
            fi
            if [ "$2" = true ] && grep -Fxq "# OSAC-5529 temporary provider access" /etc/sudoers.d/osac-agentless-net; then
                rm -f /etc/sudoers.d/osac-agentless-net
            fi
        ' sh "$NETNODE_SSHD_CREATED_BY_RUN" "$NETNODE_SUDOERS_CREATED_BY_RUN"
    fi
    NETNODE_SSHD_CREATED_BY_RUN=false
    NETNODE_SUDOERS_CREATED_BY_RUN=false
    CONTAINERLAB_ACCESS_CONFIGURED=false
}

restore_aap_ssh_key() {
    local patch_file="$TEMP_DIR/aap-networking-key-remove.json" current
    [[ "$SSH_KEY_CREATED_BY_RUN" == true ]] || return 0
    current="$(oc get secret "$AAP_NETWORKING_SECRET" -n "$OSAC_NAMESPACE" -o json)" \
        || { printf 'ERROR: cannot verify the temporary AAP SSH key before cleanup\n' >&2; return 1; }
    if [[ "$(jq -r --arg key "$AAP_SSH_KEY_SECRET_KEY" '.data[$key] // ""' <<<"$current")" == "" ]] \
        && [[ "$(jq -r --arg key "$AAP_SSH_KEY_SECRET_ANNOTATION" \
          '.metadata.annotations[$key] // ""' <<<"$current")" == "" ]]; then
        SSH_KEY_CREATED_BY_RUN=false
        SSH_KEY_EXPECTED_BASE64=""
        return 0
    fi
    if [[ "$(jq -r --arg key "$AAP_SSH_KEY_SECRET_KEY" '.data[$key] // ""' <<<"$current")" \
        != "$SSH_KEY_EXPECTED_BASE64" ]] \
        || [[ "$(jq -r --arg key "$AAP_SSH_KEY_SECRET_ANNOTATION" \
          '.metadata.annotations[$key] // ""' <<<"$current")" != OSAC-5529 ]]; then
        printf 'ERROR: the temporary AAP SSH key changed during the run; preserving the current Secret value\n' >&2
        return 1
    fi
    python3 - "$AAP_SSH_KEY_SECRET_KEY" "$AAP_SSH_KEY_SECRET_ANNOTATION" "$patch_file" <<'PY'
import json
import pathlib
import sys

data_key, annotation_key, patch_path = sys.argv[1:]
payload = {
    "data": {data_key: None},
    "metadata": {"annotations": {annotation_key: None}},
}
pathlib.Path(patch_path).write_text(json.dumps(payload))
PY
    oc patch secret "$AAP_NETWORKING_SECRET" -n "$OSAC_NAMESPACE" \
        --type=merge --patch-file="$patch_file" >/dev/null
    current="$(oc get secret "$AAP_NETWORKING_SECRET" -n "$OSAC_NAMESPACE" -o json)" \
        || { printf 'ERROR: cannot verify AAP SSH-key cleanup\n' >&2; return 1; }
    jq -e --arg data_key "$AAP_SSH_KEY_SECRET_KEY" \
        --arg annotation_key "$AAP_SSH_KEY_SECRET_ANNOTATION" \
        '(.data | has($data_key) | not) and ((.metadata.annotations[$annotation_key] // "") == "")' \
        <<<"$current" >/dev/null || { printf 'ERROR: AAP networking Secret did not return to its original SSH-key state\n' >&2; return 1; }
    SSH_KEY_CREATED_BY_RUN=false
    SSH_KEY_EXPECTED_BASE64=""
}

deployment_settings() {
    helm get values osac -n "$OSAC_NAMESPACE" --all -o json | jq -ce '{
      aap: {
        eeImage: .aap.configAsCode.eeImage,
        projectGitUri: .aap.configAsCode.projectGitUri,
        projectGitBranch: .aap.configAsCode.projectGitBranch
      },
      networking: {
        fabricManager: .global.networking.fabricManager,
        k8sManager: .global.networking.k8sManager,
        networkClassTitle: .global.networking.networkClass.title
      }
    }'
}

prepare_upgrade_values() {
    local previous_json="$TEMP_DIR/previous-helm-values.json"
    local previous_yaml="$TEMP_DIR/previous-helm-values.yaml"
    helm get values osac -n "$OSAC_NAMESPACE" --all -o json >"$previous_json" \
        || die "Could not capture the existing Helm values for a schema-compatible upgrade"
    python3 - "$previous_json" "$previous_yaml" <<'PY'
import json
import os
import pathlib
import sys
import yaml

source_path, output_path = sys.argv[1:]
with open(source_path, encoding="utf-8") as stream:
    values = json.load(stream)
if not isinstance(values, dict):
    raise SystemExit("Existing Helm values must be a mapping")

service = values.get("service")
if service is not None and not isinstance(service, dict):
    raise SystemExit("Existing service Helm values must be a mapping")
images = service.get("images") if service else None
if images is not None and not isinstance(images, dict):
    raise SystemExit("Existing service image values must be a mapping")
if isinstance(images, dict):
    legacy_pull_policy = images.pop("pullPolicy", None)
    if legacy_pull_policy is not None and legacy_pull_policy not in ("Always", "IfNotPresent", "Never"):
        raise SystemExit("Existing service image pull policy is not supported by the current chart")
    for name in ("service", "envoy"):
        image = images.get(name)
        if isinstance(image, str):
            if "@" in image:
                raise SystemExit(f"Cannot migrate digest-pinned service image {name} automatically")
            colon = image.rfind(":")
            slash = image.rfind("/")
            if colon <= slash or colon == len(image) - 1:
                raise SystemExit(f"Existing service image {name} must include a tag")
            image = {"repository": image[:colon], "tag": image[colon + 1:]}
            images[name] = image
        elif image is not None and not isinstance(image, dict):
            raise SystemExit(f"Existing service image {name} must be a string or mapping")
        if legacy_pull_policy is not None and isinstance(images.get(name), dict):
            images[name].setdefault("pullPolicy", legacy_pull_policy)

path = pathlib.Path(output_path)
path.write_text(yaml.safe_dump(values, sort_keys=False), encoding="utf-8")
os.chmod(path, 0o600)
PY
    UPGRADE_VALUES_FILE="$previous_yaml"
}

tenant_exists() {
    local tenant_list
    tenant_list="$("$CLI_BIN" --config "$CLI_CONFIG_DIR" get tenants)" || return 1
    awk -v tenant="$OSAC_TENANT" 'NR > 1 && $NF == tenant { found=1 } END { exit !found }' \
        <<<"$tenant_list"
}

ensure_osac_tenant() (
    local local_port port_forward_log admin_token tenant_payload create_succeeded=false
    local port_forward_pid=""
    if tenant_exists; then
        info "Tenant ${OSAC_TENANT} already exists."
        return 0
    fi

    info "Creating the dedicated E2E tenant ${OSAC_TENANT} through the private Tenants API..."
    local_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
    port_forward_log="${TEMP_DIR}/tenant-port-forward.log"
    trap 'if [[ -n "${port_forward_pid:-}" ]]; then kill "$port_forward_pid" >/dev/null 2>&1 || true; wait "$port_forward_pid" 2>/dev/null || true; fi' EXIT

    oc port-forward --address 127.0.0.1 service/fulfillment-internal-api \
        "${local_port}:8001" -n "$OSAC_NAMESPACE" >"$port_forward_log" 2>&1 &
    port_forward_pid=$!
    for ((attempt = 1; attempt <= 30; attempt++)); do
        grep -Fq "Forwarding from 127.0.0.1:${local_port}" "$port_forward_log" && break
        if ! kill -0 "$port_forward_pid" 2>/dev/null; then
            die "Could not forward the internal Fulfillment API for tenant creation"
        fi
        sleep 1
    done
    grep -Fq "Forwarding from 127.0.0.1:${local_port}" "$port_forward_log" \
        || die "Timed out forwarding the internal Fulfillment API for tenant creation"

    admin_token="$(oc create token admin -n "$OSAC_NAMESPACE" --duration=10m)"
    tenant_payload="$(python3 -c 'import json,sys; print(json.dumps({"object":{"metadata":{"name":sys.argv[1]}}}))' "$OSAC_TENANT")"
    if grpcurl -insecure -H "authorization: Bearer ${admin_token}" -d "$tenant_payload" \
        "127.0.0.1:${local_port}" osac.private.v1.Tenants/Create >/dev/null 2>&1; then
        create_succeeded=true
    fi
    unset admin_token
    kill "$port_forward_pid" >/dev/null 2>&1 || true
    wait "$port_forward_pid" 2>/dev/null || true
    port_forward_pid=""
    tenant_exists || die "Tenant API did not create ${OSAC_TENANT}; inspect Fulfillment service logs"
    if [[ "$create_succeeded" == true ]]; then
        info "Tenant ${OSAC_TENANT} is available."
    else
        info "Tenant ${OSAC_TENANT} was committed; continuing after the API reported an onboarding error."
    fi
)

virtual_network_cr_json() {
    local id="$1"
    local selector json
    selector="$(label_selector "$id")"
    json="$(oc get virtualnetworks -n "$NETWORKING_NAMESPACE" -l "$selector" -o json)" \
        || die "Kubernetes API failed while looking up VirtualNetwork UUID ${id}"
    jq -ce --arg id "$id" --arg tenant "$OSAC_TENANT" --arg namespace "$NETWORKING_NAMESPACE" '
      if (.items | length) != 1 then
        error("expected one VirtualNetwork CR for Fulfillment UUID " + $id)
      else
        .items[0] as $v
        | if $v.metadata.labels["osac.openshift.io/virtualnetwork-uuid"] != $id then
            error("VirtualNetwork UUID label does not match the requested resource")
          elif $v.metadata.annotations["osac.openshift.io/tenant"] != $tenant then
            error("VirtualNetwork tenant annotation does not match the requested tenant")
          elif $v.metadata.namespace != $namespace then
            error("VirtualNetwork CR is outside the configured networking namespace")
          else $v end
      end' <<<"$json"
}

wait_for_virtual_network_ready() {
    local id="$1"
    local last_state=""
    local description state
    info "Waiting for Fulfillment VirtualNetwork ${id} to become READY..."
    for ((attempt = 1; attempt <= 120; attempt++)); do
        if ! description="$("$CLI_BIN" --config "$CLI_CONFIG_DIR" --tenant "$OSAC_TENANT" \
            describe virtualnetwork "$id")"; then
            die "Fulfillment API failed while describing VirtualNetwork ${id}"
        fi
        state="$(awk -F': *' '$1 == "State" {print $2}' <<<"$description")"
        if [[ "$state" != "$last_state" ]]; then
            info "VirtualNetwork ${id} state: ${state:-unknown}"
            last_state="$state"
        fi
        if [[ "$state" == FAILED ]]; then
            printf '%s\n' "$description" >&2
            die "VirtualNetwork ${id} failed provisioning"
        fi
        if [[ "$state" == READY ]]; then
            printf '%s\n' "$description"
            return 0
        fi
        sleep 5
    done
    printf '%s\n' "$description" >&2
    die "Timed out waiting for VirtualNetwork ${id} to become READY"
}

wait_for_virtual_network_deleted() {
    local id="$1"
    local selector json count
    selector="$(label_selector "$id")"
    for ((attempt = 1; attempt <= 120; attempt++)); do
        json="$(oc get virtualnetworks -n "$NETWORKING_NAMESPACE" -l "$selector" -o json)" \
            || die "Kubernetes API failed while checking deletion of VirtualNetwork UUID ${id}"
        count="$(jq -r '.items | length' <<<"$json")"
        [[ "$count" == 0 ]] && return 0
        sleep 5
    done
    die "Timed out waiting for VirtualNetwork UUID ${id} deletion"
}

wait_for_aap_provision_success() {
    local fulfillment_id="$1" job_id="$2" cr_json job_state
    for ((attempt = 1; attempt <= 120; attempt++)); do
        cr_json="$(virtual_network_cr_json "$fulfillment_id")"
        job_state="$(jq -r --arg id "$job_id" \
            '[.status.provisioningJobs[]? | select(.jobID == $id) | .state] | last // ""' \
            <<<"$cr_json")"
        case "$job_state" in
            Succeeded) return 0 ;;
            Failed|Canceled)
                die "AAP provision job ${job_id} ended in ${job_state} for test resource ${fulfillment_id}"
                ;;
        esac
        sleep 2
    done
    die "Timed out waiting for AAP provision job ${job_id} to succeed"
}

cleanup_created_virtual_networks() {
    local original_status="$1"
    local test_vns_clean=true id selector current
    if [[ -n "$CLI_BIN" && -x "$CLI_BIN" && -n "$CLI_CONFIG_DIR" && -d "$CLI_CONFIG_DIR" ]]; then
        for id in "${CREATED_IDS[@]}"; do
            local selector current
            selector="$(label_selector "$id")"
            if current="$(oc get virtualnetworks -n "$NETWORKING_NAMESPACE" -l "$selector" -o json 2>/dev/null)" \
                && [[ "$(jq -r '.items | length' <<<"$current")" != 0 ]]; then
                info "Cleaning up test-owned VirtualNetwork UUID ${id}..."
                if "$CLI_BIN" --config "$CLI_CONFIG_DIR" --tenant "$OSAC_TENANT" \
                    delete virtualnetwork "$id" >/dev/null 2>&1; then
                    for ((attempt = 1; attempt <= 120; attempt++)); do
                        current="$(oc get virtualnetworks -n "$NETWORKING_NAMESPACE" -l "$selector" -o json 2>/dev/null || true)"
                        if [[ -n "$current" ]] && [[ "$(jq -r '.items | length' <<<"$current")" == 0 ]]; then
                            break
                        fi
                        sleep 5
                    done
                else
                    printf 'WARNING: CLI cleanup failed for test-owned UUID %s\n' "$id" >&2
                fi
            fi
        done
    fi
    for id in "${CREATED_IDS[@]}"; do
        selector="$(label_selector "$id")"
        if ! current="$(oc get virtualnetworks -n "$NETWORKING_NAMESPACE" -l "$selector" -o json 2>/dev/null)" \
            || [[ "$(jq -r '.items | length' <<<"$current")" != 0 ]]; then
            test_vns_clean=false
        fi
    done
    if ! remove_netnode_public_key; then
        printf 'ERROR: could not remove the temporary public key from the Containerlab net-node\n' >&2
        original_status=1
    fi
    if ! restore_containerlab_netnode_access; then
        printf 'ERROR: could not stop the temporary Containerlab SSH daemon or restore sudoers\n' >&2
        original_status=1
    fi
    if ! restore_aap_ssh_key; then
        printf 'ERROR: failed to restore the original AAP networking Secret data\n' >&2
        original_status=1
    fi
    if ! restore_aap_networking_instance_group; then
        printf 'ERROR: could not restore the original AAP networking-operations instance-group settings\n' >&2
        original_status=1
    fi
    if [[ "$test_vns_clean" != true ]]; then
        printf 'ERROR: test-owned VirtualNetwork cleanup is incomplete; the Containerlab fabric is retained for recovery\n' >&2
        original_status=1
    fi
    if [[ "$GENERATED_CLI_CONFIG" == true && -n "$CLI_CONFIG_DIR" ]]; then
        rm -rf -- "$CLI_CONFIG_DIR"
    fi
    if [[ "$GENERATED_CLI_BIN" == true && -n "$CLI_BIN" ]]; then
        rm -f -- "$CLI_BIN"
    fi
    if [[ -n "$CLI_CA_FILE" ]]; then
        rm -f -- "$CLI_CA_FILE"
    fi
    if [[ -n "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
    return "$original_status"
}

on_exit() {
    local status=$?
    local cleanup_status=0
    trap - EXIT
    set +e
    cleanup_created_virtual_networks "$status"
    cleanup_status=$?
    if [[ "$status" == 0 && "$cleanup_status" != 0 ]]; then
        status=1
    fi
    if [[ "$GENERATED_CLI_CONFIG" == true && -n "$CLI_CONFIG_DIR" ]]; then
        rm -rf -- "$CLI_CONFIG_DIR"
    fi
    if [[ "$GENERATED_CLI_BIN" == true && -n "$CLI_BIN" ]]; then
        rm -f -- "$CLI_BIN"
    fi
    [[ -z "$CLI_CA_FILE" ]] || rm -f -- "$CLI_CA_FILE"
    [[ -z "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
    set -e
    exit "$status"
}
trap on_exit EXIT

for tool in cluster-tool virsh oc helm go jq python3 awk sed grep sleep make ssh-keygen base64 grpcurl docker sudo ssh; do
    require_cmd "$tool"
done
require_cmd "$CONTAINER_TOOL"
require_cmd "$CONTAINERLAB"
[[ -n "$CURRENT_BRANCH" ]] || die "Could not determine the current Git branch"
[[ "$OSAC_INSTALL_MODE" == auto || "$OSAC_INSTALL_MODE" == install || "$OSAC_INSTALL_MODE" == upgrade ]] \
    || die "OSAC_INSTALL_MODE must be auto, install, or upgrade"
[[ "$AAP_IMAGE" =~ ^quay\.io/[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+$ ]] \
    || die "AAP_IMAGE must be a quay.io image reference with a tag"
[[ "$AAP_PROJECT_GIT_URI" =~ ^https://[A-Za-z0-9._/-]+$ ]] \
    || die "AAP_PROJECT_GIT_URI must be an HTTPS Git URL"
[[ "$AAP_PROJECT_GIT_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] \
    || die "AAP_PROJECT_GIT_BRANCH contains unsupported characters"
[[ "$AGENTLESS_NET_STATE_FILE" =~ ^/[A-Za-z0-9_./-]+$ ]] \
    || die "AGENTLESS_NET_STATE_FILE must be an absolute path with safe path characters"
[[ "$VIRTUAL_NETWORK_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || die "VIRTUAL_NETWORK_NAME must be a DNS label"
[[ "$PEER_VIRTUAL_NETWORK_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || die "PEER_VIRTUAL_NETWORK_NAME must be a DNS label"
[[ "$OSAC_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || die "OSAC_NAMESPACE must be a DNS label"
[[ "$OSAC_TENANT" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || die "OSAC_TENANT must be a DNS label"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/osac-5529-vn-e2e.XXXXXX")"
BASELINE_STATE_FILE="${TEMP_DIR}/baseline-state.json"
CURRENT_STATE_FILE="${TEMP_DIR}/current-state.json"
if [[ -z "$CLI_BIN" ]]; then
    CLI_BIN="$(mktemp "${TMPDIR:-/tmp}/osac-5529-cli.XXXXXX")"
    GENERATED_CLI_BIN=true
fi
if [[ -z "$CLI_CONFIG_DIR" ]]; then
    CLI_CONFIG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/osac-5529-cli-config.XXXXXX")"
    GENERATED_CLI_CONFIG=true
fi

# Phase 1: boot or reuse the SNO through cluster-tool.
if ! cluster-tool servers 2>/dev/null | awk 'NR > 2 && $1 == "local" { found = 1 } END { exit !found }'; then
    die "cluster-tool is not configured for the local development host"
fi

if VM_STATE="$(virsh domstate "$MGMT_VM_NAME" 2>/dev/null)" && [[ "$VM_STATE" == running ]]; then
    info "Reusing the running SNO VM ${MGMT_VM_NAME}"
elif virsh dominfo "$MGMT_VM_NAME" >/dev/null 2>&1; then
    die "SNO VM ${MGMT_VM_NAME} exists but is not running; start it through cluster-tool before continuing"
else
    [[ -f "$PULL_SECRET" ]] || die "Pull secret not found: ${PULL_SECRET}"
    FLAVORS="$(cluster-tool flavors 2>/dev/null || true)"
    if ! grep -Fq "$SNO_FLAVOR" <<<"$FLAVORS"; then
        info "Pulling SNO snapshot ${SNO_IMAGE}..."
        cluster-tool pull "$SNO_IMAGE"
    fi
    info "Booting SNO snapshot ${SNO_FLAVOR} as ${MGMT_CLONE_NAME}..."
    cluster-tool boot --flavor "$SNO_FLAVOR" --name "$MGMT_CLONE_NAME" --pull-secret "$PULL_SECRET"
fi

info "Waiting for the OpenShift API and node in ${MGMT_CLONE_NAME}..."
api_ready=false
for ((attempt = 1; attempt <= 180; attempt++)); do
    if oc get nodes >/dev/null 2>&1; then
        api_ready=true
        break
    fi
    sleep 10
done
[[ "$api_ready" == true ]] || die "OpenShift API did not become available"
oc wait nodes --all --for=condition=Ready --timeout=20m >/dev/null

# Phase 2: build and push the updated AAP execution environment.
if ! "$CONTAINER_TOOL" login --get-login quay.io >/dev/null 2>&1; then
    die "No saved ${CONTAINER_TOOL} login for quay.io; authenticate before building the AAP image"
fi
info "Building and pushing the AgentlessNet AAP execution environment ${AAP_IMAGE}..."
make -C "$AAP_DIR" execution-environment-build \
    "IMG=${AAP_IMAGE}" "CONTAINER_TOOL=${CONTAINER_TOOL}"
make -C "$AAP_DIR" execution-environment-push \
    "IMG=${AAP_IMAGE}" "CONTAINER_TOOL=${CONTAINER_TOOL}"

# Phase 3: install OSAC on a clean cluster or upgrade the existing release in place.
OVERLAY_FILE="${INSTALLER_DIR}/values/agentless-net-vn-smoke.yaml"
[[ -f "$OVERLAY_FILE" ]] || die "AgentlessNet VirtualNetwork overlay is missing: ${OVERLAY_FILE}"
info "Refreshing local umbrella-chart dependencies from this checkout..."
helm dependency build "${INSTALLER_DIR}/charts/osac"
EXTRA_HELM_ARGS="-f ${OVERLAY_FILE} --set-string aap.configAsCode.eeImage=${AAP_IMAGE} --set-string aap.configAsCode.projectGitUri=${AAP_PROJECT_GIT_URI} --set-string aap.configAsCode.projectGitBranch=${AAP_PROJECT_GIT_BRANCH}"
EXISTING_OSAC_RELEASE="$(helm list -n "$OSAC_NAMESPACE" --filter '^osac$' --short)"
PREVIOUS_DEPLOYMENT_SETTINGS="{}"
if [[ -n "$EXISTING_OSAC_RELEASE" ]]; then
    PREVIOUS_DEPLOYMENT_SETTINGS="$(deployment_settings)" \
        || die "Could not capture the existing AAP and networking values"
    prepare_upgrade_values
fi
if [[ "$OSAC_INSTALL_MODE" == install && -n "$EXISTING_OSAC_RELEASE" ]]; then
    die "OSAC_INSTALL_MODE=install but an OSAC release already exists; use auto or upgrade"
fi
if [[ "$OSAC_INSTALL_MODE" == upgrade && -z "$EXISTING_OSAC_RELEASE" ]]; then
    die "OSAC_INSTALL_MODE=upgrade but no OSAC release exists"
fi

if [[ -n "$EXISTING_OSAC_RELEASE" || "$OSAC_INSTALL_MODE" == upgrade ]]; then
    info "Upgrading the existing OSAC release with normalized values; deferring AAP config-as-code to the existing Controller objects..."
    helm upgrade osac "${INSTALLER_DIR}/charts/osac" \
        --namespace "$OSAC_NAMESPACE" \
        --reset-values \
        --values "$UPGRADE_VALUES_FILE" \
        --set aap.bootstrap.enabled=false \
        --set-string "aap.configAsCode.eeImage=${AAP_IMAGE}" \
        --set-string "aap.configAsCode.projectGitUri=${AAP_PROJECT_GIT_URI}" \
        --set-string "aap.configAsCode.projectGitBranch=${AAP_PROJECT_GIT_BRANCH}" \
        --values "$OVERLAY_FILE" \
        --wait --timeout 40m
else
    [[ -f "$AAP_LICENSE_FILE" ]] || die "AAP license file not found: ${AAP_LICENSE_FILE}"
    info "Installing OSAC with the AgentlessNet VirtualNetwork profile in ${OSAC_NAMESPACE}..."
    make -C "$INSTALLER_DIR" install \
        PLATFORM=openshift \
        PROFILE="$OSAC_PROFILE" \
        NS="$OSAC_NAMESPACE" \
        "AAP_LICENSE_FILE=${AAP_LICENSE_FILE}" \
        "EXTRA_HELM_ARGS=${EXTRA_HELM_ARGS}"
fi

CURRENT_DEPLOYMENT_SETTINGS="$(deployment_settings)" \
    || die "Could not capture the deployed AAP and networking values"
printf 'Deployment values before test: %s\n' "$PREVIOUS_DEPLOYMENT_SETTINGS"
printf 'Deployment values for test: %s\n' "$CURRENT_DEPLOYMENT_SETTINGS"

info "Waiting for the existing or newly installed OSAC/AAP deployments..."
oc wait deployment/fulfillment-grpc-server -n "$OSAC_NAMESPACE" \
    --for=condition=Available --timeout=300s >/dev/null
oc wait deployment/osac-operator -n "$OSAC_NAMESPACE" \
    --for=condition=Available --timeout=300s >/dev/null
oc wait deployment/osac-aap-controller-task -n "$OSAC_NAMESPACE" \
    --for=condition=Available --timeout=300s >/dev/null

AAP_BRANCH="$(helm get values osac -n "$OSAC_NAMESPACE" --all -o json | jq -er '.aap.configAsCode.projectGitBranch')" \
    || die "Could not read the current AAP project branch from Helm release values"
EXPECTED_AAP_BRANCH="${AAP_PROJECT_GIT_BRANCH:-$CURRENT_BRANCH}"
[[ "$AAP_BRANCH" == "$EXPECTED_AAP_BRANCH" ]] \
    || die "AAP project branch is ${AAP_BRANCH}; expected ${EXPECTED_AAP_BRANCH}. Update the existing AAP project before running this E2E."
info "AAP project branch: ${AAP_BRANCH}"

# Phase 4: synchronize the exact AAP source revision and prepare only the
# Containerlab topology, its net-node, sanitized inventory, and networking IG.
sync_aap_project_revision
configure_aap_execution_environment
resolve_mgmt_network
write_provider_inventory
ensure_containerlab_net_node
prepare_containerlab_net_node
prepare_aap_networking_instance_group

# Phase 5: create, verify, retry, isolate, and delete VirtualNetworks through
# the CLI, Fulfillment, the operator, and real AAP jobs. The EXIT trap cleans
# only this run's VNs and restores temporary AAP SSH/instance-group settings.
info "Preparing a temporary CLI CA bundle and building the CLI from this checkout..."
CLI_CA_FILE="$(mktemp "${TMPDIR:-/tmp}/osac-5529-ca.XXXXXX")"
oc get configmap ca-bundle -n "$OSAC_NAMESPACE" \
    -o jsonpath='{.data.bundle\.pem}' > "$CLI_CA_FILE"
[[ -s "$CLI_CA_FILE" ]] || die "OSAC CA bundle is empty"
(
    cd "${REPO_ROOT}/fulfillment-service"
    go build -o "$CLI_BIN" ./cmd/osac
)

CLUSTER_DOMAIN="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
OSAC_API="https://fulfillment-api-${OSAC_NAMESPACE}.${CLUSTER_DOMAIN}"
OSAC_TOKEN_SCRIPT="oc create token -n ${OSAC_NAMESPACE} ${OSAC_SERVICE_ACCOUNT} --duration=1h"
"$CLI_BIN" --config "$CLI_CONFIG_DIR" --tenant "$OSAC_TENANT" login \
    --ca-file "$CLI_CA_FILE" \
    --token-script "$OSAC_TOKEN_SCRIPT" \
    "$OSAC_API"

ensure_osac_tenant
"$CLI_BIN" --config "$CLI_CONFIG_DIR" --tenant "$OSAC_TENANT" tenant "$OSAC_TENANT"

netnode() {
    docker exec "$CONTAINERLAB_NET_NODE" "$@"
}

state_snapshot() {
    netnode sh -c 'if [ -f "$1" ]; then cat -- "$1"; else printf "{\"schema_version\":1,\"virtual_networks\":[]}\n"; fi' \
        sh "$AGENTLESS_NET_STATE_FILE"
}

save_current_state() {
    state_snapshot > "$CURRENT_STATE_FILE"
    jq -e '.schema_version == 1 and (.virtual_networks | type == "array")' \
        "$CURRENT_STATE_FILE" >/dev/null \
        || die "AgentlessNet state is not a valid schema-v1 snapshot"
}

assert_baseline_state_unchanged() {
    local uid before after
    while IFS= read -r uid; do
        [[ -n "$uid" ]] || continue
        before="$(jq -cS --arg uid "$uid" '.virtual_networks[] | select(.uid == $uid)' "$BASELINE_STATE_FILE")"
        after="$(jq -cS --arg uid "$uid" '.virtual_networks[] | select(.uid == $uid)' "$CURRENT_STATE_FILE")"
        [[ -n "$after" && "$before" == "$after" ]] \
            || die "Pre-existing AgentlessNet state for UID ${uid} changed during the test"
    done < <(jq -r '.virtual_networks[].uid' "$BASELINE_STATE_FILE")
}

get_state_entry() {
    local uid="$1"
    save_current_state
    jq -ce --arg uid "$uid" '
      [.virtual_networks[] | select(.uid == $uid)]
      | if length == 1 then .[0] else error("expected exactly one state entry for UID " + $uid) end' \
      "$CURRENT_STATE_FILE"
}

assert_virtual_network_state() {
    local fulfillment_id="$1"
    local expected_cidr="$2"
    local peer_fulfillment_id="${3:-}"
    local cr_json cr_uid cr_name backend_id cr_cidr entry transit_cidr namespace_name
    local host_interface namespace_interface namespace_ip host_ip gateway
    local expected_addresses host_address_json namespace_address_json
    local host_link_json namespace_link_json route_json all_routes policy rules

    cr_json="$(virtual_network_cr_json "$fulfillment_id")"
    cr_uid="$(jq -r '.metadata.uid' <<<"$cr_json")"
    cr_name="$(jq -r '.metadata.name' <<<"$cr_json")"
    backend_id="$(jq -r '.status.backendNetworkId // ""' <<<"$cr_json")"
    cr_cidr="$(jq -r '.spec.ipv4Cidr' <<<"$cr_json")"
    [[ -n "$cr_uid" && "$backend_id" == "$cr_uid" ]] \
        || die "VirtualNetwork ${fulfillment_id} does not report its Kubernetes UID as backendNetworkId"
    [[ "$cr_cidr" == "$expected_cidr" ]] \
        || die "VirtualNetwork ${fulfillment_id} CR CIDR changed from the request"

    entry="$(get_state_entry "$cr_uid")"
    [[ "$(jq -r '.virtual_network_cidr' <<<"$entry")" == "$expected_cidr" ]] \
        || die "Saved provider CIDR does not match the VirtualNetwork CR"
    transit_cidr="$(jq -r '.transit.cidr' <<<"$entry")"
    [[ "$transit_cidr" == */31 ]] || die "Transit link is not an IPv4 /31: ${transit_cidr}"
    read -r host_ip namespace_ip < <(python3 -c 'import ipaddress,sys; n=ipaddress.ip_network(sys.argv[1], strict=True); print(f"{n.network_address}/{n.prefixlen} {n.network_address + 1}/{n.prefixlen}")' "$transit_cidr")
    [[ "$(jq -r '.transit.host_ip' <<<"$entry")" == "$host_ip" ]] \
        || die "Saved host-side /31 endpoint is incorrect"
    [[ "$(jq -r '.transit.namespace_ip' <<<"$entry")" == "$namespace_ip" ]] \
        || die "Saved namespace-side /31 endpoint is incorrect"
    gateway="$(jq -r '.transit.gateway' <<<"$entry")"
    [[ "$gateway" == "${host_ip%/*}" ]] || die "Saved namespace gateway is not the host-side endpoint"
    [[ "$(jq -r '.default_forward_policy' <<<"$entry")" == permit_all ]] \
        || die "Saved namespace forwarding baseline is not permit-all"
    jq -e '((keys | sort) == ["default_forward_policy","namespace_name","transit","uid","uplink","virtual_network_cidr"])
      and ((.transit | keys | sort) == ["cidr","gateway","host_ip","namespace_ip"])' \
      <<<"$entry" >/dev/null || die "Saved v1 state contains an unexpected field shape"

    namespace_name="$(jq -r '.namespace_name' <<<"$entry")"
    host_interface="$(jq -r '.uplink.host_interface' <<<"$entry")"
    namespace_interface="$(jq -r '.uplink.namespace_interface' <<<"$entry")"
    local namespaces
    namespaces="$(netnode ip netns list)"
    awk -v name="$namespace_name" '$1 == name { found=1 } END { exit !found }' <<<"$namespaces" \
        || die "Linux namespace ${namespace_name} is absent"

    host_link_json="$(netnode ip -j -d link show dev "$host_interface")"
    jq -e --arg alias "osac-vn:${cr_uid}" '
      length == 1 and .[0].ifalias == $alias and .[0].linkinfo.info_kind == "veth"
      and (.[0].flags | index("UP") != null)' <<<"$host_link_json" >/dev/null \
        || die "Host uplink ${host_interface} is not the expected UID-owned veth in UP state"
    namespace_link_json="$(netnode ip netns exec "$namespace_name" ip -j -d link show dev "$namespace_interface")"
    jq -e --arg name "$namespace_interface" '
      length == 1 and .[0].ifname == $name and (.[0].flags | index("UP") != null)' \
      <<<"$namespace_link_json" >/dev/null \
        || die "Namespace uplink ${namespace_interface} is absent or down"

    host_address_json="$(netnode ip -j -4 address show dev "$host_interface")"
    namespace_address_json="$(netnode ip netns exec "$namespace_name" ip -j -4 address show dev "$namespace_interface")"
    jq -e --arg ip "${host_ip%/*}" --argjson prefix "${host_ip#*/}" \
      'any(.[].addr_info[]?; .family == "inet" and .local == $ip and .prefixlen == $prefix)' \
      <<<"$host_address_json" >/dev/null || die "Host uplink address ${host_ip} is absent"
    jq -e --arg ip "${namespace_ip%/*}" --argjson prefix "${namespace_ip#*/}" \
      'any(.[].addr_info[]?; .family == "inet" and .local == $ip and .prefixlen == $prefix)' \
      <<<"$namespace_address_json" >/dev/null || die "Namespace uplink address ${namespace_ip} is absent"

    route_json="$(netnode ip netns exec "$namespace_name" ip -j -4 route show default)"
    jq -e --arg gateway "$gateway" --arg dev "$namespace_interface" \
      'any(.[]; .dst == "default" and .gateway == $gateway and .dev == $dev)' \
      <<<"$route_json" >/dev/null \
        || die "Namespace default route does not use gateway ${gateway} on ${namespace_interface}"
    all_routes="$(netnode ip netns exec "$namespace_name" ip -j -4 route show table all)"
    if [[ -n "$peer_fulfillment_id" ]]; then
        local peer_json peer_cidr
        peer_json="$(virtual_network_cr_json "$peer_fulfillment_id")"
        peer_cidr="$(jq -r '.spec.ipv4Cidr' <<<"$peer_json")"
        jq -e --arg cidr "$peer_cidr" 'any(.[]; .dst == $cidr)' <<<"$all_routes" >/dev/null \
            && die "Namespace ${namespace_name} has a direct route for the peer CIDR ${peer_cidr}"
    fi

    [[ "$(netnode ip netns exec "$namespace_name" sysctl -n net.ipv4.ip_forward)" == 1 ]] \
        || die "IPv4 forwarding is not enabled inside namespace ${namespace_name}"
    policy="$(netnode ip netns exec "$namespace_name" iptables -w 10 -t filter -S FORWARD)"
    grep -Fxq -- '-P FORWARD ACCEPT' <<<"$policy" \
        || die "Namespace ${namespace_name} FORWARD policy is not ACCEPT"
    netnode ip netns exec "$namespace_name" iptables -w 10 -t filter -C FORWARD \
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT \
        || die "Namespace ${namespace_name} lacks its established/related return rule"
    rules="$(netnode iptables -w 10 -t filter -S FORWARD)"
    grep -Fxq -- "-A FORWARD -i ${host_interface} -j DROP" <<<"$rules" \
        || die "Host inbound isolation rule for ${host_interface} is absent"
    grep -Fxq -- "-A FORWARD -o ${host_interface} -j DROP" <<<"$rules" \
        || die "Host outbound isolation rule for ${host_interface} is absent"
    netnode ip netns exec "$namespace_name" ping -n -I "$namespace_interface" -c 1 -W 2 "$gateway" \
        >/dev/null 2>&1 || die "Namespace ${namespace_name} cannot reach its host gateway ${gateway}"

    info "Verified Fulfillment ID ${fulfillment_id}, CR ${cr_name}, Kubernetes UID ${cr_uid}, /31 ${transit_cidr}, gateway ${gateway}"
}

assert_private_vn_isolation() {
    local first_id="$1" peer_id="$2"
    local first_json peer_json first_uid peer_uid first_entry peer_entry
    local first_ns first_if peer_ip peer_ns peer_if
    first_json="$(virtual_network_cr_json "$first_id")"
    peer_json="$(virtual_network_cr_json "$peer_id")"
    first_uid="$(jq -r '.metadata.uid' <<<"$first_json")"
    peer_uid="$(jq -r '.metadata.uid' <<<"$peer_json")"
    [[ "$first_uid" != "$peer_uid" ]] || die "Overlapping VirtualNetworks share a Kubernetes UID"
    first_entry="$(get_state_entry "$first_uid")"
    peer_entry="$(get_state_entry "$peer_uid")"
    [[ "$(jq -r '.transit.cidr' <<<"$first_entry")" != "$(jq -r '.transit.cidr' <<<"$peer_entry")" ]] \
        || die "Overlapping VirtualNetworks share a transit /31"
    first_ns="$(jq -r '.namespace_name' <<<"$first_entry")"
    first_if="$(jq -r '.uplink.namespace_interface' <<<"$first_entry")"
    peer_ns="$(jq -r '.namespace_name' <<<"$peer_entry")"
    peer_if="$(jq -r '.uplink.namespace_interface' <<<"$peer_entry")"
    peer_ip="$(jq -r '.transit.namespace_ip' <<<"$peer_entry")"
    if netnode ip netns exec "$first_ns" ping -n -I "$first_if" -c 1 -W 2 "${peer_ip%/*}" \
        >/dev/null 2>&1; then
        die "Private address traffic passed from ${first_ns} to ${peer_ns} despite host isolation"
    fi
    peer_ip="$(jq -r '.transit.namespace_ip' <<<"$first_entry")"
    if netnode ip netns exec "$peer_ns" ping -n -I "$peer_if" -c 1 -W 2 "${peer_ip%/*}" \
        >/dev/null 2>&1; then
        die "Private address traffic passed from ${peer_ns} to ${first_ns} despite host isolation"
    fi
    info "Verified overlapping private-address traffic is denied in both directions"
}

delete_virtual_network_by_id() {
    local id="$1" selector current count job_id job_state
    LAST_DELETE_AAP_JOB_ID=""
    info "Deleting test-owned VirtualNetwork UUID ${id} through Fulfillment..."
    "$CLI_BIN" --config "$CLI_CONFIG_DIR" --tenant "$OSAC_TENANT" delete virtualnetwork "$id"
    selector="$(label_selector "$id")"
    for ((attempt = 1; attempt <= 120; attempt++)); do
        current="$(oc get virtualnetworks -n "$NETWORKING_NAMESPACE" -l "$selector" -o json)" \
            || die "Kubernetes API failed while checking deletion of VirtualNetwork UUID ${id}"
        count="$(jq -r '.items | length' <<<"$current")"
        if [[ "$count" == 0 ]]; then
            break
        fi
        job_id="$(jq -r '[.items[0].status.provisioningJobs[]? | select(.type == "deprovision") | .jobID] | last // ""' <<<"$current")"
        job_state="$(jq -r '[.items[0].status.provisioningJobs[]? | select(.type == "deprovision") | .state] | last // ""' <<<"$current")"
        [[ "$job_state" != Failed && "$job_state" != Canceled ]] \
            || die "AAP deprovision job failed while deleting test-owned UUID ${id}"
        [[ -z "$job_id" ]] || LAST_DELETE_AAP_JOB_ID="$job_id"
        sleep 2
    done
    [[ "$count" == 0 ]] || die "Timed out waiting for VirtualNetwork UUID ${id} deletion"
    [[ -n "$LAST_DELETE_AAP_JOB_ID" ]] \
        || die "No AAP deprovision job ID was recorded for test-owned UUID ${id}"
    info "AAP delete job ID for ${id}: ${LAST_DELETE_AAP_JOB_ID}"
    local index
    for index in "${!CREATED_IDS[@]}"; do
        if [[ "${CREATED_IDS[$index]}" == "$id" ]]; then
            unset 'CREATED_IDS[index]'
        fi
    done
}

assert_uid_provider_state_absent() {
    local uid="$1" namespace_name="$2" host_interface="$3" namespace_list
    save_current_state
    jq -e --arg uid "$uid" 'all(.virtual_networks[]; .uid != $uid)' "$CURRENT_STATE_FILE" >/dev/null \
        || die "Deleted VirtualNetwork UID ${uid} remains in provider state"
    namespace_list="$(netnode ip netns list)"
    if awk -v name="$namespace_name" '$1 == name { found=1 } END { exit !found }' <<<"$namespace_list"; then
        die "Deleted namespace ${namespace_name} remains on the test node"
    fi
    if netnode ip -j -d link show dev "$host_interface" >/dev/null 2>&1; then
        die "Deleted UID-owned host uplink ${host_interface} remains on the test node"
    fi
}

# Preserve the full pre-test JSON snapshot. Only the UIDs created by this run
# are asserted or removed; any unrelated node state remains untouched.
HOST_IP_FORWARDING_BEFORE="$(netnode sysctl -n net.ipv4.ip_forward)"
state_snapshot > "$BASELINE_STATE_FILE"
jq -e '.schema_version == 1 and (.virtual_networks | type == "array")' \
    "$BASELINE_STATE_FILE" >/dev/null \
    || die "AgentlessNet state must be valid schema v1 before the test starts"

info "Submitting two overlapping VirtualNetwork requests concurrently through Fulfillment..."
CREATE_ONE_OUTPUT="${TEMP_DIR}/create-one.out"
CREATE_TWO_OUTPUT="${TEMP_DIR}/create-two.out"
create_virtual_network() {
    local name="$1" output_file="$2" output id
    if ! "$CLI_BIN" --config "$CLI_CONFIG_DIR" --tenant "$OSAC_TENANT" \
        create virtualnetwork --name "$name" --ipv4-cidr "$VIRTUAL_NETWORK_IPV4_CIDR" \
        > "$output_file" 2>&1; then
        cat "$output_file" >&2
        return 1
    fi
    cat "$output_file" >&2
    output="$(cat "$output_file")"
    id="$(sed -nE 's/.*\(ID: ([0-9a-f-]+)\).*/\1/p' <<<"$output" | tail -n 1)"
    [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || { printf 'Could not parse Fulfillment UUID from CLI create output for %s\n' "$name" >&2; return 1; }
    printf '%s\n' "$id" > "${output_file}.id"
}
create_virtual_network "$VIRTUAL_NETWORK_NAME" "$CREATE_ONE_OUTPUT" &
CREATE_ONE_PID=$!
create_virtual_network "$PEER_VIRTUAL_NETWORK_NAME" "$CREATE_TWO_OUTPUT" &
CREATE_TWO_PID=$!
CREATE_ONE_STATUS=0
CREATE_TWO_STATUS=0
wait "$CREATE_ONE_PID" || CREATE_ONE_STATUS=$?
wait "$CREATE_TWO_PID" || CREATE_TWO_STATUS=$?
for id_file in "${CREATE_ONE_OUTPUT}.id" "${CREATE_TWO_OUTPUT}.id"; do
    if [[ -s "$id_file" ]]; then
        CREATED_IDS+=("$(cat "$id_file")")
    fi
done
[[ "$CREATE_ONE_STATUS" == 0 && "$CREATE_TWO_STATUS" == 0 ]] \
    || die "One or both concurrent Fulfillment create requests failed"
[[ "${#CREATED_IDS[@]}" == 2 ]] || die "Did not capture both test VirtualNetwork Fulfillment UUIDs"
FIRST_FULFILLMENT_ID="$(cat "${CREATE_ONE_OUTPUT}.id")"
SECOND_FULFILLMENT_ID="$(cat "${CREATE_TWO_OUTPUT}.id")"
[[ "$FIRST_FULFILLMENT_ID" != "$SECOND_FULFILLMENT_ID" ]] \
    || die "Fulfillment returned the same UUID for both VirtualNetwork requests"

wait_for_virtual_network_ready "$FIRST_FULFILLMENT_ID"
wait_for_virtual_network_ready "$SECOND_FULFILLMENT_ID"
FIRST_CR="$(virtual_network_cr_json "$FIRST_FULFILLMENT_ID")"
SECOND_CR="$(virtual_network_cr_json "$SECOND_FULFILLMENT_ID")"
FIRST_K8S_UID="$(jq -r '.metadata.uid' <<<"$FIRST_CR")"
SECOND_K8S_UID="$(jq -r '.metadata.uid' <<<"$SECOND_CR")"
FIRST_AAP_JOB_ID="$(jq -er '.status.provisioningJobs | map(.jobID // empty) | last' <<<"$FIRST_CR")"
SECOND_AAP_JOB_ID="$(jq -er '.status.provisioningJobs | map(.jobID // empty) | last' <<<"$SECOND_CR")"
info "AAP create job IDs: ${FIRST_AAP_JOB_ID}, ${SECOND_AAP_JOB_ID}"
printf 'create Fulfillment UUIDs: %s %s\n' "$FIRST_FULFILLMENT_ID" "$SECOND_FULFILLMENT_ID"
printf 'create Kubernetes UIDs: %s %s\n' "$FIRST_K8S_UID" "$SECOND_K8S_UID"
printf 'create AAP job IDs: %s %s\n' "$FIRST_AAP_JOB_ID" "$SECOND_AAP_JOB_ID"

info "Checking exact /31 endpoints, namespace gateway reachability, and host forwarding rules..."
assert_virtual_network_state "$FIRST_FULFILLMENT_ID" "$VIRTUAL_NETWORK_IPV4_CIDR" "$SECOND_FULFILLMENT_ID"
assert_virtual_network_state "$SECOND_FULFILLMENT_ID" "$VIRTUAL_NETWORK_IPV4_CIDR" "$FIRST_FULFILLMENT_ID"
assert_private_vn_isolation "$FIRST_FULFILLMENT_ID" "$SECOND_FULFILLMENT_ID"
save_current_state
assert_baseline_state_unchanged

FIRST_ENTRY_BEFORE_REHYDRATE="$(get_state_entry "$FIRST_K8S_UID" | jq -cS '.')"
FIRST_JOB_BEFORE_REHYDRATE="$FIRST_AAP_JOB_ID"
FIRST_CR_NAME="$(jq -r '.metadata.name' <<<"$FIRST_CR")"
FIRST_NAMESPACE_NAME="$(jq -r '.namespace_name' <<<"$(get_state_entry "$FIRST_K8S_UID")")"
FIRST_HOST_INTERFACE="$(jq -r '.uplink.host_interface' <<<"$(get_state_entry "$FIRST_K8S_UID")")"
info "Removing only the first test UID's transient namespace and uplink, then resetting its operator job history to exercise AAP rehydration..."
netnode ip netns delete "$FIRST_NAMESPACE_NAME"
netnode ip link delete dev "$FIRST_HOST_INTERFACE"
save_current_state
[[ "$(jq -cS --arg uid "$FIRST_K8S_UID" '.virtual_networks[] | select(.uid == $uid)' "$CURRENT_STATE_FILE")" == "$FIRST_ENTRY_BEFORE_REHYDRATE" ]] \
    || die "Removing runtime objects changed the persisted UID allocation"
oc patch virtualnetwork "$FIRST_CR_NAME" -n "$NETWORKING_NAMESPACE" --subresource=status \
    --type=merge -p '{"status":{"phase":"Progressing","conditions":[],"provisioningJobs":[]}}' >/dev/null

REHYDRATED=false
for ((attempt = 1; attempt <= 120; attempt++)); do
    FIRST_CR="$(virtual_network_cr_json "$FIRST_FULFILLMENT_ID")"
    FIRST_AAP_JOB_ID="$(jq -r '.status.provisioningJobs | map(.jobID // empty) | last // ""' <<<"$FIRST_CR")"
    if [[ -n "$FIRST_AAP_JOB_ID" && "$FIRST_AAP_JOB_ID" != "$FIRST_JOB_BEFORE_REHYDRATE" ]]; then
        REHYDRATED=true
        break
    fi
    sleep 2
done
[[ "$REHYDRATED" == true ]] \
    || die "Operator did not trigger a second AAP job for the same Kubernetes UID"
info "Rehydration AAP job ID: ${FIRST_AAP_JOB_ID}"
wait_for_aap_provision_success "$FIRST_FULFILLMENT_ID" "$FIRST_AAP_JOB_ID"
wait_for_virtual_network_ready "$FIRST_FULFILLMENT_ID"
[[ "$(get_state_entry "$FIRST_K8S_UID" | jq -cS '.')" == "$FIRST_ENTRY_BEFORE_REHYDRATE" ]] \
    || die "AAP retry allocated a different transit link or changed the UID mapping"
assert_virtual_network_state "$FIRST_FULFILLMENT_ID" "$VIRTUAL_NETWORK_IPV4_CIDR" "$SECOND_FULFILLMENT_ID"
assert_private_vn_isolation "$FIRST_FULFILLMENT_ID" "$SECOND_FULFILLMENT_ID"
save_current_state
assert_baseline_state_unchanged

info "Deleting the first test VirtualNetwork and verifying its peer remains provisioned..."
FIRST_PEER_ENTRY="$(get_state_entry "$SECOND_K8S_UID" | jq -cS '.')"
delete_virtual_network_by_id "$FIRST_FULFILLMENT_ID"
FIRST_DELETE_AAP_JOB_ID="$LAST_DELETE_AAP_JOB_ID"
printf 'delete AAP job ID (first VN): %s\n' "$FIRST_DELETE_AAP_JOB_ID"
assert_uid_provider_state_absent "$FIRST_K8S_UID" "$FIRST_NAMESPACE_NAME" "$FIRST_HOST_INTERFACE"
[[ "$(get_state_entry "$SECOND_K8S_UID" | jq -cS '.')" == "$FIRST_PEER_ENTRY" ]] \
    || die "Deleting the first VirtualNetwork altered its peer's provider entry"
assert_virtual_network_state "$SECOND_FULFILLMENT_ID" "$VIRTUAL_NETWORK_IPV4_CIDR"
save_current_state
assert_baseline_state_unchanged

info "Deleting the remaining test VirtualNetwork and checking final cleanup..."
SECOND_NAMESPACE_NAME="$(jq -r '.namespace_name' <<<"$(get_state_entry "$SECOND_K8S_UID")")"
SECOND_HOST_INTERFACE="$(jq -r '.uplink.host_interface' <<<"$(get_state_entry "$SECOND_K8S_UID")")"
delete_virtual_network_by_id "$SECOND_FULFILLMENT_ID"
SECOND_DELETE_AAP_JOB_ID="$LAST_DELETE_AAP_JOB_ID"
printf 'delete AAP job ID (peer VN): %s\n' "$SECOND_DELETE_AAP_JOB_ID"
assert_uid_provider_state_absent "$SECOND_K8S_UID" "$SECOND_NAMESPACE_NAME" "$SECOND_HOST_INTERFACE"
save_current_state
assert_baseline_state_unchanged
HOST_IP_FORWARDING_AFTER="$(netnode sysctl -n net.ipv4.ip_forward)"
[[ "$HOST_IP_FORWARDING_AFTER" == "$HOST_IP_FORWARDING_BEFORE" ]] \
    || die "The AgentlessNet operations changed the test node's forwarding sysctl"

info "Existing-lab AgentlessNet E2E passed: concurrent overlapping creates, AAP create/retry/delete jobs, exact /31 state, gateway reachability, bidirectional private traffic denial, peer preservation, and test-owned cleanup."
