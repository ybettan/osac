#!/usr/bin/env bash
# Run the real BMaaS-to-AgentlessNet journey on the shared VLAN development lab.
#
# The shared vlan-infra.sh prepares the SNO, OSAC with BMF, the Containerlab
# fabric, one reusable virtual BareMetalHost, the bootstrap ExternalIPPool, and
# the single osac-e2e-ci installation tenant. This runner then creates one
# BareMetalInstance in that tenant, verifies its provisioning, fabric network
# attachment, and tenant IP feedback, and deletes it with ordered cleanup.
set -euo pipefail
umask 077

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vlan-infra.sh
source "${REPO_ROOT}/vlan-infra.sh"

VLAN_E2E_SUITE="bmaas"
SUITE_USES_VN=false
SUITE_USES_SUBNET=false
SUITE_USES_SUBNET_DHCP=true
SUITE_USES_POOL=false
SUITE_USES_CLI=true
SUITE_USES_EXTERNAL_IP=false
SUITE_USES_EXTERNAL_IP_ATTACHMENT=false
SUITE_USES_NAT_GATEWAY=false
CLEANUP_MODE=false

if [[ "${VLAN_E2E_BMAAS_LIBRARY:-false}" == true ]]; then
    bmaas_pytest_env() {
        local route token
        local infra_dir
        OSAC_BMH_NAMESPACE="${OSAC_BMH_NAMESPACE:-host-inventory}"
        # The suite's private-API client creates disk images and instance types,
        # which the private API authorizes only for its admin identity. The
        # public CLI keeps the least-privilege runner identity.
        OSAC_SERVICE_ACCOUNT="${OSAC_BMAAS_PRIVATE_SERVICE_ACCOUNT:-admin}"
        export OSAC_NAMESPACE OSAC_SERVICE_ACCOUNT
        export OSAC_BMH_NAMESPACE
        export OSAC_CLI_PATH="$CLI_BIN"
        export OSAC_BMAAS_HOSTS_FILE="$(bmaas_host_state_file)"
        export OSAC_BMAAS_SOURCE_SHA="$RUNTIME_SOURCE_COMMIT"
        export OSAC_BMAAS_AAP_REVISION="$AAP_PROJECT_EXPECTED_REVISION"
        export OSAC_BMAAS_AAP_IMAGE="$AAP_IMAGE"
        export OSAC_BMAAS_BMF_IMAGE="$BMF_IMAGE"
        export OSAC_BMAAS_AAP_IMAGE_ID="$("$CONTAINER_TOOL" image inspect --format '{{.Id}}' "$AAP_IMAGE" 2>/dev/null || printf unknown)"
        export OSAC_BMAAS_BMF_IMAGE_ID="$("$CONTAINER_TOOL" image inspect --format '{{.Id}}' "$BMF_IMAGE" 2>/dev/null || printf unknown)"
        infra_dir="$(bmaas_test_infra_dir)"
        export OSAC_BMAAS_TEST_INFRA_SHA="$(git -C "$infra_dir" rev-parse HEAD 2>/dev/null || printf unknown)"
        export OSAC_BMAAS_TEST_INFRA_EXPECTED_SHA="$(bmaas_test_infra_ref)"
        OSAC_BMAAS_RUN_ID="${OSAC_BMAAS_RUN_ID:-agentless-bmaas}"
        OSAC_BMAAS_EVIDENCE_DIR="${VLAN_E2E_RUN_DIR:-${REPO_ROOT}/.artifacts/agentless-net-bmaas/runs}"
        export OSAC_BMAAS_RUN_ID OSAC_BMAAS_EVIDENCE_DIR
        route="$(oc get route osac-aap -n "$OSAC_NAMESPACE" -o jsonpath='{.spec.host}')" \
            || die "Could not read the AAP route for BMaaS diagnostics"
        token="$(oc exec deployment/osac-operator -n "$OSAC_NAMESPACE" -- \
            sh -c 'printf %s "$OSAC_AAP_TOKEN"' 2>/dev/null)" \
            || die "Could not read the AAP token for BMaaS diagnostics"
        [[ -n "$route" && -n "$token" ]] || die "AAP diagnostics credentials are unavailable"
        export OSAC_BMAAS_AAP_ROUTE="https://${route}"
        export OSAC_BMAAS_AAP_TOKEN="$token"
        export OSAC_BMAAS_AAP_CA_FILE="$AAP_API_CA_FILE"
        unset token
    }

    run_bmaas_suite() {
        local journal
        journal="${VLAN_E2E_RUN_DIR:-${REPO_ROOT}/.artifacts/agentless-net-bmaas/runs}/${OSAC_BMAAS_RUN_ID:-agentless-bmaas}.json"
        if [[ -f "$journal" ]] && [[ "$(jq -r '.cleaned // false' "$journal")" != true ]]; then
            die "Uncleaned BMaaS resources are recorded in ${journal}; run --cleanup first"
        fi
        bmaas_pytest_env
        info "Running the BMaaS-to-AgentlessNet lifecycle against one real virtual host..."
        if ! uv run pytest -n 0 tests/e2e/bmaas/agentless_net/test_agentless_net_networking.py; then
            PRESERVE_E2E_RECOVERY_ARTIFACTS=true
            return 1
        fi
    }

    run_bmaas_cleanup() {
        local journal
        journal="${VLAN_E2E_RUN_DIR:-${REPO_ROOT}/.artifacts/agentless-net-bmaas/runs}/${OSAC_BMAAS_RUN_ID:-agentless-bmaas}.json"
        bmaas_pytest_env
        if [[ ! -f "$journal" ]]; then
            # Say where the journal was expected: a cleanup that silently finds
            # nothing leaves the failed run's resources behind.
            info "No BMaaS resource journal at ${journal}; pass VLAN_E2E_RUN_DIR=<failed run directory> to clean the resources that run created."
        fi
        export OSAC_BMAAS_CLEANUP=true
        uv run pytest -n 0 tests/e2e/bmaas/agentless_net/test_agentless_net_networking.py \
            -k cleanup_owned_agentless_bmaas
    }

    return 0
