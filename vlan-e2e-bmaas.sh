#!/usr/bin/env bash
# Run the real BMaaS-to-AgentlessNet journey on the shared VLAN development lab.
#
# The shared vlan-infra.sh prepares the SNO, OSAC with BMF, the Containerlab
# fabric, one reusable virtual BareMetalHost, the bootstrap ExternalIPPool, and
# the single osac-e2e-ci installation tenant. This runner then creates one
# BareMetalInstance in that existing tenant, attaches it to the tenant's default
# Subnet, and verifies that DHCP assigned it an address inside that Subnet. The
# only other resources it creates are the inputs a BMI needs (a disk image, an
# instance type, an SSH-key Secret, and a catalog item) and it deletes all of
# them with the instance. The virtual host and the SNO/fabric are retained.
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

# One BMI is enough to prove the Fulfillment -> BMaaS -> AgentlessNet path. The
# tenant and its default networking must already exist, so this runner never
# creates a VirtualNetwork, Subnet, or SecurityGroup of its own.
BMAAS_PREFIX_BASE="agentless-bmaas"
BMAAS_RUN_ID="${OSAC_BMAAS_RUN_ID:-agentless-bmaas}"
BMAAS_RUN_LABEL="${OSAC_BMAAS_RUN_LABEL:-$(date -u +%Y%m%d%H%M%S)}"
BMAAS_PREFIX="${BMAAS_PREFIX_BASE}-${BMAAS_RUN_LABEL}"
BMAAS_DISK_IMAGE_SOURCE_REF="${BMAAS_DISK_IMAGE_SOURCE_REF:-oci://quay.io/osac-project/fedora-cloud-bmi:44}"
BMAAS_BMI_TEMPLATE="${BMAAS_BMI_TEMPLATE:-bm-host-provisioning}"
BMAAS_DEFAULT_VIRTUAL_NETWORK="${BMAAS_DEFAULT_VIRTUAL_NETWORK:-default}"
BMAAS_HOST_SELECTOR_LABEL="osac.openshift.io/vlan-e2e-host"
BMAAS_HOST_SELECTOR_VALUE="agentless-lab"
BMAAS_HOST_LABEL="${BMAAS_HOST_LABEL:-${BMAAS_HOST_SELECTOR_LABEL}=${BMAAS_HOST_SELECTOR_VALUE}}"
BMAAS_NETWORK_PORT="data-0:fabric:Ethernet:10Gbps"
BMAAS_INSTANCE_WAIT_ATTEMPTS="${BMAAS_INSTANCE_WAIT_ATTEMPTS:-180}"
BMAAS_INSTANCE_WAIT_DELAY="${BMAAS_INSTANCE_WAIT_DELAY:-10}"
BMAAS_REMOVAL_WAIT_ATTEMPTS="${BMAAS_REMOVAL_WAIT_ATTEMPTS:-120}"
BMAAS_REMOVAL_WAIT_DELAY="${BMAAS_REMOVAL_WAIT_DELAY:-5}"

bmaas_journal_path() {
    printf '%s/%s.json' \
        "${VLAN_E2E_RUN_DIR:-${REPO_ROOT}/.artifacts/agentless-net-bmaas/runs}" \
        "$BMAAS_RUN_ID"
}

bmaas_journal_write() {
    local path temp errors_json
    path="$(bmaas_journal_path)"
    mkdir -p "$(dirname "$path")" || return 1
    chmod 0700 "$(dirname "$path")" 2>/dev/null || true
    errors_json="$(printf '%s\n' ${BMAAS_CLEANUP_ERRORS[@]+"${BMAAS_CLEANUP_ERRORS[@]}"} \
        | jq -R . | jq -s 'map(select(length > 0))')" || return 1
    temp="${path}.tmp.$$"
    jq -n \
        --arg prefix "$BMAAS_PREFIX" \
        --arg run_label "$BMAAS_RUN_LABEL" \
        --arg run_id "$BMAAS_RUN_ID" \
        --arg tenant "$OSAC_TENANT" \
        --arg subnet_id "${BMAAS_SUBNET_ID:-}" \
        --arg subnet_name "${BMAAS_SUBNET_NAME:-}" \
        --arg subnet_cidr "${BMAAS_SUBNET_CIDR:-}" \
        --arg disk_image_id "${BMAAS_DISK_IMAGE_ID:-}" \
        --arg disk_image_name "${BMAAS_DISK_IMAGE_NAME:-}" \
        --arg instance_type_id "${BMAAS_INSTANCE_TYPE_ID:-}" \
        --arg instance_type_name "${BMAAS_INSTANCE_TYPE_NAME:-}" \
        --arg secret_name "${BMAAS_SECRET_NAME:-}" \
        --arg catalog_id "${BMAAS_CATALOG_ID:-}" \
        --arg catalog_name "${BMAAS_CATALOG_NAME:-}" \
        --arg bmi_id "${BMAAS_BMI_ID:-}" \
        --arg bmi_name "${BMAAS_BMI_NAME:-}" \
        --arg bmi_cr_name "${BMAAS_BMI_CR_NAME:-}" \
        --arg bmi_ip "${BMAAS_BMI_IP:-}" \
        --arg bmh_name "${BMAAS_BMH_NAME:-}" \
        --arg bmh_namespace "${BMAAS_BMH_NAMESPACE:-}" \
        --argjson cleaned "${BMAAS_CLEANED:-false}" \
        --argjson cleanup_errors "$errors_json" \
        '{
          prefix: $prefix,
          run_label: $run_label,
          run_id: $run_id,
          tenant: $tenant,
          subnet: {id: $subnet_id, name: $subnet_name, cidr: $subnet_cidr},
          inputs: {
            disk_image: {id: $disk_image_id, name: $disk_image_name},
            instance_type: {id: $instance_type_id, name: $instance_type_name},
            secret: {name: $secret_name},
            catalog_item: {id: $catalog_id, name: $catalog_name}
          },
          bmi: {
            id: $bmi_id,
            name: $bmi_name,
            cr_name: $bmi_cr_name,
            ip_address: $bmi_ip,
            bmh_name: $bmh_name,
            bmh_namespace: $bmh_namespace
          },
          cleaned: $cleaned,
          cleanup_errors: $cleanup_errors
        }' >"$temp" || return 1
    mv "$temp" "$path" && chmod 0600 "$path"
}

