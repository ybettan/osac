#!/usr/bin/env bash
# OSAC-5528/OSAC-6752/OSAC-6202/OSAC-6306/OSAC-6307 AgentlessNet development lab.
#
# The shared vlan-infra.sh prepares the SNO, OSAC with BMF, the Containerlab
# fabric, one reusable virtual BareMetalHost, the bootstrap ExternalIPPool, and
# the single osac-e2e-ci installation tenant. This runner then executes the
# selected AgentlessNet networking suite through Fulfillment and verifies the
# provider datapath with DHCP clients. It does not provision real BMIs.
set -euo pipefail
umask 077

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vlan-infra.sh
source "${REPO_ROOT}/vlan-infra.sh"

VLAN_E2E_SUITE="full"
CLEANUP_MODE=false

usage() {
    cat <<'USAGE'
Usage: bash ./vlan-e2e-agentless.sh [--suite SUITE] [--cleanup]

Suites:
  full              Run the complete ExternalIPPool/ExternalIP, VirtualNetwork, and Subnet/DHCP E2E (default).
  virtual-network   Create, verify, and delete one VirtualNetwork.
  subnet-dhcp       Create a parent VirtualNetwork and run the Subnet/DHCP E2E.
  external-ip-pool  Create, verify, and delete one ExternalIPPool.
  external-ip       Verify ExternalIP allocation and ExternalIPAttachment ingress.
  nat-gateway       Verify generic NATGateway tasks, VN-wide SNAT, and cleanup.

Every normal run ensures the shared lab infrastructure is deployed or reused:
the SNO, OSAC with BMF, the Containerlab fabric, one virtual BareMetalHost, the
bootstrap ExternalIPPool, and the osac-e2e-ci installation tenant. Set
CUMULUS_VERSION and CUMULUS_VX_IMAGE to the exact guest release and its Boxen
image. CUMULUS_LAB_ADMIN_KEY defaults to the ignored local lab key path;
VLAN_E2E_RUN_DIR optionally retains sanitized run evidence.
Use --cleanup with --suite SUITE (or a suite shorthand) as a standalone command
to remove only test-named resources for that suite through Fulfillment. It
uses the existing lab and exits without deploying or initializing it.
Set VLAN_E2E_TAKE_OWNERSHIP=true only when reinstalling into a fresh namespace
that reuses OSAC-owned cluster-scoped CRDs from the prior E2E release.
Set VLAN_E2E_REUSE_INFRA=true when the existing OSAC infrastructure release is
healthy and should be reused without reinstalling operators or MetalLB.
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
  bash ./vlan-e2e-agentless.sh
  bash ./vlan-e2e-agentless.sh --virtual-network
  bash ./vlan-e2e-agentless.sh --subnet-dhcp
  bash ./vlan-e2e-agentless.sh --external-ip-pool
  bash ./vlan-e2e-agentless.sh --external-ip
  bash ./vlan-e2e-agentless.sh --nat-gateway
  bash ./vlan-e2e-agentless.sh --cleanup --suite full
  bash ./vlan-e2e-agentless.sh --cleanup --subnet-dhcp
  bash ./vlan-e2e-agentless.sh --cleanup --virtual-network
  bash ./vlan-e2e-agentless.sh --cleanup --external-ip-pool
  bash ./vlan-e2e-agentless.sh --cleanup --external-ip
  bash ./vlan-e2e-agentless.sh --cleanup --nat-gateway
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
    local task="$1" extra_vars_file="$2" result_file="$3"
    local route token template job_id
    template="${AAP_PREFIX}-${task//_/-}"
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
            --project-revision "$AAP_PROJECT_EXPECTED_REVISION" \
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
    info "AAP ${template} completed as job ${job_id} at project revision ${AAP_PROJECT_EXPECTED_REVISION}."
}

write_network_task_extra_vars() {
    local cr_json="$1" task="$2" output_file="$3"
    jq -ce --arg task "$task" '
      .status.taskInput as $input
      | .status.networkManagers.fabric as $fabric
      | if ($input | type) != "object" or ($fabric | type) != "object"
          or ($fabric.name | type) != "string" or ($fabric.ansibleRole | type) != "string"
        then error("network task input or Fabric Manager reference is missing")
        else {osac_job_vars:($input + {
          task:$task,
          manager:{name:$fabric.name,type:"fabric",ansible_role:$fabric.ansibleRole}
        })}
        end' <<<"$cr_json" >"$output_file" \
        || { printf 'Could not write %s task variables from the stored resource snapshot\n' "$task" >&2; return 1; }
    chmod 0600 "$output_file"
}

replay_network_task_input() {
    local cr_json="$1" task="$2" result_file
    AAP_JOB_RESULT_SEQUENCE=$((AAP_JOB_RESULT_SEQUENCE + 1))
    result_file="$TEMP_DIR/${task}-replay-${AAP_JOB_RESULT_SEQUENCE}.json"
    write_network_task_extra_vars "$cr_json" "$task" "${result_file}.extra-vars.json" \
        || return 1
    run_agentless_net_aap_job "$task" "${result_file}.extra-vars.json" "$result_file" \
        || return 1
    LAST_REPLAYED_AAP_RESULT_FILE="$result_file"
}

write_client_network_attachment_extra_vars() {
    local client="$1" subnet_ref="$2" task="$3" output_file="$4"
    local api_id="${CLIENT_BMI_API_ID[$client]:-}"
    local attachment_uid="${CLIENT_ATTACHMENT_UID[$client]:-}"
    local mac="${CLIENT_PRESERVED_MAC[$client]:-}" subnet_cr subnet_task_input
    [[ -n "$mac" ]] || mac="$(<"$TEMP_DIR/client-${client}.mac")"
    [[ "$api_id" =~ ^[0-9a-f-]{36}$ ]] || {
        printf 'ERROR: DHCP client %s has no valid target API ID\n' "$client" >&2
        return 1
    }
    [[ "$attachment_uid" =~ ^[0-9a-f-]{36}$ ]] || {
        printf 'ERROR: DHCP client %s has no valid NetworkAttachment snapshot UID\n' "$client" >&2
        return 1
    }
    [[ "$subnet_ref" =~ ^[0-9a-f-]{36}$ ]] || {
        printf 'ERROR: DHCP client %s has no valid Fulfillment Subnet UUID\n' "$client" >&2
        return 1
    }
    [[ "$task" == apply_network_attachment || "$task" == query_dhcp_lease \
        || "$task" == delete_network_attachment ]] || {
        printf 'ERROR: unsupported NetworkAttachment task %s\n' "$task" >&2
        return 1
    }
    [[ "$mac" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] || {
        printf 'ERROR: DHCP client %s has no valid physical interface MAC\n' "$client" >&2
        return 1
    }
    subnet_cr="$(subnet_cr_json "$subnet_ref" "")" \
        || return 1
    subnet_task_input="$(jq -ce '.status.taskInput | select(type == "object")' <<<"$subnet_cr")" \
        || { printf 'Subnet %s has no stored task input to build the attachment request\n' "$subnet_ref" >&2; return 1; }
    jq -e --arg id "$subnet_ref" '
      .resource.kind == "Subnet" and .resource.id == $id
      and .virtual_network.kind == "VirtualNetwork"
      and (.ipam.gateway_ipv4 | type == "string")
      and (.ipam.physical_ipv4_cidrs | type == "array")
      and (.tenant | type == "string" and length > 0)' \
      <<<"$subnet_task_input" >/dev/null || {
        printf 'Subnet %s stored task input is not a complete networking snapshot\n' "$subnet_ref" >&2
        return 1
    }
    python3 - "$client" "$OSAC_NAMESPACE" "$api_id" "$attachment_uid" \
        "$subnet_ref" "$mac" "$task" "$subnet_task_input" "$output_file" <<'PY'
import json
import os
import pathlib
import sys

client, namespace, api_id, attachment_uid, subnet_ref, mac, task, raw_subnet_input, output_path = sys.argv[1:]
subnet_input = json.loads(raw_subnet_input)
subnet = subnet_input["resource"]
network_attachment = {
    "subnet": subnet_ref,
    "interface": {"type": "physical", "name": "eth0", "mac_address": mac.lower()},
    "security_group_ids": [],
}
job_vars = {
    "task": task,
    "manager": {
        "name": "agentless_net",
        "type": "fabric",
        "ansible_role": "osac.templates.agentless_net",
    },
    "resource": {
        "apiVersion": "osac.openshift.io/v1alpha1",
        "kind": "NetworkAttachment",
        "id": api_id,
        "metadata": {
            "name": f"baremetalinstance-{api_id}",
            "namespace": namespace,
            "uid": attachment_uid,
            "generation": 1,
        },
        "spec": {
            "target": {"kind": "BareMetalInstance", "id": api_id},
            "subnet": subnet_ref,
        },
    },
    "tenant": subnet_input["tenant"],
    "target": {
        "kind": "BareMetalInstance",
        "id": api_id,
        "host_name": f"osac-e2e-{client}",
    },
    "network_attachment": network_attachment,
    "virtual_network": subnet_input["virtual_network"],
    "subnet": subnet,
    "ipam": subnet_input["ipam"],
}
payload = {"osac_job_vars": job_vars}
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
    CLIENT_BMI_API_ID["$client"]="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    CLIENT_ATTACHMENT_UID["$client"]="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    CLIENT_ATTACHMENT_SUBNET["$client"]="$subnet_ref"
    CLIENT_ATTACHMENT_PENDING["$client"]=true
    extra_vars="$TEMP_DIR/${client}-apply-network-attachment.json"
    AAP_JOB_RESULT_SEQUENCE=$((AAP_JOB_RESULT_SEQUENCE + 1))
    result_file="$TEMP_DIR/${client}-apply-network-attachment-result-${AAP_JOB_RESULT_SEQUENCE}.json"
    write_client_network_attachment_extra_vars "$client" "$subnet_ref" apply_network_attachment "$extra_vars"
    run_agentless_net_aap_job apply_network_attachment "$extra_vars" "$result_file" \
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
    write_client_network_attachment_extra_vars "$client" "$subnet_ref" query_dhcp_lease "$extra_vars"
    run_agentless_net_aap_job query_dhcp_lease "$extra_vars" "$result_file" \
        || die "AAP could not discover the DHCP lease for client ${client}"
    jq -e --arg subnet "$subnet_ref" --arg ip "$lease_ip" \
        --arg mac "$expected_mac" '
      .artifacts.osac_result.dhcp_lease.ip_address == $ip
      and ((.artifacts.osac_result.dhcp_lease.mac_address | ascii_downcase) == $mac)
    ' "$result_file" >/dev/null \
        || die "AAP DHCP lease result for ${client} did not match its Subnet, eth0, MAC, and client lease"
    assert_network_attachment_state "$client"
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
    extra_vars="$TEMP_DIR/${client}-delete-network-attachment.json"
    AAP_JOB_RESULT_SEQUENCE=$((AAP_JOB_RESULT_SEQUENCE + 1))
    result_file="$TEMP_DIR/${client}-delete-network-attachment-result-${AAP_JOB_RESULT_SEQUENCE}.json"
    write_client_network_attachment_extra_vars "$client" "$subnet_ref" delete_network_attachment "$extra_vars" \
        || return 1
    run_agentless_net_aap_job delete_network_attachment "$extra_vars" "$result_file" \
        || return 1
    assert_network_attachment_state_absent "${CLIENT_BMI_API_ID[$client]}"
    CLIENT_ATTACHMENT_ACTIVE["$client"]=false
    CLIENT_ATTACHMENT_PENDING["$client"]=false
    unset "CLIENT_ATTACHMENT_SUBNET[$client]" "CLIENT_BMI_API_ID[$client]" \
        "CLIENT_ATTACHMENT_UID[$client]"
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


def _load_runtime_vlan_modules() -> tuple[Callable[..., set[int]], Callable[..., dict] | None]:
    """Import the runtime parser and, when available, the runner normalizer.

    The lab collects raw switch output over SSH for its baseline snapshot.  On a
    runtime that ships the network-runner switch filter, normalize that output
    through the vendored ``cumulus_vlans`` filter before calling
    ``parse_switch_vlan_exclusions``, which then consumes the runner's
    normalized ``list_vlans`` result exactly like the provisioned AAP runtime.
    Runtimes that predate the filter keep parsing the raw output, so the same
    E2E branch can be rebased on either base.
    """
    repo_root = Path(os.environ["OSAC_REPO_ROOT"]).resolve()
    sys.path.insert(0, str(repo_root / "osac-aap" / "collections"))
    from ansible_collections.osac.templates.plugins.module_utils.agentless_net_subnet import (
        parse_switch_vlan_exclusions,
    )
    from importlib.util import module_from_spec, spec_from_file_location

    vendored = (
        repo_root
        / "osac-aap"
        / "vendor"
        / "ansible_collections"
        / "ansible_network"
        / "network_runner"
        / "plugins"
        / "filter"
        / "switch_state.py"
    )
    if not vendored.is_file():
        return parse_switch_vlan_exclusions, None
    spec = spec_from_file_location("network_runner_switch_state", vendored)
    if spec is None or spec.loader is None:
        raise ValueError(f"vendored network-runner filter plugin is unreadable: {vendored}")
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    if not callable(getattr(module, "cumulus_vlans", None)):
        raise ValueError("vendored network-runner filter plugin lacks cumulus_vlans")
    return parse_switch_vlan_exclusions, module.cumulus_vlans


def _read_json(path: str) -> _JSON:
    try:
        return cast(_JSON, json.loads(Path(path).read_text()))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"could not read JSON file {path}: {error}") from error


