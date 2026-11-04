#!/usr/bin/env bash
# Run the real BMaaS-to-AgentlessNet journey on the shared VLAN development lab.
set -euo pipefail

if [[ "${VLAN_E2E_BMAAS_LIBRARY:-false}" == true ]]; then
    bmaas_test_infra_dir() {
        printf '%s\n' "${OSAC_TEST_INFRA_DIR:-${REPO_ROOT}/../osac-test-infra}"
    }

    bmaas_test_infra_ref() {
        printf '%s\n' "${OSAC_TEST_INFRA_REF:-4cacab7f7afe56ed111465e096c0331771edfda9}"
    }

    bmaas_activate_ironic() {
        local attempt provisioning_pods webhook_ips
        info "Activating Ironic before the OSAC BMaaS preflight..."
        oc apply -f - <<'EOF'
apiVersion: metal3.io/v1alpha1
kind: Provisioning
metadata:
  name: provisioning-configuration
spec:
  provisioningNetwork: "Disabled"
  disableVirtualMediaTLS: true
  watchAllNamespaces: true
EOF

        # `oc wait --for=create` fails when the selector has no matches yet;
        # the Provisioning resource starts these pods asynchronously.
        provisioning_pods=""
        for ((attempt = 1; attempt <= 60; attempt++)); do
            provisioning_pods="$(oc get pods -n openshift-machine-api \
                -l baremetal.openshift.io/cluster-baremetal-operator=metal3-state -o name)"
            [[ -n "$provisioning_pods" ]] && break
            sleep 5
        done
        [[ -n "$provisioning_pods" ]] \
            || die "Metal3 pods did not appear after BMaaS Ironic activation"
        oc wait --for=condition=Ready pods \
            -l baremetal.openshift.io/cluster-baremetal-operator=metal3-state \
            -n openshift-machine-api --timeout=600s >/dev/null

        webhook_ips=""
        for ((attempt = 1; attempt <= 60; attempt++)); do
            webhook_ips="$(oc get endpoints baremetal-operator-webhook-service \
                -n openshift-machine-api -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
            [[ -n "$webhook_ips" ]] && break
            sleep 5
        done
        [[ -n "$webhook_ips" ]] \
            || die "Metal3 BareMetalHost webhook did not become ready after Ironic activation"
    }

    bmaas_host_state_file() {
        printf '%s\n' "${REPO_ROOT}/.artifacts/agentless-net-bmaas/hosts.json"
    }

    bmaas_prepare_hosts() {
        local state_file inventory_file infra_dir setup_script bmh_name bridge host_link fabric_mac switch vm_state
        local bmh_namespace="${OSAC_BMH_NAMESPACE:-host-inventory}"
        local -a bmh_names=("virtual-bmh-${MGMT_CLONE_NAME}-1" "virtual-bmh-${MGMT_CLONE_NAME}-2")
        state_file="$(bmaas_host_state_file)"
        inventory_file="${HOME}/virtual-bmh-inventory-${MGMT_CLONE_NAME}.json"
        mkdir -p "$(dirname "$state_file")"
        chmod 0700 "$(dirname "$state_file")"

        if [[ -f "$state_file" ]]; then
            mapfile -t bmh_names < <(jq -r '.hosts[].name' "$state_file")
            [[ "${#bmh_names[@]}" == 2 ]] \
                || die "Recorded BMaaS host inventory must contain exactly two hosts"
            while IFS= read -r bmh_name; do
                [[ -n "$bmh_name" ]] || continue
                virsh domstate "$bmh_name" >/dev/null 2>&1 \
                    || die "Recorded BMaaS host VM ${bmh_name} is missing; inspect the lab before recovery"
                oc get bmh "$bmh_name" -n "$bmh_namespace" >/dev/null 2>&1 \
                    || die "Recorded BMaaS host ${bmh_name} is missing; inspect the lab before recovery"
            done < <(jq -r '.hosts[].name' "$state_file")
        elif [[ -f "$inventory_file" ]]; then
            mapfile -t bmh_names < <(jq -r '.hosts[].name' "$inventory_file")
            [[ "${#bmh_names[@]}" == 2 ]] \
                || die "BMaaS CI inventory must contain exactly two hosts"
            while IFS= read -r bmh_name; do
                [[ -n "$bmh_name" ]] || continue
                virsh dominfo "$bmh_name" >/dev/null 2>&1 \
                    || die "BMaaS inventory VM ${bmh_name} is missing; inspect the lab before recovery"
                oc get bmh "$bmh_name" -n "$bmh_namespace" >/dev/null 2>&1 \
                    || die "BMaaS inventory host ${bmh_name} is missing; inspect the lab before recovery"
            done < <(jq -r '.hosts[].name' "$inventory_file")
            info "Adopting the two BareMetalHosts from the existing BMaaS CI inventory."
        else
            local all_existing=true any_existing=false
            for bmh_name in "${bmh_names[@]}"; do
                local vm_exists=false bmh_exists=false
                virsh dominfo "$bmh_name" >/dev/null 2>&1 && vm_exists=true
                oc get bmh "$bmh_name" -n "$bmh_namespace" >/dev/null 2>&1 && bmh_exists=true
                if [[ "$vm_exists" == true || "$bmh_exists" == true ]]; then
                    any_existing=true
                fi
                if [[ "$vm_exists" != true || "$bmh_exists" != true ]]; then
                    all_existing=false
                fi
            done
            if [[ "$all_existing" != true ]]; then
                [[ "$any_existing" == false ]] \
                    || die "Partial BMaaS host state exists; inspect the lab before setup"
                infra_dir="$(bmaas_test_infra_dir)"
                setup_script="${infra_dir}/.github/scripts/setup-virtual-bmh.sh"
                [[ -f "$setup_script" ]] \
                    || die "BMaaS host setup script is missing: ${setup_script}; set OSAC_TEST_INFRA_DIR to the current osac-test-infra checkout"
                local expected_infra_ref actual_infra_ref
                expected_infra_ref="$(bmaas_test_infra_ref)"
                actual_infra_ref="$(git -C "$infra_dir" rev-parse HEAD 2>/dev/null)" \
                    || die "Could not resolve the osac-test-infra revision"
                [[ "$actual_infra_ref" == "$expected_infra_ref" ]] \
                    || die "BMaaS host setup requires osac-test-infra ${expected_infra_ref}; got ${actual_infra_ref}"
                info "Creating the two reusable virtual BareMetalHosts using BMaaS CI setup..."
                CLONE_NAME="$MGMT_CLONE_NAME" \
                    KUBECONFIG="$KUBECONFIG" \
                    BMH_NAMESPACE="$bmh_namespace" \
                    BMH_COUNT=2 \
                    bash "$setup_script" 9>&-
                [[ -f "$inventory_file" ]] \
                    || die "BMaaS CI setup did not write its raw host inventory"
                mapfile -t bmh_names < <(jq -r '.hosts[].name' "$inventory_file")
                [[ "${#bmh_names[@]}" == 2 ]] \
                    || die "BMaaS CI inventory must contain exactly two hosts"
            else
                info "Adopting the two existing BMaaS virtual hosts for this lab."
            fi
        fi

        # Save host ownership before attaching the fabric NICs. If a later
        # bridge or port setup step fails, the next run can adopt these hosts.
        python3 - "$state_file" "${bmh_names[@]}" <<'PY'
import json
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
names = sys.argv[2:]
hosts = [
    {
        "name": name,
        "interface": "data-0",
        "switch": f"clab-agentless-net-lab-leaf-{index}",
        "port": "swp5",
        "fabric_mac": f"52:54:00:ba:aa:{index:02x}",
    }
    for index, name in enumerate(names, start=1)
]
tmp = path.with_suffix(".tmp")
tmp.write_text(json.dumps({"hosts": hosts}, indent=2) + "\n")
tmp.chmod(0o600)
os.replace(tmp, path)
PY

        local index=0
        for bmh_name in "${bmh_names[@]}"; do
            index=$((index + 1))
            if [[ "$index" == 1 ]]; then
                host_link="bmaas-l1"
                bridge="br-bmaas-l1"
                switch="${CONTAINERLAB_PREFIX}-leaf-1"
                fabric_mac="52:54:00:ba:aa:01"
            else
                host_link="bmaas-l2"
                bridge="br-bmaas-l2"
                switch="${CONTAINERLAB_PREFIX}-leaf-2"
                fabric_mac="52:54:00:ba:aa:02"
            fi

            if ! ip link show "$host_link" >/dev/null 2>&1; then
                sudo "$CONTAINERLAB" tools veth create \
                    --a-endpoint "${switch}:swp5" \
                    --b-endpoint "host:${host_link}" \
                    || die "Could not add the dedicated BMaaS host link ${switch}/swp5"
            fi
            if ! ip link show "$bridge" >/dev/null 2>&1; then
                sudo ip link add "$bridge" type bridge
            fi
            sudo ip link set "$host_link" master "$bridge"
            sudo ip link set "$bridge" up

            if ! virsh domiflist "$bmh_name" | awk -v bridge="$bridge" '$3 == bridge { found=1 } END { exit !found }'; then
                vm_state="$(virsh domstate "$bmh_name" 2>/dev/null)" \
                    || die "Could not inspect BMaaS host VM ${bmh_name}"
                if [[ "$vm_state" == running ]]; then
                    virsh attach-interface --domain "$bmh_name" --type bridge \
                        --source "$bridge" --model virtio --mac "$fabric_mac" --config --live \
                        || die "Could not attach the BMaaS fabric NIC to ${bmh_name}"
                else
                    virsh attach-interface --domain "$bmh_name" --type bridge \
                        --source "$bridge" --model virtio --mac "$fabric_mac" --config \
                        || die "Could not attach the BMaaS fabric NIC to ${bmh_name}"
                fi
            fi

            oc label bmh "$bmh_name" -n "$bmh_namespace" \
                osac.openshift.io/host-type=default --overwrite >/dev/null
            oc annotate bmh "$bmh_name" -n "$bmh_namespace" \
                "osac.openshift.io/interface-macs={\"data-0\":\"${fabric_mac}\"}" --overwrite >/dev/null
            local hardware_nics ready=false
            hardware_nics="$(oc get bmh "$bmh_name" -n "$bmh_namespace" -o json \
                | jq -r '.status.hardware.nics[]?.mac | ascii_downcase')"
            if ! grep -Fxq "$fabric_mac" <<<"$hardware_nics"; then
                oc annotate bmh "$bmh_name" -n "$bmh_namespace" \
                    inspect.metal3.io= --overwrite >/dev/null
                for ((attempt = 1; attempt <= 180; attempt++)); do
                    if [[ "$(oc get bmh "$bmh_name" -n "$bmh_namespace" \
                        -o jsonpath='{.status.provisioning.state}' 2>/dev/null || true)" == available ]]; then
                        ready=true
                        break
                    fi
                    sleep 5
                done
                [[ "$ready" == true ]] || die "BMaaS host ${bmh_name} did not return to available after NIC inspection"
                hardware_nics="$(oc get bmh "$bmh_name" -n "$bmh_namespace" -o json \
                    | jq -r '.status.hardware.nics[]?.mac | ascii_downcase')"
            else
                ready=true
            fi
            [[ "$ready" == true ]] || {
                printf 'BMaaS host %s is not available after fabric NIC setup\n' "$bmh_name" >&2
                return 1
            }
            grep -Fxq "$fabric_mac" <<<"$hardware_nics" \
                || die "BMaaS host ${bmh_name} hardware inspection did not report its AgentlessNet NIC"
        done

        python3 - "$state_file" "$BMAAS_HOST_PORTS_FILE" <<'PY'
import json
import pathlib
import sys

hosts = json.loads(pathlib.Path(sys.argv[1]).read_text())["hosts"]
ports = {
    host["name"]: {
        host["interface"]: {"switch": host["switch"], "port": host["port"]}
    }
    for host in hosts
}
path = pathlib.Path(sys.argv[2])
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(ports, indent=2) + "\n")
path.chmod(0o600)
PY
    }

    bmaas_configure_host_ports() {
        local log_file="${TEMP_DIR}/bmaas-access-ports.log"
        info "Configuring the two BMaaS provisioning ports through network-runner..."
        if ! (
            cd "$AAP_DIR"
            uv run --locked --group development ansible-playbook \
                --inventory "$TEMP_DIR/inventory.yml" \
                --private-key "$CUMULUS_LAB_ADMIN_KEY" \
                --ssh-extra-args \
                "-o BatchMode=yes -o IdentitiesOnly=yes -o UserKnownHostsFile=$TEMP_DIR/known_hosts -o ConnectTimeout=5" \
                "${FABRIC_DIR}/configure_bmaas_access_ports.yml"
        ) >"$log_file" 2>&1; then
            tail -n 80 "$log_file" >&2
            die "Could not configure BMaaS access ports through network-runner"
        fi
    }

    bmaas_pytest_env() {
        local route token
        local infra_dir
        OSAC_BMH_NAMESPACE="${OSAC_BMH_NAMESPACE:-host-inventory}"
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
        export OSAC_BMAAS_NAT_ENDPOINT_URL="http://${EXTERNAL_IP_TEST_LINK_CLIENT_ADDRESS}:${NAT_GATEWAY_RESPONSE_PORT}/cgi-bin/observe"
        export OSAC_BMAAS_NAT_ENDPOINT_TOKEN="$NAT_GATEWAY_RESPONSE_TOKEN"
        export OSAC_BMAAS_UPSTREAM_ROUTER="$CONTAINERLAB_UPSTREAM_ROUTER"
        export OSAC_BMAAS_EXTERNAL_IP_TEST_GATEWAY="$EXTERNAL_IP_TEST_LINK_NODE_ADDRESS"
        export OSAC_BMAAS_EXTERNAL_IP_TEST_INTERFACE="$EXTERNAL_IP_CLIENT_ROUTE_INTERFACE"
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
        bmaas_prepare_hosts
        write_provider_inventory
        bmaas_configure_host_ports
        prepare_external_ip_test_link
        configure_nat_gateway_uplink
        prepare_nat_gateway_endpoint
        bmaas_pytest_env
        info "Running the BMaaS-to-AgentlessNet lifecycle against two real virtual hosts..."
        if ! uv run pytest -n 0 tests/e2e/bmaas/agentless_net/test_agentless_net_networking.py; then
            PRESERVE_E2E_RECOVERY_ARTIFACTS=true
            return 1
        fi
    }

    run_bmaas_cleanup() {
        bmaas_pytest_env
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
The runner prepares/reuses OSAC with BMF, two virtual BareMetalHosts, and the
Containerlab fabric. It tests a real BMI network attachment and cleans only its
owned test resources. The two virtual hosts and the SNO/fabric are retained.

Run --cleanup after an interrupted test. Cleanup uses the current deployment
and does not boot or reinstall the cluster.
USAGE
    exit 0
fi
if [[ "$#" -gt 0 && ("$#" -ne 1 || "$1" != --cleanup) ]]; then
    printf 'ERROR: supported arguments are --help and --cleanup\n' >&2
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == --cleanup ]]; then
    exec bash "${script_dir}/vlan-e2e.sh" --bmaas --cleanup
fi
exec bash "${script_dir}/vlan-e2e.sh" --bmaas
