#!/usr/bin/env bash
# OSAC-5530 AgentlessNet VirtualNetwork and Subnet E2E flow:
#   1. Boot or reuse the SNO with cluster-tool.
#   2. Build and push runtime images when source inputs changed, or reuse their tags.
#   3. Install or upgrade OSAC with those custom images.
#   4. Run the AgentlessNet lifecycle with real DHCP clients and traffic checks.
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
# auto reuses images tagged for the latest commit outside this runner; true/false force reuse/build.
REUSE_PREBUILT_OSAC_IMAGES="${REUSE_PREBUILT_OSAC_IMAGES:-auto}"
CLIENT_IMAGE="${CLIENT_IMAGE:-busybox:1.36.1}"
VLAN_E2E_DEBUG="${VLAN_E2E_DEBUG:-false}"
VLAN_E2E_ARTIFACT_DIR="${VLAN_E2E_ARTIFACT_DIR:-}"
DHCP_CLIENT_PREFIX="${DHCP_CLIENT_PREFIX:-osac5530-$(date -u +%Y%m%d%H%M%S)}"
CURRENT_BRANCH="$(git -C "$REPO_ROOT" branch --show-current)"
IMAGE_SOURCE_COMMIT="$(git -C "$REPO_ROOT" rev-list -1 HEAD -- . ':(exclude)vlan-e2e.sh')"
[[ -n "$IMAGE_SOURCE_COMMIT" ]] || { printf 'ERROR: could not determine the latest non-runner source commit\n' >&2; exit 1; }
IMAGE_SOURCE_SHORT="${IMAGE_SOURCE_COMMIT:0:12}"
AAP_IMAGE="${AAP_IMAGE:-quay.io/ybettan/osac-aap:osac-5530-${IMAGE_SOURCE_SHORT}}"
OPERATOR_IMAGE="${OPERATOR_IMAGE:-quay.io/ybettan/osac-operator:osac-5530-${IMAGE_SOURCE_SHORT}}"
OPERATOR_IMAGE_REPOSITORY="${OPERATOR_IMAGE%:*}"
OPERATOR_IMAGE_TAG="${OPERATOR_IMAGE##*:}"
AAP_PROJECT_GIT_URI="${AAP_PROJECT_GIT_URI:-https://github.com/ybettan/osac}"
AAP_PROJECT_GIT_BRANCH="${AAP_PROJECT_GIT_BRANCH:-${CURRENT_BRANCH}}"
AAP_PREFIX="${AAP_PREFIX:-${AAP_ORGANIZATION_NAME:-osac}}"
AAP_PROJECT_NAME="${AAP_PROJECT_NAME:-${AAP_PREFIX}}"
# By default, verify AAP against this checkout's commit. Set this when testing
# local workflow-only changes that are not part of the AAP project source branch.
AAP_PROJECT_EXPECTED_REVISION="${AAP_PROJECT_EXPECTED_REVISION:-$(git -C "$REPO_ROOT" rev-parse HEAD)}"

OSAC_NAMESPACE="${OSAC_NAMESPACE:-osac-e2e-ci}"
OSAC_TENANT="${OSAC_TENANT:-osac-e2e-ci}"
OSAC_SERVICE_ACCOUNT="${OSAC_SERVICE_ACCOUNT:-osac-operator}"
NETWORKING_NAMESPACE="${OSAC_NETWORKING_NAMESPACE:-${OSAC_NAMESPACE}}"
AGENTLESS_NET_STATE_FILE="${AGENTLESS_NET_STATE_FILE:-/etc/osac/agentless_network_state.sqlite3}"
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
SUBNET_ONE_NAME="${SUBNET_ONE_NAME:-${VIRTUAL_NETWORK_NAME}-subnet-a}"
SUBNET_TWO_NAME="${SUBNET_TWO_NAME:-${VIRTUAL_NETWORK_NAME}-subnet-b}"
SUBNET_THREE_NAME="${SUBNET_THREE_NAME:-${VIRTUAL_NETWORK_NAME}-subnet-30}"
SUBNET_ONE_IPV4_CIDR="${SUBNET_ONE_IPV4_CIDR:-}"
SUBNET_TWO_IPV4_CIDR="${SUBNET_TWO_IPV4_CIDR:-}"
SUBNET_THREE_IPV4_CIDR="${SUBNET_THREE_IPV4_CIDR:-}"

CLI_BIN="${OSAC_CLI_BIN:-}"
CLI_CONFIG_DIR="${OSAC_CLI_CONFIG_DIR:-}"
CLI_CA_FILE=""
TEMP_DIR=""
GENERATED_CLI_BIN=false
GENERATED_CLI_CONFIG=false
CREATED_IDS=()
CREATED_SUBNET_IDS=()
BASELINE_STATE_FILE=""
CURRENT_STATE_FILE=""
SWITCH_MANIFEST_FILE=""
SSH_PRIVATE_KEY_FILE=""
SSH_PUBLIC_KEY_FILE=""
SSH_KEY_CREATED_BY_RUN=false
SSH_KEY_EXPECTED_BASE64=""
SSH_KEY_ORIGINAL_ANNOTATION=""
SSH_PUBLIC_KEY_INSTALLED_BY_RUN=false
SSH_AUTHORIZED_KEYS_EXISTED=false
CONTAINERLAB_ACCESS_CONFIGURED=false
NETNODE_DOCKER_BRIDGE_ATTACHED_BY_RUN=false
NETNODE_SUDOERS_CREATED_BY_RUN=false
NETNODE_SSHD_CREATED_BY_RUN=false
SWITCH_ACCESS_CONFIGURED=false
SUPERVISOR_CONFIG_CREATED_BY_RUN=false
SUPERVISOR_DAEMON_STARTED_BY_RUN=false
ACCESS_PORTS_SNAPSHOT_FILE=""
SWITCH_VLAN_SNAPSHOT_FILE=""
CLIENT_EXPECTED_LEASES_FILE=""
DHCP_CLIENT_HELPER=""
DHCP_CLIENT_HOOK=""
DHCP_CLIENT_CONTAINERS=()
DHCP_CLIENT_HOST_LINKS=()
DEBUG_CAPTURE_PID_FILES=()
DEBUG_CAPTURE_LAUNCH_PIDS=()
DEBUG_ARTIFACT_DIR=""
DEBUG_ARTIFACT_DIR_GENERATED=false
declare -A SWITCH_AUTHORIZED_KEYS_EXISTED=()
declare -A SWITCH_PUBLIC_KEY_INSTALLED_BY_RUN=()
declare -A SWITCH_SUDOERS_CREATED_BY_RUN=()
declare -A CLIENT_PORT_CONFIGURED=()
declare -A CLIENT_PORT_VLAN=()
INVENTORY_CONFIGMAP_CHANGED_BY_RUN=false
INVENTORY_CONFIGMAP_BACKUP=""
INVENTORY_CONFIGMAP_EXPECTED=""
PRESERVE_E2E_RECOVERY_ARTIFACTS=false
AAP_API_ROUTE=""
UPGRADE_VALUES_FILE=""