def snapshot_vlan_ids(args: argparse.Namespace) -> None:
    switches = _read_json(args.input)
    if not isinstance(switches, list) or not switches:
        raise ValueError("switch snapshot must contain at least one switch")
    parser, normalize_vlan_state = _load_runtime_vlan_modules()
    seen: set[str] = set()
    excluded: set[int] = set()
    for switch in switches:
        if not isinstance(switch, dict) or not isinstance(switch.get("name"), str):
            raise ValueError("switch snapshot entry is malformed")
        if switch["name"] in seen:
            raise ValueError(f"switch snapshot repeats {switch['name']}")
        seen.add(switch["name"])
        raw_state = (
            switch.get("bridge_vlan_output"),
            switch.get("reserved_vlan_output"),
            switch.get("switchd_reserved_vlan_output"),
        )
        # Older runtimes accept the raw provider output; newer ones accept only
        # the normalized list_vlans result.
        state = raw_state if normalize_vlan_state is None else (normalize_vlan_state(*raw_state),)
        excluded.update(parser(*state))
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

    seen_addresses: set[tuple[str, str]] = set()
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
            virtual_network_uid = client["subnet"]["virtual_network_uid"]
            ipam = client["subnet"]["ipam"]
            expected_gateway = ipaddress.IPv4Address(ipam["gateway_ipv4"])
            expected_mask = str(network.netmask)
            physical_ranges = [ipaddress.ip_network(value, strict=True)
                               for value in ipam["physical_ipv4_cidrs"]]
            gateway = ipaddress.IPv4Address(lease["router"])
        except (KeyError, TypeError, ValueError) as error:
            raise ValueError(f"client {name} lease or saved Subnet state is malformed") from error
        if not isinstance(network, ipaddress.IPv4Network) or not isinstance(address, ipaddress.IPv4Address):
            raise ValueError(f"client {name} did not receive IPv4")
        if not isinstance(virtual_network_uid, str) or not virtual_network_uid:
            raise ValueError(f"client {name} Subnet has no parent VirtualNetwork ID")
        if address not in network or not any(address in item for item in physical_ranges):
            raise ValueError(f"client {name} address {address} is outside the saved physical IPAM ranges")
        if address in {network.network_address, network.broadcast_address, expected_gateway}:
            raise ValueError(f"client {name} address {address} conflicts with Subnet reservations")
        vip_ranges = [ipaddress.ip_network(value, strict=True)
                      for value in ipam["lb_vip_ipv4_cidrs"]]
        if any(address in item for item in vip_ranges):
            raise ValueError(f"client {name} address {address} overlaps the saved LB VIP range")
        if lease.get("netmask") != expected_mask or gateway != expected_gateway:
            raise ValueError(f"client {name} DHCP mask or router differs from its saved Subnet")
        address_identity = (virtual_network_uid, str(address))
        if address_identity in seen_addresses:
            raise ValueError(
                f"DHCP assigned duplicate address {address} in VirtualNetwork {virtual_network_uid}"
            )
        seen_addresses.add(address_identity)
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
        --cap-add NET_ADMIN --cap-add NET_RAW "$CLIENT_IMAGE" \
        sh -c 'while true; do sleep 3600; done' >/dev/null
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
    docker cp "$container:/tmp/osac-6752-udhcpc.log" \
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
    service_name="agentless-dhcp-${FIRST_API_ID}"
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
        netnode cat "/etc/agentless-net/dhcp/${FIRST_API_ID}/dnsmasq.conf" || true
        netnode cat "/var/lib/agentless-net/dhcp/${FIRST_API_ID}/dnsmasq.leases" || true
        netnode tail -n 100 "/var/log/agentless-net/dhcp/${FIRST_API_ID}.log" || true
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
    lease_db="/var/lib/agentless-net/dhcp/$FIRST_API_ID/dnsmasq.leases"
    service_log="/var/log/agentless-net/dhcp/$FIRST_API_ID.log"
    capture_this_client=false
    capture_phase=""
    if [[ "$VLAN_E2E_DEBUG" == true && "$client" == b1 ]]; then
        capture_this_client=true
        if [[ -n "${SUBNET_THREE_API_ID:-}" ]]; then
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
                "$capture_phase" "$SUBNET_THREE_API_ID" "$SUBNET_THREE_IPV4_CIDR" \
                "$SUBNET_THREE_VLAN_INTERFACE" "$SUBNET_THREE_AAP_JOB_ID"
        else
            start_dhcp_debug_captures "$container" "$SUBNET_TWO_VLAN_ID" \
                "$capture_phase" "$SUBNET_TWO_API_ID" "$SUBNET_TWO_IPV4_CIDR" \
                "$SECOND_SUBNET_VLAN_INTERFACE" "$SUBNET_TWO_AAP_JOB_ID"
        fi
        docker exec "$container" rm -f /tmp/osac-6752-udhcpc.log
        docker exec -d "$container" sh -c \
            'exec udhcpc -v -f -n -i eth0 -s /usr/local/sbin/osac-udhcpc-hook.sh -t 60 -T 2 >/tmp/osac-6752-udhcpc.log 2>&1'
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
        || die "Could not remove DHCP client ${client} through delete_network_attachment"
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
    gateway="$(jq -er '.ipam.gateway_ipv4 | select(type == "string" and length > 0)' \
        <<<"$subnet_entry")" \
        || die "Saved Subnet state has no IPv4 gateway for client $client"
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
    netnode cat "/var/lib/agentless-net/dhcp/${FIRST_API_ID}/dnsmasq.leases" >"$lease_file" \
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
empty = {
    "schema_version": 0,
    "state_contract": "",
    "identity_semantics": "api-id",
    "virtual_networks": [],
    "subnets": [],
    "external_ip_pools": [],
    "external_ips": [],
    "external_ip_attachments": [],
    "nat_gateways": [],
    "network_attachments": [],
    "network_attachment_ports": [],
    "deleted_resources": [],
}
if not path.exists():
    print(json.dumps(empty, sort_keys=True))
    raise SystemExit(0)