bmaas_journal_load() {
    local journal="$1" json
    json="$(cat "$journal")" || return 1
    BMAAS_PREFIX="$(jq -er '.prefix // ""' <<<"$json")" || return 1
    BMAAS_RUN_LABEL="$(jq -er '.run_label // ""' <<<"$json")" || return 1
    BMAAS_SUBNET_ID="$(jq -er '.subnet.id // ""' <<<"$json")" || return 1
    BMAAS_SUBNET_NAME="$(jq -er '.subnet.name // ""' <<<"$json")" || return 1
    BMAAS_SUBNET_CIDR="$(jq -er '.subnet.cidr // ""' <<<"$json")" || return 1
    BMAAS_DISK_IMAGE_ID="$(jq -er '.inputs.disk_image.id // ""' <<<"$json")" || return 1
    BMAAS_DISK_IMAGE_NAME="$(jq -er '.inputs.disk_image.name // ""' <<<"$json")" || return 1
    BMAAS_INSTANCE_TYPE_ID="$(jq -er '.inputs.instance_type.id // ""' <<<"$json")" || return 1
    BMAAS_INSTANCE_TYPE_NAME="$(jq -er '.inputs.instance_type.name // ""' <<<"$json")" || return 1
    BMAAS_SECRET_NAME="$(jq -er '.inputs.secret.name // ""' <<<"$json")" || return 1
    BMAAS_CATALOG_ID="$(jq -er '.inputs.catalog_item.id // ""' <<<"$json")" || return 1
    BMAAS_CATALOG_NAME="$(jq -er '.inputs.catalog_item.name // ""' <<<"$json")" || return 1
    BMAAS_BMI_ID="$(jq -er '.bmi.id // ""' <<<"$json")" || return 1
    BMAAS_BMI_NAME="$(jq -er '.bmi.name // ""' <<<"$json")" || return 1
    BMAAS_BMI_CR_NAME="$(jq -er '.bmi.cr_name // ""' <<<"$json")" || return 1
    BMAAS_BMI_IP="$(jq -er '.bmi.ip_address // ""' <<<"$json")" || return 1
    BMAAS_BMH_NAME="$(jq -er '.bmi.bmh_name // ""' <<<"$json")" || return 1
    BMAAS_BMH_NAMESPACE="$(jq -er '.bmi.bmh_namespace // ""' <<<"$json")" || return 1
    BMAAS_CLEANED="$(jq -r 'if .cleaned == true then "true" else "false" end' <<<"$json")" \
        || return 1
    BMAAS_CLEANUP_ERRORS=()
    local error
    while IFS= read -r error; do
        [[ -z "$error" ]] || BMAAS_CLEANUP_ERRORS+=("$error")
    done < <(jq -r '.cleanup_errors[]?' <<<"$json")
}

bmaas_json_list() {
    # The CLI prints a single object for one match, an array otherwise, and
    # can concatenate documents. Normalize all of those to one JSON array.
    jq -s 'if length == 1 and (.[0] | type) == "array" then .[0] else . end'
}

bmaas_cli() {
    "$CLI_BIN" --config "$CLI_CONFIG_DIR" --tenant "$OSAC_TENANT" "$@"
}

bmaas_private_cli() {
    "$CLI_BIN" --config "$BMAAS_PRIVATE_CLI_CONFIG_DIR" "$@"
}

bmaas_private_cli_login() {
    local api token_script
    [[ -n "${CLI_BIN:-}" && -x "$CLI_BIN" && -n "${CLI_CONFIG_DIR:-}" && -d "$CLI_CONFIG_DIR" ]] \
        || die "The Fulfillment CLI is not prepared for the BMaaS private API"
    [[ -n "${CLUSTER_DOMAIN:-}" && -n "${AAP_API_CA_FILE:-}" && -f "$AAP_API_CA_FILE" ]] \
        || die "The cluster domain or Fulfillment CA bundle is unavailable"
    api="https://fulfillment-internal-api-${OSAC_NAMESPACE}.${CLUSTER_DOMAIN}"
    # Disk images and instance types are private-API resources that only the
    # platform admin identity may create. The public tenant identity keeps
    # the least privilege for the instance itself.
    token_script="oc create token admin -n ${OSAC_NAMESPACE} --duration=1h --as system:admin"
    BMAAS_PRIVATE_CLI_CONFIG_DIR="${TEMP_DIR}/bmaas-private-cli"
    mkdir -p "$BMAAS_PRIVATE_CLI_CONFIG_DIR" \
        || die "Could not create the BMaaS private CLI configuration directory"
    chmod 0700 "$BMAAS_PRIVATE_CLI_CONFIG_DIR" \
        || die "Could not restrict the BMaaS private CLI configuration directory"
    BMAAS_PRIVATE_API="$api"
    BMAAS_PRIVATE_TOKEN_SCRIPT="$token_script"
    # The private CLI config is disposable, so keep the headless file secret
    # store and avoid a locked D-Bus keyring blocking CLI startup.
    export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/nonexistent}"
    "$CLI_BIN" --config "$BMAAS_PRIVATE_CLI_CONFIG_DIR" login --private "$api" \
        --ca-file "$AAP_API_CA_FILE" --token-script "$token_script" >/dev/null \
        || die "Could not log in to the private Fulfillment API as the admin identity"
    info "Prepared a private-API admin session for the test-owned BMI inputs."
}