info() { printf '==> %s\n' "$*"; }
step() {
    printf '\n========================\n%s\n=============================\n' "$*"
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

label_selector() { printf 'osac.openshift.io/virtualnetwork-uuid=%s' "$1"; }
subnet_label_selector() { printf 'osac.openshift.io/subnet-uuid=%s' "$1"; }

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
    else
        annotation="$(jq -r --arg key "$AAP_SSH_KEY_SECRET_ANNOTATION" \
            '.metadata.annotations[$key] // ""' <<<"$secret_json")"
        [[ -z "$annotation" || "$annotation" == OSAC-5529 ]] \
            || die "Refusing to replace pre-existing AAP SSH-key ownership metadata"
        SSH_KEY_ORIGINAL_ANNOTATION="$annotation"
        info "Creating an ephemeral SSH key for the Containerlab network node..."
        ssh-keygen -q -t ed25519 -N '' -C osac-5529-netnode -f "$key_file"
        patch_file="$TEMP_DIR/aap-networking-key-patch.json"
        python3 - "$key_file" "$AAP_SSH_KEY_SECRET_KEY" \
            "$AAP_SSH_KEY_SECRET_ANNOTATION" "$SSH_KEY_ORIGINAL_ANNOTATION" \
            "$patch_file" <<'PY'
import base64
import json
import pathlib
import sys

key_path, data_key, annotation_key, original_annotation, patch_path = sys.argv[1:]
key = pathlib.Path(key_path).read_bytes()
payload = {"data": {data_key: base64.b64encode(key).decode("ascii")}}
if not original_annotation:
    payload["metadata"] = {"annotations": {annotation_key: "OSAC-5529"}}
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

restore_netnode_download_network() {
    [[ "$NETNODE_DOCKER_BRIDGE_ATTACHED_BY_RUN" == true ]] || return 0
    docker network disconnect bridge "$CONTAINERLAB_NET_NODE" >/dev/null \
        || return 1
    NETNODE_DOCKER_BRIDGE_ATTACHED_BY_RUN=false
}

prepare_containerlab_net_node() {
    local public_key authorized_exists package_log bridge_status
    ensure_aap_ssh_key
    info "Installing provider tools and key-only SSH access on the Containerlab network node..."
    package_log="$TEMP_DIR/containerlab-package-install.log"
    if ! docker exec "$CONTAINERLAB_NET_NODE" apk add --no-cache \
        iptables iproute2 python3 openssh sudo conntrack-tools procps iputils dnsmasq supervisor >"$package_log" 2>&1; then
        info "The isolated Containerlab network has no package-repository egress; retrying through the Docker bridge."
        bridge_status="$(docker inspect -f '{{if index .NetworkSettings.Networks "bridge"}}true{{else}}false{{end}}' "$CONTAINERLAB_NET_NODE")" \
            || die "Could not inspect the Containerlab node network attachments"
        if [[ "$bridge_status" != true ]]; then
            docker network connect bridge "$CONTAINERLAB_NET_NODE" >/dev/null \
                || die "Could not temporarily connect the test network node to the Docker bridge"
            NETNODE_DOCKER_BRIDGE_ATTACHED_BY_RUN=true
        fi
        if ! docker exec "$CONTAINERLAB_NET_NODE" apk add --no-cache \
            iptables iproute2 python3 openssh sudo conntrack-tools procps iputils dnsmasq supervisor >"$package_log" 2>&1; then
            tail -n 20 "$package_log" >&2
            restore_netnode_download_network || true
            die "Could not install the AgentlessNet provider prerequisites on the Containerlab network node"
        fi
        restore_netnode_download_network \
            || die "Could not disconnect the temporary Docker bridge from the Containerlab network node"
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

prepare_containerlab_dhcp_supervisor() {
    if docker exec "$CONTAINERLAB_NET_NODE" test -f /etc/agentless-net/supervisord.conf; then
        if docker exec "$CONTAINERLAB_NET_NODE" grep -Fxq \
            '# OSAC-5530 temporary DHCP supervisor configuration' /etc/agentless-net/supervisord.conf; then
            SUPERVISOR_CONFIG_CREATED_BY_RUN=true
        elif ! docker exec "$CONTAINERLAB_NET_NODE" grep -Fxq \
            'files = /etc/agentless-net/supervisor.d/*.ini' /etc/agentless-net/supervisord.conf; then
            die "The existing AgentlessNet Supervisor configuration does not include its managed program directory"
        fi
    else
        docker exec -i "$CONTAINERLAB_NET_NODE" sh -s <<'SH'
set -eu
mkdir -p /etc/agentless-net/supervisor.d /run/agentless-net /var/log/agentless-net
chmod 0700 /etc/agentless-net /etc/agentless-net/supervisor.d /run/agentless-net /var/log/agentless-net
cat >/etc/agentless-net/supervisord.conf <<'CONF'
# OSAC-5530 temporary DHCP supervisor configuration
[unix_http_server]
file=/run/agentless-net/supervisor.sock
chmod=0600

[supervisord]
logfile=/var/log/agentless-net/supervisord.log
pidfile=/run/agentless-net/supervisord.pid
nodaemon=false

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///run/agentless-net/supervisor.sock

[include]
files = /etc/agentless-net/supervisor.d/*.ini
CONF
chmod 0600 /etc/agentless-net/supervisord.conf
SH
        SUPERVISOR_CONFIG_CREATED_BY_RUN=true
    fi

    if ! docker exec "$CONTAINERLAB_NET_NODE" supervisorctl \
        -c /etc/agentless-net/supervisord.conf pid >/dev/null 2>&1; then
        docker exec "$CONTAINERLAB_NET_NODE" supervisord \
            -c /etc/agentless-net/supervisord.conf
        SUPERVISOR_DAEMON_STARTED_BY_RUN=true
        for ((attempt = 1; attempt <= 30; attempt++)); do
            if docker exec "$CONTAINERLAB_NET_NODE" supervisorctl \
                -c /etc/agentless-net/supervisord.conf pid >/dev/null 2>&1; then
                break
            fi
            sleep 1
        done
        docker exec "$CONTAINERLAB_NET_NODE" supervisorctl \
            -c /etc/agentless-net/supervisord.conf pid >/dev/null 2>&1 \
            || die "AgentlessNet Supervisor did not start on the Containerlab network node"
    fi
}

ensure_containerlab_switches() {
    local switch
    jq -e '.switches | type == "array" and length > 0' "$SWITCH_MANIFEST_FILE" >/dev/null \
        || die "The workspace switch manifest is empty"
    while IFS= read -r switch; do
        [[ -n "$switch" ]] || continue
        docker inspect "$switch" >/dev/null 2>&1 \
            || die "Containerlab Cumulus switch $switch is missing"
        [[ "$(docker inspect -f '{{.State.Running}}' "$switch")" == true ]] \
            || die "Containerlab Cumulus switch $switch is stopped"
    done < <(jq -r '.switches[].name' "$SWITCH_MANIFEST_FILE")
}

prepare_containerlab_switches() {
    local switch public_key user ssh_output
    [[ -f "$SSH_PUBLIC_KEY_FILE" ]] || die "The temporary AgentlessNet SSH public key is missing"
    public_key="$(<"$SSH_PUBLIC_KEY_FILE")"
    ensure_containerlab_switches
    SWITCH_ACCESS_CONFIGURED=true
    while IFS= read -r switch; do
        [[ -n "$switch" ]] || continue
        user="$(jq -r --arg name "$switch" \
            '.switches[] | select(.name == $name) | .ansible_user' "$SWITCH_MANIFEST_FILE")"
        if docker exec "$switch" test -f /etc/sudoers.d/osac-agentless-net; then
            if docker exec "$switch" grep -Fxq '# OSAC-5530 temporary provider access' \
                /etc/sudoers.d/osac-agentless-net || docker exec "$switch" grep -Fxq \
                '# OSAC-5529 temporary provider access' /etc/sudoers.d/osac-agentless-net; then
                SWITCH_SUDOERS_CREATED_BY_RUN["$switch"]=true
            else
                die "Cumulus switch $switch already has an unrelated sudoers file at the test path"
            fi
        else
            docker exec -i "$switch" sh -s <<'SH'
set -eu
printf '%s\n' '# OSAC-5530 temporary provider access' 'cumulus ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/osac-agentless-net
chmod 0440 /etc/sudoers.d/osac-agentless-net
visudo -cf /etc/sudoers.d/osac-agentless-net >/dev/null
SH
            SWITCH_SUDOERS_CREATED_BY_RUN["$switch"]=true
        fi
        docker exec "$switch" id "$user" >/dev/null 2>&1 \
            || die "Cumulus switch $switch does not have its expected SSH user"
        if docker exec "$switch" sh -c 'test -f /home/cumulus/.ssh/authorized_keys'; then
            SWITCH_AUTHORIZED_KEYS_EXISTED["$switch"]=true
        else
            SWITCH_AUTHORIZED_KEYS_EXISTED["$switch"]=false
        fi
        if docker exec "$switch" sh -c \
            'test -f /home/cumulus/.ssh/authorized_keys && grep -Fxq "$1" /home/cumulus/.ssh/authorized_keys' \
            sh "$public_key"; then
            SWITCH_PUBLIC_KEY_INSTALLED_BY_RUN["$switch"]="$SSH_KEY_CREATED_BY_RUN"
        else
            docker exec "$switch" sh -c \
                'install -d -o cumulus -g cumulus -m 0700 /home/cumulus/.ssh'
            docker exec -i "$switch" sh -c \
                'cat >>/home/cumulus/.ssh/authorized_keys' <"$SSH_PUBLIC_KEY_FILE"
            docker exec "$switch" chown cumulus:cumulus /home/cumulus/.ssh/authorized_keys
            docker exec "$switch" chmod 0600 /home/cumulus/.ssh/authorized_keys
            SWITCH_PUBLIC_KEY_INSTALLED_BY_RUN["$switch"]=true
        fi
    done < <(jq -r '.switches[].name' "$SWITCH_MANIFEST_FILE")
    while IFS= read -r switch; do
        [[ -n "$switch" ]] || continue
        local address port
        address="$(jq -r --arg name "$switch" \
            '.switches[] | select(.name == $name) | .ansible_host' "$SWITCH_MANIFEST_FILE")"
        port="$(jq -r --arg name "$switch" \
            '.switches[] | select(.name == $name) | .ansible_port' "$SWITCH_MANIFEST_FILE")"
        ssh_output="$TEMP_DIR/switch-${switch}-ssh-check.log"
        if ! ssh -i "$SSH_PRIVATE_KEY_FILE" \
            -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
            -o "UserKnownHostsFile=$TEMP_DIR/known_hosts" -o ConnectTimeout=5 \
            -p "$port" "cumulus@$address" \
            'sudo -n bridge -j vlan show >/dev/null' >"$ssh_output" 2>&1; then
            tail -n 30 "$ssh_output" >&2
            die "Key-based SSH or Cumulus VLAN tooling is unavailable on $switch"
        fi
    done < <(jq -r '.switches[].name' "$SWITCH_MANIFEST_FILE")
    info "Containerlab Cumulus switches are reachable with the isolated provider SSH key."
}

write_provider_inventory() {
    local inventory_file="$TEMP_DIR/inventory.yml"
    local host_file="$TEMP_DIR/inventory-host"
    local user_file="$TEMP_DIR/inventory-user"
    local configmap_json configured_state_file expected_inventory patch_file existing_inventory
    MGMT_BRIDGE="$MGMT_BRIDGE" MGMT_GW="$MGMT_GW" \
        MGMT_PREFIX="$MGMT_PREFIX" MGMT_CIDR="$MGMT_CIDR" \
        MGMT_DHCP_RANGES="$MGMT_DHCP_RANGES" \
        "$AAP_DIR/.venv/bin/python" - "$CONTAINERLAB_INVENTORY" \
        "$CONTAINERLAB_TOPOLOGY" "$inventory_file" "$host_file" "$user_file" \
        "$SWITCH_MANIFEST_FILE" <<'PY'
import json
import ipaddress
import os
import pathlib
import re
import sys
import yaml

source_path, topology_path, output_path, host_path, user_path = map(pathlib.Path, sys.argv[1:6])
switch_manifest_path = pathlib.Path(sys.argv[6])
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
topology_name = topology.get("name", "")
container_prefix = f"clab-{topology_name}-"
switch_group = children.get("switches", {}) if isinstance(children, dict) else {}
switch_hosts = switch_group.get("hosts", {}) if isinstance(switch_group, dict) else {}
if not isinstance(switch_hosts, dict) or not switch_hosts:
    raise SystemExit("workspace inventory must define at least one Cumulus switch")
switch_manifest = []
switch_inventory_hosts = {}
for switch_name, switch_vars in switch_hosts.items():
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", switch_name) or not switch_name.startswith(container_prefix):
        raise SystemExit("workspace switch inventory name does not match the Containerlab topology")
    if not isinstance(switch_vars, dict):
        raise SystemExit("workspace switch inventory variables must be a mapping")
    switch_host = switch_vars.get("ansible_host")
    switch_user = switch_vars.get("ansible_user")
    if not isinstance(switch_host, str) or not isinstance(switch_user, str):
        raise SystemExit("workspace switch inventory requires ansible_host and ansible_user")
    switch_host = switch_host.replace("${MGMT_PREFIX}", prefix).replace("$MGMT_PREFIX", prefix)
    if "$" in switch_host or "{{" in switch_host or "}}" in switch_host:
        raise SystemExit("workspace switch address contains an unresolved variable")
    try:
        switch_address = ipaddress.IPv4Address(switch_host)
    except ipaddress.AddressValueError as error:
        raise SystemExit("workspace switch address is not an IPv4 address") from error
    if switch_address not in cidr:
        raise SystemExit("workspace switch address is outside the SNO management network")
    for item in filter(None, os.environ.get("MGMT_DHCP_RANGES", "").split(",")):
        start, end = (ipaddress.IPv4Address(part) for part in item.split("-", 1))
        if start <= switch_address <= end:
            raise SystemExit("workspace switch address conflicts with the SNO DHCP pool")
    if switch_user != "cumulus" or switch_vars.get("ansible_network_os", "cumulus") != "cumulus":
        raise SystemExit("workspace Cumulus switches must use the cumulus account and network_os")
    try:
        switch_port = int(switch_vars.get("ansible_port", 22))
    except (TypeError, ValueError) as error:
        raise SystemExit("workspace switch SSH port must be an integer") from error
    if not 1 <= switch_port <= 65535:
        raise SystemExit("workspace switch SSH port is outside the valid range")
    trunk_ports = switch_vars.get("trunk_ports")
    if not isinstance(trunk_ports, list) or not trunk_ports:
        raise SystemExit("workspace Cumulus switches require a nonempty trunk_ports list")
    if any(not isinstance(port, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,15}", port) for port in trunk_ports):
        raise SystemExit("workspace switch trunk port contains unsupported characters")
    if len(set(trunk_ports)) != len(trunk_ports):
        raise SystemExit("workspace switch trunk_ports must be unique")
    switch_manifest.append({
        "name": switch_name,
        "ansible_host": str(switch_address),
        "ansible_user": switch_user,
        "ansible_port": switch_port,
        "trunk_ports": trunk_ports,
    })
    switch_inventory_hosts[switch_name] = {
        "ansible_host": str(switch_address),
        "ansible_user": switch_user,
        "ansible_port": switch_port,
        "ansible_network_os": "cumulus",
        "trunk_ports": trunk_ports,
    }
switch_manifest.sort(key=lambda item: item["name"])
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
            },
            "switches": {"hosts": switch_inventory_hosts},
        },
    }
}
output_path.write_text(yaml.safe_dump(output, sort_keys=False))
output_path.chmod(0o600)
switch_manifest_path.write_text(json.dumps({"switches": switch_manifest}, sort_keys=True))
switch_manifest_path.chmod(0o600)
host_path.write_text(str(address) + "\n")
host_path.chmod(0o600)
user_path.write_text(user + "\n")
user_path.chmod(0o600)
PY
    AGENTLESS_NET_HOST="$(<"$host_file")"
    AGENTLESS_NET_USER="$(<"$user_file")"
    expected_inventory="$(<"$inventory_file")"
    INVENTORY_CONFIGMAP_EXPECTED="$expected_inventory"
    configmap_json="$(oc get configmap "$AAP_NETWORKING_SECRET" -n "$OSAC_NAMESPACE" -o json)" \
        || die "The existing network-fulfillment-ig ConfigMap is missing"
    configured_state_file="$(jq -r '.data.AGENTLESS_NET_STATE_FILE // "/etc/osac/agentless_network_state.sqlite3"' <<<"$configmap_json")"
    [[ "$configured_state_file" == "$AGENTLESS_NET_STATE_FILE" ]] \
        || die "AGENTLESS_NET_STATE_FILE differs from the value configured in network-fulfillment-ig"
    existing_inventory="$(jq -r '.data.AGENTLESS_NET_VN_INVENTORY // ""' <<<"$configmap_json")"
    if [[ "$existing_inventory" == "$expected_inventory" ]]; then
        info "Verified the password-free AgentlessNet VN and switch inventory in network-fulfillment-ig."
        return 0
    fi
    INVENTORY_CONFIGMAP_BACKUP="$TEMP_DIR/network-fulfillment-inventory-backup.json"
    patch_file="$TEMP_DIR/network-fulfillment-inventory-patch.json"
    if ! python3 - "$configmap_json" "$expected_inventory" \
        "$INVENTORY_CONFIGMAP_BACKUP" "$patch_file" <<'PY'
import json
import os
import pathlib
import sys
import yaml

configmap_raw, expected_raw, backup_path, patch_path = sys.argv[1:]
data = json.loads(configmap_raw).get("data", {})
inventory_key = "AGENTLESS_NET_VN_INVENTORY"
original_inventory = data.get(inventory_key)
expected = yaml.safe_load(expected_raw)

if original_inventory is not None and original_inventory.rstrip("\n") != expected_raw.rstrip("\n"):
    existing = yaml.safe_load(original_inventory)
    try:
        existing_all = existing["all"]
        expected_all = expected["all"]
        old_net_nodes = existing_all["children"]["net_nodes"]
        new_net_nodes = expected_all["children"]["net_nodes"]
        safe_upgrade = (
            set(existing) == {"all"}
            and existing_all.get("vars", {}) == expected_all.get("vars", {})
            and set(existing_all["children"]) == {"net_nodes"}
            and old_net_nodes == new_net_nodes
        )
    except (KeyError, TypeError):
        safe_upgrade = False
    if not safe_upgrade:
        raise SystemExit("existing AgentlessNet inventory is not the known VN-only inventory")

backup = {
    "original_inventory": original_inventory,
    "expected_inventory": expected_raw,
}
patch_data = {inventory_key: expected_raw}
pathlib.Path(backup_path).write_text(json.dumps(backup))
pathlib.Path(patch_path).write_text(json.dumps({"data": patch_data}))
os.chmod(backup_path, 0o600)
os.chmod(patch_path, 0o600)
PY
    then
        die "Existing AgentlessNet inventory differs from this workspace; refusing to overwrite it"
    fi
    oc patch configmap "$AAP_NETWORKING_SECRET" -n "$OSAC_NAMESPACE" \
        --type=merge --patch-file="$patch_file" >/dev/null
    INVENTORY_CONFIGMAP_CHANGED_BY_RUN=true
    configmap_json="$(oc get configmap "$AAP_NETWORKING_SECRET" -n "$OSAC_NAMESPACE" -o json)" \
        || die "Could not verify the temporary VN inventory configuration"
    jq -e --arg expected "$expected_inventory" \
        '.data.AGENTLESS_NET_VN_INVENTORY == $expected' \
        <<<"$configmap_json" >/dev/null \
        || die "network-fulfillment-ig did not retain the temporary inventory"
    info "Installed the temporary password-free VN and Cumulus switch inventory."
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
        "$AAP_PROJECT_EXPECTED_REVISION" "$AAP_PROJECT_NAME" <<'PY'
import json
import os
import ssl
import sys
import time
import urllib.parse
import urllib.request

base = os.environ["AAP_API_ROUTE"].rstrip("/") + "/api/controller/v2"
token = os.environ["AAP_API_TOKEN"]
expected_url, expected_branch, expected_revision, expected_name = sys.argv[1:]
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
matches = [item for item in projects if item.get("name") == expected_name]
if len(matches) != 1:
    raise SystemExit(f"AAP did not return exactly one project named {expected_name}")
project = request(base + f"/projects/{matches[0]['id']}/")
if project.get("scm_type") != "git":
    raise SystemExit("The configured AAP project does not use Git SCM")
source_changed = (
    normalize(project.get("scm_url")) != normalize(expected_url)
    or project.get("scm_branch") != expected_branch
)
if source_changed:
    request(
        base + f"/projects/{project['id']}/",
        data=json.dumps({"scm_url": expected_url, "scm_branch": expected_branch}).encode(),
        method="PATCH",
    )
    project = request(base + f"/projects/{project['id']}/")
    if normalize(project.get("scm_url")) != normalize(expected_url) or project.get("scm_branch") != expected_branch:
        raise SystemExit("AAP did not retain the requested project source and branch")
if source_changed or project.get("scm_revision") != expected_revision:
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
        raise SystemExit("AAP project did not synchronize to the requested source revision")
if project.get("scm_revision") != expected_revision:
    raise SystemExit("AAP project SCM revision does not match the requested source revision")
print(f"AAP project {expected_name} synchronized to the requested source revision.")
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
    info "Using the existing network worker Pod configuration and network-fulfillment-ig envFrom for the net-node and switches."
}

restore_provider_inventory_config() {
    local current_json patch_file
    [[ "$INVENTORY_CONFIGMAP_CHANGED_BY_RUN" == true ]] || return 0
    [[ -f "$INVENTORY_CONFIGMAP_BACKUP" ]] || {
        printf 'ERROR: the temporary AgentlessNet ConfigMap backup is missing\n' >&2
        return 1
    }
    current_json="$(oc get configmap "$AAP_NETWORKING_SECRET" -n "$OSAC_NAMESPACE" -o json)" \
        || { printf 'ERROR: cannot read network-fulfillment-ig during inventory cleanup\n' >&2; return 1; }
    jq -e --arg expected "$INVENTORY_CONFIGMAP_EXPECTED" \
        '.data.AGENTLESS_NET_VN_INVENTORY == $expected' \
        <<<"$current_json" >/dev/null \
        || { printf 'ERROR: network-fulfillment-ig inventory changed during the test; preserving its current value\n' >&2; return 1; }
    patch_file="$TEMP_DIR/network-fulfillment-inventory-remove.json"
    python3 - "$INVENTORY_CONFIGMAP_BACKUP" "$patch_file" <<'PY'
import json
import os
import pathlib
import sys

backup_path, patch_path = map(pathlib.Path, sys.argv[1:])
backup = json.loads(backup_path.read_text())
restore_data = {
    "AGENTLESS_NET_VN_INVENTORY": backup["original_inventory"],
}
patch_path.write_text(json.dumps({"data": restore_data}))
os.chmod(patch_path, 0o600)
PY
    oc patch configmap "$AAP_NETWORKING_SECRET" -n "$OSAC_NAMESPACE" \
        --type=merge --patch-file="$patch_file" >/dev/null
    current_json="$(oc get configmap "$AAP_NETWORKING_SECRET" -n "$OSAC_NAMESPACE" -o json)" \
        || { printf 'ERROR: cannot verify VN inventory cleanup\n' >&2; return 1; }
    jq -e --slurpfile backup "$INVENTORY_CONFIGMAP_BACKUP" '
      (.data | has("AGENTLESS_NET_VN_INVENTORY")) == ($backup[0].original_inventory != null)
      and .data.AGENTLESS_NET_VN_INVENTORY == $backup[0].original_inventory
    ' <<<"$current_json" >/dev/null \
        || { printf 'ERROR: original AgentlessNet inventory was not restored\n' >&2; return 1; }
    INVENTORY_CONFIGMAP_CHANGED_BY_RUN=false
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
        awk -v key="$public_key" "\$0 != key" "$authorized" >"$temporary"
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

remove_containerlab_switch_keys() {
    local switch public_key keep_empty
    [[ "$SWITCH_ACCESS_CONFIGURED" == true && -f "$SSH_PUBLIC_KEY_FILE" ]] || return 0
    public_key="$(<"$SSH_PUBLIC_KEY_FILE")"
    while IFS= read -r switch; do
        [[ -n "$switch" ]] || continue
        [[ "${SWITCH_PUBLIC_KEY_INSTALLED_BY_RUN[$switch]:-false}" == true ]] || continue
        keep_empty="${SWITCH_AUTHORIZED_KEYS_EXISTED[$switch]:-false}"
        docker exec "$switch" sh -c '
            set -eu
            public_key=$1
            keep_empty=$2
            authorized=/home/cumulus/.ssh/authorized_keys
            [ -f "$authorized" ] || exit 0
            temporary=/home/cumulus/.ssh/authorized_keys.osac-5530
            awk -v key="$public_key" "\$0 != key" "$authorized" >"$temporary"
            if [ -s "$temporary" ] || [ "$keep_empty" = true ]; then
                chown cumulus:cumulus "$temporary"
                chmod 0600 "$temporary"
                mv "$temporary" "$authorized"
            else
                rm -f "$temporary" "$authorized"
            fi
        ' sh "$public_key" "$keep_empty" || return 1
        SWITCH_PUBLIC_KEY_INSTALLED_BY_RUN["$switch"]=false
    done < <(jq -r '.switches[].name' "$SWITCH_MANIFEST_FILE")
}

restore_containerlab_switch_access() {
    local switch
    [[ "$SWITCH_ACCESS_CONFIGURED" == true ]] || return 0
    while IFS= read -r switch; do
        [[ -n "$switch" ]] || continue
        if [[ "${SWITCH_SUDOERS_CREATED_BY_RUN[$switch]:-false}" == true ]]; then
            docker exec "$switch" sh -c '
                if grep -Fxq "# OSAC-5530 temporary provider access" /etc/sudoers.d/osac-agentless-net \
                    || grep -Fxq "# OSAC-5529 temporary provider access" /etc/sudoers.d/osac-agentless-net; then
                    rm -f /etc/sudoers.d/osac-agentless-net
                fi
            ' || return 1
            SWITCH_SUDOERS_CREATED_BY_RUN["$switch"]=false
        fi
    done < <(jq -r '.switches[].name' "$SWITCH_MANIFEST_FILE")
    SWITCH_ACCESS_CONFIGURED=false
}

restore_dhcp_supervisor() {
    local baseline_subnets
    [[ "$SUPERVISOR_CONFIG_CREATED_BY_RUN" == true ]] || return 0
    [[ -s "$BASELINE_STATE_FILE" ]] || return 0
    baseline_subnets="$(jq -r '.subnets | length' "$BASELINE_STATE_FILE")"
    [[ "$baseline_subnets" == 0 ]] || return 0

    if docker exec "$CONTAINERLAB_NET_NODE" supervisorctl \
        -c /etc/agentless-net/supervisord.conf pid >/dev/null 2>&1; then
        [[ "$SUPERVISOR_DAEMON_STARTED_BY_RUN" == true ]] || return 0
        docker exec "$CONTAINERLAB_NET_NODE" supervisorctl \
            -c /etc/agentless-net/supervisord.conf shutdown >/dev/null 2>&1 || true
        for ((attempt = 1; attempt <= 15; attempt++)); do
            if ! docker exec "$CONTAINERLAB_NET_NODE" supervisorctl \
                -c /etc/agentless-net/supervisord.conf pid >/dev/null 2>&1; then
                break
            fi
            sleep 1
        done
        docker exec "$CONTAINERLAB_NET_NODE" supervisorctl \
            -c /etc/agentless-net/supervisord.conf pid >/dev/null 2>&1 \
            && return 1
    fi
    docker exec "$CONTAINERLAB_NET_NODE" sh -c '
        if grep -Fxq "# OSAC-5530 temporary DHCP supervisor configuration" /etc/agentless-net/supervisord.conf; then
            rm -f /etc/agentless-net/supervisord.conf
        fi
    ' || return 1
    SUPERVISOR_CONFIG_CREATED_BY_RUN=false
    SUPERVISOR_DAEMON_STARTED_BY_RUN=false
}

restore_aap_ssh_key() {
    local patch_file="$TEMP_DIR/aap-networking-key-remove.json" current
    [[ "$SSH_KEY_CREATED_BY_RUN" == true ]] || return 0
    current="$(oc get secret "$AAP_NETWORKING_SECRET" -n "$OSAC_NAMESPACE" -o json)" \
        || { printf 'ERROR: cannot verify the temporary AAP SSH key before cleanup\n' >&2; return 1; }
    if [[ "$(jq -r --arg key "$AAP_SSH_KEY_SECRET_KEY" '.data[$key] // ""' <<<"$current")" == "" ]] \
        && [[ "$(jq -r --arg key "$AAP_SSH_KEY_SECRET_ANNOTATION" \
          '.metadata.annotations[$key] // ""' <<<"$current")" == "$SSH_KEY_ORIGINAL_ANNOTATION" ]]; then
        SSH_KEY_CREATED_BY_RUN=false
        SSH_KEY_EXPECTED_BASE64=""
        SSH_KEY_ORIGINAL_ANNOTATION=""
        return 0
    fi
    if [[ "$(jq -r --arg key "$AAP_SSH_KEY_SECRET_KEY" '.data[$key] // ""' <<<"$current")" \
        != "$SSH_KEY_EXPECTED_BASE64" ]] \
        || [[ "$(jq -r --arg key "$AAP_SSH_KEY_SECRET_ANNOTATION" \
          '.metadata.annotations[$key] // ""' <<<"$current")" != OSAC-5529 ]]; then
        printf 'ERROR: the temporary AAP SSH key changed during the run; preserving the current Secret value\n' >&2
        return 1
    fi
    python3 - "$AAP_SSH_KEY_SECRET_KEY" "$AAP_SSH_KEY_SECRET_ANNOTATION" \
        "$SSH_KEY_ORIGINAL_ANNOTATION" "$patch_file" <<'PY'
import json
import pathlib
import sys

data_key, annotation_key, original_annotation, patch_path = sys.argv[1:]
payload = {"data": {data_key: None}}
if not original_annotation:
    payload["metadata"] = {"annotations": {annotation_key: None}}
pathlib.Path(patch_path).write_text(json.dumps(payload))
PY
    oc patch secret "$AAP_NETWORKING_SECRET" -n "$OSAC_NAMESPACE" \
        --type=merge --patch-file="$patch_file" >/dev/null
    current="$(oc get secret "$AAP_NETWORKING_SECRET" -n "$OSAC_NAMESPACE" -o json)" \
        || { printf 'ERROR: cannot verify AAP SSH-key cleanup\n' >&2; return 1; }
    jq -e --arg data_key "$AAP_SSH_KEY_SECRET_KEY" \
        --arg annotation_key "$AAP_SSH_KEY_SECRET_ANNOTATION" \
        --arg annotation "$SSH_KEY_ORIGINAL_ANNOTATION" \
        '(.data | has($data_key) | not) and ((.metadata.annotations[$annotation_key] // "") == $annotation)' \
        <<<"$current" >/dev/null || { printf 'ERROR: AAP networking Secret did not return to its original SSH-key state\n' >&2; return 1; }
    SSH_KEY_CREATED_BY_RUN=false
    SSH_KEY_EXPECTED_BASE64=""
    SSH_KEY_ORIGINAL_ANNOTATION=""
}

deployment_settings() {
    helm get values osac -n "$OSAC_NAMESPACE" --all -o json | jq -ce '{
      aap: {
        eeImage: .aap.configAsCode.eeImage,
        projectGitUri: .aap.configAsCode.projectGitUri,
        projectGitBranch: .aap.configAsCode.projectGitBranch
      },
      operator: {
        image: {
          repository: .operator.image.repository,
          tag: .operator.image.tag
        }
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

# The long-lived lab release can contain fields removed from this checkout's
# chart schema. Drop only those known legacy fields before validating upgrades.
aap = values.get("aap")
if isinstance(aap, dict):
    aap.pop("importAgents", None)
    aap.pop("importBcmAgents", None)
    config_as_code = aap.get("configAsCode")
    if isinstance(config_as_code, dict):
        config_as_code.pop("importAgentsEnabled", None)
        config_as_code.pop("importBcmAgentsEnabled", None)
    instance_groups = aap.get("instanceGroups")
    if isinstance(instance_groups, dict):
        cluster_fulfillment = instance_groups.get("clusterFulfillment")
        if isinstance(cluster_fulfillment, dict):
            config = cluster_fulfillment.get("config")
            if isinstance(config, dict):
                for name in (
                    "BCM_API_URL",
                    "BCM_DISABLE_BMC_CERT_VERIFICATION",
                    "BCM_VALIDATE_CERTS",
                    "IMPORT_AGENTS_DISABLE_BMC_CERT_VERIFICATION",
                    "IMPORT_AGENTS_INFRAENV_NAME",
                    "IMPORT_AGENTS_NAMESPACE",
                    "IMPORT_AGENTS_PULL_SECRET_NAME",
                ):
                    config.pop(name, None)

operator = values.get("operator")
if isinstance(operator, dict):
    stall = operator.get("stall")
    if isinstance(stall, dict):
        stall.pop("workersJoiningByHostType", None)

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

subnet_cr_json() {
    local id="$1" parent_id="$2" selector json
    selector="$(subnet_label_selector "$id")"
    json="$(oc get subnets -n "$NETWORKING_NAMESPACE" -l "$selector" -o json)" \
        || die "Kubernetes API failed while looking up Subnet UUID ${id}"
    jq -ce --arg id "$id" --arg parent "$parent_id" --arg tenant "$OSAC_TENANT" \
        --arg namespace "$NETWORKING_NAMESPACE" '
      if (.items | length) != 1 then
        error("expected one Subnet CR for Fulfillment UUID " + $id)
      else
        .items[0] as $s
        | if $s.metadata.labels["osac.openshift.io/subnet-uuid"] != $id then
            error("Subnet UUID label does not match the requested resource")
          elif $s.metadata.annotations["osac.openshift.io/tenant"] != $tenant then
            error("Subnet tenant annotation does not match the requested tenant")
          elif $s.spec.virtualNetwork != $parent then
            error("Subnet parent reference does not match its VirtualNetwork")
          elif $s.metadata.namespace != $namespace then
            error("Subnet CR is outside the configured networking namespace")
          else $s end
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

wait_for_subnet_ready() {
    local id="$1" parent_id="$2" last_state="" description state
    info "Waiting for Fulfillment Subnet ${id} to become READY..."
    for ((attempt = 1; attempt <= 120; attempt++)); do
        if ! description="$("$CLI_BIN" --config "$CLI_CONFIG_DIR" --tenant "$OSAC_TENANT" \
            describe subnet "$id")"; then
            die "Fulfillment API failed while describing Subnet ${id}"
        fi
        state="$(awk -F': *' '$1 == "State" {print $2}' <<<"$description")"
        if [[ "$state" != "$last_state" ]]; then
            info "Subnet ${id} state: ${state:-unknown}"
            last_state="$state"
        fi
        if [[ "$state" == FAILED ]]; then
            printf '%s\n' "$description" >&2
            die "Subnet ${id} failed provisioning"
        fi
        if [[ "$state" == READY ]]; then
            printf '%s\n' "$description"
            subnet_cr_json "$id" "$parent_id" >/dev/null
            return 0
        fi
        sleep 5
    done
    printf '%s\n' "$description" >&2
    die "Timed out waiting for Subnet ${id} to become READY"
}

wait_for_subnet_aap_provision_success() {
    local id="$1" parent_id="$2" job_id="$3" cr_json job_state
    for ((attempt = 1; attempt <= 120; attempt++)); do
        cr_json="$(subnet_cr_json "$id" "$parent_id")"
        job_state="$(jq -r --arg id "$job_id" \
            '[.status.provisioningJobs[]? | select(.jobID == $id) | .state] | last // ""' \
            <<<"$cr_json")"
        case "$job_state" in
            Succeeded) return 0 ;;
            Failed|Canceled)
                die "AAP provision job ${job_id} ended in ${job_state} for test Subnet ${id}"
                ;;
        esac
        sleep 2
    done
    die "Timed out waiting for AAP provision job ${job_id} to succeed for Subnet ${id}"
}

wait_for_subnet_retry_success() {
    local id="$1" parent_id="$2" previous_job="$3" cr_json job_id job_state phase
    for ((attempt = 1; attempt <= 120; attempt++)); do
        cr_json="$(subnet_cr_json "$id" "$parent_id")"
        phase="$(jq -r '.status.phase // ""' <<<"$cr_json")"
        job_id="$(jq -r '.status.provisioningJobs | map(.jobID // empty) | last // ""' <<<"$cr_json")"
        job_state="$(jq -r --arg id "$job_id" \
            '[.status.provisioningJobs[]? | select(.jobID == $id) | .state] | last // ""' \
            <<<"$cr_json")"
        [[ "$phase" != Failed ]] || die "Subnet ${id} failed during its retry"
        if [[ -n "$job_id" && "$job_id" != "$previous_job" ]]; then
            case "$job_state" in
                Succeeded)
                    RETRIED_SUBNET_AAP_JOB_ID="$job_id"
                    return 0
                    ;;
                Failed|Canceled)
                    die "AAP retry job ${job_id} ended in ${job_state} for Subnet ${id}"
                    ;;
            esac
        fi
        sleep 2
    done
    die "Timed out waiting for a new successful AAP retry job for Subnet ${id}"
}

wait_for_subnet_deleted() {
    local id="$1" selector current count job_id job_state
    selector="$(subnet_label_selector "$id")"
    for ((attempt = 1; attempt <= 120; attempt++)); do
        current="$(oc get subnets -n "$NETWORKING_NAMESPACE" -l "$selector" -o json)" \
            || die "Kubernetes API failed while checking deletion of Subnet UUID ${id}"
        count="$(jq -r '.items | length' <<<"$current")"
        if [[ "$count" == 0 ]]; then
            return 0
        fi
        job_id="$(jq -r '[.items[0].status.provisioningJobs[]? | select(.type == "deprovision") | .jobID] | last // ""' <<<"$current")"
        job_state="$(jq -r '[.items[0].status.provisioningJobs[]? | select(.type == "deprovision") | .state] | last // ""' <<<"$current")"
        [[ "$job_state" != Failed && "$job_state" != Canceled ]] \
            || die "AAP deprovision job failed while deleting test Subnet UUID ${id}"
        [[ -z "$job_id" ]] || LAST_SUBNET_DELETE_AAP_JOB_ID="$job_id"
        sleep 2
    done
    die "Timed out waiting for Subnet UUID ${id} deletion"
}

wait_for_aap_provision_success() {
    local fulfillment_id="$1" job_id="$2" cr_json job_state
    for ((attempt = 1; attempt <= 180; attempt++)); do
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

cleanup_created_subnets() {
    local id selector current test_subnets_clean=true
    if [[ -n "$CLI_BIN" && -x "$CLI_BIN" && -n "$CLI_CONFIG_DIR" && -d "$CLI_CONFIG_DIR" ]]; then
        for id in "${CREATED_SUBNET_IDS[@]}"; do
            selector="$(subnet_label_selector "$id")"
            if current="$(oc get subnets -n "$NETWORKING_NAMESPACE" -l "$selector" -o json 2>/dev/null)" \
                && [[ "$(jq -r '.items | length' <<<"$current")" != 0 ]]; then
                info "Cleaning up test-owned Subnet UUID ${id}..."
                if "$CLI_BIN" --config "$CLI_CONFIG_DIR" --tenant "$OSAC_TENANT" \
                    delete subnet "$id" >/dev/null 2>&1; then
                    for ((attempt = 1; attempt <= 120; attempt++)); do
                        current="$(oc get subnets -n "$NETWORKING_NAMESPACE" -l "$selector" -o json 2>/dev/null || true)"
                        if [[ -n "$current" ]] && [[ "$(jq -r '.items | length' <<<"$current")" == 0 ]]; then
                            break
                        fi
                        sleep 5
                    done
                else
                    printf 'WARNING: CLI cleanup failed for test-owned Subnet UUID %s\n' "$id" >&2
                fi
            fi
        done
    fi
    for id in "${CREATED_SUBNET_IDS[@]}"; do
        selector="$(subnet_label_selector "$id")"
        if ! current="$(oc get subnets -n "$NETWORKING_NAMESPACE" -l "$selector" -o json 2>/dev/null)" \
            || [[ "$(jq -r '.items | length' <<<"$current")" != 0 ]]; then
            test_subnets_clean=false
        fi
    done
    [[ "$test_subnets_clean" == true ]]
}

cleanup_created_virtual_networks() {
    local cleanup_incomplete=false
    local test_vns_clean=true test_subnets_clean=true id selector current
    if ! cleanup_created_subnets; then
        test_subnets_clean=false
        printf 'ERROR: test-owned Subnet cleanup is incomplete; preserving its provider and DHCP state for recovery\n' >&2
        cleanup_incomplete=true
    fi
    if [[ "$test_subnets_clean" == true && -n "$CLI_BIN" && -x "$CLI_BIN" \
        && -n "$CLI_CONFIG_DIR" && -d "$CLI_CONFIG_DIR" ]]; then
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
    if [[ "$test_subnets_clean" == true && "$test_vns_clean" == true ]]; then
        if ! restore_dhcp_supervisor; then
            printf 'ERROR: could not stop the temporary DHCP Supervisor or remove its owned configuration\n' >&2
            cleanup_incomplete=true
        fi
        if ! remove_netnode_public_key; then
            printf 'ERROR: could not remove the temporary public key from the Containerlab net-node\n' >&2
            cleanup_incomplete=true
        fi
        if ! restore_containerlab_netnode_access; then
            printf 'ERROR: could not stop the temporary Containerlab SSH daemon or restore sudoers\n' >&2
            cleanup_incomplete=true
        fi
        if ! remove_containerlab_switch_keys; then
            printf 'ERROR: could not remove the temporary public key from the Containerlab Cumulus switches\n' >&2
            cleanup_incomplete=true
        fi
        if ! restore_containerlab_switch_access; then
            printf 'ERROR: could not restore sudoers on the Containerlab Cumulus switches\n' >&2
            cleanup_incomplete=true
        fi
        if ! restore_netnode_download_network; then
            printf 'ERROR: could not disconnect the temporary Docker bridge from the Containerlab network node\n' >&2
            cleanup_incomplete=true
        fi
        if ! restore_provider_inventory_config; then
            printf 'ERROR: could not restore the original network-fulfillment-ig inventory state\n' >&2
            cleanup_incomplete=true
        fi
        if ! restore_aap_ssh_key; then
            printf 'ERROR: failed to restore the original AAP networking Secret data\n' >&2
            cleanup_incomplete=true
        fi
    else
        if [[ "$test_subnets_clean" != true ]]; then
            printf 'ERROR: preserving VirtualNetwork and provider access because Subnet cleanup is incomplete\n' >&2
        else
            printf 'ERROR: test-owned VirtualNetwork cleanup is incomplete; the Containerlab fabric is retained for recovery\n' >&2
        fi
        cleanup_incomplete=true
    fi
    if [[ "$cleanup_incomplete" == true ]]; then
        PRESERVE_E2E_RECOVERY_ARTIFACTS=true
        printf 'Recovery artifacts and provider credentials are preserved in %s\n' "$TEMP_DIR" >&2
        return 1
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
    return 0
}

export_dhcp_debug_artifacts() {
    local artifact copied=false
    [[ "$VLAN_E2E_DEBUG" == true ]] || return 0
    [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" && -n "$DEBUG_ARTIFACT_DIR" ]] || return 0
    if declare -F stop_dhcp_debug_captures >/dev/null; then
        stop_dhcp_debug_captures || return 1
    fi
    for artifact in \
        "$TEMP_DIR"/dhcp-debug-*.pcap \
        "$TEMP_DIR"/dhcp-debug-*.tcpdump.log \
        "$TEMP_DIR"/dhcp-debug-context-*.txt \
        "$TEMP_DIR"/dhcp-client-b1-runtime-*.txt \
        "$TEMP_DIR"/dhcp-client-b1-forwarding-*.log \
        "$TEMP_DIR"/client-b1-*-udhcpc.log \
        "$TEMP_DIR"/client-b1-*-lease.json; do
        [[ -f "$artifact" ]] || continue
        cp -- "$artifact" "$DEBUG_ARTIFACT_DIR/${artifact##*/}" || return 1
        chmod 0600 "$DEBUG_ARTIFACT_DIR/${artifact##*/}" || return 1
        copied=true
    done
    if [[ "$copied" == true ]]; then
        info "DHCP debug artifacts saved in ${DEBUG_ARTIFACT_DIR}"
    elif [[ "$DEBUG_ARTIFACT_DIR_GENERATED" == true ]]; then
        rmdir "$DEBUG_ARTIFACT_DIR" 2>/dev/null || true
        DEBUG_ARTIFACT_DIR=""
    fi
}

on_exit() {
    local status=$?
    local cleanup_status=0
    local provider_cleanup_allowed=true
    trap - EXIT
    set +e
    if [[ "$VLAN_E2E_DEBUG" == true ]] && ! export_dhcp_debug_artifacts; then
        printf 'ERROR: could not preserve the requested DHCP debug artifacts\n' >&2
        cleanup_status=1
    fi
    if declare -F cleanup_dhcp_clients_and_ports >/dev/null; then
        if ! cleanup_dhcp_clients_and_ports; then
            printf 'ERROR: DHCP client or access-port cleanup is incomplete\n' >&2
            cleanup_status=1
            provider_cleanup_allowed=false
            PRESERVE_E2E_RECOVERY_ARTIFACTS=true
        fi
    fi
    if [[ "$provider_cleanup_allowed" == true ]]; then
        cleanup_created_virtual_networks "$status"
        if [[ "$?" != 0 ]]; then
            cleanup_status=1
        fi
    else
        printf 'ERROR: preserving test-owned Subnets, VirtualNetworks, AAP inventory, and provider access for recovery because client-link cleanup failed\n' >&2
    fi
    if [[ "$status" == 0 && "$cleanup_status" != 0 ]]; then
        status=1
    fi
    if [[ "$PRESERVE_E2E_RECOVERY_ARTIFACTS" == true ]]; then
        printf 'Recovery artifacts and provider credentials are preserved in %s\n' "$TEMP_DIR" >&2
    else
        if [[ "$GENERATED_CLI_CONFIG" == true && -n "$CLI_CONFIG_DIR" ]]; then
            rm -rf -- "$CLI_CONFIG_DIR"
        fi
        if [[ "$GENERATED_CLI_BIN" == true && -n "$CLI_BIN" ]]; then
            rm -f -- "$CLI_BIN"
        fi
        [[ -z "$CLI_CA_FILE" ]] || rm -f -- "$CLI_CA_FILE"
        [[ -z "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
    fi
    set -e
    exit "$status"
}
trap on_exit EXIT

for tool in cluster-tool virsh oc helm go jq python3 awk sed grep sort sleep make ssh-keygen base64 grpcurl docker sudo ssh; do
    require_cmd "$tool"
done
require_cmd "$CONTAINER_TOOL"
require_cmd "$CONTAINERLAB"
if [[ "$VLAN_E2E_DEBUG" == true ]]; then
    require_cmd tcpdump
    require_cmd nsenter
fi
[[ -n "$CURRENT_BRANCH" ]] || die "Could not determine the current Git branch"
[[ "$OSAC_INSTALL_MODE" == auto || "$OSAC_INSTALL_MODE" == install || "$OSAC_INSTALL_MODE" == upgrade ]] \
    || die "OSAC_INSTALL_MODE must be auto, install, or upgrade"
[[ "$VLAN_E2E_DEBUG" == true || "$VLAN_E2E_DEBUG" == false ]] \
    || die "VLAN_E2E_DEBUG must be true or false"
if [[ "$VLAN_E2E_DEBUG" == true && -n "$VLAN_E2E_ARTIFACT_DIR" ]]; then
    [[ "$VLAN_E2E_ARTIFACT_DIR" =~ ^/[A-Za-z0-9_./-]+$ ]] \
        || die "VLAN_E2E_ARTIFACT_DIR must be an absolute path with safe path characters"
fi
[[ "$AAP_IMAGE" =~ ^quay\.io/[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+$ ]] \
    || die "AAP_IMAGE must be a quay.io image reference with a tag"
[[ "$OPERATOR_IMAGE" =~ ^quay\.io/[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+$ ]] \
    || die "OPERATOR_IMAGE must be a quay.io image reference with a tag"
[[ "$REUSE_PREBUILT_OSAC_IMAGES" == auto || "$REUSE_PREBUILT_OSAC_IMAGES" == true \
    || "$REUSE_PREBUILT_OSAC_IMAGES" == false ]] \
    || die "REUSE_PREBUILT_OSAC_IMAGES must be auto, true, or false"
[[ "$AAP_PROJECT_GIT_URI" =~ ^https://[A-Za-z0-9._/-]+$ ]] \
    || die "AAP_PROJECT_GIT_URI must be an HTTPS Git URL"
[[ "$AAP_PROJECT_GIT_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] \
    || die "AAP_PROJECT_GIT_BRANCH contains unsupported characters"
[[ "$AAP_PROJECT_EXPECTED_REVISION" =~ ^[0-9a-f]{40}$ ]] \
    || die "AAP_PROJECT_EXPECTED_REVISION must be a full lowercase Git commit SHA"
[[ "$AGENTLESS_NET_STATE_FILE" =~ ^/[A-Za-z0-9_./-]+$ ]] \
    || die "AGENTLESS_NET_STATE_FILE must be an absolute path with safe path characters"
[[ "$VIRTUAL_NETWORK_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || die "VIRTUAL_NETWORK_NAME must be a DNS label"
[[ "$PEER_VIRTUAL_NETWORK_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || die "PEER_VIRTUAL_NETWORK_NAME must be a DNS label"
[[ "$SUBNET_ONE_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || die "SUBNET_ONE_NAME must be a DNS label"
[[ "$SUBNET_TWO_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || die "SUBNET_TWO_NAME must be a DNS label"
[[ "$SUBNET_THREE_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || die "SUBNET_THREE_NAME must be a DNS label"
[[ "$SUBNET_ONE_NAME" != "$SUBNET_TWO_NAME" && "$SUBNET_ONE_NAME" != "$SUBNET_THREE_NAME" \
    && "$SUBNET_TWO_NAME" != "$SUBNET_THREE_NAME" ]] \
    || die "All test Subnet names must be different"
[[ "$OSAC_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || die "OSAC_NAMESPACE must be a DNS label"
[[ "$OSAC_TENANT" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || die "OSAC_TENANT must be a DNS label"
python3 - "$VIRTUAL_NETWORK_IPV4_CIDR" "$SUBNET_ONE_IPV4_CIDR" \
    "$SUBNET_TWO_IPV4_CIDR" "$SUBNET_THREE_IPV4_CIDR" <<'PY'
import ipaddress
import sys

parent = ipaddress.ip_network(sys.argv[1], strict=True)
if not isinstance(parent, ipaddress.IPv4Network) or str(parent) != sys.argv[1]:
    raise SystemExit("VIRTUAL_NETWORK_IPV4_CIDR must be a canonical IPv4 CIDR")
children = []
for label, value in zip(("SUBNET_ONE_IPV4_CIDR", "SUBNET_TWO_IPV4_CIDR", "SUBNET_THREE_IPV4_CIDR"), sys.argv[2:]):
    if not value:
        continue
    network = ipaddress.ip_network(value, strict=True)
    if not isinstance(network, ipaddress.IPv4Network) or str(network) != value or network.prefixlen > 30:
        raise SystemExit(f"{label} must be a canonical IPv4 CIDR with prefix length /30 or shorter")
    if not network.subnet_of(parent):
        raise SystemExit(f"{label} must be contained by VIRTUAL_NETWORK_IPV4_CIDR")
    children.append((label, network))
if len(children) == 2 and children[0][1].overlaps(children[1][1]):
    raise SystemExit("SUBNET_ONE_IPV4_CIDR and SUBNET_TWO_IPV4_CIDR must not overlap")
PY
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/osac-5530-vlan-e2e.XXXXXX")"
BASELINE_STATE_FILE="${TEMP_DIR}/baseline-state.json"
CURRENT_STATE_FILE="${TEMP_DIR}/current-state.json"
SWITCH_MANIFEST_FILE="${TEMP_DIR}/switches.json"
if [[ "$VLAN_E2E_DEBUG" == true ]]; then
    if [[ -z "$VLAN_E2E_ARTIFACT_DIR" ]]; then
        DEBUG_ARTIFACT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/osac-5530-dhcp-debug.XXXXXX")"
        DEBUG_ARTIFACT_DIR_GENERATED=true
    else
        [[ ! -e "$VLAN_E2E_ARTIFACT_DIR" && ! -L "$VLAN_E2E_ARTIFACT_DIR" ]] \
            || die "VLAN_E2E_ARTIFACT_DIR already exists; refusing to overwrite it"
        mkdir -m 0700 -- "$VLAN_E2E_ARTIFACT_DIR"
        DEBUG_ARTIFACT_DIR="$VLAN_E2E_ARTIFACT_DIR"
    fi
    chmod 0700 "$DEBUG_ARTIFACT_DIR"
    info "Opt-in DHCP traces and logs will be saved to ${DEBUG_ARTIFACT_DIR}"
fi
if [[ -z "$CLI_BIN" ]]; then
    CLI_BIN="$(mktemp "${TMPDIR:-/tmp}/osac-5530-cli.XXXXXX")"
    GENERATED_CLI_BIN=true
fi
if [[ -z "$CLI_CONFIG_DIR" ]]; then
    CLI_CONFIG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/osac-5530-cli-config.XXXXXX")"
    GENERATED_CLI_CONFIG=true
fi

# Phase 1: boot or reuse the SNO with cluster-tool.
step "STEP 1 OF 4: Deploying or reusing the SNO cluster"
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

# Phase 2: reuse source-matched images, or build and push them if missing.
# The Ansible provider changes ship in the AAP execution environment. The
# VirtualNetwork and Subnet controller changes ship in the OSAC operator image. The
# Fulfillment CLI is compiled later as a local binary; no service image changed.
step "STEP 2 OF 4: Preparing custom AAP and operator images"
REUSE_IMAGES=false
if [[ "$REUSE_PREBUILT_OSAC_IMAGES" == true ]]; then
    REUSE_IMAGES=true
elif [[ "$REUSE_PREBUILT_OSAC_IMAGES" == auto ]] \
    && "$CONTAINER_TOOL" image inspect "$AAP_IMAGE" >/dev/null 2>&1 \
    && "$CONTAINER_TOOL" image inspect "$OPERATOR_IMAGE" >/dev/null 2>&1; then
    REUSE_IMAGES=true
elif [[ "$REUSE_PREBUILT_OSAC_IMAGES" == auto ]] \
    && "$CONTAINER_TOOL" pull "$AAP_IMAGE" >/dev/null 2>&1 \
    && "$CONTAINER_TOOL" pull "$OPERATOR_IMAGE" >/dev/null 2>&1; then
    REUSE_IMAGES=true
fi
if [[ "$REUSE_IMAGES" == true ]]; then
    info "Reusing prebuilt images for source revision ${IMAGE_SOURCE_SHORT}: ${AAP_IMAGE}, ${OPERATOR_IMAGE}."
    "$CONTAINER_TOOL" image inspect "$AAP_IMAGE" >/dev/null 2>&1 \
        || die "Prebuilt AAP image is not available locally: ${AAP_IMAGE}"
    "$CONTAINER_TOOL" image inspect "$OPERATOR_IMAGE" >/dev/null 2>&1 \
        || die "Prebuilt OSAC operator image is not available locally: ${OPERATOR_IMAGE}"
else
    info "Building and pushing images for source revision ${IMAGE_SOURCE_SHORT}."
    if ! "$CONTAINER_TOOL" login --get-login quay.io >/dev/null 2>&1; then
        die "No saved ${CONTAINER_TOOL} login for quay.io; authenticate before building the custom images"
    fi
    AAP_BUILD_LOG="${TEMP_DIR}/aap-image-build.log"
    OPERATOR_BUILD_LOG="${TEMP_DIR}/operator-image-build.log"
    info "Building AAP ${AAP_IMAGE} and OSAC operator ${OPERATOR_IMAGE} images in parallel..."
    make -C "$AAP_DIR" execution-environment-build \
        "IMG=${AAP_IMAGE}" "CONTAINER_TOOL=${CONTAINER_TOOL}" >"$AAP_BUILD_LOG" 2>&1 &
    AAP_BUILD_PID=$!
    make -C "${REPO_ROOT}/osac-operator" image-build \
        "IMG=${OPERATOR_IMAGE}" "CONTAINER_TOOL=${CONTAINER_TOOL}" >"$OPERATOR_BUILD_LOG" 2>&1 &
    OPERATOR_BUILD_PID=$!
    AAP_BUILD_STATUS=0
    OPERATOR_BUILD_STATUS=0
    wait "$AAP_BUILD_PID" || AAP_BUILD_STATUS=$?
    wait "$OPERATOR_BUILD_PID" || OPERATOR_BUILD_STATUS=$?
    if [[ "$AAP_BUILD_STATUS" != 0 || "$OPERATOR_BUILD_STATUS" != 0 ]]; then
        if [[ "$AAP_BUILD_STATUS" != 0 ]]; then
            tail -n 80 "$AAP_BUILD_LOG" >&2
        fi
        if [[ "$OPERATOR_BUILD_STATUS" != 0 ]]; then
            tail -n 80 "$OPERATOR_BUILD_LOG" >&2
        fi
        die "Image build failed (AAP status ${AAP_BUILD_STATUS}, operator status ${OPERATOR_BUILD_STATUS})"
    fi
    info "Both images built successfully; pushing them to Quay..."
    make -C "$AAP_DIR" execution-environment-push \
        "IMG=${AAP_IMAGE}" "CONTAINER_TOOL=${CONTAINER_TOOL}"
    make -C "${REPO_ROOT}/osac-operator" image-push \
        "IMG=${OPERATOR_IMAGE}" "CONTAINER_TOOL=${CONTAINER_TOOL}"
fi

# Phase 3: install or upgrade OSAC with the custom AAP and operator images.
step "STEP 3 OF 4: Deploying OSAC with the custom images"
OVERLAY_FILE="${INSTALLER_DIR}/values/agentless-net-stub.yaml"
[[ -f "$OVERLAY_FILE" ]] || die "AgentlessNet VirtualNetwork/Subnet overlay is missing: ${OVERLAY_FILE}"
CLUSTER_DOMAIN="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
[[ -n "$CLUSTER_DOMAIN" ]] || die "Could not read the OpenShift cluster domain"
OIDC_ISSUER_URL="https://keycloak-keycloak.${CLUSTER_DOMAIN}/realms/osac"
info "Refreshing local umbrella-chart dependencies from this checkout..."
helm dependency build "${INSTALLER_DIR}/charts/osac"
# This smoke invokes the networking AAP jobs directly; catalog template
# publication is unrelated and its hook needs a Kubernetes token mount.
EXTRA_HELM_ARGS="-f ${OVERLAY_FILE} --set-string aap.configAsCode.eeImage=${AAP_IMAGE} --set-string aap.configAsCode.projectGitUri=${AAP_PROJECT_GIT_URI} --set-string aap.configAsCode.projectGitBranch=${AAP_PROJECT_GIT_BRANCH} --set-string operator.image.repository=${OPERATOR_IMAGE_REPOSITORY} --set-string operator.image.tag=${OPERATOR_IMAGE_TAG} --set aap.instanceGroups.publishTemplates.enabled=false"
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
    info "Upgrading the existing OSAC release with the custom AAP and operator images..."
    # Skip the existing config-as-code hook on upgrades: AAP rejects the
    # pre-existing cluster-fulfillment-ig Secret volume. Phase 4 syncs the
    # project and EE directly through the Controller API.
    helm upgrade osac "${INSTALLER_DIR}/charts/osac" \
        --namespace "$OSAC_NAMESPACE" \
        --reset-values \
        --values "$UPGRADE_VALUES_FILE" \
        --set aap.bootstrap.enabled=false \
        --set aap.instanceGroups.publishTemplates.enabled=false \
        --set-string "aap.configAsCode.eeImage=${AAP_IMAGE}" \
        --set-string "aap.configAsCode.projectGitUri=${AAP_PROJECT_GIT_URI}" \
        --set-string "aap.configAsCode.projectGitBranch=${AAP_PROJECT_GIT_BRANCH}" \
        --set-string "operator.image.repository=${OPERATOR_IMAGE_REPOSITORY}" \
        --set-string "operator.image.tag=${OPERATOR_IMAGE_TAG}" \
        --set-string "ui.auth.oidcIssuerURL=${OIDC_ISSUER_URL}" \
        --values "$OVERLAY_FILE" \
        --wait --timeout 40m
else
    [[ -f "$AAP_LICENSE_FILE" ]] || die "AAP license file not found: ${AAP_LICENSE_FILE}"
    info "Installing OSAC with the AgentlessNet VirtualNetwork/Subnet profile in ${OSAC_NAMESPACE}..."
    make -C "$INSTALLER_DIR" install \
        PLATFORM=openshift \
        "DOMAIN=${CLUSTER_DOMAIN}" \
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

# Phase 4: run the VirtualNetwork and Subnet VLAN/DHCP E2E.
# Phase 4a prepares AAP and the workspace's isolated network node/inventory.
step "STEP 4 OF 4: Running the VirtualNetwork and Subnet E2E test"
sync_aap_project_revision
configure_aap_execution_environment
resolve_mgmt_network
write_provider_inventory
ensure_containerlab_net_node
prepare_containerlab_net_node
ensure_containerlab_switches
prepare_containerlab_switches
prepare_containerlab_dhcp_supervisor
prepare_aap_networking_instance_group

# Phase 4b builds a local CLI client and exercises the VN and Subnet lifecycles.
# Coverage includes overlapping VN creates, VN and Subnet retries, internal VLAN
# discovery, real DHCP clients, gateway/L2 traffic, service restart, /30 scope,
# peer-preserving deletion, and restoration of the test access ports.
# The CLI is a local binary, not another container image.
info "Preparing a temporary CLI CA bundle and building the CLI from this checkout..."
CLI_CA_FILE="$(mktemp "${TMPDIR:-/tmp}/osac-5530-ca.XXXXXX")"
oc get configmap ca-bundle -n "$OSAC_NAMESPACE" \
    -o jsonpath='{.data.bundle\.pem}' > "$CLI_CA_FILE"
[[ -s "$CLI_CA_FILE" ]] || die "OSAC CA bundle is empty"
(
    cd "${REPO_ROOT}/fulfillment-service"
    go build -o "$CLI_BIN" ./cmd/osac
)

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

client_link() {
    case "$1" in
        a1)
            CLIENT_SWITCH="${CONTAINERLAB_PREFIX}-leaf-1"
            CLIENT_SWITCH_PORT=swp2
            CLIENT_HOST_PARENT=leaf1-swp2
            ;;
        a2)
            CLIENT_SWITCH="${CONTAINERLAB_PREFIX}-leaf-2"
            CLIENT_SWITCH_PORT=swp2
            CLIENT_HOST_PARENT=leaf2-swp2
            ;;
        b1)
            CLIENT_SWITCH="${CONTAINERLAB_PREFIX}-leaf-2"
            CLIENT_SWITCH_PORT=swp3
            CLIENT_HOST_PARENT=leaf2-swp3
            ;;
        *) die "Unknown AgentlessNet DHCP client fixture: $1" ;;
    esac
}

client_container() {
    printf '%s-%s' "$DHCP_CLIENT_PREFIX" "$1"
}

client_macvlan_name() {
    local suffix="${DHCP_CLIENT_PREFIX: -8}"
    printf 'm%s-%s' "$suffix" "$1"
}

write_agentless_e2e_helpers() {
    DHCP_CLIENT_HELPER="$TEMP_DIR/dhcp_clients.py"
    DHCP_CLIENT_HOOK="$TEMP_DIR/udhcpc-hook.sh"
    cat >"$DHCP_CLIENT_HELPER" <<'PY'
#!/usr/bin/env python3
"""Small assertions shared by the AgentlessNet lab E2E runner."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path
from typing import TypeVar, cast

_JSON = TypeVar("_JSON")


def _load_runtime_vlan_parser() -> Callable[[str, str], set[int]]:
    repo_root = Path(os.environ["OSAC_REPO_ROOT"]).resolve()
    sys.path.insert(0, str(repo_root / "osac-aap" / "collections"))
    from ansible_collections.osac.templates.plugins.module_utils.agentless_net_subnet import (
        parse_switch_vlan_exclusions,
    )

    return parse_switch_vlan_exclusions


def _read_json(path: str) -> _JSON:
    try:
        return cast(_JSON, json.loads(Path(path).read_text()))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"could not read JSON file {path}: {error}") from error


def snapshot_vlan_ids(args: argparse.Namespace) -> None:
    switches = _read_json(args.input)
    if not isinstance(switches, list) or not switches:
        raise ValueError("switch snapshot must contain at least one switch")
    parser = _load_runtime_vlan_parser()
    seen: set[str] = set()
    excluded: set[int] = set()
    for switch in switches:
        if not isinstance(switch, dict) or not isinstance(switch.get("name"), str):
            raise ValueError("switch snapshot entry is malformed")
        if switch["name"] in seen:
            raise ValueError(f"switch snapshot repeats {switch['name']}")
        seen.add(switch["name"])
        excluded.update(parser(switch.get("bridge_vlan_output"), switch.get("reserved_vlan_output")))
    Path(args.output).write_text(
        json.dumps({"switches": switches, "excluded_vlan_ids": sorted(excluded)}, sort_keys=True) + "\n"
    )


def assert_allocations(args: argparse.Namespace) -> None:
    snapshot = _read_json(args.snapshot)
    excluded = set(snapshot.get("excluded_vlan_ids", []))
    allocated = [int(value) for value in args.vlan]
    if not allocated or any(not 1 <= vlan <= 4094 for vlan in allocated):
        raise ValueError("allocated VLAN IDs must be in the physical range 1-4094")
    conflicts = sorted(set(allocated) & excluded)
    if conflicts:
        raise ValueError(f"allocated VLAN IDs overlap baseline or reserved switch state: {conflicts}")


def assert_client_leases(args: argparse.Namespace) -> None:
    expected = _read_json(args.expected)
    clients = expected.get("clients")
    if not isinstance(clients, list) or not clients:
        raise ValueError("expected client list is empty")
    lease_files = {}
    for item in args.lease:
        if "=" not in item:
            raise ValueError("client lease argument must be name=path")
        name, path = item.split("=", 1)
        lease_files[name] = _read_json(path)

    server_leases = {}
    for line in Path(args.dnsmasq_leases).read_text().splitlines():
        fields = line.split()
        if len(fields) >= 3:
            server_leases.setdefault(fields[1].lower(), []).append(fields[2])

    seen_addresses: set[str] = set()
    for client in clients:
        name = client["name"]
        expected_mac = client["mac"].lower()
        if name not in lease_files:
            raise ValueError(f"no DHCP hook record was captured for client {name}")
        lease = lease_files[name]
        if lease.get("mac", "").lower() != expected_mac:
            raise ValueError(f"client {name} lease MAC does not match its interface MAC")
        try:
            network = ipaddress.ip_network(client["subnet"]["ipv4_cidr"], strict=True)
            address = ipaddress.IPv4Address(lease["address"])
            expected_gateway = ipaddress.IPv4Address(client["subnet"]["gateway_ipv4"])
            expected_mask = str(network.netmask)
            start = ipaddress.IPv4Address(client["subnet"]["dhcp_range_start"])
            end = ipaddress.IPv4Address(client["subnet"]["dhcp_range_end"])
            gateway = ipaddress.IPv4Address(lease["router"])
        except (KeyError, TypeError, ValueError) as error:
            raise ValueError(f"client {name} lease or saved Subnet state is malformed") from error
        if not isinstance(network, ipaddress.IPv4Network) or not isinstance(address, ipaddress.IPv4Address):
            raise ValueError(f"client {name} did not receive IPv4")
        if address not in network or not start <= address <= end:
            raise ValueError(f"client {name} address {address} is outside its saved DHCP range")
        if address in {network.network_address, network.broadcast_address, expected_gateway}:
            raise ValueError(f"client {name} address {address} conflicts with Subnet reservations")
        vip_cidr = client["subnet"].get("vip_cidr", "")
        if vip_cidr and address in ipaddress.ip_network(vip_cidr, strict=True):
            raise ValueError(f"client {name} address {address} overlaps the saved VIP reservation")
        if lease.get("netmask") != expected_mask or gateway != expected_gateway:
            raise ValueError(f"client {name} DHCP mask or router differs from its saved Subnet")
        if str(address) in seen_addresses:
            raise ValueError(f"DHCP assigned duplicate address {address}")
        seen_addresses.add(str(address))
        if str(address) not in server_leases.get(expected_mac, []):
            raise ValueError(f"dnsmasq has no matching lease for {name} ({expected_mac}, {address})")


def assert_l2_delivery(args: argparse.Namespace) -> None:
    ping = subprocess.run(
        ["docker", "exec", args.client, "ping", "-c", "3", "-W", "2", args.target],
        text=True,
        capture_output=True,
        check=False,
    )
    if ping.returncode != 0:
        raise ValueError(f"{args.client} cannot ping {args.target}: {ping.stdout}{ping.stderr}")
    neighbors = subprocess.run(
        ["docker", "exec", args.client, "ip", "neigh", "show", "to", args.target],
        text=True,
        capture_output=True,
        check=False,
    )
    if neighbors.returncode != 0:
        raise ValueError(f"could not read {args.client} neighbor state: {neighbors.stderr}")
    pattern = re.compile(
        rf"\b{re.escape(args.target)}\b\s+dev\s+eth0\b.*\blladdr\s+{re.escape(args.mac.lower())}\b", re.I
    )
    if not pattern.search(neighbors.stdout):
        raise ValueError(f"{args.client} neighbor for {args.target} does not match MAC {args.mac}: {neighbors.stdout}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    snapshot = actions.add_parser("snapshot-vlans")
    snapshot.add_argument("--input", required=True)
    snapshot.add_argument("--output", required=True)
    snapshot.set_defaults(function=snapshot_vlan_ids)
    allocation = actions.add_parser("assert-allocations")
    allocation.add_argument("--snapshot", required=True)
    allocation.add_argument("--vlan", action="append", required=True)
    allocation.set_defaults(function=assert_allocations)
    leases = actions.add_parser("assert-client-leases")
    leases.add_argument("--expected", required=True)
    leases.add_argument("--dnsmasq-leases", required=True)
    leases.add_argument("--lease", action="append", required=True)
    leases.set_defaults(function=assert_client_leases)
    traffic = actions.add_parser("assert-l2-delivery")
    traffic.add_argument("--client", required=True)
    traffic.add_argument("--target", required=True)
    traffic.add_argument("--mac", required=True)
    traffic.set_defaults(function=assert_l2_delivery)
    args = parser.parse_args()
    try:
        args.function(args)
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
    cat >"$DHCP_CLIENT_HOOK" <<'SH'
#!/bin/sh
set -eu
umask 077

action="${1:-}"
interface="${interface:-eth0}"
case "$action" in
    deconfig)
        ip address flush dev "$interface" || true
        ip route flush dev "$interface" || true
        ;;
    bound|renew)
        : "${ip:?udhcpc did not provide an address}"
        : "${subnet:?udhcpc did not provide a netmask}"
        prefix="$(printf '%s\n' "$subnet" | awk -F. '
          NF != 4 { exit 1 }
          { bits = 0; for (i = 1; i <= 4; i++) {
              octet = $i + 0
              if (octet < 0 || octet > 255) exit 1
              while (octet > 0) { bits += octet % 2; octet = int(octet / 2) }
            }
            print bits
          }')"
        ip address flush dev "$interface"
        ip address add "$ip/$prefix" dev "$interface"
        if [ -n "${router:-}" ]; then
            gateway="${router%% *}"
            ip route replace default via "$gateway" dev "$interface"
        fi
        lease_dir=/run/osac-dhcp
        mkdir -p "$lease_dir"
        lease_file="$lease_dir/lease.json"
        generation=1
        if [ -s "$lease_file" ]; then
            previous_generation="$(sed -n 's/.*"generation":\([0-9][0-9]*\).*/\1/p' "$lease_file")"
            case "$previous_generation" in
                ''|*[!0-9]*) ;;
                *) generation=$((previous_generation + 1)) ;;
            esac
        fi
        temporary="$lease_dir/lease.json.tmp"
        printf '{"address":"%s","netmask":"%s","router":"%s","mac":"%s","updated_at":"%s","generation":%s}\n' \
            "$ip" "$subnet" "${router:-}" "${OSAC_CLIENT_MAC:-$(cat "/sys/class/net/$interface/address")}" \
            "$(date +%s)" "$generation" >"$temporary"
        mv "$temporary" "$lease_file"
        ;;
    *)
        exit 0
        ;;
esac
SH
    chmod 0600 "$DHCP_CLIENT_HELPER"
    chmod 0700 "$DHCP_CLIENT_HOOK"
}

snapshot_client_access_ports() {
    local raw_file="$TEMP_DIR/access-ports.jsonl" client switch port parent
    local pending_diff config_state
    local -A preflighted_switches=()
    ACCESS_PORTS_SNAPSHOT_FILE="$TEMP_DIR/access-ports-snapshot.json"
    : >"$raw_file"
    for client in a1 a2 b1; do
        client_link "$client"
        switch="$CLIENT_SWITCH" port="$CLIENT_SWITCH_PORT" parent="$CLIENT_HOST_PARENT"
        jq -e --arg switch "$switch" --arg port "$port" \
            'all(.switches[] | select(.name == $switch).trunk_ports[]; . != $port)' \
            "$SWITCH_MANIFEST_FILE" >/dev/null \
            || die "Client fixture port ${switch}/${port} overlaps a declared AgentlessNet trunk"
        if [[ "${preflighted_switches[$switch]:-false}" != true ]]; then
            pending_diff="$(docker exec "$switch" nv config diff --color off)" \
                || die "Could not inspect pending NVUE changes on ${switch}"
            [[ -z "$pending_diff" ]] \
                || die "Switch ${switch} has pending NVUE changes; refusing to apply fixture port configuration"
            preflighted_switches["$switch"]=true
        fi
        sudo ip link show dev "$parent" >/dev/null 2>&1 \
            || die "Containerlab-owned parent link ${parent} is missing"
        local bridge_state fdb_state link_state nvue_state nvue_error
        link_state="$(docker exec "$switch" ip -j link show dev "$port" \
            | jq -ce '.[0] | {master:(.master // null),admin_up:(.flags | index("UP") != null)}')" \
            || die "Could not snapshot link state on ${switch}/${port}"
        [[ "$(jq -r '.master // ""' <<<"$link_state")" == "" \
            || "$(jq -r '.master // ""' <<<"$link_state")" == br_default ]] \
            || die "Client fixture port ${switch}/${port} is attached to an unrelated bridge; preserving it"
        bridge_state="$(docker exec "$switch" bridge -j vlan show dev "$port")" \
            || die "Could not snapshot VLAN memberships on ${switch}/${port}"
        [[ "$bridge_state" == "[]" ]] \
            || die "Client fixture port ${switch}/${port} already has VLAN membership; preserving its existing configuration"
        config_state="$(docker exec "$switch" nv config show --output json \
            | jq -c --arg port "$port" '.[0].set.interface[$port] // null')" \
            || die "Could not snapshot the applied NVUE configuration on ${switch}/${port}"
        if [[ "$config_state" != null ]] && ! jq -e \
            '. == {"bridge":{"domain":{"br_default":{}}}}' \
            <<<"$config_state" >/dev/null; then
            die "Client fixture port ${switch}/${port} already has NVUE configuration; preserving it"
        fi
        fdb_state="$(docker exec "$switch" bridge fdb show dev "$port")" \
            || die "Could not snapshot forwarding entries on ${switch}/${port}"
        if grep -Ev 'self permanent$' <<<"$fdb_state" | grep -q .; then
            die "Client fixture port ${switch}/${port} has learned MAC entries; refusing to disrupt active use"
        fi
        nvue_error="$TEMP_DIR/${client}-nvue.err"
        if nvue_state="$(docker exec "$switch" nv show interface "$port" bridge domain br_default --output json 2>"$nvue_error")"; then
            [[ -z "$nvue_state" ]] \
                || die "Client fixture port ${switch}/${port} already has NVUE bridge configuration; preserving it"
        elif ! grep -q '404 NOT FOUND' "$nvue_error"; then
            cat "$nvue_error" >&2
            die "Could not verify the baseline NVUE configuration on ${switch}/${port}"
        else
            nvue_state=""
        fi
        printf '%s\n' "$(jq -nc --arg client "$client" --arg switch "$switch" \
            --arg port "$port" --arg parent "$parent" --argjson link "$link_state" \
            --arg nvue "$nvue_state" \
            --argjson config "$config_state" --argjson bridge "$bridge_state" \
            --arg fdb "$fdb_state" \
            '{client:$client,switch:$switch,port:$port,parent:$parent,link:$link,nvue:$nvue,config:$config,bridge:$bridge,fdb:$fdb}')" \
            >>"$raw_file"
    done
    jq -s . "$raw_file" >"$ACCESS_PORTS_SNAPSHOT_FILE"
    chmod 0600 "$ACCESS_PORTS_SNAPSHOT_FILE"
    info "Snapshotted the three idle access links; their switch ports are outside all declared trunks."
}

configure_client_access_port() {
    local client="$1" vlan_id="$2" key bridge_state apply_log
    client_link "$client"
    key="${CLIENT_SWITCH}/${CLIENT_SWITCH_PORT}"
    if jq -e --arg switch "$CLIENT_SWITCH" --arg port "$CLIENT_SWITCH_PORT" \
        'any(.switches[] | select(.name == $switch).trunk_ports[]; . == $port)' \
        "$SWITCH_MANIFEST_FILE" >/dev/null; then
        die "Refusing to configure client access port ${key} because it is a declared trunk"
    fi
    if [[ "${CLIENT_PORT_CONFIGURED[$key]:-false}" != true ]]; then
        CLIENT_PORT_CONFIGURED["$key"]=true
    fi
    CLIENT_PORT_VLAN["$key"]="$vlan_id"
    docker exec "$CLIENT_SWITCH" nv set interface "$CLIENT_SWITCH_PORT" bridge domain br_default
    docker exec "$CLIENT_SWITCH" nv set interface "$CLIENT_SWITCH_PORT" \
        bridge domain br_default access "$vlan_id"
    apply_log="$TEMP_DIR/${client}-nvue-apply.log"
    if ! docker exec "$CLIENT_SWITCH" nv config apply --assume-yes >"$apply_log" 2>&1; then
        cat "$apply_log" >&2
        die "NVUE could not apply fixture access VLAN ${vlan_id} to ${key}"
    fi
    bridge_state="$(docker exec "$CLIENT_SWITCH" bridge -j vlan show dev "$CLIENT_SWITCH_PORT")"
    jq -e --argjson vlan "$vlan_id" '
      ([.[] | .vlans[]?.vlan] | unique) == [$vlan]
      and any(.[]; any(.vlans[]?; .vlan == $vlan and (.flags | index("PVID") != null)))' \
      <<<"$bridge_state" >/dev/null \
        || die "Fixture access port ${key} did not converge to VLAN ${vlan_id}"
    printf 'Client %s access port %s -> VLAN %s\n' "$client" "$key" "$vlan_id"
}

restore_client_access_port() {
    local client="$1" key vlan bridge_state dynamic_fdb baseline_bridge baseline_fdb baseline_nvue
    local link_state baseline_link current_link_state nvue_state nvue_error baseline_config current_config apply_log
    local current_master baseline_admin_up client_mac client_mac_file port_mac
    client_link "$client"
    key="${CLIENT_SWITCH}/${CLIENT_SWITCH_PORT}"
    [[ "${CLIENT_PORT_CONFIGURED[$key]:-false}" == true ]] || return 0
    [[ -s "$ACCESS_PORTS_SNAPSHOT_FILE" ]] \
        || { printf 'ERROR: access-port snapshot is missing during restoration\n' >&2; return 1; }
    baseline_bridge="$(jq -c --arg client "$client" \
        '.[] | select(.client == $client) | .bridge' "$ACCESS_PORTS_SNAPSHOT_FILE")"
    baseline_fdb="$(jq -r --arg client "$client" \
        '.[] | select(.client == $client) | .fdb' "$ACCESS_PORTS_SNAPSHOT_FILE")"
    baseline_nvue="$(jq -r --arg client "$client" \
        '.[] | select(.client == $client) | .nvue' "$ACCESS_PORTS_SNAPSHOT_FILE")"
    baseline_config="$(jq -c --arg client "$client" \
        '.[] | select(.client == $client) | .config' "$ACCESS_PORTS_SNAPSHOT_FILE")"
    baseline_link="$(jq -c --arg client "$client" \
        '.[] | select(.client == $client) | .link' "$ACCESS_PORTS_SNAPSHOT_FILE")"
    [[ -n "$baseline_bridge" && "$baseline_bridge" == "[]" \
        && ("$baseline_config" == null || "$baseline_config" == '{"bridge":{"domain":{"br_default":{}}}}') \
        && -n "$baseline_link" && -z "$baseline_nvue" ]] \
        || { printf 'ERROR: access-port snapshot for %s is invalid; preserving current state\n' "$key" >&2; return 1; }
    vlan="${CLIENT_PORT_VLAN[$key]:-}"
    [[ "$vlan" =~ ^[0-9]+$ ]] \
        || { printf 'ERROR: fixture VLAN for %s is invalid; preserving current state\n' "$key" >&2; return 1; }
    bridge_state="$(docker exec "$CLIENT_SWITCH" bridge -j vlan show dev "$CLIENT_SWITCH_PORT")" \
        || { printf 'ERROR: could not inspect temporary access port %s before restoration\n' "$key" >&2; return 1; }
    link_state="$(docker exec "$CLIENT_SWITCH" ip -j link show dev "$CLIENT_SWITCH_PORT" \
        | jq -ce '.[0] | {master:(.master // null),admin_up:(.flags | index("UP") != null),mac:.address}')" \
        || { printf 'ERROR: could not inspect link state on %s before restoration\n' "$key" >&2; return 1; }
    baseline_admin_up="$(jq -r '.admin_up' <<<"$baseline_link")"
    current_master="$(jq -r '.master // ""' <<<"$link_state")"
    port_mac="$(jq -r '.mac' <<<"$link_state")"
    client_mac_file="$TEMP_DIR/client-${client}.mac"
    [[ -s "$client_mac_file" ]] \
        || { printf 'ERROR: test client MAC is missing for %s; preserving its port\n' "$key" >&2; return 1; }
    client_mac="$(<"$client_mac_file")"
    current_config="$(docker exec "$CLIENT_SWITCH" nv config show --output json \
        | jq -c --arg port "$CLIENT_SWITCH_PORT" '.[0].set.interface[$port] // null')" \
        || { printf 'ERROR: could not inspect NVUE configuration on %s before restoration\n' "$key" >&2; return 1; }
    current_link_state="$(jq -c 'del(.mac)' <<<"$link_state")"
    if [[ "$current_config" == "$baseline_config" \
        && "$(jq -c . <<<"$bridge_state")" == "$baseline_bridge" \
        && "$current_link_state" == "$baseline_link" ]]; then
        nvue_error="$TEMP_DIR/${client}-nvue-restore.err"
        if nvue_state="$(docker exec "$CLIENT_SWITCH" nv show interface "$CLIENT_SWITCH_PORT" \
            bridge domain br_default --output json 2>"$nvue_error")"; then
            [[ "$nvue_state" == "$baseline_nvue" ]] \
                || { printf 'ERROR: access port %s NVUE state differs from its saved baseline\n' "$key" >&2; return 1; }
        elif [[ -n "$baseline_nvue" ]] || ! grep -q '404 NOT FOUND' "$nvue_error"; then
            printf 'ERROR: could not verify the original NVUE state of %s\n' "$key" >&2
            return 1
        fi
        for ((attempt = 1; attempt <= 30; attempt++)); do
            dynamic_fdb="$(docker exec "$CLIENT_SWITCH" bridge fdb show dev "$CLIENT_SWITCH_PORT")" \
                || return 1
            if [[ "$(LC_ALL=C sort <<<"$dynamic_fdb")" == "$(LC_ALL=C sort <<<"$baseline_fdb")" ]]; then
                CLIENT_PORT_CONFIGURED["$key"]=false
                return 0
            fi
            sleep 1
        done
        printf 'ERROR: access port %s reached its link/config baseline but its FDB did not settle\n' "$key" >&2
        return 1
    fi
    jq -e --argjson vlan "$vlan" '
      type == "object"
      and ((keys - ["bridge", "type"]) | length) == 0
      and ((has("type") | not) or .type == "swp")
      and .bridge == {domain:{br_default:{access:$vlan}}}
    ' <<<"$current_config" >/dev/null \
        || { printf 'ERROR: NVUE configuration on %s is not the exact test fixture; preserving it\n' "$key" >&2; return 1; }
    jq -e --argjson vlan "$vlan" '
      ([.[] | .vlans[]?.vlan] | unique) == [$vlan]
      and any(.[]; any(.vlans[]?; .vlan == $vlan and (.flags | index("PVID") != null)))' \
      <<<"$bridge_state" >/dev/null \
        || { printf 'ERROR: VLAN state on %s changed unexpectedly; preserving it\n' "$key" >&2; return 1; }
    current_master="$(jq -r '.master // ""' <<<"$link_state")"
    if [[ "$current_master" != br_default ]]; then
        printf 'ERROR: bridge master on %s is not the test fixture bridge; preserving it\n' "$key" >&2
        return 1
    fi
    dynamic_fdb="$(docker exec "$CLIENT_SWITCH" bridge fdb show dev "$CLIENT_SWITCH_PORT")" \
        || { printf 'ERROR: could not inspect forwarding entries on %s before restoration\n' "$key" >&2; return 1; }
    if ! awk -v client_mac="$client_mac" -v port_mac="$port_mac" -v vlan="$vlan" '
      /self permanent$/ { next }
      $1 == client_mac && $2 == "vlan" && $3 == vlan && $4 == "master" \
        && $5 == "br_default" && NF == 5 { next }
      $1 == port_mac && (($2 == "master" && $3 == "br_default" && $4 == "permanent" && NF == 4) \
        || ($2 == "vlan" && $3 ~ /^[0-9]+$/ && $4 == "master" \
            && $5 == "br_default" && $6 == "permanent" && NF == 6)) { next }
      { unexpected = 1 }
      END { exit unexpected }
    ' <<<"$dynamic_fdb"; then
        printf 'ERROR: unknown forwarding entries remain on %s; preserving it\n' "$key" >&2
        return 1
    fi
    if [[ "$baseline_config" == null ]]; then
        docker exec "$CLIENT_SWITCH" nv unset interface "$CLIENT_SWITCH_PORT" \
            || { printf 'ERROR: could not remove the test NVUE access setting from %s\n' "$key" >&2; return 1; }
    else
        docker exec "$CLIENT_SWITCH" nv unset interface "$CLIENT_SWITCH_PORT" \
            bridge domain br_default access \
            || { printf 'ERROR: could not remove the test NVUE access setting from %s\n' "$key" >&2; return 1; }
    fi
    apply_log="$TEMP_DIR/${client}-nvue-restore.log"
    if ! docker exec "$CLIENT_SWITCH" nv config apply --assume-yes >"$apply_log" 2>&1; then
        cat "$apply_log" >&2
        printf 'ERROR: NVUE could not restore the saved port configuration on %s\n' "$key" >&2
        return 1
    fi
    if [[ "$baseline_admin_up" == true ]]; then
        docker exec "$CLIENT_SWITCH" ip link set dev "$CLIENT_SWITCH_PORT" up || return 1
    else
        docker exec "$CLIENT_SWITCH" ip link set dev "$CLIENT_SWITCH_PORT" down || return 1
    fi
    bridge_state="$(docker exec "$CLIENT_SWITCH" bridge -j vlan show dev "$CLIENT_SWITCH_PORT")" \
        || return 1
    [[ "$(jq -c . <<<"$bridge_state")" == "$baseline_bridge" ]] \
        || { printf 'ERROR: access port %s did not return to its VLAN snapshot\n' "$key" >&2; return 1; }
    link_state="$(docker exec "$CLIENT_SWITCH" ip -j link show dev "$CLIENT_SWITCH_PORT" \
        | jq -ce '.[0] | {master:(.master // null),admin_up:(.flags | index("UP") != null)}')" \
        || return 1
    [[ "$link_state" == "$baseline_link" ]] \
        || { printf 'ERROR: access port %s link state differs from its snapshot\n' "$key" >&2; return 1; }
    current_config="$(docker exec "$CLIENT_SWITCH" nv config show --output json \
        | jq -c --arg port "$CLIENT_SWITCH_PORT" '.[0].set.interface[$port] // null')" \
        || return 1
    [[ "$current_config" == "$baseline_config" ]] \
        || { printf 'ERROR: access port %s NVUE configuration differs from its snapshot\n' "$key" >&2; return 1; }
    nvue_error="$TEMP_DIR/${client}-nvue-restore.err"
    if nvue_state="$(docker exec "$CLIENT_SWITCH" nv show interface "$CLIENT_SWITCH_PORT" \
        bridge domain br_default --output json 2>"$nvue_error")"; then
        [[ "$nvue_state" == "$baseline_nvue" ]] \
            || { printf 'ERROR: access port %s did not return to its NVUE snapshot\n' "$key" >&2; return 1; }
    elif [[ -n "$baseline_nvue" ]] || ! grep -q '404 NOT FOUND' "$nvue_error"; then
        printf 'ERROR: could not verify the original NVUE state of %s\n' "$key" >&2
        return 1
    fi
    local fdb_restored=false
    for ((attempt = 1; attempt <= 30; attempt++)); do
        dynamic_fdb="$(docker exec "$CLIENT_SWITCH" bridge fdb show dev "$CLIENT_SWITCH_PORT")" \
            || return 1
        if [[ "$(LC_ALL=C sort <<<"$dynamic_fdb")" == "$(LC_ALL=C sort <<<"$baseline_fdb")" ]]; then
            fdb_restored=true
            break
        fi
        sleep 1
    done
    [[ "$fdb_restored" == true ]] \
        || { printf 'ERROR: access port %s forwarding state differs from its snapshot after settling\n' "$key" >&2; return 1; }
    CLIENT_PORT_CONFIGURED["$key"]=false
}

restore_client_access_ports() {
    local client failed=false
    for client in a1 a2 b1; do
        restore_client_access_port "$client" || failed=true
    done
    [[ "$failed" == false ]]
}

create_dhcp_client_container() {
    local client="$1" container macvlan pid mac
    client_link "$client"
    container="$(client_container "$client")"
    macvlan="$(client_macvlan_name "$client")"
    docker run -d --name "$container" --network none \
        --cap-add NET_ADMIN --cap-add NET_RAW "$CLIENT_IMAGE" sleep 3600 >/dev/null
    DHCP_CLIENT_CONTAINERS+=("$container")
    sudo ip link add link "$CLIENT_HOST_PARENT" name "$macvlan" type macvlan mode bridge
    DHCP_CLIENT_HOST_LINKS+=("$macvlan")
    pid="$(docker inspect -f '{{.State.Pid}}' "$container")"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || die "Could not read network namespace PID for $container"
    sudo ip link set dev "$macvlan" netns "$pid"
    docker exec "$container" ip link set dev "$macvlan" name eth0
    docker exec "$container" ip link set dev lo up
    docker exec "$container" ip link set dev eth0 up
    docker exec "$container" mkdir -p /usr/local/sbin
    docker cp "$DHCP_CLIENT_HOOK" \
        "$container:/usr/local/sbin/osac-udhcpc-hook.sh" >/dev/null
    docker exec "$container" chmod 0700 /usr/local/sbin/osac-udhcpc-hook.sh
    mac="$(docker exec "$container" cat /sys/class/net/eth0/address)"
    [[ "$mac" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] \
        || die "Could not read the MAC address for DHCP client $client"
    printf '%s\n' "$mac" >"$TEMP_DIR/client-${client}.mac"
    info "Prepared real DHCP client $client ($container, MAC $mac) on $CLIENT_HOST_PARENT."
}

create_dhcp_client_containers() {
    local client
    docker image inspect "$CLIENT_IMAGE" >/dev/null 2>&1 || docker pull "$CLIENT_IMAGE"
    for client in a1 a2 b1; do
        create_dhcp_client_container "$client"
    done
}

recreate_dhcp_client_container() {
    local client="$1" container macvlan index
    client_link "$client"
    container="$(client_container "$client")"
    macvlan="$(client_macvlan_name "$client")"
    stop_dhcp_client "$client"
    docker rm -f "$container" >/dev/null \
        || die "Could not replace DHCP client container $container"
    for index in "${!DHCP_CLIENT_CONTAINERS[@]}"; do
        [[ "${DHCP_CLIENT_CONTAINERS[$index]}" == "$container" ]] \
            && unset 'DHCP_CLIENT_CONTAINERS[index]'
    done
    for index in "${!DHCP_CLIENT_HOST_LINKS[@]}"; do
        [[ "${DHCP_CLIENT_HOST_LINKS[$index]}" == "$macvlan" ]] \
            && unset 'DHCP_CLIENT_HOST_LINKS[index]'
    done
    rm -f "$TEMP_DIR/client-${client}.lease.json"
    if sudo ip link show dev "$macvlan" >/dev/null 2>&1; then
        sudo ip link delete dev "$macvlan"
    fi
    create_dhcp_client_container "$client"
}

dhcp_client_pid() {
    local container="$1" pid
    if pid="$(docker exec "$container" sh -c '
      for command_file in /proc/[0-9]*/comm; do
        [ -r "$command_file" ] || continue
        IFS= read -r command_name <"$command_file" || continue
        if [ "$command_name" = udhcpc ]; then
          pid="${command_file#/proc/}"
          printf "%s\n" "${pid%/comm}"
          exit 0
        fi
      done
      exit 1
    ')"; then
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
        printf '%s\n' "$pid"
    else
        return 1
    fi
}

start_dhcp_debug_capture() {
    local label="$1" namespace_ref="$2" interface="$3" filter_mode="$4" client_mac="${5:-}"
    local capture_filter='udp port 67 or udp port 68'
    local namespace_target pid_file pcap_file log_file launch_pid capture_pid
    local -a namespace_args=()
    [[ "$VLAN_E2E_DEBUG" == true ]] || return 0
    [[ "$label" =~ ^[A-Za-z0-9-]+$ && "$interface" =~ ^[A-Za-z0-9_.:-]+$ ]] \
        || die "Unsafe DHCP debug capture label or interface"
    case "$filter_mode" in
        client)
            [[ "$client_mac" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] \
                || die "Invalid client MAC for DHCP debug capture"
            capture_filter="ether host ${client_mac} or (ether broadcast and (${capture_filter}))"
            ;;
        mac)
            [[ "$client_mac" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] \
                || die "Invalid client MAC for DHCP debug capture"
            capture_filter="ether host ${client_mac}"
            ;;
        dhcp) ;;
        *) die "Invalid DHCP debug capture filter mode" ;;
    esac
    case "$namespace_ref" in
        pid:*)
            namespace_target="${namespace_ref#pid:}"
            [[ "$namespace_target" =~ ^[1-9][0-9]*$ ]] \
                || die "Invalid process ID for DHCP debug capture"
            namespace_args=(-t "$namespace_target" -n)
            ;;
        file:*)
            namespace_target="${namespace_ref#file:}"
            [[ -e "$namespace_target" ]] \
                || die "Network namespace for DHCP debug capture is missing"
            namespace_args=("--net=${namespace_target}")
            ;;
        *) die "Invalid network namespace for DHCP debug capture" ;;
    esac
    pid_file="${TEMP_DIR}/dhcp-debug-${label}.pid"
    pcap_file="${TEMP_DIR}/dhcp-debug-${label}.pcap"
    log_file="${TEMP_DIR}/dhcp-debug-${label}.tcpdump.log"
    sudo nsenter "${namespace_args[@]}" -- /bin/sh -c \
        'printf "%s\n" "$$" >"$1"; shift; exec "$@"' \
        sh "$pid_file" /usr/sbin/tcpdump -U -n -e -s 512 -c 200 \
        -i "$interface" -w - "$capture_filter" \
        >"$pcap_file" 2>"$log_file" &
    launch_pid=$!
    DEBUG_CAPTURE_LAUNCH_PIDS+=("$launch_pid")
    for ((attempt = 1; attempt <= 20; attempt++)); do
        [[ -s "$pid_file" ]] && break
        sleep 0.1
    done
    if [[ ! -s "$pid_file" ]]; then
        kill "$launch_pid" >/dev/null 2>&1 || true
        wait "$launch_pid" 2>/dev/null || true
        cat "$log_file" >&2 || true
        die "DHCP debug capture ${label} did not start"
    fi
    capture_pid="$(<"$pid_file")"
    if [[ ! "$capture_pid" =~ ^[1-9][0-9]*$ ]] || ! kill -0 "$capture_pid" 2>/dev/null; then
        cat "$log_file" >&2 || true
        die "DHCP debug capture ${label} exited during startup"
    fi
    DEBUG_CAPTURE_PID_FILES+=("$pid_file")
}

stop_dhcp_debug_captures() {
    local pid_file capture_pid launch_pid
    for pid_file in "${DEBUG_CAPTURE_PID_FILES[@]}"; do
        [[ -s "$pid_file" ]] || continue
        capture_pid="$(<"$pid_file")"
        [[ "$capture_pid" =~ ^[1-9][0-9]*$ ]] \
            && kill "$capture_pid" >/dev/null 2>&1 || true
    done
    for launch_pid in "${DEBUG_CAPTURE_LAUNCH_PIDS[@]}"; do
        wait "$launch_pid" 2>/dev/null || true
    done
    DEBUG_CAPTURE_PID_FILES=()
    DEBUG_CAPTURE_LAUNCH_PIDS=()
}

start_dhcp_debug_captures() {
    local client_container_name="$1" vlan_id="$2" phase="$3"
    local subnet_uid="$4" subnet_cidr="$5" subnet_interface="$6" aap_job_id="$7"
    local client_pid leaf_one_pid leaf_two_pid node_pid vlan_namespace pid client_mac
    [[ "$VLAN_E2E_DEBUG" == true ]] || return 0
    client_link b1
    [[ "$CLIENT_SWITCH" == "${CONTAINERLAB_PREFIX}-leaf-2" && "$CLIENT_SWITCH_PORT" == swp3 ]] \
        || die "Unexpected B1 switch path for DHCP packet tracing"
    client_pid="$(docker inspect -f '{{.State.Pid}}' "$client_container_name")"
    leaf_one_pid="$(docker inspect -f '{{.State.Pid}}' "${CONTAINERLAB_PREFIX}-leaf-1")"
    leaf_two_pid="$(docker inspect -f '{{.State.Pid}}' "${CONTAINERLAB_PREFIX}-leaf-2")"
    node_pid="$(docker inspect -f '{{.State.Pid}}' "$CONTAINERLAB_NET_NODE")"
    client_mac="$(<"$TEMP_DIR/client-b1.mac")"
    for pid in "$client_pid" "$leaf_one_pid" "$leaf_two_pid" "$node_pid"; do
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || die "Could not inspect a DHCP trace network namespace"
    done
    vlan_namespace="/proc/${node_pid}/root/run/netns/${FIRST_PARENT_NAMESPACE}"
    [[ -e "$vlan_namespace" ]] || die "Parent namespace is not visible for DHCP packet tracing"

    start_dhcp_debug_capture "${phase}-b1-client" "pid:${client_pid}" eth0 client "$client_mac"
    start_dhcp_debug_capture "${phase}-leaf-2-access" "pid:${leaf_two_pid}" swp3 client "$client_mac"
    start_dhcp_debug_capture "${phase}-leaf-2-interlink" "pid:${leaf_two_pid}" swp1 mac "$client_mac"
    start_dhcp_debug_capture "${phase}-leaf-1-interlink" "pid:${leaf_one_pid}" swp1 mac "$client_mac"
    start_dhcp_debug_capture "${phase}-leaf-1-netnode" "pid:${leaf_one_pid}" swp3 mac "$client_mac"
    start_dhcp_debug_capture "${phase}-netnode-uplink" "pid:${node_pid}" eth1 mac "$client_mac"
    start_dhcp_debug_capture "${phase}-netnode-parent" "file:${vlan_namespace}" any dhcp
    start_dhcp_debug_capture "${phase}-netnode-subnet" "file:${vlan_namespace}" \
        "$subnet_interface" dhcp
    {
        printf 'phase=%s\n' "$phase"
        printf 'source_revision=%s\n' "$IMAGE_SOURCE_COMMIT"
        printf 'aap_project_branch=%s\n' "$AAP_PROJECT_GIT_BRANCH"
        printf 'client=b1\nmac=%s\nsubnet_uid=%s\naap_job_id=%s\ncidr=%s\nvlan=%s\ninterface=%s\n' \
            "$client_mac" "$subnet_uid" "$aap_job_id" "$subnet_cidr" \
            "$vlan_id" "$subnet_interface"
        printf 'capture_interfaces=client-eth0,leaf-2-swp3,leaf-2-swp1,leaf-1-swp1,leaf-1-swp3,net-node-eth1,parent-any,parent-vlan\n'
    } >"$TEMP_DIR/dhcp-debug-context-${phase}.txt"
    chmod 0600 "$TEMP_DIR/dhcp-debug-context-${phase}.txt"
}

copy_debug_client_log() {
    local client="$1" phase="$2" container
    [[ "$VLAN_E2E_DEBUG" == true && "$client" == b1 ]] || return 0
    container="$(client_container "$client")"
    docker cp "$container:/tmp/osac-5530-udhcpc.log" \
        "$TEMP_DIR/client-${client}-${phase}-udhcpc.log" >/dev/null 2>&1 || true
    [[ ! -f "$TEMP_DIR/client-${client}-${phase}-udhcpc.log" ]] \
        || chmod 0600 "$TEMP_DIR/client-${client}-${phase}-udhcpc.log"
    if [[ -s "$TEMP_DIR/client-${client}.lease.json" ]]; then
        cp "$TEMP_DIR/client-${client}.lease.json" \
            "$TEMP_DIR/client-${client}-${phase}-lease.json"
        chmod 0600 "$TEMP_DIR/client-${client}-${phase}-lease.json"
    fi
}

capture_failed_dhcp_client_state() {
    local client="$1" phase="$2" container service_name
    [[ "$VLAN_E2E_DEBUG" == true ]] || return 0
    container="$(client_container "$client")"
    service_name="agentless-dhcp-${FIRST_K8S_UID}"
    {
        printf 'client=%s\n' "$client"
        docker exec "$container" ps || true
        docker exec "$container" sh -c '
            printf "carrier="; cat /sys/class/net/eth0/carrier
            ip link show dev eth0
            ip route show dev eth0
            for stat in tx_packets rx_packets; do
                printf "%s=" "$stat"
                cat "/sys/class/net/eth0/statistics/$stat"
            done
        ' || true
        client_link "$client"
        docker exec "$CLIENT_SWITCH" ip -o link show dev "$CLIENT_SWITCH_PORT" || true
        docker exec "$CLIENT_SWITCH" bridge -j vlan show dev "$CLIENT_SWITCH_PORT" || true
        docker exec "$CLIENT_SWITCH" bridge fdb show dev "$CLIENT_SWITCH_PORT" || true
        while IFS=$'\t' read -r switch trunk; do
            [[ -n "$switch" && -n "$trunk" ]] || continue
            printf 'switch=%s trunk=%s\n' "$switch" "$trunk"
            docker exec "$switch" bridge -j vlan show dev "$trunk" || true
            docker exec "$switch" bridge fdb show dev "$trunk" || true
            docker exec "$switch" nv config show --output json \
                | jq -c --arg port "$trunk" '.[0].set.interface[$port] // null' || true
        done < <(jq -r '.switches[] | .name as $name | .trunk_ports[] | [$name, .] | @tsv' \
            "$SWITCH_MANIFEST_FILE")
        netnode supervisorctl -c /etc/agentless-net/supervisord.conf status "$service_name" || true
        netnode ip netns exec "$FIRST_PARENT_NAMESPACE" \
            ip -d -s link show dev "$SUBNET_THREE_VLAN_INTERFACE" || true
        netnode ip netns exec "$FIRST_PARENT_NAMESPACE" \
            ip -j address show dev "$SUBNET_THREE_VLAN_INTERFACE" || true
        netnode ip netns exec "$FIRST_PARENT_NAMESPACE" ss -lunp || true
        netnode cat "/etc/agentless-net/dhcp/${FIRST_K8S_UID}/dnsmasq.conf" || true
        netnode cat "/var/lib/agentless-net/dhcp/${FIRST_K8S_UID}/dnsmasq.leases" || true
        netnode tail -n 100 "/var/log/agentless-net/dhcp/${FIRST_K8S_UID}.log" || true
    } >"$TEMP_DIR/dhcp-client-${client}-runtime-${phase}.txt" 2>&1
    chmod 0600 "$TEMP_DIR/dhcp-client-${client}-runtime-${phase}.txt"
}

sample_dhcp_bridge_state() {
    local client="$1" phase="$2" attempt="$3" output
    [[ "$VLAN_E2E_DEBUG" == true && "$client" == b1 ]] || return 0
    output="$TEMP_DIR/dhcp-client-${client}-forwarding-${phase}.log"
    {
        printf 'attempt=%s utc=%s\n' "$attempt" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        docker exec "${CONTAINERLAB_PREFIX}-leaf-2" sh -c '
            for port in swp3 swp1; do
                printf "leaf-2 %s\n" "$port"
                bridge -d link show dev "$port"
            done
        ' || true
        docker exec "${CONTAINERLAB_PREFIX}-leaf-1" sh -c '
            for port in swp1 swp3; do
                printf "leaf-1 %s\n" "$port"
                bridge -d link show dev "$port"
            done
        ' || true
    } >>"$output" 2>&1
    chmod 0600 "$output"
}

start_dhcp_client() {
    local client="$1" container lease_path link_carrier lease_db service_log capture_this_client capture_phase
    container="$(client_container "$client")"
    lease_path=/run/osac-dhcp/lease.json
    lease_db="/var/lib/agentless-net/dhcp/$FIRST_K8S_UID/dnsmasq.leases"
    service_log="/var/log/agentless-net/dhcp/$FIRST_K8S_UID.log"
    capture_this_client=false
    capture_phase=""
    if [[ "$VLAN_E2E_DEBUG" == true && "$client" == b1 ]]; then
        capture_this_client=true
        if [[ -n "${SUBNET_THREE_K8S_UID:-}" ]]; then
            capture_phase=30
        else
            capture_phase=subnet-b
        fi
    fi
    link_carrier="$(docker exec "$container" cat /sys/class/net/eth0/carrier)" \
        || die "Could not read carrier state for DHCP client ${client}"
    [[ "$link_carrier" == 1 ]] \
        || die "DHCP client ${client} has no active carrier on its access link"
    docker exec "$container" rm -f "$lease_path"
    if [[ "$capture_this_client" == true ]]; then
        if [[ "$capture_phase" == 30 ]]; then
            start_dhcp_debug_captures "$container" "$SUBNET_THREE_VLAN_ID" \
                "$capture_phase" "$SUBNET_THREE_K8S_UID" "$SUBNET_THREE_IPV4_CIDR" \
                "$SUBNET_THREE_VLAN_INTERFACE" "$SUBNET_THREE_AAP_JOB_ID"
        else
            start_dhcp_debug_captures "$container" "$SUBNET_TWO_VLAN_ID" \
                "$capture_phase" "$SUBNET_TWO_K8S_UID" "$SUBNET_TWO_IPV4_CIDR" \
                "$SECOND_SUBNET_VLAN_INTERFACE" "$SUBNET_TWO_AAP_JOB_ID"
        fi
        docker exec "$container" rm -f /tmp/osac-5530-udhcpc.log
        docker exec -d "$container" sh -c \
            'exec udhcpc -v -f -n -i eth0 -s /usr/local/sbin/osac-udhcpc-hook.sh -t 60 -T 2 >/tmp/osac-5530-udhcpc.log 2>&1'
    else
        docker exec -d "$container" udhcpc -f -n -i eth0 \
            -s /usr/local/sbin/osac-udhcpc-hook.sh -t 60 -T 2
    fi
    for ((attempt = 1; attempt <= 45; attempt++)); do
        if docker exec "$container" test -s "$lease_path"; then
            docker exec "$container" cat "$lease_path" >"$TEMP_DIR/client-${client}.lease.json"
            if jq -e '.address and .router and .mac' \
                "$TEMP_DIR/client-${client}.lease.json" >/dev/null; then
                dhcp_client_pid "$container" >/dev/null \
                    || die "DHCP client ${client} received a lease but udhcpc is not running"
                if [[ "$capture_this_client" == true ]]; then
                    copy_debug_client_log "$client" "$capture_phase"
                    stop_dhcp_debug_captures
                fi
                return 0
            fi
        fi
        if [[ "$capture_this_client" == true && $((attempt % 3)) == 0 ]]; then
            sample_dhcp_bridge_state "$client" "$capture_phase" "$attempt"
        fi
        sleep 2
    done
    printf 'DHCP client %s did not receive a lease\n' "$client" >&2
    if [[ "$capture_this_client" == true ]]; then
        copy_debug_client_log "$client" "$capture_phase"
        capture_failed_dhcp_client_state "$client" "$capture_phase"
        stop_dhcp_debug_captures
        cat "$TEMP_DIR/dhcp-client-${client}-runtime-${capture_phase}.txt" >&2
        die "Timed out waiting for real DHCP client $client"
    fi
    client_link "$client"
    docker exec "$container" ps >&2 || true
    docker exec "$container" sh -c '
        printf "carrier="
        cat /sys/class/net/eth0/carrier
        for stat in tx_packets rx_packets; do
            printf "%s=" "$stat"
            cat "/sys/class/net/eth0/statistics/$stat"
        done
    ' >&2 || true
    docker exec "$CLIENT_SWITCH" ip -o link show dev "$CLIENT_SWITCH_PORT" >&2 || true
    docker exec "$CLIENT_SWITCH" bridge -j vlan show dev "$CLIENT_SWITCH_PORT" >&2 || true
    docker exec "$CLIENT_SWITCH" bridge fdb show dev "$CLIENT_SWITCH_PORT" >&2 || true
    netnode cat "$lease_db" >&2 || true
    netnode tail -n 40 "$service_log" >&2 || true
    die "Timed out waiting for real DHCP client $client"
}

renew_dhcp_client() {
    local client="$1" container lease_path old_generation pid
    container="$(client_container "$client")"
    lease_path=/run/osac-dhcp/lease.json
    old_generation="$(jq -r '.generation' "$TEMP_DIR/client-${client}.lease.json")"
    pid="$(dhcp_client_pid "$container")" \
        || die "Could not find the running udhcpc process for client ${client}"
    docker exec "$container" kill -USR1 "$pid"
    for ((attempt = 1; attempt <= 45; attempt++)); do
        docker exec "$container" test -s "$lease_path" || { sleep 2; continue; }
        docker exec "$container" cat "$lease_path" >"$TEMP_DIR/client-${client}.lease.json"
        if [[ "$(jq -r '.generation' "$TEMP_DIR/client-${client}.lease.json")" -gt "$old_generation" ]]; then
            return 0
        fi
        sleep 2
    done
    die "DHCP client $client did not renew after the DHCP service restart"
}

stop_dhcp_client() {
    local client="$1" container pid
    container="$(client_container "$client")"
    if pid="$(dhcp_client_pid "$container")"; then
        docker exec "$container" kill -TERM "$pid" >/dev/null 2>&1 || true
    fi
}

detach_dhcp_client() {
    local client="$1" container
    container="$(client_container "$client")"
    stop_dhcp_client "$client"
    docker exec "$container" ip address flush dev eth0
    docker exec "$container" ip route flush dev eth0
    restore_client_access_port "$client"
}

cleanup_dhcp_clients_and_ports() {
    local container link pid failed=false
    for container in "${DHCP_CLIENT_CONTAINERS[@]}"; do
        if pid="$(dhcp_client_pid "$container")"; then
            docker exec "$container" kill -TERM "$pid" >/dev/null 2>&1 || true
        fi
        docker rm -f "$container" >/dev/null 2>&1 || failed=true
    done
    for link in "${DHCP_CLIENT_HOST_LINKS[@]}"; do
        if sudo ip link show dev "$link" >/dev/null 2>&1; then
            sudo ip link delete dev "$link" || failed=true
        fi
    done
    restore_client_access_ports || failed=true
    [[ "$failed" == false ]]
}

write_client_lease_expectations() {
    local spec client subnet_entry mac clients='[]'
    CLIENT_EXPECTED_LEASES_FILE="$TEMP_DIR/dhcp-client-expectations.json"
    for spec in "$@"; do
        client="${spec%%=*}"
        subnet_entry="${spec#*=}"
        mac="$(<"$TEMP_DIR/client-${client}.mac")"
        clients="$(jq -cn --argjson current "$clients" --arg name "$client" \
            --arg mac "$mac" --argjson subnet "$subnet_entry" \
            '$current + [{name:$name,mac:$mac,subnet:$subnet}]')"
    done
    jq -n --argjson clients "$clients" '{clients:$clients}' >"$CLIENT_EXPECTED_LEASES_FILE"
    chmod 0600 "$CLIENT_EXPECTED_LEASES_FILE"
}

assert_client_gateway() {
    local client="$1" subnet_entry="$2" container gateway
    container="$(client_container "$client")"
    gateway="$(jq -r '.gateway_ipv4' <<<"$subnet_entry")"
    docker exec "$container" ping -n -c 3 -W 2 "$gateway" >/dev/null 2>&1 \
        || die "Real DHCP client $client cannot ping Subnet gateway $gateway"
}

assert_same_subnet_l2() {
    local first="$1" second="$2" first_ip second_ip first_mac second_mac
    first_ip="$(jq -r '.address' "$TEMP_DIR/client-${first}.lease.json")"
    second_ip="$(jq -r '.address' "$TEMP_DIR/client-${second}.lease.json")"
    first_mac="$(<"$TEMP_DIR/client-${first}.mac")"
    second_mac="$(<"$TEMP_DIR/client-${second}.mac")"
    OSAC_REPO_ROOT="$REPO_ROOT" python3 "$DHCP_CLIENT_HELPER" \
        assert-l2-delivery --client "$(client_container "$first")" \
        --target "$second_ip" --mac "$second_mac"
    OSAC_REPO_ROOT="$REPO_ROOT" python3 "$DHCP_CLIENT_HELPER" \
        assert-l2-delivery --client "$(client_container "$second")" \
        --target "$first_ip" --mac "$first_mac"
}

assert_real_client_leases() {
    local lease_file="$TEMP_DIR/dnsmasq-leases.txt" client
    local -a args=(assert-client-leases --expected "$CLIENT_EXPECTED_LEASES_FILE" \
        --dnsmasq-leases "$lease_file")
    netnode cat "/var/lib/agentless-net/dhcp/${FIRST_K8S_UID}/dnsmasq.leases" >"$lease_file" \
        || die "Could not read the saved dnsmasq lease file for the test VirtualNetwork"
    for client in "$@"; do
        args+=(--lease "$client=$TEMP_DIR/client-${client}.lease.json")
    done
    OSAC_REPO_ROOT="$REPO_ROOT" python3 "$DHCP_CLIENT_HELPER" "${args[@]}"
}

assert_deleted_subnet_lease_removed() {
    local mac="$1" parent_uid="$2" leases_file="$TEMP_DIR/dnsmasq-leases-after-delete.txt"
    netnode cat "/var/lib/agentless-net/dhcp/${parent_uid}/dnsmasq.leases" >"$leases_file" \
        || die "Could not read the DHCP lease file after deleting the Subnet"
    if awk -v mac="$mac" 'tolower($2) == tolower(mac) { found=1 } END { exit !found }' \
        "$leases_file"; then
        die "The deleted Subnet's DHCP lease for MAC $mac remains in the parent lease file"
    fi
}

state_snapshot() {
    docker exec -i "$CONTAINERLAB_NET_NODE" python3 - "$AGENTLESS_NET_STATE_FILE" <<'PY'
import json
import pathlib
import sqlite3
import sys

path = pathlib.Path(sys.argv[1])
if not path.exists():
    print(json.dumps({"schema_version": 0, "virtual_networks": [], "subnets": []}, sort_keys=True))
    raise SystemExit(0)
expected_virtual_network_columns = {
    "uid", "tenant_id", "virtual_network_cidr", "namespace_name",
    "namespace_interface", "host_interface", "transit_cidr", "transit_start",
    "payload",
}
expected_subnet_columns = {
    "uid", "virtual_network_uid", "tenant_id", "vlan_id", "vlan_interface",
    "ipv4_cidr", "phase", "payload",
}
connection = None
try:
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=60)
    tables = {
        row[0]
        for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")
    }
    version = connection.execute("PRAGMA user_version").fetchone()[0]
    virtual_network_columns = {
        row[1]
        for row in connection.execute("PRAGMA table_info(virtual_networks)")
    }
    if version == 1:
        if tables != {"virtual_networks"} or virtual_network_columns != expected_virtual_network_columns:
            raise SystemExit("AgentlessNet schema-v1 SQLite state is incompatible; preserving it")
        subnet_entries = []
    elif version == 2:
        subnet_columns = {
            row[1]
            for row in connection.execute("PRAGMA table_info(subnets)")
        }
        if (
            tables != {"virtual_networks", "subnets"}
            or virtual_network_columns != expected_virtual_network_columns
            or subnet_columns != expected_subnet_columns
        ):
            raise SystemExit("AgentlessNet schema-v2 SQLite state is incompatible; preserving it")
        subnet_entries = [
            json.loads(row[0])
            for row in connection.execute("SELECT payload FROM subnets ORDER BY uid")
        ]
    else:
        raise SystemExit("AgentlessNet SQLite state has an incompatible schema; preserving it")
    entries = [
        json.loads(row[0])
        for row in connection.execute("SELECT payload FROM virtual_networks ORDER BY uid")
    ]
except (OSError, sqlite3.DatabaseError, json.JSONDecodeError) as error:
    raise SystemExit("AgentlessNet SQLite state is unreadable; preserving it") from error
finally:
    if connection is not None:
        connection.close()
print(json.dumps({"schema_version": version, "virtual_networks": entries, "subnets": subnet_entries}, sort_keys=True))
PY
}

save_current_state() {
    state_snapshot > "$CURRENT_STATE_FILE"
    jq -e '.schema_version == 2 and (.virtual_networks | type == "array") and (.subnets | type == "array")' \
        "$CURRENT_STATE_FILE" >/dev/null \
        || die "AgentlessNet state is not a valid schema-v2 snapshot"
}

assert_baseline_state_unchanged() {
    local collection uid before after
    for collection in virtual_networks subnets; do
        while IFS= read -r uid; do
            [[ -n "$uid" ]] || continue
            before="$(jq -cS --arg uid "$uid" --arg collection "$collection" \
                '.[$collection][] | select(.uid == $uid)' "$BASELINE_STATE_FILE")"
            after="$(jq -cS --arg uid "$uid" --arg collection "$collection" \
                '.[$collection][] | select(.uid == $uid)' "$CURRENT_STATE_FILE")"
            [[ -n "$after" && "$before" == "$after" ]] \
                || die "Pre-existing AgentlessNet ${collection} state for UID ${uid} changed during the test"
        done < <(jq -r --arg collection "$collection" '.[$collection][].uid' "$BASELINE_STATE_FILE")
    done
}

get_state_entry() {
    local uid="$1"
    save_current_state
    jq -ce --arg uid "$uid" '
      [.virtual_networks[] | select(.uid == $uid)]
      | if length == 1 then .[0] else error("expected exactly one state entry for UID " + $uid) end' \
      "$CURRENT_STATE_FILE"
}

get_subnet_state_entry() {
    local uid="$1"
    save_current_state
    jq -ce --arg uid "$uid" '
      [.subnets[] | select(.uid == $uid)]
      | if length == 1 then .[0] else error("expected exactly one Subnet state entry for UID " + $uid) end' \
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
    jq -e '((keys | sort) == ["namespace_name","tenant_id","transit","uid","uplink","virtual_network_cidr"])
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
    grep -Fxq -- '-A FORWARD -i osacvn+ -j DROP' <<<"$rules" \
        || die "Host inbound isolation rule for ${host_interface} is absent"
    grep -Fxq -- '-A FORWARD -o osacvn+ -j DROP' <<<"$rules" \
        || die "Host outbound isolation rule for ${host_interface} is absent"
    netnode ip netns exec "$namespace_name" ping -n -I "$namespace_interface" -c 1 -W 2 "$gateway" \
        >/dev/null 2>&1 || die "Namespace ${namespace_name} cannot reach its host gateway ${gateway}"

    info "Verified Fulfillment ID ${fulfillment_id}, CR ${cr_name}, Kubernetes UID ${cr_uid}, /31 ${transit_cidr}, gateway ${gateway}"
}

assert_vlan_on_switches() {
    local vlan_id="$1" should_exist="$2" switch port switch_json
    while IFS= read -r switch; do
        [[ -n "$switch" ]] || continue
        switch_json="$(docker exec "$switch" bridge -j vlan show)" \
            || die "Could not read VLAN state from Cumulus switch ${switch}"
        if [[ "$should_exist" == true ]]; then
            while IFS= read -r port; do
                [[ -n "$port" ]] || continue
                jq -e --arg port "$port" --argjson vlan "$vlan_id" '
                  any(.[]; .ifname == $port and any(.vlans[]?;
                    ((.vlan | tonumber) <= $vlan)
                    and (((.vlanEnd // .vlan) | tonumber) >= $vlan)))' \
                  <<<"$switch_json" >/dev/null \
                    || die "VLAN ${vlan_id} is missing from declared trunk ${switch}/${port}"
            done < <(jq -r --arg name "$switch" \
                '.switches[] | select(.name == $name) | .trunk_ports[]' "$SWITCH_MANIFEST_FILE")
        else
            jq -e --argjson vlan "$vlan_id" '
              [.[].vlans[]? | select(
                ((.vlan | tonumber) <= $vlan)
                and (((.vlanEnd // .vlan) | tonumber) >= $vlan)
              )] | length == 0' <<<"$switch_json" >/dev/null \
                || die "VLAN ${vlan_id} remains on Cumulus switch ${switch} after cleanup"
        fi
    done < <(jq -r '.switches[].name' "$SWITCH_MANIFEST_FILE")
}

snapshot_switch_vlan_state() {
    local switch bridge_state reserved_state rows_file
    rows_file="$TEMP_DIR/switch-vlan-snapshot.jsonl"
    SWITCH_VLAN_SNAPSHOT_FILE="$TEMP_DIR/switch-vlan-snapshot.json"
    : >"$rows_file"
    while IFS= read -r switch; do
        [[ -n "$switch" ]] || continue
        bridge_state="$(docker exec "$switch" bridge -j vlan show)" \
            || die "Could not read VLAN state from Cumulus switch ${switch}"
        reserved_state="$(docker exec "$switch" nv show system global reserved vlan --output json)" \
            || die "Could not read reserved VLAN ranges from Cumulus switch ${switch}"
        jq -nc --arg name "$switch" --arg bridge "$bridge_state" \
            --arg reserved "$reserved_state" \
            '{name:$name,bridge_vlan_output:$bridge,reserved_vlan_output:$reserved}' >>"$rows_file"
    done < <(jq -r '.switches[].name' "$SWITCH_MANIFEST_FILE")
    jq -s . "$rows_file" >"$TEMP_DIR/switch-vlan-snapshot-input.json"
    OSAC_REPO_ROOT="$REPO_ROOT" python3 "$DHCP_CLIENT_HELPER" \
        snapshot-vlans --input "$TEMP_DIR/switch-vlan-snapshot-input.json" \
        --output "$SWITCH_VLAN_SNAPSHOT_FILE" \
        || die "Could not validate the baseline Cumulus VLAN snapshot"
    chmod 0600 "$SWITCH_VLAN_SNAPSHOT_FILE"
    info "Captured existing VLAN memberships and NVUE reserved ranges from every configured switch."
}

assert_new_vlans_avoid_baseline() {
    local vlan
    local -a args=(assert-allocations --snapshot "$SWITCH_VLAN_SNAPSHOT_FILE")
    for vlan in "$@"; do
        args+=(--vlan "$vlan")
    done
    OSAC_REPO_ROOT="$REPO_ROOT" python3 "$DHCP_CLIENT_HELPER" "${args[@]}" \
        || die "AgentlessNet allocated a VLAN already present or reserved on a configured switch"
}

assert_subnet_state() {
    local fulfillment_id="$1" parent_fulfillment_id="$2" expected_cidr="$3"
    local cr_json parent_cr parent_uid cr_uid cr_name entry parent_entry
    local vlan_id vlan_interface namespace_name gateway dhcp_start dhcp_end
    local expected_gateway expected_dhcp_start expected_dhcp_end expected_netmask
    local link_json address_json config_path config service_status socket_output

    cr_json="$(subnet_cr_json "$fulfillment_id" "$parent_fulfillment_id")"
    parent_cr="$(virtual_network_cr_json "$parent_fulfillment_id")"
    cr_uid="$(jq -r '.metadata.uid' <<<"$cr_json")"
    parent_uid="$(jq -r '.metadata.uid' <<<"$parent_cr")"
    cr_name="$(jq -r '.metadata.name' <<<"$cr_json")"
    [[ -n "$cr_uid" ]] || die "Subnet ${fulfillment_id} has no Kubernetes UID"
    [[ "$(jq -r '.spec.ipv4Cidr' <<<"$cr_json")" == "$expected_cidr" ]] \
        || die "Subnet ${fulfillment_id} CR CIDR changed from the request"
    [[ "$(jq -r '.status.phase' <<<"$cr_json")" == Ready ]] \
        || die "Subnet ${fulfillment_id} CR is not Ready"
    jq -e '.status.conditions | any(.[]?; .type == "Ready" and .status == "True")' \
        <<<"$cr_json" >/dev/null || die "Subnet ${fulfillment_id} has no successful Ready condition"

    entry="$(get_subnet_state_entry "$cr_uid")"
    parent_entry="$(get_state_entry "$parent_uid")"
    jq -e --arg uid "$cr_uid" --arg parent "$parent_uid" --arg tenant "$OSAC_TENANT" \
        --arg cidr "$expected_cidr" '
      ((keys | sort) == ["dhcp_range_end","dhcp_range_start","gateway_ipv4","ipv4_cidr","phase","tenant_id","trunk_interface","uid","vip_cidr","virtual_network_uid","vlan_id","vlan_interface"])
      and .uid == $uid
      and .virtual_network_uid == $parent
      and .tenant_id == $tenant
      and .ipv4_cidr == $cidr
      and .phase == "ready"
      and (.vlan_id | type == "number" and . >= 1 and . <= 4094)' \
      <<<"$entry" >/dev/null || die "Saved AgentlessNet Subnet state does not match the Ready Fulfillment resource"

    vlan_id="$(jq -r '.vlan_id' <<<"$entry")"
    vlan_interface="$(jq -r '.vlan_interface' <<<"$entry")"
    namespace_name="$(jq -r '.namespace_name' <<<"$parent_entry")"
    gateway="$(jq -r '.gateway_ipv4' <<<"$entry")"
    dhcp_start="$(jq -r '.dhcp_range_start' <<<"$entry")"
    dhcp_end="$(jq -r '.dhcp_range_end' <<<"$entry")"
    read -r expected_gateway expected_dhcp_start expected_dhcp_end expected_netmask \
        < <(python3 -c 'import ipaddress,sys; n=ipaddress.ip_network(sys.argv[1], strict=True); print(n.network_address+1, n.network_address+2, n.broadcast_address-1, n.netmask)' "$expected_cidr")
    [[ "$gateway" == "$expected_gateway" && "$dhcp_start" == "$expected_dhcp_start" \
        && "$dhcp_end" == "$expected_dhcp_end" ]] \
        || die "Subnet ${fulfillment_id} gateway or DHCP range is incorrect"

    link_json="$(netnode ip netns exec "$namespace_name" ip -j -d link show dev "$vlan_interface")"
    jq -e --arg alias "osac-subnet:${cr_uid}" --argjson vlan "$vlan_id" '
      length == 1 and .[0].ifalias == $alias and .[0].linkinfo.info_kind == "vlan"
      and (.[0].linkinfo.info_data.id | tonumber) == $vlan
      and (.[0].flags | index("UP") != null)' <<<"$link_json" >/dev/null \
        || die "Subnet VLAN interface ${vlan_interface} is not UID-owned, up, and tagged ${vlan_id}"
    address_json="$(netnode ip netns exec "$namespace_name" ip -j -4 address show dev "$vlan_interface")"
    jq -e --arg ip "$gateway" --argjson prefix "${expected_cidr#*/}" \
        'any(.[].addr_info[]?; .family == "inet" and .local == $ip and .prefixlen == $prefix)' \
        <<<"$address_json" >/dev/null \
        || die "Subnet gateway ${gateway}/${expected_cidr#*/} is absent from ${vlan_interface}"

    config_path="/etc/agentless-net/dhcp/${parent_uid}/dnsmasq.conf"
    config="$(netnode cat "$config_path")" \
        || die "Per-VirtualNetwork DHCP configuration is missing for Subnet ${fulfillment_id}"
    grep -Fxq "interface=${vlan_interface}" <<<"$config" \
        || die "DHCP does not bind to Subnet interface ${vlan_interface}"
    grep -Fxq "dhcp-range=set:${vlan_interface},${dhcp_start},${dhcp_end},${expected_netmask},12h" <<<"$config" \
        || die "DHCP range does not match saved Subnet state for ${fulfillment_id}"
    grep -Fxq "dhcp-option=tag:${vlan_interface},option:router,${gateway}" <<<"$config" \
        || die "DHCP router option does not match Subnet gateway ${gateway}"
    netnode dnsmasq --test --conf-file="$config_path" >/dev/null 2>&1 \
        || die "dnsmasq rejected the combined DHCP configuration for VirtualNetwork ${parent_uid}"
    service_status="$(netnode supervisorctl -c /etc/agentless-net/supervisord.conf \
        status "agentless-dhcp-${parent_uid}")"
    grep -Fq ' RUNNING ' <<<"$service_status" \
        || die "Per-VirtualNetwork DHCP Supervisor service is not running"
    socket_output="$(netnode ip netns exec "$namespace_name" ss -H -lun)"
    grep -Eq ':67([[:space:]]|$)' <<<"$socket_output" \
        || die "DHCP UDP port 67 is not listening inside namespace ${namespace_name}"
    assert_vlan_on_switches "$vlan_id" true
    info "Verified Subnet ${fulfillment_id} (${cr_name}), gateway ${gateway}, VLAN ${vlan_id}, and DHCP range ${dhcp_start}-${dhcp_end}"
}

assert_uid_subnet_state_absent() {
    local uid="$1" parent_uid="$2" namespace_name="$3" vlan_interface="$4" vlan_id="$5"
    local config_path config
    save_current_state
    jq -e --arg uid "$uid" 'all(.subnets[]; .uid != $uid)' "$CURRENT_STATE_FILE" >/dev/null \
        || die "Deleted Subnet UID ${uid} remains in provider state"
    if netnode ip netns exec "$namespace_name" ip link show dev "$vlan_interface" >/dev/null 2>&1; then
        die "Deleted Subnet VLAN interface ${vlan_interface} remains in namespace ${namespace_name}"
    fi
    config_path="/etc/agentless-net/dhcp/${parent_uid}/dnsmasq.conf"
    if config="$(netnode cat "$config_path" 2>/dev/null)"; then
        if grep -Fxq "interface=${vlan_interface}" <<<"$config"; then
            die "Deleted Subnet ${uid} remains in the parent DHCP configuration"
        fi
    fi
    assert_vlan_on_switches "$vlan_id" false
}

assert_virtual_network_dhcp_absent() {
    local parent_uid="$1" namespace_name="$2" service_status
    if service_status="$(netnode supervisorctl -c /etc/agentless-net/supervisord.conf \
        status "agentless-dhcp-${parent_uid}" 2>/dev/null)" \
        && grep -Fq "agentless-dhcp-${parent_uid}" <<<"$service_status"; then
        die "DHCP Supervisor program remains after the VirtualNetwork's last Subnet was deleted"
    fi
    if netnode ip netns exec "$namespace_name" ss -H -lun 2>/dev/null \
        | grep -Eq ':67([[:space:]]|$)'; then
        die "DHCP UDP port 67 remains open after the VirtualNetwork's last Subnet was deleted"
    fi
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

delete_subnet_by_id() {
    local id="$1"
    LAST_SUBNET_DELETE_AAP_JOB_ID=""
    info "Deleting test-owned Subnet UUID ${id} through Fulfillment..."
    "$CLI_BIN" --config "$CLI_CONFIG_DIR" --tenant "$OSAC_TENANT" delete subnet "$id"
    wait_for_subnet_deleted "$id"
    [[ -n "$LAST_SUBNET_DELETE_AAP_JOB_ID" ]] \
        || die "No AAP deprovision job ID was recorded for test-owned Subnet UUID ${id}"
    info "AAP delete job ID for Subnet ${id}: ${LAST_SUBNET_DELETE_AAP_JOB_ID}"
    local index
    for index in "${!CREATED_SUBNET_IDS[@]}"; do
        if [[ "${CREATED_SUBNET_IDS[$index]}" == "$id" ]]; then
            unset 'CREATED_SUBNET_IDS[index]'
        fi
    done
}

assert_uid_provider_state_absent() {
    local uid="$1" namespace_name="$2" host_interface="$3" namespace_list
    save_current_state
    jq -e --arg uid "$uid" 'all(.virtual_networks[]; .uid != $uid)' "$CURRENT_STATE_FILE" >/dev/null \
        || die "Deleted VirtualNetwork UID ${uid} remains in provider state"
    jq -e --arg uid "$uid" 'all(.subnets[]; .virtual_network_uid != $uid)' "$CURRENT_STATE_FILE" >/dev/null \
        || die "Deleted VirtualNetwork UID ${uid} still has Subnet provider state"
    namespace_list="$(netnode ip netns list)"
    if awk -v name="$namespace_name" '$1 == name { found=1 } END { exit !found }' <<<"$namespace_list"; then
        die "Deleted namespace ${namespace_name} remains on the test node"
    fi
    if netnode ip -j -d link show dev "$host_interface" >/dev/null 2>&1; then
        die "Deleted UID-owned host uplink ${host_interface} remains on the test node"
    fi
}

create_subnet() {
    local name="$1" parent_id="$2" cidr="$3" output_file="$4" output id
    if ! "$CLI_BIN" --config "$CLI_CONFIG_DIR" --tenant "$OSAC_TENANT" \
        create subnet --name "$name" --virtual-network "$parent_id" --ipv4-cidr "$cidr" \
        >"$output_file" 2>&1; then
        cat "$output_file" >&2
        output="$(cat "$output_file")"
        id="$(sed -nE 's/.*\(ID: ([0-9a-f-]+)\).*/\1/p' <<<"$output" | tail -n 1)"
        if [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
            CREATED_SUBNET_IDS+=("$id")
            printf '%s\n' "$id" >"${output_file}.id"
        fi
        return 1
    fi
    cat "$output_file" >&2
    output="$(cat "$output_file")"
    id="$(sed -nE 's/.*\(ID: ([0-9a-f-]+)\).*/\1/p' <<<"$output" | tail -n 1)"
    [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || { printf 'Could not parse Fulfillment UUID from CLI create output for Subnet %s\n' "$name" >&2; return 1; }
    CREATED_SUBNET_IDS+=("$id")
    printf '%s\n' "$id" >"${output_file}.id"
}

resolve_test_subnet_cidrs() {
    local parent_cidr="$1" transit_cidr="$2" subnet_output
    subnet_output="$(python3 - "$parent_cidr" "$transit_cidr" \
        "$SUBNET_ONE_IPV4_CIDR" "$SUBNET_TWO_IPV4_CIDR" <<'PY'
import ipaddress
import sys

parent = ipaddress.ip_network(sys.argv[1], strict=True)
transit = ipaddress.ip_network(sys.argv[2], strict=True)
override_one, override_two = sys.argv[3:]
if not isinstance(parent, ipaddress.IPv4Network) or not isinstance(transit, ipaddress.IPv4Network):
    raise SystemExit("AgentlessNet E2E requires IPv4 VirtualNetwork and transit CIDRs")
if not transit.subnet_of(parent):
    raise SystemExit("saved AgentlessNet transit CIDR is outside the requested VirtualNetwork")

def validate(value, label):
    network = ipaddress.ip_network(value, strict=True)
    if not isinstance(network, ipaddress.IPv4Network) or network.prefixlen > 30 or str(network) != value:
        raise SystemExit(f"{label} must be a canonical IPv4 subnet of /30 or larger")
    if not network.subnet_of(parent):
        raise SystemExit(f"{label} must be inside the requested VirtualNetwork")
    if network.overlaps(transit):
        raise SystemExit(f"{label} overlaps the AgentlessNet transit link")
    return network

if override_one:
    first = validate(override_one, "SUBNET_ONE_IPV4_CIDR")
else:
    first_prefix = max(parent.prefixlen + 1, 24)
    if first_prefix > 30:
        raise SystemExit("VirtualNetwork CIDR is too small for two AgentlessNet test Subnets")
    first = next((candidate for candidate in parent.subnets(new_prefix=first_prefix)
                  if not candidate.overlaps(transit)), None)
    if first is None:
        raise SystemExit("VirtualNetwork CIDR has no first test Subnet outside its transit link")

if override_two:
    second = validate(override_two, "SUBNET_TWO_IPV4_CIDR")
else:
    second = next((candidate for candidate in parent.subnets(new_prefix=first.prefixlen)
                   if not candidate.overlaps(transit) and not candidate.overlaps(first)), None)
    if second is None:
        raise SystemExit("VirtualNetwork CIDR has no second sibling test Subnet outside the transit link")
if first.network_address + 2 >= first.broadcast_address - 1:
    raise SystemExit("The first test Subnet must have DHCP capacity for two clients")
if first.overlaps(second):
    raise SystemExit("AgentlessNet E2E Subnet CIDRs must not overlap")
print(first, second)
PY
    )" || die "Could not select two non-overlapping Subnet CIDRs inside the test VirtualNetwork"
    read -r SUBNET_ONE_IPV4_CIDR SUBNET_TWO_IPV4_CIDR <<<"$subnet_output"
}

resolve_test_subnet_30_cidr() {
    local parent_cidr="$1" transit_cidr="$2" used_cidr="$3" subnet_output
    subnet_output="$(python3 - "$parent_cidr" "$transit_cidr" "$used_cidr" \
        "$SUBNET_THREE_IPV4_CIDR" <<'PY'
import ipaddress
import sys

parent = ipaddress.ip_network(sys.argv[1], strict=True)
transit = ipaddress.ip_network(sys.argv[2], strict=True)
used = ipaddress.ip_network(sys.argv[3], strict=True)
override = sys.argv[4]
if not isinstance(parent, ipaddress.IPv4Network) or not isinstance(transit, ipaddress.IPv4Network):
    raise SystemExit("AgentlessNet E2E requires IPv4 VirtualNetwork and transit CIDRs")
if not used.subnet_of(parent) or used.overlaps(transit):
    raise SystemExit("The active Subnet CIDR is outside its parent or overlaps transit")
if override:
    candidate = ipaddress.ip_network(override, strict=True)
    if not isinstance(candidate, ipaddress.IPv4Network) or candidate.prefixlen != 30 or str(candidate) != override:
        raise SystemExit("SUBNET_THREE_IPV4_CIDR must be a canonical IPv4 /30")
    if not candidate.subnet_of(parent) or candidate.overlaps(transit) or candidate.overlaps(used):
        raise SystemExit("SUBNET_THREE_IPV4_CIDR overlaps an excluded network")
else:
    candidate = next((network for network in parent.subnets(new_prefix=30)
                      if not network.overlaps(transit) and not network.overlaps(used)), None)
    if candidate is None:
        raise SystemExit("VirtualNetwork CIDR has no free /30 test Subnet outside transit and active Subnets")
print(candidate)
PY
    )" || die "Could not select a non-overlapping /30 test Subnet"
    SUBNET_THREE_IPV4_CIDR="$subnet_output"
}

# Preserve the full pre-test JSON snapshot. Only the UIDs created by this run
# are asserted or removed; any unrelated node state remains untouched.
write_agentless_e2e_helpers
HOST_IP_FORWARDING_BEFORE="$(netnode sysctl -n net.ipv4.ip_forward)"
state_snapshot > "$BASELINE_STATE_FILE"
jq -e '(.schema_version == 0 or .schema_version == 1 or .schema_version == 2)
      and (.virtual_networks | type == "array") and (.subnets | type == "array")' \
    "$BASELINE_STATE_FILE" >/dev/null \
    || die "AgentlessNet state must be valid schema v1 or v2 before the test starts"

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
# Deleting a network namespace can remove the host side of its veth pair too.
if netnode ip link show dev "$FIRST_HOST_INTERFACE" >/dev/null 2>&1; then
    netnode ip link delete dev "$FIRST_HOST_INTERFACE"
fi
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

info "Snapshotting existing switch VLAN memberships and reserved ranges before creating sibling Subnets..."
FIRST_ENTRY="$(get_state_entry "$FIRST_K8S_UID")"
FIRST_TRANSIT_CIDR="$(jq -r '.transit.cidr' <<<"$FIRST_ENTRY")"
resolve_test_subnet_cidrs "$VIRTUAL_NETWORK_IPV4_CIDR" "$FIRST_TRANSIT_CIDR"
printf 'test Subnet CIDRs: %s %s\n' "$SUBNET_ONE_IPV4_CIDR" "$SUBNET_TWO_IPV4_CIDR"
snapshot_switch_vlan_state
snapshot_client_access_ports

SUBNET_ONE_OUTPUT="${TEMP_DIR}/create-subnet-one.out"
SUBNET_TWO_OUTPUT="${TEMP_DIR}/create-subnet-two.out"
create_subnet "$SUBNET_ONE_NAME" "$FIRST_FULFILLMENT_ID" \
    "$SUBNET_ONE_IPV4_CIDR" "$SUBNET_ONE_OUTPUT"
SUBNET_ONE_FULFILLMENT_ID="$(cat "${SUBNET_ONE_OUTPUT}.id")"
wait_for_subnet_ready "$SUBNET_ONE_FULFILLMENT_ID" "$FIRST_FULFILLMENT_ID"
SUBNET_ONE_CR="$(subnet_cr_json "$SUBNET_ONE_FULFILLMENT_ID" "$FIRST_FULFILLMENT_ID")"
SUBNET_ONE_K8S_UID="$(jq -r '.metadata.uid' <<<"$SUBNET_ONE_CR")"
SUBNET_ONE_AAP_JOB_ID="$(jq -er '.status.provisioningJobs | map(.jobID // empty) | last' <<<"$SUBNET_ONE_CR")"
wait_for_subnet_aap_provision_success "$SUBNET_ONE_FULFILLMENT_ID" \
    "$FIRST_FULFILLMENT_ID" "$SUBNET_ONE_AAP_JOB_ID"
assert_subnet_state "$SUBNET_ONE_FULFILLMENT_ID" "$FIRST_FULFILLMENT_ID" \
    "$SUBNET_ONE_IPV4_CIDR"

create_subnet "$SUBNET_TWO_NAME" "$FIRST_FULFILLMENT_ID" \
    "$SUBNET_TWO_IPV4_CIDR" "$SUBNET_TWO_OUTPUT"
SUBNET_TWO_FULFILLMENT_ID="$(cat "${SUBNET_TWO_OUTPUT}.id")"
wait_for_subnet_ready "$SUBNET_TWO_FULFILLMENT_ID" "$FIRST_FULFILLMENT_ID"
SUBNET_TWO_CR="$(subnet_cr_json "$SUBNET_TWO_FULFILLMENT_ID" "$FIRST_FULFILLMENT_ID")"
SUBNET_TWO_K8S_UID="$(jq -r '.metadata.uid' <<<"$SUBNET_TWO_CR")"
SUBNET_TWO_AAP_JOB_ID="$(jq -er '.status.provisioningJobs | map(.jobID // empty) | last' <<<"$SUBNET_TWO_CR")"
wait_for_subnet_aap_provision_success "$SUBNET_TWO_FULFILLMENT_ID" \
    "$FIRST_FULFILLMENT_ID" "$SUBNET_TWO_AAP_JOB_ID"
assert_subnet_state "$SUBNET_ONE_FULFILLMENT_ID" "$FIRST_FULFILLMENT_ID" \
    "$SUBNET_ONE_IPV4_CIDR"
assert_subnet_state "$SUBNET_TWO_FULFILLMENT_ID" "$FIRST_FULFILLMENT_ID" \
    "$SUBNET_TWO_IPV4_CIDR"
SUBNET_ONE_ENTRY="$(get_subnet_state_entry "$SUBNET_ONE_K8S_UID")"
SUBNET_TWO_ENTRY="$(get_subnet_state_entry "$SUBNET_TWO_K8S_UID")"
SUBNET_ONE_VLAN_ID="$(jq -r '.vlan_id' <<<"$SUBNET_ONE_ENTRY")"
SUBNET_TWO_VLAN_ID="$(jq -r '.vlan_id' <<<"$SUBNET_TWO_ENTRY")"
[[ "$SUBNET_ONE_VLAN_ID" != "$SUBNET_TWO_VLAN_ID" ]] \
    || die "Sibling Subnets share the same provider VLAN ID"
assert_new_vlans_avoid_baseline "$SUBNET_ONE_VLAN_ID" "$SUBNET_TWO_VLAN_ID"
printf 'Subnet Fulfillment UUIDs: %s %s\n' \
    "$SUBNET_ONE_FULFILLMENT_ID" "$SUBNET_TWO_FULFILLMENT_ID"
printf 'Subnet Kubernetes UIDs: %s %s\n' "$SUBNET_ONE_K8S_UID" "$SUBNET_TWO_K8S_UID"
printf 'Subnet VLAN IDs: %s %s\n' "$SUBNET_ONE_VLAN_ID" "$SUBNET_TWO_VLAN_ID"
save_current_state
assert_baseline_state_unchanged

FIRST_PARENT_NAMESPACE="$(jq -r '.namespace_name' <<<"$FIRST_ENTRY")"
FIRST_SUBNET_VLAN_INTERFACE="$(jq -r '.vlan_interface' <<<"$SUBNET_ONE_ENTRY")"
SECOND_SUBNET_VLAN_INTERFACE="$(jq -r '.vlan_interface' <<<"$SUBNET_TWO_ENTRY")"

info "Attaching three real DHCP clients to the two sibling Subnets..."
create_dhcp_client_containers
configure_client_access_port a1 "$SUBNET_ONE_VLAN_ID"
configure_client_access_port a2 "$SUBNET_ONE_VLAN_ID"
configure_client_access_port b1 "$SUBNET_TWO_VLAN_ID"
start_dhcp_client a1
start_dhcp_client a2
start_dhcp_client b1
write_client_lease_expectations \
    "a1=$SUBNET_ONE_ENTRY" "a2=$SUBNET_ONE_ENTRY" "b1=$SUBNET_TWO_ENTRY"
assert_real_client_leases a1 a2 b1
assert_client_gateway a1 "$SUBNET_ONE_ENTRY"
assert_client_gateway a2 "$SUBNET_ONE_ENTRY"
assert_client_gateway b1 "$SUBNET_TWO_ENTRY"
assert_same_subnet_l2 a1 a2

info "Restarting the VirtualNetwork DHCP service and renewing all clients with their original MAC addresses..."
for client in a1 a2 b1; do
    cp "$TEMP_DIR/client-${client}.lease.json" "$TEMP_DIR/client-${client}.before-restart.json"
done
netnode supervisorctl -c /etc/agentless-net/supervisord.conf \
    restart "agentless-dhcp-${FIRST_K8S_UID}"
service_ready=false
for ((attempt = 1; attempt <= 30; attempt++)); do
    if netnode supervisorctl -c /etc/agentless-net/supervisord.conf \
        status "agentless-dhcp-${FIRST_K8S_UID}" | grep -Fq ' RUNNING '; then
        service_ready=true
        break
    fi
    sleep 1
done
[[ "$service_ready" == true ]] || die "DHCP service did not return to RUNNING after restart"
for client in a1 a2 b1; do
    renew_dhcp_client "$client"
    [[ "$(jq -r '.address' "$TEMP_DIR/client-${client}.lease.json")" == \
        "$(jq -r '.address' "$TEMP_DIR/client-${client}.before-restart.json")" ]] \
        || die "DHCP client $client did not preserve its leased address after service restart"
done
assert_real_client_leases a1 a2 b1
assert_same_subnet_l2 a1 a2
assert_client_gateway a1 "$SUBNET_ONE_ENTRY"
assert_client_gateway b1 "$SUBNET_TWO_ENTRY"

info "Removing only the test-owned Subnet interface and exercising the operator's retry path..."
FIRST_SUBNET_ENTRY_BEFORE_RETRY="$(jq -cS '.' <<<"$SUBNET_ONE_ENTRY")"
link_json="$(netnode ip netns exec "$FIRST_PARENT_NAMESPACE" ip -j -d link show dev "$FIRST_SUBNET_VLAN_INTERFACE")"
jq -e --arg alias "osac-subnet:${SUBNET_ONE_K8S_UID}" --argjson vlan "$SUBNET_ONE_VLAN_ID" '
  length == 1 and .[0].ifalias == $alias and .[0].linkinfo.info_kind == "vlan"
  and (.[0].linkinfo.info_data.id | tonumber) == $vlan' <<<"$link_json" >/dev/null \
    || die "Refusing to remove a Subnet interface without the test UID ownership alias"
FIRST_SUBNET_JOB_BEFORE_RETRY="$SUBNET_ONE_AAP_JOB_ID"
netnode ip netns exec "$FIRST_PARENT_NAMESPACE" ip link delete dev "$FIRST_SUBNET_VLAN_INTERFACE"
oc patch subnet "$(jq -r '.metadata.name' <<<"$SUBNET_ONE_CR")" \
    -n "$NETWORKING_NAMESPACE" --subresource=status --type=merge \
    -p '{"status":{"phase":"Progressing","conditions":[],"provisioningJobs":[]}}' >/dev/null
wait_for_subnet_retry_success "$SUBNET_ONE_FULFILLMENT_ID" \
    "$FIRST_FULFILLMENT_ID" "$FIRST_SUBNET_JOB_BEFORE_RETRY"
SUBNET_ONE_AAP_JOB_ID="$RETRIED_SUBNET_AAP_JOB_ID"
wait_for_subnet_ready "$SUBNET_ONE_FULFILLMENT_ID" "$FIRST_FULFILLMENT_ID"
assert_subnet_state "$SUBNET_ONE_FULFILLMENT_ID" "$FIRST_FULFILLMENT_ID" \
    "$SUBNET_ONE_IPV4_CIDR"
SUBNET_ONE_ENTRY="$(get_subnet_state_entry "$SUBNET_ONE_K8S_UID")"
[[ "$(jq -cS '.' <<<"$SUBNET_ONE_ENTRY")" == "$FIRST_SUBNET_ENTRY_BEFORE_RETRY" ]] \
    || die "Subnet retry did not preserve its UID-owned VLAN and DHCP state"
for client in a1 a2 b1; do renew_dhcp_client "$client"; done
assert_real_client_leases a1 a2 b1
assert_same_subnet_l2 a1 a2
assert_client_gateway a1 "$SUBNET_ONE_ENTRY"
assert_client_gateway b1 "$SUBNET_TWO_ENTRY"

info "Detaching client B1, restoring its access port, then deleting Subnet B while A remains usable..."
SUBNET_TWO_CLIENT_MAC="$(<"$TEMP_DIR/client-b1.mac")"
detach_dhcp_client b1
write_client_lease_expectations "a1=$SUBNET_ONE_ENTRY" "a2=$SUBNET_ONE_ENTRY"
assert_real_client_leases a1 a2
assert_same_subnet_l2 a1 a2
delete_subnet_by_id "$SUBNET_TWO_FULFILLMENT_ID"
SECOND_SUBNET_DELETE_AAP_JOB_ID="$LAST_SUBNET_DELETE_AAP_JOB_ID"
assert_uid_subnet_state_absent "$SUBNET_TWO_K8S_UID" "$FIRST_K8S_UID" \
    "$FIRST_PARENT_NAMESPACE" "$SECOND_SUBNET_VLAN_INTERFACE" "$SUBNET_TWO_VLAN_ID"
assert_deleted_subnet_lease_removed "$SUBNET_TWO_CLIENT_MAC" "$FIRST_K8S_UID"
[[ "$(get_subnet_state_entry "$SUBNET_ONE_K8S_UID" | jq -cS '.')" == \
    "$(jq -cS '.' <<<"$SUBNET_ONE_ENTRY")" ]] \
    || die "Deleting Subnet B altered Subnet A's provider state"
assert_subnet_state "$SUBNET_ONE_FULFILLMENT_ID" "$FIRST_FULFILLMENT_ID" \
    "$SUBNET_ONE_IPV4_CIDR"
assert_real_client_leases a1 a2
assert_same_subnet_l2 a1 a2
assert_client_gateway a1 "$SUBNET_ONE_ENTRY"
save_current_state
assert_baseline_state_unchanged
recreate_dhcp_client_container b1

info "Creating a /30 Subnet and verifying its single DHCP client address..."
resolve_test_subnet_30_cidr "$VIRTUAL_NETWORK_IPV4_CIDR" "$FIRST_TRANSIT_CIDR" \
    "$SUBNET_ONE_IPV4_CIDR"
SUBNET_THREE_OUTPUT="${TEMP_DIR}/create-subnet-30.out"
create_subnet "$SUBNET_THREE_NAME" "$FIRST_FULFILLMENT_ID" \
    "$SUBNET_THREE_IPV4_CIDR" "$SUBNET_THREE_OUTPUT"
SUBNET_THREE_FULFILLMENT_ID="$(cat "${SUBNET_THREE_OUTPUT}.id")"
wait_for_subnet_ready "$SUBNET_THREE_FULFILLMENT_ID" "$FIRST_FULFILLMENT_ID"
SUBNET_THREE_CR="$(subnet_cr_json "$SUBNET_THREE_FULFILLMENT_ID" "$FIRST_FULFILLMENT_ID")"
SUBNET_THREE_K8S_UID="$(jq -r '.metadata.uid' <<<"$SUBNET_THREE_CR")"
SUBNET_THREE_AAP_JOB_ID="$(jq -er '.status.provisioningJobs | map(.jobID // empty) | last' <<<"$SUBNET_THREE_CR")"
wait_for_subnet_aap_provision_success "$SUBNET_THREE_FULFILLMENT_ID" \
    "$FIRST_FULFILLMENT_ID" "$SUBNET_THREE_AAP_JOB_ID"
assert_subnet_state "$SUBNET_THREE_FULFILLMENT_ID" "$FIRST_FULFILLMENT_ID" \
    "$SUBNET_THREE_IPV4_CIDR"
SUBNET_THREE_ENTRY="$(get_subnet_state_entry "$SUBNET_THREE_K8S_UID")"
SUBNET_THREE_VLAN_ID="$(jq -r '.vlan_id' <<<"$SUBNET_THREE_ENTRY")"
SUBNET_THREE_VLAN_INTERFACE="$(jq -r '.vlan_interface' <<<"$SUBNET_THREE_ENTRY")"
[[ "$(jq -r '.dhcp_range_start' <<<"$SUBNET_THREE_ENTRY")" == \
    "$(jq -r '.dhcp_range_end' <<<"$SUBNET_THREE_ENTRY")" ]] \
    || die "The /30 Subnet does not provide exactly one DHCP address"
assert_new_vlans_avoid_baseline "$SUBNET_ONE_VLAN_ID" "$SUBNET_THREE_VLAN_ID"
configure_client_access_port b1 "$SUBNET_THREE_VLAN_ID"
start_dhcp_client b1
write_client_lease_expectations "b1=$SUBNET_THREE_ENTRY"
assert_real_client_leases b1
[[ "$(jq -r '.address' "$TEMP_DIR/client-b1.lease.json")" == \
    "$(jq -r '.dhcp_range_start' <<<"$SUBNET_THREE_ENTRY")" ]] \
    || die "The /30 client did not receive its single available IPv4 address"
assert_client_gateway b1 "$SUBNET_THREE_ENTRY"
printf 'Subnet /30 lease: client=%s address=%s gateway=%s VLAN=%s\n' \
    "$(<"$TEMP_DIR/client-b1.mac")" "$(jq -r '.address' "$TEMP_DIR/client-b1.lease.json")" \
    "$(jq -r '.gateway_ipv4' <<<"$SUBNET_THREE_ENTRY")" "$SUBNET_THREE_VLAN_ID"

info "Detaching B1 and deleting the /30 Subnet while Subnet A remains usable..."
detach_dhcp_client b1
delete_subnet_by_id "$SUBNET_THREE_FULFILLMENT_ID"
THIRD_SUBNET_DELETE_AAP_JOB_ID="$LAST_SUBNET_DELETE_AAP_JOB_ID"
assert_uid_subnet_state_absent "$SUBNET_THREE_K8S_UID" "$FIRST_K8S_UID" \
    "$FIRST_PARENT_NAMESPACE" "$SUBNET_THREE_VLAN_INTERFACE" "$SUBNET_THREE_VLAN_ID"
write_client_lease_expectations "a1=$SUBNET_ONE_ENTRY" "a2=$SUBNET_ONE_ENTRY"
assert_real_client_leases a1 a2
assert_same_subnet_l2 a1 a2
assert_client_gateway a1 "$SUBNET_ONE_ENTRY"
save_current_state
assert_baseline_state_unchanged

info "Detaching A1/A2 and deleting the last Subnet, then verifying DHCP cleanup..."
detach_dhcp_client a1
detach_dhcp_client a2
delete_subnet_by_id "$SUBNET_ONE_FULFILLMENT_ID"
FIRST_SUBNET_DELETE_AAP_JOB_ID="$LAST_SUBNET_DELETE_AAP_JOB_ID"
assert_uid_subnet_state_absent "$SUBNET_ONE_K8S_UID" "$FIRST_K8S_UID" \
    "$FIRST_PARENT_NAMESPACE" "$FIRST_SUBNET_VLAN_INTERFACE" "$SUBNET_ONE_VLAN_ID"
assert_virtual_network_dhcp_absent "$FIRST_K8S_UID" "$FIRST_PARENT_NAMESPACE"
netnode test ! -e "/etc/agentless-net/dhcp/${FIRST_K8S_UID}/dnsmasq.conf" \
    || die "Combined DHCP configuration remains after the VirtualNetwork's last Subnet was deleted"
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

cleanup_dhcp_clients_and_ports \
    || die "Could not remove run-owned DHCP client containers or restore access-port snapshots"
info "Existing-lab AgentlessNet E2E passed: overlapping VirtualNetworks, VN and Subnet retries, internal VLAN exclusion, real DHCP clients and leases, gateway and same-Subnet L2 traffic across leaves, DHCP service restart, /30 lease, peer-preserving lifecycle, and client/port cleanup."