expected_columns = {
    "virtual_networks": ["uid", "tenant_id", "virtual_network_cidr", "namespace_name", "namespace_interface", "host_interface", "transit_cidr", "transit_start", "payload"],
    "subnets": ["uid", "virtual_network_uid", "tenant_id", "vlan_id", "vlan_interface", "ipv4_cidr", "phase", "payload"],
    "external_ip_pools": ["uid", "fulfillment_id", "tenant_id", "ip_family", "ipv4_cidr"],
    "external_ips": ["uid", "fulfillment_id", "tenant_id", "pool_uid", "address"],
    "attachments": ["uid", "fulfillment_id", "tenant_id", "external_ip_uid", "virtual_network_uid", "subnet_uid", "external_address", "phase", "payload"],
    "nat_gateways": ["uid", "fulfillment_id", "tenant_id", "external_ip_uid", "virtual_network_uid", "external_address", "phase", "payload"],
    "network_attachments": ["uid", "tenant_id", "virtual_network_uid", "subnet_uid", "host_name", "interface_name", "mac_address", "address", "phase", "payload"],
    "network_attachment_ports": ["switch_name", "port_name", "attachment_uid"],
    "deleted_resources": ["kind", "uid", "tenant_id"],
    "state_metadata": ["key", "value"],
}
connection = None
try:
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=60)
    connection.execute("BEGIN")
    tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if tables != set(expected_columns):
        raise SystemExit("AgentlessNet SQLite tables do not match the API-ID contract; preserving the file")
    version = connection.execute("PRAGMA user_version").fetchone()[0]
    if version != 1:
        raise SystemExit("AgentlessNet SQLite user_version is not 1; preserving the file")
    for table, columns in expected_columns.items():
        actual = [row[1] for row in connection.execute(f"PRAGMA table_info({table})")]
        if actual != columns:
            raise SystemExit(f"AgentlessNet SQLite {table} columns do not match the API-ID contract; preserving the file")
    metadata = connection.execute("SELECT key, value FROM state_metadata ORDER BY key").fetchall()
    if metadata != [("contract", "network-manager-api-id-v1")]:
        raise SystemExit("AgentlessNet SQLite contract marker does not match; preserving the file")

    def payloads(table):
        return [json.loads(row[0]) for row in connection.execute(f"SELECT payload FROM {table} ORDER BY uid")]

    pools = [
        {"uid": row[0], "api_id": row[0], "fulfillment_id": row[1], "tenant_id": row[2], "ip_family": row[3], "ipv4_cidr": row[4]}
        for row in connection.execute("SELECT uid, fulfillment_id, tenant_id, ip_family, ipv4_cidr FROM external_ip_pools ORDER BY uid")
    ]
    ips = [
        {"uid": row[0], "api_id": row[0], "fulfillment_id": row[1], "tenant_id": row[2], "pool_uid": row[3], "address": row[4]}
        for row in connection.execute("SELECT uid, fulfillment_id, tenant_id, pool_uid, address FROM external_ips ORDER BY uid")
    ]
    attachments = [
        {"uid": row[0], "api_id": row[0], "fulfillment_id": row[1], "tenant_id": row[2], "external_ip_uid": row[3], "virtual_network_uid": row[4], "subnet_uid": row[5], "external_address": row[6], "phase": row[7], "payload": json.loads(row[8])}
        for row in connection.execute("SELECT uid, fulfillment_id, tenant_id, external_ip_uid, virtual_network_uid, subnet_uid, external_address, phase, payload FROM attachments ORDER BY uid")
    ]
    nat_gateways = [
        {"uid": row[0], "api_id": row[0], "fulfillment_id": row[1], "tenant_id": row[2], "external_ip_uid": row[3], "virtual_network_uid": row[4], "external_address": row[5], "phase": row[6], "payload": json.loads(row[7])}
        for row in connection.execute("SELECT uid, fulfillment_id, tenant_id, external_ip_uid, virtual_network_uid, external_address, phase, payload FROM nat_gateways ORDER BY uid")
    ]
    network_attachments = payloads("network_attachments")
    for item in network_attachments:
        item["api_id"] = item["uid"]
    ports = [
        {"switch_name": row[0], "port_name": row[1], "attachment_uid": row[2], "attachment_api_id": row[2]}
        for row in connection.execute("SELECT switch_name, port_name, attachment_uid FROM network_attachment_ports ORDER BY switch_name, port_name")
    ]
    deleted = [
        {"kind": row[0], "uid": row[1], "api_id": row[1], "tenant_id": row[2]}
        for row in connection.execute("SELECT kind, uid, tenant_id FROM deleted_resources ORDER BY kind, uid")
    ]
    snapshot = {
        "schema_version": version,
        "state_contract": metadata[0][1],
        "identity_semantics": "api-id",
        "virtual_networks": payloads("virtual_networks"),
        "subnets": payloads("subnets"),
        "external_ip_pools": pools,
        "external_ips": ips,
        "external_ip_attachments": attachments,
        "nat_gateways": nat_gateways,
        "network_attachments": network_attachments,
        "network_attachment_ports": ports,
        "deleted_resources": deleted,
    }
except (OSError, sqlite3.DatabaseError, json.JSONDecodeError) as error:
    raise SystemExit("AgentlessNet SQLite state is unreadable; preserving it") from error
finally:
    if connection is not None:
        connection.close()
print(json.dumps(snapshot, sort_keys=True))
PY
}

save_current_state() {
    state_snapshot > "$CURRENT_STATE_FILE"
    jq -e '.schema_version == 1
      and .state_contract == "network-manager-api-id-v1"
      and .identity_semantics == "api-id"
      and (.virtual_networks | type == "array")
      and (.subnets | type == "array")
      and (.external_ip_pools | type == "array")
      and (.external_ips | type == "array")
      and (.external_ip_attachments | type == "array")
      and (.nat_gateways | type == "array")
      and (.network_attachments | type == "array")
      and (.network_attachment_ports | type == "array")
      and (.deleted_resources | type == "array")' \
        "$CURRENT_STATE_FILE" >/dev/null \
        || die "AgentlessNet state is not a valid API-ID contract snapshot"
}

assert_baseline_state_unchanged() {
    local collection row identity found
    for collection in virtual_networks subnets external_ip_pools external_ips \
        external_ip_attachments nat_gateways network_attachments network_attachment_ports deleted_resources; do
        while IFS= read -r row; do
            [[ -n "$row" ]] || continue
            found="$(jq -e --arg collection "$collection" --argjson row "$row" \
                'any(.[$collection][]; . == $row)' "$CURRENT_STATE_FILE" >/dev/null 2>&1 && echo true || echo false)"
            identity="$(jq -r '.api_id // .attachment_api_id // .uid // .attachment_uid // "unknown"' <<<"$row")"
            if [[ "$found" != true ]]; then
                printf 'Pre-existing AgentlessNet %s state for API ID %s changed during the test\n' \
                    "$collection" "$identity" >&2
                return 1
            fi
        done < <(jq -cS --arg collection "$collection" '.[$collection][]' "$BASELINE_STATE_FILE")
    done
}

get_state_entry() {
    local api_id="$1"
    save_current_state
    jq -ce --arg id "$api_id" '
      [.virtual_networks[] | select(.uid == $id)]
      | if length == 1 then .[0] else error("expected exactly one state entry for API ID " + $id) end' \
      "$CURRENT_STATE_FILE"
}

get_subnet_state_entry() {
    local api_id="$1"
    save_current_state
    jq -ce --arg id "$api_id" '
      [.subnets[] | select(.uid == $id)]
      | if length == 1 then .[0] else error("expected exactly one Subnet state entry for API ID " + $id) end' \
      "$CURRENT_STATE_FILE"
}

get_network_attachment_state_entry() {
    local api_id="$1"
    save_current_state
    jq -ce --arg id "$api_id" '
      [.network_attachments[] | select(.api_id == $id and .uid == $id)]
      | if length == 1 then .[0] else error("expected one NetworkAttachment state row for API ID " + $id) end' \
      "$CURRENT_STATE_FILE"
}

assert_network_attachment_state() {
    local client="$1" api_id subnet_id mac address subnet_cr subnet_input vn_id entry ports
    api_id="${CLIENT_BMI_API_ID[$client]:-}"
    subnet_id="${CLIENT_ATTACHMENT_SUBNET[$client]:-}"
    mac="$(tr '[:upper:]' '[:lower:]' <"$TEMP_DIR/client-${client}.mac" | tr -d '\r\n')"
    address="$(jq -er '.address' "$TEMP_DIR/client-${client}.lease.json")" \
        || die "DHCP client ${client} has no lease for NetworkAttachment state verification"
    subnet_cr="$(subnet_cr_json "$subnet_id" "")"
    subnet_input="$(jq -ce '.status.taskInput' <<<"$subnet_cr")"
    vn_id="$(jq -er '.virtual_network.id' <<<"$subnet_input")"
    entry="$(get_network_attachment_state_entry "$api_id")"
    jq -e --arg id "$api_id" --arg tenant "$OSAC_TENANT" --arg subnet "$subnet_id" \
        --arg vn "$vn_id" --arg host "osac-e2e-${client}" --arg mac "$mac" --arg address "$address" '
      .api_id == $id and .uid == $id and .tenant_id == $tenant
      and .subnet_uid == $subnet and .virtual_network_uid == $vn
      and .host_name == $host and .interface_name == "eth0"
      and .mac_address == $mac and .address == $address and .phase == "ready"
      and (.ports | type == "array" and length > 0)
      and ([.ports[] | select(.selected == true)] | length == 1)' \
      <<<"$entry" >/dev/null || die "NetworkAttachment ${api_id} state does not match its API snapshots and DHCP lease"
    ports="$(jq -ce --arg id "$api_id" \
        '[.network_attachment_ports[] | select(.attachment_api_id == $id)]' "$CURRENT_STATE_FILE")"
    [[ "$(jq -er 'length' <<<"$ports")" == "$(jq -er '.ports | length' <<<"$entry")" ]] \
        || die "NetworkAttachment ${api_id} saved port claims differ from its state payload"
}