bmaas_default_subnet_json() {
    local subnets
    subnets="$(bmaas_cli get subnets -o json)" \
        || die "Could not list the ${OSAC_TENANT} Subnets"
    bmaas_json_list <<<"$subnets" | jq -ce \
        --arg vn "$BMAAS_DEFAULT_VIRTUAL_NETWORK" '
          map(select((.spec.virtual_network.name // "") == $vn))
          | if length != 1 then
              error("expected exactly one Subnet in VirtualNetwork " + $vn)
            else .[0] end
          | if (.status.state // "") != "SUBNET_STATE_READY" then
              error("the tenant default Subnet is not READY: " + (.status.state // "unknown"))
            else {id: .id, name: .metadata.name, cidr: .spec.ipv4_cidr} end'
}

# Convert a dotted IPv4 address to its 32-bit integer value. Returns
# non-zero for anything that is not a valid address.
bmaas_ipv4_to_int() {
    local ip="$1" a b c d
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    a=$((10#${BASH_REMATCH[1]}))
    b=$((10#${BASH_REMATCH[2]}))
    c=$((10#${BASH_REMATCH[3]}))
    d=$((10#${BASH_REMATCH[4]}))
    ((a <= 255 && b <= 255 && c <= 255 && d <= 255)) || return 1
    printf '%s\n' $(((a << 24) | (b << 16) | (c << 8) | d))
}

# Report whether an IPv4 address belongs to a CIDR block.
bmaas_ipv4_in_cidr() {
    local ip="$1" cidr="$2" address network prefix mask
    [[ "$cidr" =~ ^(.+)/([0-9]{1,2})$ ]] || return 1
    network="${BASH_REMATCH[1]}"
    prefix=$((10#${BASH_REMATCH[2]}))
    ((prefix <= 32)) || return 1
    address="$(bmaas_ipv4_to_int "$ip")" || return 1
    network="$(bmaas_ipv4_to_int "$network")" || return 1
    if ((prefix == 0)); then
        mask=0
    else
        mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
    fi
    (( (address & mask) == (network & mask) ))
}

bmaas_instance_json() {
    local bmi_id="$1" objects
    objects="$(bmaas_cli get baremetalinstances "$bmi_id" -o json 2>/dev/null)" || return 1
    bmaas_json_list <<<"$objects"
}

bmaas_validate_run_identity() {
    [[ "$BMAAS_RUN_ID" =~ ^[A-Za-z0-9._-]{1,80}$ ]] \
        || die "OSAC_BMAAS_RUN_ID must be a safe file name"
    # The longest generated object name appends "-catalog" to this suffix,
    # so bound it well below the 63-character DNS label limit.
    [[ "$BMAAS_RUN_LABEL" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] \
        || die "OSAC_BMAAS_RUN_LABEL must be a lowercase DNS label suffix of at most 31 characters"
}

bmaas_pin_prepared_host() {
    local name
    # The pool can contain other virtual hosts that have no fabric port
    # mapping, so allocate only the host this runner prepared and wired.
    name="$(jq -er '.hosts[0].name' "$(bmaas_host_state_file)")" \
        || die "Could not read the prepared BMaaS host from the host state file"
    info "Pinning the BareMetalInstance to the prepared host ${name}..."
    oc label baremetalhost "$name" -n "${OSAC_BMH_NAMESPACE:-host-inventory}" \
        "${BMAAS_HOST_SELECTOR_LABEL}=${BMAAS_HOST_SELECTOR_VALUE}" --overwrite >/dev/null \
        || die "Could not label the prepared BareMetalHost ${name}"
}

bmaas_create_inputs() {
    local key_dir
    BMAAS_DISK_IMAGE_NAME="${BMAAS_PREFIX}-image"
    BMAAS_INSTANCE_TYPE_NAME="${BMAAS_PREFIX}-type"
    BMAAS_SECRET_NAME="${BMAAS_PREFIX}-key"
    BMAAS_CATALOG_NAME="${BMAAS_PREFIX}-catalog"

    info "Creating the shared disk image ${BMAAS_DISK_IMAGE_NAME}..."
    local output
    output="$(bmaas_private_cli create diskimage \
        --name "$BMAAS_DISK_IMAGE_NAME" \
        --source-ref "$BMAAS_DISK_IMAGE_SOURCE_REF" \
        --architecture amd64)" \
        || die "Could not create the test-owned disk image ${BMAAS_DISK_IMAGE_NAME}"
    BMAAS_DISK_IMAGE_ID="$(sed -n "s/.*'\([^']*\)'.*/\1/p" <<<"$output" | head -n 1)"
    [[ -n "$BMAAS_DISK_IMAGE_ID" ]] \
        || die "Could not parse the disk image identifier from: ${output}"
    bmaas_journal_write || die "Could not record the test-owned disk image"

    info "Creating the shared bare-metal instance type ${BMAAS_INSTANCE_TYPE_NAME}..."
    output="$(bmaas_private_cli --tenant shared create baremetalinstancetype \
        --name "$BMAAS_INSTANCE_TYPE_NAME" \
        --cpu-architecture amd64 \
        --cpu-cores 8 \
        --cpu-threads-per-core 1 \
        --memory-total-gb 16 \
        --network-port "$BMAAS_NETWORK_PORT" \
        --host-label "$BMAAS_HOST_LABEL")" \
        || die "Could not create the test-owned instance type ${BMAAS_INSTANCE_TYPE_NAME}"
    BMAAS_INSTANCE_TYPE_ID="$(sed -n "s/.*'\([^']*\)'.*/\1/p" <<<"$output" | head -n 1)"
    [[ -n "$BMAAS_INSTANCE_TYPE_ID" ]] \
        || die "Could not parse the instance type identifier from: ${output}"
    bmaas_journal_write || die "Could not record the test-owned instance type"

    key_dir="${TEMP_DIR}/${BMAAS_PREFIX}-key"
    mkdir -m 0700 "$key_dir" || die "Could not create the BMaaS SSH key directory"
    ssh-keygen -q -t ed25519 -N "" -C "$BMAAS_PREFIX" -f "${key_dir}/id_ed25519" \
        || die "Could not generate the test-owned BMaaS SSH key"
    info "Registering the tenant SSH public key ${BMAAS_SECRET_NAME}..."
    bmaas_cli create secret --name "$BMAAS_SECRET_NAME" --type ssh-public-key \
        --from-file "public_key=${key_dir}/id_ed25519.pub" >/dev/null \
        || die "Could not create the test-owned SSH key Secret ${BMAAS_SECRET_NAME}"
    bmaas_journal_write || die "Could not record the test-owned SSH key Secret"

    # A catalog item is mandatory for a BMI. The tenant service account may
    # not author catalog items, so the admin identity creates this shared,
    # test-owned item; the instance still runs in the tenant.
    info "Creating the shared bare-metal instance catalog item ${BMAAS_CATALOG_NAME}..."
    output="$(bmaas_private_cli create baremetalinstancecatalogitem \
        --name "$BMAAS_CATALOG_NAME" \
        --template "$BMAAS_BMI_TEMPLATE" \
        --title "Agentless BMaaS E2E ${BMAAS_RUN_LABEL}" \
        --description "Temporary catalog item for the AgentlessNet BMaaS E2E" \
        --published)" \
        || die "Could not create the test-owned catalog item ${BMAAS_CATALOG_NAME}"
    BMAAS_CATALOG_ID="$(sed -n "s/.*'\([^']*\)'.*/\1/p" <<<"$output" | head -n 1)"
    [[ -n "$BMAAS_CATALOG_ID" ]] \
        || die "Could not parse the catalog item identifier from: ${output}"
    bmaas_journal_write || die "Could not record the test-owned catalog item"
}

bmaas_create_instance() {
    local output
    BMAAS_BMI_NAME="${BMAAS_PREFIX}-bmi"
    # The test-owned disk image lives in the shared tenant, and a bare name
    # resolves only in the owner tenant, so select the shared scope. The
    # instance type is shared the same way (the CLI sets that selector).
    output="$(bmaas_cli create baremetalinstance \
        --name "$BMAAS_BMI_NAME" \
        --catalog-item "$BMAAS_CATALOG_NAME" \
        --instance-type "$BMAAS_INSTANCE_TYPE_NAME" \
        --ssh-key "$BMAAS_SECRET_NAME" \
        --disk-image "$BMAAS_DISK_IMAGE_NAME" \
        --set "disk_image.shared=true" \
        --network-attachment "subnet=${BMAAS_SUBNET_ID},interface=data-0,primary")" \
        || die "Could not create the test-owned BareMetalInstance ${BMAAS_BMI_NAME}"
    BMAAS_BMI_ID="$(sed -n "s/.*'\([^']*\)'.*/\1/p" <<<"$output" | head -n 1)"
    [[ -n "$BMAAS_BMI_ID" ]] \
        || die "Could not parse the BareMetalInstance identifier from: ${output}"
    bmaas_journal_write || die "Could not record the test-owned BareMetalInstance"
}

bmaas_wait_for_instance() {
    local bmi_id="$1" attempt state
    for ((attempt = 1; attempt <= BMAAS_INSTANCE_WAIT_ATTEMPTS; attempt++)); do
        state="$(bmaas_instance_json "$bmi_id" \
            | jq -r 'if length == 1 then (.[0].status.state // "") else "" end')" || return 1
        case "$state" in
            BARE_METAL_INSTANCE_STATE_RUNNING)
                return 0
                ;;
            *FAILED*)
                printf 'ERROR: BareMetalInstance %s entered %s\n' "$bmi_id" "$state" >&2
                return 1
                ;;
        esac
        sleep "$BMAAS_INSTANCE_WAIT_DELAY"
    done
    printf 'ERROR: timed out after %s attempts waiting for BareMetalInstance %s to reach RUNNING\n' \
        "$BMAAS_INSTANCE_WAIT_ATTEMPTS" "$bmi_id" >&2
    return 1
}

bmaas_assert_instance_host() {
    local bmi_id="$1" cr_json cr_name host_ref bmh_json expected_mac observed_mac discovered_macs
    if ! cr_json="$(oc get baremetalinstances -A \
        -l "$(baremetal_instance_label_selector "$bmi_id")" -o json --request-timeout=20s)"; then
        printf 'ERROR: Kubernetes API failed while looking up BareMetalInstance %s\n' "$bmi_id" >&2
        return 1
    fi
    # The controller names the CR itself (bmi-<uuid>), so ownership is the
    # Fulfillment UUID label plus the tenant annotation, not the CR name.
    jq -e --arg id "$bmi_id" --arg tenant "$OSAC_TENANT" '
      (.items | length) == 1
      and .items[0].metadata.labels["osac.openshift.io/baremetalinstance-uuid"] == $id
      and .items[0].metadata.annotations["osac.openshift.io/tenant"] == $tenant' \
        <<<"$cr_json" >/dev/null || {
        printf 'ERROR: BareMetalInstance %s did not resolve to one test-owned CR in tenant %s\n' \
            "$bmi_id" "$OSAC_TENANT" >&2
        return 1
    }
    cr_name="$(jq -r '.items[0].metadata.name' <<<"$cr_json")"
    host_ref="$(jq -r '.items[0].spec.externalHostID // ""' <<<"$cr_json")"
    if [[ "$host_ref" != */* ]]; then
        printf 'ERROR: BareMetalInstance %s has no allocated external host yet\n' "$bmi_id" >&2
        return 1
    fi
    BMAAS_BMI_CR_NAME="$cr_name"
    BMAAS_BMH_NAMESPACE="${host_ref%%/*}"
    BMAAS_BMH_NAME="${host_ref#*/}"
    if ! bmh_json="$(oc get baremetalhost "$BMAAS_BMH_NAME" -n "$BMAAS_BMH_NAMESPACE" -o json)"; then
        printf 'ERROR: could not read BareMetalHost %s/%s\n' \
            "$BMAAS_BMH_NAMESPACE" "$BMAAS_BMH_NAME" >&2
        return 1
    fi
    if ! expected_mac="$(jq -er --arg name "$BMAAS_BMH_NAME" \
        '.hosts[] | select(.name == $name) | .fabric_mac' "$(bmaas_host_state_file)")"; then
        printf 'ERROR: BMH %s is not one of the prepared test hosts\n' "$BMAAS_BMH_NAME" >&2
        return 1
    fi
    if ! observed_mac="$(jq -r '.metadata.annotations["osac.openshift.io/interface-macs"] // "{}"' \
        <<<"$bmh_json" | jq -er '.["data-0"]')"; then
        printf 'ERROR: BMH %s has no data-0 interface MAC mapping\n' "$BMAAS_BMH_NAME" >&2
        return 1
    fi
    if [[ "${observed_mac,,}" != "${expected_mac,,}" ]]; then
        printf 'ERROR: BMH %s data-0 mapping %s does not match the fabric NIC %s\n' \
            "$BMAAS_BMH_NAME" "$observed_mac" "$expected_mac" >&2
        return 1
    fi
    discovered_macs="$(jq -r '[.status.hardware.nics[]?.mac // empty | ascii_downcase] | join(" ")' <<<"$bmh_json")"
    if [[ " ${discovered_macs} " != *" ${expected_mac,,} "* ]]; then
        printf 'ERROR: BMH %s inspection does not include the fabric NIC %s\n' \
            "$BMAAS_BMH_NAME" "$expected_mac" >&2
        return 1
    fi
    info "BareMetalInstance ${bmi_id} is allocated to prepared BMH ${BMAAS_BMH_NAME} with fabric NIC ${expected_mac}."
    bmaas_journal_write || {
        printf 'ERROR: could not record the allocated BareMetalHost\n' >&2
        return 1
    }
}

bmaas_assert_instance_ip() {
    local bmi_id="$1" ip
    if ! ip="$(bmaas_instance_json "$bmi_id" | jq -er \
        --arg subnet_id "$BMAAS_SUBNET_ID" \
        --arg subnet_name "$BMAAS_SUBNET_NAME" '
      (.[0].status.network_attachment_statuses // [])
      | map(select(.interface == "data-0"))
      | if length != 1 then
          error("expected exactly one data-0 network attachment status")
        else .[0] end
      | select((.subnet_ref // "") == ""
          or .subnet_ref == $subnet_id
          or .subnet_ref == $subnet_name)
      | .ip_address // ""')"; then
        printf 'ERROR: BareMetalInstance %s reached RUNNING without a data-0 address on Subnet %s\n' \
            "$bmi_id" "$BMAAS_SUBNET_ID" >&2
        return 1
    fi
    if [[ -z "$ip" ]]; then
        printf 'ERROR: BareMetalInstance %s has no address on its primary attachment\n' "$bmi_id" >&2
        return 1
    fi
    if ! bmaas_ipv4_to_int "$ip" >/dev/null; then
        printf 'ERROR: BareMetalInstance %s reported an invalid IPv4 address: %s\n' "$bmi_id" "$ip" >&2
        return 1
    fi
    if ! bmaas_ipv4_in_cidr "$ip" "$BMAAS_SUBNET_CIDR"; then
        printf 'ERROR: BareMetalInstance %s address %s is outside the tenant Subnet %s\n' \
            "$bmi_id" "$ip" "$BMAAS_SUBNET_CIDR" >&2
        return 1
    fi
    BMAAS_BMI_IP="$ip"
    bmaas_journal_write || {
        printf 'ERROR: could not record the BareMetalInstance address\n' >&2
        return 1
    }
    info "BareMetalInstance ${bmi_id} received ${ip} inside the tenant Subnet ${BMAAS_SUBNET_NAME} (${BMAAS_SUBNET_CIDR})."
}

bmaas_write_evidence() {
    local status="$1" evidence_dir object cr_json bmh_json
    [[ -n "${VLAN_E2E_RUN_DIR:-}" && -d "$VLAN_E2E_RUN_DIR" ]] || return 0
    evidence_dir="${VLAN_E2E_RUN_DIR}"
    object='[]'
    if [[ -n "${BMAAS_BMI_ID:-}" ]]; then
        object="$(bmaas_instance_json "$BMAAS_BMI_ID" 2>/dev/null || printf '[]')"
    fi
    cr_json='{}'
    if [[ -n "${BMAAS_BMI_ID:-}" ]]; then
        cr_json="$(oc get baremetalinstances -A \
            -l "$(baremetal_instance_label_selector "$BMAAS_BMI_ID")" -o json 2>/dev/null || printf '{}')"
    fi
    bmh_json='{}'
    if [[ -n "${BMAAS_BMH_NAME:-}" && -n "${BMAAS_BMH_NAMESPACE:-}" ]]; then
        bmh_json="$(oc get baremetalhost "$BMAAS_BMH_NAME" -n "$BMAAS_BMH_NAMESPACE" \
            -o json 2>/dev/null || printf '{}')"
    fi
    jq -n \
        --arg status "$status" \
        --arg tenant "$OSAC_TENANT" \
        --arg subnet_id "${BMAAS_SUBNET_ID:-}" \
        --arg subnet_name "${BMAAS_SUBNET_NAME:-}" \
        --arg subnet_cidr "${BMAAS_SUBNET_CIDR:-}" \
        --arg source_sha "${IMAGE_SOURCE_COMMIT:-}" \
        --arg aap_revision "${AAP_PROJECT_EXPECTED_REVISION:-}" \
        --argjson instance "$object" \
        --argjson cr "$cr_json" \
        --argjson bmh "$bmh_json" \
        '{
          status: $status,
          runner: "vlan-e2e-bmaas.sh",
          tenant: $tenant,
          source_sha: $source_sha,
          aap_project_revision: $aap_revision,
          subnet: {id: $subnet_id, name: $subnet_name, cidr: $subnet_cidr},
          instance: $instance,
          instance_cr: $cr,
          baremetal_host: $bmh
        }' >"${evidence_dir}/bmaas.json" \
        && chmod 0600 "${evidence_dir}/bmaas.json"
}

bmaas_owned_name() {
    [[ "$1" == "${BMAAS_PREFIX_BASE}-"* ]]
}

bmaas_delete_instance() {
    local bmi_id="$1" object name tenant
    [[ -n "$bmi_id" ]] || return 0
    if ! object="$(bmaas_instance_json "$bmi_id")"; then
        printf 'ERROR: could not read BareMetalInstance %s\n' "$bmi_id" >&2
        return 1
    fi
    if [[ "$(jq 'length' <<<"$object")" == 0 ]]; then
        return 0
    fi
    name="$(jq -r '.[0].metadata.name // ""' <<<"$object")"
    tenant="$(jq -r '.[0].metadata.tenant // ""' <<<"$object")"
    bmaas_owned_name "$name" || {
        printf 'ERROR: refusing to delete BareMetalInstance %s named %s outside the run prefix\n' \
            "$bmi_id" "$name" >&2
        return 1
    }
    [[ "$tenant" == "$OSAC_TENANT" ]] || {
        printf 'ERROR: refusing to delete BareMetalInstance %s owned by tenant %s\n' "$bmi_id" "$tenant" >&2
        return 1
    }
    info "Deleting BareMetalInstance ${bmi_id} (${name}) through Fulfillment..."
    bmaas_cli delete baremetalinstance "$bmi_id" >/dev/null || {
        printf 'ERROR: could not delete BareMetalInstance %s\n' "$bmi_id" >&2
        return 1
    }
    bmaas_wait_for_instance_removal "$bmi_id"
}

bmaas_wait_for_instance_removal() {
    local bmi_id="$1" attempt objects cr_names
    for ((attempt = 1; attempt <= BMAAS_REMOVAL_WAIT_ATTEMPTS; attempt++)); do
        if ! objects="$(bmaas_instance_json "$bmi_id")"; then
            printf 'ERROR: could not read BareMetalInstance %s while waiting for deletion\n' \
                "$bmi_id" >&2
            return 1
        fi
        if [[ "$(jq 'length' <<<"$objects")" == 0 ]]; then
            if ! cr_names="$(oc get baremetalinstances -A \
                -l "$(baremetal_instance_label_selector "$bmi_id")" \
                -o jsonpath='{.items[*].metadata.name}')"; then
                printf 'ERROR: Kubernetes API failed while waiting for BareMetalInstance %s\n' \
                    "$bmi_id" >&2
                return 1
            fi
            [[ -n "$cr_names" ]] || return 0
        fi
        sleep "$BMAAS_REMOVAL_WAIT_DELAY"
    done
    printf 'ERROR: BareMetalInstance %s did not finish deleting\n' "$bmi_id" >&2
    return 1
}

bmaas_wait_for_bmh_available() {
    local name="$1" namespace="$2" attempt state
    [[ -n "$name" && -n "$namespace" ]] || return 0
    for ((attempt = 1; attempt <= BMAAS_REMOVAL_WAIT_ATTEMPTS; attempt++)); do
        if ! state="$(oc get baremetalhost "$name" -n "$namespace" \
            -o jsonpath='{.status.provisioning.state}')"; then
            printf 'ERROR: could not read BareMetalHost %s/%s\n' "$namespace" "$name" >&2
            return 1
        fi
        [[ "$state" == available ]] && return 0
        sleep "$BMAAS_REMOVAL_WAIT_DELAY"
    done
    printf 'ERROR: BareMetalHost %s/%s was not released back to available\n' "$namespace" "$name" >&2
    return 1
}

bmaas_delete_shared_input() {
    local kind="$1" ref="$2" name="$3"
    local objects found_name
    [[ -n "$ref" || -n "$name" ]] || return 0
    if ! objects="$(bmaas_private_cli --tenant shared get "$kind" "$ref" -o json 2>/dev/null)"; then
        printf 'ERROR: could not read %s %s\n' "$kind" "$ref" >&2
        return 1
    fi
    found_name="$(bmaas_json_list <<<"$objects" | jq -r '.[0].metadata.name // ""')"
    if [[ -z "$found_name" ]]; then
        return 0
    fi
    bmaas_owned_name "$found_name" || {
        printf 'ERROR: refusing to delete %s %s outside the run prefix\n' "$kind" "$found_name" >&2
        return 1
    }
    info "Deleting the test-owned ${kind} ${found_name}..."
    bmaas_private_cli --tenant shared delete "$kind" "$found_name" >/dev/null || {
        printf 'ERROR: could not delete %s %s\n' "$kind" "$found_name" >&2
        return 1
    }
}

bmaas_delete_tenant_input() {
    local kind="$1" ref="$2" objects found_name
    [[ -n "$ref" ]] || return 0
    if ! objects="$(bmaas_cli get "$kind" "$ref" -o json 2>/dev/null)"; then
        printf 'ERROR: could not read %s %s\n' "$kind" "$ref" >&2
        return 1
    fi
    found_name="$(bmaas_json_list <<<"$objects" | jq -r '.[0].metadata.name // ""')"
    if [[ -z "$found_name" ]]; then
        return 0
    fi
    bmaas_owned_name "$found_name" || {
        printf 'ERROR: refusing to delete %s %s outside the run prefix\n' "$kind" "$found_name" >&2
        return 1
    }
    info "Deleting the test-owned ${kind} ${found_name}..."
    bmaas_cli delete "$kind" "$found_name" >/dev/null || {
        printf 'ERROR: could not delete %s %s\n' "$kind" "$found_name" >&2
        return 1
    }
}

bmaas_cleanup_resources() {
    local failed=false

    BMAAS_CLEANUP_ERRORS=()
    # The instance must be gone before its inputs, and the host must be
    # returned to the pool before the next run can allocate it. A failure
    # here preserves every input so a later --cleanup can retry in order.
    if ! bmaas_delete_instance "${BMAAS_BMI_ID:-}"; then
        BMAAS_CLEANUP_ERRORS+=("BareMetalInstance ${BMAAS_BMI_ID:-unknown} did not finish deleting")
        failed=true
    fi
    if [[ "$failed" == false ]] && ! bmaas_wait_for_bmh_available \
        "${BMAAS_BMH_NAME:-}" "${BMAAS_BMH_NAMESPACE:-}"; then
        BMAAS_CLEANUP_ERRORS+=("BareMetalHost ${BMAAS_BMH_NAME:-unknown} was not released")
        failed=true
    fi
    if [[ "$failed" == true ]]; then
        BMAAS_CLEANED=false
        bmaas_journal_write || true
        return 1
    fi

    # The remaining inputs are independent, so try every one of them and
    # report all leftovers instead of stopping at the first failure.
    bmaas_delete_shared_input baremetalinstancecatalogitem \
        "${BMAAS_CATALOG_ID:-}" "${BMAAS_CATALOG_NAME:-}" || {
        BMAAS_CLEANUP_ERRORS+=("catalog item ${BMAAS_CATALOG_NAME:-unknown} remains")
        failed=true
    }
    bmaas_delete_tenant_input secret "${BMAAS_SECRET_NAME:-}" || {
        BMAAS_CLEANUP_ERRORS+=("SSH key Secret ${BMAAS_SECRET_NAME:-unknown} remains")
        failed=true
    }
    bmaas_delete_shared_input baremetalinstancetype \
        "${BMAAS_INSTANCE_TYPE_ID:-}" "${BMAAS_INSTANCE_TYPE_NAME:-}" || {
        BMAAS_CLEANUP_ERRORS+=("instance type ${BMAAS_INSTANCE_TYPE_NAME:-unknown} remains")
        failed=true
    }
    bmaas_delete_shared_input diskimage \
        "${BMAAS_DISK_IMAGE_ID:-}" "${BMAAS_DISK_IMAGE_NAME:-}" || {
        BMAAS_CLEANUP_ERRORS+=("disk image ${BMAAS_DISK_IMAGE_NAME:-unknown} remains")
        failed=true
    }

    if [[ "$failed" == true ]]; then
        BMAAS_CLEANED=false
        bmaas_journal_write || true
        return 1
    fi
    BMAAS_CLEANED=true
    bmaas_journal_write || return 1
}

run_bmaas_suite() {
    local journal subnet_json bmi_ip
    bmaas_validate_run_identity
    journal="$(bmaas_journal_path)"
    if [[ -f "$journal" ]] && [[ "$(jq -r '.cleaned // false' "$journal" 2>/dev/null)" != true ]]; then
        die "Uncleaned BMaaS resources are recorded in ${journal}; run --cleanup first"
    fi
    BMAAS_CLEANED=false
    BMAAS_CLEANUP_ERRORS=()
    BMAAS_SUBNET_ID=""
    BMAAS_SUBNET_NAME=""
    BMAAS_SUBNET_CIDR=""
    BMAAS_DISK_IMAGE_ID=""
    BMAAS_DISK_IMAGE_NAME=""
    BMAAS_INSTANCE_TYPE_ID=""
    BMAAS_INSTANCE_TYPE_NAME=""
    BMAAS_SECRET_NAME=""
    BMAAS_CATALOG_ID=""
    BMAAS_CATALOG_NAME=""
    BMAAS_BMI_ID=""
    BMAAS_BMI_NAME=""
    BMAAS_BMI_CR_NAME=""
    BMAAS_BMI_IP=""
    BMAAS_BMH_NAME=""
    BMAAS_BMH_NAMESPACE=""

    info "Running the BMaaS default-Subnet lifecycle as tenant ${OSAC_TENANT}..."
    subnet_json="$(bmaas_default_subnet_json)" || die "Could not resolve the tenant default Subnet"
    BMAAS_SUBNET_ID="$(jq -er '.id' <<<"$subnet_json")" \
        || die "The tenant default Subnet has no identifier"
    BMAAS_SUBNET_NAME="$(jq -er '.name' <<<"$subnet_json")" \
        || die "The tenant default Subnet has no name"
    BMAAS_SUBNET_CIDR="$(jq -er '.cidr' <<<"$subnet_json")" \
        || die "The tenant default Subnet has no IPv4 CIDR"
    bmaas_journal_write || die "Could not create the BMaaS resource journal"
    info "Using the tenant default Subnet ${BMAAS_SUBNET_NAME} (${BMAAS_SUBNET_ID}, ${BMAAS_SUBNET_CIDR})."

    bmaas_pin_prepared_host
    bmaas_private_cli_login
    bmaas_create_inputs

    info "Creating one BareMetalInstance on the tenant default Subnet..."
    bmaas_create_instance
    if ! bmaas_wait_for_instance "$BMAAS_BMI_ID"; then
        bmaas_write_evidence "instance-not-running" || true
        PRESERVE_E2E_RECOVERY_ARTIFACTS=true
        die "BareMetalInstance ${BMAAS_BMI_ID} did not reach RUNNING; run --cleanup after reviewing the evidence"
    fi
    if ! bmaas_assert_instance_host "$BMAAS_BMI_ID"; then
        bmaas_write_evidence "unexpected-host" || true
        PRESERVE_E2E_RECOVERY_ARTIFACTS=true
        die "BareMetalInstance ${BMAAS_BMI_ID} was not attached to a prepared BMH"
    fi
    if ! bmaas_assert_instance_ip "$BMAAS_BMI_ID"; then
        bmaas_write_evidence "wrong-subnet-address" || true
        PRESERVE_E2E_RECOVERY_ARTIFACTS=true
        die "BareMetalInstance ${BMAAS_BMI_ID} did not receive an address inside ${BMAAS_SUBNET_CIDR}"
    fi
    bmaas_write_evidence "passed" || true
    bmi_ip="$BMAAS_BMI_IP"

    if ! bmaas_cleanup_resources; then
        bmaas_write_evidence "teardown-incomplete" || true
        PRESERVE_E2E_RECOVERY_ARTIFACTS=true
        die "BMaaS teardown did not complete; test-owned resources were preserved for --cleanup"
    fi
    bmaas_write_evidence "cleaned" || true
    info "BMaaS default-Subnet E2E passed: one BareMetalInstance provisioned on prepared host ${BMAAS_BMH_NAME}, attached to the tenant default Subnet ${BMAAS_SUBNET_NAME} (${BMAAS_SUBNET_CIDR}), received ${bmi_ip} inside that Subnet, and was deleted with its test-owned inputs."
}

run_bmaas_cleanup() {
    local journal
    journal="$(bmaas_journal_path)"
    if [[ ! -f "$journal" ]]; then
        # Say where the journal was expected: a cleanup that silently finds
        # nothing leaves the failed run's resources behind.
        info "No BMaaS resource journal at ${journal}; pass VLAN_E2E_RUN_DIR=<failed run directory> to clean the resources that run created."
        return 0
    fi
    if [[ "$(jq -r '.cleaned // false' "$journal" 2>/dev/null)" == true ]]; then
        info "The BMaaS journal records that the recorded resources were already cleaned."
        return 0
    fi
    # Journals written by the retired pytest flow recorded different fields,
    # so refuse them explicitly instead of failing on an unknown value.
    if ! jq -e '.run_label and .prefix and (.cleaned | type == "boolean")' \
        "$journal" >/dev/null 2>&1; then
        die "Journal ${journal} predates the shell-runner schema; clean its resources with the runner revision that created them"
    fi
    bmaas_journal_load "$journal" || die "Could not read the BMaaS resource journal ${journal}"
    bmaas_validate_run_identity
    bmaas_owned_name "$BMAAS_PREFIX" \
        || die "Refusing cleanup: journal prefix ${BMAAS_PREFIX} is outside the BMaaS test scope"
    info "Cleaning the BMaaS resources recorded in ${journal}..."
    bmaas_private_cli_login
    bmaas_cleanup_resources \
        || die "BMaaS cleanup could not remove all test-owned resources"
    info "BMaaS cleanup completed; reusable hosts and lab infrastructure were retained."
}


if [[ "${VLAN_E2E_BMAAS_LIBRARY:-false}" == true ]]; then
    return 0
fi

if [[ "$#" -gt 0 && "$1" == --help || "$#" -eq 1 && "$1" == -h ]]; then
    cat <<'USAGE'
Usage: bash ./vlan-e2e-bmaas.sh [--cleanup]

Run the real BMaaS-to-AgentlessNet E2E against the local shared VLAN lab using
the existing osac-e2e-ci installation tenant and its default Subnet. The shared
infrastructure step prepares or reuses OSAC with BMF, one virtual BareMetalHost,
the Containerlab fabric, the bootstrap ExternalIPPool, and the tenant. This
runner creates exactly one BareMetalInstance attached to the tenant's default
Subnet and asserts that DHCP assigned it an address inside that Subnet. The only
other objects it creates are the inputs a BMI needs (a disk image, a shared
instance type, an SSH-key Secret, and a shared catalog item), and it deletes all
of them with the instance. It never creates a VirtualNetwork, Subnet, or
SecurityGroup, and it deletes only its test-owned resources. The virtual host
and the SNO/fabric are retained.

The journal is .artifacts/agentless-net-bmaas/runs/agentless-bmaas.json in the
repository unless VLAN_E2E_RUN_DIR names another directory. Set
OSAC_BMAAS_RUN_ID to rename the journal, and OSAC_BMAAS_RUN_LABEL to choose the
resource-name suffix.

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

step "STEP 5 OF 5: Running the BMaaS default-Subnet E2E"
HOST_IP_FORWARDING_BEFORE="$(netnode sysctl -n net.ipv4.ip_forward)"
if ! run_bmaas_suite; then
    PRESERVE_E2E_RECOVERY_ARTIFACTS=true
    die "BMaaS default-Subnet E2E failed; use bash ./vlan-e2e-bmaas.sh --cleanup after reviewing the evidence"
fi
HOST_IP_FORWARDING_AFTER="$(netnode sysctl -n net.ipv4.ip_forward)"
[[ "$HOST_IP_FORWARDING_AFTER" == "$HOST_IP_FORWARDING_BEFORE" ]] \
    || die "The BMaaS E2E changed the Containerlab network-node forwarding sysctl"
assert_legacy_provider_state_unchanged \
    || die "The BMaaS E2E changed legacy AgentlessNet provider state"
info "BMaaS-to-AgentlessNet E2E passed."
