#!/usr/bin/env bash
# OSAC-5528/OSAC-5530/OSAC-6202/OSAC-6306/OSAC-6307 AgentlessNet development lab:
#   1. Boot or reuse the SNO with cluster-tool.
#   2. Build and push runtime images when source inputs changed, or reuse their tags.
#   3. Install or upgrade OSAC with those custom images.
#   4. Deploy or reuse the Containerlab fabric and initialize its declared trunks.
#   5. Run the selected AgentlessNet developer suite.
# Existing clusters and OSAC releases are reused; this script never destroys
# the SNO or Containerlab topology.
set -euo pipefail
umask 077

VLAN_E2E_SUITE="full"
CLEANUP_MODE=false

usage() {
    cat <<'USAGE'
Usage: bash ./vlan-e2e.sh [--suite SUITE] [--cleanup]

Suites:
  full              Run the complete ExternalIPPool/ExternalIP, VirtualNetwork, and Subnet/DHCP E2E (default).
  virtual-network   Create, verify, and delete one VirtualNetwork.
  subnet-dhcp       Create a parent VirtualNetwork and run the Subnet/DHCP E2E.
  external-ip-pool  Create, verify, and delete one ExternalIPPool.
  external-ip       Verify ExternalIP allocation and ExternalIPAttachment ingress.
  nat-gateway       Verify NATGateway v1 VN-wide SNAT, Subnet independence, retry, and cleanup.

All suites boot or reuse the SNO, deploy or reuse OSAC and the Containerlab
fabric, initialize the declared trunks, and run the selected checks. Set
CUMULUS_VERSION and CUMULUS_VX_IMAGE to the exact guest
release and its Boxen image. CUMULUS_LAB_ADMIN_KEY defaults to the ignored
local lab key path; VLAN_E2E_RUN_DIR optionally retains sanitized run evidence.
Use --cleanup with --suite SUITE (or a suite shorthand) as a standalone command
to remove only test-named resources for that suite through Fulfillment. It
uses the existing lab and exits without deploying or initializing it.
The runner requires a compatible AgentlessNet schema V1 database and preserves
any incompatible existing state. Keep the AgentlessNet state schema at V1 until
OSAC-5528 is complete.
The --external-ip and --full suites use an existing DHCP client as a synthetic
BareMetalInstance target for the AgentlessNet ExternalIPAttachment AAP jobs.
This validates the provider datapath and does not exercise Fulfillment-to-BMaaS
readiness. The ingress probe uses a test-only static route over the direct
Containerlab peer link; it does not test BGP advertisement.
The --nat-gateway suite and --full suite use a test-owned HTTP endpoint on the
upstream-router and a test-only static return route. The endpoint reports the
observed source IPv4 address. This is local VLAN lab validation; it does not
verify remote BGP advertisement/convergence or physical hardware.

Examples:
  bash ./vlan-e2e.sh
  bash ./vlan-e2e.sh --virtual-network
  bash ./vlan-e2e.sh --subnet-dhcp
  bash ./vlan-e2e.sh --external-ip-pool
  bash ./vlan-e2e.sh --external-ip
  bash ./vlan-e2e.sh --nat-gateway
  bash ./vlan-e2e.sh --cleanup --suite full
  bash ./vlan-e2e.sh --cleanup --subnet-dhcp
  bash ./vlan-e2e.sh --cleanup --virtual-network
  bash ./vlan-e2e.sh --cleanup --external-ip-pool
  bash ./vlan-e2e.sh --cleanup --external-ip
  bash ./vlan-e2e.sh --cleanup --nat-gateway
USAGE
}

argument_error() {
    printf 'ERROR: %s\n' "$1" >&2
    usage >&2
    exit 2
}

SUITE_SELECTED=false
while (($# > 0)); do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --cleanup)
            [[ "$CLEANUP_MODE" == false ]] || argument_error "--cleanup may be specified only once"
            CLEANUP_MODE=true
            shift
            ;;
        --suite)
            [[ "$SUITE_SELECTED" == false ]] || argument_error "--suite may be specified only once"
            (($# >= 2)) || argument_error "--suite requires a value"
            case "$2" in
                full|virtual-network|subnet-dhcp|external-ip-pool|external-ip|nat-gateway)
                    VLAN_E2E_SUITE="$2"
                    ;;
                *) argument_error "unsupported suite: $2" ;;
            esac
            SUITE_SELECTED=true
            shift 2
            ;;
        --full|--virtual-network|--subnet-dhcp|--external-ip-pool|--external-ip|--nat-gateway)
            [[ "$SUITE_SELECTED" == false ]] || argument_error "a suite may be specified only once"
            VLAN_E2E_SUITE="${1#--}"
            SUITE_SELECTED=true
            shift
            ;;
        *) argument_error "unexpected argument: $1" ;;
    esac
done

case "$VLAN_E2E_SUITE" in
    full)
        SUITE_USES_VN=true
        SUITE_USES_SUBNET=true
        SUITE_USES_SUBNET_DHCP=true
        SUITE_USES_POOL=true
        SUITE_USES_CLI=true
        SUITE_USES_EXTERNAL_IP=true
        SUITE_USES_EXTERNAL_IP_ATTACHMENT=true
        SUITE_USES_NAT_GATEWAY=true
        ;;
    virtual-network)
        SUITE_USES_VN=true
        SUITE_USES_SUBNET=false
        SUITE_USES_SUBNET_DHCP=false
        SUITE_USES_POOL=false
        SUITE_USES_CLI=true
        SUITE_USES_EXTERNAL_IP=false
        SUITE_USES_EXTERNAL_IP_ATTACHMENT=false
        SUITE_USES_NAT_GATEWAY=false
        ;;
    subnet-dhcp)
        SUITE_USES_VN=true
        SUITE_USES_SUBNET=true
        SUITE_USES_SUBNET_DHCP=true
        SUITE_USES_POOL=false
        SUITE_USES_CLI=true
        SUITE_USES_EXTERNAL_IP=false
        SUITE_USES_EXTERNAL_IP_ATTACHMENT=false
        SUITE_USES_NAT_GATEWAY=false
        ;;
    external-ip-pool)
        SUITE_USES_VN=false
        SUITE_USES_SUBNET=false
        SUITE_USES_SUBNET_DHCP=false
        SUITE_USES_POOL=true
        SUITE_USES_CLI=false
        SUITE_USES_EXTERNAL_IP=false
        SUITE_USES_EXTERNAL_IP_ATTACHMENT=false
        SUITE_USES_NAT_GATEWAY=false
        ;;
    external-ip)
        SUITE_USES_VN=true
        SUITE_USES_SUBNET=true
        SUITE_USES_SUBNET_DHCP=true
        SUITE_USES_POOL=true
        SUITE_USES_CLI=true
        SUITE_USES_EXTERNAL_IP=true
        SUITE_USES_EXTERNAL_IP_ATTACHMENT=true
        SUITE_USES_NAT_GATEWAY=false
        ;;
    nat-gateway)
        SUITE_USES_VN=true
        SUITE_USES_SUBNET=true
        SUITE_USES_SUBNET_DHCP=true
        SUITE_USES_POOL=true
        SUITE_USES_CLI=true
        SUITE_USES_EXTERNAL_IP=true
        SUITE_USES_EXTERNAL_IP_ATTACHMENT=false
        SUITE_USES_NAT_GATEWAY=true
        ;;
esac

SUITE_USES_EXTERNAL_ROUTING=false
if [[ "$SUITE_USES_EXTERNAL_IP_ATTACHMENT" == true || "$SUITE_USES_NAT_GATEWAY" == true ]]; then
    SUITE_USES_EXTERNAL_ROUTING=true
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AAP_DIR="${REPO_ROOT}/osac-aap"
INSTALLER_DIR="${REPO_ROOT}/osac-installer"
FABRIC_DIR="${REPO_ROOT}/tests/e2e/agentless_net/lab"
AAP_JOBS_HELPER="${FABRIC_DIR}/aap_jobs.py"
CONTAINERLAB_TOPOLOGY="${FABRIC_DIR}/agentless-net-lab.clab.yml"
CONTAINERLAB_INVENTORY="${FABRIC_DIR}/inventory.yml"
CONTAINERLAB_CONFIGURE_PLAYBOOK="${FABRIC_DIR}/configure_network.yml"
CONTAINERLAB_NAME="agentless-net-lab"
CONTAINERLAB_PREFIX="clab-${CONTAINERLAB_NAME}"
CONTAINERLAB_NET_NODE="${CONTAINERLAB_PREFIX}-net-node"
CONTAINERLAB_UPSTREAM_ROUTER="${CONTAINERLAB_PREFIX}-upstream-router"
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
CUMULUS_VERSION="${CUMULUS_VERSION:-}"
CUMULUS_VX_IMAGE="${CUMULUS_VX_IMAGE:-}"
CUMULUS_LAB_ADMIN_KEY="${CUMULUS_LAB_ADMIN_KEY:-${REPO_ROOT}/.artifacts/agentless-net-lab/admin_ed25519}"
CUMULUS_SSH_CONFIG_FILE="${REPO_ROOT}/.artifacts/agentless-net-lab/ssh_config"
CUMULUS_STARTUP_CONFIG=""
CUMULUS_ADMIN_PUBLIC_KEY_FILE=""
CUMULUS_ADMIN_NVUE_KEY_ID="osac-agentless-e2e-admin"
CUMULUS_IMAGE_ID=""
CUMULUS_IMAGE_PROVENANCE_FILE="${CUMULUS_IMAGE_PROVENANCE_FILE:-}"
VLAN_E2E_RUN_DIR="${VLAN_E2E_RUN_DIR:-}"

CONTAINER_TOOL="${CONTAINER_TOOL:-podman}"
# auto reuses images tagged for the latest commit outside this runner; true/false force reuse/build.
REUSE_PREBUILT_OSAC_IMAGES="${REUSE_PREBUILT_OSAC_IMAGES:-auto}"
CLIENT_IMAGE="${CLIENT_IMAGE:-busybox:1.36.1}"
VLAN_E2E_DEBUG="${VLAN_E2E_DEBUG:-false}"
VLAN_E2E_ARTIFACT_DIR="${VLAN_E2E_ARTIFACT_DIR:-}"
DHCP_CLIENT_PREFIX="${DHCP_CLIENT_PREFIX:-osac5530-$(date -u +%Y%m%d%H%M%S)}"
IMPLEMENTATION_BRANCH_NAME="osac-6202-natgateway-snat"
CURRENT_BRANCH="$(git -C "$REPO_ROOT" branch --show-current)"
if [[ "$CURRENT_BRANCH" != e2e ]]; then
    printf 'ERROR: run vlan-e2e.sh from the e2e branch; current branch is %s\n' "$CURRENT_BRANCH" >&2
    exit 1
fi

resolve_runtime_source() {
    local repo="$1" implementation_branch="$2" source_commit
    source_commit="$(git -C "$repo" rev-parse --verify \
        "refs/heads/${implementation_branch}^{commit}" 2>/dev/null)" || return 1
    git -C "$repo" merge-base --is-ancestor "$source_commit" HEAD || return 1
    local source_branch="$implementation_branch"
    printf '%s\n%s\n' "$source_branch" "$source_commit"
}

if ! RUNTIME_SOURCE_INFO="$(resolve_runtime_source "$REPO_ROOT" "$IMPLEMENTATION_BRANCH_NAME")"; then
    printf 'ERROR: e2e must include local implementation branch %s\n' \
        "$IMPLEMENTATION_BRANCH_NAME" >&2
    exit 1
fi
mapfile -t RUNTIME_SOURCE_FIELDS <<<"$RUNTIME_SOURCE_INFO"
RUNTIME_SOURCE_BRANCH="${RUNTIME_SOURCE_FIELDS[0]}"
RUNTIME_SOURCE_COMMIT="${RUNTIME_SOURCE_FIELDS[1]}"
# When the base branch advances, require its production source to remain exactly
# represented in e2e before using that branch for images and the AAP project.
for runtime_path in osac-aap osac-operator fulfillment-service proto osac-installer bare-metal-fulfillment-operator; do
    if ! git -C "$REPO_ROOT" diff --quiet "$RUNTIME_SOURCE_COMMIT" HEAD -- "$runtime_path"; then
        printf 'ERROR: production source under %s differs from the selected runtime branch\n' \
            "$runtime_path" >&2
        exit 1
    fi
    if [[ -n "$(git -C "$REPO_ROOT" ls-files --others --exclude-standard -- "$runtime_path")" ]]; then
        printf 'ERROR: untracked production source exists under %s\n' "$runtime_path" >&2
        exit 1
    fi
    if ! git -C "$REPO_ROOT" diff --quiet HEAD -- "$runtime_path" \
        || ! git -C "$REPO_ROOT" diff --cached --quiet HEAD -- "$runtime_path"; then
        printf 'ERROR: production source under %s has uncommitted changes\n' "$runtime_path" >&2
        exit 1
    fi
done
IMAGE_SOURCE_COMMIT="$RUNTIME_SOURCE_COMMIT"
IMAGE_SOURCE_SHORT="${IMAGE_SOURCE_COMMIT:0:12}"
AAP_IMAGE="${AAP_IMAGE:-quay.io/ybettan/osac-aap:osac-5530-${IMAGE_SOURCE_SHORT}}"
OPERATOR_IMAGE="${OPERATOR_IMAGE:-quay.io/ybettan/osac-operator:osac-5530-${IMAGE_SOURCE_SHORT}}"
FULFILLMENT_IMAGE="${FULFILLMENT_IMAGE:-quay.io/ybettan/fulfillment-service:osac-6307-${IMAGE_SOURCE_SHORT}}"
OPERATOR_IMAGE_REPOSITORY="${OPERATOR_IMAGE%:*}"
OPERATOR_IMAGE_TAG="${OPERATOR_IMAGE##*:}"
FULFILLMENT_IMAGE_REPOSITORY="${FULFILLMENT_IMAGE%:*}"
FULFILLMENT_IMAGE_TAG="${FULFILLMENT_IMAGE##*:}"
AAP_PROJECT_GIT_URI="${AAP_PROJECT_GIT_URI:-https://github.com/ybettan/osac}"
AAP_PROJECT_GIT_BRANCH="${AAP_PROJECT_GIT_BRANCH:-${RUNTIME_SOURCE_BRANCH}}"
AAP_PREFIX="${AAP_PREFIX:-${AAP_ORGANIZATION_NAME:-osac}}"
AAP_PROJECT_NAME="${AAP_PROJECT_NAME:-${AAP_PREFIX}}"
# AAP executes the exact selected implementation commit. Runner-only commits
# never change the runtime project revision or image tags.
AAP_PROJECT_EXPECTED_REVISION="${AAP_PROJECT_EXPECTED_REVISION:-${RUNTIME_SOURCE_COMMIT}}"

OSAC_NAMESPACE="${OSAC_NAMESPACE:-osac-e2e-ci}"
OSAC_TENANT="${OSAC_TENANT:-osac-e2e-ci}"
OSAC_SERVICE_ACCOUNT="${OSAC_SERVICE_ACCOUNT:-osac-operator}"
OSAC_BMAAS_NAMESPACE="${OSAC_BMAAS_NAMESPACE:-osac-baremetalinstance}"
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
AAP_JOB_TIMEOUT="${AAP_JOB_TIMEOUT:-1800}"
AAP_JOB_RESULT_SEQUENCE=0
AAP_SSH_KEY_SECRET_KEY="AGENTLESS_NET_SSH_PRIVATE_KEY"
AAP_SSH_KEY_SECRET_ANNOTATION="osac.openshift.io/agentless-vn-ssh"
AAP_SUBNET_READER_NAME="vlan-e2e-subnet-reader"
AAP_SUBNET_LOCK_NAME="vlan-e2e-subnet-lock"
AAP_SUBNET_READER_CREDENTIAL_TYPE="OSAC VLAN E2E Kubernetes API"
AAP_SUBNET_READER_CREDENTIAL="vlan-e2e-subnet-reader"
AAP_SUBNET_READER_SETUP_ATTEMPTED=false
VIRTUAL_NETWORK_NAME_INPUT="${VIRTUAL_NETWORK_NAME:-}"
VIRTUAL_NETWORK_NAME="${VIRTUAL_NETWORK_NAME:-agentless-smoke-vn-$(date -u +%Y%m%d%H%M%S)}"
PEER_VIRTUAL_NETWORK_NAME="${PEER_VIRTUAL_NETWORK_NAME:-${VIRTUAL_NETWORK_NAME}-peer}"
VIRTUAL_NETWORK_IPV4_CIDR="${VIRTUAL_NETWORK_IPV4_CIDR:-10.250.0.0/16}"
SUBNET_ONE_NAME="${SUBNET_ONE_NAME:-${VIRTUAL_NETWORK_NAME}-subnet-a}"
SUBNET_TWO_NAME="${SUBNET_TWO_NAME:-${VIRTUAL_NETWORK_NAME}-subnet-b}"
SUBNET_THREE_NAME="${SUBNET_THREE_NAME:-${VIRTUAL_NETWORK_NAME}-subnet-30}"
EXTERNAL_IP_ATTACHMENT_SUBNET_NAME="${VIRTUAL_NETWORK_NAME}-eip-subnet"
EXTERNAL_IP_ATTACHMENT_SUBNET_CIDR="${OSAC_EIA_SUBNET_IPV4_CIDR:-}"
SUBNET_ONE_IPV4_CIDR_EXPLICIT=false
SUBNET_TWO_IPV4_CIDR_EXPLICIT=false
if [[ -n "${SUBNET_ONE_IPV4_CIDR:-}" ]]; then
    SUBNET_ONE_IPV4_CIDR_EXPLICIT=true
fi
if [[ -n "${SUBNET_TWO_IPV4_CIDR:-}" ]]; then
    SUBNET_TWO_IPV4_CIDR_EXPLICIT=true
fi
SUBNET_ONE_IPV4_CIDR="${SUBNET_ONE_IPV4_CIDR:-}"
SUBNET_TWO_IPV4_CIDR="${SUBNET_TWO_IPV4_CIDR:-}"
SUBNET_THREE_IPV4_CIDR="${SUBNET_THREE_IPV4_CIDR:-}"
EXTERNAL_IP_POOL_CIDR_EXPLICIT=false
if [[ -n "${EXTERNAL_IP_POOL_CIDR:-}" ]]; then
    EXTERNAL_IP_POOL_CIDR_EXPLICIT=true
fi
EXTERNAL_IP_POOL_NAME="agentless-e2e-pool-$(date -u +%Y%m%d%H%M%S)-$$"
EXTERNAL_IP_POOL_CIDR="${EXTERNAL_IP_POOL_CIDR:-198.51.100.0/24}"
EXTERNAL_IP_POOL_CIDR_RESOLVED=false
EXTERNAL_IP_PREFIX="agentless-eip-$(date -u +%Y%m%d%H%M%S)-$$"
EXTERNAL_IP_ONE_NAME="${EXTERNAL_IP_PREFIX}-a"
EXTERNAL_IP_TWO_NAME="${EXTERNAL_IP_PREFIX}-b"
EXTERNAL_IP_ATTACHMENT_PREFIX="agentless-eip-attach-$(date -u +%Y%m%d%H%M%S)-$$"
EXTERNAL_IP_ATTACHMENT_ONE_NAME="${EXTERNAL_IP_ATTACHMENT_PREFIX}-a"
EXTERNAL_IP_ATTACHMENT_TWO_NAME="${EXTERNAL_IP_ATTACHMENT_PREFIX}-b"
NAT_GATEWAY_PREFIX="agentless-natgw-$(date -u +%Y%m%d%H%M%S)-$$"
NAT_GATEWAY_ONE_NAME="${NAT_GATEWAY_PREFIX}-a"
NAT_GATEWAY_TWO_NAME="${NAT_GATEWAY_PREFIX}-b"
NAT_GATEWAY_SUBNET_ONE_NAME="${VIRTUAL_NETWORK_NAME}-natgw-subnet-a"
NAT_GATEWAY_SUBNET_TWO_NAME="${VIRTUAL_NETWORK_NAME}-natgw-subnet-b"
NAT_GATEWAY_PEER_SUBNET_NAME="${PEER_VIRTUAL_NETWORK_NAME}-natgw-subnet-a"
NAT_GATEWAY_SUBNET_ONE_CIDR=""
NAT_GATEWAY_SUBNET_TWO_CIDR=""
NAT_GATEWAY_ONE_ID=""
NAT_GATEWAY_TWO_ID=""
NAT_GATEWAY_ONE_UID=""
NAT_GATEWAY_TWO_UID=""
NAT_GATEWAY_ONE_ADDRESS=""
NAT_GATEWAY_TWO_ADDRESS=""
NAT_GATEWAY_ONE_SUBNET_ID=""
NAT_GATEWAY_ONE_SUBNET_UID=""
NAT_GATEWAY_TWO_SUBNET_ID=""
NAT_GATEWAY_TWO_SUBNET_UID=""
NAT_GATEWAY_ONE_INITIAL_STATE=""
NAT_GATEWAY_TWO_INITIAL_STATE=""
LAST_NAT_GATEWAY_JOB_ID=""
LAST_NAT_GATEWAY_STATE=""
LAST_NAT_GATEWAY_CLEANUP_JOB_ID=""
EXTERNAL_IP_SYNTHETIC_CLIENT="a1"
EXTERNAL_IP_SYNTHETIC_TARGET_NAME="vlan-e2e-synthetic-dhcp-target"
EXTERNAL_IP_SYNTHETIC_TARGET_ID=""
EXTERNAL_IP_SYNTHETIC_TARGET_UID=""
EXTERNAL_IP_SYNTHETIC_TARGET_IP=""
EXTERNAL_IP_RESPONSE_PORT="${OSAC_EIA_RESPONSE_PORT:-18080}"
EXTERNAL_IP_RESPONSE_TOKEN=""
EXTERNAL_IP_CLIENT_ROUTE_GATEWAY=""
EXTERNAL_IP_UPLINK_INTERFACE="eth2"
EXTERNAL_IP_CLIENT_ROUTE_INTERFACE="eth1"
EXTERNAL_IP_TEST_LINK_NODE_ADDRESS="192.0.2.1"
EXTERNAL_IP_TEST_LINK_CLIENT_ADDRESS="192.0.2.2"
EXTERNAL_IP_CLIENT_ROUTE_ADDRESSES=()
NAT_GATEWAY_RESPONSE_PORT="${OSAC_NAT_GATEWAY_RESPONSE_PORT:-18081}"
NAT_GATEWAY_RESPONSE_TOKEN=""
NAT_GATEWAY_ENDPOINT_CONTAINER=""
NAT_GATEWAY_ENDPOINT_CREATED_BY_RUN=false
NAT_GATEWAY_UPLINK_CHANGED_BY_RUN=false
NAT_GATEWAY_UPLINK_BACKUP=""
NAT_GATEWAY_UPLINK_EXPECTED=""
NAT_GATEWAY_UPLINK_OWNER=""
NAT_GATEWAY_UPLINK_OWNER_ANNOTATION="osac.openshift.io/vlan-e2e-natgw-uplink-owner"
NAT_GATEWAY_UPLINK_BACKUP_ANNOTATION="osac.openshift.io/vlan-e2e-natgw-uplink-original"
CLEANUP_EIP_ADDRESSES=()

CLI_BIN="${OSAC_CLI_BIN:-}"
CLI_CONFIG_DIR="${OSAC_CLI_CONFIG_DIR:-}"
CLI_CA_FILE=""
AAP_API_CA_FILE=""
TEMP_DIR=""
GENERATED_CLI_BIN=false
GENERATED_CLI_CONFIG=false
CREATED_IDS=()
CREATED_SUBNET_IDS=()
CREATED_EXTERNAL_IP_IDS=()
CREATED_EXTERNAL_IP_ATTACHMENT_IDS=()
CREATED_NAT_GATEWAY_IDS=()
CREATED_NAT_GATEWAY_UIDS=()
CREATED_SYNTHETIC_EXTERNAL_IP_ATTACHMENT_IDS=()
CREATED_SYNTHETIC_EXTERNAL_IP_ATTACHMENT_UIDS=()
CREATED_BARE_METAL_INSTANCE_IDS=()
CLEANUP_VN_UIDS=()
CLEANUP_SUBNET_UIDS=()
CLEANUP_ATTACHMENT_UIDS=()
CLEANUP_ATTACHMENT_IDS=()
CLEANUP_NAT_GATEWAY_IDS=()
CLEANUP_NAT_GATEWAY_UIDS=()
CLEANUP_SYNTHETIC_ATTACHMENT_UIDS=()
CLEANUP_SYNTHETIC_ATTACHMENT_IDS=()
CLEANUP_BMI_IDS=()
CLEANUP_BMI_UIDS=()
CLEANUP_POOL_UIDS=()
CLEANUP_POOL_IDS=()
CLEANUP_POOL_CIDRS=()
CLEANUP_POOL_EIP_IDS_JSON=()
CLEANUP_EIP_UIDS=()
CLEANUP_EIP_IDS=()
CLEANUP_PENDING_POOL_IDS=()
CLEANUP_STATE_FILE=""
CLEANUP_DISCOVERY_COMPLETE=false
CLEANUP_CLIENTS_COMPLETE=true
STALE_RECOVERY_DIRS=()
EXTERNAL_IP_POOL_ID=""
EXTERNAL_IP_POOL_K8S_UID=""
EXTERNAL_IP_POOL_INITIAL_ENTRY=""
EXTERNAL_IP_POOL_CREATE_AAP_JOB_ID=""
EXTERNAL_IP_POOL_DELETE_AAP_JOB_ID=""
EXTERNAL_IP_POOL_PENDING_CLEANUP=false
EXTERNAL_IP_POOL_INITIAL_ALLOCATED=0
EXTERNAL_IP_POOL_INITIAL_AVAILABLE=0
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
RUN_DIR_CREATED=false
RUN_STARTED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PROVIDER_NVUE_KEY_ID="osac_e2e_$(date -u +%s)_$$"
CUMULUS_SSH_CONFIG_CREATED_BY_RUN=false
CURRENT_STAGE="startup"
SUPERVISOR_CONFIG_CREATED_BY_RUN=false
SUPERVISOR_DAEMON_STARTED_BY_RUN=false
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
declare -A SWITCH_NVUE_KEY_INSTALLED_BY_RUN=()
declare -A SWITCH_SUDOERS_CREATED_BY_RUN=()
declare -A CLIENT_BMI_UID=()
declare -A CLIENT_ATTACHMENT_ACTIVE=()
declare -A CLIENT_ATTACHMENT_PENDING=()
declare -A CLIENT_ATTACHMENT_SUBNET=()
declare -A CLIENT_PRESERVED_MAC=()
INVENTORY_CONFIGMAP_CHANGED_BY_RUN=false
INVENTORY_CONFIGMAP_BACKUP=""
INVENTORY_CONFIGMAP_EXPECTED=""
PRESERVE_E2E_RECOVERY_ARTIFACTS=false
PREEXISTING_PROVIDER_CLEANUP_PENDING=false
AAP_API_ROUTE=""
UPGRADE_VALUES_FILE=""

info() { printf '==> %s\n' "$*"; }
step() {
    CURRENT_STAGE="$*"
    printf '\n========================\n%s\n=============================\n' "$*"
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

label_selector() { printf 'osac.openshift.io/virtualnetwork-uuid=%s' "$1"; }
subnet_label_selector() { printf 'osac.openshift.io/subnet-uuid=%s' "$1"; }
external_ip_pool_label_selector() { printf 'osac.openshift.io/externalippool-uuid=%s' "$1"; }
external_ip_label_selector() { printf 'osac.openshift.io/externalip-uuid=%s' "$1"; }
external_ip_attachment_label_selector() { printf 'osac.openshift.io/externalipattachment-uuid=%s' "$1"; }
nat_gateway_label_selector() { printf 'osac.openshift.io/natgateway-uuid=%s' "$1"; }
baremetal_instance_label_selector() { printf 'osac.openshift.io/baremetalinstance-uuid=%s' "$1"; }

assert_provider_schema_v1() {
    python3 - "$AAP_DIR/collections/ansible_collections/osac/templates/plugins/module_utils/agentless_net_state.py" <<'PY'
import ast
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
try:
    tree = ast.parse(source.read_text(encoding="utf-8"))
except (OSError, SyntaxError) as error:
    raise SystemExit(f"could not read the AgentlessNet state source: {error}") from error

versions = []
for node in tree.body:
    if not isinstance(node, ast.Assign):
        continue
    if any(isinstance(target, ast.Name) and target.id == "SCHEMA_VERSION" for target in node.targets):
        try:
            versions.append(ast.literal_eval(node.value))
        except (TypeError, ValueError) as error:
            raise SystemExit("AgentlessNet SCHEMA_VERSION must be a literal integer") from error

if versions != [1]:
    raise SystemExit(f"AgentlessNet SCHEMA_VERSION must remain 1 until OSAC-5528 is complete; found {versions!r}")
PY
}

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
    raise SystemExit("the Containerlab management network requires an IPv4 /24")
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
    annotation="$(jq -r --arg key "$AAP_SSH_KEY_SECRET_ANNOTATION" \
        '.metadata.annotations[$key] // ""' <<<"$secret_json")"
    if jq -e --arg key "$AAP_SSH_KEY_SECRET_KEY" '.data | has($key)' \
        <<<"$secret_json" >/dev/null; then
        SSH_KEY_EXPECTED_BASE64="$(jq -r --arg key "$AAP_SSH_KEY_SECRET_KEY" \
            '.data[$key]' <<<"$secret_json")"
        printf '%s' "$SSH_KEY_EXPECTED_BASE64" \
            | base64 -d >"$key_file"
        chmod 0600 "$key_file"
        if [[ "$annotation" == OSAC-5529 ]]; then
            SSH_KEY_CREATED_BY_RUN=true
            SSH_KEY_ORIGINAL_ANNOTATION=""
        fi
    else
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

ensure_cumulus_admin_identity() {
    local key_dir key_mode dir_mode public_key existing_switch
    key_dir="$(dirname "$CUMULUS_LAB_ADMIN_KEY")"
    if [[ ! -s "$CUMULUS_LAB_ADMIN_KEY" ]]; then
        for existing_switch in "${CONTAINERLAB_PREFIX}-leaf-1" "${CONTAINERLAB_PREFIX}-leaf-2"; do
            if docker inspect "$existing_switch" >/dev/null 2>&1; then
                die "Cumulus admin key is missing while $existing_switch exists; set CUMULUS_LAB_ADMIN_KEY to its original key or recover the guest before continuing"
            fi
        done
        mkdir -p -- "$key_dir"
        chmod 0700 "$key_dir"
        ssh-keygen -q -t ed25519 -N '' -C osac-agentless-lab-admin -f "$CUMULUS_LAB_ADMIN_KEY"
        chmod 0600 "$CUMULUS_LAB_ADMIN_KEY"
    fi
    [[ -f "$CUMULUS_LAB_ADMIN_KEY" && ! -L "$CUMULUS_LAB_ADMIN_KEY" ]] \
        || die "CUMULUS_LAB_ADMIN_KEY must be a regular private-key file"
    [[ -d "$key_dir" && ! -L "$key_dir" ]] \
        || die "The CUMULUS_LAB_ADMIN_KEY parent must be a regular directory"
    dir_mode="$(stat -c '%a' "$key_dir")" \
        || die "Could not inspect the CUMULUS_LAB_ADMIN_KEY parent directory"
    [[ "$dir_mode" =~ ^[0-7]{3,4}$ ]] \
        || die "Could not parse the CUMULUS_LAB_ADMIN_KEY parent permissions"
    (( (8#$dir_mode & 077) == 0 )) \
        || die "The CUMULUS_LAB_ADMIN_KEY parent directory must not be accessible by group or other users"
    key_mode="$(stat -c '%a' "$CUMULUS_LAB_ADMIN_KEY")" \
        || die "Could not inspect CUMULUS_LAB_ADMIN_KEY permissions"
    [[ "$key_mode" =~ ^[0-7]{3,4}$ ]] \
        || die "Could not parse CUMULUS_LAB_ADMIN_KEY permissions"
    (( (8#$key_mode & 077) == 0 )) \
        || die "CUMULUS_LAB_ADMIN_KEY must not be accessible by group or other users"
    public_key="$(ssh-keygen -y -f "$CUMULUS_LAB_ADMIN_KEY" 2>/dev/null)" \
        || die "Could not read CUMULUS_LAB_ADMIN_KEY; encrypted or invalid keys are unsupported"
    CUMULUS_ADMIN_PUBLIC_KEY_FILE="$TEMP_DIR/cumulus-admin.pub"
    printf '%s\n' "$public_key" >"$CUMULUS_ADMIN_PUBLIC_KEY_FILE"
    chmod 0600 "$CUMULUS_ADMIN_PUBLIC_KEY_FILE"
}

prepare_cumulus_startup_config() {
    [[ -s "$CUMULUS_ADMIN_PUBLIC_KEY_FILE" ]] \
        || die "Cumulus administrator public key is unavailable for startup configuration"
    CUMULUS_STARTUP_CONFIG="$TEMP_DIR/cumulus-startup.cfg"
    python3 - "$CUMULUS_ADMIN_PUBLIC_KEY_FILE" "$CUMULUS_STARTUP_CONFIG" <<'PY'
import pathlib
import shlex
import sys

public_key = pathlib.Path(sys.argv[1]).read_text().strip()
key_literal = shlex.quote(public_key)
commands = [
    "install -d -m 0700 /home/cumulus/.ssh",
    "touch /home/cumulus/.ssh/authorized_keys",
    f"grep -Fqx -- {key_literal} /home/cumulus/.ssh/authorized_keys || printf '%s\\n' {key_literal} >> /home/cumulus/.ssh/authorized_keys",
    "chmod 0600 /home/cumulus/.ssh/authorized_keys",
]
pathlib.Path(sys.argv[2]).write_text("\n".join(commands) + "\n")
PY
    chmod 0600 "$CUMULUS_STARTUP_CONFIG"
}

write_cumulus_ssh_config() {
    local provider_key="${SSH_PRIVATE_KEY_FILE:-}"
    local known_hosts_file="${TEMP_DIR}/known_hosts"
    [[ ! -L "$CUMULUS_SSH_CONFIG_FILE" ]] \
        || die "Cumulus SSH config path must not be a symlink: $CUMULUS_SSH_CONFIG_FILE"
    [[ ! -e "$CUMULUS_SSH_CONFIG_FILE" || -f "$CUMULUS_SSH_CONFIG_FILE" ]] \
        || die "Cumulus SSH config path is not a regular file: $CUMULUS_SSH_CONFIG_FILE"
    mkdir -p -- "$(dirname "$CUMULUS_SSH_CONFIG_FILE")"
    chmod 0700 "$(dirname "$CUMULUS_SSH_CONFIG_FILE")"
    python3 - "$SWITCH_MANIFEST_FILE" "$CONTAINERLAB_PREFIX" \
        "$CUMULUS_LAB_ADMIN_KEY" "$provider_key" "$known_hosts_file" \
        "$CUMULUS_SSH_CONFIG_FILE" <<'PY'
import json
import pathlib
import sys

manifest_path, prefix, admin_key, provider_key, known_hosts, output_path = sys.argv[1:]
manifest = json.loads(pathlib.Path(manifest_path).read_text())
if not isinstance(manifest, dict) or not isinstance(manifest.get("switches"), list):
    raise SystemExit("switch manifest must contain a switches array")

def config_value(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

lines = []
for switch in manifest["switches"]:
    name = switch["name"]
    expected_prefix = prefix + "-"
    if not name.startswith(expected_prefix):
        raise SystemExit(f"switch name does not match Containerlab topology: {name}")
    node = name[len(expected_prefix):]
    if node not in ("leaf-1", "leaf-2"):
        raise SystemExit(f"unsupported Cumulus switch alias: {node}")
    for identity, key_path in (("admin", admin_key), ("provider", provider_key)):
        if identity == "provider" and not key_path:
            continue
        alias = f"osac-agentless-{node}-{identity}"
        lines.extend(
            [
                f"Host {alias}",
                f"  HostName {switch['ansible_host']}",
                f"  User {switch['ansible_user']}",
                f"  Port {switch['ansible_port']}",
                f"  IdentityFile {config_value(key_path)}",
                "  IdentitiesOnly yes",
                "  BatchMode yes",
                "  ConnectTimeout 5",
                "  StrictHostKeyChecking accept-new",
                f"  UserKnownHostsFile {config_value(known_hosts)}",
                "  LogLevel ERROR",
                "",
            ]
        )
path = pathlib.Path(output_path)
path.write_text("\n".join(lines))
path.chmod(0o600)
PY
    chmod 0600 "$CUMULUS_SSH_CONFIG_FILE"
    CUMULUS_SSH_CONFIG_CREATED_BY_RUN=true
}

switch_ssh() {
    local identity="$1" use_sudo="$2" switch="$3" node alias remote_command
    shift 3
    node="${switch#${CONTAINERLAB_PREFIX}-}"
    [[ "$node" == leaf-1 || "$node" == leaf-2 ]] \
        || die "Unknown Cumulus guest in switch manifest: $switch"
    alias="osac-agentless-${node}-${identity}"
    remote_command="$(python3 - "$use_sudo" "$@" <<'PY'
import shlex
import sys

use_sudo = sys.argv[1] == "true"
args = sys.argv[2:]
if not args:
    raise SystemExit("switch command is empty")
if use_sudo:
    args = ["sudo", "-n", *args]
print(" ".join(shlex.quote(arg) for arg in args))
PY
)" || return 1
    [[ -n "$remote_command" ]] || return 1
    ssh -F "$CUMULUS_SSH_CONFIG_FILE" "$alias" "$remote_command" </dev/null
}

switch_exec() {
    local switch="$1"
    shift
    switch_ssh provider true "$switch" "$@"
}

switch_provider_user_exec() {
    local switch="$1"
    shift
    switch_ssh provider false "$switch" "$@"
}

switch_admin_exec() {
    local switch="$1"
    shift
    switch_ssh admin true "$switch" "$@"
}

switch_admin_user_exec() {
    local switch="$1"
    shift
    switch_ssh admin false "$switch" "$@"
}

switch_nvue_diff() {
    local identity="$1" switch="$2" output="" status=0
    case "$identity" in
        admin)
            if output="$(switch_admin_user_exec "$switch" nv config diff --output commands)"; then
                status=0
            else
                status=$?
            fi
            ;;
        provider)
            if output="$(switch_exec "$switch" nv config diff --output commands)"; then
                status=0
            else
                status=$?
            fi
            ;;
        *) return 2 ;;
    esac
    if [[ -n "$output" ]]; then
        printf '%s' "$output"
        return 0
    fi
    return "$status"
}

assert_provider_key_survived() {
    local context="$1" target_switch="${2:-}" switch key_config found_target=false
    while IFS= read -r switch; do
        [[ -n "$switch" ]] || continue
        [[ -z "$target_switch" || "$switch" == "$target_switch" ]] || continue
        [[ "$switch" != "$target_switch" ]] || found_target=true
        info "Provider-key checkpoint after ${context}: inspecting ${switch}."
        key_config="$(switch_admin_user_exec "$switch" nv show system aaa user cumulus ssh authorized-key --output json)" \
            || die "Could not inspect the provider NVUE key after ${context} on ${switch}"
        jq -e --arg id "$PROVIDER_NVUE_KEY_ID" 'has($id)' <<<"$key_config" >/dev/null \
            || die "Per-run provider NVUE key disappeared after ${context} on ${switch}"
        switch_provider_user_exec "$switch" sudo -n true \
            || die "Per-run provider SSH failed after ${context} on ${switch}"
        info "Provider-key checkpoint after ${context} passed on ${switch}."
    done < <(jq -r '.switches[].name' "$SWITCH_MANIFEST_FILE")
    if [[ -n "$target_switch" ]]; then
        [[ "$found_target" == true ]] \
            || die "Provider-key checkpoint target ${target_switch} is not in the switch manifest"
        info "Per-run provider key remains available on ${target_switch} after ${context}."
    else
        info "Per-run provider key remains available on all switches after ${context}."
    fi
}

ensure_containerlab_net_node() {
    local node_state existing_names
    [[ -f "$CONTAINERLAB_TOPOLOGY" && -f "$CONTAINERLAB_INVENTORY" \
        && -f "$CONTAINERLAB_CONFIGURE_PLAYBOOK" ]] \
        || die "A repository-owned Containerlab topology, inventory, or trunk playbook is missing"
    resolve_mgmt_network
    if docker inspect "$CONTAINERLAB_NET_NODE" >/dev/null 2>&1; then
        node_state="$(docker inspect -f '{{.State.Running}}' "$CONTAINERLAB_NET_NODE")"
        [[ "$node_state" == true ]] \
            || die "The Containerlab network node exists but is stopped; refusing to modify a partial lab"
        ensure_containerlab_switches
        assert_containerlab_switch_images
        info "Reusing the running Containerlab network node."
        return 0
    fi
    existing_names="$(docker ps -a --format '{{.Names}}' | awk -v prefix="$CONTAINERLAB_PREFIX-" 'index($0, prefix) == 1')"
    [[ -z "$existing_names" ]] \
        || die "A partial Containerlab topology exists without its network node; refusing to redeploy it"
    info "Deploying the repository Containerlab topology on the existing SNO management bridge..."
    sudo env \
        "MGMT_BRIDGE=$MGMT_BRIDGE" \
        "MGMT_CIDR=$MGMT_CIDR" \
        "MGMT_GW=$MGMT_GW" \
        "MGMT_PREFIX=$MGMT_PREFIX" \
        "CUMULUS_VX_IMAGE=$CUMULUS_VX_IMAGE" \
        "CUMULUS_STARTUP_CONFIG=$CUMULUS_STARTUP_CONFIG" \
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
    local -a provider_packages=(iptables iproute2 python3 openssh sudo conntrack-tools procps iputils dnsmasq supervisor)
    if [[ "$SUITE_USES_EXTERNAL_ROUTING" == true ]]; then
        provider_packages+=(frr frr-openrc openrc)
    fi
    ensure_aap_ssh_key
    if [[ "$CLEANUP_MODE" == true ]]; then
        info "Checking existing provider tools and preparing temporary SSH access on the network node..."
        docker exec "$CONTAINERLAB_NET_NODE" sh -c \
            'for tool in iptables ip python3 sshd sudo conntrack dnsmasq supervisorctl; do command -v "$tool" >/dev/null || exit 1; done' \
            || die "The existing Containerlab network node lacks provider cleanup tools; cleanup will not install packages"
        if [[ "$SUITE_USES_EXTERNAL_ROUTING" == true ]]; then
            docker exec "$CONTAINERLAB_NET_NODE" sh -c \
                'for tool in vtysh rc-service pgrep; do command -v "$tool" >/dev/null || exit 1; done; test -x /etc/init.d/frr; test -f /etc/frr/daemons' \
                || die "The network node lacks FRR; cleanup will not install packages"
        fi
    else
        info "Installing provider tools and key-only SSH access on the Containerlab network node..."
        package_log="$TEMP_DIR/containerlab-package-install.log"
        if ! docker exec "$CONTAINERLAB_NET_NODE" apk add --no-cache \
            "${provider_packages[@]}" >"$package_log" 2>&1; then
            info "The isolated Containerlab network has no package-repository egress; retrying through the Docker bridge."
            bridge_status="$(docker inspect -f '{{if index .NetworkSettings.Networks "bridge"}}true{{else}}false{{end}}' "$CONTAINERLAB_NET_NODE")" \
                || die "Could not inspect the Containerlab node network attachments"
            if [[ "$bridge_status" != true ]]; then
                docker network connect \
                    --driver-opt=com.docker.network.endpoint.ifname=net-download \
                    bridge "$CONTAINERLAB_NET_NODE" >/dev/null \
                    || die "Could not temporarily connect the test network node to the Docker bridge"
                NETNODE_DOCKER_BRIDGE_ATTACHED_BY_RUN=true
            fi
            if ! docker exec "$CONTAINERLAB_NET_NODE" apk add --no-cache \
                "${provider_packages[@]}" >"$package_log" 2>&1; then
                tail -n 20 "$package_log" >&2
                restore_netnode_download_network || true
                die "Could not install the AgentlessNet provider prerequisites on the Containerlab network node"
            fi
            restore_netnode_download_network \
                || die "Could not disconnect the temporary Docker bridge from the Containerlab network node"
        fi
    fi
    if [[ "$SUITE_USES_EXTERNAL_ROUTING" == true ]]; then
        prepare_containerlab_frr
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

prepare_containerlab_frr() {
    info "Preparing local FRR static-route support on the Containerlab network node..."
    docker exec -i "$CONTAINERLAB_NET_NODE" sh -s <<'SH'
set -eu
mkdir -p /run/openrc
touch /run/openrc/softlevel
for daemon in zebra staticd; do
    if grep -q "^${daemon}=" /etc/frr/daemons; then
        sed -i "s/^${daemon}=.*/${daemon}=yes/" /etc/frr/daemons
    else
        printf '%s=yes\n' "$daemon" >>/etc/frr/daemons
    fi
    config="/etc/frr/${daemon}.conf"
    if [ ! -e "$config" ]; then
        : >"$config"
    fi
    chown frr:frr "$config"
    chmod 0640 "$config"
done
SH
    if ! docker exec "$CONTAINERLAB_NET_NODE" sh -c \
        'pgrep -x zebra >/dev/null && pgrep -x staticd >/dev/null && vtysh -c "show running-config" >/dev/null 2>&1'; then
        docker exec "$CONTAINERLAB_NET_NODE" rc-service frr start \
            || die "Could not start FRR on the Containerlab network node"
    fi
    docker exec "$CONTAINERLAB_NET_NODE" sh -c \
        'pgrep -x zebra >/dev/null && pgrep -x staticd >/dev/null && vtysh -c "show running-config" >/dev/null 2>&1' \
        || die "FRR did not expose a working zebra/staticd vtysh session on the Containerlab network node"
    info "Local FRR zebra/staticd and vtysh are ready on the Containerlab network node."
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
        || die "The local lab switch manifest is empty"
    while IFS= read -r switch; do
        [[ -n "$switch" ]] || continue
        docker inspect "$switch" >/dev/null 2>&1 \
            || die "Containerlab Cumulus switch $switch is missing"
        [[ "$(docker inspect -f '{{.State.Running}}' "$switch")" == true ]] \
            || die "Containerlab Cumulus switch $switch is stopped"
    done < <(jq -r '.switches[].name' "$SWITCH_MANIFEST_FILE")
}

assert_containerlab_switch_images() {
    local switch current_image current_image_id
    while IFS= read -r switch; do
        [[ -n "$switch" ]] || continue
        current_image="$(docker inspect -f '{{.Config.Image}}' "$switch")" \
            || die "Could not inspect the Containerlab switch image for $switch"
        [[ "$current_image" == "$CUMULUS_VX_IMAGE" ]] \
            || die "Containerlab switch $switch uses $current_image; expected $CUMULUS_VX_IMAGE. Migrate only leaf-1 and leaf-2 with the documented filtered Containerlab commands."
        current_image_id="$(docker inspect -f '{{.Image}}' "$switch")" \
            || die "Could not inspect the resolved Containerlab switch image ID for $switch"
        [[ "$current_image_id" == "$CUMULUS_IMAGE_ID" ]] \
            || die "Containerlab switch $switch runs image $current_image_id; expected $CUMULUS_IMAGE_ID. Migrate only leaf-1 and leaf-2 with the documented filtered Containerlab commands."
    done < <(jq -r '.switches[].name' "$SWITCH_MANIFEST_FILE")
}

wait_for_cumulus_guests() {
    local switch expected_address health guest_ready deadline next_report version mgmt_address pending_diff
    deadline=$((SECONDS + 1200))
    next_report=$((SECONDS + 60))
    ensure_containerlab_switches
    while IFS= read -r switch; do
        [[ -n "$switch" ]] || continue
        expected_address="$(jq -er --arg name "$switch" \
            '.switches[] | select(.name == $name) | .ansible_host' "$SWITCH_MANIFEST_FILE")" \
            || die "Could not resolve the management address for $switch"
        guest_ready=false
        while ((SECONDS < deadline)); do
            health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$switch" 2>/dev/null || true)"
            if [[ "$health" == healthy ]] \
                && switch_admin_user_exec "$switch" true >/dev/null 2>&1; then
                guest_ready=true
                break
            fi
            if ((SECONDS >= next_report)); then
                info "Waiting for Boxen guest $switch (health=$health)"
                next_report=$((SECONDS + 60))
            fi
            sleep 5
        done
        if [[ "$guest_ready" != true ]]; then
            printf 'ERROR: Boxen guest %s did not become healthy and SSH-ready within 20 minutes\n' "$switch" >&2
            docker logs --tail 100 "$switch" >&2 || true
            return 1
        fi

        version="$(switch_admin_user_exec "$switch" sh -c '. /etc/os-release; printf "%s" "$VERSION_ID"')" \
            || die "Could not read the guest release from $switch"
        [[ "$version" == "$CUMULUS_VERSION" ]] \
            || die "Cumulus guest $switch reports $version; expected $CUMULUS_VERSION"
        mgmt_address="$(switch_admin_user_exec "$switch" ip -4 -o addr show dev eth0 \
            | awk '{print $4}' | cut -d/ -f1)" \
            || die "Could not read the IPv4 management address from $switch"
        [[ "$mgmt_address" == "$expected_address" ]] \
            || die "Cumulus guest $switch has management address $mgmt_address; expected $expected_address"
        switch_admin_user_exec "$switch" sudo -n true \
            || die "Cumulus guest $switch does not have the required passwordless sudo baseline"
        switch_admin_user_exec "$switch" sh -c \
            'for port in swp1 swp2 swp3 swp4; do ip link show dev "$port" >/dev/null 2>&1 || exit 1; done' \
            || die "Cumulus guest $switch does not expose swp1 through swp4"
        pending_diff="$(switch_nvue_diff admin "$switch")" \
            || die "Could not inspect the pending NVUE candidate on $switch"
        [[ -z "$pending_diff" ]] \
            || die "Cumulus guest $switch has unapplied NVUE candidate changes before fabric setup"
        info "Boxen guest $switch is ready: Cumulus $version, management $mgmt_address, swp1-swp4 present."
    done < <(jq -r '.switches[].name' "$SWITCH_MANIFEST_FILE")
}

ensure_containerlab_admin_nvue_key() {
    local switch="$1" key_type key_data pending_diff key_config
    read -r key_type key_data _ <"$CUMULUS_ADMIN_PUBLIC_KEY_FILE" \
        || die "Could not parse the persistent Cumulus administrator public key"
    case "$key_type" in
        ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) ;;
        *) die "Unsupported Cumulus administrator SSH key type: ${key_type:-missing}" ;;
    esac
    [[ "$key_data" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] \
        || die "The persistent Cumulus administrator public key has an invalid payload"
    pending_diff="$(switch_nvue_diff admin "$switch")" \
        || die "Could not inspect pending NVUE changes on ${switch} before preserving admin access"
    [[ -z "$pending_diff" ]] \
        || die "Switch ${switch} has pending NVUE changes; refusing to apply administrator-key configuration"
    key_config="$(switch_admin_user_exec "$switch" nv show system aaa user cumulus ssh authorized-key --output json)" \
        || die "Could not inspect NVUE authorized keys on ${switch}"
    if jq -e --arg id "$CUMULUS_ADMIN_NVUE_KEY_ID" 'has($id)' \
        <<<"$key_config" >/dev/null; then
        jq -e --arg id "$CUMULUS_ADMIN_NVUE_KEY_ID" --arg type "$key_type" \
            '.[$id].type == $type' <<<"$key_config" >/dev/null \
            || die "NVUE administrator key ID ${CUMULUS_ADMIN_NVUE_KEY_ID} has a different key type on ${switch}"
        # NVUE redacts key literals in show output. This command already proves the saved admin identity is accepted.
        return 0
    fi

    switch_admin_user_exec "$switch" nv set system aaa user cumulus ssh authorized-key \
        "$CUMULUS_ADMIN_NVUE_KEY_ID" key "$key_data" \
        || die "Could not stage the persistent administrator SSH key in NVUE on ${switch}"
    switch_admin_user_exec "$switch" nv set system aaa user cumulus ssh authorized-key \
        "$CUMULUS_ADMIN_NVUE_KEY_ID" type "$key_type" \
        || die "Could not stage the persistent administrator SSH key type in NVUE on ${switch}"
    switch_admin_user_exec "$switch" nv config apply --assume-yes \
        || die "Could not apply the persistent administrator SSH key in NVUE on ${switch}"

    key_config="$(switch_admin_user_exec "$switch" nv show system aaa user cumulus ssh authorized-key --output json)" \
        || die "Could not verify the persistent administrator SSH key on ${switch}"
    jq -e --arg id "$CUMULUS_ADMIN_NVUE_KEY_ID" --arg type "$key_type" \
        '.[$id].type == $type' <<<"$key_config" >/dev/null \
        || die "NVUE did not retain the persistent administrator SSH key on ${switch}"
    switch_admin_user_exec "$switch" true \
        || die "The persistent administrator SSH key stopped working on ${switch} after NVUE apply"
}

assert_containerlab_admin_nvue_key() {
    local switch="$1" key_type key_config
    read -r key_type _ <"$CUMULUS_ADMIN_PUBLIC_KEY_FILE" \
        || die "Could not parse the persistent Cumulus administrator public key"
    key_config="$(switch_admin_user_exec "$switch" nv show system aaa user cumulus ssh authorized-key --output json)" \
        || die "Could not inspect NVUE authorized keys on ${switch}"
    jq -e --arg id "$CUMULUS_ADMIN_NVUE_KEY_ID" --arg type "$key_type" \
        '.[$id].type == $type' <<<"$key_config" >/dev/null \
        || die "The persistent administrator NVUE key is missing or different on ${switch}; cleanup will not modify it"
    switch_admin_user_exec "$switch" true \
        || die "The persistent administrator SSH key is not accepted on ${switch}"
}

install_containerlab_switch_provider_key() {
    local switch="$1" key_type="$2" key_data="$3" pending_diff key_config
    info "Installing per-run provider NVUE key on ${switch}."
    pending_diff="$(switch_nvue_diff admin "$switch")" \
        || die "Could not inspect pending NVUE changes on ${switch} before adding the provider key"
    [[ -z "$pending_diff" ]] \
        || die "Switch ${switch} has pending NVUE changes; refusing to apply provider-key configuration"
    key_config="$(switch_admin_user_exec "$switch" nv show system aaa user cumulus ssh authorized-key --output json)" \
        || die "Could not inspect NVUE authorized keys on ${switch}"
    if jq -e --arg id "$PROVIDER_NVUE_KEY_ID" 'has($id)' <<<"$key_config" >/dev/null; then
        die "NVUE provider-key ID ${PROVIDER_NVUE_KEY_ID} already exists on ${switch}; preserving it"
    fi

    # Cumulus manages the cumulus account through NVUE, so direct authorized_keys edits are overwritten by nv config apply.
    SWITCH_NVUE_KEY_INSTALLED_BY_RUN["$switch"]=true
    switch_admin_user_exec "$switch" nv set system aaa user cumulus ssh authorized-key \
        "$PROVIDER_NVUE_KEY_ID" key "$key_data" \
        || die "Could not stage the provider SSH key in NVUE on ${switch}"
    switch_admin_user_exec "$switch" nv set system aaa user cumulus ssh authorized-key \
        "$PROVIDER_NVUE_KEY_ID" type "$key_type" \
        || die "Could not stage the provider SSH key type in NVUE on ${switch}"
    switch_admin_user_exec "$switch" nv config apply --assume-yes \
        || die "Could not apply the provider SSH key in NVUE on ${switch}"

    key_config="$(switch_admin_user_exec "$switch" nv show system aaa user cumulus ssh authorized-key --output json)" \
        || die "Could not verify the NVUE provider SSH key on ${switch}"
    jq -e --arg id "$PROVIDER_NVUE_KEY_ID" --arg type "$key_type" \
        '.[$id].type == $type' <<<"$key_config" >/dev/null \
        || die "NVUE did not retain the provider SSH key on ${switch}"
    info "Per-run provider NVUE key installation verified on ${switch}."
}

prepare_containerlab_switches() {
    local switch public_key admin_public_key ssh_output user provider_key_type provider_key_data
    [[ -f "$SSH_PUBLIC_KEY_FILE" ]] || die "The temporary AgentlessNet SSH public key is missing"
    public_key="$(<"$SSH_PUBLIC_KEY_FILE")"
    admin_public_key="$(<"$CUMULUS_ADMIN_PUBLIC_KEY_FILE")"
    [[ "$public_key" != "$admin_public_key" ]] \
        || die "The per-run AAP SSH key must differ from the persistent Cumulus administrator key"
    read -r provider_key_type provider_key_data _ <"$SSH_PUBLIC_KEY_FILE" \
        || die "Could not parse the per-run provider SSH public key"
    case "$provider_key_type" in
        ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) ;;
        *) die "Unsupported per-run provider SSH key type: ${provider_key_type:-missing}" ;;
    esac
    [[ "$provider_key_data" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] \
        || die "The per-run provider SSH public key has an invalid key payload"
    ensure_containerlab_switches
    write_cumulus_ssh_config
    SWITCH_ACCESS_CONFIGURED=true
    while IFS= read -r switch; do
        [[ -n "$switch" ]] || continue
        user="$(jq -r --arg name "$switch" \
            '.switches[] | select(.name == $name) | .ansible_user' "$SWITCH_MANIFEST_FILE")"
        switch_admin_exec "$switch" test -r /etc/sudoers.d/osac-cumulus-lab-bootstrap \
            || die "Cumulus switch $switch lacks the packaged lab sudo baseline; rebuild its Boxen image"
        switch_admin_exec "$switch" grep -Fqx \
            'cumulus ALL=(ALL) NOPASSWD: ALL' /etc/sudoers.d/osac-cumulus-lab-bootstrap \
            || die "Cumulus switch $switch has an invalid lab sudo baseline"
        switch_admin_user_exec "$switch" sudo -n true \
            || die "Cumulus switch $switch does not allow the required sudo -n provider operations"
        if switch_admin_exec "$switch" test -f /etc/sudoers.d/osac-agentless-net; then
            if switch_admin_exec "$switch" grep -Fxq '# OSAC-5530 temporary provider access' \
                /etc/sudoers.d/osac-agentless-net || switch_admin_exec "$switch" grep -Fxq \
                '# OSAC-5529 temporary provider access' /etc/sudoers.d/osac-agentless-net; then
                SWITCH_SUDOERS_CREATED_BY_RUN["$switch"]=true
            else
                die "Cumulus switch $switch already has an unrelated sudoers file at the test path"
            fi
        fi
        switch_admin_user_exec "$switch" id "$user" >/dev/null 2>&1 \
            || die "Cumulus switch $switch does not have its expected SSH user"
        if [[ "$CLEANUP_MODE" == true ]]; then
            assert_containerlab_admin_nvue_key "$switch"
        else
            ensure_containerlab_admin_nvue_key "$switch"
        fi
        install_containerlab_switch_provider_key "$switch" "$provider_key_type" "$provider_key_data"
    done < <(jq -r '.switches[].name' "$SWITCH_MANIFEST_FILE")
    while IFS= read -r switch; do
        [[ -n "$switch" ]] || continue
        ssh_output="$TEMP_DIR/switch-${switch}-ssh-check.log"
        info "Provider-key SSH checkpoint: testing the per-run identity on ${switch}."
        if ! switch_provider_user_exec "$switch" sh -c \
            'sudo -n true && sudo -n bridge -j vlan show >/dev/null && sudo -n nv show bridge --output json >/dev/null' \
            >"$ssh_output" 2>&1; then
            tail -n 30 "$ssh_output" >&2
            die "Cumulus switch $switch is not reachable through the per-run provider SSH identity"
        fi
        info "Provider-key SSH checkpoint passed on ${switch}."
    done < <(jq -r '.switches[].name' "$SWITCH_MANIFEST_FILE")
    info "Containerlab Cumulus switches are reachable with the isolated provider SSH key."
}

configure_containerlab_fabric() {
    local switch pending_diff playbook_log
    while IFS= read -r switch; do
        [[ -n "$switch" ]] || continue
        if ! pending_diff="$(switch_nvue_diff provider "$switch")"; then
            die "Could not inspect pending NVUE changes on $switch"
        fi
        [[ -z "$pending_diff" ]] \
            || die "Switch $switch has pending NVUE changes; refusing to apply fabric trunk configuration"
    done < <(jq -r '.switches[].name' "$SWITCH_MANIFEST_FILE")

    playbook_log="$TEMP_DIR/fabric-setup.log"
    info "Checking declared Cumulus trunks and initializing missing ports in br_default..."
    if ! (
        cd "$AAP_DIR"
        # This is local lab bootstrap; provider-key access is checked above and
        # is still used by AAP for resource provisioning.
        uv run --locked --group development ansible-playbook \
            --inventory "$TEMP_DIR/inventory.yml" \
            --private-key "$CUMULUS_LAB_ADMIN_KEY" \
            --ssh-extra-args \
            "-o BatchMode=yes -o IdentitiesOnly=yes -o UserKnownHostsFile=$TEMP_DIR/known_hosts -o ConnectTimeout=5" \
            "$CONTAINERLAB_CONFIGURE_PLAYBOOK"
    ) >"$playbook_log" 2>&1; then
        tail -n 80 "$playbook_log" >&2
        die "Containerlab fabric trunk initialization failed"
    fi
    info "Declared Cumulus trunk ports are initialized and verified."
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
    raise SystemExit("local lab inventory must be a mapping")
mgmt = topology.get("mgmt", {}) if isinstance(topology, dict) else {}
if not isinstance(mgmt, dict):
    raise SystemExit("Containerlab topology management network must be a mapping")
for key, env_name in (("bridge", "MGMT_BRIDGE"), ("ipv4-subnet", "MGMT_CIDR"), ("ipv4-gw", "MGMT_GW")):
    value = str(mgmt.get(key, ""))
    expected = os.environ[env_name]
    if env_name not in value and value != expected:
        raise SystemExit("Containerlab management network does not use the existing SNO libvirt network")
all_group = inventory.get("all", {})
all_vars = all_group.get("vars", {}) if isinstance(all_group, dict) else {}
if not isinstance(all_vars, dict):
    raise SystemExit("local lab all.vars must be a mapping")
children = all_group.get("children", {}) if isinstance(all_group, dict) else {}
net_nodes = children.get("net_nodes", {}) if isinstance(children, dict) else {}
hosts = net_nodes.get("hosts", {}) if isinstance(net_nodes, dict) else {}
if not isinstance(hosts, dict) or len(hosts) != 1:
    raise SystemExit("local lab inventory must define exactly one authoritative net node")
name, vars = next(iter(hosts.items()))
if not isinstance(vars, dict):
    raise SystemExit("local lab net-node inventory variables must be a mapping")
host = vars.get("ansible_host")
user = vars.get("ansible_user")
prefix = os.environ["MGMT_PREFIX"]
cidr = ipaddress.IPv4Network(os.environ["MGMT_CIDR"], strict=False)
if not isinstance(host, str) or not isinstance(user, str):
    raise SystemExit("local lab net-node inventory requires ansible_host and ansible_user")
host = host.replace("$" + "{MGMT_PREFIX}", prefix).replace("$MGMT_PREFIX", prefix)
if "$" in host or "{{" in host or "}}" in host:
    raise SystemExit("local lab net-node address contains an unresolved variable")
try:
    address = ipaddress.IPv4Address(host)
except ipaddress.AddressValueError as error:
    raise SystemExit("local lab net-node address is not an IPv4 address") from error
if address not in cidr:
    raise SystemExit("local lab net-node address is outside the SNO management network")
for item in filter(None, os.environ.get("MGMT_DHCP_RANGES", "").split(",")):
    start, end = (ipaddress.IPv4Address(part) for part in item.split("-", 1))
    if start <= address <= end:
        raise SystemExit("local lab net-node address conflicts with the SNO DHCP pool")
if user != "root":
    raise SystemExit("the Containerlab net-node must use its root SSH account")
if not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
    raise SystemExit("local lab net-node inventory name contains unsupported characters")
topology_name = topology.get("name", "")
container_prefix = f"clab-{topology_name}-"
switch_group = children.get("switches", {}) if isinstance(children, dict) else {}
switch_hosts = switch_group.get("hosts", {}) if isinstance(switch_group, dict) else {}
if not isinstance(switch_hosts, dict) or not switch_hosts:
    raise SystemExit("local lab inventory must define at least one Cumulus switch")
switch_manifest = []
switch_inventory_hosts = {}
for switch_name, switch_vars in switch_hosts.items():
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", switch_name) or not switch_name.startswith(container_prefix):
        raise SystemExit("local lab switch inventory name does not match the Containerlab topology")
    if not isinstance(switch_vars, dict):
        raise SystemExit("local lab switch inventory variables must be a mapping")
    switch_host = switch_vars.get("ansible_host")
    switch_user = switch_vars.get("ansible_user")
    if not isinstance(switch_host, str) or not isinstance(switch_user, str):
        raise SystemExit("local lab switch inventory requires ansible_host and ansible_user")
    switch_host = switch_host.replace("${MGMT_PREFIX}", prefix).replace("$MGMT_PREFIX", prefix)
    if "$" in switch_host or "{{" in switch_host or "}}" in switch_host:
        raise SystemExit("local lab switch address contains an unresolved variable")
    try:
        switch_address = ipaddress.IPv4Address(switch_host)
    except ipaddress.AddressValueError as error:
        raise SystemExit("local lab switch address is not an IPv4 address") from error
    if switch_address not in cidr:
        raise SystemExit("local lab switch address is outside the SNO management network")
    for item in filter(None, os.environ.get("MGMT_DHCP_RANGES", "").split(",")):
        start, end = (ipaddress.IPv4Address(part) for part in item.split("-", 1))
        if start <= switch_address <= end:
            raise SystemExit("local lab switch address conflicts with the SNO DHCP pool")
    if switch_user != "cumulus" or switch_vars.get("ansible_network_os", "cumulus") != "cumulus":
        raise SystemExit("local lab Cumulus switches must use the cumulus account and network_os")
    try:
        switch_port = int(switch_vars.get("ansible_port", 22))
    except (TypeError, ValueError) as error:
        raise SystemExit("local lab switch SSH port must be an integer") from error
    if not 1 <= switch_port <= 65535:
        raise SystemExit("local lab switch SSH port is outside the valid range")
    trunk_ports = switch_vars.get("trunk_ports")
    if not isinstance(trunk_ports, list) or not trunk_ports:
        raise SystemExit("local lab Cumulus switches require a nonempty trunk_ports list")
    if any(not isinstance(port, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,15}", port) for port in trunk_ports):
        raise SystemExit("local lab switch trunk port contains unsupported characters")
    if len(set(trunk_ports)) != len(trunk_ports):
        raise SystemExit("local lab switch trunk_ports must be unique")
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
provisioning_network = all_vars.get("agentless_net_provisioning_network")
if not isinstance(provisioning_network, dict):
    raise SystemExit("local lab inventory must define the AgentlessNet provisioning network")
provisioning_name = provisioning_network.get("name")
provisioning_vlan = provisioning_network.get("vlan_id")
if not isinstance(provisioning_name, str) or not provisioning_name.strip():
    raise SystemExit("AgentlessNet provisioning network name must be a nonempty string")
if not isinstance(provisioning_vlan, int) or not 1 <= provisioning_vlan <= 4094:
    raise SystemExit("AgentlessNet provisioning network VLAN must be between 1 and 4094")
host_ports = all_vars.get("agentless_net_host_ports")
if not isinstance(host_ports, dict) or not host_ports:
    raise SystemExit("local lab inventory must define AgentlessNet BMI host-port mappings")
claimed_ports = set()
for host_name, interfaces in host_ports.items():
    if not isinstance(host_name, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,63}", host_name):
        raise SystemExit("AgentlessNet BMI host mapping contains an invalid host name")
    if not isinstance(interfaces, dict) or not interfaces:
        raise SystemExit("AgentlessNet BMI hosts must map at least one logical interface")
    for interface, mapping in interfaces.items():
        if not isinstance(interface, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,15}", interface):
            raise SystemExit("AgentlessNet BMI mapping contains an invalid logical interface")
        if not isinstance(mapping, dict):
            raise SystemExit("AgentlessNet BMI interface mapping must be a mapping")
        switch = mapping.get("switch")
        port = mapping.get("port")
        if switch not in switch_inventory_hosts or not isinstance(port, str) or not re.fullmatch(r"swp[0-9]+", port):
            raise SystemExit("AgentlessNet BMI mapping must reference a known switch and Cumulus swp port")
        if port in switch_inventory_hosts[switch]["trunk_ports"]:
            raise SystemExit("AgentlessNet BMI access ports must not overlap declared Subnet trunks")
        claim = (switch, port)
        if claim in claimed_ports:
            raise SystemExit("AgentlessNet BMI switch ports must not be assigned more than once")
        claimed_ports.add(claim)
switch_manifest.sort(key=lambda item: item["name"])
output = {
    "all": {
        "vars": {
            "ansible_ssh_common_args": "-o StrictHostKeyChecking=accept-new",
            "agentless_net_provisioning_network": {
                "name": provisioning_name.strip(),
                "vlan_id": provisioning_vlan,
            },
            "agentless_net_host_ports": host_ports,
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
        old_children = existing_all["children"]
        expected_children = expected_all["children"]
        old_net_nodes = old_children["net_nodes"]
        new_net_nodes = expected_children["net_nodes"]
        expected_legacy_vars = {
            key: value
            for key, value in expected_all.get("vars", {}).items()
            if key not in ("agentless_net_provisioning_network", "agentless_net_host_ports")
        }
        safe_upgrade = (
            set(existing) == {"all"}
            and existing_all.get("vars", {}) == expected_legacy_vars
            and set(old_children) in ({"net_nodes"}, {"net_nodes", "switches"})
            and old_net_nodes == new_net_nodes
            and (
                "switches" not in old_children
                or old_children["switches"] == expected_children["switches"]
            )
        )
    except (KeyError, TypeError):
        safe_upgrade = False
    if not safe_upgrade:
        raise SystemExit("existing AgentlessNet inventory is not the known legacy inventory")

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
        die "Existing AgentlessNet inventory differs from the local lab configuration; refusing to overwrite it"
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

prepare_aap_ca_bundle() {
    local ingress_ca_file="${TEMP_DIR}/default-ingress-ca.pem"
    if ! oc get configmap ca-bundle -n "$OSAC_NAMESPACE" -o json \
        | jq -er '.data["bundle.pem"] | select(type == "string" and length > 0)' \
            >"$AAP_API_CA_FILE"; then
        die "Could not read the OSAC API CA bundle"
    fi
    if ! oc get configmap default-ingress-cert -n openshift-config-managed -o json \
        | jq -er '.data["ca-bundle.crt"] | select(type == "string" and length > 0)' \
            >"$ingress_ca_file"; then
        die "Could not read the OpenShift default ingress CA bundle"
    fi
    if ! python3 - "$AAP_API_CA_FILE" "$ingress_ca_file" <<'PY'
import pathlib
import sys

target, ingress = (pathlib.Path(value) for value in sys.argv[1:])
osac_bundle = target.read_text().strip()
ingress_bundle = ingress.read_text().strip()
if not osac_bundle or not ingress_bundle:
    raise SystemExit("both CA bundles must be non-empty")
target.write_text(osac_bundle + "\n" + ingress_bundle + "\n")
PY
    then
        die "Could not combine the OSAC and default ingress CA bundles"
    fi
    [[ -s "$AAP_API_CA_FILE" ]] || die "Combined OSAC and ingress CA bundle is empty"
    chmod 0600 "$AAP_API_CA_FILE"
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
        AAP_API_CA_FILE="$AAP_API_CA_FILE" \
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
context = ssl.create_default_context(cafile=os.environ["AAP_API_CA_FILE"])

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
        AAP_API_CA_FILE="$AAP_API_CA_FILE" \
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
context = ssl.create_default_context(cafile=os.environ["AAP_API_CA_FILE"])

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

configure_aap_subnet_reader() {
    [[ "$SUITE_USES_SUBNET_DHCP" == true ]] || return 0

    local token_file="${TEMP_DIR}/aap-subnet-reader.token"
    local ca_file="${TEMP_DIR}/aap-subnet-reader-ca.pem"
    local route token result can_list verb can
    local role_name="$AAP_SUBNET_READER_NAME"
    AAP_SUBNET_READER_SETUP_ATTEMPTED=true

    oc create serviceaccount "$AAP_SUBNET_READER_NAME" -n "$OSAC_NAMESPACE" \
        --dry-run=client -o yaml \
        | oc apply -f - >/dev/null \
        || { printf 'ERROR: could not ensure the Subnet reader ServiceAccount\n' >&2; return 1; }
    oc create role "$role_name" -n "$NETWORKING_NAMESPACE" \
        --verb=get,list --resource=subnets.osac.openshift.io \
        --dry-run=client -o yaml \
        | oc apply -f - >/dev/null \
        || { printf 'ERROR: could not ensure the Subnet reader Role\n' >&2; return 1; }
    oc create rolebinding "$role_name" -n "$NETWORKING_NAMESPACE" \
        --role="$role_name" \
        --serviceaccount="${OSAC_NAMESPACE}:${AAP_SUBNET_READER_NAME}" \
        --dry-run=client -o yaml \
        | oc apply -f - >/dev/null \
        || { printf 'ERROR: could not ensure the Subnet reader RoleBinding\n' >&2; return 1; }
    oc create role "$AAP_SUBNET_LOCK_NAME" -n "$OSAC_NAMESPACE" \
        --verb=get,create,update,patch --resource=leases.coordination.k8s.io \
        --dry-run=client -o yaml \
        | oc apply -f - >/dev/null \
        || { printf 'ERROR: could not ensure the Subnet lock Role\n' >&2; return 1; }
    oc create rolebinding "$AAP_SUBNET_LOCK_NAME" -n "$OSAC_NAMESPACE" \
        --role="$AAP_SUBNET_LOCK_NAME" \
        --serviceaccount="${OSAC_NAMESPACE}:${AAP_SUBNET_READER_NAME}" \
        --dry-run=client -o yaml \
        | oc apply -f - >/dev/null \
        || { printf 'ERROR: could not ensure the Subnet lock RoleBinding\n' >&2; return 1; }

    if ! can_list="$(oc auth can-i list subnets.osac.openshift.io \
        --as="system:serviceaccount:${OSAC_NAMESPACE}:${AAP_SUBNET_READER_NAME}" \
        -n "$NETWORKING_NAMESPACE")" || [[ "$can_list" != yes ]]; then
        printf 'ERROR: the temporary AAP ServiceAccount cannot list Subnets in %s\n' \
            "$NETWORKING_NAMESPACE" >&2
        return 1
    fi
    for verb in get create update patch; do
        if ! can="$(oc auth can-i "$verb" leases.coordination.k8s.io \
            --as="system:serviceaccount:${OSAC_NAMESPACE}:${AAP_SUBNET_READER_NAME}" \
            -n "$OSAC_NAMESPACE")" || [[ "$can" != yes ]]; then
            printf 'ERROR: the temporary AAP ServiceAccount cannot %s V-Net lock Leases\n' \
                "$verb" >&2
            return 1
        fi
    done

    if ! oc create token "$AAP_SUBNET_READER_NAME" -n "$OSAC_NAMESPACE" \
        --duration=24h >"$token_file"; then
        printf 'ERROR: could not mint the temporary AAP Subnet reader token\n' >&2
        return 1
    fi
    chmod 0600 "$token_file"
    if ! oc get configmap kube-root-ca.crt -n "$NETWORKING_NAMESPACE" -o json \
        | jq -er '.data["ca.crt"] | select(type == "string" and length > 0)' >"$ca_file"; then
        rm -f -- "$token_file"
        printf 'ERROR: could not read the Kubernetes API CA bundle\n' >&2
        return 1
    fi
    chmod 0600 "$ca_file"

    route="$(oc get route osac-aap -n "$OSAC_NAMESPACE" -o jsonpath='{.spec.host}')" \
        || { rm -f -- "$token_file" "$ca_file"; printf 'ERROR: could not read the AAP Controller route\n' >&2; return 1; }
    token="$(oc exec deployment/osac-operator -n "$OSAC_NAMESPACE" -- \
        sh -c 'printf %s "$OSAC_AAP_TOKEN"' 2>/dev/null)" \
        || { rm -f -- "$token_file" "$ca_file"; printf 'ERROR: could not obtain the AAP API token\n' >&2; return 1; }
    if [[ -z "$route" || -z "$token" ]]; then
        unset token
        rm -f -- "$token_file" "$ca_file"
        printf 'ERROR: AAP Controller route or API token is unavailable\n' >&2
        return 1
    fi
    if ! result="$(AAP_API_ROUTE="https://${route}" AAP_API_TOKEN="$token" \
        AAP_API_CA_FILE="$AAP_API_CA_FILE" \
        python3 "$AAP_JOBS_HELPER" configure-k8s-credential \
            --job-template "${AAP_PREFIX}-move-network-attachment" \
            --job-template "${AAP_PREFIX}-query-dhcp-lease" \
            --credential-name "$AAP_SUBNET_READER_CREDENTIAL" \
            --credential-type-name "$AAP_SUBNET_READER_CREDENTIAL_TYPE" \
            --api-host https://kubernetes.default.svc \
            --token-file "$token_file" --ca-file "$ca_file")"; then
        unset token
        rm -f -- "$token_file" "$ca_file"
        printf 'ERROR: could not attach the temporary Subnet and lock credential to the AAP move job\n' >&2
        return 1
    fi
    unset token
    rm -f -- "$token_file" "$ca_file"
    jq -e '.credential_id and .credential_type_id and (.template_ids | length == 2)' \
        <<<"$result" >/dev/null \
        || { printf 'ERROR: AAP did not confirm the Subnet credential association\n' >&2; return 1; }
    info "Configured temporary Subnet and V-Net lock credentials for the move and DHCP lease query jobs."
}

cleanup_aap_subnet_reader() {
    [[ "$AAP_SUBNET_READER_SETUP_ATTEMPTED" == true ]] || return 0

    local route token
    route="$(oc get route osac-aap -n "$OSAC_NAMESPACE" -o jsonpath='{.spec.host}')" \
        || { printf 'ERROR: could not read the AAP route while removing the Subnet credential\n' >&2; return 1; }
    token="$(oc exec deployment/osac-operator -n "$OSAC_NAMESPACE" -- \
        sh -c 'printf %s "$OSAC_AAP_TOKEN"' 2>/dev/null)" \
        || { printf 'ERROR: could not obtain the AAP API token for credential cleanup\n' >&2; return 1; }
    if [[ -z "$route" || -z "$token" ]]; then
        unset token
        printf 'ERROR: AAP Controller route or API token is unavailable for credential cleanup\n' >&2
        return 1
    fi
    if ! AAP_API_ROUTE="https://${route}" AAP_API_TOKEN="$token" \
        AAP_API_CA_FILE="$AAP_API_CA_FILE" \
        python3 "$AAP_JOBS_HELPER" cleanup-k8s-credential \
            --job-template "${AAP_PREFIX}-move-network-attachment" \
            --job-template "${AAP_PREFIX}-query-dhcp-lease" \
            --credential-name "$AAP_SUBNET_READER_CREDENTIAL" \
            --credential-type-name "$AAP_SUBNET_READER_CREDENTIAL_TYPE"; then
        unset token
        printf 'ERROR: could not detach and remove the temporary AAP Subnet credential\n' >&2
        return 1
    fi
    unset token

    if ! oc delete rolebinding "$AAP_SUBNET_READER_NAME" -n "$NETWORKING_NAMESPACE" \
        --ignore-not-found=true --wait=true >/dev/null \
        || ! oc delete rolebinding "$AAP_SUBNET_LOCK_NAME" -n "$OSAC_NAMESPACE" \
            --ignore-not-found=true --wait=true >/dev/null \
        || ! oc delete role "$AAP_SUBNET_READER_NAME" -n "$NETWORKING_NAMESPACE" \
            --ignore-not-found=true --wait=true >/dev/null \
        || ! oc delete role "$AAP_SUBNET_LOCK_NAME" -n "$OSAC_NAMESPACE" \
            --ignore-not-found=true --wait=true >/dev/null \
        || ! oc delete serviceaccount "$AAP_SUBNET_READER_NAME" -n "$OSAC_NAMESPACE" \
            --ignore-not-found=true --wait=true >/dev/null; then
        printf 'ERROR: could not remove the temporary Subnet and lock RBAC resources\n' >&2
        return 1
    fi
    AAP_SUBNET_READER_SETUP_ATTEMPTED=false
    info "Removed the temporary AAP credential and Subnet/lock ServiceAccount roles."
}

wait_for_existing_provider_deletions() {
    local deadline=$((SECONDS + 600)) current pending last_pending=""
    while ((SECONDS < deadline)); do
        if ! current="$(oc get externalippools,subnets,virtualnetworks \
            -n "$NETWORKING_NAMESPACE" -o json)"; then
            PREEXISTING_PROVIDER_CLEANUP_PENDING=true
            printf 'ERROR: could not inspect existing AgentlessNet provider deletions\n' >&2
            return 1
        fi
        if ! pending="$(jq -ce '[.items[]? | select(.metadata.deletionTimestamp != null)
            | {kind:.kind,name:.metadata.name,finalizers:(.metadata.finalizers // [])}]
            | sort_by(.kind,.name)' <<<"$current")"; then
            PREEXISTING_PROVIDER_CLEANUP_PENDING=true
            printf 'ERROR: could not parse existing AgentlessNet provider deletions\n' >&2
            return 1
        fi
        if [[ "$pending" == '[]' ]]; then
            PREEXISTING_PROVIDER_CLEANUP_PENDING=false
            return 0
        fi
        PREEXISTING_PROVIDER_CLEANUP_PENDING=true
        if [[ "$pending" != "$last_pending" ]]; then
            info "Waiting for existing AgentlessNet provider cleanup: ${pending}"
            last_pending="$pending"
        fi
        sleep 5
    done
    printf 'ERROR: existing AgentlessNet provider resources remain in deletion: %s\n' \
        "$pending" >&2
    return 1
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

configure_nat_gateway_uplink() {
    local current_json current_owner backup_json resource_version
    local original_present original_value annotations_present patch_file
    local current_present current_value
    [[ "$SUITE_USES_NAT_GATEWAY" == true ]] || return 0
    current_json="$(oc get configmap "$AAP_NETWORKING_SECRET" -n "$OSAC_NAMESPACE" -o json)" \
        || die "Could not read network-fulfillment-ig before configuring the NATGateway test uplink"
    current_owner="$(jq -r --arg key "$NAT_GATEWAY_UPLINK_OWNER_ANNOTATION" \
        '.metadata.annotations[$key] // ""' <<<"$current_json")"
    if [[ -n "$current_owner" ]]; then
        if [[ "$CLEANUP_MODE" != true ]]; then
            die "A previous NATGateway test still owns the network uplink override; run --cleanup --nat-gateway first"
        fi
        backup_json="$(jq -r --arg key "$NAT_GATEWAY_UPLINK_BACKUP_ANNOTATION" \
            '.metadata.annotations[$key] // ""' <<<"$current_json")"
        jq -e --arg owner "$current_owner" \
            '.owner == $owner and (.original_present | type == "boolean")
             and (.original_value | type == "string")
             and (.original_annotations_present | type == "boolean")' <<<"$backup_json" >/dev/null \
            || die "Saved NATGateway uplink recovery metadata is invalid"
        current_present="$(jq -r '.data | has("AGENTLESS_NET_EXTERNAL_INTERFACE")' <<<"$current_json")"
        current_value="$(jq -r '.data.AGENTLESS_NET_EXTERNAL_INTERFACE // ""' <<<"$current_json")"
        if [[ "$current_present" != true || "$current_value" != eth2 ]]; then
            jq -e --argjson present "$current_present" --arg value "$current_value" \
                --slurpfile backup <(printf '%s\n' "$backup_json") '
              ($backup[0].original_present == $present)
              and (if $present then $backup[0].original_value == $value else true end)' \
                <<<"$current_json" >/dev/null \
                || die "The NATGateway uplink changed after the interrupted run; preserving the current ConfigMap"
            resource_version="$(jq -er '.metadata.resourceVersion' <<<"$current_json")" \
                || die "network-fulfillment-ig has no resourceVersion for guarded NATGateway cleanup recovery"
            patch_file="${TEMP_DIR}/nat-gateway-uplink-recovery-patch.json"
            jq -n --arg rv "$resource_version" \
                --arg owner_key "$NAT_GATEWAY_UPLINK_OWNER_ANNOTATION" \
                --arg backup_key "$NAT_GATEWAY_UPLINK_BACKUP_ANNOTATION" \
                --arg owner "$current_owner" --arg backup "$backup_json" \
                --argjson present "$current_present" --arg value "$current_value" '
              [{op:"test",path:"/metadata/resourceVersion",value:$rv},
               {op:"test",path:("/metadata/annotations/" + ($owner_key | gsub("/";"~1"))),value:$owner},
               {op:"test",path:("/metadata/annotations/" + ($backup_key | gsub("/";"~1"))),value:$backup}]
              + (if $present then
                   [{op:"test",path:"/data/AGENTLESS_NET_EXTERNAL_INTERFACE",value:$value}]
                 else [] end)
              + [{op:"add",path:"/data/AGENTLESS_NET_EXTERNAL_INTERFACE",value:"eth2"}]' \
                >"$patch_file" \
                || die "Could not prepare guarded NATGateway uplink recovery"
            oc patch configmap "$AAP_NETWORKING_SECRET" -n "$OSAC_NAMESPACE" \
                --type=json --patch-file="$patch_file" >/dev/null \
                || die "Could not reapply the guarded NATGateway uplink override for cleanup"
            current_json="$(oc get configmap "$AAP_NETWORKING_SECRET" -n "$OSAC_NAMESPACE" -o json)" \
                || die "Could not verify the recovered NATGateway uplink override"
            jq -e --arg owner_key "$NAT_GATEWAY_UPLINK_OWNER_ANNOTATION" \
                --arg backup_key "$NAT_GATEWAY_UPLINK_BACKUP_ANNOTATION" \
                --arg owner "$current_owner" --arg backup "$backup_json" '
              .data.AGENTLESS_NET_EXTERNAL_INTERFACE == "eth2"
              and .metadata.annotations[$owner_key] == $owner
              and .metadata.annotations[$backup_key] == $backup' <<<"$current_json" >/dev/null \
                || die "network-fulfillment-ig did not retain the guarded NATGateway uplink recovery"
            info "Reapplied the NATGateway uplink override after the deployment restored its original value."
        fi
        NAT_GATEWAY_UPLINK_OWNER="$current_owner"
        NAT_GATEWAY_UPLINK_BACKUP="$backup_json"
        NAT_GATEWAY_UPLINK_EXPECTED=eth2
        NAT_GATEWAY_UPLINK_CHANGED_BY_RUN=true
        return 0
    fi
    [[ "$CLEANUP_MODE" != true ]] || return 0

    original_present="$(jq -r '.data | has("AGENTLESS_NET_EXTERNAL_INTERFACE")' <<<"$current_json")"
    original_value="$(jq -r '.data.AGENTLESS_NET_EXTERNAL_INTERFACE // ""' <<<"$current_json")"
    annotations_present="$(jq -r '(.metadata.annotations | type) == "object"' <<<"$current_json")"
    NAT_GATEWAY_UPLINK_OWNER="vlan-e2e-natgw-${DHCP_CLIENT_PREFIX}"
    NAT_GATEWAY_UPLINK_EXPECTED=eth2
    backup_json="$(jq -cn --arg owner "$NAT_GATEWAY_UPLINK_OWNER" \
        --argjson present "$original_present" --arg value "$original_value" \
        --argjson annotations_present "$annotations_present" \
        '{owner:$owner,original_present:$present,original_value:$value,
          original_annotations_present:$annotations_present}')"
    resource_version="$(jq -er '.metadata.resourceVersion' <<<"$current_json")" \
        || die "network-fulfillment-ig has no resourceVersion for a guarded NATGateway uplink update"
    patch_file="${TEMP_DIR}/nat-gateway-uplink-patch.json"
    jq -n --arg rv "$resource_version" --arg owner_key "$NAT_GATEWAY_UPLINK_OWNER_ANNOTATION" \
        --arg backup_key "$NAT_GATEWAY_UPLINK_BACKUP_ANNOTATION" \
        --arg owner "$NAT_GATEWAY_UPLINK_OWNER" --arg backup "$backup_json" \
        --arg annotations_present "$annotations_present" '
      [{op:"test",path:"/metadata/resourceVersion",value:$rv}]
      + (if $annotations_present == "true" then [] else
          [{op:"add",path:"/metadata/annotations",value:{}}] end)
      + [
          {op:"add",path:("/metadata/annotations/" + ($owner_key | gsub("/";"~1"))),value:$owner},
          {op:"add",path:("/metadata/annotations/" + ($backup_key | gsub("/";"~1"))),value:$backup},
          {op:"add",path:"/data/AGENTLESS_NET_EXTERNAL_INTERFACE",value:"eth2"}
        ]' >"$patch_file" || die "Could not prepare the guarded NATGateway uplink patch"
    oc patch configmap "$AAP_NETWORKING_SECRET" -n "$OSAC_NAMESPACE" \
        --type=json --patch-file="$patch_file" >/dev/null \
        || die "Could not install the temporary NATGateway uplink override"
    current_json="$(oc get configmap "$AAP_NETWORKING_SECRET" -n "$OSAC_NAMESPACE" -o json)" \
        || die "Could not verify the NATGateway uplink override"
    jq -e --arg owner_key "$NAT_GATEWAY_UPLINK_OWNER_ANNOTATION" \
        --arg backup_key "$NAT_GATEWAY_UPLINK_BACKUP_ANNOTATION" \
        --arg owner "$NAT_GATEWAY_UPLINK_OWNER" --arg backup "$backup_json" '
      .data.AGENTLESS_NET_EXTERNAL_INTERFACE == "eth2"
      and .metadata.annotations[$owner_key] == $owner
      and .metadata.annotations[$backup_key] == $backup' <<<"$current_json" >/dev/null \
        || die "network-fulfillment-ig did not retain the guarded NATGateway uplink override"
    NAT_GATEWAY_UPLINK_BACKUP="$backup_json"
    NAT_GATEWAY_UPLINK_CHANGED_BY_RUN=true
    info "Configured the AAP network instance group to use external interface eth2 for NATGateway jobs."
}

restore_nat_gateway_uplink() {
    local current_json resource_version backup_json patch_file owner annotations_empty_after_restore
    [[ "$NAT_GATEWAY_UPLINK_CHANGED_BY_RUN" == true ]] || return 0
    current_json="$(oc get configmap "$AAP_NETWORKING_SECRET" -n "$OSAC_NAMESPACE" -o json)" \
        || { printf 'ERROR: cannot read network-fulfillment-ig while restoring the NATGateway uplink\n' >&2; return 1; }
    owner="$(jq -r --arg key "$NAT_GATEWAY_UPLINK_OWNER_ANNOTATION" \
        '.metadata.annotations[$key] // ""' <<<"$current_json")"
    jq -e --arg owner "$NAT_GATEWAY_UPLINK_OWNER" \
        --arg owner_key "$NAT_GATEWAY_UPLINK_OWNER_ANNOTATION" \
        --arg backup_key "$NAT_GATEWAY_UPLINK_BACKUP_ANNOTATION" \
        --arg backup "$NAT_GATEWAY_UPLINK_BACKUP" '
      .metadata.annotations[$owner_key] == $owner
      and .metadata.annotations[$backup_key] == $backup
      and .data.AGENTLESS_NET_EXTERNAL_INTERFACE == "eth2"' \
        <<<"$current_json" >/dev/null \
        || { printf 'ERROR: NATGateway uplink override changed; preserving its current ConfigMap value\n' >&2; return 1; }
    jq -e --arg owner "$owner" \
        '.owner == $owner and (.original_present | type == "boolean")
         and (.original_value | type == "string")
         and (.original_annotations_present | type == "boolean")' <<<"$NAT_GATEWAY_UPLINK_BACKUP" >/dev/null \
        || { printf 'ERROR: saved NATGateway uplink recovery metadata is invalid\n' >&2; return 1; }
    annotations_empty_after_restore="$(jq -r --arg owner_key "$NAT_GATEWAY_UPLINK_OWNER_ANNOTATION" \
        --arg backup_key "$NAT_GATEWAY_UPLINK_BACKUP_ANNOTATION" \
        '((.metadata.annotations // {}) | del(.[$owner_key], .[$backup_key]) | length) == 0' \
        <<<"$current_json")"
    resource_version="$(jq -er '.metadata.resourceVersion' <<<"$current_json")" || return 1
    patch_file="${TEMP_DIR}/nat-gateway-uplink-restore.json"
    jq -n --arg rv "$resource_version" --arg owner "$owner" \
        --arg owner_key "$NAT_GATEWAY_UPLINK_OWNER_ANNOTATION" \
        --arg backup_key "$NAT_GATEWAY_UPLINK_BACKUP_ANNOTATION" \
        --argjson remove_empty_annotations "$annotations_empty_after_restore" \
        --slurpfile backup <(printf '%s\n' "$NAT_GATEWAY_UPLINK_BACKUP") '
      [{op:"test",path:"/metadata/resourceVersion",value:$rv},
       {op:"test",path:("/metadata/annotations/" + ($owner_key | gsub("/";"~1"))),value:$owner},
       {op:"test",path:"/data/AGENTLESS_NET_EXTERNAL_INTERFACE",value:"eth2"}]
      + (if $backup[0].original_present then
          [{op:"replace",path:"/data/AGENTLESS_NET_EXTERNAL_INTERFACE",value:$backup[0].original_value}]
        else [{op:"remove",path:"/data/AGENTLESS_NET_EXTERNAL_INTERFACE"}] end)
      + [{op:"remove",path:("/metadata/annotations/" + ($owner_key | gsub("/";"~1")))},
         {op:"remove",path:("/metadata/annotations/" + ($backup_key | gsub("/";"~1")))}]
      + (if ($backup[0].original_annotations_present | not)
          and $remove_empty_annotations
          then [{op:"remove",path:"/metadata/annotations"}] else [] end)' \
        >"$patch_file" || return 1
    oc patch configmap "$AAP_NETWORKING_SECRET" -n "$OSAC_NAMESPACE" \
        --type=json --patch-file="$patch_file" >/dev/null || return 1
    current_json="$(oc get configmap "$AAP_NETWORKING_SECRET" -n "$OSAC_NAMESPACE" -o json)" \
        || return 1
    jq -e --slurpfile backup <(printf '%s\n' "$NAT_GATEWAY_UPLINK_BACKUP") '
      ((.data | has("AGENTLESS_NET_EXTERNAL_INTERFACE")) == $backup[0].original_present)
      and (if $backup[0].original_present then
        .data.AGENTLESS_NET_EXTERNAL_INTERFACE == $backup[0].original_value
      else (.data | has("AGENTLESS_NET_EXTERNAL_INTERFACE") | not) end)
      and ((.metadata.annotations // {}) | has("osac.openshift.io/vlan-e2e-natgw-uplink-owner") | not)
      and ((.metadata.annotations // {}) | has("osac.openshift.io/vlan-e2e-natgw-uplink-original") | not)' \
        <<<"$current_json" >/dev/null || return 1
    NAT_GATEWAY_UPLINK_CHANGED_BY_RUN=false
    NAT_GATEWAY_UPLINK_OWNER=""
    NAT_GATEWAY_UPLINK_BACKUP=""
    info "Restored the original AgentlessNet AAP external-interface setting."
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
    local switch pending_diff key_config active_key
    [[ "$SWITCH_ACCESS_CONFIGURED" == true ]] || return 0
    while IFS= read -r switch; do
        [[ -n "$switch" ]] || continue
        [[ "${SWITCH_NVUE_KEY_INSTALLED_BY_RUN[$switch]:-false}" == true ]] || continue
        pending_diff="$(switch_nvue_diff admin "$switch")" || {
            printf 'ERROR: could not inspect NVUE changes before provider-key cleanup on %s\n' "$switch" >&2
            return 1
        }
        if [[ -n "$pending_diff" ]] && grep -Fv -- "$PROVIDER_NVUE_KEY_ID" <<<"$pending_diff" | grep -q .; then
            printf 'ERROR: unrelated NVUE candidate changes exist on %s; preserving them and the provider key\n' "$switch" >&2
            return 1
        fi
        key_config="$(switch_admin_user_exec "$switch" nv show system aaa user cumulus ssh authorized-key --output json)" || {
            printf 'ERROR: could not inspect NVUE authorized keys before provider-key cleanup on %s\n' "$switch" >&2
            return 1
        }
        active_key=false
        if jq -e --arg id "$PROVIDER_NVUE_KEY_ID" 'has($id)' <<<"$key_config" >/dev/null; then
            active_key=true
        fi
        if [[ "$active_key" == true ]] || grep -Fq -- "$PROVIDER_NVUE_KEY_ID" <<<"$pending_diff"; then
            switch_admin_user_exec "$switch" nv unset system aaa user cumulus ssh authorized-key \
                "$PROVIDER_NVUE_KEY_ID" || {
                printf 'ERROR: could not stage removal of the per-run NVUE key on %s\n' "$switch" >&2
                return 1
            }
            pending_diff="$(switch_nvue_diff admin "$switch")" || {
                printf 'ERROR: could not inspect NVUE provider-key removal on %s\n' "$switch" >&2
                return 1
            }
            if [[ -n "$pending_diff" ]] && grep -Fv -- "$PROVIDER_NVUE_KEY_ID" <<<"$pending_diff" | grep -q .; then
                printf 'ERROR: unrelated NVUE candidate changes appeared on %s; preserving them\n' "$switch" >&2
                return 1
            fi
            if [[ -n "$pending_diff" ]]; then
                switch_admin_user_exec "$switch" nv config apply --assume-yes || {
                    printf 'ERROR: could not apply provider-key removal on %s\n' "$switch" >&2
                    return 1
                }
            fi
        fi
        key_config="$(switch_admin_user_exec "$switch" nv show system aaa user cumulus ssh authorized-key --output json)" || {
            printf 'ERROR: could not verify NVUE provider-key cleanup on %s\n' "$switch" >&2
            return 1
        }
        if jq -e --arg id "$PROVIDER_NVUE_KEY_ID" 'has($id)' <<<"$key_config" >/dev/null; then
            printf 'ERROR: per-run NVUE provider key remains configured on %s\n' "$switch" >&2
            return 1
        fi
        pending_diff="$(switch_nvue_diff admin "$switch")" || return 1
        [[ -z "$pending_diff" ]] || {
            printf 'ERROR: NVUE candidate changes remain after provider-key cleanup on %s\n' "$switch" >&2
            return 1
        }
        SWITCH_NVUE_KEY_INSTALLED_BY_RUN["$switch"]=false
    done < <(jq -r '.switches[].name' "$SWITCH_MANIFEST_FILE")
}

restore_containerlab_switch_access() {
    local switch
    [[ "$SWITCH_ACCESS_CONFIGURED" == true ]] || return 0
    while IFS= read -r switch; do
        [[ -n "$switch" ]] || continue
        if [[ "${SWITCH_SUDOERS_CREATED_BY_RUN[$switch]:-false}" == true ]]; then
            switch_admin_exec "$switch" sh -c '
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
      fulfillment: {
        image: {
          repository: .service.images.service.repository,
          tag: .service.images.service.tag
        }
      },
      service: {
        eventPublisherEnabled: (.service.eventPublisher.enabled // false)
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
    python3 - "$previous_json" "$previous_yaml" \
        "${INSTALLER_DIR}/values/${OSAC_PROFILE}/instance.yaml" <<'PY'
import json
import os
import pathlib
import sys
import yaml

source_path, output_path, profile_path = sys.argv[1:]
with open(source_path, encoding="utf-8") as stream:
    values = json.load(stream)
if not isinstance(values, dict):
    raise SystemExit("Existing Helm values must be a mapping")
with open(profile_path, encoding="utf-8") as stream:
    profile_values = yaml.safe_load(stream) or {}

# This development release predates removal of the CSI subcharts and VAST
# storage-operations credential values from the current umbrella chart.
values.pop("csiBackends", None)
values.pop("csiDriver", None)

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
        storage_fulfillment = instance_groups.get("storageFulfillment")
        if isinstance(storage_fulfillment, dict):
            secret = storage_fulfillment.get("secret")
            if isinstance(secret, dict):
                for name in ("VAST_ENDPOINT", "VAST_PASSWORD", "VAST_USERNAME"):
                    secret.pop(name, None)
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
                # Older lab releases used an empty DNS_CLASS to disable
                # external DNS; the current schema requires a fully-qualified
                # driver name.
                if config.get("DNS_CLASS") == "":
                    config["DNS_CLASS"] = "dns.noop.dns"

operator = values.get("operator")
if isinstance(operator, dict):
    stall = operator.get("stall")
    if isinstance(stall, dict):
        stall.pop("workersJoiningByHostType", None)
    fulfillment = operator.get("fulfillment")
    if isinstance(fulfillment, dict):
        fulfillment.pop("tokenFile", None)

metering = values.get("metering")
if isinstance(metering, dict):
    metering.pop("enabled", None)
    metering.pop("reconciliation", None)

# Older lab releases may lack the diskImage required for their default
# ClusterVersion. Backfill it from the selected profile's current values.
profile_cluster_versions = profile_values.get("clusterVersions", {})
profile_versions = {
    version.get("version"): version
    for version in profile_cluster_versions.get("versions", [])
}
cluster_versions = values.get("clusterVersions", {})
for version in cluster_versions.get("versions", []):
    if version.get("default") and "diskImage" not in version:
        current = profile_versions.get(version.get("version"), {})
        if "diskImage" in current:
            version["diskImage"] = current["diskImage"]

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

# Calls one private Fulfillment RPC. A fresh token and short-lived port-forward
# are used for each call so the token cannot expire during the long VLAN run.
external_ip_pool_rpc() (
    local method="$1" request_file="$2" response_file="$3" error_file="$4"
    local local_port="" port_forward_log="" port_forward_pid="" admin_token=""
    local attempt

    case "$method" in
        Create|Get|Delete|List) ;;
        *)
            printf 'Unsupported ExternalIPPool RPC method: %s\n' "$method" >&2
            return 1
            ;;
    esac
    [[ -f "$request_file" && -d "$TEMP_DIR" ]] || {
        printf 'ExternalIPPool RPC request or temporary directory is missing\n' >&2
        return 1
    }
    : >"$response_file" || return 1
    : >"$error_file" || return 1

    local_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')" \
        || return 1
    port_forward_log="${TEMP_DIR}/external-ip-pool-${method}-port-forward.log"
    cleanup_external_ip_pool_port_forward() {
        if [[ -n "$port_forward_pid" ]]; then
            kill "$port_forward_pid" >/dev/null 2>&1 || true
            wait "$port_forward_pid" 2>/dev/null || true
            port_forward_pid=""
        fi
    }
    trap cleanup_external_ip_pool_port_forward EXIT

    oc port-forward --address 127.0.0.1 service/fulfillment-internal-api \
        "${local_port}:8001" -n "$OSAC_NAMESPACE" >"$port_forward_log" 2>&1 &
    port_forward_pid=$!
    for ((attempt = 1; attempt <= 30; attempt++)); do
        if grep -Fq "Forwarding from 127.0.0.1:${local_port}" "$port_forward_log"; then
            break
        fi
        if ! kill -0 "$port_forward_pid" 2>/dev/null; then
            cat "$port_forward_log" >&2
            return 1
        fi
        sleep 1
    done
    if ! grep -Fq "Forwarding from 127.0.0.1:${local_port}" "$port_forward_log"; then
        cat "$port_forward_log" >&2
        return 1
    fi

    admin_token="$(oc create token admin -n "$OSAC_NAMESPACE" --duration=10m)" || return 1
    if grpcurl -insecure -connect-timeout 5 -max-time 20 -format json -format-error \
        -H "authorization: Bearer ${admin_token}" -d @ \
        "127.0.0.1:${local_port}" "osac.private.v1.ExternalIPPools/${method}" \
        <"$request_file" >"$response_file" 2>"$error_file"; then
        unset admin_token
        return 0
    fi
    unset admin_token
    return 1
)

external_ip_pool_list_items() {
    jq -ce '
        if . == {} then []
        elif (.items | type) == "array" then .items
        else error("items is not an array")
        end' "$1"
}

cleanup_cli_list_json() {
    local resource="$1" filter="$2" output
    [[ -n "$CLI_BIN" && -x "$CLI_BIN" && -n "$CLI_CONFIG_DIR" && -d "$CLI_CONFIG_DIR" ]] \
        || die "Fulfillment CLI is unavailable for suite cleanup"
    output="$("$CLI_BIN" --config "$CLI_CONFIG_DIR" --tenant "$OSAC_TENANT" \
        get "$resource" --filter "$filter" --output json)" \
        || die "Could not list test-owned ${resource} resources for cleanup"
    jq -ce '
      if type == "array" then .
      elif type == "object" and has("id") then [.]
      else error("Fulfillment CLI returned an invalid cleanup list")
      end' <<<"$output"
}

cleanup_subnet_parent_id() {
    jq -er '(.spec.virtual_network // .spec.virtualNetwork) as $parent
      | if ($parent | type) == "string" then $parent else $parent.id end' <<<"$1"
}

cleanup_name_filter() {
    local default_prefix="$1" custom_prefix="$2"
    python3 - "$default_prefix" "$custom_prefix" <<'PY'
import json
import sys

prefixes = [sys.argv[1]]
if sys.argv[2] and sys.argv[2] not in prefixes:
    prefixes.append(sys.argv[2])
print("(" + " || ".join(
    "this.metadata.name.startsWith(" + json.dumps(prefix) + ")"
    for prefix in prefixes
) + ")")
PY
}

cleanup_array_json() {
    if (($# == 0)); then
        printf '[]\n'
    else
        printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0))'
    fi
}

resolve_external_ip_pool_cidr() {
    [[ "$EXTERNAL_IP_POOL_CIDR_RESOLVED" == false ]] || return 0

    local request_file="${TEMP_DIR}/external-ip-pool-cidr-list.request.json"
    local response_file="${TEMP_DIR}/external-ip-pool-cidr-list.response.json"
    local error_file="${TEMP_DIR}/external-ip-pool-cidr-list.error.json"
    local pool_items pool_cidrs selected_cidr
    jq -n '{filter:"this.metadata.tenant == \"shared\""}' >"$request_file" \
        || die "Could not write shared ExternalIPPool CIDR lookup request"
    if ! external_ip_pool_rpc List "$request_file" "$response_file" "$error_file"; then
        cat "$error_file" >&2
        die "Could not inspect shared ExternalIPPool CIDRs before the E2E run"
    fi
    pool_items="$(external_ip_pool_list_items "$response_file")" \
        || die "Private Fulfillment List returned an invalid ExternalIPPool response"
    pool_cidrs="$(jq -ce '[.[] | {name:(.metadata.name // "unknown"),cidrs:.spec.cidrs}]' \
        <<<"$pool_items")" \
        || die "Could not read CIDRs from existing shared ExternalIPPools"
    if ! selected_cidr="$(EXTERNAL_POOL_LIST_JSON="$pool_cidrs" \
        python3 - "$EXTERNAL_IP_POOL_CIDR_EXPLICIT" "$EXTERNAL_IP_POOL_CIDR" <<'PY'
import ipaddress
import json
import os
import sys

explicit, requested = sys.argv[1:]
pools = json.loads(os.environ["EXTERNAL_POOL_LIST_JSON"])
existing = []
for pool in pools:
    cidrs = pool.get("cidrs")
    if not isinstance(cidrs, list):
        raise SystemExit(f"shared ExternalIPPool {pool.get('name', 'unknown')} has no CIDR list")
    for value in cidrs:
        try:
            network = ipaddress.ip_network(value, strict=True)
        except (TypeError, ValueError) as error:
            raise SystemExit(f"shared ExternalIPPool has invalid CIDR {value!r}") from error
        existing.append((pool.get("name", "unknown"), network))

if explicit == "true":
    try:
        candidate = ipaddress.ip_network(requested, strict=True)
    except ValueError as error:
        raise SystemExit(f"EXTERNAL_IP_POOL_CIDR must be a canonical CIDR: {error}") from error
    if not isinstance(candidate, ipaddress.IPv4Network) or str(candidate) != requested:
        raise SystemExit("EXTERNAL_IP_POOL_CIDR must be a canonical IPv4 CIDR")
    conflict = next(((name, network) for name, network in existing if candidate.overlaps(network)), None)
    if conflict:
        raise SystemExit(
            f"EXTERNAL_IP_POOL_CIDR {candidate} overlaps existing shared pool "
            f"{conflict[0]} CIDR {conflict[1]}"
        )
else:
    candidate = None
    for option in ipaddress.ip_network("198.18.0.0/15").subnets(new_prefix=24):
        if not any(option.overlaps(network) for _, network in existing):
            candidate = option
            break
    if candidate is None:
        raise SystemExit("No free /24 test CIDR remains in 198.18.0.0/15; set EXTERNAL_IP_POOL_CIDR")

print(candidate)
PY
    )"; then
        return 1
    fi
    EXTERNAL_IP_POOL_CIDR="$selected_cidr"
    EXTERNAL_IP_POOL_CIDR_RESOLVED=true
    info "Selected non-overlapping ExternalIPPool test CIDR ${EXTERNAL_IP_POOL_CIDR}."
}

external_ip_pool_rpc_error_is_not_found() {
    local response_file
    for response_file in "$@"; do
        [[ -s "$response_file" ]] || continue
        if jq -e '(.code | type == "number") and .code == 5' "$response_file" \
            >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

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

external_ip_pool_crs_json() {
    local id="$1" selector json
    selector="$(external_ip_pool_label_selector "$id")"
    json="$(oc get externalippools -n "$NETWORKING_NAMESPACE" -l "$selector" \
        -o json --request-timeout=20s)" || return 1
    jq -ce --arg id "$id" --arg namespace "$NETWORKING_NAMESPACE" '
      if (.items | type) != "array" then
        error("ExternalIPPool list response has no items array")
      elif any(.items[]; .metadata.namespace != $namespace
               or .metadata.labels["osac.openshift.io/externalippool-uuid"] != $id) then
        error("ExternalIPPool list contains a resource with mismatched identity")
      else . end' <<<"$json"
}

external_ip_pool_validate_cr_identity() {
    local cr_json="$1" id="$2"
    jq -e --arg id "$id" --arg namespace "$NETWORKING_NAMESPACE" \
        --arg cidr "$EXTERNAL_IP_POOL_CIDR" '
      (.metadata.namespace == $namespace)
      and (.metadata.labels["osac.openshift.io/externalippool-uuid"] == $id)
      and (.metadata.annotations["osac.openshift.io/tenant"] == "shared")
      and (.metadata.uid | type == "string"
           and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
      and (.metadata.uid != $id)
      and (.spec.ipFamily == "IPv4")
      and (.spec.cidrs == [$cidr])' <<<"$cr_json" >/dev/null
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

subnet_fulfillment_state() {
    local id="$1" description state
    description="$("$CLI_BIN" --config "$CLI_CONFIG_DIR" --tenant "$OSAC_TENANT" \
        describe subnet "$id")" \
        || die "Fulfillment API failed while observing Subnet ${id} ordering"
    state="$(awk -F': *' '$1 == "State" {print $2}' <<<"$description")"
    [[ -n "$state" ]] || die "Fulfillment returned no state for Subnet ${id}"
    printf '%s\n' "$state"
}

wait_for_subnet_cr_created() {
    local id="$1" parent_id="$2" selector json count
    selector="$(subnet_label_selector "$id")"
    for ((attempt = 1; attempt <= 120; attempt++)); do
        json="$(oc get subnets -n "$NETWORKING_NAMESPACE" -l "$selector" \
            -o json --request-timeout=20s)" \
            || die "Kubernetes API failed while waiting for Subnet UUID ${id}"
        count="$(jq -er '.items | length' <<<"$json")" \
            || die "Could not count Subnet CRs for UUID ${id}"
        [[ "$count" -le 1 ]] || die "Found multiple Subnet CRs for UUID ${id}"
        if [[ "$count" == 1 ]]; then
            subnet_cr_json "$id" "$parent_id"
            return 0
        fi
        sleep 2
    done
    die "Timed out waiting for Subnet UUID ${id} CR creation"
}

wait_for_subnet_aap_provision_success() {
    local id="$1" parent_id="$2" job_id="$3" cr_json job_state
    for ((attempt = 1; attempt <= 120; attempt++)); do
        cr_json="$(subnet_cr_json "$id" "$parent_id")"
        job_state="$(jq -r --arg id "$job_id" \
            '[.status.provisioningJobs[]? | select(.jobID == $id) | .state] | last // ""' \
            <<<"$cr_json")"
        case "$job_state" in
            Succeeded)
                assert_provider_key_survived "AAP Subnet job ${job_id}"
                return 0
                ;;
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

wait_for_external_ip_pool_ready() {
    local id="$1" deadline=$((SECONDS + 600))
    local pool_crs pool_cr pool_count phase provision_job provision_job_id provision_state
    local get_request get_response get_error pool_state
    get_request="${TEMP_DIR}/external-ip-pool-get.request.json"
    get_response="${TEMP_DIR}/external-ip-pool-get.response.json"
    get_error="${TEMP_DIR}/external-ip-pool-get.error.json"
    jq -n --arg id "$id" '{id: $id}' >"$get_request" \
        || die "Could not write ExternalIPPool Get request"

    info "Waiting for ExternalIPPool ${id} to become READY..."
    while ((SECONDS < deadline)); do
        if ! pool_crs="$(external_ip_pool_crs_json "$id")"; then
            die "Kubernetes API failed while looking up ExternalIPPool UUID ${id}"
        fi
        pool_count="$(jq -er '.items | length' <<<"$pool_crs")" \
            || die "Could not count ExternalIPPool CRs for UUID ${id}"
        if [[ "$pool_count" -gt 1 ]]; then
            die "Expected one ExternalIPPool CR for Fulfillment UUID ${id}; found ${pool_count}"
        fi
        if [[ "$pool_count" == 1 ]]; then
            pool_cr="$(jq -c '.items[0]' <<<"$pool_crs")"
            external_ip_pool_validate_cr_identity "$pool_cr" "$id" \
                || die "ExternalIPPool CR identity or spec does not match Fulfillment UUID ${id}"
            EXTERNAL_IP_POOL_K8S_UID="$(jq -er '.metadata.uid' <<<"$pool_cr")" \
                || die "ExternalIPPool CR has no Kubernetes UID"
            phase="$(jq -r '.status.phase // ""' <<<"$pool_cr")"
            provision_job="$(jq -c '
              [.status.provisioningJobs[]? | select(.type == "provision")]
              | last // {}' <<<"$pool_cr")"
            provision_job_id="$(jq -r '.jobID // ""' <<<"$provision_job")"
            provision_state="$(jq -r '.state // ""' <<<"$provision_job")"
            [[ -z "$provision_job_id" ]] \
                || EXTERNAL_IP_POOL_CREATE_AAP_JOB_ID="$provision_job_id"
            [[ "$phase" != Failed ]] \
                || die "ExternalIPPool ${id} entered Failed phase"
            [[ "$provision_state" != Failed && "$provision_state" != Canceled ]] \
                || die "AAP provision job ${provision_job_id} ended in ${provision_state} for ExternalIPPool ${id}"

            if [[ "$phase" == Ready && "$provision_state" == Succeeded \
                && -n "$provision_job_id" ]]; then
                jq -e '.metadata.annotations["osac.openshift.io/implementation-strategy"] == "agentless_net"' \
                    <<<"$pool_cr" >/dev/null \
                    || die "ExternalIPPool ${id} did not resolve to the AgentlessNet implementation"
                if ! external_ip_pool_rpc Get "$get_request" "$get_response" "$get_error"; then
                    cat "$get_error" >&2
                    die "Fulfillment API failed while reading ExternalIPPool ${id} status"
                fi
                jq -e --arg id "$id" --arg cidr "$EXTERNAL_IP_POOL_CIDR" '
                  .object.id == $id
                  and .object.metadata.tenant == "shared"
                  and .object.spec.ipFamily == "IP_FAMILY_IPV4"
                  and .object.spec.cidrs == [$cidr]' \
                    "$get_response" >/dev/null \
                    || die "Fulfillment ExternalIPPool ${id} response has mismatched identity or spec"
                pool_state="$(jq -r '.object.status.state // ""' "$get_response")"
                case "$pool_state" in
                    EXTERNAL_IP_POOL_STATE_READY)
                        jq -e '((.object.status.allocated // 0 | tonumber) == 0)' \
                            "$get_response" >/dev/null \
                            || die "ExternalIPPool ${id} unexpectedly has allocated addresses"
                        return 0
                        ;;
                    EXTERNAL_IP_POOL_STATE_FAILED|EXTERNAL_IP_POOL_STATE_DELETE_FAILED)
                        die "Fulfillment ExternalIPPool ${id} entered ${pool_state}"
                        ;;
                esac
            fi
        fi
        sleep 5
    done
    die "Timed out waiting for ExternalIPPool ${id} to become READY"
}

external_ip_pool_state_is_absent() {
    local uid="$1" id="$2" snapshot
    if ! snapshot="$(state_snapshot)"; then
        printf 'Could not read AgentlessNet state while checking ExternalIPPool cleanup\n' >&2
        return 1
    fi
    jq -e --arg uid "$uid" --arg id "$id" '
      .schema_version == 1
      and all(.external_ip_pools[]; .uid != $uid and .fulfillment_id != $id)' \
        <<<"$snapshot" >/dev/null 2>&1
}

wait_for_external_ip_pool_removed() {
    local id="$1" uid="$2" deadline=$((SECONDS + 600))
    local pool_crs pool_cr pool_count deprovision_job deprovision_job_id deprovision_state
    local get_request get_response get_error
    get_request="${TEMP_DIR}/external-ip-pool-get.request.json"
    get_response="${TEMP_DIR}/external-ip-pool-get.response.json"
    get_error="${TEMP_DIR}/external-ip-pool-get.error.json"
    jq -n --arg id "$id" '{id: $id}' >"$get_request" \
        || { printf 'Could not write ExternalIPPool Get request\n' >&2; return 1; }

    while ((SECONDS < deadline)); do
        if ! pool_crs="$(external_ip_pool_crs_json "$id")"; then
            printf 'Kubernetes API failed while checking ExternalIPPool UUID %s deletion\n' "$id" >&2
            return 1
        fi
        if ! pool_count="$(jq -er '.items | length' <<<"$pool_crs")"; then
            printf 'Could not count ExternalIPPool CRs for UUID %s\n' "$id" >&2
            return 1
        fi
        if [[ "$pool_count" -gt 1 ]]; then
            printf 'Found multiple ExternalIPPool CRs for UUID %s during deletion\n' "$id" >&2
            return 1
        fi
        if [[ "$pool_count" == 1 ]]; then
            pool_cr="$(jq -c '.items[0]' <<<"$pool_crs")"
            if ! external_ip_pool_validate_cr_identity "$pool_cr" "$id"; then
                printf 'ExternalIPPool CR identity changed during deletion of UUID %s\n' "$id" >&2
                return 1
            fi
            deprovision_job="$(jq -c '
              [.status.provisioningJobs[]? | select(.type == "deprovision")]
              | last // {}' <<<"$pool_cr")"
            deprovision_job_id="$(jq -r '.jobID // ""' <<<"$deprovision_job")"
            deprovision_state="$(jq -r '.state // ""' <<<"$deprovision_job")"
            [[ -z "$deprovision_job_id" ]] \
                || EXTERNAL_IP_POOL_DELETE_AAP_JOB_ID="$deprovision_job_id"
            if [[ "$deprovision_state" == Failed || "$deprovision_state" == Canceled ]]; then
                printf 'AAP deprovision job %s ended in %s for ExternalIPPool %s\n' \
                    "$deprovision_job_id" "$deprovision_state" "$id" >&2
                return 1
            fi
        fi

        if ! external_ip_pool_rpc Get "$get_request" "$get_response" "$get_error"; then
            if ! external_ip_pool_rpc_error_is_not_found "$get_error" "$get_response"; then
                cat "$get_error" >&2
                printf 'Fulfillment API failed while checking ExternalIPPool UUID %s deletion\n' "$id" >&2
                return 1
            fi
            if [[ "$pool_count" == 0 ]] && external_ip_pool_state_is_absent "$uid" "$id"; then
                return 0
            fi
        fi
        sleep 5
    done
    printf 'Timed out waiting for ExternalIPPool UUID %s and its provider state to be deleted\n' "$id" >&2
    return 1
}

wait_for_aap_provision_success() {
    local fulfillment_id="$1" job_id="$2" cr_json job_state
    for ((attempt = 1; attempt <= 180; attempt++)); do
        cr_json="$(virtual_network_cr_json "$fulfillment_id")"
        job_state="$(jq -r --arg id "$job_id" \
            '[.status.provisioningJobs[]? | select(.jobID == $id) | .state] | last // ""' \
            <<<"$cr_json")"
        case "$job_state" in
            Succeeded)
                assert_provider_key_survived "AAP VirtualNetwork job ${job_id}"
                return 0
                ;;
            Failed|Canceled)
                die "AAP provision job ${job_id} ended in ${job_state} for test resource ${fulfillment_id}"
                ;;
        esac
        sleep 2
    done
    die "Timed out waiting for AAP provision job ${job_id} to succeed"
}

external_ip_crs_json() {
    local id="$1" selector
    selector="$(external_ip_label_selector "$id")"
    oc get externalips -n "$NETWORKING_NAMESPACE" -l "$selector" \
        -o json --request-timeout=20s
}

external_ip_cr_json() {
    local id="$1" expected_pool="${2-${EXTERNAL_IP_POOL_ID:-}}" json
    json="$(external_ip_crs_json "$id")" \
        || die "Kubernetes API failed while looking up ExternalIP UUID ${id}"
    jq -ce --arg id "$id" --arg pool "$expected_pool" \
        --arg tenant "$OSAC_TENANT" --arg namespace "$NETWORKING_NAMESPACE" '
      if (.items | length) != 1 then
        error("expected one ExternalIP CR for Fulfillment UUID " + $id)
      else
        .items[0] as $ip
        | if $ip.metadata.labels["osac.openshift.io/externalip-uuid"] != $id then
            error("ExternalIP UUID label does not match the requested resource")
          elif $ip.metadata.annotations["osac.openshift.io/tenant"] != $tenant then
            error("ExternalIP tenant annotation does not match the test tenant")
          elif $ip.metadata.annotations["osac.openshift.io/implementation-strategy"] != "agentless_net" then
            error("ExternalIP did not resolve to AgentlessNet")
          elif $ip.metadata.annotations["osac.openshift.io/externalip-contract-version"] != "v1" then
            error("ExternalIP is not using the v1 contract")
          elif $ip.metadata.namespace != $namespace or ($pool != "" and $ip.spec.pool != $pool) then
            error("ExternalIP namespace or pool does not match the test request")
          else $ip end
      end' <<<"$json"
}

external_ip_attachment_crs_json() {
    local selector
    selector="$(external_ip_attachment_label_selector "$1")"
    oc get externalipattachments -n "$NETWORKING_NAMESPACE" -l "$selector" \
        -o json --request-timeout=20s
}

external_ip_attachment_cr_json() {
    local id="$1" json
    json="$(external_ip_attachment_crs_json "$id")" \
        || die "Kubernetes API failed while looking up ExternalIPAttachment UUID ${id}"
    jq -ce --arg id "$id" --arg tenant "$OSAC_TENANT" \
        --arg namespace "$NETWORKING_NAMESPACE" '
      if (.items | length) != 1 then
        error("expected one ExternalIPAttachment CR for Fulfillment UUID " + $id)
      else
        .items[0] as $attachment
        | if $attachment.metadata.labels["osac.openshift.io/externalipattachment-uuid"] != $id then
            error("ExternalIPAttachment UUID label does not match the requested resource")
          elif $attachment.metadata.annotations["osac.openshift.io/tenant"] != $tenant then
            error("ExternalIPAttachment tenant annotation does not match the test tenant")
          elif $attachment.metadata.annotations["osac.openshift.io/implementation-strategy"] != "agentless_net" then
            error("ExternalIPAttachment did not resolve to AgentlessNet")
          elif $attachment.metadata.annotations["osac.openshift.io/externalipattachment-contract-version"] != "v1" then
            error("ExternalIPAttachment is not using the v1 contract")
          elif $attachment.metadata.namespace != $namespace then
            error("ExternalIPAttachment is in an unexpected namespace")
          elif ($attachment.metadata.name | startswith("agentless-eip-attach-") | not) then
            error("ExternalIPAttachment is outside the test name scope")
          else $attachment end
      end' <<<"$json"
}

nat_gateway_crs_json() {
    local selector
    selector="$(nat_gateway_label_selector "$1")"
    oc get natgateways -n "$NETWORKING_NAMESPACE" -l "$selector" \
        -o json --request-timeout=20s
}

nat_gateway_cr_json() {
    local id="$1" expected_virtual_network="$2" expected_external_ip="$3" json
    json="$(nat_gateway_crs_json "$id")" \
        || die "Kubernetes API failed while looking up NATGateway UUID ${id}"
    jq -ce --arg id "$id" --arg tenant "$OSAC_TENANT" \
        --arg namespace "$NETWORKING_NAMESPACE" \
        --arg virtual_network "$expected_virtual_network" \
        --arg external_ip "$expected_external_ip" '
      if (.items | length) != 1 then
        error("expected one NATGateway CR for Fulfillment UUID " + $id)
      else
        .items[0] as $gateway
        | if $gateway.metadata.labels["osac.openshift.io/natgateway-uuid"] != $id then
            error("NATGateway UUID label does not match the requested resource")
          elif $gateway.metadata.annotations["osac.openshift.io/tenant"] != $tenant then
            error("NATGateway tenant annotation does not match the test tenant")
          elif $gateway.metadata.annotations["osac.openshift.io/implementation-strategy"] != "agentless_net" then
            error("NATGateway did not resolve to AgentlessNet")
          elif $gateway.metadata.annotations["osac.openshift.io/natgateway-contract-version"] != "v1" then
            error("NATGateway is not using the v1 contract")
          elif $gateway.metadata.namespace != $namespace then
            error("NATGateway is in an unexpected namespace")
          elif $gateway.spec.virtualNetwork != $virtual_network
            or $gateway.spec.externalIP != $external_ip then
            error("NATGateway dependency references do not match the test request")
          else $gateway end
      end' <<<"$json"
}

baremetal_instance_crs_json() {
    local selector
    selector="$(baremetal_instance_label_selector "$1")"
    oc get baremetalinstances -A -l "$selector" -o json --request-timeout=20s
}

baremetal_instance_cr_json() {
    local id="$1" json
    json="$(baremetal_instance_crs_json "$id")" \
        || die "Kubernetes API failed while looking up BareMetalInstance UUID ${id}"
    jq -ce --arg id "$id" --arg tenant "$OSAC_TENANT" '
      if (.items | length) != 1 then
        error("expected one BareMetalInstance CR for Fulfillment UUID " + $id)
      else
        .items[0] as $instance
        | if $instance.metadata.labels["osac.openshift.io/baremetalinstance-uuid"] != $id then
            error("BareMetalInstance UUID label does not match the requested resource")
          elif $instance.metadata.annotations["osac.openshift.io/tenant"] != $tenant then
            error("BareMetalInstance tenant annotation does not match the test tenant")
          elif ($instance.metadata.name | startswith("agentless-eip-bmi-") | not) then
            error("BareMetalInstance is outside the test name scope")
          else $instance end
      end' <<<"$json"
}

external_ip_attachment_assert_result() {
    local artifacts="$1" operation="$2" uid="$3" generation="$4"
    jq -e --arg operation "$operation" --arg uid "$uid" \
        --argjson generation "$generation" '
      .osac_result as $result
      | $result.schemaVersion == "v1"
        and $result.operation == $operation
        and $result.resourceUID == $uid
        and $result.observedGeneration == $generation
        and $result.data == {}' <<<"$artifacts" >/dev/null
}

external_ip_attachment_state_entry() {
    local uid="$1" fulfillment_id="$2"
    save_current_state
    jq -ceS --arg uid "$uid" --arg id "$fulfillment_id" '
      [.external_ip_attachments[] | select(.uid == $uid and .fulfillment_id == $id)]
      | if length == 1 then .[0] else error("expected one saved ExternalIPAttachment") end' \
        "$CURRENT_STATE_FILE"
}

write_synthetic_external_ip_attachment_attach_vars() {
    local attachment_id="$1" attachment_uid="$2" attachment_name="$3"
    local external_ip_id="$4" external_ip_uid="$5" external_ip_name="$6" external_address="$7"
    local subnet_id="$8" subnet_uid="$9" subnet_name="${10}" subnet_cidr="${11}"
    local virtual_network_id="${12}" virtual_network_uid="${13}" virtual_network_name="${14}"
    local tenant="${15}" namespace="${16}" target_id="${17}" target_uid="${18}"
    local target_name="${19}" target_namespace="${20}" target_ip="${21}" output_file="${22}"
    local external_interface="${23}"
    python3 - "$attachment_id" "$attachment_uid" "$attachment_name" \
        "$external_ip_id" "$external_ip_uid" "$external_ip_name" "$external_address" \
        "$subnet_id" "$subnet_uid" "$subnet_name" "$subnet_cidr" \
        "$virtual_network_id" "$virtual_network_uid" "$virtual_network_name" \
        "$tenant" "$namespace" "$target_id" "$target_uid" "$target_name" \
        "$target_namespace" "$target_ip" "$output_file" "$external_interface" <<'PY'
import json
import pathlib
import sys

(
    attachment_id, attachment_uid, attachment_name,
    external_ip_id, external_ip_uid, external_ip_name, external_address,
    subnet_id, subnet_uid, subnet_name, subnet_cidr,
    virtual_network_id, virtual_network_uid, virtual_network_name,
    tenant, namespace, target_id, target_uid, target_name,
    target_namespace, target_ip, output_path, external_interface,
) = sys.argv[1:]

attachment = {
    "apiVersion": "osac.openshift.io/v1alpha1",
    "kind": "ExternalIPAttachment",
    "metadata": {
        "name": attachment_name,
        "namespace": namespace,
        "uid": attachment_uid,
        "generation": 1,
        "labels": {"osac.openshift.io/externalipattachment-uuid": attachment_id},
        "annotations": {
            "osac.openshift.io/tenant": tenant,
            "osac.openshift.io/owner-reference": "vlan-e2e-run",
            "osac.openshift.io/implementation-strategy": "agentless_net",
            "osac.openshift.io/externalipattachment-contract-version": "v1",
        },
    },
    "spec": {
        "externalIP": external_ip_id,
        "baremetalInstance": target_id,
    },
}
context = {
    "external_ip": {
        "name": external_ip_name,
        "namespace": namespace,
        "fulfillment_id": external_ip_id,
        "kubernetes_uid": external_ip_uid,
        "tenant_id": tenant,
        "address": external_address,
        "state": "Allocated",
        "phase": "Ready",
    },
    "target": {
        "kind": "BareMetalInstance",
        "name": target_name,
        "namespace": target_namespace,
        "fulfillment_id": target_id,
        "kubernetes_uid": target_uid,
        "tenant_id": tenant,
        "ip_address": target_ip,
        "ready": True,
    },
    "subnet": {
        "name": subnet_name,
        "namespace": namespace,
        "fulfillment_id": subnet_id,
        "kubernetes_uid": subnet_uid,
        "tenant_id": tenant,
        "ipv4_cidr": subnet_cidr,
        "virtual_network_id": virtual_network_id,
        "phase": "Ready",
    },
    "virtual_network": {
        "name": virtual_network_name,
        "namespace": namespace,
        "fulfillment_id": virtual_network_id,
        "kubernetes_uid": virtual_network_uid,
        "tenant_id": tenant,
        "phase": "Ready",
    },
}
output = pathlib.Path(output_path)
output.write_text(json.dumps({
    "agentless_net_external_interface": external_interface,
    "osac_job_vars": {
        "resource": attachment,
        "external_ip_attachment_context": context,
    },
}, separators=(",", ":")) + "\n")
output.chmod(0o600)
PY
}

write_synthetic_external_ip_attachment_detach_vars() {
    local entry="$1" output_file="$2"
    python3 - "$entry" "$output_file" <<'PY'
import datetime
import json
import pathlib
import sys

entry = json.loads(sys.argv[1])
context = entry["payload"]["context"]
external_ip = context["external_ip"]
target = context["target"]
tenant = entry["tenant_id"]
resource = {
    "apiVersion": "osac.openshift.io/v1alpha1",
    "kind": "ExternalIPAttachment",
    "metadata": {
        "name": f"agentless-eip-attach-{entry['fulfillment_id'][:8]}",
        "namespace": external_ip["namespace"],
        "uid": entry["uid"],
        "generation": 1,
        "deletionTimestamp": datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "labels": {
            "osac.openshift.io/externalipattachment-uuid": entry["fulfillment_id"],
        },
        "annotations": {
            "osac.openshift.io/tenant": tenant,
            "osac.openshift.io/owner-reference": "vlan-e2e-run",
            "osac.openshift.io/implementation-strategy": "agentless_net",
            "osac.openshift.io/externalipattachment-contract-version": "v1",
        },
    },
    "spec": {
        "externalIP": external_ip["fulfillment_id"],
        "baremetalInstance": target["fulfillment_id"],
    },
}
output = pathlib.Path(sys.argv[2])
output.write_text(json.dumps({"osac_job_vars": {"resource": resource}}, separators=(",", ":")) + "\n")
output.chmod(0o600)
PY
}

run_synthetic_external_ip_attachment_attach_job() {
    local attachment_id="$1" attachment_uid="$2" attachment_name="$3"
    local external_ip_id="$4" external_ip_uid="$5" external_ip_name="$6" external_address="$7"
    local output_file="$8" extra_vars result_file job_id artifacts
    extra_vars="${output_file}.extra-vars.json"
    AAP_JOB_RESULT_SEQUENCE=$((AAP_JOB_RESULT_SEQUENCE + 1))
    result_file="${output_file}.result-${AAP_JOB_RESULT_SEQUENCE}.json"
    write_synthetic_external_ip_attachment_attach_vars \
        "$attachment_id" "$attachment_uid" "$attachment_name" \
        "$external_ip_id" "$external_ip_uid" "$external_ip_name" "$external_address" \
        "$EXTERNAL_IP_ATTACHMENT_SUBNET_ID" "$EXTERNAL_IP_ATTACHMENT_SUBNET_UID" \
        "$EXTERNAL_IP_ATTACHMENT_SUBNET_NAME" "$EXTERNAL_IP_ATTACHMENT_SUBNET_CIDR" \
        "$FIRST_FULFILLMENT_ID" "$FIRST_K8S_UID" "$FIRST_CR_NAME" \
        "$OSAC_TENANT" "$NETWORKING_NAMESPACE" \
        "$EXTERNAL_IP_SYNTHETIC_TARGET_ID" "$EXTERNAL_IP_SYNTHETIC_TARGET_UID" \
        "$EXTERNAL_IP_SYNTHETIC_TARGET_NAME" "$OSAC_BMAAS_NAMESPACE" \
        "$EXTERNAL_IP_SYNTHETIC_TARGET_IP" "$extra_vars" \
        "$EXTERNAL_IP_UPLINK_INTERFACE" \
        || return 1
    run_agentless_net_aap_job attach-external-ip "$extra_vars" "$result_file" \
        || return 1
    job_id="$(jq -er '.job_id' "$result_file")" || return 1
    artifacts="$(external_ip_aap_job_artifacts "$job_id")" || return 1
    external_ip_attachment_assert_result \
        "$artifacts" external_ip_attachment.attach "$attachment_uid" 1 \
        || return 1
    LAST_EXTERNAL_IP_ATTACHMENT_JOB_ID="$job_id"
    LAST_EXTERNAL_IP_ATTACHMENT_PROVISION_JOB_ID="$job_id"
}

run_synthetic_external_ip_attachment_detach_job() {
    local entry="$1" output_file="$2" extra_vars result_file job_id artifacts
    local uid generation
    uid="$(jq -er '.uid' <<<"$entry")" || return 1
    generation="${3:-1}"
    extra_vars="${output_file}.extra-vars.json"
    AAP_JOB_RESULT_SEQUENCE=$((AAP_JOB_RESULT_SEQUENCE + 1))
    result_file="${output_file}.result-${AAP_JOB_RESULT_SEQUENCE}.json"
    write_synthetic_external_ip_attachment_detach_vars "$entry" "$extra_vars" \
        || return 1
    run_agentless_net_aap_job detach-external-ip "$extra_vars" "$result_file" \
        || return 1
    job_id="$(jq -er '.job_id' "$result_file")" || return 1
    artifacts="$(external_ip_aap_job_artifacts "$job_id")" || return 1
    external_ip_attachment_assert_result \
        "$artifacts" external_ip_attachment.detach "$uid" "$generation" \
        || return 1
    LAST_EXTERNAL_IP_ATTACHMENT_JOB_ID="$job_id"
}

synthetic_external_ip_attachment_remove_created_id() {
    local id="$1" index
    for index in "${!CREATED_SYNTHETIC_EXTERNAL_IP_ATTACHMENT_IDS[@]}"; do
        if [[ "${CREATED_SYNTHETIC_EXTERNAL_IP_ATTACHMENT_IDS[$index]}" == "$id" ]]; then
            unset 'CREATED_SYNTHETIC_EXTERNAL_IP_ATTACHMENT_IDS[index]'
            unset 'CREATED_SYNTHETIC_EXTERNAL_IP_ATTACHMENT_UIDS[index]'
        fi
    done
}

attach_synthetic_external_ip_attachment() {
    local attachment_id attachment_uid attachment_name output_file entry
    attachment_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    attachment_uid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    attachment_name="agentless-eip-attach-${attachment_id:0:8}"
    output_file="${TEMP_DIR}/${attachment_name}-attach"
    CREATED_SYNTHETIC_EXTERNAL_IP_ATTACHMENT_IDS+=("$attachment_id")
    CREATED_SYNTHETIC_EXTERNAL_IP_ATTACHMENT_UIDS+=("$attachment_uid")
    run_synthetic_external_ip_attachment_attach_job \
        "$attachment_id" "$attachment_uid" "$attachment_name" \
        "$1" "$2" "$3" "$4" "$output_file" \
        || die "AAP could not attach synthetic target to ExternalIP $1"
    entry="$(external_ip_attachment_state_entry "$attachment_uid" "$attachment_id")" \
        || die "AAP attach job did not persist synthetic ExternalIPAttachment state"
    jq -e --arg uid "$attachment_uid" --arg id "$attachment_id" \
        --arg tenant "$OSAC_TENANT" --arg eip_uid "$2" --arg address "$4" \
        --arg vn_uid "$FIRST_K8S_UID" --arg subnet_uid "$EXTERNAL_IP_ATTACHMENT_SUBNET_UID" \
        --arg target_id "$EXTERNAL_IP_SYNTHETIC_TARGET_ID" \
        --arg target_uid "$EXTERNAL_IP_SYNTHETIC_TARGET_UID" \
        --arg target_ip "$EXTERNAL_IP_SYNTHETIC_TARGET_IP" \
        --arg target_name "$EXTERNAL_IP_SYNTHETIC_TARGET_NAME" '
      .uid == $uid and .fulfillment_id == $id and .tenant_id == $tenant
      and .external_ip_uid == $eip_uid and .external_address == $address
      and .virtual_network_uid == $vn_uid and .subnet_uid == $subnet_uid
      and .phase == "ready"
      and .payload.context.external_ip.address == $address
      and .payload.context.target.kind == "BareMetalInstance"
      and .payload.context.target.fulfillment_id == $target_id
      and .payload.context.target.kubernetes_uid == $target_uid
      and .payload.context.target.name == $target_name
      and .payload.context.target.ip_address == $target_ip
    ' <<<"$entry" >/dev/null \
        || die "Synthetic ExternalIPAttachment provider state does not match the AAP input"
    LAST_EXTERNAL_IP_ATTACHMENT_ID="$attachment_id"
    LAST_EXTERNAL_IP_ATTACHMENT_UID="$attachment_uid"
    LAST_EXTERNAL_IP_ATTACHMENT_GENERATION=1
    LAST_EXTERNAL_IP_ATTACHMENT_PROVISION_JOB_ID="$LAST_EXTERNAL_IP_ATTACHMENT_JOB_ID"
    LAST_EXTERNAL_IP_ATTACHMENT_STATE="$entry"
}

detach_synthetic_external_ip_attachment() {
    local id="$1" uid="$2" address="$3" entry namespace output_file
    entry="$(external_ip_attachment_state_entry "$uid" "$id")" \
        || die "Synthetic ExternalIPAttachment state is missing before detach"
    jq -e --arg tenant "$OSAC_TENANT" --arg target "$EXTERNAL_IP_SYNTHETIC_TARGET_NAME" \
        '.tenant_id == $tenant and .payload.context.target.name == $target' \
        <<<"$entry" >/dev/null \
        || die "Refusing to detach provider state outside the synthetic test target"
    namespace="$(jq -er '.payload.provider.namespace_name' <<<"$entry")" \
        || die "Synthetic ExternalIPAttachment state has no provider namespace"
    output_file="${TEMP_DIR}/synthetic-eia-${id}-detach"
    run_synthetic_external_ip_attachment_detach_job "$entry" "$output_file" 1 \
        || return 1
    assert_external_ip_attachment_provider_absent "$uid" "$address" "$namespace" \
        || return 1
    synthetic_external_ip_attachment_remove_created_id "$id"
    info "Synthetic ExternalIPAttachment ${id} detached; AAP job ${LAST_EXTERNAL_IP_ATTACHMENT_JOB_ID} removed provider state and rules."
}

external_ip_attachment_remove_created_id() {
    local id="$1" index
    for index in "${!CREATED_EXTERNAL_IP_ATTACHMENT_IDS[@]}"; do
        if [[ "${CREATED_EXTERNAL_IP_ATTACHMENT_IDS[$index]}" == "$id" ]]; then
            unset 'CREATED_EXTERNAL_IP_ATTACHMENT_IDS[index]'
        fi
    done
}

delete_external_ip_attachment_and_verify() {
    local id="$1" uid="$2" address="$3" namespace="$4"
    local output_file="${TEMP_DIR}/delete-external-ip-attachment-${id}.out"
    local hold_finalizer="osac.openshift.io/e2e-hold-external-ip-attachment"
    local operator_finalizer="osac.openshift.io/externalipattachment-finalizer"
    local cr crs count deadline=$((SECONDS + 1800)) job job_id="" job_state generation artifacts validated=false
    cr="$(external_ip_attachment_cr_json "$id")"
    generation="$(jq -er '.metadata.generation' <<<"$cr")" \
        || die "ExternalIPAttachment ${id} has no generation"
    if [[ -z "$(jq -r '.metadata.deletionTimestamp // ""' <<<"$cr")" ]]; then
        if ! jq -e --arg finalizer "$hold_finalizer" \
            '(.metadata.finalizers // []) | index($finalizer) != null' <<<"$cr" >/dev/null; then
            oc patch externalipattachment "$(jq -r '.metadata.name' <<<"$cr")" \
                -n "$NETWORKING_NAMESPACE" --type=json \
                -p="[{\"op\":\"add\",\"path\":\"/metadata/finalizers/-\",\"value\":\"${hold_finalizer}\"}]" >/dev/null
        fi
        cr="$(external_ip_attachment_cr_json "$id")"
        info "Deleting ExternalIPAttachment ${id} through Fulfillment..."
        if ! "$CLI_BIN" --config "$CLI_CONFIG_DIR" --tenant "$OSAC_TENANT" \
            delete externalipattachment "$id" >"$output_file" 2>&1; then
            cat "$output_file" >&2
            die "Fulfillment could not delete ExternalIPAttachment ${id}"
        fi
    fi

    while ((SECONDS < deadline)); do
        crs="$(external_ip_attachment_crs_json "$id")" \
            || die "Kubernetes API failed while waiting for ExternalIPAttachment ${id} deletion"
        count="$(jq -er '.items | length' <<<"$crs")" \
            || die "Could not count ExternalIPAttachment CRs for UUID ${id} during deletion"
        [[ "$count" == 1 ]] || {
            printf 'Expected the held ExternalIPAttachment %s to remain until detach validation; found %s CRs\n' \
                "$id" "$count" >&2
            return 1
        }
        cr="$(jq -c '.items[0]' <<<"$crs")"
        job="$(jq -c '[.status.provisioningJobs[]? | select(.type == "deprovision")] | last // {}' <<<"$cr")"
        job_id="$(jq -r '.jobID // ""' <<<"$job")"
        job_state="$(jq -r '.state // ""' <<<"$job")"
        if [[ -n "$job_id" && ( "$job_state" == Failed || "$job_state" == Canceled ) ]]; then
            printf 'AAP detach job %s ended in %s for ExternalIPAttachment %s; retaining ExternalIP, target, Subnet, and route\n' \
                "$job_id" "$job_state" "$id" >&2
            return 1
        fi
        if [[ -n "$job_id" ]] \
            && jq -e --arg hold "$hold_finalizer" --arg operator "$operator_finalizer" '
                (.metadata.finalizers // []) as $values
                | ($values | index($hold) != null)
                  and ($values | index($operator) == null)' <<<"$cr" >/dev/null; then
            artifacts="$(external_ip_aap_job_artifacts "$job_id" 2>/dev/null || true)"
            if [[ -n "$artifacts" ]] \
                && external_ip_attachment_assert_result "$artifacts" \
                    external_ip_attachment.detach "$uid" "$generation"; then
                validated=true
                break
            fi
        fi
        sleep 2
    done
    [[ "$validated" == true ]] || {
        printf 'Timed out validating detach for ExternalIPAttachment %s; AAP job %s; next: bash ./vlan-e2e.sh --cleanup --external-ip\n' \
            "$id" "${job_id:-unknown}" >&2
        return 1
    }
    cr="$(external_ip_attachment_cr_json "$id")"
    oc patch externalipattachment "$(jq -r '.metadata.name' <<<"$cr")" \
        -n "$NETWORKING_NAMESPACE" --type=merge \
        -p="$(jq -c --arg hold "$hold_finalizer" \
            '{metadata:{finalizers:((.metadata.finalizers // []) | map(select(. != $hold)))}}' <<<"$cr")" \
        >/dev/null || return 1

    deadline=$((SECONDS + 600))
    while ((SECONDS < deadline)); do
        crs="$(external_ip_attachment_crs_json "$id")" \
            || { printf 'Could not verify ExternalIPAttachment %s disappearance\n' "$id" >&2; return 1; }
        count="$(jq -er '.items | length' <<<"$crs")" || return 1
        [[ "$count" == 0 ]] && break
        [[ "$count" == 1 ]] || return 1
        sleep 2
    done
    [[ "$count" == 0 ]] || {
        printf 'Timed out waiting for detached ExternalIPAttachment %s to disappear\n' "$id" >&2
        return 1
    }
    assert_external_ip_attachment_provider_absent "$uid" "$address" "$namespace" || return 1
    external_ip_attachment_remove_created_id "$id"
    info "ExternalIPAttachment ${id} is detached; AAP job ${job_id}; provider route, rules, conntrack, and state are absent"
}

prepare_external_ip_test_link() {
    local node_addresses client_addresses route
    node_addresses="$(docker exec "$CONTAINERLAB_NET_NODE" ip -o -4 addr show \
        dev "$EXTERNAL_IP_UPLINK_INTERFACE" | awk '{print $4}')" || return 1
    client_addresses="$(docker exec "$CONTAINERLAB_UPSTREAM_ROUTER" ip -o -4 addr show \
        dev "$EXTERNAL_IP_CLIENT_ROUTE_INTERFACE" | awk '{print $4}')" || return 1

    if [[ -z "$node_addresses" ]]; then
        docker exec "$CONTAINERLAB_NET_NODE" ip address add \
            "${EXTERNAL_IP_TEST_LINK_NODE_ADDRESS}/30" dev "$EXTERNAL_IP_UPLINK_INTERFACE" \
            || return 1
    elif [[ "$node_addresses" != "${EXTERNAL_IP_TEST_LINK_NODE_ADDRESS}/30" ]]; then
        printf 'Unexpected IPv4 address on %s/%s: %s\n' \
            "$CONTAINERLAB_NET_NODE" "$EXTERNAL_IP_UPLINK_INTERFACE" "$node_addresses" >&2
        return 1
    fi

    if [[ -z "$client_addresses" ]]; then
        docker exec "$CONTAINERLAB_UPSTREAM_ROUTER" ip address add \
            "${EXTERNAL_IP_TEST_LINK_CLIENT_ADDRESS}/30" dev "$EXTERNAL_IP_CLIENT_ROUTE_INTERFACE" \
            || return 1
    elif [[ "$client_addresses" != "${EXTERNAL_IP_TEST_LINK_CLIENT_ADDRESS}/30" ]]; then
        printf 'Unexpected IPv4 address on %s/%s: %s\n' \
            "$CONTAINERLAB_UPSTREAM_ROUTER" "$EXTERNAL_IP_CLIENT_ROUTE_INTERFACE" \
            "$client_addresses" >&2
        return 1
    fi

    route="$(docker exec "$CONTAINERLAB_UPSTREAM_ROUTER" ip route get \
        "$EXTERNAL_IP_TEST_LINK_NODE_ADDRESS")" || return 1
    [[ "$route" == *"dev ${EXTERNAL_IP_CLIENT_ROUTE_INTERFACE}"* \
        && "$route" == *"src ${EXTERNAL_IP_TEST_LINK_CLIENT_ADDRESS}"* ]] || {
        printf 'Unexpected route to the AgentlessNet test uplink: %s\n' "$route" >&2
        return 1
    }
    docker exec "$CONTAINERLAB_UPSTREAM_ROUTER" ping -c 3 -W 1 \
        "$EXTERNAL_IP_TEST_LINK_NODE_ADDRESS" >/dev/null || return 1
    info "ExternalIP test client link is ready on ${EXTERNAL_IP_UPLINK_INTERFACE}/${EXTERNAL_IP_CLIENT_ROUTE_INTERFACE}."
}

add_external_ip_client_route() {
    local address="$1" current gateway
    gateway="$EXTERNAL_IP_TEST_LINK_NODE_ADDRESS"
    current="$(docker exec "$CONTAINERLAB_UPSTREAM_ROUTER" ip route show | \
        awk -v destination="$address" '$1 == destination || $1 == destination "/32"')" \
        || return 1
    if [[ -n "$current" ]]; then
        [[ "$(wc -l <<<"$current")" == 1 && "$current" == *" via ${gateway} "* \
            && "$current" == *" dev ${EXTERNAL_IP_CLIENT_ROUTE_INTERFACE}"* ]] \
            || { printf 'Refusing to replace unexpected upstream route for ExternalIP %s: %s\n' "$address" "$current" >&2; return 1; }
    else
        docker exec "$CONTAINERLAB_UPSTREAM_ROUTER" ip route add "${address}/32" \
            via "$gateway" dev "$EXTERNAL_IP_CLIENT_ROUTE_INTERFACE" || return 1
    fi
    EXTERNAL_IP_CLIENT_ROUTE_GATEWAY="$gateway"
    EXTERNAL_IP_CLIENT_ROUTE_ADDRESSES+=("$address")
}

remove_external_ip_client_route() {
    local address="$1" current gateway="$EXTERNAL_IP_TEST_LINK_NODE_ADDRESS" index
    current="$(docker exec "$CONTAINERLAB_UPSTREAM_ROUTER" ip route show | \
        awk -v destination="$address" '$1 == destination || $1 == destination "/32"')" \
        || return 1
    if [[ -n "$current" ]]; then
        [[ "$(wc -l <<<"$current")" == 1 && "$current" == *" via ${gateway} "* \
            && "$current" == *" dev ${EXTERNAL_IP_CLIENT_ROUTE_INTERFACE}"* ]] \
            || { printf 'Refusing to remove unexpected upstream route for ExternalIP %s: %s\n' "$address" "$current" >&2; return 1; }
        docker exec "$CONTAINERLAB_UPSTREAM_ROUTER" ip route del "${address}/32" \
            via "$gateway" dev "$EXTERNAL_IP_CLIENT_ROUTE_INTERFACE" || return 1
        current="$(docker exec "$CONTAINERLAB_UPSTREAM_ROUTER" ip route show | \
            awk -v destination="$address" '$1 == destination || $1 == destination "/32"')" \
            || return 1
        [[ -z "$current" ]] || {
            printf 'Upstream route for ExternalIP %s remains after cleanup\n' "$address" >&2
            return 1
        }
    fi
    for index in "${!EXTERNAL_IP_CLIENT_ROUTE_ADDRESSES[@]}"; do
        if [[ "${EXTERNAL_IP_CLIENT_ROUTE_ADDRESSES[$index]}" == "$address" ]]; then
            unset 'EXTERNAL_IP_CLIENT_ROUTE_ADDRESSES[index]'
        fi
    done
}

probe_external_ip_response() {
    local address="$1"
    docker exec "$CONTAINERLAB_UPSTREAM_ROUTER" wget -q -T 5 -O - \
        "http://${address}:${EXTERNAL_IP_RESPONSE_PORT}/osac-eia-response"
}

wait_for_external_ip_response() {
    local address="$1" deadline=$((SECONDS + 300)) response
    while ((SECONDS < deadline)); do
        if response="$(probe_external_ip_response "$address" 2>/dev/null)" \
            && [[ "$response" == "$EXTERNAL_IP_RESPONSE_TOKEN" ]]; then
            info "External client received the synthetic target response through ExternalIP ${address}."
            return 0
        fi
        sleep 2
    done
    die "ExternalIP ${address} did not return the expected synthetic target response from the upstream-router"
}

prepare_nat_gateway_endpoint() {
    local script_file token_file response
    [[ "$SUITE_USES_NAT_GATEWAY" == true ]] || return 0
    prepare_external_ip_test_link \
        || die "Could not prepare the direct NATGateway test peer link"
    NAT_GATEWAY_ENDPOINT_CONTAINER="osac-natgw-source-endpoint"
    if docker inspect "$NAT_GATEWAY_ENDPOINT_CONTAINER" >/dev/null 2>&1; then
        die "NATGateway test endpoint ${NAT_GATEWAY_ENDPOINT_CONTAINER} already exists; recover the prior run first"
    fi
    NAT_GATEWAY_RESPONSE_TOKEN="osac-natgw-$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
    token_file="${TEMP_DIR}/nat-gateway-endpoint-token"
    script_file="${TEMP_DIR}/nat-gateway-endpoint-cgi"
    printf '%s' "$NAT_GATEWAY_RESPONSE_TOKEN" >"$token_file"
    chmod 0600 "$token_file"
    cat >"$script_file" <<'CGI'
#!/bin/sh
printf 'Content-Type: application/json\r\n\r\n'
token="$(cat /www/natgw-token)"
printf '{"token":"%s","source_ip":"%s"}\n' "$token" "${REMOTE_ADDR:-}"
CGI
    chmod 0700 "$script_file"
    docker image inspect "$CLIENT_IMAGE" >/dev/null 2>&1 || docker pull "$CLIENT_IMAGE"
    docker run -d --name "$NAT_GATEWAY_ENDPOINT_CONTAINER" \
        --label osac.openshift.io/e2e-owner=agentless-natgateway \
        --network "container:${CONTAINERLAB_UPSTREAM_ROUTER}" \
        "$CLIENT_IMAGE" sh -c 'while true; do sleep 3600; done' >/dev/null \
        || die "Could not start the NATGateway test endpoint container"
    NAT_GATEWAY_ENDPOINT_CREATED_BY_RUN=true
    docker exec "$NAT_GATEWAY_ENDPOINT_CONTAINER" mkdir -p /www/cgi-bin \
        || die "Could not prepare the NATGateway test endpoint document root"
    docker cp "$token_file" "${NAT_GATEWAY_ENDPOINT_CONTAINER}:/www/natgw-token" >/dev/null \
        || die "Could not install the private NATGateway test token"
    docker cp "$script_file" "${NAT_GATEWAY_ENDPOINT_CONTAINER}:/www/cgi-bin/observe" >/dev/null \
        || die "Could not install the NATGateway source-observation endpoint"
    docker exec "$NAT_GATEWAY_ENDPOINT_CONTAINER" chmod 0600 /www/natgw-token
    docker exec "$NAT_GATEWAY_ENDPOINT_CONTAINER" chmod 0700 /www/cgi-bin/observe
    docker exec -d "$NAT_GATEWAY_ENDPOINT_CONTAINER" \
        busybox httpd -f -p "$NAT_GATEWAY_RESPONSE_PORT" -h /www \
        || die "Could not start the NATGateway source-observation endpoint"
    for ((attempt = 1; attempt <= 30; attempt++)); do
        if response="$(docker exec "$NAT_GATEWAY_ENDPOINT_CONTAINER" \
            wget -q -T 5 -O - "http://127.0.0.1:${NAT_GATEWAY_RESPONSE_PORT}/cgi-bin/observe" 2>/dev/null)" \
            && jq -e --arg token "$NAT_GATEWAY_RESPONSE_TOKEN" \
                '.token == $token and (.source_ip | type == "string" and length > 0)' \
                <<<"$response" >/dev/null; then
            info "NATGateway source-observation endpoint is ready on port ${NAT_GATEWAY_RESPONSE_PORT}."
            return 0
        fi
        sleep 2
    done
    die "NATGateway source-observation endpoint did not become ready"
}

probe_nat_gateway_endpoint() {
    local client="$1" external_address="$2" container
    container="$(client_container "$client")"
    docker exec "$container" wget -q -T 5 -O - \
        "http://${EXTERNAL_IP_TEST_LINK_CLIENT_ADDRESS}:${NAT_GATEWAY_RESPONSE_PORT}/cgi-bin/observe"
}

wait_for_nat_gateway_source() {
    local client="$1" external_address="$2" deadline=$((SECONDS + 300)) response
    while ((SECONDS < deadline)); do
        if response="$(probe_nat_gateway_endpoint "$client" "$external_address" 2>/dev/null)" \
            && jq -e --arg token "$NAT_GATEWAY_RESPONSE_TOKEN" \
                --arg source "$external_address" \
                '.token == $token
                 and ((.source_ip | sub("^\\[::ffff:"; "") | sub("\\]$"; "")) == $source)' \
                <<<"$response" >/dev/null; then
            info "Client ${client} reached the endpoint through NATGateway ${external_address}; observed source ${external_address}."
            return 0
        fi
        sleep 2
    done
    die "Client ${client} did not reach the NATGateway endpoint with source ${external_address}"
}

cleanup_nat_gateway_endpoint() {
    local existing_owner network_mode upstream_router_id
    NAT_GATEWAY_ENDPOINT_CONTAINER="${NAT_GATEWAY_ENDPOINT_CONTAINER:-osac-natgw-source-endpoint}"
    if [[ "$NAT_GATEWAY_ENDPOINT_CREATED_BY_RUN" != true ]]; then
        [[ "${CLEANUP_MODE:-false}" == true ]] || return 0
        docker inspect "$NAT_GATEWAY_ENDPOINT_CONTAINER" >/dev/null 2>&1 || return 0
        existing_owner="$(docker inspect -f '{{ index .Config.Labels "osac.openshift.io/e2e-owner" }}' \
            "$NAT_GATEWAY_ENDPOINT_CONTAINER")" || return 1
        network_mode="$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$NAT_GATEWAY_ENDPOINT_CONTAINER")" \
            || return 1
        upstream_router_id="$(docker inspect -f '{{.Id}}' "$CONTAINERLAB_UPSTREAM_ROUTER")" \
            || return 1
        [[ "$existing_owner" == agentless-natgateway \
            && -n "$upstream_router_id" \
            && "$network_mode" == "container:${upstream_router_id}" ]] || {
            printf 'Refusing to remove an endpoint container outside the NATGateway e2e scope\n' >&2
            return 1
        }
    fi
    docker rm -f "$NAT_GATEWAY_ENDPOINT_CONTAINER" >/dev/null \
        || return 1
    NAT_GATEWAY_ENDPOINT_CREATED_BY_RUN=false
    NAT_GATEWAY_ENDPOINT_CONTAINER=""
    NAT_GATEWAY_RESPONSE_TOKEN=""
}

assert_external_ip_attachment_provider_absent() {
    local uid="$1" address="$2" namespace="$3" state routes nat forwarding conntrack
    state="$(state_snapshot)" || return 1
    if jq -e --arg uid "$uid" 'any(.external_ip_attachments[]; .uid == $uid)' <<<"$state" >/dev/null; then
        printf 'ExternalIPAttachment provider row remains for UID %s\n' "$uid" >&2
        return 1
    fi
    routes="$(netnode vtysh -c "show ip route ${address}/32" 2>&1 || true)"
    if grep -Fq "${address}/32" <<<"$routes"; then
        printf 'ExternalIP route %s remains on the network node after detach\n' "$address" >&2
        return 1
    fi
    forwarding="$(netnode iptables -w -t filter -S OSAC-EXTERNAL 2>&1 || true)"
    nat=""
    conntrack=""
    if [[ -n "$namespace" ]]; then
        nat="$(netnode ip netns exec "$namespace" iptables -w -t nat -S PREROUTING 2>&1)" \
            || return 1
        conntrack="$(netnode ip netns exec "$namespace" conntrack -L -f ipv4 2>&1)" \
            || return 1
    fi
    if grep -Fq "osac-eia:${uid}:" <<<"$nat$forwarding"; then
        printf 'ExternalIPAttachment %s still owns a forwarding or DNAT rule\n' "$uid" >&2
        return 1
    fi
    if [[ -n "$namespace" ]] && grep -E "(^| )(src|dst)=${address}([[:space:]]|$)" <<<"$conntrack"; then
        printf 'ExternalIP %s conntrack entries remain after detach\n' "$address" >&2
        return 1
    fi
}

external_ip_pool_get_json() {
    local request_file="${TEMP_DIR}/external-ip-pool-status.request.json"
    local response_file="${TEMP_DIR}/external-ip-pool-status.response.json"
    local error_file="${TEMP_DIR}/external-ip-pool-status.error.json"
    jq -n --arg id "$EXTERNAL_IP_POOL_ID" '{id:$id}' >"$request_file" \
        || die "Could not write ExternalIPPool Get request"
    if ! external_ip_pool_rpc Get "$request_file" "$response_file" "$error_file"; then
        cat "$error_file" >&2
        return 1
    fi
    cat "$response_file"
}

external_ip_pool_has_delta() {
    local delta="$1" allocated available response
    allocated=$((EXTERNAL_IP_POOL_INITIAL_ALLOCATED + delta))
    available=$((EXTERNAL_IP_POOL_INITIAL_AVAILABLE - delta))
    response="$(external_ip_pool_get_json)" || return 1
    jq -e --arg id "$EXTERNAL_IP_POOL_ID" --argjson allocated "$allocated" \
        --argjson available "$available" '
      .object.id == $id
      and ((.object.status.allocated // 0) | tonumber) == $allocated
      and ((.object.status.available // 0) | tonumber) == $available' \
        <<<"$response" >/dev/null
}

external_ip_pool_wait_for_delta() {
    local delta="$1" deadline=$((SECONDS + 600))
    while ((SECONDS < deadline)); do
        if external_ip_pool_has_delta "$delta"; then
            return 0
        fi
        sleep 2
    done
    die "ExternalIPPool counters did not reach allocated=$((EXTERNAL_IP_POOL_INITIAL_ALLOCATED + delta)) and available=$((EXTERNAL_IP_POOL_INITIAL_AVAILABLE - delta))"
}

external_ip_state_entry() {
    local uid="$1" fulfillment_id="$2"
    save_current_state
    jq -ceS --arg uid "$uid" --arg id "$fulfillment_id" '
      [.external_ips[] | select(.uid == $uid and .fulfillment_id == $id)]
      | if length == 1 then .[0] else error("expected one saved ExternalIP reservation") end' \
      "$CURRENT_STATE_FILE"
}

external_ip_assert_state() {
    local entry="$1" uid="$2" fulfillment_id="$3" tenant_id="$4" pool_uid="$5" address="$6"
    jq -e --arg uid "$uid" --arg id "$fulfillment_id" --arg tenant "$tenant_id" \
        --arg pool "$pool_uid" --arg address "$address" '
      .uid == $uid
      and .fulfillment_id == $id
      and .tenant_id == $tenant
      and .pool_uid == $pool
      and .address == $address' <<<"$entry" >/dev/null \
        || die "AgentlessNet ExternalIP reservation does not match the CR and pool"
}

external_ip_assert_state_absent() {
    local uid="$1" fulfillment_id="$2"
    save_current_state
    jq -e --arg uid "$uid" --arg id "$fulfillment_id" '
      all(.external_ips[]; .uid != $uid and .fulfillment_id != $id)' \
        "$CURRENT_STATE_FILE" >/dev/null \
        || die "Released ExternalIP ${fulfillment_id} remains in provider state"
}

external_ip_aap_job_artifacts() (
    local job_id="$1" route token
    route="$(oc get route osac-aap -n "$OSAC_NAMESPACE" -o jsonpath='{.spec.host}')" \
        || return 1
    token="$(oc exec deployment/osac-operator -n "$OSAC_NAMESPACE" -- \
        sh -c 'printf %s "$OSAC_AAP_TOKEN"' 2>/dev/null)" \
        || return 1
    [[ -n "$route" && -n "$token" ]] || return 1
    AAP_API_ROUTE="https://$route" AAP_API_TOKEN="$token" \
        AAP_API_CA_FILE="$AAP_API_CA_FILE" \
        python3 - "$job_id" <<'PY'
import json
import os
import ssl
import sys
import urllib.request

base = os.environ["AAP_API_ROUTE"].rstrip("/") + "/api/controller/v2"
token = os.environ["AAP_API_TOKEN"]
context = ssl.create_default_context(cafile=os.environ["AAP_API_CA_FILE"])
job_id = sys.argv[1]
request = urllib.request.Request(
    f"{base}/jobs/{job_id}/",
    headers={"Authorization": f"Bearer {token}"},
)
with urllib.request.urlopen(request, context=context, timeout=20) as response:
    job = json.load(response)
if job.get("status") != "successful":
    raise SystemExit(f"AAP job {job_id} is not successful")
artifacts = job.get("artifacts")
if not isinstance(artifacts, dict):
    raise SystemExit(f"AAP job {job_id} has no result artifacts")
sys.stdout.write(json.dumps(artifacts, sort_keys=True))
PY
)

nat_gateway_aap_job_details() (
    local job_id="$1" operation="$2" route token
    route="$(oc get route osac-aap -n "$OSAC_NAMESPACE" -o jsonpath='{.spec.host}')" \
        || return 1
    token="$(oc exec deployment/osac-operator -n "$OSAC_NAMESPACE" -- \
        sh -c 'printf %s "$OSAC_AAP_TOKEN"' 2>/dev/null)" \
        || return 1
    [[ -n "$route" && -n "$token" ]] || return 1
    AAP_API_ROUTE="https://${route}" AAP_API_TOKEN="$token" \
        AAP_API_CA_FILE="$AAP_API_CA_FILE" \
        python3 "$AAP_JOBS_HELPER" inspect-nat-gateway-job \
            --job-id "$job_id" \
            --operation "$operation" \
            --project-name "$AAP_PROJECT_NAME" \
            --project-revision "$RUNTIME_SOURCE_COMMIT" \
            --ee-name "$AAP_EXECUTION_ENVIRONMENT_NAME" \
            --ee-image "$AAP_IMAGE"
)

external_ip_assert_result() {
    local artifacts="$1" operation="$2" uid="$3" generation="$4" address="${5:-}"
    jq -e --arg operation "$operation" --arg uid "$uid" \
        --argjson generation "$generation" --arg address "$address" '
      .osac_result as $result
      | $result.schemaVersion == "v1"
        and $result.operation == $operation
        and $result.resourceUID == $uid
        and $result.observedGeneration == $generation
        and (if $operation == "external_ip.allocate"
             then ($result.data.address == $address and $address != "")
             else $result.data == {} end)' <<<"$artifacts" >/dev/null
}

nat_gateway_assert_result() {
    local result="$1" operation="$2" uid="$3" generation="$4"
    jq -e --arg operation "$operation" --arg uid "$uid" \
        --argjson generation "$generation" '
      .schemaVersion == "v1"
      and .operation == $operation
      and .resourceUID == $uid
      and .observedGeneration == $generation
      and .data == {}' <<<"$result" >/dev/null
}

nat_gateway_assert_ensure_job() {
    local job="$1" gateway_cr="$2" external_ip_cr="$3" virtual_network_cr="$4"
    local expected_context expected_uid expected_generation
    expected_uid="$(jq -er '.metadata.uid' <<<"$gateway_cr")" \
        || die "NATGateway CR has no Kubernetes UID"
    expected_generation="$(jq -er '.metadata.generation' <<<"$gateway_cr")" \
        || die "NATGateway CR has no generation"
    expected_context="$(jq -ncS --argjson ip "$external_ip_cr" --argjson vn "$virtual_network_cr" '
      {
        external_ip: {
          name: $ip.metadata.name,
          namespace: $ip.metadata.namespace,
          fulfillment_id: $ip.metadata.labels["osac.openshift.io/externalip-uuid"],
          kubernetes_uid: $ip.metadata.uid,
          tenant_id: $ip.metadata.annotations["osac.openshift.io/tenant"],
          address: $ip.status.address,
          state: $ip.status.state,
          phase: $ip.status.phase
        },
        virtual_network: {
          name: $vn.metadata.name,
          namespace: $vn.metadata.namespace,
          fulfillment_id: $vn.metadata.labels["osac.openshift.io/virtualnetwork-uuid"],
          kubernetes_uid: $vn.metadata.uid,
          tenant_id: $vn.metadata.annotations["osac.openshift.io/tenant"],
          ipv4_cidr: $vn.spec.ipv4Cidr,
          phase: $vn.status.phase
        }
      }')" || die "Could not construct the expected NATGateway job context"
    jq -e --arg uid "$expected_uid" --argjson generation "$expected_generation" \
        --argjson gateway "$gateway_cr" --argjson context "$expected_context" '
      .status == "successful"
      and .resource.metadata.uid == $uid
      and .resource.metadata.generation == $generation
      and .resource.metadata.labels["osac.openshift.io/natgateway-uuid"]
          == $gateway.metadata.labels["osac.openshift.io/natgateway-uuid"]
      and .resource.metadata.annotations["osac.openshift.io/tenant"]
          == $gateway.metadata.annotations["osac.openshift.io/tenant"]
      and .resource.metadata.annotations["osac.openshift.io/implementation-strategy"] == "agentless_net"
      and .resource.metadata.annotations["osac.openshift.io/natgateway-contract-version"] == "v1"
      and .resource.spec.virtualNetwork == $gateway.spec.virtualNetwork
      and .resource.spec.externalIP == $gateway.spec.externalIP
      and .nat_gateway_context == $context' <<<"$job" >/dev/null \
        || die "AAP ensure job input does not match the current NATGateway and dependencies"
    nat_gateway_assert_result "$(jq -c '.artifacts.osac_result' <<<"$job")" \
        nat_gateway.ensure "$expected_uid" "$expected_generation" \
        || die "AAP ensure artifact does not match NATGateway ${expected_uid}"
}

nat_gateway_assert_delete_job() {
    local job="$1" gateway_cr="$2" expected_uid expected_generation
    expected_uid="$(jq -er '.metadata.uid' <<<"$gateway_cr")" \
        || die "Deleting NATGateway has no Kubernetes UID"
    expected_generation="$(jq -er '.metadata.generation' <<<"$gateway_cr")" \
        || die "Deleting NATGateway has no generation"
    jq -e --arg uid "$expected_uid" --argjson generation "$expected_generation" \
        --argjson gateway "$gateway_cr" '
      .status == "successful"
      and .resource.metadata.uid == $uid
      and .resource.metadata.generation == $generation
      and .resource.metadata.labels["osac.openshift.io/natgateway-uuid"]
          == $gateway.metadata.labels["osac.openshift.io/natgateway-uuid"]
      and .resource.metadata.annotations["osac.openshift.io/tenant"]
          == $gateway.metadata.annotations["osac.openshift.io/tenant"]
      and .resource.metadata.annotations["osac.openshift.io/implementation-strategy"] == "agentless_net"
      and .resource.metadata.annotations["osac.openshift.io/natgateway-contract-version"] == "v1"
      and .resource.spec.virtualNetwork == $gateway.spec.virtualNetwork
      and .resource.spec.externalIP == $gateway.spec.externalIP' <<<"$job" >/dev/null \
        || die "AAP delete job input does not match deleting NATGateway ${expected_uid}"
    nat_gateway_assert_result "$(jq -c '.artifacts.osac_result' <<<"$job")" \
        nat_gateway.delete "$expected_uid" "$expected_generation" \
        || die "AAP delete artifact does not match NATGateway ${expected_uid}"
}

nat_gateway_assert_provider_state() {
    local id="$1" uid="$2" virtual_network_uid="$3" external_ip_uid="$4"
    local address="$5" entry
    entry="$(get_nat_gateway_state_entry "$uid" "$id")" \
        || die "NATGateway ${id} has no unique saved provider row"
    jq -e --arg id "$id" --arg uid "$uid" --arg tenant "$OSAC_TENANT" \
        --arg vn_uid "$virtual_network_uid" --arg eip_uid "$external_ip_uid" \
        --arg address "$address" '
      .uid == $uid
      and .fulfillment_id == $id
      and .tenant_id == $tenant
      and .external_ip_uid == $eip_uid
      and .virtual_network_uid == $vn_uid
      and .external_address == $address
      and .phase == "ready"
      and .payload.phase == "ready"
      and (.payload | keys | sort) == ["context", "external_address", "external_ip_uid", "fulfillment_id", "phase", "provider", "tenant_id", "uid", "virtual_network_uid"]
      and .payload.context.external_ip.kubernetes_uid == $eip_uid
      and .payload.context.external_ip.address == $address
      and .payload.context.virtual_network.kubernetes_uid == $vn_uid
      and .payload.provider.external_interface == "eth2"
      and (.payload.provider.next_hop | type == "string" and length > 0)' \
        <<<"$entry" >/dev/null \
        || die "NATGateway ${id} provider state does not match its current dependencies"
    printf '%s\n' "$entry"
}

nat_gateway_assert_provider_rules() {
    local id="$1" uid="$2" address="$3" entry="$4"
    local namespace namespace_interface next_hop next_hop_address vn_cidr transit_cidr
    local nat_rules forward_rules bypass_rules first_hook forwarding_rules snat_line isolation_line
    local infra_line snat_line_namespace owned count route
    local -a namespace_pair
    namespace="$(jq -er '.payload.provider.namespace_name' <<<"$entry")"
    namespace_interface="$(jq -er '.payload.provider.namespace_interface' <<<"$entry")"
    next_hop="$(jq -er '.payload.provider.next_hop' <<<"$entry")"
    next_hop_address="${next_hop%%/*}"
    vn_cidr="$(jq -er '.payload.context.virtual_network.ipv4_cidr' <<<"$entry")"
    transit_cidr="$(python3 - "$next_hop" <<'PY'
import ipaddress
import sys
print(ipaddress.ip_interface(sys.argv[1]).network)
PY
)" || die "Could not derive the saved NATGateway transit CIDR"
    nat_rules="$(netnode ip netns exec "$namespace" iptables -w -t nat -S POSTROUTING)" \
        || die "Could not inspect NATGateway ${id} namespace SNAT rules"
    mapfile -t namespace_pair < <(awk '$1 == "-A" && $2 == "POSTROUTING" { print; count++; if (count == 2) exit }' <<<"$nat_rules")
    [[ "${#namespace_pair[@]}" == 2 ]] \
        || die "NATGateway ${id} does not have two namespace POSTROUTING rules"
    infra_line="${namespace_pair[0]}"
    snat_line_namespace="${namespace_pair[1]}"
    [[ "$infra_line" == *"-s ${transit_cidr}"* \
        && "$infra_line" == *"-o ${namespace_interface}"* \
        && "$infra_line" == *"osac-ngw:${uid}:infra-bypass"* \
        && "$infra_line" == *"-j ACCEPT"* ]] \
        || die "NATGateway ${id} does not have the ordered transit exemption"
    [[ "$snat_line_namespace" == *"-s ${vn_cidr}"* \
        && "$snat_line_namespace" == *"-o ${namespace_interface}"* \
        && "$snat_line_namespace" == *"osac-ngw:${uid}:snat"* \
        && "$snat_line_namespace" == *"-j SNAT"* \
        && "$snat_line_namespace" == *"--to-source ${address}"* ]] \
        || die "NATGateway ${id} does not have the ordered VN-wide SNAT rule"
    owned="$(grep -F -- "osac-ngw:${uid}:infra-bypass" <<<"$nat_rules" || true)"
    count="$(wc -l <<<"$owned" | tr -d ' ')"
    [[ "$count" == 1 ]] || die "NATGateway ${id} has duplicate transit exemptions"
    owned="$(grep -F -- "osac-ngw:${uid}:snat" <<<"$nat_rules" || true)"
    count="$(wc -l <<<"$owned" | tr -d ' ')"
    [[ "$count" == 1 ]] || die "NATGateway ${id} has duplicate VN-wide SNAT rules"
    forward_rules="$(netnode iptables -w -t filter -S OSAC-SNAT-FORWARD 2>/dev/null || true)"
    owned="$(grep -F -- "osac-ngw:${uid}:forward-" <<<"$forward_rules" || true)"
    count="$(wc -l <<<"$owned" | tr -d ' ')"
    [[ "$count" == 2 ]] || die "NATGateway ${id} does not own exactly two host forwarding rules"
    bypass_rules="$(netnode iptables -w -t nat -S OSAC-SNAT-BYPASS 2>/dev/null || true)"
    owned="$(grep -F -- "osac-ngw:${uid}:bypass" <<<"$bypass_rules" || true)"
    count="$(wc -l <<<"$owned" | tr -d ' ')"
    [[ "$count" == 1 && "$owned" == *"-s ${address}/32"* && "$owned" == *"-j ACCEPT"* ]] \
        || die "NATGateway ${id} does not own exactly one address-scoped MASQUERADE bypass rule"
    first_hook="$(netnode iptables -w -t nat -S POSTROUTING \
        | awk '$1 == "-A" && $2 == "POSTROUTING" {print; exit}')"
    [[ "$first_hook" == "-A POSTROUTING -j OSAC-SNAT-BYPASS" ]] \
        || die "NATGateway MASQUERADE bypass hook is not first in host POSTROUTING"
    forwarding_rules="$(netnode iptables -w -t filter -S FORWARD)"
    snat_line="$(grep -nF -- '-A FORWARD -j OSAC-SNAT-FORWARD' <<<"$forwarding_rules" | head -n 1 | cut -d: -f1)"
    [[ -n "$snat_line" ]] || die "NATGateway host forwarding hook is missing"
    isolation_line="$(grep -nF -- '-A FORWARD -j OSAC-VN-ISOLATION' <<<"$forwarding_rules" \
        | head -n 1 | cut -d: -f1 || true)"
    if [[ -n "$isolation_line" && "$snat_line" -ge "$isolation_line" ]]; then
        die "NATGateway forwarding hook is below the VirtualNetwork isolation hook"
    fi
    route="$(netnode vtysh -c "show ip route ${address}/32" 2>&1)" \
        || die "Could not inspect the NATGateway local /32 route"
    [[ "$route" == *"${address}/32"* && "$route" == *"${next_hop_address}"* ]] \
        || die "NATGateway ${id} local /32 route does not use its saved next hop"
}

nat_gateway_assert_transit_exempt() {
    local namespace="$1" host_transit="$2" namespace_transit="$3"
    local port response_file server_pid observed
    port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
    response_file="${TEMP_DIR}/nat-gateway-transit-probe-${namespace}.txt"
    : >"$response_file"
    netnode python3 - "$host_transit" "$port" >"$response_file" 2>&1 <<'PY' &
import socket
import sys

host = sys.argv[1].split("/", 1)[0]
port = int(sys.argv[2])
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server:
    server.settimeout(30)
    server.bind((host, port))
    print("ready", flush=True)
    payload, address = server.recvfrom(128)
    server.sendto(address[0].encode(), address)
PY
    server_pid=$!
    for _ in {1..30}; do
        grep -Fxq ready "$response_file" && break
        sleep 1
    done
    if ! grep -Fxq ready "$response_file"; then
        cat "$response_file" >&2
        die "NATGateway transit exemption responder did not start"
    fi
    netnode ip netns exec "$namespace" python3 - "$namespace_transit" "$host_transit" "$port" <<'PY'
import socket
import sys

source = sys.argv[1].split("/", 1)[0]
destination = sys.argv[2].split("/", 1)[0]
port = int(sys.argv[3])
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
    client.settimeout(10)
    client.bind((source, 0))
    client.sendto(b"transit-probe", (destination, port))
    observed, _ = client.recvfrom(128)
    print(observed.decode(), flush=True)
PY
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
    observed="$(tail -n 1 "$response_file")"
    [[ "$observed" == "${namespace_transit%%/*}" ]] \
        || die "NATGateway transit traffic was translated from ${namespace_transit} to ${observed}"
    info "NATGateway transit exemption preserved source ${observed}."
}

nat_gateway_assert_provider_absent() {
    local uid="$1" address="$2" namespace="$3" state nat_rules forward_rules bypass_rules route conntrack
    state="$(state_snapshot)" || return 1
    if jq -e --arg uid "$uid" 'any(.nat_gateways[]; .uid == $uid)' <<<"$state" >/dev/null; then
        printf 'NATGateway provider row remains for UID %s\n' "$uid" >&2
        return 1
    fi
    nat_rules="$(netnode ip netns exec "$namespace" iptables -w -t nat -S POSTROUTING 2>&1 || true)"
    forward_rules="$(netnode iptables -w -t filter -S OSAC-SNAT-FORWARD 2>&1 || true)"
    bypass_rules="$(netnode iptables -w -t nat -S OSAC-SNAT-BYPASS 2>&1 || true)"
    if grep -Fq -- "osac-ngw:${uid}:" <<<"$nat_rules$forward_rules$bypass_rules"; then
        printf 'NATGateway rules remain for UID %s\n' "$uid" >&2
        return 1
    fi
    route="$(netnode vtysh -c "show ip route ${address}/32" 2>&1 || true)"
    if grep -Fq -- "${address}/32" <<<"$route"; then
        printf 'NATGateway local route %s remains after deletion\n' "$address" >&2
        return 1
    fi
    conntrack="$(netnode ip netns exec "$namespace" conntrack -L -f ipv4 \
        --reply-dst "$address" 2>&1 || true)"
    if grep -Fq -- "reply_dst=${address}" <<<"$conntrack"; then
        printf 'NATGateway conntrack entries remain for address %s\n' "$address" >&2
        return 1
    fi
}

external_ip_validate_address() {
    python3 - "$1" "$EXTERNAL_IP_POOL_CIDR" <<'PY'
import ipaddress
import sys

address = ipaddress.ip_address(sys.argv[1])
pool = ipaddress.ip_network(sys.argv[2], strict=True)
if not isinstance(address, ipaddress.IPv4Address) or str(address) != sys.argv[1] or address not in pool:
    raise SystemExit("ExternalIP result is not a canonical address in the test pool")
PY
}

create_external_ip() {
    local name="$1" output_file="$2" output id create_status=0
    if "$CLI_BIN" --config "$CLI_CONFIG_DIR" --tenant "$OSAC_TENANT" \
        create externalip --name "$name" --pool "$EXTERNAL_IP_POOL_ID" \
        >"$output_file" 2>&1; then
        create_status=0
    else
        create_status=$?
    fi
    cat "$output_file" >&2 || return 1
    output="$(cat "$output_file")" || return 1
    id="$(sed -nE 's/.*\(ID: ([0-9a-f-]+)\).*/\1/p' <<<"$output" | tail -n 1)"
    if [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        CREATED_EXTERNAL_IP_IDS+=("$id")
        printf '%s\n' "$id" >"${output_file}.id" || return 1
    fi
    [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || { printf 'Could not parse Fulfillment UUID from CLI create output for %s\n' "$name" >&2; return 1; }
    return "$create_status"
}

wait_for_external_ip_ready() {
    local id="$1" deadline=$((SECONDS + 600))
    local crs count cr phase state provision_job job_id job_state address uid generation artifacts entry
    info "Waiting for ExternalIP ${id} to become Ready..."
    while ((SECONDS < deadline)); do
        if ! crs="$(external_ip_crs_json "$id")"; then
            die "Kubernetes API failed while looking up ExternalIP UUID ${id}"
        fi
        count="$(jq -er '.items | length' <<<"$crs")" \
            || die "Could not count ExternalIP CRs for UUID ${id}"
        if [[ "$count" == 0 ]]; then
            sleep 2
            continue
        fi
        [[ "$count" == 1 ]] || die "Expected one ExternalIP CR for UUID ${id}; found ${count}"
        cr="$(external_ip_cr_json "$id")"
        phase="$(jq -r '.status.phase // ""' <<<"$cr")"
        state="$(jq -r '.status.state // ""' <<<"$cr")"
        provision_job="$(jq -c '[.status.provisioningJobs[]? | select(.type == "provision")] | last // {}' <<<"$cr")"
        job_id="$(jq -r '.jobID // ""' <<<"$provision_job")"
        job_state="$(jq -r '.state // ""' <<<"$provision_job")"
        if [[ "$phase" == Failed || "$state" == Failed || "$job_state" == Failed || "$job_state" == Canceled ]]; then
            printf '%s\n' "$cr" >&2
            die "ExternalIP ${id} failed allocation"
        fi
        if [[ "$phase" == Ready && "$state" == Allocated && "$job_state" == Succeeded && -n "$job_id" ]]; then
            uid="$(jq -er '.metadata.uid' <<<"$cr")"
            generation="$(jq -er '.metadata.generation' <<<"$cr")"
            address="$(jq -er '.status.address' <<<"$cr")"
            jq -e '(.metadata.annotations // {}) | has("osac.openshift.io/allocated-address") | not' \
                <<<"$cr" >/dev/null \
                || die "ExternalIP ${id} contains the obsolete allocated-address annotation"
            if ! artifacts="$(external_ip_aap_job_artifacts "$job_id")"; then
                die "Could not retrieve allocation artifacts for AAP job ${job_id}"
            fi
            external_ip_assert_result "$artifacts" external_ip.allocate "$uid" "$generation" "$address" \
                || die "AAP allocation artifact does not match ExternalIP ${id}"
            external_ip_validate_address "$address" \
                || die "ExternalIP ${id} has an invalid address"
            entry="$(external_ip_state_entry "$uid" "$id")"
            external_ip_assert_state "$entry" "$uid" "$id" "$OSAC_TENANT" \
                "$EXTERNAL_IP_POOL_K8S_UID" "$address"
            LAST_EXTERNAL_IP_UID="$uid"
            LAST_EXTERNAL_IP_ADDRESS="$address"
            LAST_EXTERNAL_IP_PROVISION_JOB_ID="$job_id"
            info "ExternalIP ${id} is Ready at ${address}; AAP job ${job_id}"
            return 0
        fi
        sleep 2
    done
    die "Timed out waiting for ExternalIP ${id} to become Ready"
}

create_nat_gateway() {
    local name="$1" virtual_network_id="$2" external_ip_id="$3" output_file="$4"
    local output id create_status=0
    if "$CLI_BIN" --config "$CLI_CONFIG_DIR" --tenant "$OSAC_TENANT" \
        create natgateway --name "$name" --virtual-network "$virtual_network_id" \
        --externalip "$external_ip_id" >"$output_file" 2>&1; then
        create_status=0
    else
        create_status=$?
    fi
    output="$(cat "$output_file")" || return 1
    printf '%s\n' "$output" >&2
    id="$(sed -nE 's/.*\(ID: ([0-9a-f-]+)\).*/\1/p' <<<"$output" | tail -n 1)"
    if [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        CREATED_NAT_GATEWAY_IDS+=("$id")
        printf '%s\n' "$id" >"${output_file}.id" || return 1
    fi
    [[ "$create_status" == 0 && "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || return 1
    return 0
}

nat_gateway_wait_for_ready() {
    local id="$1" virtual_network_id="$2" external_ip_id="$3"
    local deadline=$((SECONDS + AAP_JOB_TIMEOUT + 300))
    local crs count cr phase job job_id job_state uid generation ready details ip_cr vn_cr
    LAST_NAT_GATEWAY_JOB_ID=""
    LAST_NAT_GATEWAY_STATE=""
    while ((SECONDS < deadline)); do
        if ! crs="$(nat_gateway_crs_json "$id")"; then
            die "Kubernetes API failed while looking up NATGateway UUID ${id}"
        fi
        count="$(jq -er '.items | length' <<<"$crs")" \
            || die "Could not count NATGateway CRs for UUID ${id}"
        if [[ "$count" == 0 ]]; then
            sleep 2
            continue
        fi
        [[ "$count" == 1 ]] || die "Expected one NATGateway CR for UUID ${id}; found ${count}"
        cr="$(nat_gateway_cr_json "$id" "$virtual_network_id" "$external_ip_id")"
        phase="$(jq -r '.status.phase // ""' <<<"$cr")"
        job="$(jq -c '[.status.provisioningJobs[]? | select(.type == "provision")] | last // {}' <<<"$cr")"
        job_id="$(jq -r '.jobID // ""' <<<"$job")"
        job_state="$(jq -r '.state // ""' <<<"$job")"
        LAST_NAT_GATEWAY_STATE="$phase"
        if [[ "$phase" == Failed || "$job_state" == Failed || "$job_state" == Canceled ]]; then
            printf '%s\n' "$cr" >&2
            die "NATGateway ${id} failed provisioning"
        fi
        ready="$(jq -r 'any(.status.conditions[]?; .type == "Ready" and .status == "True")' <<<"$cr")"
        if [[ "$phase" == Ready && "$ready" == true && "$job_state" == Succeeded && -n "$job_id" ]]; then
            uid="$(jq -er '.metadata.uid' <<<"$cr")"
            generation="$(jq -er '.metadata.generation' <<<"$cr")"
            ip_cr="$(external_ip_cr_json "$external_ip_id")"
            vn_cr="$(virtual_network_cr_json "$virtual_network_id")"
            if ! details="$(nat_gateway_aap_job_details "$job_id" nat_gateway.ensure)"; then
                die "Could not inspect successful NATGateway ensure job ${job_id}"
            fi
            nat_gateway_assert_ensure_job "$details" "$cr" "$ip_cr" "$vn_cr"
            LAST_NAT_GATEWAY_JOB_ID="$job_id"
            return 0
        fi
        sleep 2
    done
    die "Timed out waiting for NATGateway ${id} to become Ready"
}

nat_gateway_retry_and_verify() {
    local id="$1" virtual_network_id="$2" external_ip_id="$3"
    local cr cr_name uid generation original_job before_state after_state ip_address
    cr="$(nat_gateway_cr_json "$id" "$virtual_network_id" "$external_ip_id")"
    uid="$(jq -er '.metadata.uid' <<<"$cr")"
    generation="$(jq -er '.metadata.generation' <<<"$cr")"
    original_job="$(jq -er '[.status.provisioningJobs[]? | select(.type == "provision") | .jobID] | last' <<<"$cr")"
    before_state="$(get_nat_gateway_state_entry "$uid" "$id")"
    ip_address="$(jq -er '.status.address' <<<"$(external_ip_cr_json "$external_ip_id")")"
    cr_name="$(jq -er '.metadata.name' <<<"$cr")"
    oc patch natgateway "$cr_name" -n "$NETWORKING_NAMESPACE" --subresource=status \
        --type=merge -p '{"status":{"phase":"Progressing","conditions":[],"provisioningJobs":[]}}' >/dev/null \
        || die "Could not reset NATGateway ${id} status to exercise controller retry"
    nat_gateway_wait_for_ready "$id" "$virtual_network_id" "$external_ip_id"
    [[ "$LAST_NAT_GATEWAY_JOB_ID" != "$original_job" ]] \
        || die "NATGateway retry did not create a new AAP job"
    cr="$(nat_gateway_cr_json "$id" "$virtual_network_id" "$external_ip_id")"
    [[ "$(jq -er '.metadata.uid' <<<"$cr")" == "$uid" \
        && "$(jq -er '.metadata.generation' <<<"$cr")" == "$generation" \
        && "$(jq -er '.status.address' <<<"$(external_ip_cr_json "$external_ip_id")")" == "$ip_address" ]] \
        || die "NATGateway retry changed resource identity, generation, or ExternalIP"
    after_state="$(get_nat_gateway_state_entry "$uid" "$id")"
    jq -e --argjson before "$before_state" '. == $before' <<<"$after_state" >/dev/null \
        || die "NATGateway retry changed its complete saved provider payload"
}

nat_gateway_add_hold_finalizer() {
    local gateway_cr="$1" name="$2" uid="$3" finalizers resource_version patch_file
    finalizers="$(jq -c '.metadata.finalizers // []' <<<"$gateway_cr")"
    if jq -e --arg hold 'osac.openshift.io/e2e-hold-natgateway' \
        'index($hold) != null' <<<"$finalizers" >/dev/null; then
        return 0
    fi
    jq -e --arg operator 'osac.openshift.io/natgateway-finalizer' \
        'index($operator) != null' <<<"$finalizers" >/dev/null \
        || die "NATGateway ${uid} lacks its operator finalizer before test deletion"
    resource_version="$(jq -er '.metadata.resourceVersion' <<<"$gateway_cr")"
    patch_file="${TEMP_DIR}/nat-gateway-hold-finalizer-${uid}.json"
    jq -n --arg rv "$resource_version" --arg uid "$uid" \
        --arg name "$name" --arg hold 'osac.openshift.io/e2e-hold-natgateway' \
        '[{op:"test",path:"/metadata/resourceVersion",value:$rv},
          {op:"test",path:"/metadata/uid",value:$uid},
          {op:"add",path:"/metadata/finalizers/-",value:$hold}]' >"$patch_file"
    oc patch natgateway "$name" -n "$NETWORKING_NAMESPACE" --type=json \
        --patch-file="$patch_file" >/dev/null \
        || die "Could not add the NATGateway test hold finalizer"
}

nat_gateway_remove_hold_finalizer() {
    local id="$1" virtual_network_id="$2" external_ip_id="$3" gateway_cr name uid rv finalizers
    local patch_file
    gateway_cr="$(nat_gateway_cr_json "$id" "$virtual_network_id" "$external_ip_id")" \
        || return 1
    name="$(jq -er '.metadata.name' <<<"$gateway_cr")" || return 1
    uid="$(jq -er '.metadata.uid' <<<"$gateway_cr")" || return 1
    rv="$(jq -er '.metadata.resourceVersion' <<<"$gateway_cr")" || return 1
    finalizers="$(jq -c '.metadata.finalizers // []' <<<"$gateway_cr")" || return 1
    jq -e --arg hold 'osac.openshift.io/e2e-hold-natgateway' \
        'index($hold) != null' <<<"$finalizers" >/dev/null || return 1
    patch_file="${TEMP_DIR}/nat-gateway-release-hold-${uid}.json"
    jq -n --arg rv "$rv" --arg uid "$uid" --arg hold 'osac.openshift.io/e2e-hold-natgateway' \
        --argjson finalizers "$finalizers" \
        '[{op:"test",path:"/metadata/resourceVersion",value:$rv},
          {op:"test",path:"/metadata/uid",value:$uid},
          {op:"replace",path:"/metadata/finalizers",value:($finalizers | map(select(. != $hold)))}]' \
        >"$patch_file" || return 1
    oc patch natgateway "$name" -n "$NETWORKING_NAMESPACE" --type=json \
        --patch-file="$patch_file" >/dev/null || return 1
}

delete_nat_gateway_and_verify() {
    local id="$1" virtual_network_id="$2" external_ip_id="$3"
    local gateway_cr name uid generation address vn_cr vn_uid entry namespace state provider_rows
    local output_file crs count job job_id job_state finalizers deadline details
    local operator_finalizer='osac.openshift.io/natgateway-finalizer'
    local hold_finalizer='osac.openshift.io/e2e-hold-natgateway'
    gateway_cr="$(nat_gateway_cr_json "$id" "$virtual_network_id" "$external_ip_id")" \
        || return 1
    name="$(jq -er '.metadata.name' <<<"$gateway_cr")" || return 1
    uid="$(jq -er '.metadata.uid' <<<"$gateway_cr")" || return 1
    generation="$(jq -er '.metadata.generation' <<<"$gateway_cr")" || return 1
    address="$(jq -er '.status.address' <<<"$(external_ip_cr_json "$external_ip_id")")" || return 1
    vn_cr="$(virtual_network_cr_json "$virtual_network_id")" || return 1
    vn_uid="$(jq -er '.metadata.uid' <<<"$vn_cr")" || return 1
    state="$(state_snapshot)" || return 1
    provider_rows="$(jq -ce --arg uid "$uid" \
        '[.nat_gateways[] | select(.uid == $uid)]' <<<"$state")" || return 1
    [[ "$(jq -er 'length' <<<"$provider_rows")" -le 1 ]] || return 1
    entry="$(jq -c '.[0] // empty' <<<"$provider_rows")"
    if [[ -n "$entry" ]]; then
        namespace="$(jq -er '.payload.provider.namespace_name' <<<"$entry")" || return 1
    else
        local vn_entry
        vn_entry="$(get_state_entry "$vn_uid")" || return 1
        namespace="$(jq -er '.namespace_name' <<<"$vn_entry")" || return 1
    fi
    if [[ -z "$(jq -r '.metadata.deletionTimestamp // ""' <<<"$gateway_cr")" ]]; then
        nat_gateway_add_hold_finalizer "$gateway_cr" "$name" "$uid" || return 1
        output_file="${TEMP_DIR}/delete-nat-gateway-${id}.out"
        if ! "$CLI_BIN" --config "$CLI_CONFIG_DIR" --tenant "$OSAC_TENANT" \
            delete natgateway "$id" >"$output_file" 2>&1; then
            cat "$output_file" >&2
            printf 'Fulfillment could not delete test NATGateway %s\n' "$id" >&2
            return 1
        fi
    fi
    deadline=$((SECONDS + AAP_JOB_TIMEOUT + 300))
    while ((SECONDS < deadline)); do
        if ! crs="$(nat_gateway_crs_json "$id")"; then
            printf 'Kubernetes API failed while waiting for NATGateway %s deletion\n' "$id" >&2
            return 1
        fi
        count="$(jq -er '.items | length' <<<"$crs")" || return 1
        [[ "$count" == 1 ]] || { printf 'NATGateway %s disappeared before its held result was verified\n' "$id" >&2; return 1; }
        gateway_cr="$(jq -c '.items[0]' <<<"$crs")"
        [[ "$(jq -r '.metadata.uid' <<<"$gateway_cr")" == "$uid" ]] \
            || { printf 'NATGateway %s UID changed during deletion\n' "$id" >&2; return 1; }
        job="$(jq -c '[.status.provisioningJobs[]? | select(.type == "deprovision")] | last // {}' <<<"$gateway_cr")"
        job_id="$(jq -r '.jobID // ""' <<<"$job")"
        job_state="$(jq -r '.state // ""' <<<"$job")"
        if [[ "$job_state" == Failed || "$job_state" == Canceled ]]; then
            printf 'NATGateway delete job %s ended in %s; retaining dependencies\n' "$job_id" "$job_state" >&2
            return 1
        fi
        finalizers="$(jq -c '.metadata.finalizers // []' <<<"$gateway_cr")"
        if [[ -n "$job_id" ]] \
            && ! jq -e --arg operator "$operator_finalizer" 'index($operator) != null' \
                <<<"$finalizers" >/dev/null; then
            if ! details="$(nat_gateway_aap_job_details "$job_id" nat_gateway.delete)"; then
                printf 'Could not inspect NATGateway delete job %s; retaining dependencies\n' "$job_id" >&2
                return 1
            fi
            nat_gateway_assert_delete_job "$details" "$gateway_cr" || return 1
            [[ "$finalizers" == *"$hold_finalizer"* ]] \
                || { printf 'NATGateway test hold finalizer was lost before result verification\n' >&2; return 1; }
            break
        fi
        sleep 2
    done
    [[ "$SECONDS" -lt "$deadline" ]] \
        || { printf 'Timed out waiting for NATGateway %s delete job/result\n' "$id" >&2; return 1; }
    nat_gateway_assert_provider_absent "$uid" "$address" "$namespace" || return 1
    local eip_cr eip_state
    eip_cr="$(external_ip_cr_json "$external_ip_id")" || return 1
    eip_state="$(jq -r '.status.state // ""' <<<"$eip_cr")"
    [[ "$eip_state" == Allocated && "$(jq -r '.status.address' <<<"$eip_cr")" == "$address" ]] \
        || { printf 'ExternalIP %s was released before NATGateway cleanup completed\n' "$external_ip_id" >&2; return 1; }
    nat_gateway_remove_hold_finalizer "$id" "$virtual_network_id" "$external_ip_id" || return 1
    deadline=$((SECONDS + 600))
    while ((SECONDS < deadline)); do
        crs="$(nat_gateway_crs_json "$id")" || return 1
        count="$(jq -er '.items | length' <<<"$crs")" || return 1
        [[ "$count" == 0 ]] && break
        sleep 2
    done
    [[ "$count" == 0 ]] || { printf 'Timed out waiting for NATGateway %s removal\n' "$id" >&2; return 1; }
    LAST_NAT_GATEWAY_CLEANUP_JOB_ID="$job_id"
    local index
    for index in "${!CREATED_NAT_GATEWAY_IDS[@]}"; do
        if [[ "${CREATED_NAT_GATEWAY_IDS[$index]}" == "$id" ]]; then
            unset 'CREATED_NAT_GATEWAY_IDS[index]'
            unset 'CREATED_NAT_GATEWAY_UIDS[index]'
        fi
    done
    info "NATGateway ${id} provider cleanup accepted by AAP job ${job_id}."
}

cleanup_created_nat_gateways() {
    local id crs count cr virtual_network_id external_ip_id
    [[ "${#CREATED_NAT_GATEWAY_IDS[@]}" -gt 0 ]] || return 0
    [[ -n "$CLI_BIN" && -x "$CLI_BIN" && -n "$CLI_CONFIG_DIR" && -d "$CLI_CONFIG_DIR" ]] \
        || return 1
    for id in "${CREATED_NAT_GATEWAY_IDS[@]}"; do
        [[ -n "$id" ]] || continue
        if ! crs="$(nat_gateway_crs_json "$id")"; then
            printf 'Could not inspect NATGateway %s during cleanup\n' "$id" >&2
            return 1
        fi
        count="$(jq -er '.items | length' <<<"$crs")" || return 1
        if [[ "$count" == 0 ]]; then
            local state
            state="$(state_snapshot)" || return 1
            if jq -e --arg id "$id" 'any(.nat_gateways[]; .fulfillment_id == $id)' \
                <<<"$state" >/dev/null; then
                printf 'NATGateway %s is gone from Kubernetes but its provider row remains\n' "$id" >&2
                return 1
            fi
            printf 'NATGateway %s disappeared before its provider cleanup could be verified\n' "$id" >&2
            return 1
        fi
        [[ "$count" == 1 ]] || { printf 'Found multiple NATGateway CRs for %s\n' "$id" >&2; return 1; }
        cr="$(jq -c '.items[0]' <<<"$crs")"
        virtual_network_id="$(jq -er '.spec.virtualNetwork' <<<"$cr")" || return 1
        external_ip_id="$(jq -er '.spec.externalIP' <<<"$cr")" || return 1
        cr="$(nat_gateway_cr_json "$id" "$virtual_network_id" "$external_ip_id")" || return 1
        delete_nat_gateway_and_verify "$id" "$virtual_network_id" "$external_ip_id" || return 1
    done
}

external_ip_remove_created_id() {
    local id="$1" index
    for index in "${!CREATED_EXTERNAL_IP_IDS[@]}"; do
        if [[ "${CREATED_EXTERNAL_IP_IDS[$index]}" == "$id" ]]; then
            unset 'CREATED_EXTERNAL_IP_IDS[index]'
        fi
    done
}

delete_external_ip_and_verify() {
    local id="$1" uid="$2" capacity_delta="$3"
    local output_file="${TEMP_DIR}/delete-external-ip-${id}.out"
    local hold_finalizer="osac.openshift.io/e2e-hold-external-ip"
    local operator_finalizer="osac.openshift.io/externalip-finalizer"
    local cr crs count deadline=$((SECONDS + 600)) release_job release_job_id="" job_state artifacts
    local release_generation
    local release_validated=false
    cr="$(external_ip_cr_json "$id")"
    if [[ -z "$(jq -r '.metadata.deletionTimestamp // ""' <<<"$cr")" ]]; then
        jq -e --arg finalizer "$hold_finalizer" \
            '(.metadata.finalizers // []) | index($finalizer) == null' <<<"$cr" >/dev/null \
            || die "ExternalIP ${id} already has the E2E hold finalizer"
        oc patch externalip "$(jq -r '.metadata.name' <<<"$cr")" -n "$NETWORKING_NAMESPACE" \
            --type=json -p="[{\"op\":\"add\",\"path\":\"/metadata/finalizers/-\",\"value\":\"${hold_finalizer}\"}]" >/dev/null
        cr="$(external_ip_cr_json "$id")"
        info "Deleting ExternalIP ${id} through Fulfillment..."
        if ! "$CLI_BIN" --config "$CLI_CONFIG_DIR" --tenant "$OSAC_TENANT" \
            delete externalip "$id" >"$output_file" 2>&1; then
            cat "$output_file" >&2
            die "Fulfillment could not delete ExternalIP ${id}"
        fi
    fi

    while ((SECONDS < deadline)); do
        if ! crs="$(external_ip_crs_json "$id")"; then
            die "Kubernetes API failed while waiting for ExternalIP ${id} deletion"
        fi
        count="$(jq -er '.items | length' <<<"$crs")" \
            || die "Could not count ExternalIP CRs for UUID ${id} during deletion"
        if [[ "$count" == 0 ]]; then
            break
        fi
        [[ "$count" == 1 ]] || die "Expected one ExternalIP CR for UUID ${id} during deletion"
        cr="$(jq -c '.items[0]' <<<"$crs")"
        release_generation="$(jq -er '.metadata.generation' <<<"$cr")" \
            || die "Could not read the deleting ExternalIP ${id} generation"
        release_job="$(jq -c '[.status.provisioningJobs[]? | select(.type == "deprovision")] | last // {}' <<<"$cr")"
        release_job_id="$(jq -r '.jobID // ""' <<<"$release_job")"
        job_state="$(jq -r '.state // ""' <<<"$release_job")"
        if [[ -n "$release_job_id" && ( "$job_state" == Failed || "$job_state" == Canceled ) ]]; then
            die "AAP release job ${release_job_id} ended in ${job_state} for ExternalIP ${id}"
        fi
        if [[ -n "$release_job_id" ]] \
            && jq -e --arg hold "$hold_finalizer" --arg operator "$operator_finalizer" '
                (.metadata.finalizers // []) as $finalizers
                | ($finalizers | index($hold) != null)
                  and ($finalizers | index($operator) == null)' <<<"$cr" >/dev/null; then
            if artifacts="$(external_ip_aap_job_artifacts "$release_job_id" 2>/dev/null)"; then
                external_ip_assert_result "$artifacts" external_ip.release "$uid" "$release_generation" \
                    || die "AAP release artifact does not match ExternalIP ${id}"
                release_validated=true
                break
            fi
        fi
        sleep 2
    done
    [[ "$count" == 1 && -n "$release_job_id" && "$release_validated" == true ]] \
        || die "Timed out waiting for the operator to validate release of ExternalIP ${id}"
    jq -e --arg hold "$hold_finalizer" --arg operator "$operator_finalizer" '
        (.metadata.finalizers // []) as $finalizers
        | ($finalizers | index($hold) != null)
          and ($finalizers | index($operator) == null)' <<<"$cr" >/dev/null \
        || die "ExternalIP ${id} was not retained by the test hold finalizer after operator cleanup"
    external_ip_pool_wait_for_delta "$((capacity_delta + 1))"
    oc patch externalip "$(jq -r '.metadata.name' <<<"$cr")" -n "$NETWORKING_NAMESPACE" \
        --type=merge -p="$(jq -c --arg hold "$hold_finalizer" \
            '{metadata:{finalizers:((.metadata.finalizers // []) | map(select(. != $hold)))}}' <<<"$cr")" >/dev/null
    deadline=$((SECONDS + 600))
    while ((SECONDS < deadline)); do
        crs="$(external_ip_crs_json "$id")" \
            || die "Kubernetes API failed while removing the E2E hold finalizer from ExternalIP ${id}"
        count="$(jq -er '.items | length' <<<"$crs")" \
            || die "Could not count ExternalIP CRs after releasing ${id}"
        [[ "$count" == 0 ]] && break
        sleep 2
    done
    [[ "$count" == 0 ]] || die "Timed out waiting for ExternalIP ${id} to be removed after cleanup"
    external_ip_assert_state_absent "$uid" "$id"
    external_ip_pool_wait_for_delta "$capacity_delta"
    external_ip_remove_created_id "$id"
    info "ExternalIP ${id} is released and Fulfillment capacity is updated; AAP job ${release_job_id}"
}

run_external_ip_lifecycle() {
    local pool_status initial_total output_file state_after_retry original_job cr name
    pool_status="$(external_ip_pool_get_json)" \
        || die "Could not read test ExternalIPPool capacity"
    initial_total="$(jq -er '.object.status.total | tonumber' <<<"$pool_status")" \
        || die "ExternalIPPool has no total capacity"
    EXTERNAL_IP_POOL_INITIAL_AVAILABLE="$(jq -er '.object.status.available | tonumber' <<<"$pool_status")" \
        || die "ExternalIPPool has no available capacity"
    EXTERNAL_IP_POOL_INITIAL_ALLOCATED="$(jq -er '(.object.status.allocated // 0) | tonumber' <<<"$pool_status")" \
        || die "ExternalIPPool has invalid allocated capacity"
    [[ "$initial_total" -gt 0 && "$EXTERNAL_IP_POOL_INITIAL_ALLOCATED" == 0 ]] \
        || die "ExternalIPPool must start Ready with capacity available and no allocated ExternalIPs"

    output_file="${TEMP_DIR}/create-external-ip-one.out"
    create_external_ip "$EXTERNAL_IP_ONE_NAME" "$output_file" \
        || die "Could not create test ExternalIP ${EXTERNAL_IP_ONE_NAME}"
    EXTERNAL_IP_ONE_ID="$(<"${output_file}.id")"
    external_ip_pool_wait_for_delta 1
    wait_for_external_ip_ready "$EXTERNAL_IP_ONE_ID"
    EXTERNAL_IP_ONE_UID="$LAST_EXTERNAL_IP_UID"
    EXTERNAL_IP_ONE_ADDRESS="$LAST_EXTERNAL_IP_ADDRESS"
    EXTERNAL_IP_ONE_PROVISION_JOB_ID="$LAST_EXTERNAL_IP_PROVISION_JOB_ID"
    EXTERNAL_IP_ONE_STATE="$(external_ip_state_entry "$EXTERNAL_IP_ONE_UID" "$EXTERNAL_IP_ONE_ID")"

    output_file="${TEMP_DIR}/create-external-ip-two.out"
    create_external_ip "$EXTERNAL_IP_TWO_NAME" "$output_file" \
        || die "Could not create test ExternalIP ${EXTERNAL_IP_TWO_NAME}"
    EXTERNAL_IP_TWO_ID="$(<"${output_file}.id")"
    external_ip_pool_wait_for_delta 2
    wait_for_external_ip_ready "$EXTERNAL_IP_TWO_ID"
    EXTERNAL_IP_TWO_UID="$LAST_EXTERNAL_IP_UID"
    EXTERNAL_IP_TWO_ADDRESS="$LAST_EXTERNAL_IP_ADDRESS"
    EXTERNAL_IP_TWO_PROVISION_JOB_ID="$LAST_EXTERNAL_IP_PROVISION_JOB_ID"
    EXTERNAL_IP_TWO_STATE="$(external_ip_state_entry "$EXTERNAL_IP_TWO_UID" "$EXTERNAL_IP_TWO_ID")"
    [[ "$EXTERNAL_IP_ONE_ADDRESS" != "$EXTERNAL_IP_TWO_ADDRESS" ]] \
        || die "Two ExternalIPs received the same address from one pool"
    external_ip_pool_wait_for_delta 2

    info "Retrying ExternalIP ${EXTERNAL_IP_ONE_ID} with the same Kubernetes UID..."
    original_job="$EXTERNAL_IP_ONE_PROVISION_JOB_ID"
    cr="$(external_ip_cr_json "$EXTERNAL_IP_ONE_ID")"
    name="$(jq -er '.metadata.name' <<<"$cr")"
    oc patch externalip "$name" -n "$NETWORKING_NAMESPACE" --subresource=status \
        --type=merge -p '{"status":{"phase":"Progressing","state":"Pending","conditions":[],"provisioningJobs":[]}}' >/dev/null
    wait_for_external_ip_ready "$EXTERNAL_IP_ONE_ID"
    [[ "$LAST_EXTERNAL_IP_PROVISION_JOB_ID" != "$original_job" ]] \
        || die "ExternalIP retry did not create a new AAP job"
    [[ "$LAST_EXTERNAL_IP_UID" == "$EXTERNAL_IP_ONE_UID" \
        && "$LAST_EXTERNAL_IP_ADDRESS" == "$EXTERNAL_IP_ONE_ADDRESS" ]] \
        || die "ExternalIP retry changed its UID or reserved address"
    state_after_retry="$(external_ip_state_entry "$EXTERNAL_IP_ONE_UID" "$EXTERNAL_IP_ONE_ID")"
    [[ "$state_after_retry" == "$EXTERNAL_IP_ONE_STATE" ]] \
        || die "ExternalIP retry changed its UID-owned provider reservation"
    external_ip_pool_wait_for_delta 2

    if [[ "${SUITE_USES_EXTERNAL_IP_ATTACHMENT:-false}" == true ]]; then
        run_external_ip_attachment_lifecycle
    fi

    delete_external_ip_and_verify "$EXTERNAL_IP_ONE_ID" "$EXTERNAL_IP_ONE_UID" 1
    cr="$(external_ip_cr_json "$EXTERNAL_IP_TWO_ID")"
    [[ "$(jq -r '.status.address' <<<"$cr")" == "$EXTERNAL_IP_TWO_ADDRESS" ]] \
        || die "Deleting ExternalIP ${EXTERNAL_IP_ONE_ID} changed its peer address"
    state_after_retry="$(external_ip_state_entry "$EXTERNAL_IP_TWO_UID" "$EXTERNAL_IP_TWO_ID")"
    [[ "$state_after_retry" == "$EXTERNAL_IP_TWO_STATE" ]] \
        || die "Deleting ExternalIP ${EXTERNAL_IP_ONE_ID} changed its peer reservation"

    delete_external_ip_and_verify "$EXTERNAL_IP_TWO_ID" "$EXTERNAL_IP_TWO_UID" 0
    external_ip_pool_wait_for_delta 0
    save_current_state
    assert_baseline_state_unchanged
}

run_external_ip_attachment_lifecycle() {
    local original_job state_after_retry peer_state peer_eip_state entry client="$EXTERNAL_IP_SYNTHETIC_CLIENT"
    [[ -n "$EXTERNAL_IP_SYNTHETIC_TARGET_ID" && -n "$EXTERNAL_IP_SYNTHETIC_TARGET_UID" \
        && -n "$EXTERNAL_IP_SYNTHETIC_TARGET_IP" && -n "$EXTERNAL_IP_ATTACHMENT_SUBNET_UID" ]] \
        || die "ExternalIPAttachment lifecycle requires a synthetic DHCP target and Ready Subnet"

    attach_synthetic_external_ip_attachment \
        "$EXTERNAL_IP_ONE_ID" "$EXTERNAL_IP_ONE_UID" "$EXTERNAL_IP_ONE_NAME" "$EXTERNAL_IP_ONE_ADDRESS"
    EXTERNAL_IP_ATTACHMENT_ONE_ID="$LAST_EXTERNAL_IP_ATTACHMENT_ID"
    EXTERNAL_IP_ATTACHMENT_ONE_UID="$LAST_EXTERNAL_IP_ATTACHMENT_UID"
    EXTERNAL_IP_ATTACHMENT_ONE_JOB_ID="$LAST_EXTERNAL_IP_ATTACHMENT_PROVISION_JOB_ID"
    EXTERNAL_IP_ATTACHMENT_ONE_STATE="$LAST_EXTERNAL_IP_ATTACHMENT_STATE"

    attach_synthetic_external_ip_attachment \
        "$EXTERNAL_IP_TWO_ID" "$EXTERNAL_IP_TWO_UID" "$EXTERNAL_IP_TWO_NAME" "$EXTERNAL_IP_TWO_ADDRESS"
    EXTERNAL_IP_ATTACHMENT_TWO_ID="$LAST_EXTERNAL_IP_ATTACHMENT_ID"
    EXTERNAL_IP_ATTACHMENT_TWO_UID="$LAST_EXTERNAL_IP_ATTACHMENT_UID"
    EXTERNAL_IP_ATTACHMENT_TWO_JOB_ID="$LAST_EXTERNAL_IP_ATTACHMENT_PROVISION_JOB_ID"
    EXTERNAL_IP_ATTACHMENT_TWO_STATE="$LAST_EXTERNAL_IP_ATTACHMENT_STATE"

    add_external_ip_client_route "$EXTERNAL_IP_ONE_ADDRESS" \
        || die "Could not add the test-only upstream route for ExternalIP ${EXTERNAL_IP_ONE_ADDRESS}"
    add_external_ip_client_route "$EXTERNAL_IP_TWO_ADDRESS" \
        || die "Could not add the test-only upstream route for peer ExternalIP ${EXTERNAL_IP_TWO_ADDRESS}"
    wait_for_external_ip_response "$EXTERNAL_IP_ONE_ADDRESS"
    wait_for_external_ip_response "$EXTERNAL_IP_TWO_ADDRESS"

    info "Retrying the first synthetic ExternalIPAttachment with the same provider identity..."
    original_job="$EXTERNAL_IP_ATTACHMENT_ONE_JOB_ID"
    run_synthetic_external_ip_attachment_attach_job \
        "$EXTERNAL_IP_ATTACHMENT_ONE_ID" "$EXTERNAL_IP_ATTACHMENT_ONE_UID" \
        "$EXTERNAL_IP_ATTACHMENT_ONE_NAME" "$EXTERNAL_IP_ONE_ID" \
        "$EXTERNAL_IP_ONE_UID" "$EXTERNAL_IP_ONE_NAME" "$EXTERNAL_IP_ONE_ADDRESS" \
        "${TEMP_DIR}/synthetic-eia-${EXTERNAL_IP_ATTACHMENT_ONE_ID}-retry" \
        || die "AAP could not retry synthetic ExternalIPAttachment ${EXTERNAL_IP_ATTACHMENT_ONE_ID}"
    [[ "$LAST_EXTERNAL_IP_ATTACHMENT_PROVISION_JOB_ID" != "$original_job" ]] \
        || die "ExternalIPAttachment retry did not create a new AAP job"
    entry="$(external_ip_attachment_state_entry \
        "$EXTERNAL_IP_ATTACHMENT_ONE_UID" "$EXTERNAL_IP_ATTACHMENT_ONE_ID")"
    state_after_retry="$entry"
    [[ "$state_after_retry" == "$EXTERNAL_IP_ATTACHMENT_ONE_STATE" ]] \
        || die "Synthetic ExternalIPAttachment retry changed its UID-owned provider state"
    wait_for_external_ip_response "$EXTERNAL_IP_ONE_ADDRESS"

    peer_state="$(external_ip_attachment_state_entry \
        "$EXTERNAL_IP_ATTACHMENT_TWO_UID" "$EXTERNAL_IP_ATTACHMENT_TWO_ID")"
    peer_eip_state="$(external_ip_state_entry "$EXTERNAL_IP_TWO_UID" "$EXTERNAL_IP_TWO_ID")"
    detach_synthetic_external_ip_attachment "$EXTERNAL_IP_ATTACHMENT_ONE_ID" \
        "$EXTERNAL_IP_ATTACHMENT_ONE_UID" "$EXTERNAL_IP_ONE_ADDRESS" \
        || die "Synthetic detach failed for ${EXTERNAL_IP_ATTACHMENT_ONE_ID}; retaining EIPs and network resources"
    first_cr="$(external_ip_cr_json "$EXTERNAL_IP_ONE_ID")"
    [[ "$(jq -r '.status.state' <<<"$first_cr")" == Allocated ]] \
        || die "ExternalIP ${EXTERNAL_IP_ONE_ID} was released before its attachment cleanup completed"
    if probe_external_ip_response "$EXTERNAL_IP_ONE_ADDRESS" >/dev/null 2>&1; then
        die "Detached ExternalIP ${EXTERNAL_IP_ONE_ADDRESS} still reaches the synthetic DHCP client"
    fi
    [[ "$(external_ip_attachment_state_entry \
        "$EXTERNAL_IP_ATTACHMENT_TWO_UID" "$EXTERNAL_IP_ATTACHMENT_TWO_ID")" == "$peer_state" ]] \
        || die "Detaching ExternalIP ${EXTERNAL_IP_ONE_ADDRESS} changed its peer attachment state"
    [[ "$(external_ip_state_entry "$EXTERNAL_IP_TWO_UID" "$EXTERNAL_IP_TWO_ID")" == "$peer_eip_state" ]] \
        || die "Detaching ExternalIP ${EXTERNAL_IP_ONE_ADDRESS} changed its peer ExternalIP state"
    wait_for_external_ip_response "$EXTERNAL_IP_TWO_ADDRESS"

    detach_synthetic_external_ip_attachment "$EXTERNAL_IP_ATTACHMENT_TWO_ID" \
        "$EXTERNAL_IP_ATTACHMENT_TWO_UID" "$EXTERNAL_IP_TWO_ADDRESS" \
        || die "Synthetic peer detach failed for ${EXTERNAL_IP_ATTACHMENT_TWO_ID}; preserving dependent resources"
    if probe_external_ip_response "$EXTERNAL_IP_TWO_ADDRESS" >/dev/null 2>&1; then
        die "Detached peer ExternalIP ${EXTERNAL_IP_TWO_ADDRESS} still reaches the synthetic DHCP client"
    fi
    remove_external_ip_client_route "$EXTERNAL_IP_ONE_ADDRESS" \
        || die "Could not remove the test route for ExternalIP ${EXTERNAL_IP_ONE_ADDRESS}"
    remove_external_ip_client_route "$EXTERNAL_IP_TWO_ADDRESS" \
        || die "Could not remove the test route for ExternalIP ${EXTERNAL_IP_TWO_ADDRESS}"
    detach_dhcp_client "$client"
    info "Synthetic-target ExternalIPAttachment ingress, retry, peer preservation, and detach checks passed."
}

cleanup_created_external_ips() {
    [[ "${#CREATED_EXTERNAL_IP_IDS[@]}" -gt 0 ]] || return 0
    [[ -n "$CLI_BIN" && -x "$CLI_BIN" && -n "$CLI_CONFIG_DIR" && -d "$CLI_CONFIG_DIR" ]] \
        || return 1

    local id crs count cr uid name output_file release_job release_job_id job_state
    local release_generation artifacts hold_finalizer operator_finalizer
    local state_file remaining deadline
    hold_finalizer="osac.openshift.io/e2e-hold-external-ip"
    operator_finalizer="osac.openshift.io/externalip-finalizer"
    for id in "${CREATED_EXTERNAL_IP_IDS[@]}"; do
        if ! crs="$(external_ip_crs_json "$id")"; then
            printf 'Could not read ExternalIP %s while cleaning up\n' "$id" >&2
            return 1
        fi
        count="$(jq -er '.items | length' <<<"$crs")" || return 1
        if [[ "$count" == 1 ]]; then
            cr="$(jq -c '.items[0]' <<<"$crs")"
            uid="$(jq -r '.metadata.uid' <<<"$cr")"
            name="$(jq -er '.metadata.name' <<<"$cr")" || return 1
            if [[ -z "$(jq -r '.metadata.deletionTimestamp // ""' <<<"$cr")" ]]; then
                output_file="${TEMP_DIR}/cleanup-external-ip-${id}.out"
                if ! "$CLI_BIN" --config "$CLI_CONFIG_DIR" --tenant "$OSAC_TENANT" \
                    delete externalip "$id" >"$output_file" 2>&1; then
                    cat "$output_file" >&2
                    printf 'Could not request cleanup of test ExternalIP %s\n' "$id" >&2
                    return 1
                fi
            fi

            deadline=$((SECONDS + 600))
            while ((SECONDS < deadline)); do
                if ! crs="$(external_ip_crs_json "$id")"; then
                    printf 'Could not read ExternalIP %s while waiting for cleanup\n' "$id" >&2
                    return 1
                fi
                count="$(jq -er '.items | length' <<<"$crs")" || return 1
                [[ "$count" != 0 ]] || break
                [[ "$count" == 1 ]] || return 1
                cr="$(jq -c '.items[0]' <<<"$crs")"
                release_job="$(jq -c '[.status.provisioningJobs[]? | select(.type == "deprovision")] | last // {}' <<<"$cr")"
                release_job_id="$(jq -r '.jobID // ""' <<<"$release_job")"
                job_state="$(jq -r '.state // ""' <<<"$release_job")"
                if [[ "$job_state" == Failed || "$job_state" == Canceled ]]; then
                    printf 'ExternalIP %s release job ended in %s; preserving resources\n' "$id" "$job_state" >&2
                    return 1
                fi
                if [[ -n "$release_job_id" ]] \
                    && jq -e --arg hold "$hold_finalizer" --arg operator "$operator_finalizer" '
                        (.metadata.finalizers // []) as $values
                        | ($values | index($hold) != null)
                          and ($values | index($operator) == null)' <<<"$cr" >/dev/null; then
                    release_generation="$(jq -er '.metadata.generation' <<<"$cr")" || return 1
                    if artifacts="$(external_ip_aap_job_artifacts "$release_job_id" 2>/dev/null)" \
                        && external_ip_assert_result "$artifacts" external_ip.release "$uid" \
                            "$release_generation"; then
                        oc patch externalip "$name" -n "$NETWORKING_NAMESPACE" \
                            --type=merge -p="$(jq -c --arg hold "$hold_finalizer" \
                                '{metadata:{finalizers:((.metadata.finalizers // []) | map(select(. != $hold)))}}' \
                                <<<"$cr")" >/dev/null \
                            || return 1
                    fi
                fi
                sleep 2
            done
            [[ "$count" == 0 ]] || {
                printf 'Timed out waiting for test ExternalIP %s cleanup\n' "$id" >&2
                return 1
            }
        elif [[ "$count" == 0 ]]; then
            uid=""
        else
            printf 'Multiple ExternalIP CRs found for Fulfillment UUID %s\n' "$id" >&2
            return 1
        fi

        state_file="$(state_snapshot)" || return 1
        if jq -e --arg uid "$uid" --arg id "$id" \
            'any(.external_ips[]; .fulfillment_id == $id or ($uid != "" and .uid == $uid))' \
            <<<"$state_file" >/dev/null; then
            printf 'Provider reservation for test ExternalIP %s remains after CR cleanup\n' "$id" >&2
            return 1
        fi
        external_ip_remove_created_id "$id"
        remaining="${#CREATED_EXTERNAL_IP_IDS[@]}"
        deadline=$((SECONDS + 600))
        while ((SECONDS < deadline)); do
            if external_ip_pool_has_delta "$remaining"; then
                break
            fi
            sleep 2
        done
        external_ip_pool_has_delta "$remaining" || {
            printf 'Fulfillment capacity did not return to the expected count after ExternalIP %s cleanup\n' "$id" >&2
            return 1
        }
    done
    return 0
}

cleanup_created_external_ip_attachments() {
    if [[ "${#CREATED_EXTERNAL_IP_ATTACHMENT_IDS[@]}" == 0 \
        && "${#CREATED_SYNTHETIC_EXTERNAL_IP_ATTACHMENT_IDS[@]}" == 0 ]]; then
        return 0
    fi
    if [[ "${#CREATED_EXTERNAL_IP_ATTACHMENT_IDS[@]}" -gt 0 ]]; then
        [[ -n "$CLI_BIN" && -x "$CLI_BIN" && -n "$CLI_CONFIG_DIR" && -d "$CLI_CONFIG_DIR" ]] \
            || return 1
    fi
    local id crs count cr uid name eip_id bmi_id eip_crs eip_cr eip_count address
    local state state_rows state_count entry namespace target_selected selected_bmi_id
    for id in "${CREATED_EXTERNAL_IP_ATTACHMENT_IDS[@]}"; do
        crs="$(external_ip_attachment_crs_json "$id")" || return 1
        count="$(jq -er '.items | length' <<<"$crs")" || return 1
        state="$(state_snapshot)" || return 1
        state_rows="$(jq -ce --arg id "$id" \
            '[.external_ip_attachments[] | select(.fulfillment_id == $id)]' <<<"$state")" || return 1
        state_count="$(jq -er 'length' <<<"$state_rows")" || return 1
        if [[ "$count" == 0 ]]; then
            [[ "$state_count" == 0 ]] || {
                printf 'ExternalIPAttachment CR %s is absent while provider state remains; preserving all dependent resources\n' "$id" >&2
                return 1
            }
            external_ip_attachment_remove_created_id "$id"
            continue
        fi
        [[ "$count" == 1 ]] || {
            printf 'Multiple ExternalIPAttachment CRs exist for test UUID %s\n' "$id" >&2
            return 1
        }
        cr="$(external_ip_attachment_cr_json "$id")" || return 1
        uid="$(jq -er '.metadata.uid' <<<"$cr")" || return 1
        name="$(jq -er '.metadata.name' <<<"$cr")" || return 1
        eip_id="$(jq -er '.spec.externalIP' <<<"$cr")" || return 1
        bmi_id="$(jq -er '.spec.baremetalInstance' <<<"$cr")" || return 1
        [[ "${CREATED_EXTERNAL_IP_IDS[*]} " == *"${eip_id} "* ]] || {
            printf 'ExternalIPAttachment %s references ExternalIP %s outside this cleanup scope\n' "$id" "$eip_id" >&2
            return 1
        }
        eip_crs="$(external_ip_crs_json "$eip_id")" || return 1
        eip_count="$(jq -er '.items | length' <<<"$eip_crs")" || return 1
        [[ "$eip_count" == 1 ]] || {
            printf 'ExternalIPAttachment %s does not have exactly one ExternalIP CR for %s\n' "$id" "$eip_id" >&2
            return 1
        }
        eip_cr="$(jq -c '.items[0]' <<<"$eip_crs")"
        jq -e --arg id "$eip_id" --arg tenant "$OSAC_TENANT" '
          .metadata.labels["osac.openshift.io/externalip-uuid"] == $id
          and .metadata.annotations["osac.openshift.io/tenant"] == $tenant
          and .metadata.annotations["osac.openshift.io/implementation-strategy"] == "agentless_net"
          and .status.state == "Allocated"' <<<"$eip_cr" >/dev/null || {
            printf 'ExternalIPAttachment %s refers to an unallocated or out-of-scope ExternalIP %s\n' "$id" "$eip_id" >&2
            return 1
        }
        address="$(jq -er '.status.address' <<<"$eip_cr")" || return 1
        if [[ "$state_count" == 1 ]]; then
            entry="$(jq -c '.[0]' <<<"$state_rows")"
            [[ "$(jq -r '.uid' <<<"$entry")" == "$uid" ]] || {
                printf 'ExternalIPAttachment %s provider UID does not match its Kubernetes UID\n' "$id" >&2
                return 1
            }
            jq -e --arg id "$bmi_id" --arg tenant "$OSAC_TENANT" '
              .payload.context.target.kind == "BareMetalInstance"
              and .payload.context.target.fulfillment_id == $id
              and .payload.context.target.tenant_id == $tenant
              and (.payload.context.target.name | startswith("agentless-eip-bmi-"))' \
                <<<"$entry" >/dev/null || {
                printf 'ExternalIPAttachment %s saved target context is outside the selected BMI scope\n' "$id" >&2
                return 1
            }
            namespace="$(jq -er '.payload.provider.namespace_name' <<<"$entry")" || return 1
        else
            target_selected=false
            for selected_bmi_id in "${CREATED_BARE_METAL_INSTANCE_IDS[@]}"; do
                [[ "$selected_bmi_id" == "$bmi_id" ]] && target_selected=true
            done
            [[ "$target_selected" == true ]] || {
                printf 'ExternalIPAttachment %s references BMI %s outside the Fulfillment cleanup scope and has no saved provider identity\n' "$id" "$bmi_id" >&2
                return 1
            }
            namespace=""
        fi
        info "Cleaning ExternalIPAttachment ${id} (${name}) before its ExternalIP or BMI..."
        delete_external_ip_attachment_and_verify "$id" "$uid" "$address" "$namespace" || return 1
    done
    cleanup_synthetic_external_ip_attachments
}

cleanup_synthetic_external_ip_attachments() {
    [[ "${#CREATED_SYNTHETIC_EXTERNAL_IP_ATTACHMENT_IDS[@]}" -gt 0 ]] || return 0
    local index id uid state rows count entry address namespace output_file
    local external_ip_id selected selected_id
    for index in "${!CREATED_SYNTHETIC_EXTERNAL_IP_ATTACHMENT_IDS[@]}"; do
        id="${CREATED_SYNTHETIC_EXTERNAL_IP_ATTACHMENT_IDS[$index]}"
        uid="${CREATED_SYNTHETIC_EXTERNAL_IP_ATTACHMENT_UIDS[$index]}"
        state="$(state_snapshot)" || return 1
        rows="$(jq -ce --arg uid "$uid" --arg id "$id" \
            '[.external_ip_attachments[] | select(.uid == $uid and .fulfillment_id == $id)]' \
            <<<"$state")" || return 1
        count="$(jq -er 'length' <<<"$rows")" || return 1
        if [[ "$count" == 0 ]]; then
            synthetic_external_ip_attachment_remove_created_id "$id"
            continue
        fi
        [[ "$count" == 1 ]] || {
            printf 'Multiple provider rows exist for synthetic ExternalIPAttachment %s\n' "$id" >&2
            return 1
        }
        entry="$(jq -c '.[0]' <<<"$rows")"
        jq -e --arg tenant "$OSAC_TENANT" --arg uid "$uid" --arg id "$id" \
            --arg target "$EXTERNAL_IP_SYNTHETIC_TARGET_NAME" \
            '.uid == $uid and .fulfillment_id == $id and .tenant_id == $tenant
             and .payload.context.target.kind == "BareMetalInstance"
             and .payload.context.target.name == $target
             and (.payload.context.external_ip.name | startswith("agentless-eip-"))' \
            <<<"$entry" >/dev/null || {
            printf 'Synthetic ExternalIPAttachment provider row %s is outside this run scope\n' "$id" >&2
            return 1
        }
        external_ip_id="$(jq -er '.payload.context.external_ip.fulfillment_id' <<<"$entry")" \
            || return 1
        selected=false
        for selected_id in "${CREATED_EXTERNAL_IP_IDS[@]}" "${CLEANUP_EIP_IDS[@]}"; do
            [[ -n "$selected_id" && "$selected_id" == "$external_ip_id" ]] && selected=true
        done
        [[ "$selected" == true ]] || {
            printf 'Synthetic ExternalIPAttachment %s references an ExternalIP outside this cleanup scope\n' "$id" >&2
            return 1
        }
        address="$(jq -er '.external_address' <<<"$entry")" || return 1
        namespace="$(jq -er '.payload.provider.namespace_name' <<<"$entry")" || return 1
        output_file="${TEMP_DIR}/synthetic-eia-${id}-cleanup"
        if ! run_synthetic_external_ip_attachment_detach_job "$entry" "$output_file" 1; then
            printf 'AAP detach failed for synthetic ExternalIPAttachment %s; preserving its EIP and network\n' "$id" >&2
            return 1
        fi
        assert_external_ip_attachment_provider_absent "$uid" "$address" "$namespace" \
            || return 1
        synthetic_external_ip_attachment_remove_created_id "$id"
        info "Synthetic ExternalIPAttachment ${id} provider state and forwarding rules are removed."
    done
    return 0
}

remove_external_ip_client_routes() {
    local id crs count address state index
    local -a addresses=("${EXTERNAL_IP_CLIENT_ROUTE_ADDRESSES[@]}" "${CLEANUP_EIP_ADDRESSES[@]}")
    if ((${#addresses[@]} == 0 && ${#CREATED_EXTERNAL_IP_IDS[@]} == 0 && ${#CLEANUP_EIP_IDS[@]} == 0)); then
        return 0
    fi
    for id in "${CREATED_EXTERNAL_IP_IDS[@]}"; do
        crs="$(external_ip_crs_json "$id" 2>/dev/null || true)"
        [[ -n "$crs" ]] || crs='{"items":[]}'
        count="$(jq -r '.items | length' <<<"$crs" 2>/dev/null || printf '0')"
        if [[ "$count" == 1 ]]; then
            address="$(jq -r '.items[0].status.address // ""' <<<"$crs")"
            [[ -z "$address" ]] || addresses+=("$address")
        fi
    done
    state="$(state_snapshot)" || return 1
    for id in "${CLEANUP_EIP_IDS[@]}"; do
        address="$(jq -r --arg id "$id" \
            '[.external_ips[] | select(.fulfillment_id == $id) | .address] | first // ""' <<<"$state")"
        [[ -z "$address" ]] || addresses+=("$address")
    done
    for address in "${addresses[@]}"; do
        [[ -n "$address" ]] || continue
        remove_external_ip_client_route "$address" || return 1
        for index in "${!EXTERNAL_IP_CLIENT_ROUTE_ADDRESSES[@]}"; do
            if [[ "${EXTERNAL_IP_CLIENT_ROUTE_ADDRESSES[$index]}" == "$address" ]]; then
                unset 'EXTERNAL_IP_CLIENT_ROUTE_ADDRESSES[index]'
            fi
        done
    done
    return 0
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

cleanup_created_external_ip_pool() {
    [[ "$EXTERNAL_IP_POOL_PENDING_CLEANUP" == true ]] || return 0

    local request_file="${TEMP_DIR}/external-ip-pool-cleanup.request.json"
    local response_file="${TEMP_DIR}/external-ip-pool-cleanup.response.json"
    local error_file="${TEMP_DIR}/external-ip-pool-cleanup.error.json"
    local list_request="${TEMP_DIR}/external-ip-pool-list.request.json"
    local list_response="${TEMP_DIR}/external-ip-pool-list.response.json"
    local list_error="${TEMP_DIR}/external-ip-pool-list.error.json"
    local list_json match_count recovered_id baseline_pools current_pools

    info "Cleaning up the ExternalIPPool created by this run..."

    if [[ -z "$EXTERNAL_IP_POOL_ID" ]]; then
        jq -n --arg name "$EXTERNAL_IP_POOL_NAME" \
            '{filter: ("this.metadata.name == \"" + $name + "\" && this.metadata.tenant == \"shared\"")} ' \
            >"$list_request" || return 1
        if ! external_ip_pool_rpc List "$list_request" "$list_response" "$list_error"; then
            cat "$list_error" >&2
            printf 'Could not recover the ExternalIPPool ID for cleanup\n' >&2
            return 1
        fi
        if ! list_json="$(external_ip_pool_list_items "$list_response")"; then
            printf 'Private Fulfillment List returned an invalid ExternalIPPool response\n' >&2
            return 1
        fi
        match_count="$(jq -er 'length' <<<"$list_json")" || return 1
        if [[ "$match_count" -gt 1 ]]; then
            printf 'Multiple pools use the generated ExternalIPPool name; preserving resources\n' >&2
            return 1
        fi
        if [[ "$match_count" == 0 ]]; then
            if ! current_pools="$(state_snapshot | jq -cS '.external_ip_pools')"; then
                printf 'Could not verify ExternalIPPool provider state during recovery\n' >&2
                return 1
            fi
            if ! baseline_pools="$(jq -cS '.external_ip_pools' "$BASELINE_STATE_FILE")"; then
                printf 'Could not read the baseline ExternalIPPool state\n' >&2
                return 1
            fi
            if [[ "$current_pools" != "$baseline_pools" ]]; then
                printf 'ExternalIPPool state changed but its Fulfillment ID is unknown; preserving provider state\n' >&2
                return 1
            fi
            EXTERNAL_IP_POOL_PENDING_CLEANUP=false
            return 0
        fi
        recovered_id="$(jq -er --arg name "$EXTERNAL_IP_POOL_NAME" \
            '.[0] | select(.metadata.name == $name and .metadata.tenant == "shared") | .id' \
            <<<"$list_json")" || {
            printf 'Private Fulfillment List returned a pool with unexpected ownership metadata\n' >&2
            return 1
        }
        EXTERNAL_IP_POOL_ID="$recovered_id"
    fi

    jq -n --arg id "$EXTERNAL_IP_POOL_ID" '{id: $id}' >"$request_file" || return 1
    if ! external_ip_pool_rpc Delete "$request_file" "$response_file" "$error_file"; then
        if ! external_ip_pool_rpc_error_is_not_found "$error_file" "$response_file"; then
            cat "$error_file" >&2
            printf 'Private Fulfillment could not delete ExternalIPPool %s\n' \
                "$EXTERNAL_IP_POOL_ID" >&2
            return 1
        fi
    fi
    if ! wait_for_external_ip_pool_removed "$EXTERNAL_IP_POOL_ID" \
        "$EXTERNAL_IP_POOL_K8S_UID"; then
        printf 'ExternalIPPool %s is not fully removed; preserving provider access for recovery\n' \
            "$EXTERNAL_IP_POOL_ID" >&2
        return 1
    fi

    if [[ -n "$EXTERNAL_IP_POOL_DELETE_AAP_JOB_ID" ]]; then
        info "AAP ExternalIPPool delete job ID: ${EXTERNAL_IP_POOL_DELETE_AAP_JOB_ID}"
    fi
    EXTERNAL_IP_POOL_PENDING_CLEANUP=false
    if [[ "${CLEANUP_MODE:-false}" == true ]]; then
        local index
        for index in "${!CLEANUP_PENDING_POOL_IDS[@]}"; do
            if [[ "${CLEANUP_PENDING_POOL_IDS[$index]}" == "$EXTERNAL_IP_POOL_ID" ]]; then
                unset 'CLEANUP_PENDING_POOL_IDS[index]'
            fi
        done
    fi
    return 0
}

cleanup_provisioning_vlan() {
    "$AAP_DIR/.venv/bin/python" - "$TEMP_DIR/inventory.yml" <<'PY'
import pathlib
import sys
import yaml

inventory = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
value = inventory["all"]["vars"]["agentless_net_provisioning_network"]["vlan_id"]
if not isinstance(value, int) or not 1 <= value <= 4094:
    raise SystemExit("invalid AgentlessNet provisioning VLAN")
print(value)
PY
}

cleanup_interrupted_dhcp_clients() {
    [[ "$SUITE_USES_SUBNET_DHCP" == true ]] || return 0

    local all_names labeled_names container client prefix recovery_dir label_dir
    local runner_label client_label prefix_label
    local container_mac saved_mac attachment_file resource_json uid subnet_ref
    local selected_subnet candidate_subnet link previous_prefix candidate
    local switch_vlan_json provisioning_vlan
    local duplicate
    local -a containers=() matching_dirs=()
    local -A selected_containers=()

    CLEANUP_CLIENTS_COMPLETE=false
    labeled_names="$(docker ps -a --filter label=io.osac.e2e.runner=vlan-e2e \
        --format '{{.Names}}')" \
        || die "Could not list Step 5 DHCP client containers"
    all_names="$(docker ps -a --format '{{.Names}}')" \
        || die "Could not inspect local containers for interrupted DHCP clients"
    while IFS= read -r container; do
        [[ -n "$container" ]] || continue
        [[ -z "${selected_containers[$container]:-}" ]] || continue
        if grep -Fxq -- "$container" <<<"$labeled_names"; then
            selected_containers["$container"]=true
            containers+=("$container")
            continue
        fi
        if [[ "$container" =~ ^(osac5530-[0-9]{14})-(a1|a2|b1)$ ]]; then
            selected_containers["$container"]=true
            containers+=("$container")
        fi
    done <<<"$all_names"

    if ((${#containers[@]} == 0)); then
        CLEANUP_CLIENTS_COMPLETE=true
        return 0
    fi

    info "Found ${#containers[@]} interrupted Step 5 DHCP client containers; offboarding them before Subnet cleanup..."
    for container in "${containers[@]}"; do
        if [[ "$container" =~ ^(.+)-(a1|a2|b1)$ ]]; then
            prefix="${BASH_REMATCH[1]}"
            client="${BASH_REMATCH[2]}"
        else
            die "Test DHCP client container ${container} has an invalid name"
        fi

        runner_label="$(docker inspect --format \
            '{{index .Config.Labels "io.osac.e2e.runner"}}' "$container" 2>/dev/null || true)"
        client_label="$(docker inspect --format \
            '{{index .Config.Labels "io.osac.e2e.client"}}' "$container" 2>/dev/null || true)"
        prefix_label="$(docker inspect --format \
            '{{index .Config.Labels "io.osac.e2e.prefix"}}' "$container" 2>/dev/null || true)"
        if [[ "$runner_label" == vlan-e2e ]]; then
            [[ "$client_label" == "$client" && "$prefix_label" == "$prefix" ]] \
                || die "Step 5 client ${container} has mismatched ownership labels"
        else
            [[ "$prefix" =~ ^osac5530-[0-9]{14}$ ]] \
                || die "Refusing to clean unlabelled non-E2E client container ${container}"
        fi

        label_dir="$(docker inspect --format \
            '{{index .Config.Labels "io.osac.e2e.run-dir"}}' "$container" 2>/dev/null || true)"
        recovery_dir=""
        if [[ -n "$label_dir" && "$label_dir" != '<no value>' ]]; then
            [[ "$label_dir" == "${TMPDIR:-/tmp}"/osac-5530-vlan-e2e.* \
                || "$label_dir" == /tmp/osac-5530-vlan-e2e.* ]] \
                && [[ -d "$label_dir" && ! -L "$label_dir" ]] \
                || die "Step 5 client ${container} has an invalid recovery directory label"
            recovery_dir="$label_dir"
        else
            container_mac="$(docker exec "$container" cat /sys/class/net/eth0/address 2>/dev/null || true)"
            container_mac="$(tr '[:upper:]' '[:lower:]' <<<"$container_mac" | tr -d '\r\n')"
            matching_dirs=()
            for candidate in "${TMPDIR:-/tmp}"/osac-5530-vlan-e2e.*; do
                [[ -d "$candidate" && ! -L "$candidate" \
                    && -f "$candidate/client-${client}.mac" ]] || continue
                saved_mac="$(tr '[:upper:]' '[:lower:]' \
                    <"$candidate/client-${client}.mac" | tr -d '\r\n')"
                [[ -n "$container_mac" && "$saved_mac" == "$container_mac" ]] \
                    && matching_dirs+=("$candidate")
            done
            if [[ "${#matching_dirs[@]}" == 1 ]]; then
                recovery_dir="${matching_dirs[0]}"
            elif [[ "${#matching_dirs[@]}" == 0 \
                && "$prefix" =~ ^osac5530-[0-9]{14}$ ]]; then
                recovery_dir=""
            else
                die "Could not identify unique recovery data for Step 5 client ${container}"
            fi
        fi
        previous_prefix="$DHCP_CLIENT_PREFIX"
        DHCP_CLIENT_PREFIX="$prefix"
        stop_dhcp_client "$client"
        docker exec "$container" ip address flush dev eth0 >/dev/null 2>&1 || true
        docker exec "$container" ip route flush dev eth0 >/dev/null 2>&1 || true

        if [[ -n "$recovery_dir" ]]; then
            [[ "$recovery_dir" != "$TEMP_DIR" \
                && -f "$recovery_dir/client-${client}.mac" ]] \
                || die "Step 5 client ${container} has no saved MAC recovery data"
            duplicate=false
            for candidate in "${STALE_RECOVERY_DIRS[@]}"; do
                [[ "$candidate" == "$recovery_dir" ]] && duplicate=true
            done
            [[ "$duplicate" == true ]] || STALE_RECOVERY_DIRS+=("$recovery_dir")
            saved_mac="$(tr '[:upper:]' '[:lower:]' \
                <"$recovery_dir/client-${client}.mac" | tr -d '\r\n')"
            [[ "$saved_mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] \
                || die "Saved MAC for Step 5 client ${container} is invalid"
            attachment_file="$recovery_dir/${client}-move-network-attachment.json"
            if [[ ! -f "$attachment_file" ]]; then
                attachment_file="$recovery_dir/${client}-offboard-network-attachment.json"
            fi
        else
            client_link "$client"
            switch_vlan_json="$(switch_exec "$CLIENT_SWITCH" bridge -j vlan show dev "$CLIENT_SWITCH_PORT")" \
                || die "Could not verify the legacy Step 5 client ${container} switch port"
            provisioning_vlan="$(cleanup_provisioning_vlan)" \
                || die "Could not read the declared AgentlessNet provisioning VLAN"
            jq -e --arg port "$CLIENT_SWITCH_PORT" --argjson vlan "$provisioning_vlan" '
              length == 1
              and .[0].ifname == $port
              and (.[0].vlans | length == 1)
              and (.[0].vlans[0].vlan | tonumber) == $vlan
              and (.[0].vlans[0].flags | index("PVID") != null)
              and (.[0].vlans[0].flags | index("Egress Untagged") != null)
            ' <<<"$switch_vlan_json" >/dev/null \
                || die "Legacy Step 5 client ${container} is not on the provisioning access VLAN"
            info "Legacy Step 5 client ${container} is on the provisioning VLAN; removing its stale container and link."
            attachment_file=""
        fi

        if [[ -n "$attachment_file" && -f "$attachment_file" ]]; then
            resource_json="$(jq -ce '.osac_job_vars.resource' "$attachment_file")" \
                || die "Saved BMI attachment recovery data for ${container} is invalid"
            jq -e --arg client "$client" --arg tenant "$OSAC_TENANT" '
              .apiVersion == "osac.openshift.io/v1alpha1"
              and .kind == "BareMetalInstance"
              and .metadata.name == ("osac-e2e-" + $client)
              and .spec.externalHostID == ("osac-e2e-" + $client)
              and .metadata.annotations["osac.openshift.io/tenant"] == $tenant
              and .metadata.annotations["osac.openshift.io/owner-reference"] == "vlan-e2e-run"
              and .metadata.annotations["osac.openshift.io/implementation-strategy"] == "agentless_net"
              and (.metadata.uid | type == "string" and test("^[0-9a-f-]{36}$"))
              and (.spec.networkAttachments | type == "array" and length == 1)
              and (.spec.networkAttachments[0].subnetRef | type == "string")
              and (.spec.networkAttachments[0].interface == "eth0")
            ' <<<"$resource_json" >/dev/null \
                || die "Saved BMI identity for Step 5 client ${container} is outside the E2E scope"
            uid="$(jq -er '.metadata.uid' <<<"$resource_json")"
            subnet_ref="$(jq -er '.spec.networkAttachments[0].subnetRef' <<<"$resource_json")"
            selected_subnet=false
            for candidate_subnet in "${CREATED_SUBNET_IDS[@]}"; do
                if [[ "$candidate_subnet" == "$subnet_ref" ]]; then
                    selected_subnet=true
                    break
                fi
            done
            [[ "$selected_subnet" == true ]] \
                || die "Step 5 client ${container} references a Subnet outside the selected cleanup scope"

            if [[ "$AAP_SUBNET_READER_SETUP_ATTEMPTED" != true ]]; then
                configure_aap_subnet_reader \
                    || die "Could not configure AAP access to offboard Step 5 client ${container}"
            fi
            CLIENT_BMI_UID["$client"]="$uid"
            CLIENT_ATTACHMENT_SUBNET["$client"]="$subnet_ref"
            CLIENT_ATTACHMENT_ACTIVE["$client"]=true
            CLIENT_ATTACHMENT_PENDING["$client"]=false
            CLIENT_PRESERVED_MAC["$client"]="$saved_mac"
            offboard_client_from_subnet "$client" "$subnet_ref" \
                || die "Could not offboard Step 5 client ${container} through osac-move-network-attachment"
        fi

        docker rm -f "$container" >/dev/null \
            || die "Could not remove Step 5 DHCP client container ${container}"
        link="$(client_macvlan_name "$client")"
        if sudo ip link show dev "$link" >/dev/null 2>&1; then
            sudo ip link delete dev "$link" \
                || die "Could not remove Step 5 DHCP client link ${link}"
        fi
        DHCP_CLIENT_PREFIX="$previous_prefix"
    done

    CLEANUP_CLIENTS_COMPLETE=true
    info "Removed interrupted Step 5 DHCP client containers and links."
}

prepare_suite_cleanup() {
    local vn_filter subnet_filter eip_filter vn_items subnet_items eip_items
    local bmi_filter bmi_items attachment_filter attachment_items attachment_object attachment_id attachment_cr attachment_uid
    local nat_gateway_filter nat_gateway_items nat_gateway_object nat_gateway_cr nat_gateway_crs nat_gateway_uid nat_gateway_vn_id nat_gateway_vn_uid nat_gateway_vn_cr nat_gateway_eip_id nat_gateway_eip_uid nat_gateway_eip_cr nat_gateway_id
    local pool_request pool_response pool_error pool_items external_ips state_before=""
    local pool_object pool_id pool_name pool_cidr pool_crs pool_count pool_cr pool_uid
    local pool_state pool_status allocated available total active_count
    local eip_object eip_id eip_name eip_cr eip_uid eip_pool eip_address id item attachment_eip_id attachment_bmi_id
    local eip_candidate selected_eip
    local pool_ip_crs pool_ip_count pool_eip_ids_json selected_parent parent_id_candidate
    local provider_ip_rows provider_ip_count assigned_id
    local vn_ids_json subnet_ids_json pool_uids_json pool_ids_json eip_uids_json eip_ids_json attachment_uids_json attachment_ids_json
    local nat_gateway_uids_json nat_gateway_ids_json selected_nat_gateway_ids_json nat_gateway_orphan_rows
    local snapshot synthetic_row synthetic_id synthetic_uid synthetic_eip_id synthetic_address
    local -a vn_ids=() vn_uids=() subnet_ids=() subnet_uids=()
    local -a pool_ids=() pool_uids=() pool_cidrs=() pool_eip_ids_jsons=()
    local -a pool_initial_allocated=() pool_initial_available=()
    local -a eip_ids=() eip_uids=() assigned_eip_ids=()
    local -a bmi_ids=() bmi_uids=() attachment_ids=() attachment_uids=()
    local -a synthetic_attachment_ids=() synthetic_attachment_uids=()
    local -a nat_gateway_ids=() nat_gateway_uids=() nat_gateway_vn_ids=() nat_gateway_eip_ids=()
    local -a pool_eip_ids=() pool_eip_uids=()
    local index

    vn_filter="$(cleanup_name_filter 'agentless-smoke-vn-' "$VIRTUAL_NETWORK_NAME_INPUT")"
    subnet_filter="$vn_filter"
    if [[ "$SUITE_USES_VN" == true ]]; then
        vn_items="$(cleanup_cli_list_json virtualnetwork "$vn_filter")" \
            || die "Could not list test VirtualNetworks for cleanup"
        jq -e --arg tenant "$OSAC_TENANT" --arg prefix 'agentless-smoke-vn-' \
            --arg custom "$VIRTUAL_NETWORK_NAME_INPUT" '
          all(.[]; .metadata.tenant == $tenant
            and (.metadata.name | (startswith($prefix) or ($custom != "" and startswith($custom))))
            and (.id | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")))' \
            <<<"$vn_items" >/dev/null \
            || die "Fulfillment returned a VirtualNetwork outside the test tenant or name scope"
        while IFS= read -r id; do
            [[ -n "$id" ]] || continue
            local cr uid
            cr="$(virtual_network_cr_json "$id")"
            jq -e '.metadata.annotations["osac.openshift.io/implementation-strategy"] == "agentless_net"' \
                <<<"$cr" >/dev/null \
                || die "Refusing to clean a test-named VirtualNetwork managed by another provider"
            uid="$(jq -er '.metadata.uid' <<<"$cr")" \
                || die "VirtualNetwork ${id} has no Kubernetes UID"
            vn_ids+=("$id")
            vn_uids+=("$uid")
        done < <(jq -r '.[].id' <<<"$vn_items")
    fi

    if [[ "$SUITE_USES_SUBNET" == true || "$SUITE_USES_VN" == true ]]; then
        subnet_items="$(cleanup_cli_list_json subnet "$subnet_filter")" \
            || die "Could not list test Subnets for cleanup"
        jq -e --arg tenant "$OSAC_TENANT" --arg prefix 'agentless-smoke-vn-' \
            --arg custom "$VIRTUAL_NETWORK_NAME_INPUT" '
          all(.[]; .metadata.tenant == $tenant
            and (.metadata.name | (startswith($prefix) or ($custom != "" and startswith($custom))))
            and (.id | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")))' \
            <<<"$subnet_items" >/dev/null \
            || die "Fulfillment returned a Subnet outside the test tenant or name scope"
        if [[ "$SUITE_USES_SUBNET" != true ]] \
            && [[ "$(jq -er 'length' <<<"$subnet_items")" != 0 ]]; then
            die "Test Subnets remain; use --cleanup --subnet-dhcp or --cleanup --full before deleting VirtualNetworks"
        fi
        if [[ "$SUITE_USES_SUBNET" == true ]]; then
            while IFS= read -r item; do
                [[ -n "$item" ]] || continue
                local parent_id cr uid
                id="$(jq -er '.id' <<<"$item")"
                parent_id="$(cleanup_subnet_parent_id "$item")" \
                    || die "Test Subnet ${id} has no parent VirtualNetwork reference"
                selected_parent=false
                for parent_id_candidate in "${vn_ids[@]}"; do
                    if [[ "$parent_id_candidate" == "$parent_id" ]]; then
                        selected_parent=true
                        break
                    fi
                done
                [[ "$selected_parent" == true ]] \
                    || die "Subnet ${id} is not attached to a selected E2E VirtualNetwork"
                cr="$(subnet_cr_json "$id" "$parent_id")"
                jq -e '.metadata.annotations["osac.openshift.io/implementation-strategy"] == "agentless_net"' \
                    <<<"$cr" >/dev/null \
                    || die "Refusing to clean a test-named Subnet managed by another provider"
                uid="$(jq -er '.metadata.uid' <<<"$cr")" \
                    || die "Subnet ${id} has no Kubernetes UID"
                subnet_ids+=("$id")
                subnet_uids+=("$uid")
            done < <(jq -c '.[]' <<<"$subnet_items")
        fi
    fi

    eip_items='[]'
    if [[ "$SUITE_USES_EXTERNAL_IP" == true ]]; then
        eip_filter='this.metadata.name.startsWith("agentless-eip-")'
        eip_items="$(cleanup_cli_list_json externalip "$eip_filter")" \
            || die "Could not list test ExternalIPs for cleanup"
        jq -e --arg tenant "$OSAC_TENANT" '
          all(.[]; .metadata.tenant == $tenant
            and (.metadata.name | startswith("agentless-eip-"))
            and (.id | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")))' \
            <<<"$eip_items" >/dev/null \
            || die "Fulfillment returned an ExternalIP outside the test tenant or name scope"
    fi

    bmi_items='[]'
    attachment_items='[]'
    if [[ "$SUITE_USES_EXTERNAL_IP_ATTACHMENT" == true ]]; then
        attachment_filter='this.metadata.name.startsWith("agentless-eip-attach-")'
        attachment_items="$(cleanup_cli_list_json externalipattachment "$attachment_filter")" \
            || die "Could not list test ExternalIPAttachments for cleanup"
        jq -e --arg tenant "$OSAC_TENANT" '
          all(.[]; .metadata.tenant == $tenant
            and (.metadata.name | startswith("agentless-eip-attach-"))
            and (.id | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")))' \
            <<<"$attachment_items" >/dev/null \
            || die "Fulfillment returned an ExternalIPAttachment outside the E2E tenant or name scope"
        if [[ "$(jq -er 'length' <<<"$attachment_items")" -gt 0 ]]; then
            bmi_filter='this.metadata.name.startsWith("agentless-eip-bmi-")'
            bmi_items="$(cleanup_cli_list_json baremetalinstance "$bmi_filter")" \
                || die "Could not list legacy BMaaS targets for attachment cleanup"
            jq -e --arg tenant "$OSAC_TENANT" '
              all(.[]; .metadata.tenant == $tenant
                and (.metadata.name | startswith("agentless-eip-bmi-"))
                and (.id | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")))' \
                <<<"$bmi_items" >/dev/null \
                || die "Fulfillment returned a legacy BMI outside the E2E tenant or name scope"
            while IFS= read -r id; do
                [[ -n "$id" ]] || continue
                local bmi_cr bmi_uid
                bmi_cr="$(baremetal_instance_cr_json "$id")" \
                    || die "Legacy test target ${id} has no unique Kubernetes CR"
                bmi_uid="$(jq -er '.metadata.uid' <<<"$bmi_cr")" \
                    || die "Legacy test target ${id} has no Kubernetes UID"
                bmi_ids+=("$id")
                bmi_uids+=("$bmi_uid")
            done < <(jq -r '.[].id' <<<"$bmi_items")
        fi
        while IFS= read -r attachment_id; do
            [[ -n "$attachment_id" ]] || continue
            attachment_cr="$(external_ip_attachment_cr_json "$attachment_id")" \
                || die "Test ExternalIPAttachment ${attachment_id} has no unique Kubernetes CR"
            attachment_uid="$(jq -er '.metadata.uid' <<<"$attachment_cr")" \
                || die "Test ExternalIPAttachment ${attachment_id} has no Kubernetes UID"
            attachment_eip_id="$(jq -er '.spec.externalIP' <<<"$attachment_cr")" \
                || die "Test ExternalIPAttachment ${attachment_id} has no ExternalIP reference"
            attachment_bmi_id="$(jq -er '.spec.baremetalInstance' <<<"$attachment_cr")" \
                || die "Test ExternalIPAttachment ${attachment_id} has no BMI reference"
            local selected_eip=false
            while IFS= read -r eip_id; do
                if [[ "$eip_id" == "$attachment_eip_id" ]]; then
                    selected_eip=true
                    break
                fi
            done < <(jq -r '.[].id' <<<"$eip_items")
            [[ "$selected_eip" == true ]] \
                || die "ExternalIPAttachment ${attachment_id} references an ExternalIP outside the test name scope"
            [[ " ${bmi_ids[*]} " == *" ${attachment_bmi_id} "* ]] \
                || die "ExternalIPAttachment ${attachment_id} references a BMI outside the test name scope"
            attachment_ids+=("$attachment_id")
            attachment_uids+=("$attachment_uid")
        done < <(jq -r '.[].id' <<<"$attachment_items")
    fi

    nat_gateway_items='[]'
    if [[ "$SUITE_USES_NAT_GATEWAY" == true ]]; then
        nat_gateway_filter='this.metadata.name.startsWith("agentless-natgw-")'
        nat_gateway_items="$(cleanup_cli_list_json natgateway "$nat_gateway_filter")" \
            || die "Could not list test NATGateways for cleanup"
        jq -e --arg tenant "$OSAC_TENANT" '
          all(.[]; .metadata.tenant == $tenant
            and (.metadata.name | startswith("agentless-natgw-"))
            and (.id | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")))' \
            <<<"$nat_gateway_items" >/dev/null \
            || die "Fulfillment returned a NATGateway outside the test tenant or name scope"
        if [[ "$(jq -er 'length' <<<"$nat_gateway_items")" -gt 0 ]]; then
            state_before="$(state_snapshot)" \
                || die "Could not read AgentlessNet state before NATGateway cleanup discovery"
        fi
        while IFS= read -r nat_gateway_object; do
            [[ -n "$nat_gateway_object" ]] || continue
            nat_gateway_id="$(jq -er '.id' <<<"$nat_gateway_object")"
            nat_gateway_crs="$(nat_gateway_crs_json "$nat_gateway_id")" \
                || die "Could not find NATGateway CR ${nat_gateway_id} during cleanup discovery"
            [[ "$(jq -er '.items | length' <<<"$nat_gateway_crs")" == 1 ]] \
                || die "NATGateway ${nat_gateway_id} has no unique Kubernetes CR"
            nat_gateway_cr="$(jq -c '.items[0]' <<<"$nat_gateway_crs")"
            nat_gateway_vn_id="$(jq -er '.spec.virtualNetwork' <<<"$nat_gateway_cr")" \
                || die "NATGateway ${nat_gateway_id} has no VirtualNetwork reference"
            nat_gateway_eip_id="$(jq -er '.spec.externalIP' <<<"$nat_gateway_cr")" \
                || die "NATGateway ${nat_gateway_id} has no ExternalIP reference"
            nat_gateway_cr="$(nat_gateway_cr_json "$nat_gateway_id" \
                "$nat_gateway_vn_id" "$nat_gateway_eip_id")" \
                || die "NATGateway ${nat_gateway_id} identity is outside cleanup scope"
            selected_parent=false
            for parent_id_candidate in "${vn_ids[@]}"; do
                [[ "$parent_id_candidate" == "$nat_gateway_vn_id" ]] && selected_parent=true
            done
            [[ "$selected_parent" == true ]] \
                || die "NATGateway ${nat_gateway_id} references a VirtualNetwork outside cleanup scope"
            selected_eip=false
            while IFS= read -r eip_candidate; do
                if [[ "$eip_candidate" == "$nat_gateway_eip_id" ]]; then
                    selected_eip=true
                    break
                fi
            done < <(jq -r '.[].id' <<<"$eip_items")
            [[ "$selected_eip" == true ]] \
                || die "NATGateway ${nat_gateway_id} references an ExternalIP outside cleanup scope"
            nat_gateway_eip_cr="$(external_ip_cr_json "$nat_gateway_eip_id" "")" \
                || die "NATGateway ${nat_gateway_id} ExternalIP CR is unavailable"
            pool_id="$(jq -er '.spec.pool' <<<"$nat_gateway_eip_cr")" \
                || die "NATGateway ${nat_gateway_id} ExternalIP has no pool reference"
            EXTERNAL_IP_POOL_ID="$pool_id"
            pool_status="$(external_ip_pool_get_json)" \
                || die "Could not inspect the test pool for NATGateway ${nat_gateway_id}"
            jq -e --arg id "$pool_id" '
              .object.id == $id
              and .object.metadata.tenant == "shared"
              and (.object.metadata.name | startswith("agentless-e2e-pool-"))
              and (.object.spec.ipFamily == "IP_FAMILY_IPV4" or .object.spec.ipFamily == "IPv4")
              and (.object.spec.cidrs | type == "array" and length == 1)' \
                <<<"$pool_status" >/dev/null \
                || die "NATGateway ${nat_gateway_id} ExternalIP references a pool outside cleanup scope"
            EXTERNAL_IP_POOL_CIDR="$(jq -er '.object.spec.cidrs[0]' <<<"$pool_status")" \
                || die "Test pool ${pool_id} has no unique IPv4 CIDR"
            pool_crs="$(external_ip_pool_crs_json "$pool_id")" \
                || die "Could not inspect the Kubernetes pool for NATGateway ${nat_gateway_id}"
            [[ "$(jq -er '.items | length' <<<"$pool_crs")" == 1 ]] \
                || die "Test pool ${pool_id} has no unique Kubernetes CR"
            pool_cr="$(jq -c '.items[0]' <<<"$pool_crs")"
            external_ip_pool_validate_cr_identity "$pool_cr" "$pool_id" \
                || die "Test pool ${pool_id} Kubernetes CR identity does not match Fulfillment"
            nat_gateway_uid="$(jq -er '.metadata.uid' <<<"$nat_gateway_cr")" \
                || die "NATGateway ${nat_gateway_id} has no Kubernetes UID"
            nat_gateway_vn_cr="$(virtual_network_cr_json "$nat_gateway_vn_id")" \
                || die "NATGateway ${nat_gateway_id} VirtualNetwork CR is unavailable"
            nat_gateway_vn_uid="$(jq -er '.metadata.uid' <<<"$nat_gateway_vn_cr")" \
                || die "NATGateway ${nat_gateway_id} VirtualNetwork has no Kubernetes UID"
            nat_gateway_eip_cr="$(external_ip_cr_json "$nat_gateway_eip_id" "$pool_id")" \
                || die "NATGateway ${nat_gateway_id} ExternalIP CR is unavailable"
            nat_gateway_eip_uid="$(jq -er '.metadata.uid' <<<"$nat_gateway_eip_cr")" \
                || die "NATGateway ${nat_gateway_id} ExternalIP has no Kubernetes UID"
            local provider_rows provider_count
            provider_rows="$(jq -ce --arg uid "$nat_gateway_uid" \
                '[.nat_gateways[] | select(.uid == $uid)]' <<<"$state_before")" \
                || die "Could not inspect saved NATGateway provider state"
            provider_count="$(jq -er 'length' <<<"$provider_rows")"
            [[ "$provider_count" -le 1 ]] \
                || die "NATGateway ${nat_gateway_id} has duplicate provider rows"
            if [[ "$provider_count" == 1 ]]; then
                jq -e --arg id "$nat_gateway_id" --arg uid "$nat_gateway_uid" \
                    --arg vn_uid "$nat_gateway_vn_uid" --arg eip_uid "$nat_gateway_eip_uid" \
                    --arg tenant "$OSAC_TENANT" '
                  .[0].uid == $uid
                  and .[0].fulfillment_id == $id
                  and .[0].tenant_id == $tenant
                  and .[0].virtual_network_uid == $vn_uid
                  and .[0].external_ip_uid == $eip_uid' <<<"$provider_rows" >/dev/null \
                    || die "NATGateway ${nat_gateway_id} saved provider identity is outside cleanup scope"
            fi
            nat_gateway_ids+=("$nat_gateway_id")
            nat_gateway_uids+=("$nat_gateway_uid")
            nat_gateway_vn_ids+=("$nat_gateway_vn_id")
            nat_gateway_eip_ids+=("$nat_gateway_eip_id")
        done < <(jq -c '.[]' <<<"$nat_gateway_items")
    fi

    pool_items='[]'
    external_ips='{"items":[]}'
    if [[ "$SUITE_USES_POOL" == true ]]; then
        pool_request="${TEMP_DIR}/cleanup-external-ip-pools.request.json"
        pool_response="${TEMP_DIR}/cleanup-external-ip-pools.response.json"
        pool_error="${TEMP_DIR}/cleanup-external-ip-pools.error.json"
        jq -n '{filter:"this.metadata.tenant == \"shared\""}' >"$pool_request" \
            || die "Could not write ExternalIPPool cleanup lookup request"
        if ! external_ip_pool_rpc List "$pool_request" "$pool_response" "$pool_error"; then
            cat "$pool_error" >&2
            die "Could not list shared ExternalIPPools for cleanup"
        fi
        pool_items="$(external_ip_pool_list_items "$pool_response")" \
            || die "Private Fulfillment List returned an invalid ExternalIPPool response"
        pool_items="$(jq -ce '[.[] | select((.metadata.name // "") | startswith("agentless-e2e-pool-"))]' \
            <<<"$pool_items")" \
            || die "Could not select test ExternalIPPools for cleanup"
        if [[ "$(jq -er 'length' <<<"$pool_items")" != 0 ]]; then
            external_ips="$(oc get externalips -n "$NETWORKING_NAMESPACE" -o json)" \
                || die "Could not list ExternalIP CRs before pool cleanup"
            state_before="$(state_snapshot)" \
                || die "Could not read AgentlessNet state before suite cleanup"
        fi

        while IFS= read -r pool_object; do
            [[ -n "$pool_object" ]] || continue
            pool_id="$(jq -er '.id' <<<"$pool_object")" \
                || die "Test ExternalIPPool has no Fulfillment UUID"
            pool_name="$(jq -er '.metadata.name' <<<"$pool_object")"
            pool_cidr="$(jq -er '.spec.cidrs | select(type == "array" and length == 1) | .[0]' <<<"$pool_object")" \
                || die "Test ExternalIPPool ${pool_name} has an invalid CIDR list"
            jq -e --arg name "$pool_name" --arg id "$pool_id" '
              .metadata.tenant == "shared"
              and (.metadata.name | startswith("agentless-e2e-pool-"))
              and .id == $id
              and (.spec.ipFamily == "IP_FAMILY_IPV4" or .spec.ipFamily == "IPv4")' \
                <<<"$pool_object" >/dev/null \
                || die "Refusing to clean an ExternalIPPool outside the E2E name and tenant scope"

            EXTERNAL_IP_POOL_ID="$pool_id"
            EXTERNAL_IP_POOL_CIDR="$pool_cidr"
            pool_crs="$(external_ip_pool_crs_json "$pool_id")" \
                || die "Could not inspect test ExternalIPPool ${pool_id} in Kubernetes"
            pool_count="$(jq -er '.items | length' <<<"$pool_crs")" \
                || die "Could not count ExternalIPPool CRs for cleanup"
            [[ "$pool_count" -le 1 ]] \
                || die "Multiple Kubernetes ExternalIPPool CRs found for ${pool_id}"
            if [[ "$pool_count" == 1 ]]; then
                pool_cr="$(jq -c '.items[0]' <<<"$pool_crs")"
                external_ip_pool_validate_cr_identity "$pool_cr" "$pool_id" \
                    || die "ExternalIPPool ${pool_id} CR identity does not match its Fulfillment object"
                pool_uid="$(jq -er '.metadata.uid' <<<"$pool_cr")"
            else
                pool_uid="$(jq -r --arg id "$pool_id" \
                    '[.external_ip_pools[] | select(.fulfillment_id == $id) | .uid] | first // ""' \
                    <<<"$state_before")"
            fi

            pool_eip_ids=()
            pool_eip_uids=()
            if [[ "$SUITE_USES_EXTERNAL_IP" == true ]]; then
                while IFS= read -r eip_object; do
                    [[ -n "$eip_object" ]] || continue
                    eip_id="$(jq -er '.id' <<<"$eip_object")"
                    eip_name="$(jq -er '.metadata.name' <<<"$eip_object")"
                    eip_cr="$(jq -ce --arg id "$eip_id" \
                        '[.items[] | select(.metadata.labels["osac.openshift.io/externalip-uuid"] == $id)]
                         | if length == 1 then .[0] else error("expected one ExternalIP CR") end' \
                        <<<"$external_ips")" \
                        || die "ExternalIP ${eip_id} has no unique Kubernetes CR"
                    eip_pool="$(jq -er '.spec.pool' <<<"$eip_cr")" \
                        || die "ExternalIP ${eip_id} has no pool reference"
                    if [[ "$eip_pool" == "$pool_id" ]]; then
                        [[ "$(jq -r '.metadata.annotations["osac.openshift.io/tenant"] // ""' <<<"$eip_cr")" == "$OSAC_TENANT" ]] \
                            || die "ExternalIP ${eip_id} belongs to a different tenant"
                        [[ "$(jq -r '.metadata.annotations["osac.openshift.io/implementation-strategy"] // ""' <<<"$eip_cr")" == agentless_net ]] \
                            || die "ExternalIP ${eip_id} is not managed by AgentlessNet"
                        eip_uid="$(jq -er '.metadata.uid' <<<"$eip_cr")"
                        eip_address="$(jq -r '.status.address // ""' <<<"$eip_cr")"
                        [[ -n "$eip_address" ]] \
                            || die "ExternalIP ${eip_id} has no address for route cleanup"
                        pool_eip_ids+=("$eip_id")
                        pool_eip_uids+=("$eip_uid")
                        CLEANUP_EIP_ADDRESSES+=("$eip_address")
                    fi
                done < <(jq -c '.[]' <<<"$eip_items")
            fi

            pool_ip_crs="$(jq -ce --arg id "$pool_id" \
                '[.items[] | select(.spec.pool == $id)]' <<<"$external_ips")" \
                || die "Could not select ExternalIP CRs for pool ${pool_id}"
            pool_ip_count="$(jq -er 'length' <<<"$pool_ip_crs")"
            if [[ "$SUITE_USES_EXTERNAL_IP" != true && "$pool_ip_count" != 0 ]]; then
                die "ExternalIPPool ${pool_name} still has ExternalIPs; use --cleanup --external-ip or --cleanup --full"
            fi
            if [[ "$pool_ip_count" != "${#pool_eip_ids[@]}" ]]; then
                die "ExternalIPPool ${pool_name} has ExternalIPs outside the selected E2E name scope"
            fi
            pool_eip_ids_json="$(cleanup_array_json "${pool_eip_ids[@]}")"
            provider_ip_rows="$(jq -ce --arg uid "$pool_uid" \
                '[.external_ips[] | select(.pool_uid == $uid)]' <<<"$state_before")" \
                || die "Could not inspect provider ExternalIP state for pool ${pool_id}"
            provider_ip_count="$(jq -er 'length' <<<"$provider_ip_rows")"
            [[ "$provider_ip_count" == "${#pool_eip_ids[@]}" ]] \
                || die "ExternalIPPool ${pool_name} has provider allocations outside the selected E2E resources"
            if [[ "$provider_ip_count" -gt 0 ]]; then
                jq -e --argjson ids "$pool_eip_ids_json" \
                    'all(.[]; .fulfillment_id as $id | ($ids | index($id)) != null)' \
                    <<<"$provider_ip_rows" >/dev/null \
                    || die "ExternalIPPool ${pool_name} has a provider reservation outside the E2E name scope"
            fi

            EXTERNAL_IP_POOL_K8S_UID="$pool_uid"
            pool_status="$(external_ip_pool_get_json)" \
                || die "Could not read ExternalIPPool ${pool_id} counters before cleanup"
            allocated="$(jq -er '(.object.status.allocated // 0) | tonumber' <<<"$pool_status")" \
                || die "ExternalIPPool ${pool_id} has an invalid allocated counter"
            available="$(jq -er '(.object.status.available // 0) | tonumber' <<<"$pool_status")" \
                || die "ExternalIPPool ${pool_id} has an invalid available counter"
            total="$(jq -er '.object.status.total | tonumber' <<<"$pool_status")" \
                || die "ExternalIPPool ${pool_id} has an invalid total counter"
            [[ "$allocated" == "$provider_ip_count" && "$available" -le "$total" ]] \
                || die "ExternalIPPool ${pool_name} counters do not match its E2E provider allocations"
            pool_ids+=("$pool_id")
            pool_uids+=("$pool_uid")
            pool_cidrs+=("$pool_cidr")
            pool_eip_ids_jsons+=("$pool_eip_ids_json")
            pool_initial_allocated+=("$((allocated - provider_ip_count))")
            pool_initial_available+=("$((available + provider_ip_count))")
            eip_ids+=("${pool_eip_ids[@]}")
            eip_uids+=("${pool_eip_uids[@]}")
            assigned_eip_ids+=("${pool_eip_ids[@]}")
        done < <(jq -c '.[]' <<<"$pool_items")

        if [[ "$SUITE_USES_EXTERNAL_IP" == true ]]; then
            for eip_id in $(jq -r '.[].id' <<<"$eip_items"); do
                local assigned=false
                for assigned_id in "${assigned_eip_ids[@]}"; do
                    [[ "$assigned_id" == "$eip_id" ]] && assigned=true
                done
                [[ "$assigned" == true ]] \
                    || die "Test ExternalIP ${eip_id} does not belong to a selected E2E ExternalIPPool"
            done
        fi
    fi

    if [[ "$SUITE_USES_NAT_GATEWAY" == true ]]; then
        for nat_gateway_eip_id in "${nat_gateway_eip_ids[@]}"; do
            local selected_nat_gateway_eip=false
            for eip_id in "${eip_ids[@]}"; do
                [[ "$eip_id" == "$nat_gateway_eip_id" ]] && selected_nat_gateway_eip=true
            done
            [[ "$selected_nat_gateway_eip" == true ]] \
                || die "Test NATGateway references an ExternalIP outside the selected E2E pool"
        done
    fi

    if [[ -z "$state_before" ]]; then
        state_before="$(state_snapshot)" \
            || die "Could not snapshot AgentlessNet state before suite cleanup"
    fi
    if [[ "$SUITE_USES_NAT_GATEWAY" == true ]]; then
        selected_nat_gateway_ids_json="$(cleanup_array_json "${nat_gateway_ids[@]}")"
        nat_gateway_orphan_rows="$(jq -ce --arg tenant "$OSAC_TENANT" \
            --arg custom_vn "$VIRTUAL_NETWORK_NAME_INPUT" \
            --argjson ids "$selected_nat_gateway_ids_json" '
          [.nat_gateways[]
            | select(.tenant_id == $tenant
              and ((.payload.context.external_ip.name // "") | startswith("agentless-eip-"))
              and (((.payload.context.virtual_network.name // "") | startswith("agentless-smoke-vn-"))
                or ($custom_vn != "" and
                  ((.payload.context.virtual_network.name // "") | startswith($custom_vn)))))
            | select((.fulfillment_id as $id | ($ids | index($id))) == null)]' \
            <<<"$state_before")" \
            || die "Could not check for orphaned test NATGateway provider rows"
        [[ "$(jq -er 'length' <<<"$nat_gateway_orphan_rows")" == 0 ]] \
            || die "Found a test NATGateway provider row without a matching test CR; preserving state for manual recovery"
    fi
    if [[ "$SUITE_USES_EXTERNAL_IP_ATTACHMENT" == true ]]; then
        while IFS= read -r synthetic_row; do
            [[ -n "$synthetic_row" ]] || continue
            jq -e --arg tenant "$OSAC_TENANT" \
                --arg target "$EXTERNAL_IP_SYNTHETIC_TARGET_NAME" '
              .tenant_id == $tenant
              and .payload.context.target.kind == "BareMetalInstance"
              and .payload.context.target.name == $target
              and (.payload.context.external_ip.name | startswith("agentless-eip-"))
            ' <<<"$synthetic_row" >/dev/null \
                || die "Synthetic ExternalIPAttachment provider state is outside the cleanup scope"
            synthetic_id="$(jq -er '.fulfillment_id' <<<"$synthetic_row")" \
                || die "Synthetic ExternalIPAttachment state has no Fulfillment UUID"
            synthetic_uid="$(jq -er '.uid' <<<"$synthetic_row")" \
                || die "Synthetic ExternalIPAttachment state has no Kubernetes UID"
            synthetic_eip_id="$(jq -er '.payload.context.external_ip.fulfillment_id' <<<"$synthetic_row")" \
                || die "Synthetic ExternalIPAttachment state has no ExternalIP UUID"
            synthetic_address="$(jq -er '.external_address' <<<"$synthetic_row")" \
                || die "Synthetic ExternalIPAttachment state has no allocated address"
            [[ "$synthetic_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ \
                && "$synthetic_uid" =~ ^[0-9a-f-]{36}$ ]] \
                || die "Synthetic ExternalIPAttachment state has an invalid identity"
            local selected_synthetic_eip=false selected_test_eip
            for selected_test_eip in "${eip_ids[@]}"; do
                [[ "$selected_test_eip" == "$synthetic_eip_id" ]] \
                    && selected_synthetic_eip=true
            done
            [[ "$selected_synthetic_eip" == true ]] \
                || die "Synthetic ExternalIPAttachment ${synthetic_id} references an ExternalIP outside cleanup scope"
            synthetic_attachment_ids+=("$synthetic_id")
            synthetic_attachment_uids+=("$synthetic_uid")
            CLEANUP_EIP_ADDRESSES+=("$synthetic_address")
        done < <(jq -ce --arg tenant "$OSAC_TENANT" \
            --arg target "$EXTERNAL_IP_SYNTHETIC_TARGET_NAME" '
          [.external_ip_attachments[]
            | select(.tenant_id == $tenant
              and .payload.context.target.name == $target
              and (.payload.context.external_ip.name | startswith("agentless-eip-")))][]
        ' <<<"$state_before")
    fi
    printf '%s\n' "$state_before" >"$CURRENT_STATE_FILE" \
        || die "Could not save the cleanup baseline state"
    CLEANUP_STATE_FILE="${TEMP_DIR}/cleanup-state.json"
    cp -- "$CURRENT_STATE_FILE" "$CLEANUP_STATE_FILE" \
        || die "Could not preserve the pre-cleanup provider snapshot"

    CLEANUP_VN_UIDS=("${vn_uids[@]}")
    CLEANUP_SUBNET_UIDS=("${subnet_uids[@]}")
    CLEANUP_POOL_UIDS=("${pool_uids[@]}")
    CLEANUP_POOL_IDS=("${pool_ids[@]}")
    CLEANUP_POOL_CIDRS=("${pool_cidrs[@]}")
    CLEANUP_POOL_EIP_IDS_JSON=("${pool_eip_ids_jsons[@]}")
    CLEANUP_EIP_UIDS=("${eip_uids[@]}")
    CLEANUP_EIP_IDS=("${eip_ids[@]}")
    CLEANUP_ATTACHMENT_UIDS=("${attachment_uids[@]}" "${synthetic_attachment_uids[@]}")
    CLEANUP_ATTACHMENT_IDS=("${attachment_ids[@]}" "${synthetic_attachment_ids[@]}")
    CLEANUP_NAT_GATEWAY_UIDS=("${nat_gateway_uids[@]}")
    CLEANUP_NAT_GATEWAY_IDS=("${nat_gateway_ids[@]}")
    CLEANUP_SYNTHETIC_ATTACHMENT_UIDS=("${synthetic_attachment_uids[@]}")
    CLEANUP_SYNTHETIC_ATTACHMENT_IDS=("${synthetic_attachment_ids[@]}")
    CLEANUP_BMI_IDS=("${bmi_ids[@]}")
    CLEANUP_BMI_UIDS=("${bmi_uids[@]}")
    CLEANUP_PENDING_POOL_IDS=("${pool_ids[@]}")
    CREATED_IDS=("${vn_ids[@]}")
    CREATED_SUBNET_IDS=("${subnet_ids[@]}")
    CREATED_EXTERNAL_IP_IDS=("${eip_ids[@]}")
    CREATED_EXTERNAL_IP_ATTACHMENT_IDS=("${attachment_ids[@]}")
    CREATED_NAT_GATEWAY_IDS=("${nat_gateway_ids[@]}")
    CREATED_NAT_GATEWAY_UIDS=("${nat_gateway_uids[@]}")
    CREATED_SYNTHETIC_EXTERNAL_IP_ATTACHMENT_IDS=("${synthetic_attachment_ids[@]}")
    CREATED_SYNTHETIC_EXTERNAL_IP_ATTACHMENT_UIDS=("${synthetic_attachment_uids[@]}")
    CREATED_BARE_METAL_INSTANCE_IDS=("${bmi_ids[@]}")

    vn_ids_json="$(cleanup_array_json "${CLEANUP_VN_UIDS[@]}")"
    subnet_ids_json="$(cleanup_array_json "${CLEANUP_SUBNET_UIDS[@]}")"
    pool_uids_json="$(cleanup_array_json "${CLEANUP_POOL_UIDS[@]}")"
    pool_ids_json="$(cleanup_array_json "${CLEANUP_POOL_IDS[@]}")"
    eip_uids_json="$(cleanup_array_json "${CLEANUP_EIP_UIDS[@]}")"
    eip_ids_json="$(cleanup_array_json "${CLEANUP_EIP_IDS[@]}")"
    attachment_uids_json="$(cleanup_array_json "${CLEANUP_ATTACHMENT_UIDS[@]}")"
    attachment_ids_json="$(cleanup_array_json "${CLEANUP_ATTACHMENT_IDS[@]}")"
    nat_gateway_uids_json="$(cleanup_array_json "${CLEANUP_NAT_GATEWAY_UIDS[@]}")"
    nat_gateway_ids_json="$(cleanup_array_json "${CLEANUP_NAT_GATEWAY_IDS[@]}")"
    jq --argjson vns "$vn_ids_json" --argjson subnets "$subnet_ids_json" \
        --argjson pools "$pool_uids_json" --argjson pool_ids "$pool_ids_json" \
        --argjson ips "$eip_uids_json" --argjson ip_ids "$eip_ids_json" \
        --argjson attachments "$attachment_uids_json" --argjson attachment_ids "$attachment_ids_json" \
        --argjson nat_gateways "$nat_gateway_uids_json" --argjson nat_gateway_ids "$nat_gateway_ids_json" '
      .virtual_networks |= map(select((.uid as $uid | ($vns | index($uid))) == null))
      | .subnets |= map(select((.uid as $uid | ($subnets | index($uid))) == null))
      | .external_ip_pools |= map(select(
          (.uid as $uid | ($pools | index($uid))) == null
          and (.fulfillment_id as $id | ($pool_ids | index($id))) == null))
      | .external_ips |= map(select(
          (.uid as $uid | ($ips | index($uid))) == null
          and (.fulfillment_id as $id | ($ip_ids | index($id))) == null))
      | .external_ip_attachments |= map(select(
          (.uid as $uid | ($attachments | index($uid))) == null
          and (.fulfillment_id as $id | ($attachment_ids | index($id))) == null))
      | .nat_gateways |= map(select(
          (.uid as $uid | ($nat_gateways | index($uid))) == null
          and (.fulfillment_id as $id | ($nat_gateway_ids | index($id))) == null))' \
        "$CURRENT_STATE_FILE" >"$BASELINE_STATE_FILE" \
        || die "Could not compute the unrelated provider-state baseline for cleanup"
    CLEANUP_DISCOVERY_COMPLETE=true
    if [[ "$SUITE_USES_SUBNET_DHCP" == true ]]; then
        CLEANUP_CLIENTS_COMPLETE=false
    fi

    info "Suite cleanup found ${#CLEANUP_NAT_GATEWAY_IDS[@]} NATGateways, ${#CLEANUP_ATTACHMENT_IDS[@]} ExternalIPAttachments (${#CLEANUP_SYNTHETIC_ATTACHMENT_IDS[@]} synthetic), ${#CLEANUP_EIP_IDS[@]} ExternalIPs, ${#CLEANUP_BMI_IDS[@]} legacy BMaaS instances, ${#CLEANUP_POOL_IDS[@]} test pools, ${#CREATED_SUBNET_IDS[@]} Subnets, and ${#CREATED_IDS[@]} VirtualNetworks."
    if [[ "$SUITE_USES_NAT_GATEWAY" == true ]]; then
        if ! cleanup_created_nat_gateways; then
            CLEANUP_CLIENTS_COMPLETE=false
            PRESERVE_E2E_RECOVERY_ARTIFACTS=true
            die "Could not clean up all test NATGateways; preserving clients, ExternalIPs, pool, Subnets, VirtualNetworks, endpoint, routes, and AAP configuration"
        fi
        if ! cleanup_nat_gateway_endpoint; then
            CLEANUP_CLIENTS_COMPLETE=false
            PRESERVE_E2E_RECOVERY_ARTIFACTS=true
            die "Could not remove the NATGateway test endpoint; preserving dependent test resources and AAP configuration"
        fi
    fi
    if [[ "${#CREATED_EXTERNAL_IP_ATTACHMENT_IDS[@]}" -gt 0 \
        || "${#CREATED_SYNTHETIC_EXTERNAL_IP_ATTACHMENT_IDS[@]}" -gt 0 ]]; then
        cleanup_created_external_ip_attachments \
            || die "Could not detach all test ExternalIPAttachments; preserving ExternalIPs, Subnet, and VirtualNetwork"
    fi
    remove_external_ip_client_routes \
        || die "Could not remove test-only upstream routes; preserving ExternalIPs and network resources"
    for index in "${!CLEANUP_POOL_IDS[@]}"; do
        EXTERNAL_IP_POOL_ID="${CLEANUP_POOL_IDS[$index]}"
        EXTERNAL_IP_POOL_K8S_UID="${CLEANUP_POOL_UIDS[$index]}"
        EXTERNAL_IP_POOL_CIDR="${CLEANUP_POOL_CIDRS[$index]}"
        EXTERNAL_IP_POOL_INITIAL_ALLOCATED="${pool_initial_allocated[$index]}"
        EXTERNAL_IP_POOL_INITIAL_AVAILABLE="${pool_initial_available[$index]}"
        EXTERNAL_IP_POOL_PENDING_CLEANUP=true
        mapfile -t CREATED_EXTERNAL_IP_IDS < <(jq -r '.[]' <<<"${CLEANUP_POOL_EIP_IDS_JSON[$index]}")
        if [[ "${#CREATED_EXTERNAL_IP_IDS[@]}" -gt 0 ]] && ! cleanup_created_external_ips; then
            die "Could not release all test ExternalIPs from pool ${EXTERNAL_IP_POOL_ID}"
        fi
        cleanup_created_external_ip_pool \
            || die "Could not delete test ExternalIPPool ${EXTERNAL_IP_POOL_ID}"
        CREATED_EXTERNAL_IP_IDS=()
    done
    [[ "${#CLEANUP_PENDING_POOL_IDS[@]}" == 0 ]] \
        || die "Test ExternalIPPool cleanup is incomplete; preserving provider access"
    EXTERNAL_IP_POOL_ID=""
    EXTERNAL_IP_POOL_K8S_UID=""
    EXTERNAL_IP_POOL_CIDR=""
    EXTERNAL_IP_POOL_PENDING_CLEANUP=false
    if [[ "${#CREATED_BARE_METAL_INSTANCE_IDS[@]}" -gt 0 ]]; then
        cleanup_created_bare_metal_instances \
            || die "Could not offboard test BMaaS instances; preserving their Subnets and VirtualNetworks"
    fi
    if [[ "$SUITE_USES_SUBNET_DHCP" == true ]]; then
        cleanup_interrupted_dhcp_clients
    fi
    info "Suite cleanup resource discovery is complete; the exit handler will delete Subnets before VirtualNetworks and verify provider cleanup."
}

supervisor_service_status_is_absent() {
    [[ "$2" == "$1: ERROR (no such process)" ]]
}

verify_suite_cleanup_provider_state() {
    local current collection uid before after entry namespace host_interface baseline_uids
    local parent_uid vlan_interface vlan_id config config_path service_status service_name service_file
    if ! current="$(state_snapshot)"; then
        printf 'Could not snapshot AgentlessNet state after suite cleanup\n' >&2
        return 1
    fi
    printf '%s\n' "$current" >"$CURRENT_STATE_FILE" || return 1

    for uid in "${CLEANUP_VN_UIDS[@]}"; do
        if jq -e --arg uid "$uid" 'any(.virtual_networks[]; .uid == $uid)' \
            <<<"$current" >/dev/null; then
            printf 'Deleted test VirtualNetwork provider row remains for UID %s\n' "$uid" >&2
            return 1
        fi
    done
    for uid in "${CLEANUP_SUBNET_UIDS[@]}"; do
        if jq -e --arg uid "$uid" 'any(.subnets[]; .uid == $uid)' \
            <<<"$current" >/dev/null; then
            printf 'Deleted test Subnet provider row remains for UID %s\n' "$uid" >&2
            return 1
        fi
    done
    for uid in "${CLEANUP_POOL_UIDS[@]}"; do
        if jq -e --arg uid "$uid" 'any(.external_ip_pools[]; .uid == $uid)' \
            <<<"$current" >/dev/null; then
            printf 'Deleted test ExternalIPPool provider row remains for UID %s\n' "$uid" >&2
            return 1
        fi
    done
    for uid in "${CLEANUP_EIP_UIDS[@]}"; do
        if jq -e --arg uid "$uid" 'any(.external_ips[]; .uid == $uid)' \
            <<<"$current" >/dev/null; then
            printf 'Deleted test ExternalIP provider row remains for UID %s\n' "$uid" >&2
            return 1
        fi
    done
    for uid in "${CLEANUP_ATTACHMENT_UIDS[@]}"; do
        if jq -e --arg uid "$uid" 'any(.external_ip_attachments[]; .uid == $uid)' \
            <<<"$current" >/dev/null; then
            printf 'Deleted test ExternalIPAttachment provider row remains for UID %s\n' "$uid" >&2
            return 1
        fi
    done
    for uid in "${CLEANUP_NAT_GATEWAY_UIDS[@]}"; do
        if jq -e --arg uid "$uid" 'any(.nat_gateways[]; .uid == $uid)' \
            <<<"$current" >/dev/null; then
            printf 'Deleted test NATGateway provider row remains for UID %s\n' "$uid" >&2
            return 1
        fi
    done

    if [[ -s "$CLEANUP_STATE_FILE" ]]; then
        while IFS= read -r entry; do
            uid="$(jq -r '.uid' <<<"$entry")"
            namespace="$(jq -r '.namespace_name' <<<"$entry")"
            host_interface="$(jq -r '.host_interface' <<<"$entry")"
            local namespaces
            if ! namespaces="$(netnode ip netns list)"; then
                printf 'Could not inspect namespaces after deleting VirtualNetwork UID %s\n' "$uid" >&2
                return 1
            fi
            if awk -v name="$namespace" '$1 == name { found=1 } END { exit !found }' \
                <<<"$namespaces"; then
                printf 'Deleted VirtualNetwork namespace %s remains on the network node\n' "$namespace" >&2
                return 1
            fi
            if netnode ip link show dev "$host_interface" >/dev/null 2>&1; then
                printf 'Deleted VirtualNetwork interface %s remains on the network node\n' "$host_interface" >&2
                return 1
            fi
            service_name="agentless-dhcp-${uid}"
            if service_status="$(netnode supervisorctl -c /etc/agentless-net/supervisord.conf \
                status "$service_name" 2>&1)"; then
                printf 'Deleted VirtualNetwork DHCP service remains for UID %s\n' "$uid" >&2
                return 1
            fi
            if ! supervisor_service_status_is_absent "$service_name" "$service_status"; then
                printf 'Could not verify Supervisor state for deleted VirtualNetwork UID %s\n' "$uid" >&2
                return 1
            fi
            if ! netnode test -d /etc/agentless-net/supervisor.d; then
                printf 'Could not inspect Supervisor program files after deleting VirtualNetwork UID %s\n' "$uid" >&2
                return 1
            fi
            service_file="/etc/agentless-net/supervisor.d/${uid}.ini"
            if netnode test -f "$service_file"; then
                printf 'Deleted VirtualNetwork Supervisor config %s remains on the network node\n' \
                    "$service_file" >&2
                return 1
            fi
        done < <(jq -c --argjson uids "$(cleanup_array_json "${CLEANUP_VN_UIDS[@]}")" \
            '[.virtual_networks[] | select(.uid as $uid | ($uids | index($uid)) != null)][]' \
            "$CLEANUP_STATE_FILE")

        while IFS= read -r entry; do
            uid="$(jq -r '.uid' <<<"$entry")"
            parent_uid="$(jq -r '.virtual_network_uid' <<<"$entry")"
            vlan_interface="$(jq -r '.vlan_interface' <<<"$entry")"
            vlan_id="$(jq -r '.vlan_id' <<<"$entry")"
            namespace="$(jq -r --arg uid "$parent_uid" \
                '.virtual_networks[] | select(.uid == $uid) | .namespace_name' \
                "$CLEANUP_STATE_FILE")"
            if netnode ip netns exec "$namespace" ip link show dev "$vlan_interface" \
                >/dev/null 2>&1; then
                printf 'Deleted Subnet VLAN interface %s remains in namespace %s\n' \
                    "$vlan_interface" "$namespace" >&2
                return 1
            fi
            config_path="/etc/agentless-net/dhcp/${parent_uid}/dnsmasq.conf"
            if config="$(netnode cat "$config_path" 2>/dev/null)" \
                && grep -Fxq "interface=${vlan_interface}" <<<"$config"; then
                printf 'Deleted Subnet VLAN interface %s remains in DHCP configuration\n' \
                    "$vlan_interface" >&2
                return 1
            fi
            if ! (assert_vlan_on_switches "$vlan_id" false) >/dev/null 2>&1; then
                printf 'Deleted Subnet VLAN %s remains on a Cumulus switch\n' "$vlan_id" >&2
                return 1
            fi
        done < <(jq -c --argjson uids "$(cleanup_array_json "${CLEANUP_SUBNET_UIDS[@]}")" \
            '[.subnets[] | select(.uid as $uid | ($uids | index($uid)) != null)][]' \
            "$CLEANUP_STATE_FILE")
    fi

    for collection in virtual_networks subnets external_ip_pools external_ips external_ip_attachments nat_gateways; do
        baseline_uids="$(jq -r --arg collection "$collection" \
            'if (.[$collection] | type) != "array" then error("invalid state collection") else .[$collection][].uid end' \
            "$BASELINE_STATE_FILE")" || return 1
        while IFS= read -r uid; do
            [[ -n "$uid" ]] || continue
            before="$(jq -cS --arg uid "$uid" --arg collection "$collection" \
                '.[$collection][] | select(.uid == $uid)' "$BASELINE_STATE_FILE")"
            after="$(jq -cS --arg uid "$uid" --arg collection "$collection" \
                '.[$collection][] | select(.uid == $uid)' "$CURRENT_STATE_FILE")"
            if [[ -z "$after" || "$before" != "$after" ]]; then
                printf 'Unrelated AgentlessNet %s state for UID %s changed during cleanup\n' \
                    "$collection" "$uid" >&2
                return 1
            fi
        done <<<"$baseline_uids"
    done
    return 0
}

cleanup_created_virtual_networks() {
    local cleanup_incomplete=false
    local test_nat_gateways_clean=true
    local test_vns_clean=true test_subnets_clean=true test_external_ips_clean=true test_external_ip_pool_clean=true
    local test_external_ip_attachments_clean=true test_baremetal_instances_clean=true routes_clean=true
    local id selector current
    if [[ "$SUITE_USES_NAT_GATEWAY" == true ]] && ! cleanup_created_nat_gateways; then
        test_nat_gateways_clean=false
        printf 'ERROR: preserving clients, ExternalIPs, pool, Subnets, VirtualNetworks, endpoint, routes, and AAP configuration because NATGateway cleanup is incomplete\n' >&2
        cleanup_incomplete=true
    elif [[ "$SUITE_USES_NAT_GATEWAY" == true ]] && ! cleanup_nat_gateway_endpoint; then
        test_nat_gateways_clean=false
        printf 'ERROR: preserving test dependencies and AAP configuration because NATGateway endpoint cleanup is incomplete\n' >&2
        cleanup_incomplete=true
    fi
    if [[ "$test_nat_gateways_clean" == true ]] && ! cleanup_created_external_ip_attachments; then
        test_external_ip_attachments_clean=false
        printf 'ERROR: preserving test ExternalIPs, DHCP target, Subnet, VirtualNetwork, route, and provider state because detach cleanup is incomplete\n' >&2
        cleanup_incomplete=true
    elif [[ "$test_nat_gateways_clean" != true ]]; then
        test_external_ip_attachments_clean=false
    fi
    if [[ "$test_nat_gateways_clean" == true && "$test_external_ip_attachments_clean" == true ]] \
        && ! remove_external_ip_client_routes; then
        routes_clean=false
        printf 'ERROR: preserving test ExternalIPs and network resources because upstream route cleanup is incomplete\n' >&2
        cleanup_incomplete=true
    fi
    if [[ "$test_nat_gateways_clean" == true && "$test_external_ip_attachments_clean" == true \
        && "$routes_clean" == true ]] \
        && ! cleanup_created_external_ips; then
        test_external_ips_clean=false
        printf 'ERROR: preserving test ExternalIPs and provider state because cleanup is incomplete\n' >&2
        cleanup_incomplete=true
    fi
    if [[ "$test_nat_gateways_clean" == true && "$test_external_ip_attachments_clean" == true \
        && "$routes_clean" == true \
        && "$test_external_ips_clean" == true ]] && ! cleanup_created_external_ip_pool; then
        test_external_ip_pool_clean=false
        printf 'ERROR: preserving the ExternalIPPool and provider access because pool cleanup is incomplete\n' >&2
        cleanup_incomplete=true
    elif [[ "$test_nat_gateways_clean" != true || "$test_external_ip_attachments_clean" != true || "$routes_clean" != true \
        || "$test_external_ips_clean" != true ]]; then
        test_external_ip_pool_clean=false
    fi
    if [[ "${CLEANUP_MODE:-false}" == true ]] \
        && declare -p CLEANUP_PENDING_POOL_IDS >/dev/null 2>&1 \
        && ((${#CLEANUP_PENDING_POOL_IDS[@]} > 0)); then
        test_external_ip_pool_clean=false
        printf 'ERROR: preserving provider access; test ExternalIPPool cleanup is incomplete\n' >&2
        cleanup_incomplete=true
    fi
    if [[ "$test_nat_gateways_clean" == true && "$test_external_ips_clean" == true \
        && "$test_external_ip_pool_clean" == true \
        && "$test_external_ip_attachments_clean" == true && "$routes_clean" == true \
        && "${#CREATED_BARE_METAL_INSTANCE_IDS[@]}" -gt 0 ]] \
        && ! cleanup_created_bare_metal_instances; then
        test_baremetal_instances_clean=false
        printf 'ERROR: preserving target Subnet and VirtualNetwork because legacy BMaaS cleanup is incomplete\n' >&2
        cleanup_incomplete=true
    fi
    if [[ "$test_nat_gateways_clean" == true && "$test_external_ip_attachments_clean" == true \
        && "$routes_clean" == true \
        && "$test_external_ips_clean" == true && "$test_external_ip_pool_clean" == true \
        && "$test_baremetal_instances_clean" == true ]] && ! cleanup_created_subnets; then
        test_subnets_clean=false
        printf 'ERROR: test-owned Subnet cleanup is incomplete; preserving its provider and DHCP state for recovery\n' >&2
        cleanup_incomplete=true
    elif [[ "$test_nat_gateways_clean" != true || "$test_external_ip_attachments_clean" != true || "$routes_clean" != true \
        || "$test_external_ips_clean" != true || "$test_external_ip_pool_clean" != true \
        || "$test_baremetal_instances_clean" != true ]]; then
        test_subnets_clean=false
    fi
    if [[ "$test_nat_gateways_clean" == true && "$test_subnets_clean" == true \
        && -n "$CLI_BIN" && -x "$CLI_BIN" \
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
    if [[ "${CLEANUP_MODE:-false}" == true \
        && "${CLEANUP_DISCOVERY_COMPLETE:-false}" == true \
        && "$test_nat_gateways_clean" == true \
        && "$test_external_ip_attachments_clean" == true && "$routes_clean" == true \
        && "$test_external_ips_clean" == true \
        && "$test_external_ip_pool_clean" == true && "$test_baremetal_instances_clean" == true \
        && "$test_subnets_clean" == true \
        && "$test_vns_clean" == true ]]; then
        if ! verify_suite_cleanup_provider_state; then
            test_vns_clean=false
            cleanup_incomplete=true
        fi
    fi
    if [[ "$test_nat_gateways_clean" == true \
        && "$test_external_ip_attachments_clean" == true && "$routes_clean" == true \
        && "$test_external_ips_clean" == true && "$test_external_ip_pool_clean" == true \
        && "$test_baremetal_instances_clean" == true \
        && "$test_subnets_clean" == true \
        && "$test_vns_clean" == true ]]; then
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
        if [[ "$SUITE_USES_NAT_GATEWAY" == true ]] && ! restore_nat_gateway_uplink; then
            printf 'ERROR: could not restore the original NATGateway AAP uplink setting\n' >&2
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
        if [[ "$test_nat_gateways_clean" != true ]]; then
            printf 'ERROR: preserving clients, endpoints, routes, ExternalIPs, Subnets, VirtualNetworks, and AAP configuration because NATGateway cleanup is incomplete\n' >&2
        elif [[ "$test_external_ip_pool_clean" != true ]]; then
            printf 'ERROR: preserving AAP inventory and provider access because ExternalIPPool cleanup is incomplete\n' >&2
        elif [[ "$test_external_ip_attachments_clean" != true ]]; then
            printf 'ERROR: preserving EIPs, DHCP target, Subnet, VirtualNetwork, provider state, and route because ExternalIPAttachment cleanup is incomplete\n' >&2
        elif [[ "$routes_clean" != true ]]; then
            printf 'ERROR: preserving ExternalIPs and network resources because upstream route cleanup is incomplete\n' >&2
        elif [[ "$test_external_ips_clean" != true ]]; then
            printf 'ERROR: preserving test ExternalIPs and provider access because ExternalIP cleanup is incomplete\n' >&2
        elif [[ "$test_baremetal_instances_clean" != true ]]; then
            printf 'ERROR: preserving Subnet and VirtualNetwork because BMaaS cleanup is incomplete\n' >&2
        elif [[ "$test_subnets_clean" != true ]]; then
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

write_run_evidence() {
    local status="$1" cleanup_status="$2" switch
    local switch_rows
    [[ "$RUN_DIR_CREATED" == true && -n "$VLAN_E2E_RUN_DIR" ]] || return 0
    switch_rows="$VLAN_E2E_RUN_DIR/switches.jsonl"
    : >"$switch_rows"
    if [[ -n "$SWITCH_MANIFEST_FILE" && -f "$SWITCH_MANIFEST_FILE" ]]; then
        while IFS= read -r switch; do
            [[ -n "$switch" ]] || continue
            local container_state guest_version candidate_diff bridge_state
            container_state="$(docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}/{{.Image}}' "$switch" 2>/dev/null || printf 'missing')"
            guest_version="unavailable"
            candidate_diff="unavailable"
            bridge_state="unavailable"
            if [[ -f "$CUMULUS_SSH_CONFIG_FILE" ]]; then
                guest_version="$(switch_admin_user_exec "$switch" sh -c '. /etc/os-release; printf "%s" "$VERSION_ID"' 2>/dev/null || printf 'unavailable')"
                candidate_diff="$(switch_nvue_diff admin "$switch" 2>/dev/null || printf 'unavailable')"
                bridge_state="$(switch_admin_user_exec "$switch" /usr/sbin/bridge -j vlan show 2>/dev/null || printf 'unavailable')"
            fi
            jq -nc --arg name "$switch" --arg container "$container_state" \
                --arg guest_version "$guest_version" --arg candidate_diff "$candidate_diff" \
                --arg bridge_state "$bridge_state" \
                '{name:$name,container:$container,guest_version:$guest_version,candidate_diff:$candidate_diff,bridge_state:$bridge_state}' \
                >>"$switch_rows" || return 1
        done < <(jq -r '.switches[].name' "$SWITCH_MANIFEST_FILE")
    fi
    python3 - "$VLAN_E2E_RUN_DIR/summary.json" "$RUN_STARTED_AT_UTC" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$status" "$cleanup_status" "$CURRENT_STAGE" \
        "$VLAN_E2E_SUITE" "$CURRENT_BRANCH" \
        "$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown')" \
        "$(git -C "$REPO_ROOT" log -1 --format=%H -- osac-aap osac-operator proto 2>/dev/null || true)" \
        "$AAP_PROJECT_GIT_BRANCH" "$AAP_PROJECT_EXPECTED_REVISION" \
        "$CUMULUS_VERSION" "$CUMULUS_VX_IMAGE" "$CUMULUS_IMAGE_ID" \
        "$CUMULUS_IMAGE_PROVENANCE_FILE" "$switch_rows" <<'PY'
import json
import pathlib
import sys

(
    output_path,
    started_at,
    finished_at,
    exit_status,
    cleanup_status,
    failed_stage,
    suite,
    branch,
    repository_sha,
    runtime_sha,
    aap_project_branch,
    aap_project_revision,
    cumulus_version,
    cumulus_image,
    cumulus_image_id,
    provenance_path,
    switches_path,
) = sys.argv[1:]
provenance = None
if provenance_path and pathlib.Path(provenance_path).is_file():
    provenance = json.loads(pathlib.Path(provenance_path).read_text())
switches = []
switches_file = pathlib.Path(switches_path)
if switches_file.is_file():
    switches = [json.loads(line) for line in switches_file.read_text().splitlines() if line]
summary = {
    "started_at_utc": started_at,
    "finished_at_utc": finished_at,
    "exit_status": int(exit_status),
    "cleanup_status": int(cleanup_status),
    "failed_stage": failed_stage,
    "suite": suite,
    "repository": {"branch": branch, "sha": repository_sha, "runtime_sha": runtime_sha},
    "aap_project": {"branch": aap_project_branch, "expected_revision": aap_project_revision},
    "cumulus": {
        "expected_version": cumulus_version,
        "image": cumulus_image,
        "image_id": cumulus_image_id,
        "provenance": provenance,
    },
    "switches": switches,
}
path = pathlib.Path(output_path)
path.write_text(json.dumps(summary, indent=2) + "\n")
path.chmod(0o600)
switches_file.unlink(missing_ok=True)
PY
}

on_exit() {
    local status=$?
    local cleanup_status=0
    local provider_cleanup_allowed=true
    local stale_dir
    trap - EXIT
    set +e
    if [[ "$SUITE_USES_SUBNET_DHCP" == true && "$VLAN_E2E_DEBUG" == true ]] \
        && ! export_dhcp_debug_artifacts; then
        printf 'ERROR: could not preserve the requested DHCP debug artifacts\n' >&2
        cleanup_status=1
    fi
    if [[ "${CLEANUP_MODE:-false}" != true && "$SUITE_USES_NAT_GATEWAY" == true ]]; then
        if ! cleanup_created_nat_gateways; then
            printf 'ERROR: NATGateway cleanup is incomplete; preserving clients, ExternalIPs, pool, Subnets, VirtualNetworks, endpoint, routes, and AAP configuration\n' >&2
            cleanup_status=1
            provider_cleanup_allowed=false
            PRESERVE_E2E_RECOVERY_ARTIFACTS=true
        elif ! cleanup_nat_gateway_endpoint; then
            printf 'ERROR: NATGateway endpoint cleanup is incomplete; preserving dependent resources and AAP configuration\n' >&2
            cleanup_status=1
            provider_cleanup_allowed=false
            PRESERVE_E2E_RECOVERY_ARTIFACTS=true
        fi
    fi
    if [[ "${CLEANUP_MODE:-false}" != true \
        && "$SUITE_USES_EXTERNAL_IP_ATTACHMENT" == true \
        && ("${#CREATED_EXTERNAL_IP_ATTACHMENT_IDS[@]}" -gt 0 \
            || "${#CREATED_SYNTHETIC_EXTERNAL_IP_ATTACHMENT_IDS[@]}" -gt 0) ]]; then
        if ! cleanup_created_external_ip_attachments; then
            printf 'ERROR: ExternalIPAttachment detach is incomplete; preserving the DHCP client and dependent resources\n' >&2
            cleanup_status=1
            provider_cleanup_allowed=false
            PRESERVE_E2E_RECOVERY_ARTIFACTS=true
        fi
    fi
    if [[ "${CLEANUP_MODE:-false}" != true && "$SUITE_USES_SUBNET_DHCP" == true ]] \
        && "$provider_cleanup_allowed" == true \
        && declare -F cleanup_dhcp_clients_and_attachments >/dev/null; then
        if ! cleanup_dhcp_clients_and_attachments; then
            printf 'ERROR: simulated BMI, DHCP client, or client-link cleanup is incomplete\n' >&2
            cleanup_status=1
            provider_cleanup_allowed=false
            PRESERVE_E2E_RECOVERY_ARTIFACTS=true
        fi
    fi
    if [[ "$PREEXISTING_PROVIDER_CLEANUP_PENDING" == true ]]; then
        printf 'ERROR: preserving AAP inventory and provider access while existing provider deletions remain pending\n' >&2
        cleanup_status=1
        provider_cleanup_allowed=false
        PRESERVE_E2E_RECOVERY_ARTIFACTS=true
    fi
    if [[ "${CLEANUP_MODE:-false}" == true \
        && "${CLEANUP_DISCOVERY_COMPLETE:-false}" != true ]]; then
        printf 'ERROR: cleanup inventory was not completed; preserving lab resources and provider access\n' >&2
        cleanup_status=1
        provider_cleanup_allowed=false
        PRESERVE_E2E_RECOVERY_ARTIFACTS=true
    fi
    if [[ "${CLEANUP_MODE:-false}" == true \
        && "${CLEANUP_CLIENTS_COMPLETE:-true}" != true ]]; then
        printf 'ERROR: preserving Step 5 network resources because client offboarding is incomplete\n' >&2
        cleanup_status=1
        provider_cleanup_allowed=false
        PRESERVE_E2E_RECOVERY_ARTIFACTS=true
    fi
    if [[ "$provider_cleanup_allowed" == true ]]; then
        cleanup_created_virtual_networks "$status"
        if [[ "$?" != 0 ]]; then
            cleanup_status=1
        fi
    else
        printf 'ERROR: preserving test resources, AAP inventory, and provider access because provider cleanup is incomplete\n' >&2
    fi
    if [[ "$AAP_SUBNET_READER_SETUP_ATTEMPTED" == true ]]; then
        if [[ "$provider_cleanup_allowed" != true || "$PRESERVE_E2E_RECOVERY_ARTIFACTS" == true ]]; then
            printf 'ERROR: preserving the AAP Subnet credential until provider cleanup completes\n' >&2
        elif ! cleanup_aap_subnet_reader; then
            printf 'ERROR: AAP Subnet credential cleanup is incomplete; preserving recovery state\n' >&2
            cleanup_status=1
            PRESERVE_E2E_RECOVERY_ARTIFACTS=true
        fi
    fi
    if [[ "$status" == 0 && "$cleanup_status" != 0 ]]; then
        status=1
    fi
    if ! write_run_evidence "$status" "$cleanup_status"; then
        printf 'ERROR: could not write the requested E2E evidence to %s\n' "$VLAN_E2E_RUN_DIR" >&2
        cleanup_status=1
        status=1
    fi
    if [[ "$PRESERVE_E2E_RECOVERY_ARTIFACTS" == true ]]; then
        printf 'Recovery artifacts and provider credentials are preserved in %s\n' "$TEMP_DIR" >&2
    else
        for stale_dir in "${STALE_RECOVERY_DIRS[@]}"; do
            [[ -z "$stale_dir" || "$stale_dir" == "$TEMP_DIR" ]] || rm -rf -- "$stale_dir"
        done
        if [[ "$GENERATED_CLI_CONFIG" == true && -n "$CLI_CONFIG_DIR" ]]; then
            rm -rf -- "$CLI_CONFIG_DIR"
        fi
        if [[ "$GENERATED_CLI_BIN" == true && -n "$CLI_BIN" ]]; then
            rm -f -- "$CLI_BIN"
        fi
        [[ -z "$CLI_CA_FILE" ]] || rm -f -- "$CLI_CA_FILE"
        if [[ "$CUMULUS_SSH_CONFIG_CREATED_BY_RUN" == true ]]; then
            rm -f -- "$CUMULUS_SSH_CONFIG_FILE"
            CUMULUS_SSH_CONFIG_CREATED_BY_RUN=false
        fi
        [[ -z "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
    fi
    set -e
    exit "$status"
}
trap on_exit EXIT

if [[ "$CLEANUP_MODE" == true ]]; then
    for tool in virsh oc helm go jq python3 awk sed grep sort cut sleep ssh-keygen base64 grpcurl docker sudo ssh stat tr; do
        require_cmd "$tool"
    done
else
    for tool in cluster-tool virsh oc helm go jq python3 awk sed grep sort cut sleep make ssh-keygen base64 grpcurl docker sudo ssh uv stat tr; do
        require_cmd "$tool"
    done
    require_cmd "$CONTAINER_TOOL"
    require_cmd "$CONTAINERLAB"
fi
[[ -f "$CONTAINERLAB_TOPOLOGY" ]] || die "Containerlab topology is missing: $CONTAINERLAB_TOPOLOGY"
[[ -f "$CONTAINERLAB_INVENTORY" ]] || die "Containerlab inventory is missing: $CONTAINERLAB_INVENTORY"
[[ -f "$CONTAINERLAB_CONFIGURE_PLAYBOOK" ]] || die "Containerlab trunk playbook is missing: $CONTAINERLAB_CONFIGURE_PLAYBOOK"
[[ -f "$AAP_JOBS_HELPER" ]] || die "AAP job helper is missing: $AAP_JOBS_HELPER"
if [[ "$SUITE_USES_SUBNET_DHCP" == true && "$VLAN_E2E_DEBUG" == true ]]; then
    require_cmd tcpdump
    require_cmd nsenter
fi
[[ -n "$CURRENT_BRANCH" ]] || die "Could not determine the current Git branch"
[[ "$OSAC_INSTALL_MODE" == auto || "$OSAC_INSTALL_MODE" == install || "$OSAC_INSTALL_MODE" == upgrade ]] \
    || die "OSAC_INSTALL_MODE must be auto, install, or upgrade"
[[ "$VLAN_E2E_DEBUG" == true || "$VLAN_E2E_DEBUG" == false ]] \
    || die "VLAN_E2E_DEBUG must be true or false"
if [[ "$CLEANUP_MODE" != true ]]; then
    [[ "$CUMULUS_VERSION" =~ ^5\.[0-9]+\.[0-9]+$ ]] \
        || die "CUMULUS_VERSION must be an exact Cumulus release such as 5.16.5"
    [[ "$CUMULUS_VX_IMAGE" =~ ^[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+$ ]] \
        || die "CUMULUS_VX_IMAGE must be an explicit image reference with a version tag"
    [[ "${CUMULUS_VX_IMAGE##*:}" == "$CUMULUS_VERSION" ]] \
        || die "CUMULUS_VX_IMAGE tag must match CUMULUS_VERSION"
fi
[[ "$CUMULUS_LAB_ADMIN_KEY" =~ ^/[A-Za-z0-9_./-]+$ ]] \
    || die "CUMULUS_LAB_ADMIN_KEY must be an absolute path with safe path characters"
if [[ "$CLEANUP_MODE" != true && -n "$CUMULUS_IMAGE_PROVENANCE_FILE" ]]; then
    [[ "$CUMULUS_IMAGE_PROVENANCE_FILE" =~ ^/[A-Za-z0-9_./-]+$ && -f "$CUMULUS_IMAGE_PROVENANCE_FILE" ]] \
        || die "CUMULUS_IMAGE_PROVENANCE_FILE must name an existing file with a safe absolute path"
fi
if [[ "$CLEANUP_MODE" != true && -n "$VLAN_E2E_RUN_DIR" ]]; then
    [[ "$VLAN_E2E_RUN_DIR" =~ ^/[A-Za-z0-9_./-]+$ ]] \
        || die "VLAN_E2E_RUN_DIR must be an absolute path with safe path characters"
    [[ ! -e "$VLAN_E2E_RUN_DIR" && ! -L "$VLAN_E2E_RUN_DIR" ]] \
        || die "VLAN_E2E_RUN_DIR already exists; refusing to overwrite it"
fi
if [[ "$CLEANUP_MODE" != true ]]; then
    if ! CUMULUS_IMAGE_ID="$(docker image inspect --format '{{.Id}}' "$CUMULUS_VX_IMAGE")"; then
        die "CUMULUS_VX_IMAGE is not available in the local Docker image store: $CUMULUS_VX_IMAGE"
    fi
    CUMULUS_IMAGE_VENDOR="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.vendor"}}' "$CUMULUS_VX_IMAGE")" \
        || die "Could not inspect the Boxen vendor label for CUMULUS_VX_IMAGE"
    [[ "$CUMULUS_IMAGE_VENDOR" == Boxen ]] \
        || die "CUMULUS_VX_IMAGE is not a Boxen-packaged image"
fi
if [[ "$CLEANUP_MODE" != true && "$SUITE_USES_SUBNET_DHCP" == true \
    && "$VLAN_E2E_DEBUG" == true && -n "$VLAN_E2E_ARTIFACT_DIR" ]]; then
    [[ "$VLAN_E2E_ARTIFACT_DIR" =~ ^/[A-Za-z0-9_./-]+$ ]] \
        || die "VLAN_E2E_ARTIFACT_DIR must be an absolute path with safe path characters"
fi
if [[ "$CLEANUP_MODE" != true ]]; then
    [[ "$AAP_IMAGE" =~ ^quay\.io/[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+$ ]] \
        || die "AAP_IMAGE must be a quay.io image reference with a tag"
    [[ "$OPERATOR_IMAGE" =~ ^quay\.io/[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+$ ]] \
        || die "OPERATOR_IMAGE must be a quay.io image reference with a tag"
    [[ "$FULFILLMENT_IMAGE" =~ ^quay\.io/[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+$ ]] \
        || die "FULFILLMENT_IMAGE must be a quay.io image reference with a tag"
    [[ "$REUSE_PREBUILT_OSAC_IMAGES" == auto || "$REUSE_PREBUILT_OSAC_IMAGES" == true \
        || "$REUSE_PREBUILT_OSAC_IMAGES" == false ]] \
        || die "REUSE_PREBUILT_OSAC_IMAGES must be auto, true, or false"
fi
[[ "$AAP_PROJECT_GIT_URI" =~ ^https://[A-Za-z0-9._/-]+$ ]] \
    || die "AAP_PROJECT_GIT_URI must be an HTTPS Git URL"
[[ "$AAP_PROJECT_GIT_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] \
    || die "AAP_PROJECT_GIT_BRANCH contains unsupported characters"
[[ "$AAP_PROJECT_GIT_BRANCH" == "$RUNTIME_SOURCE_BRANCH" ]] \
    || die "AAP_PROJECT_GIT_BRANCH must match the selected source branch ${RUNTIME_SOURCE_BRANCH}"
[[ "$AAP_PROJECT_EXPECTED_REVISION" =~ ^[0-9a-f]{40}$ ]] \
    || die "AAP_PROJECT_EXPECTED_REVISION must be a full lowercase Git commit SHA"
[[ "$AAP_PROJECT_EXPECTED_REVISION" == "$RUNTIME_SOURCE_COMMIT" ]] \
    || die "AAP_PROJECT_EXPECTED_REVISION must match selected source commit ${RUNTIME_SOURCE_COMMIT}"
if [[ "$CLEANUP_MODE" != true ]]; then
    for runtime_image in "$AAP_IMAGE" "$OPERATOR_IMAGE" "$FULFILLMENT_IMAGE"; do
        [[ "${runtime_image##*:}" == *-"$IMAGE_SOURCE_SHORT" ]] \
            || die "Runtime image tag must end in the selected source revision ${IMAGE_SOURCE_SHORT}: ${runtime_image}"
    done
fi
[[ "$AAP_JOB_TIMEOUT" =~ ^[0-9]+$ ]] \
    && ((10#$AAP_JOB_TIMEOUT >= 60 && 10#$AAP_JOB_TIMEOUT <= 7200)) \
    || die "AAP_JOB_TIMEOUT must be between 60 and 7200 seconds"
[[ "$AGENTLESS_NET_STATE_FILE" =~ ^/[A-Za-z0-9_./-]+$ ]] \
    || die "AGENTLESS_NET_STATE_FILE must be an absolute path with safe path characters"
[[ "$OSAC_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || die "OSAC_NAMESPACE must be a DNS label"
if [[ "$SUITE_USES_VN" == true ]]; then
    [[ "$VIRTUAL_NETWORK_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
        || die "VIRTUAL_NETWORK_NAME must be a DNS label"
fi
if [[ "$SUITE_USES_CLI" == true ]]; then
    [[ "$OSAC_TENANT" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
        || die "OSAC_TENANT must be a DNS label"
fi
if [[ "$SUITE_USES_EXTERNAL_IP" == true ]]; then
    [[ "$EXTERNAL_IP_ONE_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ \
        && "$EXTERNAL_IP_TWO_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ \
        && "$EXTERNAL_IP_ONE_NAME" != "$EXTERNAL_IP_TWO_NAME" ]] \
        || die "ExternalIP test names must be distinct DNS labels"
fi
if [[ "$VLAN_E2E_SUITE" == full ]]; then
    [[ "$PEER_VIRTUAL_NETWORK_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
        || die "PEER_VIRTUAL_NETWORK_NAME must be a DNS label"
fi
if [[ "$SUITE_USES_SUBNET_DHCP" == true ]]; then
    [[ "$AAP_PREFIX" == osac && "$AAP_PROJECT_NAME" == osac ]] \
        || die "BMaaS attachment E2E requires the osac AAP project and job-template prefix"
    [[ "$SUBNET_ONE_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
        || die "SUBNET_ONE_NAME must be a DNS label"
    [[ "$SUBNET_TWO_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
        || die "SUBNET_TWO_NAME must be a DNS label"
    [[ "$SUBNET_THREE_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
        || die "SUBNET_THREE_NAME must be a DNS label"
    [[ "$SUBNET_ONE_NAME" != "$SUBNET_TWO_NAME" && "$SUBNET_ONE_NAME" != "$SUBNET_THREE_NAME" \
        && "$SUBNET_TWO_NAME" != "$SUBNET_THREE_NAME" ]] \
        || die "All test Subnet names must be different"
fi
if [[ "$SUITE_USES_VN" == true ]]; then
    SUBNET_CIDR_ARGUMENTS=("" "" "")
    if [[ "$SUITE_USES_SUBNET_DHCP" == true ]]; then
        SUBNET_CIDR_ARGUMENTS=(
            "$SUBNET_ONE_IPV4_CIDR"
            "$SUBNET_TWO_IPV4_CIDR"
            "$SUBNET_THREE_IPV4_CIDR"
        )
    fi
    python3 - "$VIRTUAL_NETWORK_IPV4_CIDR" "${SUBNET_CIDR_ARGUMENTS[@]}" <<'PY'
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
fi
assert_provider_schema_v1 || die "The AgentlessNet provider schema must remain V1 until OSAC-5528 is complete"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/osac-5530-vlan-e2e.XXXXXX")"
BASELINE_STATE_FILE="${TEMP_DIR}/baseline-state.json"
CURRENT_STATE_FILE="${TEMP_DIR}/current-state.json"
SWITCH_MANIFEST_FILE="${TEMP_DIR}/switches.json"
if [[ -n "$VLAN_E2E_RUN_DIR" && "$CLEANUP_MODE" != true ]]; then
    mkdir -m 0700 -- "$VLAN_E2E_RUN_DIR"
    RUN_DIR_CREATED=true
fi
if [[ "$CLEANUP_MODE" != true && "$SUITE_USES_SUBNET_DHCP" == true \
    && "$VLAN_E2E_DEBUG" == true ]]; then
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
if [[ "$SUITE_USES_CLI" == true ]]; then
    if [[ -z "$CLI_BIN" ]]; then
        CLI_BIN="$(mktemp "${TMPDIR:-/tmp}/osac-5530-cli.XXXXXX")"
        GENERATED_CLI_BIN=true
    fi
    if [[ -z "$CLI_CONFIG_DIR" ]]; then
        CLI_CONFIG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/osac-5530-cli-config.XXXXXX")"
        GENERATED_CLI_CONFIG=true
    fi
    if [[ "$GENERATED_CLI_CONFIG" == true ]]; then
        # The disposable CLI config uses its file-backed secret store. Avoid a
        # headless runner's D-Bus keyring probe hanging CLI startup.
        export DBUS_SESSION_BUS_ADDRESS="unix:path=/nonexistent"
    fi
fi

# Normal E2E runs are idempotent across these deployment stages. Cleanup is a
# separate command that skips all deployment and fabric initialization work.
if [[ "$CLEANUP_MODE" != true ]]; then
# Step 1: deploy or reuse the SNO with cluster-tool.
step "STEP 1 OF 5: Deploying or reusing the SNO cluster"
if ! cluster-tool servers 2>/dev/null | awk 'NR > 2 && $1 == "local" { found = 1 } END { exit !found }'; then
    die "cluster-tool is not configured for the local development host"
fi

if VM_STATE="$(virsh domstate "$MGMT_VM_NAME" 2>/dev/null)"; then
    case "$VM_STATE" in
        running)
            info "Reusing the running SNO VM ${MGMT_VM_NAME}"
            ;;
        paused)
            info "Resuming the paused SNO VM ${MGMT_VM_NAME}"
            virsh resume "$MGMT_VM_NAME" >/dev/null \
                || die "Could not resume the paused SNO VM ${MGMT_VM_NAME}"
            ;;
        "shut off")
            info "Starting the existing SNO VM ${MGMT_VM_NAME}"
            virsh start "$MGMT_VM_NAME" >/dev/null \
                || die "Could not start the existing SNO VM ${MGMT_VM_NAME}"
            ;;
        *) die "SNO VM ${MGMT_VM_NAME} is in unsupported state ${VM_STATE}" ;;
    esac
elif virsh dominfo "$MGMT_VM_NAME" >/dev/null 2>&1; then
    die "SNO VM ${MGMT_VM_NAME} exists but its state could not be read"
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

# Step 2: prepare source-matched images and deploy or reuse OSAC.
# ExternalIP capacity behavior and migration 125 ship in the Fulfillment image.
step "STEP 2 OF 5: Deploying OSAC with source-pinned images"
REUSE_IMAGES=false
if [[ "$REUSE_PREBUILT_OSAC_IMAGES" == true ]]; then
    REUSE_IMAGES=true
elif [[ "$REUSE_PREBUILT_OSAC_IMAGES" == auto ]] \
    && "$CONTAINER_TOOL" image inspect "$AAP_IMAGE" >/dev/null 2>&1 \
    && "$CONTAINER_TOOL" image inspect "$OPERATOR_IMAGE" >/dev/null 2>&1 \
    && "$CONTAINER_TOOL" image inspect "$FULFILLMENT_IMAGE" >/dev/null 2>&1; then
    REUSE_IMAGES=true
elif [[ "$REUSE_PREBUILT_OSAC_IMAGES" == auto ]] \
    && "$CONTAINER_TOOL" pull "$AAP_IMAGE" >/dev/null 2>&1 \
    && "$CONTAINER_TOOL" pull "$OPERATOR_IMAGE" >/dev/null 2>&1 \
    && "$CONTAINER_TOOL" pull "$FULFILLMENT_IMAGE" >/dev/null 2>&1; then
    REUSE_IMAGES=true
fi
if [[ "$REUSE_IMAGES" == true ]]; then
    info "Reusing prebuilt images for source revision ${IMAGE_SOURCE_SHORT}: ${AAP_IMAGE}, ${OPERATOR_IMAGE}, ${FULFILLMENT_IMAGE}."
    "$CONTAINER_TOOL" image inspect "$AAP_IMAGE" >/dev/null 2>&1 \
        || die "Prebuilt AAP image is not available locally: ${AAP_IMAGE}"
    "$CONTAINER_TOOL" image inspect "$OPERATOR_IMAGE" >/dev/null 2>&1 \
        || die "Prebuilt OSAC operator image is not available locally: ${OPERATOR_IMAGE}"
    "$CONTAINER_TOOL" image inspect "$FULFILLMENT_IMAGE" >/dev/null 2>&1 \
        || die "Prebuilt Fulfillment image is not available locally: ${FULFILLMENT_IMAGE}"
else
    info "Building and pushing images for source revision ${IMAGE_SOURCE_SHORT}."
    if ! "$CONTAINER_TOOL" login --get-login quay.io >/dev/null 2>&1; then
        die "No saved ${CONTAINER_TOOL} login for quay.io; authenticate before building the custom images"
    fi
    AAP_BUILD_LOG="${TEMP_DIR}/aap-image-build.log"
    OPERATOR_BUILD_LOG="${TEMP_DIR}/operator-image-build.log"
    FULFILLMENT_BUILD_LOG="${TEMP_DIR}/fulfillment-image-build.log"
    info "Building AAP, OSAC operator, and Fulfillment images in parallel..."
    make -C "$AAP_DIR" execution-environment-build \
        "IMG=${AAP_IMAGE}" "CONTAINER_TOOL=${CONTAINER_TOOL}" >"$AAP_BUILD_LOG" 2>&1 &
    AAP_BUILD_PID=$!
    make -C "${REPO_ROOT}/osac-operator" image-build \
        "IMG=${OPERATOR_IMAGE}" "CONTAINER_TOOL=${CONTAINER_TOOL}" >"$OPERATOR_BUILD_LOG" 2>&1 &
    OPERATOR_BUILD_PID=$!
    make -C "${REPO_ROOT}/fulfillment-service" image-build \
        "IMG=${FULFILLMENT_IMAGE}" "CONTAINER_TOOL=${CONTAINER_TOOL}" >"$FULFILLMENT_BUILD_LOG" 2>&1 &
    FULFILLMENT_BUILD_PID=$!
    AAP_BUILD_STATUS=0
    OPERATOR_BUILD_STATUS=0
    FULFILLMENT_BUILD_STATUS=0
    wait "$AAP_BUILD_PID" || AAP_BUILD_STATUS=$?
    wait "$OPERATOR_BUILD_PID" || OPERATOR_BUILD_STATUS=$?
    wait "$FULFILLMENT_BUILD_PID" || FULFILLMENT_BUILD_STATUS=$?
    if [[ "$AAP_BUILD_STATUS" != 0 || "$OPERATOR_BUILD_STATUS" != 0 || "$FULFILLMENT_BUILD_STATUS" != 0 ]]; then
        if [[ "$AAP_BUILD_STATUS" != 0 ]]; then
            tail -n 80 "$AAP_BUILD_LOG" >&2
        fi
        if [[ "$OPERATOR_BUILD_STATUS" != 0 ]]; then
            tail -n 80 "$OPERATOR_BUILD_LOG" >&2
        fi
        if [[ "$FULFILLMENT_BUILD_STATUS" != 0 ]]; then
            tail -n 80 "$FULFILLMENT_BUILD_LOG" >&2
        fi
        die "Image build failed (AAP status ${AAP_BUILD_STATUS}, operator status ${OPERATOR_BUILD_STATUS}, Fulfillment status ${FULFILLMENT_BUILD_STATUS})"
    fi
    info "All three images built successfully; pushing them to Quay..."
    make -C "$AAP_DIR" execution-environment-push \
        "IMG=${AAP_IMAGE}" "CONTAINER_TOOL=${CONTAINER_TOOL}"
    make -C "${REPO_ROOT}/osac-operator" image-push \
        "IMG=${OPERATOR_IMAGE}" "CONTAINER_TOOL=${CONTAINER_TOOL}"
    make -C "${REPO_ROOT}/fulfillment-service" image-push \
        "IMG=${FULFILLMENT_IMAGE}" "CONTAINER_TOOL=${CONTAINER_TOOL}"
fi

# Phase 2 continues with the idempotent OSAC install or upgrade.
OVERLAY_FILE="${INSTALLER_DIR}/values/agentless-net-stub.yaml"
[[ -f "$OVERLAY_FILE" ]] || die "AgentlessNet VirtualNetwork/Subnet overlay is missing: ${OVERLAY_FILE}"
CLUSTER_DOMAIN="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
[[ -n "$CLUSTER_DOMAIN" ]] || die "Could not read the OpenShift cluster domain"
OIDC_ISSUER_URL="https://keycloak-keycloak.${CLUSTER_DOMAIN}/realms/osac"
# This smoke invokes the networking AAP jobs directly; catalog template
# publication is unrelated and its hook needs a Kubernetes token mount.
EXTRA_HELM_ARGS="-f ${OVERLAY_FILE} --set-string aap.configAsCode.eeImage=${AAP_IMAGE} --set-string aap.configAsCode.projectGitUri=${AAP_PROJECT_GIT_URI} --set-string aap.configAsCode.projectGitBranch=${AAP_PROJECT_GIT_BRANCH} --set-string operator.image.repository=${OPERATOR_IMAGE_REPOSITORY} --set-string operator.image.tag=${OPERATOR_IMAGE_TAG} --set-string service.images.service.repository=${FULFILLMENT_IMAGE_REPOSITORY} --set-string service.images.service.tag=${FULFILLMENT_IMAGE_TAG} --set service.eventPublisher.enabled=true --set aap.instanceGroups.publishTemplates.enabled=false"
EXISTING_OSAC_RELEASE="$(helm list -n "$OSAC_NAMESPACE" --filter '^osac$' --short)"
PREVIOUS_DEPLOYMENT_SETTINGS="{}"
EXPECTED_DEPLOYMENT_SETTINGS="$(jq -ncS \
    --arg ee "$AAP_IMAGE" \
    --arg project_uri "$AAP_PROJECT_GIT_URI" \
    --arg project_branch "$AAP_PROJECT_GIT_BRANCH" \
    --arg operator_repository "$OPERATOR_IMAGE_REPOSITORY" \
    --arg operator_tag "$OPERATOR_IMAGE_TAG" \
    --arg fulfillment_repository "$FULFILLMENT_IMAGE_REPOSITORY" \
    --arg fulfillment_tag "$FULFILLMENT_IMAGE_TAG" \
    '{aap:{eeImage:$ee,projectGitUri:$project_uri,projectGitBranch:$project_branch},
      operator:{image:{repository:$operator_repository,tag:$operator_tag}},
      fulfillment:{image:{repository:$fulfillment_repository,tag:$fulfillment_tag}},
      service:{eventPublisherEnabled:true},
      networking:{fabricManager:"agentless_net",k8sManager:"",
        networkClassTitle:"AgentlessNet VirtualNetwork and Subnet baseline"}}')"
OSAC_DEPLOYMENT_NEEDED=true
if [[ -n "$EXISTING_OSAC_RELEASE" ]]; then
    PREVIOUS_DEPLOYMENT_SETTINGS="$(deployment_settings)" \
        || die "Could not capture the existing AAP and networking values"
    if [[ "$OSAC_INSTALL_MODE" == auto ]] \
        && [[ "$(jq -cS . <<<"$PREVIOUS_DEPLOYMENT_SETTINGS")" == "$EXPECTED_DEPLOYMENT_SETTINGS" ]]; then
        OSAC_DEPLOYMENT_NEEDED=false
        info "The existing OSAC release already matches the implementation-branch deployment settings."
    else
        prepare_upgrade_values
    fi
fi
if [[ "$OSAC_INSTALL_MODE" == install && -n "$EXISTING_OSAC_RELEASE" ]]; then
    die "OSAC_INSTALL_MODE=install but an OSAC release already exists; use auto or upgrade"
fi
if [[ "$OSAC_INSTALL_MODE" == upgrade && -z "$EXISTING_OSAC_RELEASE" ]]; then
    die "OSAC_INSTALL_MODE=upgrade but no OSAC release exists"
fi

if [[ "$OSAC_DEPLOYMENT_NEEDED" == false ]]; then
    info "Skipping the OSAC Helm operation because the desired release is already deployed."
elif [[ -n "$EXISTING_OSAC_RELEASE" || "$OSAC_INSTALL_MODE" == upgrade ]]; then
    info "Refreshing local umbrella-chart dependencies from this checkout..."
    helm dependency build "${INSTALLER_DIR}/charts/osac"
    info "Upgrading the existing OSAC release with the custom AAP and operator images..."
    # Skip the existing config-as-code hook on upgrades: AAP rejects the
    # pre-existing cluster-fulfillment-ig Secret volume. Phase 4 syncs the
    # project and EE directly through the Controller API.
    helm upgrade osac "${INSTALLER_DIR}/charts/osac" \
        --namespace "$OSAC_NAMESPACE" \
        --reset-values \
        --values "$UPGRADE_VALUES_FILE" \
        --set aap.bootstrap.enabled=false \
        --set service.eventPublisher.enabled=true \
        --set aap.instanceGroups.publishTemplates.enabled=false \
        --set-string "aap.configAsCode.eeImage=${AAP_IMAGE}" \
        --set-string "aap.configAsCode.projectGitUri=${AAP_PROJECT_GIT_URI}" \
        --set-string "aap.configAsCode.projectGitBranch=${AAP_PROJECT_GIT_BRANCH}" \
        --set-string "operator.image.repository=${OPERATOR_IMAGE_REPOSITORY}" \
        --set-string "operator.image.tag=${OPERATOR_IMAGE_TAG}" \
        --set-string "service.images.service.repository=${FULFILLMENT_IMAGE_REPOSITORY}" \
        --set-string "service.images.service.tag=${FULFILLMENT_IMAGE_TAG}" \
        --set-string "ui.auth.oidcIssuerURL=${OIDC_ISSUER_URL}" \
        --values "$OVERLAY_FILE" \
        --wait --timeout 40m
else
    info "Refreshing local umbrella-chart dependencies from this checkout..."
    helm dependency build "${INSTALLER_DIR}/charts/osac"
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

# Step 3: deploy or reuse the Containerlab topology.
step "STEP 3 OF 5: Deploying or reusing the Containerlab fabric"
(
    cd "$AAP_DIR"
    uv sync --locked --group development
)
resolve_mgmt_network
write_provider_inventory
ensure_cumulus_admin_identity
prepare_cumulus_startup_config
write_cumulus_ssh_config
ensure_containerlab_net_node
assert_containerlab_switch_images
wait_for_cumulus_guests

# Step 4: prepare provider access and initialize the declared fabric trunks.
step "STEP 4 OF 5: Initializing provider and fabric"
AAP_API_CA_FILE="$TEMP_DIR/aap-api-ca.pem"
prepare_aap_ca_bundle
sync_aap_project_revision
configure_aap_execution_environment
prepare_containerlab_net_node
write_cumulus_ssh_config
prepare_containerlab_switches
configure_containerlab_fabric
assert_provider_key_survived "trunk initialization"
if [[ "$SUITE_USES_SUBNET_DHCP" == true ]]; then
    prepare_containerlab_dhcp_supervisor
fi
prepare_aap_networking_instance_group
wait_for_existing_provider_deletions \
    || die "Existing AgentlessNet resources are still deleting; provider access is preserved for recovery"
if [[ "$SUITE_USES_SUBNET_DHCP" == true ]]; then
    configure_aap_subnet_reader \
        || die "Could not configure AAP Kubernetes authentication for BMaaS attachment jobs"
fi

if [[ "$SUITE_USES_CLI" == true ]]; then
    # The CLI is a local binary, not another container image.
    info "Preparing a temporary CLI CA bundle and building the CLI from this checkout..."
    CLI_CA_FILE="$AAP_API_CA_FILE"
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
fi
fi

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

run_agentless_net_aap_job() {
    local job_suffix="$1" extra_vars_file="$2" result_file="$3"
    local route token template job_id
    template="${AAP_PREFIX}-${job_suffix}"
    if ! route="$(oc get route osac-aap -n "$OSAC_NAMESPACE" -o jsonpath='{.spec.host}')"; then
        printf 'ERROR: could not read the AAP Controller route before launching %s\n' "$template" >&2
        return 1
    fi
    if ! token="$(oc exec deployment/osac-operator -n "$OSAC_NAMESPACE" -- \
        sh -c 'printf %s "$OSAC_AAP_TOKEN"' 2>/dev/null)"; then
        printf 'ERROR: could not obtain the AAP API token before launching %s\n' "$template" >&2
        return 1
    fi
    if [[ -z "$route" || -z "$token" ]]; then
        printf 'ERROR: AAP Controller route or API token is unavailable for %s\n' "$template" >&2
        unset token
        return 1
    fi
    if ! AAP_API_ROUTE="https://${route}" AAP_API_TOKEN="$token" \
        AAP_API_CA_FILE="$AAP_API_CA_FILE" \
        python3 "$AAP_JOBS_HELPER" launch \
            --job-template "$template" \
            --extra-vars "$extra_vars_file" \
            --output "$result_file" \
            --project-name "$AAP_PROJECT_NAME" \
            --project-revision "$RUNTIME_SOURCE_COMMIT" \
            --ee-name "$AAP_EXECUTION_ENVIRONMENT_NAME" \
            --ee-image "$AAP_IMAGE" \
            --timeout "$AAP_JOB_TIMEOUT"; then
        unset token
        return 1
    fi
    unset token
    if ! job_id="$(jq -er '.job_id' "$result_file")"; then
        printf 'ERROR: AAP helper returned invalid job metadata for %s\n' "$template" >&2
        return 1
    fi
    info "AAP ${template} completed as job ${job_id} at source revision ${RUNTIME_SOURCE_COMMIT}."
}

write_client_bmi_extra_vars() {
    local client="$1" subnet_ref="$2" output_file="$3" offboard="$4"
    local uid="${CLIENT_BMI_UID[$client]:-}" mac="${CLIENT_PRESERVED_MAC[$client]:-}"
    [[ -n "$mac" ]] || mac="$(<"$TEMP_DIR/client-${client}.mac")"
    [[ "$uid" =~ ^[0-9a-f-]{36}$ ]] || {
        printf 'ERROR: DHCP client %s has no valid simulated BMI UID\n' "$client" >&2
        return 1
    }
    [[ "$subnet_ref" =~ ^[0-9a-f-]{36}$ ]] || {
        printf 'ERROR: DHCP client %s has no valid Fulfillment Subnet UUID\n' "$client" >&2
        return 1
    }
    [[ "$mac" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] || {
        printf 'ERROR: DHCP client %s has no valid simulated BMI NIC MAC\n' "$client" >&2
        return 1
    }
    python3 - "$client" "$OSAC_NAMESPACE" "$OSAC_TENANT" "$subnet_ref" \
        "$uid" "$mac" "$offboard" "$output_file" <<'PY'
import datetime
import json
import os
import pathlib
import sys

client, namespace, tenant, subnet_ref, uid, mac, offboard, output_path = sys.argv[1:]
host_id = f"osac-e2e-{client}"
resource = {
    "apiVersion": "osac.openshift.io/v1alpha1",
    "kind": "BareMetalInstance",
    "metadata": {
        "name": host_id,
        "namespace": namespace,
        "uid": uid,
        "annotations": {
            "osac.openshift.io/tenant": tenant,
            "osac.openshift.io/owner-reference": "vlan-e2e-run",
            "osac.openshift.io/implementation-strategy": "agentless_net",
        },
    },
    "spec": {
        "externalHostID": host_id,
        "networkAttachments": [{
            "subnetRef": subnet_ref,
            "interface": "eth0",
            "primary": True,
        }],
    },
}
if offboard == "true":
    resource["metadata"]["deletionTimestamp"] = (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )
payload = {"osac_job_vars": {"resource": resource}}
if offboard == "query":
    payload["osac_job_vars"]["network_attachment_macs"] = {
        subnet_ref: mac.lower(),
    }
path = pathlib.Path(output_path)
path.write_text(json.dumps(payload, separators=(",", ":")) + "\n")
path.chmod(0o600)
PY
}

attach_client_to_subnet() {
    local client="$1" subnet_ref="$2" extra_vars result_file
    if [[ "${CLIENT_ATTACHMENT_ACTIVE[$client]:-false}" == true ]]; then
        [[ "${CLIENT_ATTACHMENT_SUBNET[$client]:-}" == "$subnet_ref" ]] \
            || die "DHCP client ${client} is already attached to a different Subnet"
        info "DHCP client ${client} already has the requested simulated BMI attachment."
        return 0
    fi
    CLIENT_BMI_UID["$client"]="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    CLIENT_ATTACHMENT_SUBNET["$client"]="$subnet_ref"
    CLIENT_ATTACHMENT_PENDING["$client"]=true
    extra_vars="$TEMP_DIR/${client}-move-network-attachment.json"
    AAP_JOB_RESULT_SEQUENCE=$((AAP_JOB_RESULT_SEQUENCE + 1))
    result_file="$TEMP_DIR/${client}-move-network-attachment-result-${AAP_JOB_RESULT_SEQUENCE}.json"
    write_client_bmi_extra_vars "$client" "$subnet_ref" "$extra_vars" false
    run_agentless_net_aap_job move-network-attachment "$extra_vars" "$result_file" \
        || die "AAP could not attach DHCP client ${client} to Subnet ${subnet_ref}"
    CLIENT_ATTACHMENT_ACTIVE["$client"]=true
    CLIENT_ATTACHMENT_PENDING["$client"]=false
    CLIENT_PRESERVED_MAC["$client"]="$(<"$TEMP_DIR/client-${client}.mac")"
}

discover_client_dhcp_lease() {
    local client="$1" subnet_ref mac extra_vars result_file lease_ip expected_mac
    subnet_ref="${CLIENT_ATTACHMENT_SUBNET[$client]:-}"
    [[ -n "$subnet_ref" && "${CLIENT_ATTACHMENT_ACTIVE[$client]:-false}" == true ]] \
        || die "DHCP client ${client} has no active simulated BMI attachment to query"
    mac="$(<"$TEMP_DIR/client-${client}.mac")"
    expected_mac="$(tr '[:upper:]' '[:lower:]' <<<"$mac" | tr -d '\r\n')"
    lease_ip="$(jq -er '.address' "$TEMP_DIR/client-${client}.lease.json")" \
        || die "DHCP client ${client} has no IPv4 lease to query"
    extra_vars="$TEMP_DIR/${client}-query-dhcp-lease.json"
    AAP_JOB_RESULT_SEQUENCE=$((AAP_JOB_RESULT_SEQUENCE + 1))
    result_file="$TEMP_DIR/${client}-query-dhcp-lease-result-${AAP_JOB_RESULT_SEQUENCE}.json"
    write_client_bmi_extra_vars "$client" "$subnet_ref" "$extra_vars" query
    run_agentless_net_aap_job query-dhcp-lease "$extra_vars" "$result_file" \
        || die "AAP could not discover the DHCP lease for client ${client}"
    jq -e --arg subnet "$subnet_ref" --arg ip "$lease_ip" \
        --arg mac "$expected_mac" '
      (.artifacts.leases | type == "array" and length == 1)
      and .artifacts.leases[0].subnet_ref == $subnet
      and .artifacts.leases[0].interface == "eth0"
      and ((.artifacts.leases[0].mac_address | ascii_downcase) == $mac)
      and .artifacts.leases[0].ip_address == $ip
    ' "$result_file" >/dev/null \
        || die "AAP DHCP lease result for ${client} did not match its Subnet, eth0, MAC, and client lease"
    info "AAP verified client ${client} lease ${lease_ip} on Subnet ${subnet_ref} for MAC ${expected_mac}."
}

offboard_client_from_subnet() {
    local client="$1" subnet_ref extra_vars result_file
    if [[ "${CLIENT_ATTACHMENT_PENDING[$client]:-false}" != true \
        && "${CLIENT_ATTACHMENT_ACTIVE[$client]:-false}" != true ]]; then
        return 0
    fi
    subnet_ref="${CLIENT_ATTACHMENT_SUBNET[$client]:-}"
    [[ -n "$subnet_ref" ]] || {
        printf 'ERROR: cannot offboard client %s without its original Subnet reference\n' "$client" >&2
        return 1
    }
    extra_vars="$TEMP_DIR/${client}-offboard-network-attachment.json"
    AAP_JOB_RESULT_SEQUENCE=$((AAP_JOB_RESULT_SEQUENCE + 1))
    result_file="$TEMP_DIR/${client}-offboard-network-attachment-result-${AAP_JOB_RESULT_SEQUENCE}.json"
    write_client_bmi_extra_vars "$client" "$subnet_ref" "$extra_vars" true \
        || return 1
    run_agentless_net_aap_job move-network-attachment "$extra_vars" "$result_file" \
        || return 1
    CLIENT_ATTACHMENT_ACTIVE["$client"]=false
    CLIENT_ATTACHMENT_PENDING["$client"]=false
    unset "CLIENT_ATTACHMENT_SUBNET[$client]" "CLIENT_BMI_UID[$client]"
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


def _load_runtime_vlan_parser() -> Callable[[str, str, str | None], set[int]]:
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
        excluded.update(
            parser(
                switch.get("bridge_vlan_output"),
                switch.get("reserved_vlan_output"),
                switch.get("switchd_reserved_vlan_output"),
            )
        )
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

nvue_interface_config() {
    local switch="$1" port="$2"
    switch_exec "$switch" nv config show --output json \
        | jq -c --arg port "$port" '
            (if type == "array" then . else [.] end)
            | ([.[] | .set? // empty] | last) as $set
            | ($set // {}).interface[$port] // null'
}

create_dhcp_client_container() {
    local client="$1" container macvlan pid mac preserved_mac="${CLIENT_PRESERVED_MAC[$1]:-}"
    client_link "$client"
    container="$(client_container "$client")"
    macvlan="$(client_macvlan_name "$client")"
    docker run -d --name "$container" \
        --label io.osac.e2e.runner=vlan-e2e \
        --label "io.osac.e2e.client=${client}" \
        --label "io.osac.e2e.prefix=${DHCP_CLIENT_PREFIX}" \
        --label "io.osac.e2e.run-dir=${TEMP_DIR}" \
        --network none \
        --cap-add NET_ADMIN --cap-add NET_RAW "$CLIENT_IMAGE" sleep 3600 >/dev/null
    DHCP_CLIENT_CONTAINERS+=("$container")
    sudo ip link add link "$CLIENT_HOST_PARENT" name "$macvlan" type macvlan mode bridge
    DHCP_CLIENT_HOST_LINKS+=("$macvlan")
    if [[ -n "$preserved_mac" ]]; then
        [[ "$preserved_mac" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] \
            || die "Saved DHCP client ${client} MAC is invalid"
        sudo ip link set dev "$macvlan" address "$preserved_mac"
    fi
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
    if [[ -n "$preserved_mac" && "${mac,,}" != "${preserved_mac,,}" ]]; then
        die "Recreated DHCP client ${client} changed its preserved MAC address"
    fi
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
    CLIENT_PRESERVED_MAC["$client"]="$(<"$TEMP_DIR/client-${client}.mac")"
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
        switch_exec "$CLIENT_SWITCH" ip -o link show dev "$CLIENT_SWITCH_PORT" || true
        switch_exec "$CLIENT_SWITCH" bridge -j vlan show dev "$CLIENT_SWITCH_PORT" || true
        switch_exec "$CLIENT_SWITCH" bridge fdb show dev "$CLIENT_SWITCH_PORT" || true
        while IFS=$'\t' read -r switch trunk; do
            [[ -n "$switch" && -n "$trunk" ]] || continue
            printf 'switch=%s trunk=%s\n' "$switch" "$trunk"
            switch_exec "$switch" bridge -j vlan show dev "$trunk" || true
            switch_exec "$switch" bridge fdb show dev "$trunk" || true
            nvue_interface_config "$switch" "$trunk" || true
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
        switch_exec "${CONTAINERLAB_PREFIX}-leaf-2" sh -c '
            for port in swp3 swp1; do
                printf "leaf-2 %s\n" "$port"
                bridge -d link show dev "$port"
            done
        ' || true
        switch_exec "${CONTAINERLAB_PREFIX}-leaf-1" sh -c '
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
    switch_exec "$CLIENT_SWITCH" ip -o link show dev "$CLIENT_SWITCH_PORT" >&2 || true
    switch_exec "$CLIENT_SWITCH" bridge -j vlan show dev "$CLIENT_SWITCH_PORT" >&2 || true
    switch_exec "$CLIENT_SWITCH" bridge fdb show dev "$CLIENT_SWITCH_PORT" >&2 || true
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
    if docker inspect "$container" >/dev/null 2>&1; then
        docker exec "$container" ip address flush dev eth0 || true
        docker exec "$container" ip route flush dev eth0 || true
    fi
    offboard_client_from_subnet "$client" \
        || die "Could not offboard DHCP client ${client} through osac-move-network-attachment"
}

cleanup_dhcp_clients_and_attachments() {
    local client container link pid failed=false
    for client in a1 a2 b1; do
        if [[ "${CLIENT_ATTACHMENT_PENDING[$client]:-false}" == true \
            || "${CLIENT_ATTACHMENT_ACTIVE[$client]:-false}" == true ]]; then
            stop_dhcp_client "$client"
            container="$(client_container "$client")"
            if docker inspect "$container" >/dev/null 2>&1; then
                docker exec "$container" ip address flush dev eth0 >/dev/null 2>&1 || true
                docker exec "$container" ip route flush dev eth0 >/dev/null 2>&1 || true
            fi
            if ! offboard_client_from_subnet "$client"; then
                printf 'ERROR: could not offboard simulated BMI for client %s; retaining its client link and provider resources\n' \
                    "$client" >&2
                failed=true
            fi
        fi
    done
    [[ "$failed" == false ]] || return 1
    for container in "${DHCP_CLIENT_CONTAINERS[@]}"; do
        if ! docker inspect "$container" >/dev/null 2>&1; then
            docker ps >/dev/null 2>&1 || failed=true
            continue
        fi
        if pid="$(dhcp_client_pid "$container" 2>/dev/null)"; then
            docker exec "$container" kill -TERM "$pid" >/dev/null 2>&1 || true
        fi
        if ! docker rm -f "$container" >/dev/null 2>&1; then
            docker inspect "$container" >/dev/null 2>&1 || docker ps >/dev/null 2>&1 || failed=true
        fi
    done
    for link in "${DHCP_CLIENT_HOST_LINKS[@]}"; do
        if sudo ip link show dev "$link" >/dev/null 2>&1; then
            sudo ip link delete dev "$link" || failed=true
        fi
    done
    if [[ "$failed" == false ]]; then
        DHCP_CLIENT_CONTAINERS=()
        DHCP_CLIENT_HOST_LINKS=()
    fi
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
    print(json.dumps({
        "schema_version": 0,
        "virtual_networks": [],
        "subnets": [],
        "external_ip_pools": [],
        "external_ips": [],
        "external_ip_attachments": [],
        "nat_gateways": [],
    }, sort_keys=True))
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
expected_external_ip_pool_columns = {
    "uid", "fulfillment_id", "tenant_id", "ip_family", "ipv4_cidr",
}
expected_external_ip_columns = {
    "uid", "fulfillment_id", "tenant_id", "pool_uid", "address",
}
expected_attachment_columns = {
    "uid", "fulfillment_id", "tenant_id", "external_ip_uid",
    "virtual_network_uid", "subnet_uid", "external_address", "phase", "payload",
}
expected_nat_gateway_columns = {
    "uid", "fulfillment_id", "tenant_id", "external_ip_uid",
    "virtual_network_uid", "external_address", "phase", "payload",
}
connection = None
try:
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=60)
    connection.execute("BEGIN")
    tables = {
        row[0]
        for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")
    }
    version = connection.execute("PRAGMA user_version").fetchone()[0]
    legacy_tables = {"virtual_networks", "subnets", "external_ip_pools", "external_ips"}
    attachment_tables = legacy_tables | {"attachments"}
    current_tables = attachment_tables | {"nat_gateways"}
    if version != 1 or tables not in (legacy_tables, attachment_tables, current_tables):
        raise SystemExit("AgentlessNet SQLite state is incompatible with schema v1; preserving it")

    virtual_network_columns = {
        row[1]
        for row in connection.execute("PRAGMA table_info(virtual_networks)")
    }
    subnet_columns = {
        row[1]
        for row in connection.execute("PRAGMA table_info(subnets)")
    }
    external_ip_pool_columns = {
        row[1]
        for row in connection.execute("PRAGMA table_info(external_ip_pools)")
    }
    external_ip_columns = {
        row[1]
        for row in connection.execute("PRAGMA table_info(external_ips)")
    }
    attachment_columns = set()
    if "attachments" in tables:
        attachment_columns = {
            row[1]
            for row in connection.execute("PRAGMA table_info(attachments)")
        }
    nat_gateway_columns = set()
    if "nat_gateways" in tables:
        nat_gateway_columns = {
            row[1]
            for row in connection.execute("PRAGMA table_info(nat_gateways)")
        }
    if (
        virtual_network_columns != expected_virtual_network_columns
        or subnet_columns != expected_subnet_columns
        or external_ip_pool_columns != expected_external_ip_pool_columns
        or external_ip_columns != expected_external_ip_columns
        or ("attachments" in tables and attachment_columns != expected_attachment_columns)
        or ("nat_gateways" in tables and nat_gateway_columns != expected_nat_gateway_columns)
    ):
        raise SystemExit("AgentlessNet SQLite table definitions are incompatible with schema v1; preserving it")

    subnet_entries = [
        json.loads(row[0])
        for row in connection.execute("SELECT payload FROM subnets ORDER BY uid")
    ]
    entries = [
        json.loads(row[0])
        for row in connection.execute("SELECT payload FROM virtual_networks ORDER BY uid")
    ]
    external_ip_pool_entries = [
        {
            "uid": row[0],
            "fulfillment_id": row[1],
            "tenant_id": row[2],
            "ip_family": row[3],
            "ipv4_cidr": row[4],
        }
        for row in connection.execute(
            """SELECT uid, fulfillment_id, tenant_id, ip_family, ipv4_cidr
               FROM external_ip_pools ORDER BY uid"""
        )
    ]
    external_ip_entries = [
        {
            "uid": row[0],
            "fulfillment_id": row[1],
            "tenant_id": row[2],
            "pool_uid": row[3],
            "address": row[4],
        }
        for row in connection.execute(
            """SELECT uid, fulfillment_id, tenant_id, pool_uid, address
               FROM external_ips ORDER BY uid"""
        )
    ]
    attachment_entries = [
        {
            "uid": row[0],
            "fulfillment_id": row[1],
            "tenant_id": row[2],
            "external_ip_uid": row[3],
            "virtual_network_uid": row[4],
            "subnet_uid": row[5],
            "external_address": row[6],
            "phase": row[7],
            "payload": json.loads(row[8]),
        }
        for row in connection.execute(
            """SELECT uid, fulfillment_id, tenant_id, external_ip_uid,
                      virtual_network_uid, subnet_uid, external_address, phase, payload
               FROM attachments ORDER BY uid"""
        )
    ] if "attachments" in tables else []
    nat_gateway_entries = [
        {
            "uid": row[0],
            "fulfillment_id": row[1],
            "tenant_id": row[2],
            "external_ip_uid": row[3],
            "virtual_network_uid": row[4],
            "external_address": row[5],
            "phase": row[6],
            "payload": json.loads(row[7]),
        }
        for row in connection.execute(
            """SELECT uid, fulfillment_id, tenant_id, external_ip_uid,
                      virtual_network_uid, external_address, phase, payload
               FROM nat_gateways ORDER BY uid"""
        )
    ] if "nat_gateways" in tables else []
except (OSError, sqlite3.DatabaseError, json.JSONDecodeError) as error:
    raise SystemExit("AgentlessNet SQLite state is unreadable; preserving it") from error
finally:
    if connection is not None:
        connection.close()
print(json.dumps({
    "schema_version": version,
    "virtual_networks": entries,
    "subnets": subnet_entries,
    "external_ip_pools": external_ip_pool_entries,
    "external_ips": external_ip_entries,
    "external_ip_attachments": attachment_entries,
    "nat_gateways": nat_gateway_entries,
}, sort_keys=True))
PY
}

save_current_state() {
    state_snapshot > "$CURRENT_STATE_FILE"
    jq -e '.schema_version == 1
      and (.virtual_networks | type == "array")
      and (.subnets | type == "array")
      and (.external_ip_pools | type == "array")
      and (.external_ips | type == "array")
      and (.external_ip_attachments | type == "array")
      and (.nat_gateways | type == "array")' \
        "$CURRENT_STATE_FILE" >/dev/null \
        || die "AgentlessNet state is not a valid schema-v1 snapshot"
}

assert_baseline_state_unchanged() {
    local collection uid before after
    for collection in virtual_networks subnets external_ip_pools external_ips external_ip_attachments nat_gateways; do
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

get_external_ip_pool_state_entry() {
    local uid="$1" fulfillment_id="$2"
    save_current_state
    jq -ceS --arg uid "$uid" --arg id "$fulfillment_id" '
      [.external_ip_pools[] | select(.uid == $uid and .fulfillment_id == $id)]
      | if length == 1 then .[0] else error("expected exactly one ExternalIPPool state entry") end' \
      "$CURRENT_STATE_FILE"
}

get_nat_gateway_state_entry() {
    local uid="$1" fulfillment_id="$2"
    save_current_state
    jq -ceS --arg uid "$uid" --arg id "$fulfillment_id" '
      [.nat_gateways[] | select(.uid == $uid and .fulfillment_id == $id)]
      | if length == 1 then .[0] else error("expected exactly one NATGateway provider state entry") end' \
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
        switch_json="$(switch_exec "$switch" bridge -j vlan show)" \
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
    local switch bridge_state reserved_state switchd_reserved_state rows_file
    rows_file="$TEMP_DIR/switch-vlan-snapshot.jsonl"
    SWITCH_VLAN_SNAPSHOT_FILE="$TEMP_DIR/switch-vlan-snapshot.json"
    : >"$rows_file"
    while IFS= read -r switch; do
        [[ -n "$switch" ]] || continue
        bridge_state="$(switch_exec "$switch" bridge -j vlan show)" \
            || die "Could not read VLAN state from Cumulus switch ${switch}"
        reserved_state="$(switch_exec "$switch" nv show system global reserved vlan --output json)" \
            || die "Could not read reserved VLAN ranges from Cumulus switch ${switch}"
        switchd_reserved_state="$(switch_exec "$switch" awk \
            '/^[[:space:]]*resv_vlan_range[[:space:]]*=/ { print }' \
            /etc/cumulus/switchd.conf)" \
            || die "Could not read switchd reserved VLAN range from Cumulus switch ${switch}"
        jq -nc --arg name "$switch" --arg bridge "$bridge_state" \
            --arg reserved "$reserved_state" --arg switchd_reserved "$switchd_reserved_state" \
            '{name:$name,bridge_vlan_output:$bridge,reserved_vlan_output:$reserved,switchd_reserved_vlan_output:$switchd_reserved}' \
            >>"$rows_file"
    done < <(jq -r '.switches[].name' "$SWITCH_MANIFEST_FILE")
    jq -s . "$rows_file" >"$TEMP_DIR/switch-vlan-snapshot-input.json"
    OSAC_REPO_ROOT="$REPO_ROOT" python3 "$DHCP_CLIENT_HELPER" \
        snapshot-vlans --input "$TEMP_DIR/switch-vlan-snapshot-input.json" \
        --output "$SWITCH_VLAN_SNAPSHOT_FILE" \
        || die "Could not validate the baseline Cumulus VLAN snapshot"
    chmod 0600 "$SWITCH_VLAN_SNAPSHOT_FILE"
    info "Captured switch VLAN memberships and NVUE/switchd reserved ranges."
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

create_external_ip_pool() {
    local request_file="${TEMP_DIR}/external-ip-pool-create.request.json"
    local response_file="${TEMP_DIR}/external-ip-pool-create.response.json"
    local error_file="${TEMP_DIR}/external-ip-pool-create.error.json"
    local list_request="${TEMP_DIR}/external-ip-pool-preflight.request.json"
    local list_response="${TEMP_DIR}/external-ip-pool-preflight.response.json"
    local list_error="${TEMP_DIR}/external-ip-pool-preflight.error.json"
    local existing_count

    resolve_external_ip_pool_cidr
    jq -n --arg name "$EXTERNAL_IP_POOL_NAME" --arg cidr "$EXTERNAL_IP_POOL_CIDR" \
        '{object:{metadata:{name:$name,tenant:"shared"},spec:{cidrs:[$cidr],ipFamily:"IP_FAMILY_IPV4"}}}' \
        >"$request_file" || die "Could not write ExternalIPPool Create request"
    jq -n --arg name "$EXTERNAL_IP_POOL_NAME" \
        '{filter:("this.metadata.name == \"" + $name + "\" && this.metadata.tenant == \"shared\"")}' \
        >"$list_request" || die "Could not write ExternalIPPool preflight List request"
    if ! external_ip_pool_rpc List "$list_request" "$list_response" "$list_error"; then
        cat "$list_error" >&2
        die "Could not check whether the generated ExternalIPPool name is already in use"
    fi
    list_json="$(external_ip_pool_list_items "$list_response")" \
        || die "Private Fulfillment List returned an invalid ExternalIPPool response"
    existing_count="$(jq -er 'length' <<<"$list_json")" \
        || die "Private Fulfillment List returned an invalid ExternalIPPool response"
    [[ "$existing_count" == 0 ]] \
        || die "Generated ExternalIPPool name ${EXTERNAL_IP_POOL_NAME} already exists"

    EXTERNAL_IP_POOL_PENDING_CLEANUP=true
    if ! external_ip_pool_rpc Create "$request_file" "$response_file" "$error_file"; then
        cat "$error_file" >&2
        die "Private Fulfillment could not create ExternalIPPool ${EXTERNAL_IP_POOL_NAME}"
    fi
    if ! EXTERNAL_IP_POOL_ID="$(jq -er --arg name "$EXTERNAL_IP_POOL_NAME" \
        --arg cidr "$EXTERNAL_IP_POOL_CIDR" '
        .object as $pool
        | select($pool.metadata.name == $name
            and $pool.metadata.tenant == "shared"
            and $pool.spec.ipFamily == "IP_FAMILY_IPV4"
            and $pool.spec.cidrs == [$cidr])
        | $pool.id
        | select(type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))' \
        "$response_file")"; then
        printf '%s\n' "$(cat "$response_file")" >&2
        die "Fulfillment Create response did not contain a canonical ExternalIPPool UUID"
    fi

    printf 'ExternalIPPool Fulfillment UUID: %s\n' "$EXTERNAL_IP_POOL_ID"
    wait_for_external_ip_pool_ready "$EXTERNAL_IP_POOL_ID"
    [[ "$EXTERNAL_IP_POOL_K8S_UID" != "$EXTERNAL_IP_POOL_ID" ]] \
        || die "ExternalIPPool Kubernetes UID and Fulfillment UUID unexpectedly match"
    EXTERNAL_IP_POOL_INITIAL_ENTRY="$(get_external_ip_pool_state_entry \
        "$EXTERNAL_IP_POOL_K8S_UID" "$EXTERNAL_IP_POOL_ID")"
    jq -e --arg uid "$EXTERNAL_IP_POOL_K8S_UID" --arg id "$EXTERNAL_IP_POOL_ID" \
        --arg cidr "$EXTERNAL_IP_POOL_CIDR" '
      .uid == $uid
      and .fulfillment_id == $id
      and .tenant_id == "shared"
      and .ip_family == "IPv4"
      and .ipv4_cidr == $cidr' <<<"$EXTERNAL_IP_POOL_INITIAL_ENTRY" >/dev/null \
        || die "Saved AgentlessNet ExternalIPPool identity does not match the CR"
    [[ -n "$EXTERNAL_IP_POOL_CREATE_AAP_JOB_ID" ]] \
        || die "No successful AAP provision job ID was recorded for ExternalIPPool ${EXTERNAL_IP_POOL_ID}"
    info "ExternalIPPool ${EXTERNAL_IP_POOL_ID} is Ready; Kubernetes UID ${EXTERNAL_IP_POOL_K8S_UID}; AAP job ${EXTERNAL_IP_POOL_CREATE_AAP_JOB_ID}"
    assert_baseline_state_unchanged
}

delete_external_ip_pool() {
    local request_file="${TEMP_DIR}/external-ip-pool-delete.request.json"
    local response_file="${TEMP_DIR}/external-ip-pool-delete.response.json"
    local error_file="${TEMP_DIR}/external-ip-pool-delete.error.json"
    local current_entry

    [[ "$EXTERNAL_IP_POOL_PENDING_CLEANUP" == true \
        && -n "$EXTERNAL_IP_POOL_ID" && -n "$EXTERNAL_IP_POOL_K8S_UID" ]] \
        || die "ExternalIPPool test identity is incomplete before deletion"
    current_entry="$(get_external_ip_pool_state_entry \
        "$EXTERNAL_IP_POOL_K8S_UID" "$EXTERNAL_IP_POOL_ID")"
    [[ "$current_entry" == "$EXTERNAL_IP_POOL_INITIAL_ENTRY" ]] \
        || die "ExternalIPPool provider state changed during the VLAN/Subnet test"

    jq -n --arg id "$EXTERNAL_IP_POOL_ID" '{id:$id}' >"$request_file" \
        || die "Could not write ExternalIPPool Delete request"
    if ! external_ip_pool_rpc Delete "$request_file" "$response_file" "$error_file"; then
        if ! external_ip_pool_rpc_error_is_not_found "$error_file" "$response_file"; then
            cat "$error_file" >&2
            die "Private Fulfillment could not delete ExternalIPPool ${EXTERNAL_IP_POOL_ID}"
        fi
    fi
    wait_for_external_ip_pool_removed "$EXTERNAL_IP_POOL_ID" "$EXTERNAL_IP_POOL_K8S_UID" \
        || die "ExternalIPPool ${EXTERNAL_IP_POOL_ID} was not completely removed"
    [[ -z "$EXTERNAL_IP_POOL_DELETE_AAP_JOB_ID" ]] \
        || info "Observed ExternalIPPool AAP delete job ID: ${EXTERNAL_IP_POOL_DELETE_AAP_JOB_ID}"
    EXTERNAL_IP_POOL_PENDING_CLEANUP=false
    assert_baseline_state_unchanged
    info "ExternalIPPool ${EXTERNAL_IP_POOL_ID} is absent from Fulfillment, Kubernetes, and AgentlessNet SQLite"
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

resolve_nat_gateway_subnet_cidrs() {
    local parent_cidr="$1" first_transit="$2" peer_transit="$3" override_one="" override_two="" selected
    [[ "$SUBNET_ONE_IPV4_CIDR_EXPLICIT" == true ]] && override_one="$SUBNET_ONE_IPV4_CIDR"
    [[ "$SUBNET_TWO_IPV4_CIDR_EXPLICIT" == true ]] && override_two="$SUBNET_TWO_IPV4_CIDR"
    selected="$(python3 - "$parent_cidr" "$first_transit" "$peer_transit" \
        "$override_one" "$override_two" <<'PY'
import ipaddress
import sys

parent = ipaddress.ip_network(sys.argv[1], strict=True)
transits = [ipaddress.ip_network(value, strict=True) for value in sys.argv[2:4]]
overrides = sys.argv[4:6]
if not isinstance(parent, ipaddress.IPv4Network) or any(
    not isinstance(value, ipaddress.IPv4Network) for value in transits
):
    raise SystemExit("NATGateway VLAN lab requires IPv4 parent and transit networks")
if any(not value.subnet_of(parent) for value in transits):
    raise SystemExit("Both VirtualNetwork transit ranges must be inside the shared test CIDR")

def validate(value: str, label: str):
    network = ipaddress.ip_network(value, strict=True)
    if not isinstance(network, ipaddress.IPv4Network) or network.prefixlen > 30 or str(network) != value:
        raise SystemExit(f"{label} must be a canonical IPv4 subnet of /30 or larger")
    if not network.subnet_of(parent) or any(network.overlaps(transit) for transit in transits):
        raise SystemExit(f"{label} must be inside the parent and outside both transit ranges")
    return network

if overrides[0]:
    first = validate(overrides[0], "SUBNET_ONE_IPV4_CIDR")
else:
    prefix = max(parent.prefixlen + 1, 24)
    if prefix > 30:
        raise SystemExit("VirtualNetwork CIDR is too small for NATGateway DHCP Subnets")
    first = next((candidate for candidate in parent.subnets(new_prefix=prefix)
                  if not any(candidate.overlaps(transit) for transit in transits)), None)
    if first is None:
        raise SystemExit("VirtualNetwork CIDR has no test Subnet outside both transit ranges")

if overrides[1]:
    second = validate(overrides[1], "SUBNET_TWO_IPV4_CIDR")
else:
    second = next((candidate for candidate in parent.subnets(new_prefix=first.prefixlen)
                   if not candidate.overlaps(first)
                   and not any(candidate.overlaps(transit) for transit in transits)), None)
    if second is None:
        raise SystemExit("VirtualNetwork CIDR has no second test Subnet outside transit and the first Subnet")
if first.overlaps(second) or first.network_address + 2 >= first.broadcast_address - 1:
    raise SystemExit("NATGateway test Subnets must be disjoint and the first must support two DHCP clients")
print(first, second)
PY
    )" || die "Could not select NATGateway Subnet CIDRs outside both transit links"
    read -r NAT_GATEWAY_SUBNET_ONE_CIDR NAT_GATEWAY_SUBNET_TWO_CIDR <<<"$selected"
}

create_nat_gateway_subnet() {
    local name="$1" parent_id="$2" cidr="$3" output_file="$4"
    local id cr uid job_id
    create_subnet "$name" "$parent_id" "$cidr" "$output_file" \
        || die "Could not create NATGateway test Subnet ${name}"
    id="$(<"${output_file}.id")"
    cr="$(wait_for_subnet_cr_created "$id" "$parent_id")"
    uid="$(jq -er '.metadata.uid' <<<"$cr")" \
        || die "NATGateway test Subnet ${id} has no Kubernetes UID"
    wait_for_subnet_ready "$id" "$parent_id"
    cr="$(subnet_cr_json "$id" "$parent_id")"
    job_id="$(jq -er '.status.provisioningJobs | map(.jobID // empty) | last' <<<"$cr")" \
        || die "NATGateway test Subnet ${id} has no AAP provision job"
    wait_for_subnet_aap_provision_success "$id" "$parent_id" "$job_id"
    assert_subnet_state "$id" "$parent_id" "$cidr"
    LAST_NAT_GATEWAY_SUBNET_ID="$id"
    LAST_NAT_GATEWAY_SUBNET_UID="$uid"
    LAST_NAT_GATEWAY_SUBNET_CIDR="$cidr"
}

ensure_nat_gateway_dhcp_client() {
    local client="$1" container tracked=false
    container="$(client_container "$client")"
    for tracked in "${DHCP_CLIENT_CONTAINERS[@]}"; do
        [[ "$tracked" == "$container" ]] && return 0
    done
    if docker inspect "$container" >/dev/null 2>&1; then
        die "DHCP client ${container} exists outside this run; recover its prior run before NATGateway testing"
    fi
    docker image inspect "$CLIENT_IMAGE" >/dev/null 2>&1 || docker pull "$CLIENT_IMAGE"
    create_dhcp_client_container "$client"
}

attach_nat_gateway_dhcp_client() {
    local client="$1" subnet_id="$2" subnet_entry="$3"
    ensure_nat_gateway_dhcp_client "$client"
    if [[ "${CLIENT_ATTACHMENT_PENDING[$client]:-false}" == true \
        || "${CLIENT_ATTACHMENT_ACTIVE[$client]:-false}" == true ]]; then
        detach_dhcp_client "$client"
    fi
    attach_client_to_subnet "$client" "$subnet_id"
    start_dhcp_client "$client"
    discover_client_dhcp_lease "$client"
    write_client_lease_expectations "$client=$subnet_entry"
    assert_real_client_leases "$client"
    assert_client_gateway "$client" "$subnet_entry"
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

create_virtual_network() {
    local name="$1" output_file="$2" output id create_status=0
    if "$CLI_BIN" --config "$CLI_CONFIG_DIR" --tenant "$OSAC_TENANT" \
        create virtualnetwork --name "$name" --ipv4-cidr "$VIRTUAL_NETWORK_IPV4_CIDR" \
        > "$output_file" 2>&1; then
        create_status=0
    else
        create_status=$?
    fi
    cat "$output_file" >&2 || return 1
    output="$(cat "$output_file")" || return 1
    id="$(sed -nE 's/.*\(ID: ([0-9a-f-]+)\).*/\1/p' <<<"$output" | tail -n 1)"
    [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || { printf 'Could not parse Fulfillment UUID from CLI create output for %s\n' "$name" >&2; return 1; }
    printf '%s\n' "$id" > "${output_file}.id" || return 1
    return "$create_status"
}
create_primary_virtual_network_for_suite() {
    local output_file="$TEMP_DIR/create-primary-vn.out"
    local create_status=0

    if create_virtual_network "$VIRTUAL_NETWORK_NAME" "$output_file"; then
        create_status=0
    else
        create_status=$?
    fi
    if [[ -s "$output_file.id" ]]; then
        FIRST_FULFILLMENT_ID="$(<"$output_file.id")"
        CREATED_IDS+=("$FIRST_FULFILLMENT_ID")
    fi
    [[ "$create_status" == 0 ]] || die "Could not create test VirtualNetwork $VIRTUAL_NETWORK_NAME"
    [[ "$FIRST_FULFILLMENT_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || die "VirtualNetwork creation did not return a valid Fulfillment UUID"

    wait_for_virtual_network_ready "$FIRST_FULFILLMENT_ID"
    FIRST_CR="$(virtual_network_cr_json "$FIRST_FULFILLMENT_ID")"
    FIRST_CR_NAME="$(jq -er '.metadata.name' <<<"$FIRST_CR")"
    FIRST_K8S_UID="$(jq -er '.metadata.uid' <<<"$FIRST_CR")"
    FIRST_AAP_JOB_ID="$(jq -er '.status.provisioningJobs | map(.jobID // empty) | last' <<<"$FIRST_CR")"
    wait_for_aap_provision_success "$FIRST_FULFILLMENT_ID" "$FIRST_AAP_JOB_ID"
    FIRST_ENTRY="$(get_state_entry "$FIRST_K8S_UID")"
    FIRST_NAMESPACE_NAME="$(jq -r '.namespace_name' <<<"$FIRST_ENTRY")"
    FIRST_HOST_INTERFACE="$(jq -r '.uplink.host_interface' <<<"$FIRST_ENTRY")"
    assert_virtual_network_state "$FIRST_FULFILLMENT_ID" "$VIRTUAL_NETWORK_IPV4_CIDR"
    save_current_state
    assert_baseline_state_unchanged
}

create_external_ip_attachment_test_network_and_client() {
    local entry transit_cidr subnet_output client container response_file response attempt
    prepare_external_ip_test_link \
        || die "Could not prepare the direct ExternalIP client link"
    if [[ -z "${FIRST_FULFILLMENT_ID:-}" ]]; then
        create_primary_virtual_network_for_suite
    fi
    entry="$(get_state_entry "$FIRST_K8S_UID")"
    transit_cidr="$(jq -er '.transit.cidr' <<<"$entry")" \
        || die "Test VirtualNetwork has no saved transit CIDR"
    if [[ -n "$EXTERNAL_IP_ATTACHMENT_SUBNET_CIDR" ]]; then
        SUBNET_ONE_IPV4_CIDR="$EXTERNAL_IP_ATTACHMENT_SUBNET_CIDR"
    fi
    resolve_test_subnet_cidrs "$VIRTUAL_NETWORK_IPV4_CIDR" "$transit_cidr"
    EXTERNAL_IP_ATTACHMENT_SUBNET_CIDR="$SUBNET_ONE_IPV4_CIDR"
    subnet_output="${TEMP_DIR}/create-external-ip-attachment-subnet.out"
    create_subnet "$EXTERNAL_IP_ATTACHMENT_SUBNET_NAME" "$FIRST_FULFILLMENT_ID" \
        "$EXTERNAL_IP_ATTACHMENT_SUBNET_CIDR" "$subnet_output" \
        || die "Could not create ExternalIPAttachment test Subnet"
    EXTERNAL_IP_ATTACHMENT_SUBNET_ID="$(<"${subnet_output}.id")"
    wait_for_subnet_ready "$EXTERNAL_IP_ATTACHMENT_SUBNET_ID" "$FIRST_FULFILLMENT_ID"
    EXTERNAL_IP_ATTACHMENT_SUBNET_CR="$(subnet_cr_json \
        "$EXTERNAL_IP_ATTACHMENT_SUBNET_ID" "$FIRST_FULFILLMENT_ID")"
    EXTERNAL_IP_ATTACHMENT_SUBNET_UID="$(jq -er '.metadata.uid' \
        <<<"$EXTERNAL_IP_ATTACHMENT_SUBNET_CR")" \
        || die "ExternalIPAttachment test Subnet has no Kubernetes UID"
    assert_subnet_state "$EXTERNAL_IP_ATTACHMENT_SUBNET_ID" "$FIRST_FULFILLMENT_ID" \
        "$EXTERNAL_IP_ATTACHMENT_SUBNET_CIDR"

    client="$EXTERNAL_IP_SYNTHETIC_CLIENT"
    if [[ "${CLIENT_ATTACHMENT_PENDING[$client]:-false}" == true \
        || "${CLIENT_ATTACHMENT_ACTIVE[$client]:-false}" == true ]]; then
        detach_dhcp_client "$client"
    fi
    container="$(client_container "$client")"
    if docker inspect "$container" >/dev/null 2>&1; then
        [[ -f "$TEMP_DIR/client-${client}.mac" ]] \
            || die "Synthetic target client ${container} already exists; run --cleanup --external-ip first"
        recreate_dhcp_client_container "$client"
    else
        docker image inspect "$CLIENT_IMAGE" >/dev/null 2>&1 || docker pull "$CLIENT_IMAGE"
        create_dhcp_client_container "$client"
    fi
    attach_client_to_subnet "$client" "$EXTERNAL_IP_ATTACHMENT_SUBNET_ID"
    start_dhcp_client "$client"
    discover_client_dhcp_lease "$client"
    EXTERNAL_IP_SYNTHETIC_TARGET_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    EXTERNAL_IP_SYNTHETIC_TARGET_UID="${CLIENT_BMI_UID[$client]:-}"
    EXTERNAL_IP_SYNTHETIC_TARGET_IP="$(jq -er '.address' \
        "$TEMP_DIR/client-${client}.lease.json")" \
        || die "Synthetic target client ${client} did not receive a Subnet address"
    [[ "$EXTERNAL_IP_SYNTHETIC_TARGET_UID" =~ ^[0-9a-f-]{36}$ ]] \
        || die "Synthetic target client ${client} has no BMI-shaped UID"

    EXTERNAL_IP_RESPONSE_TOKEN="osac-eia-$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
    response_file="${TEMP_DIR}/external-ip-attachment-response"
    printf '%s' "$EXTERNAL_IP_RESPONSE_TOKEN" >"$response_file"
    chmod 0600 "$response_file"
    docker cp "$response_file" "$container:/tmp/osac-eia-response" >/dev/null \
        || die "Could not copy the synthetic ExternalIP response into client ${client}"
    docker exec -d "$container" busybox httpd -f -p "$EXTERNAL_IP_RESPONSE_PORT" -h /tmp \
        || die "Could not start the synthetic ExternalIP response server in client ${client}"
    response=""
    for ((attempt = 1; attempt <= 20; attempt++)); do
        response="$(docker exec "$container" busybox wget -q -O - \
            "http://127.0.0.1:${EXTERNAL_IP_RESPONSE_PORT}/osac-eia-response" 2>/dev/null || true)"
        [[ "$response" == "$EXTERNAL_IP_RESPONSE_TOKEN" ]] && break
        sleep 1
    done
    [[ "$response" == "$EXTERNAL_IP_RESPONSE_TOKEN" ]] \
        || die "Synthetic target client ${client} did not serve the expected HTTP response"
    info "Synthetic DHCP target ${client} is Ready at ${EXTERNAL_IP_SYNTHETIC_TARGET_IP} on Subnet ${EXTERNAL_IP_ATTACHMENT_SUBNET_ID}."
}

cleanup_created_bare_metal_instances() {
    [[ "${#CREATED_BARE_METAL_INSTANCE_IDS[@]}" -gt 0 ]] || return 0
    [[ -n "$CLI_BIN" && -x "$CLI_BIN" && -n "$CLI_CONFIG_DIR" && -d "$CLI_CONFIG_DIR" ]] \
        || return 1
    local id crs count cr name output_file deadline selected index
    for id in "${CREATED_BARE_METAL_INSTANCE_IDS[@]}"; do
        if ! crs="$(baremetal_instance_crs_json "$id")"; then
            printf 'Could not inspect BareMetalInstance %s during cleanup; preserve its Subnet and VirtualNetwork\n' "$id" >&2
            return 1
        fi
        count="$(jq -er '.items | length' <<<"$crs")" || return 1
        if [[ "$count" == 1 ]]; then
            cr="$(baremetal_instance_cr_json "$id")"
            name="$(jq -er '.metadata.name' <<<"$cr")" || return 1
            if [[ -z "$(jq -r '.metadata.deletionTimestamp // ""' <<<"$cr")" ]]; then
                output_file="${TEMP_DIR}/delete-baremetal-instance-${id}.out"
                if ! "$CLI_BIN" --config "$CLI_CONFIG_DIR" --tenant "$OSAC_TENANT" \
                    delete baremetalinstance "$id" >"$output_file" 2>&1; then
                    cat "$output_file" >&2
                    printf 'Could not delete BareMetalInstance %s (%s); preserve its Subnet and VirtualNetwork\n' \
                        "$id" "$name" >&2
                    return 1
                fi
            fi
            deadline=$((SECONDS + 1800))
            while ((SECONDS < deadline)); do
                crs="$(baremetal_instance_crs_json "$id")" || return 1
                count="$(jq -er '.items | length' <<<"$crs")" || return 1
                [[ "$count" == 0 ]] && break
                [[ "$count" == 1 ]] || return 1
                sleep 5
            done
            [[ "$count" == 0 ]] || {
                printf 'Timed out deleting BareMetalInstance %s (%s); preserve its Subnet and VirtualNetwork\n' \
                    "$id" "$name" >&2
                return 1
            }
        elif [[ "$count" != 0 ]]; then
            printf 'Multiple BareMetalInstance CRs exist for test UUID %s; preserving its network resources\n' "$id" >&2
            return 1
        fi
        selected="$(cleanup_cli_list_json baremetalinstance "this.id == \"${id}\"")" \
            || return 1
        [[ "$(jq -er 'length' <<<"$selected")" == 0 ]] || {
            printf 'Fulfillment BareMetalInstance %s remains after Kubernetes cleanup\n' "$id" >&2
            return 1
        }
        for index in "${!CREATED_BARE_METAL_INSTANCE_IDS[@]}"; do
            if [[ "${CREATED_BARE_METAL_INSTANCE_IDS[$index]}" == "$id" ]]; then
                unset 'CREATED_BARE_METAL_INSTANCE_IDS[index]'
            fi
        done
    done
    info "Test BareMetalInstance cleanup completed; its network can now be removed."
}

delete_primary_virtual_network_for_suite() {
    delete_virtual_network_by_id "$FIRST_FULFILLMENT_ID"
    printf 'delete AAP job ID (test VN): %s\n' "$LAST_DELETE_AAP_JOB_ID"
    assert_uid_provider_state_absent \
        "$FIRST_K8S_UID" "$FIRST_NAMESPACE_NAME" "$FIRST_HOST_INTERFACE"
    save_current_state
    assert_baseline_state_unchanged
}

run_subnet_dhcp_checks() {
info "Snapshotting existing switch VLAN memberships and reserved ranges before creating sibling Subnets..."
FIRST_ENTRY="$(get_state_entry "$FIRST_K8S_UID")"
FIRST_TRANSIT_CIDR="$(jq -r '.transit.cidr' <<<"$FIRST_ENTRY")"
resolve_test_subnet_cidrs "$VIRTUAL_NETWORK_IPV4_CIDR" "$FIRST_TRANSIT_CIDR"
printf 'test Subnet CIDRs: %s %s\n' "$SUBNET_ONE_IPV4_CIDR" "$SUBNET_TWO_IPV4_CIDR"
snapshot_switch_vlan_state
assert_provider_key_survived "switch VLAN snapshot"

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
attach_client_to_subnet a1 "$SUBNET_ONE_FULFILLMENT_ID"
attach_client_to_subnet a2 "$SUBNET_ONE_FULFILLMENT_ID"
attach_client_to_subnet b1 "$SUBNET_TWO_FULFILLMENT_ID"
start_dhcp_client a1
start_dhcp_client a2
start_dhcp_client b1
discover_client_dhcp_lease a1
discover_client_dhcp_lease a2
discover_client_dhcp_lease b1
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
for client in a1 a2 b1; do discover_client_dhcp_lease "$client"; done
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
attach_client_to_subnet b1 "$SUBNET_THREE_FULFILLMENT_ID"
start_dhcp_client b1
discover_client_dhcp_lease b1
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
}

create_nat_gateway_virtual_networks() {
    local output_file create_status=0
    if [[ -z "${FIRST_FULFILLMENT_ID:-}" ]]; then
        create_primary_virtual_network_for_suite
    fi
    if [[ -z "${SECOND_FULFILLMENT_ID:-}" ]]; then
        output_file="${TEMP_DIR}/create-natgw-peer-vn.out"
        if create_virtual_network "$PEER_VIRTUAL_NETWORK_NAME" "$output_file"; then
            create_status=0
        else
            create_status=$?
        fi
        if [[ -s "${output_file}.id" ]]; then
            SECOND_FULFILLMENT_ID="$(<"${output_file}.id")"
            CREATED_IDS+=("$SECOND_FULFILLMENT_ID")
        fi
        [[ "$create_status" == 0 && -n "$SECOND_FULFILLMENT_ID" ]] \
            || die "Could not create NATGateway peer VirtualNetwork"
        wait_for_virtual_network_ready "$SECOND_FULFILLMENT_ID"
        SECOND_CR="$(virtual_network_cr_json "$SECOND_FULFILLMENT_ID")"
        SECOND_CR_NAME="$(jq -er '.metadata.name' <<<"$SECOND_CR")"
        SECOND_K8S_UID="$(jq -er '.metadata.uid' <<<"$SECOND_CR")"
        SECOND_AAP_JOB_ID="$(jq -er '.status.provisioningJobs | map(.jobID // empty) | last' <<<"$SECOND_CR")"
        wait_for_aap_provision_success "$SECOND_FULFILLMENT_ID" "$SECOND_AAP_JOB_ID"
        SECOND_ENTRY="$(get_state_entry "$SECOND_K8S_UID")"
        SECOND_NAMESPACE_NAME="$(jq -r '.namespace_name' <<<"$SECOND_ENTRY")"
        SECOND_HOST_INTERFACE="$(jq -r '.uplink.host_interface' <<<"$SECOND_ENTRY")"
        assert_virtual_network_state "$SECOND_FULFILLMENT_ID" "$VIRTUAL_NETWORK_IPV4_CIDR"
    fi
    assert_private_vn_isolation "$FIRST_FULFILLMENT_ID" "$SECOND_FULFILLMENT_ID"
    save_current_state
    assert_baseline_state_unchanged
}

nat_gateway_create_subnets() {
    local first_entry second_entry first_transit second_transit output_file
    first_entry="$(get_state_entry "$FIRST_K8S_UID")"
    second_entry="$(get_state_entry "$SECOND_K8S_UID")"
    first_transit="$(jq -er '.transit.cidr' <<<"$first_entry")" \
        || die "Primary VirtualNetwork has no saved transit CIDR"
    second_transit="$(jq -er '.transit.cidr' <<<"$second_entry")" \
        || die "Peer VirtualNetwork has no saved transit CIDR"
    resolve_nat_gateway_subnet_cidrs "$VIRTUAL_NETWORK_IPV4_CIDR" \
        "$first_transit" "$second_transit"

    output_file="${TEMP_DIR}/create-natgw-subnet-a1.out"
    create_nat_gateway_subnet "$NAT_GATEWAY_SUBNET_ONE_NAME" "$FIRST_FULFILLMENT_ID" \
        "$NAT_GATEWAY_SUBNET_ONE_CIDR" "$output_file"
    NAT_GATEWAY_SUBNET_ONE_ID="$LAST_NAT_GATEWAY_SUBNET_ID"
    NAT_GATEWAY_SUBNET_ONE_UID="$LAST_NAT_GATEWAY_SUBNET_UID"
    NAT_GATEWAY_SUBNET_ONE_ENTRY="$(get_subnet_state_entry "$NAT_GATEWAY_SUBNET_ONE_UID")"
    output_file="${TEMP_DIR}/create-natgw-subnet-peer.out"
    create_nat_gateway_subnet "$NAT_GATEWAY_PEER_SUBNET_NAME" "$SECOND_FULFILLMENT_ID" \
        "$NAT_GATEWAY_SUBNET_ONE_CIDR" "$output_file"
    NAT_GATEWAY_PEER_SUBNET_ID="$LAST_NAT_GATEWAY_SUBNET_ID"
    NAT_GATEWAY_PEER_SUBNET_UID="$LAST_NAT_GATEWAY_SUBNET_UID"
    NAT_GATEWAY_PEER_SUBNET_ENTRY="$(get_subnet_state_entry "$NAT_GATEWAY_PEER_SUBNET_UID")"
    [[ "$NAT_GATEWAY_SUBNET_ONE_UID" != "$NAT_GATEWAY_PEER_SUBNET_UID" ]] \
        || die "Overlapping VirtualNetworks unexpectedly received the same Subnet UID"
}

nat_gateway_expect_create_rejected() {
    local name="$1" virtual_network_id="$2" external_ip_id="$3"
    local output_file="$4" before_state="$5" before_cr_count after_state after_cr_count output id
    before_cr_count="$(oc get natgateways -n "$NETWORKING_NAMESPACE" -o json \
        | jq -er --arg prefix "$NAT_GATEWAY_PREFIX" \
            '[.items[] | select(.metadata.name | startswith($prefix))] | length')" \
        || die "Could not snapshot NATGateway CR count before a negative Create"
    if "$CLI_BIN" --config "$CLI_CONFIG_DIR" --tenant "$OSAC_TENANT" \
        create natgateway --name "$name" --virtual-network "$virtual_network_id" \
        --externalip "$external_ip_id" >"$output_file" 2>&1; then
        output="$(cat "$output_file")"
        id="$(sed -nE 's/.*\(ID: ([0-9a-f-]+)\).*/\1/p' <<<"$output" | tail -n 1)"
        if [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
            CREATED_NAT_GATEWAY_IDS+=("$id")
        fi
        die "Fulfillment unexpectedly accepted invalid NATGateway create ${name}"
    fi
    output="$(cat "$output_file")" || die "Could not read rejected NATGateway Create output"
    printf '%s\n' "$output" >&2
    grep -Eiq 'already|in use|one NAT|unique|FailedPrecondition|InvalidArgument' <<<"$output" \
        || die "NATGateway ${name} failed for an unexpected reason"
    after_cr_count="$(oc get natgateways -n "$NETWORKING_NAMESPACE" -o json \
        | jq -er --arg prefix "$NAT_GATEWAY_PREFIX" \
            '[.items[] | select(.metadata.name | startswith($prefix))] | length')" \
        || die "Could not verify NATGateway CR count after a negative Create"
    [[ "$after_cr_count" == "$before_cr_count" ]] \
        || die "Rejected NATGateway create ${name} left an unexpected Kubernetes CR"
    after_state="$(state_snapshot)" || die "Could not inspect provider state after rejected NATGateway Create"
    jq -e --argjson before "$before_state" '
      .nat_gateways == $before.nat_gateways
      and .external_ips == $before.external_ips' <<<"$after_state" >/dev/null \
        || die "Rejected NATGateway create ${name} changed consumer or ExternalIP provider state"
}

nat_gateway_ensure_client_container() {
    local client="$1" container tracked
    container="$(client_container "$client")"
    for tracked in "${DHCP_CLIENT_CONTAINERS[@]}"; do
        [[ "$tracked" == "$container" ]] && return 0
    done
    if docker inspect "$container" >/dev/null 2>&1; then
        die "DHCP client ${container} exists outside this run; recover its prior run before NATGateway testing"
    fi
    docker image inspect "$CLIENT_IMAGE" >/dev/null 2>&1 || docker pull "$CLIENT_IMAGE"
    create_dhcp_client_container "$client"
}

nat_gateway_attach_client() {
    local client="$1" subnet_id="$2" subnet_entry="$3"
    nat_gateway_ensure_client_container "$client"
    if [[ "${CLIENT_ATTACHMENT_PENDING[$client]:-false}" == true \
        || "${CLIENT_ATTACHMENT_ACTIVE[$client]:-false}" == true ]]; then
        detach_dhcp_client "$client"
    fi
    attach_client_to_subnet "$client" "$subnet_id"
    start_dhcp_client "$client"
    discover_client_dhcp_lease "$client"
    assert_client_gateway "$client" "$subnet_entry"
}

nat_gateway_assert_client_leases() {
    local specs=() client entry subnet_id
    local lease_file="$TEMP_DIR/dnsmasq-nat-gateway-leases.txt"
    local -a args
    for client in "$@"; do
        case "$client" in
            a1) entry="$(get_subnet_state_entry "$NAT_GATEWAY_SUBNET_ONE_UID")" ;;
            a2)
                subnet_id="${CLIENT_ATTACHMENT_SUBNET[$client]:-}"
                if [[ "$subnet_id" == "${NAT_GATEWAY_SUBNET_TWO_ID:-}" ]]; then
                    entry="$(get_subnet_state_entry "$NAT_GATEWAY_SUBNET_TWO_UID")"
                else
                    entry="$(get_subnet_state_entry "$NAT_GATEWAY_SUBNET_ONE_UID")"
                fi
                ;;
            b1) entry="$(get_subnet_state_entry "$NAT_GATEWAY_PEER_SUBNET_UID")" ;;
            *) die "Unknown NATGateway DHCP client ${client}" ;;
        esac
        specs+=("${client}=${entry}")
    done
    write_client_lease_expectations "${specs[@]}"
    args=(assert-client-leases --expected "$CLIENT_EXPECTED_LEASES_FILE" \
        --dnsmasq-leases "$lease_file")
    : >"$lease_file"
    netnode cat "/var/lib/agentless-net/dhcp/${FIRST_K8S_UID}/dnsmasq.leases" \
        >"$lease_file" \
        || die "Could not read the primary NATGateway dnsmasq lease file"
    if [[ -n "${SECOND_K8S_UID:-}" && "$SECOND_K8S_UID" != "$FIRST_K8S_UID" ]]; then
        netnode cat "/var/lib/agentless-net/dhcp/${SECOND_K8S_UID}/dnsmasq.leases" \
            >>"$lease_file" \
            || die "Could not read the peer NATGateway dnsmasq lease file"
    fi
    for client in "$@"; do
        args+=(--lease "$client=$TEMP_DIR/client-${client}.lease.json")
    done
    OSAC_REPO_ROOT="$REPO_ROOT" python3 "$DHCP_CLIENT_HELPER" "${args[@]}"
}

run_nat_gateway_lifecycle() {
    local pool_status total output_file before_state after_state
    local gateway_cr gateway_entry ip_cr peer_entry peer_address peer_eip_state_before_a_delete
    configure_nat_gateway_uplink
    prepare_nat_gateway_endpoint

    if [[ "${EXTERNAL_IP_POOL_PENDING_CLEANUP:-false}" != true ]]; then
        die "NATGateway lifecycle requires a test-owned ExternalIPPool"
    fi
    pool_status="$(external_ip_pool_get_json)" \
        || die "Could not read ExternalIPPool capacity before NATGateway tests"
    total="$(jq -er '.object.status.total | tonumber' <<<"$pool_status")" \
        || die "ExternalIPPool has no total capacity"
    EXTERNAL_IP_POOL_INITIAL_AVAILABLE="$(jq -er '.object.status.available | tonumber' <<<"$pool_status")" \
        || die "ExternalIPPool has no available capacity"
    EXTERNAL_IP_POOL_INITIAL_ALLOCATED="$(jq -er '(.object.status.allocated // 0) | tonumber' <<<"$pool_status")" \
        || die "ExternalIPPool has an invalid allocated counter"
    [[ "$total" -ge 2 && "$EXTERNAL_IP_POOL_INITIAL_ALLOCATED" == 0 ]] \
        || die "NATGateway test pool must have at least two free addresses and no existing allocations"

    output_file="${TEMP_DIR}/create-natgw-external-ip-a.out"
    create_external_ip "$EXTERNAL_IP_ONE_NAME" "$output_file" \
        || die "Could not create NATGateway test ExternalIP A"
    EXTERNAL_IP_ONE_ID="$(<"${output_file}.id")"
    external_ip_pool_wait_for_delta 1
    wait_for_external_ip_ready "$EXTERNAL_IP_ONE_ID"
    EXTERNAL_IP_ONE_UID="$LAST_EXTERNAL_IP_UID"
    EXTERNAL_IP_ONE_ADDRESS="$LAST_EXTERNAL_IP_ADDRESS"
    output_file="${TEMP_DIR}/create-natgw-external-ip-b.out"
    create_external_ip "$EXTERNAL_IP_TWO_NAME" "$output_file" \
        || die "Could not create NATGateway test ExternalIP B"
    EXTERNAL_IP_TWO_ID="$(<"${output_file}.id")"
    external_ip_pool_wait_for_delta 2
    wait_for_external_ip_ready "$EXTERNAL_IP_TWO_ID"
    EXTERNAL_IP_TWO_UID="$LAST_EXTERNAL_IP_UID"
    EXTERNAL_IP_TWO_ADDRESS="$LAST_EXTERNAL_IP_ADDRESS"
    [[ "$EXTERNAL_IP_ONE_ADDRESS" != "$EXTERNAL_IP_TWO_ADDRESS" ]] \
        || die "NATGateway test ExternalIPs received the same address"

    FIRST_ENTRY="$(get_state_entry "$FIRST_K8S_UID")"
    SECOND_ENTRY="$(get_state_entry "$SECOND_K8S_UID")"
    jq -e --arg uid "$FIRST_K8S_UID" --arg peer "$SECOND_K8S_UID" \
        'all(.subnets[]; .virtual_network_uid != $uid and .virtual_network_uid != $peer)' \
        "$CURRENT_STATE_FILE" >/dev/null \
        || die "NATGateway empty-VirtualNetwork case requires both test VirtualNetworks to have no Subnets"
    output_file="${TEMP_DIR}/create-natgw-a.out"
    create_nat_gateway "$NAT_GATEWAY_ONE_NAME" "$FIRST_FULFILLMENT_ID" \
        "$EXTERNAL_IP_ONE_ID" "$output_file" \
        || die "Could not create NATGateway A"
    NAT_GATEWAY_ONE_ID="$(<"${output_file}.id")"
    nat_gateway_wait_for_ready "$NAT_GATEWAY_ONE_ID" "$FIRST_FULFILLMENT_ID" "$EXTERNAL_IP_ONE_ID"
    gateway_cr="$(nat_gateway_cr_json "$NAT_GATEWAY_ONE_ID" "$FIRST_FULFILLMENT_ID" "$EXTERNAL_IP_ONE_ID")"
    NAT_GATEWAY_ONE_UID="$(jq -er '.metadata.uid' <<<"$gateway_cr")"
    NAT_GATEWAY_ONE_INITIAL_STATE="$(nat_gateway_assert_provider_state \
        "$NAT_GATEWAY_ONE_ID" "$NAT_GATEWAY_ONE_UID" "$FIRST_K8S_UID" \
        "$EXTERNAL_IP_ONE_UID" "$EXTERNAL_IP_ONE_ADDRESS")"
    nat_gateway_assert_provider_rules "$NAT_GATEWAY_ONE_ID" "$NAT_GATEWAY_ONE_UID" \
        "$EXTERNAL_IP_ONE_ADDRESS" "$NAT_GATEWAY_ONE_INITIAL_STATE"
    FIRST_ENTRY="$(get_state_entry "$FIRST_K8S_UID")"
    FIRST_NAMESPACE_NAME="$(jq -er '.namespace_name' <<<"$FIRST_ENTRY")"
    nat_gateway_assert_transit_exempt "$FIRST_NAMESPACE_NAME" \
        "$(jq -er '.transit.host_ip' <<<"$FIRST_ENTRY")" \
        "$(jq -er '.transit.namespace_ip' <<<"$FIRST_ENTRY")"

    before_state="$(state_snapshot)" || die "Could not snapshot NATGateway state before negative creates"
    output_file="${TEMP_DIR}/reject-natgw-duplicate-vn.out"
    nat_gateway_expect_create_rejected "${NAT_GATEWAY_PREFIX}-duplicate-vn" \
        "$FIRST_FULFILLMENT_ID" "$EXTERNAL_IP_TWO_ID" "$output_file" "$before_state"
    output_file="${TEMP_DIR}/reject-natgw-duplicate-eip.out"
    nat_gateway_expect_create_rejected "${NAT_GATEWAY_PREFIX}-duplicate-eip" \
        "$SECOND_FULFILLMENT_ID" "$EXTERNAL_IP_ONE_ID" "$output_file" "$before_state"

    output_file="${TEMP_DIR}/create-natgw-peer.out"
    create_nat_gateway "$NAT_GATEWAY_TWO_NAME" "$SECOND_FULFILLMENT_ID" \
        "$EXTERNAL_IP_TWO_ID" "$output_file" \
        || die "Could not create NATGateway peer gateway"
    NAT_GATEWAY_TWO_ID="$(<"${output_file}.id")"
    nat_gateway_wait_for_ready "$NAT_GATEWAY_TWO_ID" "$SECOND_FULFILLMENT_ID" "$EXTERNAL_IP_TWO_ID"
    gateway_cr="$(nat_gateway_cr_json "$NAT_GATEWAY_TWO_ID" "$SECOND_FULFILLMENT_ID" "$EXTERNAL_IP_TWO_ID")"
    NAT_GATEWAY_TWO_UID="$(jq -er '.metadata.uid' <<<"$gateway_cr")"
    NAT_GATEWAY_TWO_INITIAL_STATE="$(nat_gateway_assert_provider_state \
        "$NAT_GATEWAY_TWO_ID" "$NAT_GATEWAY_TWO_UID" "$SECOND_K8S_UID" \
        "$EXTERNAL_IP_TWO_UID" "$EXTERNAL_IP_TWO_ADDRESS")"
    nat_gateway_assert_provider_rules "$NAT_GATEWAY_TWO_ID" "$NAT_GATEWAY_TWO_UID" \
        "$EXTERNAL_IP_TWO_ADDRESS" "$NAT_GATEWAY_TWO_INITIAL_STATE"
    assert_private_vn_isolation "$FIRST_FULFILLMENT_ID" "$SECOND_FULFILLMENT_ID"

    nat_gateway_create_subnets
    NAT_GATEWAY_ONE_INITIAL_STATE="$(nat_gateway_assert_provider_state \
        "$NAT_GATEWAY_ONE_ID" "$NAT_GATEWAY_ONE_UID" "$FIRST_K8S_UID" \
        "$EXTERNAL_IP_ONE_UID" "$EXTERNAL_IP_ONE_ADDRESS")"
    nat_gateway_assert_provider_rules "$NAT_GATEWAY_ONE_ID" "$NAT_GATEWAY_ONE_UID" \
        "$EXTERNAL_IP_ONE_ADDRESS" "$NAT_GATEWAY_ONE_INITIAL_STATE"
    NAT_GATEWAY_TWO_INITIAL_STATE="$(nat_gateway_assert_provider_state \
        "$NAT_GATEWAY_TWO_ID" "$NAT_GATEWAY_TWO_UID" "$SECOND_K8S_UID" \
        "$EXTERNAL_IP_TWO_UID" "$EXTERNAL_IP_TWO_ADDRESS")"
    nat_gateway_assert_provider_rules "$NAT_GATEWAY_TWO_ID" "$NAT_GATEWAY_TWO_UID" \
        "$EXTERNAL_IP_TWO_ADDRESS" "$NAT_GATEWAY_TWO_INITIAL_STATE"
    peer_entry="$NAT_GATEWAY_TWO_INITIAL_STATE"
    peer_eip_state_before_a_delete="$(external_ip_state_entry "$EXTERNAL_IP_TWO_UID" "$EXTERNAL_IP_TWO_ID")"

    nat_gateway_attach_client a1 "$NAT_GATEWAY_SUBNET_ONE_ID" "$NAT_GATEWAY_SUBNET_ONE_ENTRY"
    nat_gateway_attach_client a2 "$NAT_GATEWAY_SUBNET_ONE_ID" "$NAT_GATEWAY_SUBNET_ONE_ENTRY"
    nat_gateway_attach_client b1 "$NAT_GATEWAY_PEER_SUBNET_ID" "$NAT_GATEWAY_PEER_SUBNET_ENTRY"
    nat_gateway_assert_client_leases a1 a2 b1
    assert_same_subnet_l2 a1 a2
    assert_private_vn_isolation "$FIRST_FULFILLMENT_ID" "$SECOND_FULFILLMENT_ID"
    add_external_ip_client_route "$EXTERNAL_IP_ONE_ADDRESS" \
        || die "Could not add the NATGateway A test-only return route"
    add_external_ip_client_route "$EXTERNAL_IP_TWO_ADDRESS" \
        || die "Could not add the NATGateway peer test-only return route"
    wait_for_nat_gateway_source a1 "$EXTERNAL_IP_ONE_ADDRESS"
    wait_for_nat_gateway_source a2 "$EXTERNAL_IP_ONE_ADDRESS"
    wait_for_nat_gateway_source b1 "$EXTERNAL_IP_TWO_ADDRESS"

    info "Retrying NATGateway A for the same UID and provider identity..."
    nat_gateway_retry_and_verify "$NAT_GATEWAY_ONE_ID" "$FIRST_FULFILLMENT_ID" "$EXTERNAL_IP_ONE_ID"
    NAT_GATEWAY_ONE_INITIAL_STATE="$(nat_gateway_assert_provider_state \
        "$NAT_GATEWAY_ONE_ID" "$NAT_GATEWAY_ONE_UID" "$FIRST_K8S_UID" \
        "$EXTERNAL_IP_ONE_UID" "$EXTERNAL_IP_ONE_ADDRESS")"
    nat_gateway_assert_provider_rules "$NAT_GATEWAY_ONE_ID" "$NAT_GATEWAY_ONE_UID" \
        "$EXTERNAL_IP_ONE_ADDRESS" "$NAT_GATEWAY_ONE_INITIAL_STATE"
    wait_for_nat_gateway_source a1 "$EXTERNAL_IP_ONE_ADDRESS"
    wait_for_nat_gateway_source b1 "$EXTERNAL_IP_TWO_ADDRESS"

    info "Adding a second Subnet under NATGateway A and moving client a2..."
    output_file="${TEMP_DIR}/create-natgw-subnet-a2.out"
    create_nat_gateway_subnet "$NAT_GATEWAY_SUBNET_TWO_NAME" "$FIRST_FULFILLMENT_ID" \
        "$NAT_GATEWAY_SUBNET_TWO_CIDR" "$output_file"
    NAT_GATEWAY_SUBNET_TWO_ID="$LAST_NAT_GATEWAY_SUBNET_ID"
    NAT_GATEWAY_SUBNET_TWO_UID="$LAST_NAT_GATEWAY_SUBNET_UID"
    NAT_GATEWAY_SUBNET_TWO_ENTRY="$(get_subnet_state_entry "$NAT_GATEWAY_SUBNET_TWO_UID")"
    after_state="$(nat_gateway_assert_provider_state "$NAT_GATEWAY_ONE_ID" \
        "$NAT_GATEWAY_ONE_UID" "$FIRST_K8S_UID" "$EXTERNAL_IP_ONE_UID" \
        "$EXTERNAL_IP_ONE_ADDRESS")"
    [[ "$after_state" == "$NAT_GATEWAY_ONE_INITIAL_STATE" ]] \
        || die "Creating a second Subnet changed the NATGateway provider payload"
    nat_gateway_assert_provider_rules "$NAT_GATEWAY_ONE_ID" "$NAT_GATEWAY_ONE_UID" \
        "$EXTERNAL_IP_ONE_ADDRESS" "$after_state"
    nat_gateway_attach_client a2 "$NAT_GATEWAY_SUBNET_TWO_ID" "$NAT_GATEWAY_SUBNET_TWO_ENTRY"
    nat_gateway_assert_client_leases a1 a2 b1
    wait_for_nat_gateway_source a2 "$EXTERNAL_IP_ONE_ADDRESS"
    wait_for_nat_gateway_source b1 "$EXTERNAL_IP_TWO_ADDRESS"

    info "Deleting Subnet A2 without changing the VN-wide NATGateway..."
    detach_dhcp_client a2
    delete_subnet_by_id "$NAT_GATEWAY_SUBNET_TWO_ID"
    assert_uid_subnet_state_absent "$NAT_GATEWAY_SUBNET_TWO_UID" "$FIRST_K8S_UID" \
        "$FIRST_NAMESPACE_NAME" \
        "$(jq -er '.vlan_interface' <<<"$NAT_GATEWAY_SUBNET_TWO_ENTRY")" \
        "$(jq -er '.vlan_id' <<<"$NAT_GATEWAY_SUBNET_TWO_ENTRY")"
    after_state="$(nat_gateway_assert_provider_state "$NAT_GATEWAY_ONE_ID" \
        "$NAT_GATEWAY_ONE_UID" "$FIRST_K8S_UID" "$EXTERNAL_IP_ONE_UID" \
        "$EXTERNAL_IP_ONE_ADDRESS")"
    [[ "$after_state" == "$NAT_GATEWAY_ONE_INITIAL_STATE" ]] \
        || die "Deleting a Subnet changed the NATGateway provider payload"
    nat_gateway_assert_provider_rules "$NAT_GATEWAY_ONE_ID" "$NAT_GATEWAY_ONE_UID" \
        "$EXTERNAL_IP_ONE_ADDRESS" "$after_state"
    nat_gateway_assert_client_leases a1 b1
    wait_for_nat_gateway_source a1 "$EXTERNAL_IP_ONE_ADDRESS"
    wait_for_nat_gateway_source b1 "$EXTERNAL_IP_TWO_ADDRESS"

    info "Deleting the last Subnet and verifying the gateway retains its state..."
    detach_dhcp_client a1
    delete_subnet_by_id "$NAT_GATEWAY_SUBNET_ONE_ID"
    assert_uid_subnet_state_absent "$NAT_GATEWAY_SUBNET_ONE_UID" "$FIRST_K8S_UID" \
        "$FIRST_NAMESPACE_NAME" \
        "$(jq -er '.vlan_interface' <<<"$NAT_GATEWAY_SUBNET_ONE_ENTRY")" \
        "$(jq -er '.vlan_id' <<<"$NAT_GATEWAY_SUBNET_ONE_ENTRY")"
    after_state="$(nat_gateway_assert_provider_state "$NAT_GATEWAY_ONE_ID" \
        "$NAT_GATEWAY_ONE_UID" "$FIRST_K8S_UID" "$EXTERNAL_IP_ONE_UID" \
        "$EXTERNAL_IP_ONE_ADDRESS")"
    [[ "$after_state" == "$NAT_GATEWAY_ONE_INITIAL_STATE" ]] \
        || die "Deleting the last Subnet changed the NATGateway provider payload"
    nat_gateway_assert_provider_rules "$NAT_GATEWAY_ONE_ID" "$NAT_GATEWAY_ONE_UID" \
        "$EXTERNAL_IP_ONE_ADDRESS" "$after_state"
    wait_for_nat_gateway_source b1 "$EXTERNAL_IP_TWO_ADDRESS"

    info "Deleting NATGateway A before releasing its ExternalIP..."
    delete_nat_gateway_and_verify "$NAT_GATEWAY_ONE_ID" "$FIRST_FULFILLMENT_ID" "$EXTERNAL_IP_ONE_ID" \
        || die "NATGateway A cleanup failed; retaining ExternalIP and network resources"
    remove_external_ip_client_route "$EXTERNAL_IP_ONE_ADDRESS" \
        || die "Could not remove the NATGateway A test-only return route"
    delete_external_ip_and_verify "$EXTERNAL_IP_ONE_ID" "$EXTERNAL_IP_ONE_UID" 1
    wait_for_nat_gateway_source b1 "$EXTERNAL_IP_TWO_ADDRESS"
    [[ "$(get_nat_gateway_state_entry "$NAT_GATEWAY_TWO_UID" "$NAT_GATEWAY_TWO_ID")" \
        == "$peer_entry" ]] \
        || die "NATGateway A deletion altered the peer NATGateway provider state"
    [[ "$(external_ip_state_entry "$EXTERNAL_IP_TWO_UID" "$EXTERNAL_IP_TWO_ID")" \
        == "$peer_eip_state_before_a_delete" ]] \
        || die "NATGateway A deletion altered the peer ExternalIP state"

    info "Deleting the peer NATGateway while its Subnet still exists..."
    detach_dhcp_client b1
    delete_nat_gateway_and_verify "$NAT_GATEWAY_TWO_ID" "$SECOND_FULFILLMENT_ID" "$EXTERNAL_IP_TWO_ID" \
        || die "Peer NATGateway cleanup failed; retaining its ExternalIP and Subnet"
    remove_external_ip_client_route "$EXTERNAL_IP_TWO_ADDRESS" \
        || die "Could not remove the peer NATGateway test-only return route"
    delete_external_ip_and_verify "$EXTERNAL_IP_TWO_ID" "$EXTERNAL_IP_TWO_UID" 0
    delete_subnet_by_id "$NAT_GATEWAY_PEER_SUBNET_ID"
    assert_uid_subnet_state_absent "$NAT_GATEWAY_PEER_SUBNET_UID" "$SECOND_K8S_UID" \
        "$SECOND_NAMESPACE_NAME" \
        "$(jq -er '.vlan_interface' <<<"$NAT_GATEWAY_PEER_SUBNET_ENTRY")" \
        "$(jq -er '.vlan_id' <<<"$NAT_GATEWAY_PEER_SUBNET_ENTRY")"
    cleanup_nat_gateway_endpoint \
        || die "Could not remove the NATGateway test endpoint after provider cleanup"
    external_ip_pool_wait_for_delta 0
    save_current_state
    assert_baseline_state_unchanged
    info "NATGateway SNAT, source observation, retry, Subnet churn, peer isolation, and cleanup passed."
}

run_nat_gateway_suite() {
    info "Creating the local NATGateway test pool and overlapping VirtualNetworks..."
    create_external_ip_pool
    create_nat_gateway_virtual_networks
    run_nat_gateway_lifecycle
    info "Deleting the NATGateway test VirtualNetworks and ExternalIPPool..."
    delete_virtual_network_by_id "$FIRST_FULFILLMENT_ID"
    FIRST_DELETE_AAP_JOB_ID="$LAST_DELETE_AAP_JOB_ID"
    delete_virtual_network_by_id "$SECOND_FULFILLMENT_ID"
    SECOND_DELETE_AAP_JOB_ID="$LAST_DELETE_AAP_JOB_ID"
    delete_external_ip_pool
    save_current_state
    assert_baseline_state_unchanged
}

run_full_suite() {
info "Creating and verifying one shared IPv4 ExternalIPPool through Fulfillment..."
create_external_ip_pool

info "Submitting two overlapping VirtualNetwork requests concurrently through Fulfillment..."
CREATE_ONE_OUTPUT="${TEMP_DIR}/create-one.out"
CREATE_TWO_OUTPUT="${TEMP_DIR}/create-two.out"
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
assert_provider_key_survived "concurrent VirtualNetwork provisioning"
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
    run_subnet_dhcp_checks
if [[ "$SUITE_USES_EXTERNAL_IP_ATTACHMENT" == true ]]; then
    info "Preparing a synthetic DHCP target on the test VirtualNetwork for ExternalIP ingress checks..."
    create_external_ip_attachment_test_network_and_client
    info "Running ExternalIP allocation, retry, ingress, detach, and capacity checks..."
    run_external_ip_lifecycle
    delete_subnet_by_id "$EXTERNAL_IP_ATTACHMENT_SUBNET_ID"
fi
if [[ "$SUITE_USES_NAT_GATEWAY" == true ]]; then
    info "Running local NATGateway SNAT, source observation, retry, and Subnet lifecycle checks..."
    run_nat_gateway_lifecycle
fi
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

EXTERNAL_IP_POOL_ENTRY_AFTER_VN_DELETE="$(get_external_ip_pool_state_entry \
    "$EXTERNAL_IP_POOL_K8S_UID" "$EXTERNAL_IP_POOL_ID")"
[[ "$EXTERNAL_IP_POOL_ENTRY_AFTER_VN_DELETE" == "$EXTERNAL_IP_POOL_INITIAL_ENTRY" ]] \
    || die "VirtualNetwork and Subnet deletion altered ExternalIPPool provider state"
info "Deleting the test-owned ExternalIPPool through Fulfillment and verifying provider cleanup..."
delete_external_ip_pool
save_current_state
assert_baseline_state_unchanged
}

run_virtual_network_suite() {
    create_primary_virtual_network_for_suite
    delete_primary_virtual_network_for_suite
}

run_subnet_dhcp_suite() {
    create_primary_virtual_network_for_suite
    run_subnet_dhcp_checks
    delete_primary_virtual_network_for_suite
}

run_external_ip_pool_suite() {
    info "Creating and verifying one shared IPv4 ExternalIPPool through Fulfillment..."
    create_external_ip_pool
    info "Deleting the test-owned ExternalIPPool through Fulfillment and verifying provider cleanup..."
    delete_external_ip_pool
    save_current_state
    assert_baseline_state_unchanged
}

run_external_ip_suite() {
    info "Creating a test VirtualNetwork, Subnet, and synthetic DHCP target for ExternalIP ingress..."
    create_external_ip_attachment_test_network_and_client
    info "Creating the shared IPv4 ExternalIPPool used by the lifecycle test..."
    create_external_ip_pool
    run_external_ip_lifecycle
    delete_subnet_by_id "$EXTERNAL_IP_ATTACHMENT_SUBNET_ID"
    delete_primary_virtual_network_for_suite
    info "Deleting the test-owned ExternalIPPool after all ExternalIPs were released..."
    delete_external_ip_pool
    save_current_state
    assert_baseline_state_unchanged
}

# Standalone cleanup uses the current deployment and fabric only. It deliberately
# skips Steps 1-4 so cleanup never boots, deploys, upgrades, or initializes them.
if [[ "$CLEANUP_MODE" == true ]]; then
    step "Standalone cleanup: removing ${VLAN_E2E_SUITE} E2E resources"
    oc get nodes >/dev/null \
        || die "The existing OpenShift cluster is unavailable; cleanup will not deploy it"
    oc wait deployment/fulfillment-grpc-server -n "$OSAC_NAMESPACE" \
        --for=condition=Available --timeout=300s >/dev/null \
        || die "The existing Fulfillment API is not available for cleanup"
    oc wait deployment/osac-operator -n "$OSAC_NAMESPACE" \
        --for=condition=Available --timeout=300s >/dev/null \
        || die "The existing OSAC operator is not available for cleanup"
    oc wait deployment/osac-aap-controller-task -n "$OSAC_NAMESPACE" \
        --for=condition=Available --timeout=300s >/dev/null \
        || die "The existing AAP controller is not available for cleanup"

    CLUSTER_DOMAIN="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
    [[ -n "$CLUSTER_DOMAIN" ]] || die "Could not read the existing cluster domain"
    AAP_IMAGE="$(helm get values osac -n "$OSAC_NAMESPACE" --all -o json \
        | jq -er '.aap.configAsCode.eeImage')" \
        || die "Could not read the currently deployed AAP execution environment image"
    [[ "$AAP_IMAGE" =~ ^quay\.io/[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+$ ]] \
        || die "The deployed AAP execution environment image reference is invalid"
    AAP_API_CA_FILE="$TEMP_DIR/aap-api-ca.pem"
    prepare_aap_ca_bundle
    sync_aap_project_revision

    resolve_mgmt_network
    if ! docker inspect "$CONTAINERLAB_NET_NODE" >/dev/null 2>&1 \
        || [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINERLAB_NET_NODE")" != true ]]; then
        die "The existing Containerlab network node is unavailable; cleanup will not deploy the fabric"
    fi
    if [[ "$SUITE_USES_EXTERNAL_ROUTING" == true ]] \
        && { ! docker inspect "$CONTAINERLAB_UPSTREAM_ROUTER" >/dev/null 2>&1 \
            || [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINERLAB_UPSTREAM_ROUTER")" != true ]]; }; then
        die "The existing upstream-router test client is unavailable; cleanup will not deploy the fabric"
    fi
    write_provider_inventory
    ensure_containerlab_switches
    ensure_cumulus_admin_identity
    write_cumulus_ssh_config
    prepare_containerlab_net_node
    prepare_containerlab_switches
    if [[ "$SUITE_USES_SUBNET_DHCP" == true ]]; then
        prepare_containerlab_dhcp_supervisor
        configure_aap_subnet_reader \
            || die "Could not configure AAP Kubernetes authentication for cleanup of interrupted DHCP clients"
    fi
    prepare_aap_networking_instance_group
    if [[ "$SUITE_USES_NAT_GATEWAY" == true ]]; then
        configure_nat_gateway_uplink \
            || die "Could not adopt the guarded NATGateway uplink override for cleanup"
    fi

    if [[ "$SUITE_USES_CLI" == true ]]; then
        info "Building a temporary local Fulfillment CLI for cleanup..."
        CLI_CA_FILE="$AAP_API_CA_FILE"
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
        "$CLI_BIN" --config "$CLI_CONFIG_DIR" --tenant "$OSAC_TENANT" \
            tenant "$OSAC_TENANT" >/dev/null \
            || die "The existing E2E tenant is unavailable; cleanup will not create it"
    fi

    prepare_suite_cleanup
    info "Cleanup is prepared; the exit handler will delete selected resources in dependency order."
    exit 0
fi
step "STEP 5 OF 5: Running the ${VLAN_E2E_SUITE} E2E suite"

# Preserve the full pre-test JSON snapshot. Only the UIDs created by this run
# are asserted or removed; any unrelated node state remains untouched.
if [[ "$SUITE_USES_SUBNET_DHCP" == true ]]; then
    write_agentless_e2e_helpers
fi
HOST_IP_FORWARDING_BEFORE="$(netnode sysctl -n net.ipv4.ip_forward)"
state_snapshot > "$BASELINE_STATE_FILE"
jq -e '(.schema_version == 0 or .schema_version == 1)
      and (.virtual_networks | type == "array")
      and (.subnets | type == "array")
      and (.external_ip_pools | type == "array")
      and (.external_ips | type == "array")
      and (.external_ip_attachments | type == "array")
      and (.nat_gateways | type == "array")' \
    "$BASELINE_STATE_FILE" >/dev/null \
    || die "AgentlessNet state must be empty or use the current schema v1 before the test starts"


case "$VLAN_E2E_SUITE" in
    full) run_full_suite ;;
    virtual-network) run_virtual_network_suite ;;
    subnet-dhcp) run_subnet_dhcp_suite ;;
    external-ip-pool) run_external_ip_pool_suite ;;
    external-ip) run_external_ip_suite ;;
    nat-gateway) run_nat_gateway_suite ;;
esac

HOST_IP_FORWARDING_AFTER="$(netnode sysctl -n net.ipv4.ip_forward)"
[[ "$HOST_IP_FORWARDING_AFTER" == "$HOST_IP_FORWARDING_BEFORE" ]] \
    || die "The AgentlessNet operations changed the test node's forwarding sysctl"

if [[ "$SUITE_USES_SUBNET_DHCP" == true ]]; then
    cleanup_dhcp_clients_and_attachments \
        || die "Could not offboard simulated BMIs or remove run-owned DHCP client links"
fi
case "$VLAN_E2E_SUITE" in
    full)
        info "Local AgentlessNet VLAN lab E2E passed: ExternalIP allocation/retry/release and synthetic-target ExternalIPAttachment ingress, VN-wide NATGateway SNAT and observed source address, independent Subnet lifecycle, overlapping VirtualNetworks, VN and Subnet retries, internal VLAN exclusion, AAP DHCP attachment and lease lookup for test clients, gateway and same-Subnet L2 traffic across leaves, DHCP service restart, /30 lease, peer-preserving lifecycle, and ordered cleanup. Remote BGP convergence and physical hardware are not covered."
        ;;
    virtual-network)
        info "VirtualNetwork-only E2E passed: one VN was created, verified, deleted, and cleaned up."
        ;;
    subnet-dhcp)
        info "Subnet/DHCP-only E2E passed: Subnet, retry, DHCP client, /30, and temporary parent VN cleanup checks passed."
        ;;
    external-ip-pool)
        info "ExternalIPPool-only E2E passed: one pool was created, verified, deleted, and cleaned up."
        ;;
    external-ip)
        info "ExternalIP E2E passed: two addresses were allocated, one UID retry reused its reservation, the synthetic DHCP target replied through both ExternalIPs, attachment retry and peer preservation passed, attachments were detached before EIPs and network resources, pool capacity was restored, and test network resources were deleted. The external client uses a test-only static route; upstream BGP advertisement is not exercised."
        ;;
    nat-gateway)
        info "Local NATGateway VLAN lab E2E passed: the VN CIDR was SNATed to the allocated ExternalIP with a transit exemption, Subnet creation and deletion left gateway state unchanged, retry retained provider identity, the peer NATGateway remained unchanged, and cleanup completed. Remote BGP convergence, service restarts, and physical hardware are not covered."
        ;;
esac