assert_network_attachment_state_absent() {
    local api_id="$1"
    save_current_state
    jq -e --arg id "$api_id" --arg tenant "$OSAC_TENANT" '
      all(.network_attachments[]; .api_id != $id and .uid != $id)
      and all(.network_attachment_ports[]; .attachment_api_id != $id)
      and any(.deleted_resources[]; .kind == "NetworkAttachment" and .api_id == $id and .tenant_id == $tenant)' \
      "$CURRENT_STATE_FILE" >/dev/null \
        || die "NetworkAttachment ${api_id} remains claimed or has no delete tombstone"
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
    local cr_json cr_api_id cr_name backend_id cr_cidr entry transit_cidr namespace_name
    local host_interface namespace_interface namespace_ip host_ip gateway
    local expected_addresses host_address_json namespace_address_json
    local host_link_json namespace_link_json route_json all_routes policy rules

    cr_json="$(virtual_network_cr_json "$fulfillment_id")"
    cr_api_id="$(jq -r '.metadata.labels["osac.openshift.io/virtualnetwork-uuid"]' <<<"$cr_json")"
    cr_name="$(jq -r '.metadata.name' <<<"$cr_json")"
    backend_id="$(jq -r '.status.backendNetworkId // ""' <<<"$cr_json")"
    cr_cidr="$(jq -r '.spec.ipv4Cidr' <<<"$cr_json")"
    [[ "$cr_api_id" == "$fulfillment_id" ]] \
        || die "VirtualNetwork ${fulfillment_id} CR does not retain its API ID"
    [[ -z "$backend_id" || "$backend_id" == "$fulfillment_id" ]] \
        || die "VirtualNetwork ${fulfillment_id} reports an unexpected backend ID"
    [[ "$cr_cidr" == "$expected_cidr" ]] \
        || die "VirtualNetwork ${fulfillment_id} CR CIDR changed from the request"

    entry="$(get_state_entry "$cr_api_id")"
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
    jq -e --arg alias "osac-vn:${cr_api_id}" '
      length == 1 and .[0].ifalias == $alias and .[0].linkinfo.info_kind == "veth"
      and (.[0].flags | index("UP") != null)' <<<"$host_link_json" >/dev/null \
        || die "Host uplink ${host_interface} is not the expected API-ID-owned veth in UP state"
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

    info "Verified VirtualNetwork API ID ${fulfillment_id}, CR ${cr_name}, /31 ${transit_cidr}, gateway ${gateway}"
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
    local cr_json parent_cr subnet_api_id parent_api_id cr_name entry parent_entry ipam
    local vlan_id vlan_interface namespace_name gateway network_address expected_netmask
    local link_json address_json config_path config service_status socket_output

    cr_json="$(subnet_cr_json "$fulfillment_id" "$parent_fulfillment_id")"
    parent_cr="$(virtual_network_cr_json "$parent_fulfillment_id")"
    subnet_api_id="$(jq -er '.metadata.labels["osac.openshift.io/subnet-uuid"]' <<<"$cr_json")"
    parent_api_id="$(jq -er '.metadata.labels["osac.openshift.io/virtualnetwork-uuid"]' <<<"$parent_cr")"
    cr_name="$(jq -r '.metadata.name' <<<"$cr_json")"
    [[ "$subnet_api_id" == "$fulfillment_id" && "$parent_api_id" == "$parent_fulfillment_id" ]] \
        || die "Subnet or VirtualNetwork API ID label does not match its Fulfillment ID"
    [[ "$(jq -r '.spec.ipv4Cidr' <<<"$cr_json")" == "$expected_cidr" ]] \
        || die "Subnet ${fulfillment_id} CR CIDR changed from the request"
    jq -e '.status.conditions | any(.[]?; .type == "Ready" and .status == "True")' \
        <<<"$cr_json" >/dev/null || die "Subnet ${fulfillment_id} has no successful Ready condition"

    entry="$(get_subnet_state_entry "$subnet_api_id")"
    parent_entry="$(get_state_entry "$parent_api_id")"
    ipam="$(jq -ce '.status.taskInput.ipam | select(type == "object")' <<<"$cr_json")" \
        || die "Subnet ${fulfillment_id} has no captured IPAM task input"
    jq -e --arg id "$subnet_api_id" --arg parent "$parent_api_id" --arg tenant "$OSAC_TENANT" \
        --arg cidr "$expected_cidr" '
      ((keys | sort) == ["ipam","ipv4_cidr","phase","tenant_id","trunk_interface","uid","virtual_network_uid","vlan_id","vlan_interface"])
      and .uid == $id
      and .virtual_network_uid == $parent
      and .tenant_id == $tenant
      and .ipv4_cidr == $cidr
      and .phase == "ready"
      and (.vlan_id | type == "number" and . >= 1 and . <= 4094)' \
      <<<"$entry" >/dev/null \
        || die "Saved AgentlessNet Subnet state does not match the Ready Fulfillment resource"
    jq -e --argjson expected "$ipam" '
      .ipam == $expected
      and .status.ipam.gatewayIpv4 == $expected.gateway_ipv4
      and (.status.ipam.overlayIpv4Cidrs // []) == $expected.overlay_ipv4_cidrs
      and (.status.ipam.physicalIpv4Cidrs // []) == $expected.physical_ipv4_cidrs
      and (.status.ipam.lbVipIpv4Cidrs // []) == $expected.lb_vip_ipv4_cidrs' \
      <<<"$(jq -n --argjson status "$(jq -c '.status' <<<"$cr_json")" --argjson state "$entry" \
          '{ipam:$state.ipam,status:$status}')" >/dev/null \
        || die "Subnet ${fulfillment_id} stored and observed IPAM differ"

    vlan_id="$(jq -r '.vlan_id' <<<"$entry")"
    vlan_interface="$(jq -r '.vlan_interface' <<<"$entry")"
    namespace_name="$(jq -r '.namespace_name' <<<"$parent_entry")"
    gateway="$(jq -r '.ipam.gateway_ipv4' <<<"$entry")"
    read -r network_address expected_netmask \
        < <(python3 -c 'import ipaddress,sys; n=ipaddress.ip_network(sys.argv[1], strict=True); print(n.network_address, n.netmask)' "$expected_cidr")
    jq -e --argjson prefix "${expected_cidr#*/}" '
      (.physical_ipv4_cidrs | length > 0)
      and (.overlay_ipv4_cidrs | length == 0)
      and (.lb_vip_ipv4_cidrs | length == 0)' <<<"$ipam" >/dev/null \
        || die "Subnet ${fulfillment_id} IPAM is not all-physical"

    link_json="$(netnode ip netns exec "$namespace_name" ip -j -d link show dev "$vlan_interface")"
    jq -e --arg alias "osac-subnet:${subnet_api_id}" --argjson vlan "$vlan_id" '
      length == 1 and .[0].ifalias == $alias and .[0].linkinfo.info_kind == "vlan"
      and (.[0].linkinfo.info_data.id | tonumber) == $vlan
      and (.[0].flags | index("UP") != null)' <<<"$link_json" >/dev/null \
        || die "Subnet VLAN interface ${vlan_interface} is not API-ID-owned, up, and tagged ${vlan_id}"
    address_json="$(netnode ip netns exec "$namespace_name" ip -j -4 address show dev "$vlan_interface")"
    jq -e --arg ip "$gateway" --argjson prefix "${expected_cidr#*/}" \
        'any(.[].addr_info[]?; .family == "inet" and .local == $ip and .prefixlen == $prefix)' \
        <<<"$address_json" >/dev/null \
        || die "Subnet gateway ${gateway}/${expected_cidr#*/} is absent from ${vlan_interface}"

    config_path="/etc/agentless-net/dhcp/${parent_api_id}/dnsmasq.conf"
    config="$(netnode cat "$config_path")" \
        || die "Per-VirtualNetwork DHCP configuration is missing for Subnet ${fulfillment_id}"
    grep -Fxq "interface=${vlan_interface}" <<<"$config" \
        || die "DHCP does not bind to Subnet interface ${vlan_interface}"
    grep -Fxq "dhcp-range=set:${vlan_interface},${network_address},static,${expected_netmask},12h" <<<"$config" \
        || die "DHCP static range does not match the Subnet IPAM for ${fulfillment_id}"
    grep -Fxq "dhcp-option=tag:${vlan_interface},option:router,${gateway}" <<<"$config" \
        || die "DHCP router option does not match Subnet gateway ${gateway}"
    netnode dnsmasq --test --conf-file="$config_path" >/dev/null 2>&1 \
        || die "dnsmasq rejected the combined DHCP configuration for VirtualNetwork ${parent_uid}"
    service_status="$(netnode supervisorctl -c /etc/agentless-net/supervisord.conf \
        status "agentless-dhcp-${parent_api_id}")"
    grep -Fq ' RUNNING ' <<<"$service_status" \
        || die "Per-VirtualNetwork DHCP Supervisor service is not running"
    socket_output="$(netnode ip netns exec "$namespace_name" ss -H -lun)"
    grep -Eq ':67([[:space:]]|$)' <<<"$socket_output" \
        || die "DHCP UDP port 67 is not listening inside namespace ${namespace_name}"
    assert_vlan_on_switches "$vlan_id" true
    info "Verified Subnet ${fulfillment_id} (${cr_name}), gateway ${gateway}, VLAN ${vlan_id}, and physical IPAM ${expected_cidr}"
}

assert_uid_subnet_state_absent() {
    local uid="$1" parent_uid="$2" namespace_name="$3" vlan_interface="$4" vlan_id="$5"
    local config_path config
    save_current_state
    jq -e --arg id "$uid" 'all(.subnets[]; .uid != $id)
      and any(.deleted_resources[]; .kind == "Subnet" and .api_id == $id)' "$CURRENT_STATE_FILE" >/dev/null \
        || die "Deleted Subnet API ID ${uid} remains in provider state or lacks its tombstone"
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
    local first_json peer_json first_api_id peer_api_id first_entry peer_entry
    local first_ns first_if peer_ip peer_ns peer_if
    first_json="$(virtual_network_cr_json "$first_id")"
    peer_json="$(virtual_network_cr_json "$peer_id")"
    first_api_id="$(jq -er '.metadata.labels["osac.openshift.io/virtualnetwork-uuid"]' <<<"$first_json")"
    peer_api_id="$(jq -er '.metadata.labels["osac.openshift.io/virtualnetwork-uuid"]' <<<"$peer_json")"
    [[ "$first_api_id" != "$peer_api_id" ]] || die "Overlapping VirtualNetworks share an API ID"
    first_entry="$(get_state_entry "$first_api_id")"
    peer_entry="$(get_state_entry "$peer_api_id")"
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
        local vn_cr
        vn_cr="$(jq -c '.items[0]' <<<"$current")"
        job_id="$(network_task_job_id "$vn_cr" delete_virtual_network)"
        job_state="$(network_task_state "$vn_cr" delete_virtual_network)"
        [[ "$job_state" != Failed && "$job_state" != Cancelled ]] \
            || die "AAP delete_virtual_network job failed while deleting test-owned API ID ${id}"
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
    EXTERNAL_IP_POOL_INITIAL_ENTRY="$(get_external_ip_pool_state_entry \
        "$EXTERNAL_IP_POOL_API_ID" "$EXTERNAL_IP_POOL_ID")"
    jq -e --arg uid "$EXTERNAL_IP_POOL_API_ID" --arg id "$EXTERNAL_IP_POOL_ID" \
        --arg cidr "$EXTERNAL_IP_POOL_CIDR" '
      .uid == $uid
      and .fulfillment_id == $id
      and .tenant_id == "shared"
      and .ip_family == "IPv4"
      and .ipv4_cidr == $cidr' <<<"$EXTERNAL_IP_POOL_INITIAL_ENTRY" >/dev/null \
        || die "Saved AgentlessNet ExternalIPPool identity does not match the CR"
    [[ -n "$EXTERNAL_IP_POOL_CREATE_AAP_JOB_ID" ]] \
        || die "No successful AAP provision job ID was recorded for ExternalIPPool ${EXTERNAL_IP_POOL_ID}"
    info "ExternalIPPool ${EXTERNAL_IP_POOL_ID} is Ready; provider state is keyed by API ID; AAP job ${EXTERNAL_IP_POOL_CREATE_AAP_JOB_ID}"
    assert_baseline_state_unchanged
}

delete_external_ip_pool() {
    local request_file="${TEMP_DIR}/external-ip-pool-delete.request.json"
    local response_file="${TEMP_DIR}/external-ip-pool-delete.response.json"
    local error_file="${TEMP_DIR}/external-ip-pool-delete.error.json"
    local current_entry

    [[ "$EXTERNAL_IP_POOL_PENDING_CLEANUP" == true \
        && -n "$EXTERNAL_IP_POOL_ID" && -n "$EXTERNAL_IP_POOL_API_ID" ]] \
        || die "ExternalIPPool test identity is incomplete before deletion"
    current_entry="$(get_external_ip_pool_state_entry \
        "$EXTERNAL_IP_POOL_API_ID" "$EXTERNAL_IP_POOL_ID")"
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
    wait_for_external_ip_pool_removed "$EXTERNAL_IP_POOL_ID" "$EXTERNAL_IP_POOL_API_ID" \
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
    jq -e --arg id "$uid" 'all(.virtual_networks[]; .uid != $id)
      and any(.deleted_resources[]; .kind == "VirtualNetwork" and .api_id == $id)' "$CURRENT_STATE_FILE" >/dev/null \
        || die "Deleted VirtualNetwork API ID ${uid} remains in provider state or lacks its tombstone"
    jq -e --arg id "$uid" 'all(.subnets[]; .virtual_network_uid != $id)' "$CURRENT_STATE_FILE" >/dev/null \
        || die "Deleted VirtualNetwork API ID ${uid} still has Subnet provider state"
    namespace_list="$(netnode ip netns list)"
    if awk -v name="$namespace_name" '$1 == name { found=1 } END { exit !found }' <<<"$namespace_list"; then
        die "Deleted namespace ${namespace_name} remains on the test node"
    fi
    if netnode ip -j -d link show dev "$host_interface" >/dev/null 2>&1; then
        die "Deleted API-ID-owned host uplink ${host_interface} remains on the test node"
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
    if not isinstance(network, ipaddress.IPv4Network) or network.prefixlen > 28 or str(network) != value:
        raise SystemExit(f"{label} must be a canonical IPv4 subnet of /28 or larger")
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
    if not isinstance(network, ipaddress.IPv4Network) or network.prefixlen > 28 or str(network) != value:
        raise SystemExit(f"{label} must be a canonical IPv4 subnet of /28 or larger")
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
    local id cr api_id job_id
    create_subnet "$name" "$parent_id" "$cidr" "$output_file" \
        || die "Could not create NATGateway test Subnet ${name}"
    id="$(<"${output_file}.id")"
    cr="$(wait_for_subnet_cr_created "$id" "$parent_id")"
    api_id="$(jq -er '.metadata.labels["osac.openshift.io/subnet-uuid"]' <<<"$cr")" \
        || die "NATGateway test Subnet ${id} has no API ID label"
    wait_for_subnet_ready "$id" "$parent_id"
    cr="$(subnet_cr_json "$id" "$parent_id")"
    job_id="$(network_task_job_id "$cr" create_subnet)" \
        || die "NATGateway test Subnet ${id} has no AAP provision job"
    wait_for_subnet_aap_provision_success "$id" "$parent_id" "$job_id"
    assert_subnet_state "$id" "$parent_id" "$cidr"
    LAST_NAT_GATEWAY_SUBNET_ID="$id"
    LAST_NAT_GATEWAY_SUBNET_UID="$api_id"
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

resolve_test_subnet_28_cidr() {
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
    if not isinstance(candidate, ipaddress.IPv4Network) or candidate.prefixlen != 28 or str(candidate) != override:
        raise SystemExit("SUBNET_THREE_IPV4_CIDR must be a canonical IPv4 /28")
    if not candidate.subnet_of(parent) or candidate.overlaps(transit) or candidate.overlaps(used):
        raise SystemExit("SUBNET_THREE_IPV4_CIDR overlaps an excluded network")
else:
    candidate = next((network for network in parent.subnets(new_prefix=28)
                      if not network.overlaps(transit) and not network.overlaps(used)), None)
    if candidate is None:
        raise SystemExit("VirtualNetwork CIDR has no free /28 test Subnet outside transit and active Subnets")
print(candidate)
PY
    )" || die "Could not select a non-overlapping /28 test Subnet"
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
    FIRST_API_ID="$(jq -er '.metadata.labels["osac.openshift.io/virtualnetwork-uuid"]' <<<"$FIRST_CR")"
    FIRST_AAP_JOB_ID="$(network_task_job_id "$FIRST_CR" create_virtual_network)"
    wait_for_aap_provision_success "$FIRST_FULFILLMENT_ID" "$FIRST_AAP_JOB_ID"
    FIRST_ENTRY="$(get_state_entry "$FIRST_API_ID")"
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
    entry="$(get_state_entry "$FIRST_API_ID")"
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
    EXTERNAL_IP_ATTACHMENT_SUBNET_API_ID="$(jq -er '.metadata.labels["osac.openshift.io/subnet-uuid"]' \
        <<<"$EXTERNAL_IP_ATTACHMENT_SUBNET_CR")" \
        || die "ExternalIPAttachment test Subnet has no API ID label"
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
    EXTERNAL_IP_SYNTHETIC_TARGET_ID="${CLIENT_BMI_API_ID[$client]:-}"
    EXTERNAL_IP_SYNTHETIC_TARGET_UID="$EXTERNAL_IP_SYNTHETIC_TARGET_ID"
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
        "$FIRST_API_ID" "$FIRST_NAMESPACE_NAME" "$FIRST_HOST_INTERFACE"
    save_current_state
    assert_baseline_state_unchanged
}

run_subnet_dhcp_checks() {
info "Snapshotting existing switch VLAN memberships and reserved ranges before creating sibling Subnets..."
FIRST_ENTRY="$(get_state_entry "$FIRST_API_ID")"
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
    SUBNET_ONE_API_ID="$(jq -er '.metadata.labels["osac.openshift.io/subnet-uuid"]' <<<"$SUBNET_ONE_CR")"
SUBNET_ONE_AAP_JOB_ID="$(network_task_job_id "$SUBNET_ONE_CR" create_subnet)"
wait_for_subnet_aap_provision_success "$SUBNET_ONE_FULFILLMENT_ID" \
    "$FIRST_FULFILLMENT_ID" "$SUBNET_ONE_AAP_JOB_ID"
assert_subnet_state "$SUBNET_ONE_FULFILLMENT_ID" "$FIRST_FULFILLMENT_ID" \
    "$SUBNET_ONE_IPV4_CIDR"

create_subnet "$SUBNET_TWO_NAME" "$FIRST_FULFILLMENT_ID" \
    "$SUBNET_TWO_IPV4_CIDR" "$SUBNET_TWO_OUTPUT"
SUBNET_TWO_FULFILLMENT_ID="$(cat "${SUBNET_TWO_OUTPUT}.id")"
wait_for_subnet_ready "$SUBNET_TWO_FULFILLMENT_ID" "$FIRST_FULFILLMENT_ID"
SUBNET_TWO_CR="$(subnet_cr_json "$SUBNET_TWO_FULFILLMENT_ID" "$FIRST_FULFILLMENT_ID")"
    SUBNET_TWO_API_ID="$(jq -er '.metadata.labels["osac.openshift.io/subnet-uuid"]' <<<"$SUBNET_TWO_CR")"
SUBNET_TWO_AAP_JOB_ID="$(network_task_job_id "$SUBNET_TWO_CR" create_subnet)"
wait_for_subnet_aap_provision_success "$SUBNET_TWO_FULFILLMENT_ID" \
    "$FIRST_FULFILLMENT_ID" "$SUBNET_TWO_AAP_JOB_ID"
assert_subnet_state "$SUBNET_ONE_FULFILLMENT_ID" "$FIRST_FULFILLMENT_ID" \
    "$SUBNET_ONE_IPV4_CIDR"
assert_subnet_state "$SUBNET_TWO_FULFILLMENT_ID" "$FIRST_FULFILLMENT_ID" \
    "$SUBNET_TWO_IPV4_CIDR"
SUBNET_ONE_ENTRY="$(get_subnet_state_entry "$SUBNET_ONE_API_ID")"
SUBNET_TWO_ENTRY="$(get_subnet_state_entry "$SUBNET_TWO_API_ID")"
SUBNET_ONE_VLAN_ID="$(jq -r '.vlan_id' <<<"$SUBNET_ONE_ENTRY")"
SUBNET_TWO_VLAN_ID="$(jq -r '.vlan_id' <<<"$SUBNET_TWO_ENTRY")"
[[ "$SUBNET_ONE_VLAN_ID" != "$SUBNET_TWO_VLAN_ID" ]] \
    || die "Sibling Subnets share the same provider VLAN ID"
assert_new_vlans_avoid_baseline "$SUBNET_ONE_VLAN_ID" "$SUBNET_TWO_VLAN_ID"
printf 'Subnet Fulfillment UUIDs: %s %s\n' \
    "$SUBNET_ONE_FULFILLMENT_ID" "$SUBNET_TWO_FULFILLMENT_ID"
printf 'Subnet API IDs: %s %s\n' "$SUBNET_ONE_API_ID" "$SUBNET_TWO_API_ID"
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
    restart "agentless-dhcp-${FIRST_API_ID}"
service_ready=false
for ((attempt = 1; attempt <= 30; attempt++)); do
    if netnode supervisorctl -c /etc/agentless-net/supervisord.conf \
        status "agentless-dhcp-${FIRST_API_ID}" | grep -Fq ' RUNNING '; then
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

info "Removing only the test-owned Subnet interface and replaying the stored create_subnet input..."
FIRST_SUBNET_ENTRY_BEFORE_RETRY="$(jq -cS '.' <<<"$SUBNET_ONE_ENTRY")"
FIRST_SUBNET_INPUT_BEFORE_REPLAY="$(jq -cS '.status.taskInput' <<<"$SUBNET_ONE_CR")"
FIRST_SUBNET_JOBS_BEFORE_REPLAY="$(jq -cS '.status.jobs' <<<"$SUBNET_ONE_CR")"
link_json="$(netnode ip netns exec "$FIRST_PARENT_NAMESPACE" ip -j -d link show dev "$FIRST_SUBNET_VLAN_INTERFACE")"
jq -e --arg alias "osac-subnet:${SUBNET_ONE_API_ID}" --argjson vlan "$SUBNET_ONE_VLAN_ID" '
  length == 1 and .[0].ifalias == $alias and .[0].linkinfo.info_kind == "vlan"
  and (.[0].linkinfo.info_data.id | tonumber) == $vlan' <<<"$link_json" >/dev/null \
    || die "Refusing to remove a Subnet interface without the test UID ownership alias"
netnode ip netns exec "$FIRST_PARENT_NAMESPACE" ip link delete dev "$FIRST_SUBNET_VLAN_INTERFACE"
replay_network_task_input "$SUBNET_ONE_CR" create_subnet \
    || die "AAP could not replay the stored Subnet task input"
SUBNET_ONE_CR="$(subnet_cr_json "$SUBNET_ONE_FULFILLMENT_ID" "$FIRST_FULFILLMENT_ID")"
[[ "$(jq -cS '.status.taskInput' <<<"$SUBNET_ONE_CR")" == "$FIRST_SUBNET_INPUT_BEFORE_REPLAY" \
    && "$(jq -cS '.status.jobs' <<<"$SUBNET_ONE_CR")" == "$FIRST_SUBNET_JOBS_BEFORE_REPLAY" ]] \
    || die "Replaying the Subnet task input changed operator task input or job history"
assert_subnet_state "$SUBNET_ONE_FULFILLMENT_ID" "$FIRST_FULFILLMENT_ID" \
    "$SUBNET_ONE_IPV4_CIDR"
SUBNET_ONE_ENTRY="$(get_subnet_state_entry "$SUBNET_ONE_API_ID")"
[[ "$(jq -cS '.' <<<"$SUBNET_ONE_ENTRY")" == "$FIRST_SUBNET_ENTRY_BEFORE_RETRY" ]] \
    || die "Subnet task-input replay did not preserve its API-ID-owned VLAN and DHCP state"
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
assert_uid_subnet_state_absent "$SUBNET_TWO_API_ID" "$FIRST_API_ID" \
    "$FIRST_PARENT_NAMESPACE" "$SECOND_SUBNET_VLAN_INTERFACE" "$SUBNET_TWO_VLAN_ID"
assert_deleted_subnet_lease_removed "$SUBNET_TWO_CLIENT_MAC" "$FIRST_API_ID"
[[ "$(get_subnet_state_entry "$SUBNET_ONE_API_ID" | jq -cS '.')" == \
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

info "Verifying the API rejects a /30 Subnet before provider allocation..."
resolve_test_subnet_28_cidr "$VIRTUAL_NETWORK_IPV4_CIDR" "$FIRST_TRANSIT_CIDR" \
    "$SUBNET_ONE_IPV4_CIDR"
SUBNET_THIRTY_CIDR="$(python3 -c 'import ipaddress,sys; print(next(ipaddress.ip_network(sys.argv[1], strict=True).subnets(new_prefix=30)))' \
    "$SUBNET_THREE_IPV4_CIDR")"
SUBNET_THIRTY_NAME="${VIRTUAL_NETWORK_NAME}-subnet-30-rejected"
SUBNET_THIRTY_OUTPUT="${TEMP_DIR}/create-subnet-30-rejected.out"
SUBNETS_BEFORE_SMALL_REJECTION="$(state_snapshot | jq -cS '.subnets')"
if create_subnet "$SUBNET_THIRTY_NAME" "$FIRST_FULFILLMENT_ID" \
    "$SUBNET_THIRTY_CIDR" "$SUBNET_THIRTY_OUTPUT"; then
    die "Fulfillment accepted unsupported /30 Subnet ${SUBNET_THIRTY_CIDR}"
fi
[[ ! -e "${SUBNET_THIRTY_OUTPUT}.id" ]] \
    || die "Rejected /30 Subnet unexpectedly returned a Fulfillment ID"
SUBNET_THIRTY_ITEMS="$(cleanup_cli_list_json subnet \
    "this.metadata.name == \"${SUBNET_THIRTY_NAME}\"")"
[[ "$(jq -er 'length' <<<"$SUBNET_THIRTY_ITEMS")" == 0 ]] \
    || die "Rejected /30 Subnet was persisted in Fulfillment"
[[ "$(state_snapshot | jq -cS '.subnets')" == "$SUBNETS_BEFORE_SMALL_REJECTION" ]] \
    || die "Rejected /30 Subnet allocated provider state"

info "Creating a /28 Subnet and verifying its physical DHCP allocation..."
SUBNET_THREE_OUTPUT="${TEMP_DIR}/create-subnet-28.out"
create_subnet "$SUBNET_THREE_NAME" "$FIRST_FULFILLMENT_ID" \
    "$SUBNET_THREE_IPV4_CIDR" "$SUBNET_THREE_OUTPUT"
SUBNET_THREE_FULFILLMENT_ID="$(cat "${SUBNET_THREE_OUTPUT}.id")"
wait_for_subnet_ready "$SUBNET_THREE_FULFILLMENT_ID" "$FIRST_FULFILLMENT_ID"
SUBNET_THREE_CR="$(subnet_cr_json "$SUBNET_THREE_FULFILLMENT_ID" "$FIRST_FULFILLMENT_ID")"
SUBNET_THREE_API_ID="$(jq -er '.metadata.labels["osac.openshift.io/subnet-uuid"]' <<<"$SUBNET_THREE_CR")"
SUBNET_THREE_AAP_JOB_ID="$(network_task_job_id "$SUBNET_THREE_CR" create_subnet)"
wait_for_subnet_aap_provision_success "$SUBNET_THREE_FULFILLMENT_ID" \
    "$FIRST_FULFILLMENT_ID" "$SUBNET_THREE_AAP_JOB_ID"
assert_subnet_state "$SUBNET_THREE_FULFILLMENT_ID" "$FIRST_FULFILLMENT_ID" \
    "$SUBNET_THREE_IPV4_CIDR"
SUBNET_THREE_ENTRY="$(get_subnet_state_entry "$SUBNET_THREE_API_ID")"
SUBNET_THREE_VLAN_ID="$(jq -r '.vlan_id' <<<"$SUBNET_THREE_ENTRY")"
SUBNET_THREE_VLAN_INTERFACE="$(jq -r '.vlan_interface' <<<"$SUBNET_THREE_ENTRY")"
[[ "$(jq -e --arg cidr "$SUBNET_THREE_IPV4_CIDR" \
    '.ipam.physical_ipv4_cidrs == [$cidr]' <<<"$SUBNET_THREE_ENTRY")" == true ]] \
    || die "The /28 Subnet does not use its supplied physical address range"
[[ "$(jq -c '.ipam.overlay_ipv4_cidrs' <<<"$SUBNET_THREE_ENTRY")" == '[]' \
    && "$(jq -c '.ipam.lb_vip_ipv4_cidrs' <<<"$SUBNET_THREE_ENTRY")" == '[]' ]] \
    || die "The /28 Subnet IPAM plan includes a nonphysical range"
assert_new_vlans_avoid_baseline "$SUBNET_ONE_VLAN_ID" "$SUBNET_THREE_VLAN_ID"
attach_client_to_subnet b1 "$SUBNET_THREE_FULFILLMENT_ID"
start_dhcp_client b1
discover_client_dhcp_lease b1
write_client_lease_expectations "b1=$SUBNET_THREE_ENTRY"
assert_real_client_leases b1
info "DHCP client B1 received a usable address from the /28 physical range."
assert_client_gateway b1 "$SUBNET_THREE_ENTRY"
printf 'Subnet /28 lease: client=%s address=%s gateway=%s VLAN=%s\n' \
    "$(<"$TEMP_DIR/client-b1.mac")" "$(jq -r '.address' "$TEMP_DIR/client-b1.lease.json")" \
    "$(jq -r '.ipam.gateway_ipv4' <<<"$SUBNET_THREE_ENTRY")" "$SUBNET_THREE_VLAN_ID"

info "Detaching B1 and deleting the /28 Subnet while Subnet A remains usable..."
detach_dhcp_client b1
delete_subnet_by_id "$SUBNET_THREE_FULFILLMENT_ID"
THIRD_SUBNET_DELETE_AAP_JOB_ID="$LAST_SUBNET_DELETE_AAP_JOB_ID"
assert_uid_subnet_state_absent "$SUBNET_THREE_API_ID" "$FIRST_API_ID" \
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
assert_uid_subnet_state_absent "$SUBNET_ONE_API_ID" "$FIRST_API_ID" \
    "$FIRST_PARENT_NAMESPACE" "$FIRST_SUBNET_VLAN_INTERFACE" "$SUBNET_ONE_VLAN_ID"
assert_virtual_network_dhcp_absent "$FIRST_API_ID" "$FIRST_PARENT_NAMESPACE"
netnode test ! -e "/etc/agentless-net/dhcp/${FIRST_API_ID}/dnsmasq.conf" \
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
        SECOND_API_ID="$(jq -er '.metadata.labels["osac.openshift.io/virtualnetwork-uuid"]' <<<"$SECOND_CR")"
        SECOND_AAP_JOB_ID="$(network_task_job_id "$SECOND_CR" create_virtual_network)"
        wait_for_aap_provision_success "$SECOND_FULFILLMENT_ID" "$SECOND_AAP_JOB_ID"
        SECOND_ENTRY="$(get_state_entry "$SECOND_API_ID")"
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
    first_entry="$(get_state_entry "$FIRST_API_ID")"
    second_entry="$(get_state_entry "$SECOND_API_ID")"
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
    netnode cat "/var/lib/agentless-net/dhcp/${FIRST_API_ID}/dnsmasq.leases" \
        >"$lease_file" \
        || die "Could not read the primary NATGateway dnsmasq lease file"
    if [[ -n "${SECOND_API_ID:-}" && "$SECOND_API_ID" != "$FIRST_API_ID" ]]; then
        netnode cat "/var/lib/agentless-net/dhcp/${SECOND_API_ID}/dnsmasq.leases" \
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
    local peer_namespace_name
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

    FIRST_ENTRY="$(get_state_entry "$FIRST_API_ID")"
    SECOND_ENTRY="$(get_state_entry "$SECOND_API_ID")"
    jq -e --arg uid "$FIRST_API_ID" --arg peer "$SECOND_API_ID" \
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
    NAT_GATEWAY_ONE_UID="$NAT_GATEWAY_ONE_ID"
    NAT_GATEWAY_ONE_INITIAL_STATE="$(nat_gateway_assert_provider_state \
        "$NAT_GATEWAY_ONE_ID" "$NAT_GATEWAY_ONE_UID" "$FIRST_API_ID" \
        "$EXTERNAL_IP_ONE_UID" "$EXTERNAL_IP_ONE_ADDRESS")"
    nat_gateway_assert_provider_rules "$NAT_GATEWAY_ONE_ID" "$NAT_GATEWAY_ONE_UID" \
        "$EXTERNAL_IP_ONE_ADDRESS" "$NAT_GATEWAY_ONE_INITIAL_STATE"
    FIRST_ENTRY="$(get_state_entry "$FIRST_API_ID")"
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
    NAT_GATEWAY_TWO_UID="$NAT_GATEWAY_TWO_ID"
    NAT_GATEWAY_TWO_INITIAL_STATE="$(nat_gateway_assert_provider_state \
        "$NAT_GATEWAY_TWO_ID" "$NAT_GATEWAY_TWO_UID" "$SECOND_API_ID" \
        "$EXTERNAL_IP_TWO_UID" "$EXTERNAL_IP_TWO_ADDRESS")"
    nat_gateway_assert_provider_rules "$NAT_GATEWAY_TWO_ID" "$NAT_GATEWAY_TWO_UID" \
        "$EXTERNAL_IP_TWO_ADDRESS" "$NAT_GATEWAY_TWO_INITIAL_STATE"
    assert_private_vn_isolation "$FIRST_FULFILLMENT_ID" "$SECOND_FULFILLMENT_ID"

    nat_gateway_create_subnets
    NAT_GATEWAY_ONE_INITIAL_STATE="$(nat_gateway_assert_provider_state \
        "$NAT_GATEWAY_ONE_ID" "$NAT_GATEWAY_ONE_UID" "$FIRST_API_ID" \
        "$EXTERNAL_IP_ONE_UID" "$EXTERNAL_IP_ONE_ADDRESS")"
    nat_gateway_assert_provider_rules "$NAT_GATEWAY_ONE_ID" "$NAT_GATEWAY_ONE_UID" \
        "$EXTERNAL_IP_ONE_ADDRESS" "$NAT_GATEWAY_ONE_INITIAL_STATE"
    NAT_GATEWAY_TWO_INITIAL_STATE="$(nat_gateway_assert_provider_state \
        "$NAT_GATEWAY_TWO_ID" "$NAT_GATEWAY_TWO_UID" "$SECOND_API_ID" \
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

    info "Replaying NATGateway A's stored task input with the same API ID..."
    nat_gateway_replay_and_verify "$NAT_GATEWAY_ONE_ID" "$FIRST_FULFILLMENT_ID" "$EXTERNAL_IP_ONE_ID"
    NAT_GATEWAY_ONE_INITIAL_STATE="$(nat_gateway_assert_provider_state \
        "$NAT_GATEWAY_ONE_ID" "$NAT_GATEWAY_ONE_UID" "$FIRST_API_ID" \
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
        "$NAT_GATEWAY_ONE_UID" "$FIRST_API_ID" "$EXTERNAL_IP_ONE_UID" \
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
    assert_uid_subnet_state_absent "$NAT_GATEWAY_SUBNET_TWO_UID" "$FIRST_API_ID" \
        "$FIRST_NAMESPACE_NAME" \
        "$(jq -er '.vlan_interface' <<<"$NAT_GATEWAY_SUBNET_TWO_ENTRY")" \
        "$(jq -er '.vlan_id' <<<"$NAT_GATEWAY_SUBNET_TWO_ENTRY")"
    after_state="$(nat_gateway_assert_provider_state "$NAT_GATEWAY_ONE_ID" \
        "$NAT_GATEWAY_ONE_UID" "$FIRST_API_ID" "$EXTERNAL_IP_ONE_UID" \
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
    assert_uid_subnet_state_absent "$NAT_GATEWAY_SUBNET_ONE_UID" "$FIRST_API_ID" \
        "$FIRST_NAMESPACE_NAME" \
        "$(jq -er '.vlan_interface' <<<"$NAT_GATEWAY_SUBNET_ONE_ENTRY")" \
        "$(jq -er '.vlan_id' <<<"$NAT_GATEWAY_SUBNET_ONE_ENTRY")"
    after_state="$(nat_gateway_assert_provider_state "$NAT_GATEWAY_ONE_ID" \
        "$NAT_GATEWAY_ONE_UID" "$FIRST_API_ID" "$EXTERNAL_IP_ONE_UID" \
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
    # The full suite creates both VirtualNetworks before this lifecycle, so
    # derive the peer namespace here instead of relying on the suite that
    # created it.
    peer_namespace_name="$(jq -er '.namespace_name' <<<"$(get_state_entry "$SECOND_API_ID")")"
    assert_uid_subnet_state_absent "$NAT_GATEWAY_PEER_SUBNET_UID" "$SECOND_API_ID" \
        "$peer_namespace_name" \
        "$(jq -er '.vlan_interface' <<<"$NAT_GATEWAY_PEER_SUBNET_ENTRY")" \
        "$(jq -er '.vlan_id' <<<"$NAT_GATEWAY_PEER_SUBNET_ENTRY")"
    cleanup_nat_gateway_endpoint \
        || die "Could not remove the NATGateway test endpoint after provider cleanup"
    external_ip_pool_wait_for_delta 0
    save_current_state
    assert_baseline_state_unchanged
    info "NATGateway SNAT, source observation, stored-input replay, Subnet churn, peer isolation, and cleanup passed."
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
FIRST_API_ID="$(jq -er '.metadata.labels["osac.openshift.io/virtualnetwork-uuid"]' <<<"$FIRST_CR")"
FIRST_CR_NAME="$(jq -er '.metadata.name' <<<"$FIRST_CR")"
SECOND_API_ID="$(jq -er '.metadata.labels["osac.openshift.io/virtualnetwork-uuid"]' <<<"$SECOND_CR")"
FIRST_AAP_JOB_ID="$(network_task_job_id "$FIRST_CR" create_virtual_network)"
SECOND_AAP_JOB_ID="$(network_task_job_id "$SECOND_CR" create_virtual_network)"
info "AAP create job IDs: ${FIRST_AAP_JOB_ID}, ${SECOND_AAP_JOB_ID}"
printf 'create Fulfillment UUIDs: %s %s\n' "$FIRST_FULFILLMENT_ID" "$SECOND_FULFILLMENT_ID"
printf 'create VirtualNetwork API IDs: %s %s\n' "$FIRST_API_ID" "$SECOND_API_ID"
printf 'create AAP job IDs: %s %s\n' "$FIRST_AAP_JOB_ID" "$SECOND_AAP_JOB_ID"

info "Checking exact /31 endpoints, namespace gateway reachability, and host forwarding rules..."
assert_virtual_network_state "$FIRST_FULFILLMENT_ID" "$VIRTUAL_NETWORK_IPV4_CIDR" "$SECOND_FULFILLMENT_ID"
assert_virtual_network_state "$SECOND_FULFILLMENT_ID" "$VIRTUAL_NETWORK_IPV4_CIDR" "$FIRST_FULFILLMENT_ID"
assert_private_vn_isolation "$FIRST_FULFILLMENT_ID" "$SECOND_FULFILLMENT_ID"
save_current_state
assert_baseline_state_unchanged

FIRST_ENTRY_BEFORE_REHYDRATE="$(get_state_entry "$FIRST_API_ID" | jq -cS '.')"
FIRST_TASK_INPUT_BEFORE_REPLAY="$(jq -cS '.status.taskInput' <<<"$FIRST_CR")"
FIRST_JOBS_BEFORE_REPLAY="$(jq -cS '.status.jobs' <<<"$FIRST_CR")"
FIRST_NAMESPACE_NAME="$(jq -r '.namespace_name' <<<"$(get_state_entry "$FIRST_API_ID")")"
FIRST_HOST_INTERFACE="$(jq -r '.uplink.host_interface' <<<"$(get_state_entry "$FIRST_API_ID")")"
info "Removing only the first test API ID's transient namespace and uplink, then replaying its stored task input..."
netnode ip netns delete "$FIRST_NAMESPACE_NAME"
# Deleting a network namespace can remove the host side of its veth pair too.
if netnode ip link show dev "$FIRST_HOST_INTERFACE" >/dev/null 2>&1; then
    netnode ip link delete dev "$FIRST_HOST_INTERFACE"
fi
save_current_state
[[ "$(jq -cS --arg uid "$FIRST_API_ID" '.virtual_networks[] | select(.uid == $uid)' "$CURRENT_STATE_FILE")" == "$FIRST_ENTRY_BEFORE_REHYDRATE" ]] \
    || die "Removing runtime objects changed the persisted API-ID allocation"
replay_network_task_input "$FIRST_CR" create_virtual_network \
    || die "AAP could not replay the stored VirtualNetwork task input"
FIRST_REPLAY_JOB_ID="$(jq -er '.job_id' "$LAST_REPLAYED_AAP_RESULT_FILE")"
FIRST_CR="$(virtual_network_cr_json "$FIRST_FULFILLMENT_ID")"
[[ "$(jq -cS '.status.taskInput' <<<"$FIRST_CR")" == "$FIRST_TASK_INPUT_BEFORE_REPLAY" \
    && "$(jq -cS '.status.jobs' <<<"$FIRST_CR")" == "$FIRST_JOBS_BEFORE_REPLAY" \
    && "$(network_ready_condition_status "$FIRST_CR")" == True ]] \
    || die "Direct task-input replay changed the stored input, operator job history, or Ready condition"
info "Replayed VirtualNetwork task input as AAP job ${FIRST_REPLAY_JOB_ID}; operator job history stayed intact."
[[ "$(get_state_entry "$FIRST_API_ID" | jq -cS '.')" == "$FIRST_ENTRY_BEFORE_REHYDRATE" ]] \
    || die "Task-input replay allocated a different transit link or changed the API-ID mapping"
assert_virtual_network_state "$FIRST_FULFILLMENT_ID" "$VIRTUAL_NETWORK_IPV4_CIDR" "$SECOND_FULFILLMENT_ID"
assert_private_vn_isolation "$FIRST_FULFILLMENT_ID" "$SECOND_FULFILLMENT_ID"
save_current_state
assert_baseline_state_unchanged
    run_subnet_dhcp_checks
if [[ "$SUITE_USES_EXTERNAL_IP_ATTACHMENT" == true ]]; then
    info "Preparing a synthetic DHCP target on the test VirtualNetwork for ExternalIP ingress checks..."
    create_external_ip_attachment_test_network_and_client
    info "Running ExternalIP allocation, stored-input replay, ingress, detach, and capacity checks..."
    run_external_ip_lifecycle
    delete_subnet_by_id "$EXTERNAL_IP_ATTACHMENT_SUBNET_ID"
fi
if [[ "$SUITE_USES_NAT_GATEWAY" == true ]]; then
    info "Running local NATGateway SNAT, source observation, task-input replay, and Subnet lifecycle checks..."
    run_nat_gateway_lifecycle
fi
info "Deleting the first test VirtualNetwork and verifying its peer remains provisioned..."
FIRST_PEER_ENTRY="$(get_state_entry "$SECOND_API_ID" | jq -cS '.')"
delete_virtual_network_by_id "$FIRST_FULFILLMENT_ID"
FIRST_DELETE_AAP_JOB_ID="$LAST_DELETE_AAP_JOB_ID"
printf 'delete AAP job ID (first VN): %s\n' "$FIRST_DELETE_AAP_JOB_ID"
assert_uid_provider_state_absent "$FIRST_API_ID" "$FIRST_NAMESPACE_NAME" "$FIRST_HOST_INTERFACE"
[[ "$(get_state_entry "$SECOND_API_ID" | jq -cS '.')" == "$FIRST_PEER_ENTRY" ]] \
    || die "Deleting the first VirtualNetwork altered its peer's provider entry"
assert_virtual_network_state "$SECOND_FULFILLMENT_ID" "$VIRTUAL_NETWORK_IPV4_CIDR"
save_current_state
assert_baseline_state_unchanged

info "Deleting the remaining test VirtualNetwork and checking final cleanup..."
SECOND_NAMESPACE_NAME="$(jq -r '.namespace_name' <<<"$(get_state_entry "$SECOND_API_ID")")"
SECOND_HOST_INTERFACE="$(jq -r '.uplink.host_interface' <<<"$(get_state_entry "$SECOND_API_ID")")"
delete_virtual_network_by_id "$SECOND_FULFILLMENT_ID"
SECOND_DELETE_AAP_JOB_ID="$LAST_DELETE_AAP_JOB_ID"
printf 'delete AAP job ID (peer VN): %s\n' "$SECOND_DELETE_AAP_JOB_ID"
assert_uid_provider_state_absent "$SECOND_API_ID" "$SECOND_NAMESPACE_NAME" "$SECOND_HOST_INTERFACE"
save_current_state
assert_baseline_state_unchanged

EXTERNAL_IP_POOL_ENTRY_AFTER_VN_DELETE="$(get_external_ip_pool_state_entry \
    "$EXTERNAL_IP_POOL_API_ID" "$EXTERNAL_IP_POOL_ID")"
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

on_exit() {
    local status=$?
    local cleanup_status=0
    local provider_cleanup_allowed=true
    trap - EXIT
    set +e
    if [[ "$SUITE_USES_SUBNET_DHCP" == true && "$VLAN_E2E_DEBUG" == true ]] \
        && ! export_dhcp_debug_artifacts; then
        printf 'ERROR: could not preserve the requested DHCP debug artifacts\n' >&2
        cleanup_status=1
    fi
    if [[ "${CLEANUP_MODE:-false}" != true && "$SUITE_USES_NAT_GATEWAY" == true \
        && "$provider_cleanup_allowed" == true ]]; then
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
    vlan_infra_on_exit_tail "$status" "$cleanup_status"
}
trap on_exit EXIT

vlan_infra_init

if [[ "$CLEANUP_MODE" == true ]]; then
    vlan_infra_prepare_cleanup
    prepare_suite_cleanup
    info "Cleanup is prepared; the exit handler will delete selected resources in dependency order."
    exit 0
fi

vlan_infra_up

step "STEP 5 OF 5: Running the ${VLAN_E2E_SUITE} E2E suite"

# Preserve the full pre-test JSON snapshot. Only the UIDs created by this run
# are asserted or removed; any unrelated node state remains untouched.
if [[ "$SUITE_USES_SUBNET_DHCP" == true ]]; then
    write_agentless_e2e_helpers
fi
HOST_IP_FORWARDING_BEFORE="$(netnode sysctl -n net.ipv4.ip_forward)"
state_snapshot > "$BASELINE_STATE_FILE"
jq -e '(.schema_version == 0 or .schema_version == 1)
      and (.identity_semantics == "api-id")
      and (.schema_version == 0 or .state_contract == "network-manager-api-id-v1")
      and (.virtual_networks | type == "array")
      and (.subnets | type == "array")
      and (.external_ip_pools | type == "array")
      and (.external_ips | type == "array")
      and (.external_ip_attachments | type == "array")
      and (.nat_gateways | type == "array")
      and (.network_attachments | type == "array")
      and (.network_attachment_ports | type == "array")
      and (.deleted_resources | type == "array")' \
    "$BASELINE_STATE_FILE" >/dev/null \
    || die "AgentlessNet state must be empty or use the API-ID contract before the test starts"


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
assert_legacy_provider_state_unchanged \
    || die "The legacy AgentlessNet database was not preserved"
case "$VLAN_E2E_SUITE" in
    full)
        info "Local AgentlessNet VLAN lab E2E passed: ExternalIP allocation/replay/release and synthetic-target ExternalIPAttachment ingress, VN-wide NATGateway SNAT and observed source address, independent Subnet lifecycle, overlapping VirtualNetworks, stored-input replay, internal VLAN exclusion, AAP DHCP attachment and lease lookup for test clients, gateway and same-Subnet L2 traffic across leaves, DHCP service restart, /28 allocation with /30 rejection, peer-preserving lifecycle, and ordered cleanup. Remote BGP convergence and physical hardware are not covered."
        ;;
    virtual-network)
        info "VirtualNetwork-only E2E passed: one VN was created, verified, deleted, and cleaned up."
        ;;
    subnet-dhcp)
        info "Subnet/DHCP-only E2E passed: Subnet, stored-input replay, DHCP client, /28 allocation and /30 rejection, and temporary parent VN cleanup passed."
        ;;
    external-ip-pool)
        info "ExternalIPPool-only E2E passed: one pool was created, verified, deleted, and cleaned up."
        ;;
    external-ip)
        info "ExternalIP E2E passed: two addresses were allocated, stored task input replay kept the reservation, the synthetic DHCP target replied through both ExternalIPs, attachment replay and peer preservation passed, attachments were detached before EIPs and network resources, pool capacity was restored, and test network resources were deleted. The external client uses a test-only static route; upstream BGP advertisement is not exercised."
        ;;
    nat-gateway)
        info "Local NATGateway VLAN lab E2E passed: the VN CIDR was SNATed to the allocated ExternalIP with a transit exemption, Subnet creation and deletion left gateway state unchanged, stored task input replay retained provider identity, the peer NATGateway remained unchanged, and cleanup completed. Remote BGP convergence, service restarts, and physical hardware are not covered."
        ;;
esac