fi

if [[ "$#" -gt 0 && "$1" == --help || "$#" -eq 1 && "$1" == -h ]]; then
    cat <<'USAGE'
Usage: bash ./vlan-e2e-bmaas.sh [--cleanup]

Run the complete BMaaS-to-AgentlessNet E2E against the local shared VLAN lab.
The shared infrastructure step prepares or reuses OSAC with BMF, one virtual
BareMetalHost, the Containerlab fabric, the bootstrap ExternalIPPool, and the
osac-e2e-ci installation tenant. This runner then tests one real BMI network
attachment and cleans only its owned test resources. The virtual host and the
SNO/fabric are retained.

Run --cleanup after an interrupted test. Cleanup uses the current deployment
and does not boot or reinstall the cluster.
USAGE
    exit 0
fi
if [[ "$#" -gt 0 && ("$#" -ne 1 || "$1" != --cleanup) ]]; then
    printf 'ERROR: supported arguments are --help and --cleanup\n' >&2
    exit 2
fi
if [[ "${1:-}" == --cleanup ]]; then
    CLEANUP_MODE=true
fi

on_exit() {
    local status=$?
    trap - EXIT
    set +e
    if [[ "$status" != 0 ]]; then
        printf 'ERROR: preserving BMaaS provider access and test resources after a failed journey\n' >&2
        PRESERVE_E2E_RECOVERY_ARTIFACTS=true
    fi
    vlan_infra_on_exit_tail "$status" 0
}
trap on_exit EXIT

vlan_infra_init

if [[ "$CLEANUP_MODE" == true ]]; then
    vlan_infra_prepare_cleanup
    if ! run_bmaas_cleanup; then
        PRESERVE_E2E_RECOVERY_ARTIFACTS=true
        die "BMaaS cleanup could not remove all test-owned resources"
    fi
    CLEANUP_DISCOVERY_COMPLETE=true
    CLEANUP_CLIENTS_COMPLETE=true
    info "BMaaS cleanup completed; reusable hosts and lab infrastructure were retained."
    exit 0
fi

vlan_infra_up

step "STEP 5 OF 5: Running the BMaaS-to-AgentlessNet E2E"
HOST_IP_FORWARDING_BEFORE="$(netnode sysctl -n net.ipv4.ip_forward)"
if ! run_bmaas_suite; then
    PRESERVE_E2E_RECOVERY_ARTIFACTS=true
    die "BMaaS-to-AgentlessNet E2E failed; use bash ./vlan-e2e-bmaas.sh --cleanup after reviewing the evidence"
fi
HOST_IP_FORWARDING_AFTER="$(netnode sysctl -n net.ipv4.ip_forward)"
[[ "$HOST_IP_FORWARDING_AFTER" == "$HOST_IP_FORWARDING_BEFORE" ]] \
    || die "The BMaaS E2E changed the Containerlab network-node forwarding sysctl"
assert_legacy_provider_state_unchanged \
    || die "The BMaaS E2E changed legacy AgentlessNet provider state"
info "BMaaS-to-AgentlessNet E2E passed."
