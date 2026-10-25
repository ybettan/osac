import base64
import json
import os
import shlex
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
RUNNER = REPO_ROOT / "vlan-e2e.sh"
SOURCE = RUNNER.read_text()


def function_block(start: str, end: str) -> str:
    start_index = SOURCE.index(f"\n{start}() {{") + 1
    end_index = SOURCE.index(f"\n{end}() {{", start_index)
    return SOURCE[start_index:end_index]


def run_bash(tmp_path: Path, script: str, env: dict[str, str] | None = None):
    environment = os.environ.copy()
    environment.update(env or {})
    return subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
        timeout=5,
    )


def render_provider_inventory(tmp_path: Path, inventory_path: Path):
    helper = function_block("write_provider_inventory", "sync_aap_project_revision")
    heredoc_start = helper.index("<<'PY'\n") + len("<<'PY'\n")
    heredoc_end = helper.index("\nPY\n", heredoc_start)
    renderer = helper[heredoc_start:heredoc_end]
    topology_path = REPO_ROOT / "tests/e2e/agentless_net/lab/agentless-net-lab.clab.yml"
    output_path = tmp_path / "rendered-inventory.yml"
    host_path = tmp_path / "net-node-host"
    user_path = tmp_path / "net-node-user"
    manifest_path = tmp_path / "switches.json"
    environment = os.environ.copy()
    environment.update(
        MGMT_BRIDGE="virbr-agentless",
        MGMT_CIDR="192.168.162.0/24",
        MGMT_GW="192.168.162.1",
        MGMT_PREFIX="192.168.162",
        MGMT_DHCP_RANGES="192.168.162.100-192.168.162.200",
    )
    return subprocess.run(
        [
            sys.executable,
            "-",
            str(inventory_path),
            str(topology_path),
            str(output_path),
            str(host_path),
            str(user_path),
            str(manifest_path),
        ],
        input=renderer,
        check=False,
        capture_output=True,
        text=True,
        env=environment,
        timeout=5,
    ), output_path, manifest_path


def test_switch_ssh_quotes_remote_argv_as_shell_words(tmp_path):
    helpers = function_block("switch_ssh", "ensure_containerlab_net_node")
    capture = tmp_path / "remote-command.txt"
    marker = tmp_path / "would-execute-locally"
    payload = f"space value; touch {marker}"
    script = f"""
set -euo pipefail
CONTAINERLAB_PREFIX=clab-agentless-net-lab
CUMULUS_SSH_CONFIG_FILE=/tmp/test-ssh-config
die() {{ printf '%s\\n' "$*" >&2; exit 1; }}
ssh() {{
    [[ "$1" == -F && "$2" == "$CUMULUS_SSH_CONFIG_FILE" ]]
    [[ "$3" == osac-agentless-leaf-1-provider ]]
    printf '%s' "$4" >"$CAPTURE"
}}
{helpers}
switch_exec clab-agentless-net-lab-leaf-1 printf '%s' "$REMOTE_PAYLOAD"
"""
    result = run_bash(
        tmp_path,
        script,
        {"CAPTURE": str(capture), "REMOTE_PAYLOAD": payload},
    )

    assert result.returncode == 0, result.stderr
    assert shlex.split(capture.read_text()) == ["sudo", "-n", "printf", "%s", payload]
    assert not marker.exists()


def test_switch_ssh_does_not_consume_remaining_switch_loop_input(tmp_path):
    helpers = function_block("switch_ssh", "ensure_containerlab_net_node")
    capture = tmp_path / "ssh-aliases.txt"
    script = f"""
set -euo pipefail
CONTAINERLAB_PREFIX=clab-agentless-net-lab
CUMULUS_SSH_CONFIG_FILE=/tmp/test-ssh-config
CAPTURE={shlex.quote(str(capture))}
ssh() {{
    cat >/dev/null
    printf '%s\\n' "$3" >>"$CAPTURE"
}}
{helpers}
while IFS= read -r switch; do
    switch_admin_user_exec "$switch" true
done < <(printf '%s\\n' \\
    clab-agentless-net-lab-leaf-1 clab-agentless-net-lab-leaf-2)
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    assert capture.read_text().splitlines() == [
        "osac-agentless-leaf-1-admin",
        "osac-agentless-leaf-2-admin",
    ]


def test_cumulus_ssh_config_refreshes_stale_config_with_named_lab_aliases(tmp_path):
    helper = function_block("write_cumulus_ssh_config", "switch_ssh")
    manifest = tmp_path / "switches.json"
    manifest.write_text(
        json.dumps(
            {
                "switches": [
                    {
                        "name": "clab-agentless-net-lab-leaf-1",
                        "ansible_host": "192.168.162.11",
                        "ansible_user": "cumulus",
                        "ansible_port": 22,
                    },
                    {
                        "name": "clab-agentless-net-lab-leaf-2",
                        "ansible_host": "192.168.162.12",
                        "ansible_user": "cumulus",
                        "ansible_port": 22,
                    },
                ]
            }
        )
    )
    config = tmp_path / "ssh_config"
    config.write_text("stale SSH config from an earlier lab run\n")
    script = f"""
set -euo pipefail
SWITCH_MANIFEST_FILE={shlex.quote(str(manifest))}
CONTAINERLAB_PREFIX=clab-agentless-net-lab
CUMULUS_LAB_ADMIN_KEY=/keys/admin_ed25519
SSH_PRIVATE_KEY_FILE=/tmp/provider_ed25519
TEMP_DIR=/tmp/osac-run
CUMULUS_SSH_CONFIG_FILE={shlex.quote(str(config))}
{helper}
write_cumulus_ssh_config
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    content = config.read_text()
    assert "Host osac-agentless-leaf-1-admin" in content
    assert "Host osac-agentless-leaf-2-provider" in content
    assert "HostName 192.168.162.11" in content
    assert "IdentityFile \"/keys/admin_ed25519\"" in content
    assert "IdentityFile \"/tmp/provider_ed25519\"" in content
    assert "stale SSH config" not in content
    assert 'UserKnownHostsFile "/tmp/osac-run/known_hosts"' in content
    assert "StrictHostKeyChecking accept-new" in content
    assert config.stat().st_mode & 0o777 == 0o600


def test_startup_config_embeds_only_the_admin_public_key(tmp_path):
    helper = function_block("prepare_cumulus_startup_config", "write_cumulus_ssh_config")
    public_key = "ssh-ed25519 AAAAC3Nza-admin osac-agentless-lab-admin"
    public_key_file = tmp_path / "admin.pub"
    public_key_file.write_text(public_key + "\n")
    startup_config = tmp_path / "cumulus-startup.cfg"
    script = f"""
set -euo pipefail
TEMP_DIR={shlex.quote(str(tmp_path))}
CUMULUS_ADMIN_PUBLIC_KEY_FILE={shlex.quote(str(public_key_file))}
CUMULUS_STARTUP_CONFIG=
{helper}
prepare_cumulus_startup_config
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    assert startup_config.read_text().count(public_key) == 2
    assert "install -d -m 0700 /home/cumulus/.ssh" in startup_config.read_text()
    assert startup_config.stat().st_mode & 0o777 == 0o600


def test_old_container_image_is_refused_for_boxen_lab(tmp_path):
    helpers = function_block("assert_containerlab_switch_images", "wait_for_cumulus_guests")
    script = f"""
set -euo pipefail
SWITCH_MANIFEST_FILE=/tmp/ignored-switches.json
CUMULUS_VX_IMAGE=boxen-nvidia_cumulusvx:5.16.5
CUMULUS_IMAGE_ID=sha256:expected
ensure_containerlab_switches() {{ :; }}
jq() {{ printf '%s\\n' clab-agentless-net-lab-leaf-1; }}
docker() {{
    case "$3" in
        *Config.Image*) printf '%s' networkop/cx:5.3.0 ;;
        *.Image*) printf '%s' sha256:old ;;
        *) return 2 ;;
    esac
}}
die() {{ printf 'ERROR: %s\\n' "$*" >&2; exit 1; }}
{helpers}
assert_containerlab_switch_images
"""
    result = run_bash(tmp_path, script)

    assert result.returncode != 0
    assert "expected boxen-nvidia_cumulusvx:5.16.5" in result.stderr


def test_guest_readiness_timeout_is_bounded(tmp_path):
    helpers = function_block("wait_for_cumulus_guests", "prepare_containerlab_switches")
    script = f"""
set -euo pipefail
SECONDS=0
CONTAINERLAB_PREFIX=clab-agentless-net-lab
SWITCH_MANIFEST_FILE=/tmp/ignored-switches.json
CUMULUS_VERSION=5.16.5
ensure_containerlab_switches() {{ :; }}
jq() {{ printf '%s\\n' clab-agentless-net-lab-leaf-1; }}
docker() {{
    case "$1" in
        inspect) printf '%s\\n' starting ;;
        logs) return 0 ;;
        *) return 2 ;;
    esac
}}
switch_admin_user_exec() {{ return 1; }}
sleep() {{ SECONDS=$((SECONDS + 1200)); }}
info() {{ :; }}
{helpers}
wait_for_cumulus_guests
"""
    result = run_bash(tmp_path, script)

    assert result.returncode != 0
    assert "did not become healthy and SSH-ready within 20 minutes" in result.stderr


def test_owned_aap_ssh_key_from_interrupted_run_is_adopted_for_cleanup(tmp_path):
    helper = function_block("ensure_aap_ssh_key", "ensure_cumulus_admin_identity")
    private_key = "temporary key bytes from an interrupted run"
    key_base64 = base64.b64encode(private_key.encode()).decode()
    secret_json = json.dumps(
        {
            "metadata": {"annotations": {"osac.openshift.io/agentless-vn-ssh": "OSAC-5529"}},
            "data": {"AGENTLESS_NET_SSH_PRIVATE_KEY": key_base64},
        }
    )
    script = f"""
set -euo pipefail
TEMP_DIR={shlex.quote(str(tmp_path))}
AAP_NETWORKING_SECRET=network-fulfillment-ig
OSAC_NAMESPACE=osac-e2e-ci
AAP_SSH_KEY_SECRET_KEY=AGENTLESS_NET_SSH_PRIVATE_KEY
AAP_SSH_KEY_SECRET_ANNOTATION=osac.openshift.io/agentless-vn-ssh
SSH_KEY_CREATED_BY_RUN=false
SSH_KEY_EXPECTED_BASE64=
SSH_KEY_ORIGINAL_ANNOTATION=
SECRET_JSON={shlex.quote(secret_json)}
oc() {{ printf '%s' "$SECRET_JSON"; }}
ssh-keygen() {{ printf 'ssh-ed25519 test-key osac-test\\n'; }}
die() {{ printf 'ERROR: %s\\n' "$*" >&2; exit 1; }}
{helper}
ensure_aap_ssh_key
[[ "$SSH_KEY_CREATED_BY_RUN" == true ]]
[[ "$SSH_KEY_EXPECTED_BASE64" == {shlex.quote(key_base64)} ]]
[[ -z "$SSH_KEY_ORIGINAL_ANNOTATION" ]]
[[ "$SSH_PRIVATE_KEY_FILE" == "$TEMP_DIR/agentless-net-id_ed25519" ]]
"""

    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr


def test_nvue_interface_config_reads_set_object_after_header(tmp_path):
    helper = function_block("nvue_interface_config", "create_dhcp_client_container")
    nvue_output = json.dumps(
        [
            {"header": {"model": "Cumulus Linux"}},
            {
                "set": {
                    "interface": {
                        "swp2": {"bridge": {"domain": {"br_default": {"access": 2}}}},
                        "swp3": {"bridge": {"domain": {"br_default": {"access": 3}}}},
                    }
                }
            },
        ]
    )
    swp2 = json.dumps({"bridge": {"domain": {"br_default": {"access": 2}}}}, separators=(",", ":"))
    swp3 = json.dumps({"bridge": {"domain": {"br_default": {"access": 3}}}}, separators=(",", ":"))
    script = f"""
set -euo pipefail
NVUE_OUTPUT={shlex.quote(nvue_output)}
switch_exec() {{ printf '%s' "$NVUE_OUTPUT"; }}
{helper}
[[ "$(nvue_interface_config leaf-2 swp2)" == {shlex.quote(swp2)} ]]
[[ "$(nvue_interface_config leaf-2 swp3)" == {shlex.quote(swp3)} ]]
NVUE_OUTPUT='[{{"header":{{"model":"Cumulus Linux"}}}},{{"set":{{"interface":{{}}}}}}]'
[[ "$(nvue_interface_config leaf-2 swp2)" == null ]]
NVUE_OUTPUT={shlex.quote(json.dumps({"set": {"interface": {"swp2": {"bridge": {"domain": {"br_default": {"access": 2}}}}}}}))}
[[ "$(nvue_interface_config leaf-2 swp2)" == {shlex.quote(swp2)} ]]
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr


def test_nvue_diff_reader_accepts_exit_one_when_commands_are_returned(tmp_path):
    helper = function_block("switch_nvue_diff", "ensure_containerlab_net_node")
    script = f"""
set -euo pipefail
ADMIN_DIFF='nv unset system aaa user cumulus ssh authorized-key osac_e2e_test'
ADMIN_STATUS=1
PROVIDER_DIFF='nv set interface swp1 bridge domain br_default'
PROVIDER_STATUS=1
switch_admin_user_exec() {{ printf '%s' "$ADMIN_DIFF"; return "$ADMIN_STATUS"; }}
switch_exec() {{ printf '%s' "$PROVIDER_DIFF"; return "$PROVIDER_STATUS"; }}
{helper}
[[ "$(switch_nvue_diff admin leaf-1)" == "$ADMIN_DIFF" ]]
[[ "$(switch_nvue_diff provider leaf-2)" == "$PROVIDER_DIFF" ]]
ADMIN_DIFF=
ADMIN_STATUS=0
[[ -z "$(switch_nvue_diff admin leaf-1)" ]]
ADMIN_STATUS=1
if switch_nvue_diff admin leaf-1; then exit 1; fi
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr


def test_external_ip_pool_list_normalizes_omitted_empty_items(tmp_path):
    helper = function_block("external_ip_pool_list_items", "external_ip_pool_rpc_error_is_not_found")
    response_file = tmp_path / "pool-list.json"
    script = f"""
set -euo pipefail
RESPONSE={shlex.quote(str(response_file))}
{helper}
printf '%s' '{{}}' >"$RESPONSE"
[[ "$(external_ip_pool_list_items "$RESPONSE")" == '[]' ]]
printf '%s' '{{"items":[]}}' >"$RESPONSE"
[[ "$(external_ip_pool_list_items "$RESPONSE")" == '[]' ]]
printf '%s' '{{"items":[{{"id":"pool-id"}}]}}' >"$RESPONSE"
[[ "$(external_ip_pool_list_items "$RESPONSE")" == '[{{"id":"pool-id"}}]' ]]
printf '%s' '{{"items":{{}}}}' >"$RESPONSE"
if external_ip_pool_list_items "$RESPONSE" >/dev/null 2>&1; then exit 1; fi
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr


def test_external_ip_pool_cidr_can_be_overridden_for_a_lab_run(tmp_path):
    assignment = next(
        line for line in SOURCE.splitlines() if line.startswith("EXTERNAL_IP_POOL_CIDR=")
    )
    script = f"""
set -euo pipefail
{assignment}
printf '%s' "$EXTERNAL_IP_POOL_CIDR"
"""
    result = run_bash(tmp_path, script, {"EXTERNAL_IP_POOL_CIDR": "203.0.113.0/24"})

    assert result.returncode == 0, result.stderr
    assert result.stdout == "203.0.113.0/24"


def test_external_ip_pool_default_selects_a_non_overlapping_test_cidr(tmp_path):
    helpers = (
        function_block("external_ip_pool_list_items", "external_ip_pool_rpc_error_is_not_found")
        + "\n"
        + function_block("resolve_external_ip_pool_cidr", "external_ip_pool_rpc_error_is_not_found")
    )
    request_file = tmp_path / "shared-pool-list.request.json"
    script = f"""
set -euo pipefail
TEMP_DIR={shlex.quote(str(tmp_path))}
EXTERNAL_IP_POOL_CIDR_EXPLICIT=false
EXTERNAL_IP_POOL_CIDR=198.51.100.0/24
EXTERNAL_IP_POOL_CIDR_RESOLVED=false
REQUEST_CAPTURE={shlex.quote(str(request_file))}
info() {{ :; }}
external_ip_pool_rpc() {{
    [[ "$1" == List ]]
    cp "$2" "$REQUEST_CAPTURE"
    printf '%s' '{{"items":[{{"metadata":{{"name":"leftover-e2e-pool","tenant":"shared"}},"spec":{{"cidrs":["198.51.100.0/24"]}}}}]}}' >"$3"
}}
{helpers}
resolve_external_ip_pool_cidr
[[ "$EXTERNAL_IP_POOL_CIDR" == 198.18.0.0/24 ]]
[[ "$EXTERNAL_IP_POOL_CIDR_RESOLVED" == true ]]
jq -e '.filter == "this.metadata.tenant == \\"shared\\""' "$REQUEST_CAPTURE" >/dev/null
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr


def test_external_ip_pool_explicit_cidr_reports_overlap_before_create(tmp_path):
    helpers = (
        function_block("external_ip_pool_list_items", "external_ip_pool_rpc_error_is_not_found")
        + "\n"
        + function_block("resolve_external_ip_pool_cidr", "external_ip_pool_rpc_error_is_not_found")
    )
    script = f"""
set -euo pipefail
TEMP_DIR={shlex.quote(str(tmp_path))}
EXTERNAL_IP_POOL_CIDR_EXPLICIT=true
EXTERNAL_IP_POOL_CIDR=198.51.100.0/24
EXTERNAL_IP_POOL_CIDR_RESOLVED=false
info() {{ :; }}
external_ip_pool_rpc() {{
    printf '%s' '{{"items":[{{"metadata":{{"name":"leftover-e2e-pool","tenant":"shared"}},"spec":{{"cidrs":["198.51.100.0/24"]}}}}]}}' >"$3"
}}
{helpers}
if resolve_external_ip_pool_cidr; then exit 1; fi
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    assert "overlaps existing shared pool leftover-e2e-pool" in result.stderr


def test_provider_key_checkpoint_detects_nvues_key_disappearance(tmp_path):
    helper = function_block("assert_provider_key_survived", "ensure_containerlab_net_node")
    manifest = tmp_path / "switches.json"
    manifest.write_text(
        json.dumps(
            {
                "switches": [
                    {"name": "clab-agentless-net-lab-leaf-1"},
                    {"name": "clab-agentless-net-lab-leaf-2"},
                ]
            }
        )
    )
    script = f"""
set -euo pipefail
PROVIDER_NVUE_KEY_ID=osac_e2e_test
SWITCH_MANIFEST_FILE={shlex.quote(str(manifest))}
KEY_STATE=absent
die() {{ printf 'ERROR: %s\\n' "$*" >&2; exit 1; }}
info() {{ :; }}
switch_admin_user_exec() {{
    local switch="$1"
    if [[ "$switch" == clab-agentless-net-lab-leaf-2 && "$KEY_STATE" == absent ]]; then
        printf '%s' '{{"osac-agentless-lab-admin":{{"type":"ssh-ed25519","key":"redacted"}}}}'
    else
        printf '%s' '{{"osac_e2e_test":{{"type":"ssh-ed25519","key":"redacted"}}}}'
    fi
}}
switch_provider_user_exec() {{
    [[ "$2" == sudo && "$3" == -n && "$4" == true ]]
    [[ "$1" != clab-agentless-net-lab-leaf-2 || "$KEY_STATE" != absent ]]
}}
{helper}
assert_provider_key_survived 'AAP rehydration'
"""
    result = run_bash(tmp_path, script)

    assert result.returncode != 0
    assert "disappeared after AAP rehydration on clab-agentless-net-lab-leaf-2" in result.stderr


def test_provider_key_checkpoint_can_focus_on_the_a2_switch(tmp_path):
    helper = function_block("assert_provider_key_survived", "ensure_containerlab_net_node")
    manifest = tmp_path / "switches.json"
    manifest.write_text(
        json.dumps(
            {
                "switches": [
                    {"name": "clab-agentless-net-lab-leaf-1"},
                    {"name": "clab-agentless-net-lab-leaf-2"},
                ]
            }
        )
    )
    capture = tmp_path / "checkpoint.log"
    script = f"""
set -euo pipefail
PROVIDER_NVUE_KEY_ID=osac_e2e_test
SWITCH_MANIFEST_FILE={shlex.quote(str(manifest))}
CAPTURE={shlex.quote(str(capture))}
die() {{ printf 'ERROR: %s\\n' "$*" >&2; exit 1; }}
info() {{ printf 'INFO: %s\\n' "$*" >>"$CAPTURE"; }}
switch_admin_user_exec() {{
    printf 'admin:%s\\n' "$1" >>"$CAPTURE"
    printf '%s' '{{"osac_e2e_test":{{"type":"ssh-ed25519","key":"redacted"}}}}'
}}
switch_provider_user_exec() {{
    printf 'provider:%s\\n' "$1" >>"$CAPTURE"
}}
{helper}
assert_provider_key_survived 'before A2 provider preflight' clab-agentless-net-lab-leaf-2
grep -Fxq 'admin:clab-agentless-net-lab-leaf-2' "$CAPTURE"
grep -Fxq 'provider:clab-agentless-net-lab-leaf-2' "$CAPTURE"
if grep -Fxq 'admin:clab-agentless-net-lab-leaf-1' "$CAPTURE"; then exit 1; fi
if grep -Fxq 'provider:clab-agentless-net-lab-leaf-1' "$CAPTURE"; then exit 1; fi
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr


def test_provider_key_is_installed_through_nvue(tmp_path):
    helper = (
        function_block("switch_nvue_diff", "ensure_containerlab_net_node")
        + "\n"
        + function_block("install_containerlab_switch_provider_key", "prepare_containerlab_switches")
    )
    capture = tmp_path / "nvue-commands.txt"
    script = f"""
set -euo pipefail
PROVIDER_NVUE_KEY_ID=osac_e2e_test
declare -A SWITCH_NVUE_KEY_INSTALLED_BY_RUN=()
APPLIED=false
CAPTURE={shlex.quote(str(capture))}
LOG_CAPTURE={shlex.quote(str(tmp_path / "install.log"))}
info() {{ printf 'INFO: %s\\n' "$*" >>"$LOG_CAPTURE"; }}
die() {{ printf 'ERROR: %s\\n' "$*" >&2; exit 1; }}
switch_admin_user_exec() {{
    local switch="$1"
    shift
    [[ "$switch" == clab-agentless-net-lab-leaf-2 ]]
    printf '%s\\n' "$*" >>"$CAPTURE"
    case "$*" in
        'nv config diff --output commands') ;;
        'nv show system aaa user cumulus ssh authorized-key --output json')
            if [[ "$APPLIED" == true ]]; then
                printf '%s' '{{"osac-agentless-lab-admin":{{"type":"ssh-ed25519","key":"adminblob"}},"osac_e2e_test":{{"type":"ssh-ed25519","key":"providerblob"}}}}'
            else
                printf '%s' '{{"osac-agentless-lab-admin":{{"type":"ssh-ed25519","key":"adminblob"}}}}'
            fi
            ;;
        'nv set system aaa user cumulus ssh authorized-key osac_e2e_test key providerblob') ;;
        'nv set system aaa user cumulus ssh authorized-key osac_e2e_test type ssh-ed25519') ;;
        'nv config apply --assume-yes') APPLIED=true ;;
        *) return 2 ;;
    esac
}}
{helper}
install_containerlab_switch_provider_key clab-agentless-net-lab-leaf-2 ssh-ed25519 providerblob
[[ "${{SWITCH_NVUE_KEY_INSTALLED_BY_RUN[clab-agentless-net-lab-leaf-2]}}" == true ]]
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    assert capture.read_text().splitlines() == [
        "nv config diff --output commands",
        "nv show system aaa user cumulus ssh authorized-key --output json",
        "nv set system aaa user cumulus ssh authorized-key osac_e2e_test key providerblob",
        "nv set system aaa user cumulus ssh authorized-key osac_e2e_test type ssh-ed25519",
        "nv config apply --assume-yes",
        "nv show system aaa user cumulus ssh authorized-key --output json",
    ]
    assert (tmp_path / "install.log").read_text().splitlines() == [
        "INFO: Installing per-run provider NVUE key on clab-agentless-net-lab-leaf-2.",
        "INFO: Per-run provider NVUE key installation verified on clab-agentless-net-lab-leaf-2.",
    ]


def test_persistent_admin_key_is_registered_before_nvue_apply(tmp_path):
    helper = (
        function_block("switch_nvue_diff", "ensure_containerlab_net_node")
        + "\n"
        + function_block("ensure_containerlab_admin_nvue_key", "install_containerlab_switch_provider_key")
    )
    public_key = tmp_path / "admin.pub"
    public_key.write_text("ssh-ed25519 adminblob osac-admin\n")
    capture = tmp_path / "nvue-admin-commands.txt"
    script = f"""
set -euo pipefail
CUMULUS_ADMIN_NVUE_KEY_ID=osac-agentless-e2e-admin
CUMULUS_ADMIN_PUBLIC_KEY_FILE={shlex.quote(str(public_key))}
APPLIED=false
CAPTURE={shlex.quote(str(capture))}
die() {{ printf 'ERROR: %s\\n' "$*" >&2; exit 1; }}
switch_admin_user_exec() {{
    local switch="$1"
    shift
    [[ "$switch" == clab-agentless-net-lab-leaf-1 ]]
    printf '%s\\n' "$*" >>"$CAPTURE"
    case "$*" in
        'nv config diff --output commands') ;;
        'nv show system aaa user cumulus ssh authorized-key --output json')
            if [[ "$APPLIED" == true ]]; then
                printf '%s' '{{"stale-admin":{{"type":"ssh-ed25519","key":"oldblob"}},"osac-agentless-e2e-admin":{{"type":"ssh-ed25519","key":"adminblob"}}}}'
            else
                printf '%s' '{{"stale-admin":{{"type":"ssh-ed25519","key":"oldblob"}}}}'
            fi
            ;;
        'nv set system aaa user cumulus ssh authorized-key osac-agentless-e2e-admin key adminblob') ;;
        'nv set system aaa user cumulus ssh authorized-key osac-agentless-e2e-admin type ssh-ed25519') ;;
        'nv config apply --assume-yes') APPLIED=true ;;
        'true') ;;
        *) return 2 ;;
    esac
}}
{helper}
ensure_containerlab_admin_nvue_key clab-agentless-net-lab-leaf-1
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    assert capture.read_text().splitlines() == [
        "nv config diff --output commands",
        "nv show system aaa user cumulus ssh authorized-key --output json",
        "nv set system aaa user cumulus ssh authorized-key osac-agentless-e2e-admin key adminblob",
        "nv set system aaa user cumulus ssh authorized-key osac-agentless-e2e-admin type ssh-ed25519",
        "nv config apply --assume-yes",
        "nv show system aaa user cumulus ssh authorized-key --output json",
        "true",
    ]


def test_vlan_snapshot_collects_switchd_reserved_range(tmp_path):
    helper_writer = function_block("write_agentless_e2e_helpers", "nvue_interface_config")
    snapshotter = function_block("snapshot_switch_vlan_state", "assert_new_vlans_avoid_baseline")
    run_dir = tmp_path / "run"
    run_dir.mkdir()
    manifest = run_dir / "switches.json"
    manifest.write_text(
        json.dumps({"switches": [{"name": "clab-agentless-net-lab-leaf-1"}]})
    )
    script = f"""
set -euo pipefail
TEMP_DIR={shlex.quote(str(run_dir))}
REPO_ROOT={shlex.quote(str(REPO_ROOT))}
SWITCH_MANIFEST_FILE={shlex.quote(str(manifest))}
info() {{ :; }}
die() {{ printf '%s\\n' "$*" >&2; exit 1; }}
switch_exec() {{
    local switch="$1"
    shift
    [[ "$switch" == clab-agentless-net-lab-leaf-1 ]]
    case "$1" in
        bridge) printf '%s\\n' "$BRIDGE_OUTPUT" ;;
        nv) printf '%s\\n' "$RESERVED_OUTPUT" ;;
        awk) printf '%s\\n' "$SWITCHD_OUTPUT" ;;
        *) return 2 ;;
    esac
}}
{helper_writer}
{snapshotter}
write_agentless_e2e_helpers
snapshot_switch_vlan_state
jq -e '.excluded_vlan_ids == ([1] + [range(3725; 4000)] + [range(4000; 4065)])' \
    "$SWITCH_VLAN_SNAPSHOT_FILE" >/dev/null
jq -e '.switches[0].switchd_reserved_vlan_output == "resv_vlan_range = 3725-3999"' \
    "$SWITCH_VLAN_SNAPSHOT_FILE" >/dev/null
"""
    result = run_bash(
        tmp_path,
        script,
        {
            "BRIDGE_OUTPUT": json.dumps([{"ifname": "br_default", "vlans": [{"vlan": 1}]}]),
            "RESERVED_OUTPUT": json.dumps(
                {"internal": {}, "l3-vni-vlan": {"begin": 4000, "end": 4064}}
            ),
            "SWITCHD_OUTPUT": "resv_vlan_range = 3725-3999",
        },
    )

    assert result.returncode == 0, result.stderr


def test_run_evidence_is_retained_after_failed_suite(tmp_path):
    helpers = function_block("write_run_evidence", "on_exit")
    run_dir = tmp_path / "evidence"
    run_dir.mkdir(mode=0o700)
    repo_root = str(REPO_ROOT)
    script = f"""
set -euo pipefail
RUN_DIR_CREATED=true
VLAN_E2E_RUN_DIR={shlex.quote(str(run_dir))}
SWITCH_MANIFEST_FILE={shlex.quote(str(tmp_path / 'missing-switches.json'))}
RUN_STARTED_AT_UTC=2026-10-15T09:00:00Z
CURRENT_STAGE=smoke-test
VLAN_E2E_SUITE=full
CURRENT_BRANCH=e2e
REPO_ROOT={shlex.quote(repo_root)}
AAP_PROJECT_GIT_BRANCH=agentless-net-cumulus-fixes
AAP_PROJECT_EXPECTED_REVISION=0123456789abcdef0123456789abcdef01234567
CUMULUS_VERSION=5.16.5
CUMULUS_VX_IMAGE=boxen-nvidia_cumulusvx:5.16.5
CUMULUS_IMAGE_ID=sha256:1234
CUMULUS_IMAGE_PROVENANCE_FILE=
CUMULUS_SSH_CONFIG_FILE=/tmp/unused-agentless-ssh-config
{helpers}
write_run_evidence 1 1
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    summary_path = run_dir / "summary.json"
    assert summary_path.is_file()
    summary = json.loads(summary_path.read_text())
    assert summary["exit_status"] == 1
    assert summary["cleanup_status"] == 1
    assert summary["failed_stage"] == "smoke-test"
    assert summary["switches"] == []
    assert summary_path.stat().st_mode & 0o777 == 0o600


def test_per_run_nvue_key_cleanup_preserves_admin_key(tmp_path):
    helpers = (
        function_block("switch_nvue_diff", "ensure_containerlab_net_node")
        + "\n"
        + function_block("remove_containerlab_switch_keys", "restore_containerlab_switch_access")
    )
    manifest = tmp_path / "switches.json"
    manifest.write_text(
        json.dumps({"switches": [{"name": "clab-agentless-net-lab-leaf-1"}]})
    )
    admin_config = json.dumps(
        {
            "osac-agentless-lab-admin": {"type": "ssh-ed25519", "key": "stale-adminblob"},
            "osac-agentless-e2e-admin": {"type": "ssh-ed25519", "key": "adminblob"},
        }
    )
    active_config = json.dumps(
        {
            "osac-agentless-lab-admin": {"type": "ssh-ed25519", "key": "stale-adminblob"},
            "osac-agentless-e2e-admin": {"type": "ssh-ed25519", "key": "adminblob"},
            "osac_e2e_test": {"type": "ssh-ed25519", "key": "providerblob"},
        }
    )
    script = f"""
set -euo pipefail
SWITCH_ACCESS_CONFIGURED=true
PROVIDER_NVUE_KEY_ID=osac_e2e_test
SWITCH_MANIFEST_FILE={shlex.quote(str(manifest))}
ACTIVE_KEYS={shlex.quote(active_config)}
ADMIN_KEYS={shlex.quote(admin_config)}
CANDIDATE_DIFF=
declare -A SWITCH_NVUE_KEY_INSTALLED_BY_RUN=([clab-agentless-net-lab-leaf-1]=true)
switch_admin_user_exec() {{
    local switch="$1"
    shift
    [[ "$switch" == clab-agentless-net-lab-leaf-1 ]]
    case "$*" in
        'nv config diff --output commands') printf '%s' "$CANDIDATE_DIFF"; [[ -z "$CANDIDATE_DIFF" ]] ;;
        'nv show system aaa user cumulus ssh authorized-key --output json') printf '%s' "$ACTIVE_KEYS" ;;
        'nv unset system aaa user cumulus ssh authorized-key osac_e2e_test')
            CANDIDATE_DIFF='nv unset system aaa user cumulus ssh authorized-key osac_e2e_test'
            ;;
        'nv config apply --assume-yes') ACTIVE_KEYS="$ADMIN_KEYS"; CANDIDATE_DIFF= ;;
        *) return 2 ;;
    esac
}}
{helpers}
remove_containerlab_switch_keys
[[ "${{SWITCH_NVUE_KEY_INSTALLED_BY_RUN[clab-agentless-net-lab-leaf-1]}}" == false ]]
jq -e 'has("osac-agentless-lab-admin") and has("osac-agentless-e2e-admin") and (has("osac_e2e_test") | not)' <<<"$ACTIVE_KEYS" >/dev/null
[[ -z "$CANDIDATE_DIFF" ]]
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr


def test_per_run_nvue_key_cleanup_preserves_unrelated_candidate_changes(tmp_path):
    helpers = (
        function_block("switch_nvue_diff", "ensure_containerlab_net_node")
        + "\n"
        + function_block("remove_containerlab_switch_keys", "restore_containerlab_switch_access")
    )
    manifest = tmp_path / "switches.json"
    manifest.write_text(
        json.dumps({"switches": [{"name": "clab-agentless-net-lab-leaf-1"}]})
    )
    script = f"""
set -euo pipefail
SWITCH_ACCESS_CONFIGURED=true
PROVIDER_NVUE_KEY_ID=osac_e2e_test
SWITCH_MANIFEST_FILE={shlex.quote(str(manifest))}
CANDIDATE_DIFF='nv set system hostname preserved'
declare -A SWITCH_NVUE_KEY_INSTALLED_BY_RUN=([clab-agentless-net-lab-leaf-1]=true)
switch_admin_user_exec() {{
    local switch="$1"
    shift
    [[ "$switch" == clab-agentless-net-lab-leaf-1 ]]
    [[ "$*" == 'nv config diff --output commands' ]]
    printf '%s' "$CANDIDATE_DIFF"
    [[ -z "$CANDIDATE_DIFF" ]]
}}
{helpers}
if remove_containerlab_switch_keys; then exit 1; fi
[[ "$CANDIDATE_DIFF" == 'nv set system hostname preserved' ]]
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    assert "preserving them and the provider key" in result.stderr


def test_local_trunk_setup_uses_admin_key_and_checks_provider_key():
    setup = function_block("configure_containerlab_fabric", "write_provider_inventory")
    provider_check = function_block("prepare_containerlab_switches", "configure_containerlab_fabric")

    assert '--private-key "$CUMULUS_LAB_ADMIN_KEY"' in setup
    assert '--private-key "$SSH_PRIVATE_KEY_FILE"' not in setup
    assert "switch_provider_user_exec \"$switch\"" in provider_check


def test_trunk_initialization_precedes_the_suite_start():
    lab_prep = SOURCE.index('step "STEP 4 OF 5: Initializing provider and fabric"')
    trunk_setup = SOURCE.index("\nconfigure_containerlab_fabric\n", lab_prep)
    suite_start = SOURCE.index('step "STEP 5 OF 5: Running the ${VLAN_E2E_SUITE} E2E suite"')
    suite_dispatch = SOURCE.index('case "$VLAN_E2E_SUITE" in', suite_start)

    assert lab_prep < trunk_setup < suite_start < suite_dispatch


def test_dhcp_client_switch_attachment_uses_production_aap_jobs():
    assert 'run_agentless_net_aap_job move-network-attachment' in SOURCE
    assert 'run_agentless_net_aap_job query-dhcp-lease' in SOURCE
    assert 'configure_client_access_port' not in SOURCE
    assert 'nv set interface "$CLIENT_SWITCH_PORT"' not in SOURCE
    assert 'nv unset interface "$CLIENT_SWITCH_PORT"' not in SOURCE


def test_provider_inventory_keeps_bmaas_port_mapping_for_aap_jobs(tmp_path):
    inventory = REPO_ROOT / "tests/e2e/agentless_net/lab/inventory.yml"

    result, output_path, manifest_path = render_provider_inventory(tmp_path, inventory)

    assert result.returncode == 0, result.stderr
    rendered = yaml.safe_load(output_path.read_text())
    inventory_vars = rendered["all"]["vars"]
    assert inventory_vars["agentless_net_provisioning_network"] == {
        "name": "agentless-provisioning",
        "vlan_id": 1,
    }
    assert inventory_vars["agentless_net_host_ports"] == {
        "osac-e2e-a1": {"eth0": {"switch": "clab-agentless-net-lab-leaf-1", "port": "swp2"}},
        "osac-e2e-a2": {"eth0": {"switch": "clab-agentless-net-lab-leaf-2", "port": "swp2"}},
        "osac-e2e-b1": {"eth0": {"switch": "clab-agentless-net-lab-leaf-2", "port": "swp3"}},
    }
    manifest = json.loads(manifest_path.read_text())
    trunk_ports = {switch["name"]: set(switch["trunk_ports"]) for switch in manifest["switches"]}
    for host in inventory_vars["agentless_net_host_ports"].values():
        for mapping in host.values():
            assert mapping["port"] not in trunk_ports[mapping["switch"]]


def test_provider_inventory_rejects_duplicate_bmaas_port_claims(tmp_path):
    source = yaml.safe_load(
        (REPO_ROOT / "tests/e2e/agentless_net/lab/inventory.yml").read_text()
    )
    source["all"]["vars"]["agentless_net_host_ports"]["osac-e2e-a2"]["eth0"] = {
        "switch": "clab-agentless-net-lab-leaf-1",
        "port": "swp2",
    }
    inventory = tmp_path / "duplicate-inventory.yml"
    inventory.write_text(yaml.safe_dump(source, sort_keys=False))

    result, _, _ = render_provider_inventory(tmp_path, inventory)

    assert result.returncode != 0
    assert "must not be assigned more than once" in result.stderr


def test_provider_inventory_upgrade_accepts_matching_legacy_switch_inventory(tmp_path):
    source_inventory = REPO_ROOT / "tests/e2e/agentless_net/lab/inventory.yml"
    rendered_result, expected_path, _ = render_provider_inventory(tmp_path, source_inventory)
    assert rendered_result.returncode == 0, rendered_result.stderr
    expected_inventory = expected_path.read_text()
    legacy = yaml.safe_load(expected_inventory)
    legacy_vars = legacy["all"]["vars"]
    legacy_vars.pop("agentless_net_provisioning_network")
    legacy_vars.pop("agentless_net_host_ports")
    legacy_inventory = yaml.safe_dump(legacy, sort_keys=False)
    configmap = json.dumps(
        {"data": {"AGENTLESS_NET_VN_INVENTORY": legacy_inventory}}
    )

    helper = function_block("write_provider_inventory", "sync_aap_project_revision")
    marker = "<<'PY'\n"
    first_start = helper.index(marker) + len(marker)
    first_end = helper.index("\nPY\n", first_start)
    second_start = helper.index(marker, first_end) + len(marker)
    second_end = helper.index("\nPY\n", second_start)
    migration = helper[second_start:second_end]
    backup_path = tmp_path / "inventory-backup.json"
    patch_path = tmp_path / "inventory-patch.json"
    script = f"""
set -euo pipefail
python3 - {shlex.quote(configmap)} {shlex.quote(expected_inventory)} \
    {shlex.quote(str(backup_path))} {shlex.quote(str(patch_path))} <<'PY'
{migration}
PY
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    backup = json.loads(backup_path.read_text())
    assert backup["original_inventory"] == legacy_inventory
    assert backup["expected_inventory"] == expected_inventory

    invalid_legacy = yaml.safe_load(legacy_inventory)
    invalid_legacy["all"]["children"]["switches"]["hosts"][
        "clab-agentless-net-lab-leaf-2"
    ]["ansible_host"] = "192.168.162.99"
    invalid_configmap = json.dumps(
        {
            "data": {
                "AGENTLESS_NET_VN_INVENTORY": yaml.safe_dump(
                    invalid_legacy, sort_keys=False
                )
            }
        }
    )
    script = f"""
set -euo pipefail
python3 - {shlex.quote(invalid_configmap)} {shlex.quote(expected_inventory)} \
    {shlex.quote(str(backup_path))} {shlex.quote(str(patch_path))} <<'PY'
{migration}
PY
"""
    result = run_bash(tmp_path, script)

    assert result.returncode != 0
    assert "not the known legacy inventory" in result.stderr


def test_aap_ca_bundle_combines_osac_and_default_ingress_cas(tmp_path):
    helper = function_block("prepare_aap_ca_bundle", "sync_aap_project_revision")
    osac_ca = "-----BEGIN CERTIFICATE-----\nOSAC-CA\n-----END CERTIFICATE-----\n"
    ingress_ca = "-----BEGIN CERTIFICATE-----\nINGRESS-CA\n-----END CERTIFICATE-----\n"
    osac_config = json.dumps({"data": {"bundle.pem": osac_ca}})
    ingress_config = json.dumps({"data": {"ca-bundle.crt": ingress_ca}})
    ca_file = tmp_path / "combined-ca.pem"
    script = f"""
set -euo pipefail
TEMP_DIR={shlex.quote(str(tmp_path))}
OSAC_NAMESPACE=osac-e2e-ci
AAP_API_CA_FILE={shlex.quote(str(ca_file))}
die() {{ printf 'ERROR: %s\\n' "$*" >&2; exit 1; }}
oc() {{
    case "$*" in
        'get configmap ca-bundle -n osac-e2e-ci -o json') printf '%s' {shlex.quote(osac_config)} ;;
        'get configmap default-ingress-cert -n openshift-config-managed -o json') printf '%s' {shlex.quote(ingress_config)} ;;
        *) return 2 ;;
    esac
}}
{helper}
prepare_aap_ca_bundle
"""

    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    assert ca_file.read_text() == osac_ca.strip() + "\n" + ingress_ca.strip() + "\n"
    assert ca_file.stat().st_mode & 0o777 == 0o600


def test_wait_for_existing_provider_deletions_before_suite(tmp_path):
    helper = function_block(
        "wait_for_existing_provider_deletions", "restore_provider_inventory_config"
    )
    query_marker = tmp_path / "pending-seen"
    script = f"""
set -euo pipefail
NETWORKING_NAMESPACE=osac-e2e-ci
PREEXISTING_PROVIDER_CLEANUP_PENDING=true
QUERY_MARKER={shlex.quote(str(query_marker))}
oc() {{
    [[ "$*" == 'get externalippools,subnets,virtualnetworks -n osac-e2e-ci -o json' ]]
    if [[ ! -e "$QUERY_MARKER" ]]; then
        touch "$QUERY_MARKER"
        printf '%s' '{{"items":[{{"kind":"ExternalIPPool","metadata":{{"name":"stale-pool","deletionTimestamp":"now","finalizers":["pool-finalizer"]}}}}]}}'
    else
        printf '%s' '{{"items":[]}}'
    fi
}}
sleep() {{ SECONDS=$((SECONDS + 5)); }}
info() {{ :; }}
{helper}
wait_for_existing_provider_deletions
[[ "$PREEXISTING_PROVIDER_CLEANUP_PENDING" == false ]]
"""

    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    assert query_marker.exists()


def test_pending_provider_deletions_preserve_recovery_access_on_timeout(tmp_path):
    helper = function_block(
        "wait_for_existing_provider_deletions", "restore_provider_inventory_config"
    )
    script = f"""
set -euo pipefail
SECONDS=0
NETWORKING_NAMESPACE=osac-e2e-ci
PREEXISTING_PROVIDER_CLEANUP_PENDING=false
oc() {{
    printf '%s' '{{"items":[{{"kind":"ExternalIPPool","metadata":{{"name":"stale-pool","deletionTimestamp":"now","finalizers":["pool-finalizer"]}}}}]}}'
}}
sleep() {{ SECONDS=$((SECONDS + 601)); }}
info() {{ :; }}
{helper}
if wait_for_existing_provider_deletions; then exit 1; fi
[[ "$PREEXISTING_PROVIDER_CLEANUP_PENDING" == true ]]
"""

    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    assert "existing AgentlessNet provider resources remain in deletion" in result.stderr


def test_aap_subnet_reader_uses_scoped_subnet_and_lock_rbac(tmp_path):
    helper = function_block("configure_aap_subnet_reader", "cleanup_aap_subnet_reader")
    events = tmp_path / "aap-subnet-reader.log"
    script = f"""
set -euo pipefail
TEMP_DIR={shlex.quote(str(tmp_path))}
OSAC_NAMESPACE=osac-e2e-ci
NETWORKING_NAMESPACE=osac-e2e-ci
SUITE_USES_SUBNET_DHCP=true
AAP_SUBNET_READER_NAME=vlan-e2e-subnet-reader
AAP_SUBNET_LOCK_NAME=vlan-e2e-subnet-lock
AAP_SUBNET_READER_CREDENTIAL_TYPE='OSAC VLAN E2E Kubernetes API'
AAP_SUBNET_READER_CREDENTIAL=vlan-e2e-subnet-reader
AAP_PREFIX=osac
AAP_JOBS_HELPER=/tmp/aap_jobs.py
AAP_API_CA_FILE=/tmp/aap-ca.pem
EVENTS={shlex.quote(str(events))}
info() {{ :; }}
oc() {{
    printf '%s\\n' "$*" >>"$EVENTS"
    case "$*" in
        'create serviceaccount '*|'create role '*|'create rolebinding '*) printf 'kind: test\\n' ;;
        'apply -f -') cat >/dev/null ;;
        'auth can-i list subnets.osac.openshift.io'*) printf 'yes\\n' ;;
        'auth can-i get leases.coordination.k8s.io'*|'auth can-i create leases.coordination.k8s.io'*|'auth can-i update leases.coordination.k8s.io'*|'auth can-i patch leases.coordination.k8s.io'*) printf 'yes\\n' ;;
        'create token '*) printf 'service-account-token\\n' ;;
        'get configmap kube-root-ca.crt '*) printf '{{"data":{{"ca.crt":"test-ca"}}}}' ;;
        'get route osac-aap '*) printf 'aap.example.test' ;;
        'exec deployment/osac-operator '*) printf 'operator-api-token' ;;
        *) return 1 ;;
    esac
}}
python3() {{
    [[ "$1" == "$AAP_JOBS_HELPER" && "$2" == configure-k8s-credential ]]
    [[ "$AAP_API_TOKEN" == operator-api-token ]]
    [[ " $* " == *"--job-template osac-move-network-attachment"* ]]
    [[ " $* " == *"--job-template osac-query-dhcp-lease"* ]]
    [[ "$(<"$TEMP_DIR/aap-subnet-reader.token")" == service-account-token ]]
    [[ "$(<"$TEMP_DIR/aap-subnet-reader-ca.pem")" == test-ca ]]
    printf '{{"template_ids":[12,13],"credential_id":55,"credential_type_id":44}}\\n'
}}
{helper}
configure_aap_subnet_reader
[[ "$AAP_SUBNET_READER_SETUP_ATTEMPTED" == true ]]
[[ ! -e "$TEMP_DIR/aap-subnet-reader.token" && ! -e "$TEMP_DIR/aap-subnet-reader-ca.pem" ]]
grep -Fq -- '--verb=get,list --resource=subnets.osac.openshift.io' "$EVENTS"
grep -Fq -- '--verb=get,create,update,patch --resource=leases.coordination.k8s.io' "$EVENTS"
grep -Fq -- '--serviceaccount=osac-e2e-ci:vlan-e2e-subnet-reader' "$EVENTS"
grep -Fq -- 'create rolebinding vlan-e2e-subnet-lock -n osac-e2e-ci' "$EVENTS"
! grep -Fq cluster-admin "$EVENTS"
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr


def test_aap_subnet_reader_cleanup_removes_credential_before_rbac(tmp_path):
    helper = function_block("cleanup_aap_subnet_reader", "wait_for_existing_provider_deletions")
    events = tmp_path / "aap-subnet-reader-cleanup.log"
    script = f"""
set -euo pipefail
OSAC_NAMESPACE=osac-e2e-ci
NETWORKING_NAMESPACE=osac-e2e-ci
AAP_SUBNET_READER_NAME=vlan-e2e-subnet-reader
AAP_SUBNET_LOCK_NAME=vlan-e2e-subnet-lock
AAP_SUBNET_READER_CREDENTIAL_TYPE='OSAC VLAN E2E Kubernetes API'
AAP_SUBNET_READER_CREDENTIAL=vlan-e2e-subnet-reader
AAP_SUBNET_READER_SETUP_ATTEMPTED=true
AAP_PREFIX=osac
AAP_JOBS_HELPER=/tmp/aap_jobs.py
AAP_API_CA_FILE=/tmp/aap-ca.pem
EVENTS={shlex.quote(str(events))}
info() {{ :; }}
oc() {{
    printf '%s\\n' "$*" >>"$EVENTS"
    case "$*" in
        'get route osac-aap '*) printf 'aap.example.test' ;;
        'exec deployment/osac-operator '*) printf 'operator-api-token' ;;
        'delete rolebinding '*|'delete role '*|'delete serviceaccount '*) return 0 ;;
        *) return 1 ;;
    esac
}}
python3() {{
    [[ "$1" == "$AAP_JOBS_HELPER" && "$2" == cleanup-k8s-credential ]]
    [[ "$AAP_API_TOKEN" == operator-api-token ]]
    [[ " $* " == *"--job-template osac-move-network-attachment"* ]]
    [[ " $* " == *"--job-template osac-query-dhcp-lease"* ]]
    printf 'AAP credential removed\\n' >>"$EVENTS"
    printf '{{"template_ids":[12,13],"status":"removed"}}\\n'
}}
{helper}
cleanup_aap_subnet_reader
[[ "$AAP_SUBNET_READER_SETUP_ATTEMPTED" == false ]]
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    events = events.read_text().splitlines()
    assert events.index("AAP credential removed") < events.index(
        "delete rolebinding vlan-e2e-subnet-reader -n osac-e2e-ci --ignore-not-found=true --wait=true"
    )
    assert events.index("delete rolebinding vlan-e2e-subnet-reader -n osac-e2e-ci --ignore-not-found=true --wait=true") < events.index(
        "delete role vlan-e2e-subnet-reader -n osac-e2e-ci --ignore-not-found=true --wait=true"
    )
    assert events.index("delete rolebinding vlan-e2e-subnet-lock -n osac-e2e-ci --ignore-not-found=true --wait=true") < events.index(
        "delete role vlan-e2e-subnet-lock -n osac-e2e-ci --ignore-not-found=true --wait=true"
    )
    assert events.index("delete role vlan-e2e-subnet-reader -n osac-e2e-ci --ignore-not-found=true --wait=true") < events.index(
        "delete serviceaccount vlan-e2e-subnet-reader -n osac-e2e-ci --ignore-not-found=true --wait=true"
    )


def test_aap_subnet_credential_is_retained_until_provider_cleanup_succeeds(tmp_path):
    start = SOURCE.index("on_exit() {")
    end = SOURCE.index("\ntrap on_exit EXIT", start)
    on_exit = SOURCE[start:end]

    def run_cleanup(provider_succeeds: bool, label: str):
        events = tmp_path / f"{label}.log"
        provider_result = "return 0" if provider_succeeds else (
            "PRESERVE_E2E_RECOVERY_ARTIFACTS=true; return 1"
        )
        script = f"""
set -uo pipefail
CURRENT_STAGE=test
CLEANUP_MODE=false
SUITE_USES_SUBNET_DHCP=false
SUITE_USES_NAT_GATEWAY=false
SUITE_USES_EXTERNAL_IP_ATTACHMENT=false
CREATED_NAT_GATEWAY_IDS=()
VLAN_E2E_DEBUG=false
PREEXISTING_PROVIDER_CLEANUP_PENDING=false
PRESERVE_E2E_RECOVERY_ARTIFACTS=false
AAP_SUBNET_READER_SETUP_ATTEMPTED=true
RUN_DIR_CREATED=false
VLAN_E2E_RUN_DIR=
GENERATED_CLI_CONFIG=false
GENERATED_CLI_BIN=false
CLI_CA_FILE=
CUMULUS_SSH_CONFIG_CREATED_BY_RUN=false
TEMP_DIR=
EVENTS={shlex.quote(str(events))}
cleanup_created_virtual_networks() {{
    printf 'provider cleanup\\n' >>"$EVENTS"
    {provider_result}
}}
cleanup_aap_subnet_reader() {{ printf 'AAP credential cleanup\\n' >>"$EVENTS"; }}
write_run_evidence() {{ return 0; }}
info() {{ :; }}
{on_exit}
set +e
false
on_exit
"""
        return run_bash(tmp_path, script), events

    successful_run, success_events = run_cleanup(True, "provider-cleanup-success")
    failed_run, failure_events = run_cleanup(False, "provider-cleanup-failure")

    assert successful_run.returncode == 1
    assert success_events.read_text().splitlines() == [
        "provider cleanup",
        "AAP credential cleanup",
    ]
    assert failed_run.returncode == 1
    assert failure_events.read_text().splitlines() == ["provider cleanup"]


def test_provider_cleanup_keeps_aap_ca_until_subnet_credential_cleanup(tmp_path: Path) -> None:
    helper = function_block("cleanup_created_virtual_networks", "export_dhcp_debug_artifacts")
    temp_dir = tmp_path / "runner-temp"
    temp_dir.mkdir()
    ca_file = temp_dir / "aap-api-ca.pem"
    ca_file.write_text("test CA")
    script = f"""
set -euo pipefail
AAP_SUBNET_READER_SETUP_ATTEMPTED=true
SUITE_USES_NAT_GATEWAY=false
CLI_CA_FILE={shlex.quote(str(ca_file))}
AAP_API_CA_FILE={shlex.quote(str(ca_file))}
TEMP_DIR={shlex.quote(str(temp_dir))}
RUN_DIR_CREATED=false
GENERATED_CLI_CONFIG=false
GENERATED_CLI_BIN=false
CLI_CONFIG_DIR=
CLI_BIN=
CREATED_IDS=()
CREATED_SUBNET_IDS=()
CREATED_EXTERNAL_IP_IDS=()
CREATED_EXTERNAL_IP_ATTACHMENT_IDS=()
CREATED_BARE_METAL_INSTANCE_IDS=()
cleanup_created_external_ip_attachments() {{ return 0; }}
remove_external_ip_client_routes() {{ return 0; }}
cleanup_created_external_ips() {{ return 0; }}
cleanup_created_external_ip_pool() {{ return 0; }}
cleanup_created_bare_metal_instances() {{ return 0; }}
cleanup_created_subnets() {{ return 0; }}
restore_dhcp_supervisor() {{ return 0; }}
remove_netnode_public_key() {{ return 0; }}
restore_containerlab_netnode_access() {{ return 0; }}
remove_containerlab_switch_keys() {{ return 0; }}
restore_containerlab_switch_access() {{ return 0; }}
restore_netnode_download_network() {{ return 0; }}
restore_provider_inventory_config() {{ return 0; }}
restore_aap_ssh_key() {{ return 0; }}
info() {{ :; }}
{helper}
cleanup_created_virtual_networks 1
[[ -f "$CLI_CA_FILE" ]]
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    assert temp_dir.is_dir()


def test_repeated_dhcp_lease_queries_use_distinct_private_result_files(tmp_path: Path) -> None:
    helper = function_block("discover_client_dhcp_lease", "offboard_client_from_subnet")
    (tmp_path / "client-a1.mac").write_text("02:00:00:00:00:01\n")
    (tmp_path / "client-a1.lease.json").write_text('{"address":"10.0.0.2"}\n')
    capture = tmp_path / "result-paths.txt"
    script = f"""
set -euo pipefail
TEMP_DIR={shlex.quote(str(tmp_path))}
AAP_JOB_RESULT_SEQUENCE=0
CAPTURE={shlex.quote(str(capture))}
declare -A CLIENT_ATTACHMENT_SUBNET=([a1]=11234567-89ab-cdef-0123-456789abcdef)
declare -A CLIENT_ATTACHMENT_ACTIVE=([a1]=true)
write_client_bmi_extra_vars() {{ :; }}
run_agentless_net_aap_job() {{
    [[ "$1" == query-dhcp-lease ]]
    printf '%s\\n' "$3" >>"$CAPTURE"
    printf '%s\\n' '{{"artifacts":{{"leases":[{{"subnet_ref":"11234567-89ab-cdef-0123-456789abcdef","interface":"eth0","mac_address":"02:00:00:00:00:01","ip_address":"10.0.0.2"}}]}}}}' >"$3"
}}
info() {{ :; }}
die() {{ printf 'ERROR: %s\\n' "$*" >&2; exit 1; }}
{helper}
discover_client_dhcp_lease a1
discover_client_dhcp_lease a1
[[ "$(wc -l <"$CAPTURE")" -eq 2 ]]
result_one="$(sed -n '1p' "$CAPTURE")"
result_two="$(sed -n '2p' "$CAPTURE")"
[[ "$result_one" != "$result_two" ]]
[[ -s "$result_one" && -s "$result_two" ]]
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr


def test_bmi_extra_vars_reuse_identity_for_move_and_query_and_mark_offboard(tmp_path):
    helpers = function_block("write_client_bmi_extra_vars", "attach_client_to_subnet")
    variables = tmp_path / "client-vars"
    script = f"""
set -euo pipefail
TEMP_DIR={shlex.quote(str(tmp_path))}
OSAC_NAMESPACE=osac-e2e-ci
OSAC_TENANT=osac-e2e-ci
declare -A CLIENT_BMI_UID=([a1]=01234567-89ab-cdef-0123-456789abcdef)
declare -A CLIENT_PRESERVED_MAC=([a1]=02:00:00:00:00:01)
{helpers}
write_client_bmi_extra_vars a1 11234567-89ab-cdef-0123-456789abcdef {shlex.quote(str(variables / 'attach.json'))} false
write_client_bmi_extra_vars a1 11234567-89ab-cdef-0123-456789abcdef {shlex.quote(str(variables / 'query.json'))} query
write_client_bmi_extra_vars a1 11234567-89ab-cdef-0123-456789abcdef {shlex.quote(str(variables / 'offboard.json'))} true
jq -e '
  .osac_job_vars.resource.kind == "BareMetalInstance"
  and .osac_job_vars.resource.metadata.annotations["osac.openshift.io/tenant"] == "osac-e2e-ci"
  and .osac_job_vars.resource.metadata.annotations["osac.openshift.io/owner-reference"] == "vlan-e2e-run"
  and .osac_job_vars.resource.metadata.annotations["osac.openshift.io/implementation-strategy"] == "agentless_net"
  and .osac_job_vars.resource.metadata.uid == "01234567-89ab-cdef-0123-456789abcdef"
  and .osac_job_vars.resource.spec.externalHostID == "osac-e2e-a1"
  and .osac_job_vars.resource.spec.networkAttachments == [{{"subnetRef":"11234567-89ab-cdef-0123-456789abcdef","interface":"eth0","primary":true}}]
' {shlex.quote(str(variables / 'attach.json'))} >/dev/null
jq -e '.osac_job_vars.network_attachment_macs["11234567-89ab-cdef-0123-456789abcdef"] == "02:00:00:00:00:01"' \
  {shlex.quote(str(variables / 'query.json'))} >/dev/null
jq -e '
  .osac_job_vars.resource.metadata.deletionTimestamp
  | test("^[0-9]{{4}}-[0-9]{{2}}-[0-9]{{2}}T.*Z$")
' {shlex.quote(str(variables / 'offboard.json'))} >/dev/null
"""
    variables.mkdir()
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    assert (variables / "attach.json").stat().st_mode & 0o777 == 0o600
    assert (variables / "query.json").stat().st_mode & 0o777 == 0o600
    assert (variables / "offboard.json").stat().st_mode & 0o777 == 0o600


def test_client_attachment_is_idempotent_and_offboard_reuses_bmi_uid(tmp_path):
    helpers = (
        function_block("write_client_bmi_extra_vars", "attach_client_to_subnet")
        + "\n"
        + function_block("attach_client_to_subnet", "discover_client_dhcp_lease")
        + "\n"
        + function_block("offboard_client_from_subnet", "write_agentless_e2e_helpers")
    )
    mac_file = tmp_path / "client-a1.mac"
    mac_file.write_text("02:00:00:00:00:01\n")
    script = f"""
set -euo pipefail
TEMP_DIR={shlex.quote(str(tmp_path))}
AAP_JOB_RESULT_SEQUENCE=0
OSAC_NAMESPACE=osac-e2e-ci
OSAC_TENANT=osac-e2e-ci
declare -A CLIENT_ATTACHMENT_ACTIVE=()
declare -A CLIENT_ATTACHMENT_PENDING=()
declare -A CLIENT_ATTACHMENT_SUBNET=()
declare -A CLIENT_BMI_UID=()
declare -A CLIENT_PRESERVED_MAC=()
JOB_CALLS=0
run_agentless_net_aap_job() {{
    local suffix="$1" vars="$2" output="$3"
    [[ "$suffix" == move-network-attachment ]]
    JOB_CALLS=$((JOB_CALLS + 1))
    cp "$vars" "$TEMP_DIR/job-$JOB_CALLS.json"
    printf '%s\\n' "$output" >>"$TEMP_DIR/result-paths.txt"
    printf '{{"job_id":%d,"status":"successful","artifacts":{{}}}}\\n' "$JOB_CALLS" >"$output"
}}
info() {{ :; }}
die() {{ printf 'ERROR: %s\\n' "$*" >&2; exit 1; }}
{helpers}
attach_client_to_subnet a1 11234567-89ab-cdef-0123-456789abcdef
first_uid="${{CLIENT_BMI_UID[a1]}}"
attach_client_to_subnet a1 11234567-89ab-cdef-0123-456789abcdef
[[ "$JOB_CALLS" == 1 && "${{CLIENT_ATTACHMENT_ACTIVE[a1]}}" == true ]]
[[ "${{CLIENT_ATTACHMENT_PENDING[a1]}}" == false ]]
offboard_client_from_subnet a1
[[ "$JOB_CALLS" == 2 && "${{CLIENT_ATTACHMENT_ACTIVE[a1]}}" == false ]]
[[ -z "${{CLIENT_BMI_UID[a1]:-}}" && -z "${{CLIENT_ATTACHMENT_SUBNET[a1]:-}}" ]]
attach_client_to_subnet a1 11234567-89ab-cdef-0123-456789abcdef
[[ "$JOB_CALLS" == 3 && "${{CLIENT_ATTACHMENT_ACTIVE[a1]}}" == true ]]
[[ "${{CLIENT_BMI_UID[a1]}}" != "$first_uid" ]]
[[ "$(sort -u "$TEMP_DIR/result-paths.txt" | wc -l)" == 3 ]]
jq -e --arg uid "$first_uid" '
  .osac_job_vars.resource.metadata.uid == $uid
  and .osac_job_vars.resource.metadata.deletionTimestamp != null
' "$TEMP_DIR/job-2.json" >/dev/null
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr


def test_client_cleanup_keeps_links_and_resources_when_offboarding_fails(tmp_path):
    helper = function_block("cleanup_dhcp_clients_and_attachments", "write_client_lease_expectations")
    events = tmp_path / "cleanup.log"
    script = f"""
set -euo pipefail
TEMP_DIR={shlex.quote(str(tmp_path))}
EVENTS={shlex.quote(str(events))}
declare -a DHCP_CLIENT_CONTAINERS=(test-run-a1)
declare -a DHCP_CLIENT_HOST_LINKS=(m12345678-a1)
declare -A CLIENT_ATTACHMENT_ACTIVE=([a1]=true)
declare -A CLIENT_ATTACHMENT_PENDING=([a1]=false)
client_container() {{ printf 'test-run-%s' "$1"; }}
stop_dhcp_client() {{ printf 'stop %s\\n' "$1" >>"$EVENTS"; }}
offboard_client_from_subnet() {{ return 1; }}
docker() {{
    printf 'docker %s\\n' "$*" >>"$EVENTS"
    case "$1 $2" in
        'inspect test-run-a1'|'exec test-run-a1') return 0 ;;
        *) return 2 ;;
    esac
}}
sudo() {{ printf 'sudo %s\\n' "$*" >>"$EVENTS"; return 0; }}
{helper}
if cleanup_dhcp_clients_and_attachments; then exit 1; fi
! grep -Fq 'docker rm -f test-run-a1' "$EVENTS"
! grep -Fq 'sudo ip link delete dev m12345678-a1' "$EVENTS"
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr


def test_dhcp_client_creation_restores_saved_mac_before_moving_macvlan(tmp_path):
    helper = function_block("create_dhcp_client_container", "create_dhcp_client_containers")
    events = tmp_path / "events.log"
    hook = tmp_path / "udhcpc-hook.sh"
    hook.write_text("#!/bin/sh\n")
    script = f"""
set -euo pipefail
TEMP_DIR={shlex.quote(str(tmp_path))}
DHCP_CLIENT_PREFIX=test-run
CLIENT_IMAGE=busybox:1.36.1
CLIENT_HOST_PARENT=leaf2-swp3
DHCP_CLIENT_HOOK={shlex.quote(str(hook))}
EVENTS={shlex.quote(str(events))}
declare -a DHCP_CLIENT_CONTAINERS=()
declare -a DHCP_CLIENT_HOST_LINKS=()
declare -A CLIENT_PRESERVED_MAC=([b1]=02:00:00:00:00:01)
client_link() {{ CLIENT_HOST_PARENT=leaf2-swp3; }}
client_container() {{ printf 'test-run-%s' "$1"; }}
client_macvlan_name() {{ printf 'm12345678-%s' "$1"; }}
info() {{ :; }}
die() {{ printf 'ERROR: %s\\n' "$*" >&2; exit 1; }}
sudo() {{
    [[ "$1" == ip && "$2" == link ]]
    printf 'sudo %s\\n' "$*" >>"$EVENTS"
}}
docker() {{
    case "$1 $2" in
        'run -d') printf 'container-id\\n' ;;
        'inspect -f') printf '1234\\n' ;;
        'exec test-run-b1')
            shift 2
            if [[ "$1" == cat ]]; then
                printf '02:00:00:00:00:01\\n'
            fi
            printf 'docker exec %s\\n' "$*" >>"$EVENTS"
            ;;
        cp*) printf 'docker cp\\n' >>"$EVENTS" ;;
        *) return 2 ;;
    esac
}}
{helper}
create_dhcp_client_container b1
[[ "$(<"$TEMP_DIR/client-b1.mac")" == 02:00:00:00:00:01 ]]
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    operations = events.read_text().splitlines()
    set_mac = next(i for i, event in enumerate(operations) if "address 02:00:00:00:00:01" in event)
    move_netns = next(i for i, event in enumerate(operations) if "netns 1234" in event)
    assert set_mac < move_netns


def test_runtime_source_pins_the_implementation_commit_and_requires_it_as_ancestor(tmp_path: Path) -> None:
    repository = tmp_path / "repository"
    repository.mkdir()

    def git(*arguments: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(repository), *arguments],
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()

    git("init", "--initial-branch=main")
    git("config", "user.name", "E2E Test")
    git("config", "user.email", "e2e@example.invalid")
    production_file = repository / "osac-aap" / "source.py"
    production_file.parent.mkdir()
    production_file.write_text("fix source\n")
    git("add", "osac-aap/source.py")
    git("commit", "-m", "base")
    git("checkout", "-b", "osac-6202-natgateway-snat")
    production_file.write_text("implementation source\n")
    git("commit", "-am", "implementation")
    implementation_commit = git("rev-parse", "HEAD")
    git("checkout", "-b", "e2e")
    (repository / "vlan-e2e.sh").write_text("runner update\n")
    git("add", "vlan-e2e.sh")
    git("commit", "-m", "runner")

    helper_start = SOURCE.index("resolve_runtime_source() {")
    helper_end = SOURCE.index("\n}\n", helper_start) + 3
    helper = SOURCE[helper_start:helper_end]
    script = f"""
set -euo pipefail
{helper}
resolve_runtime_source {shlex.quote(str(repository))} osac-6202-natgateway-snat
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines() == ["osac-6202-natgateway-snat", implementation_commit]
    assert git("merge-base", "osac-6202-natgateway-snat", "HEAD") == implementation_commit
    assert subprocess.run(
        ["git", "-C", str(repository), "diff", "--quiet", "osac-6202-natgateway-snat", "HEAD", "--", "osac-aap"]
    ).returncode == 0

    git("checkout", "osac-6202-natgateway-snat")
    production_file.write_text("implementation advanced\n")
    git("commit", "-am", "advance implementation")
    git("checkout", "e2e")
    assert subprocess.run(
        ["git", "-C", str(repository), "diff", "--quiet", "osac-6202-natgateway-snat", "HEAD", "--", "osac-aap"]
    ).returncode == 1
    advanced = run_bash(tmp_path, script)
    assert advanced.returncode != 0


def test_runtime_source_rejects_a_missing_implementation_branch(tmp_path: Path) -> None:
    repository = tmp_path / "repository"
    repository.mkdir()
    subprocess.run(["git", "-C", str(repository), "init", "--initial-branch=main"], check=True)
    subprocess.run(["git", "-C", str(repository), "config", "user.name", "E2E Test"], check=True)
    subprocess.run(["git", "-C", str(repository), "config", "user.email", "e2e@example.invalid"], check=True)
    source = repository / "osac-aap" / "source.py"
    source.parent.mkdir()
    source.write_text("base\n")
    subprocess.run(["git", "-C", str(repository), "add", "osac-aap/source.py"], check=True)
    subprocess.run(["git", "-C", str(repository), "commit", "-m", "base"], check=True)

    helper_start = SOURCE.index("resolve_runtime_source() {")
    helper_end = SOURCE.index("\n}\n", helper_start) + 3
    helper = SOURCE[helper_start:helper_end]
    result = run_bash(
        tmp_path,
        f"set -euo pipefail\n{helper}\n"
        f"resolve_runtime_source {shlex.quote(str(repository))} "
        "osac-6202-natgateway-snat\n",
    )
    assert result.returncode != 0


def test_runner_stages_are_ordered_and_source_revision_is_pinned():
    stage_markers = [
        'step "STEP 1 OF 5:',
        'step "STEP 2 OF 5:',
        'step "STEP 3 OF 5:',
        'step "STEP 4 OF 5:',
        'step "STEP 5 OF 5:',
    ]
    positions = [SOURCE.index(marker) for marker in stage_markers]

    assert positions == sorted(positions)
    assert 'AAP_PROJECT_GIT_BRANCH" == "$RUNTIME_SOURCE_BRANCH"' in SOURCE
    assert 'AAP_PROJECT_EXPECTED_REVISION" == "$RUNTIME_SOURCE_COMMIT"' in SOURCE
    assert 'IMAGE_SOURCE_COMMIT="$RUNTIME_SOURCE_COMMIT"' in SOURCE


def test_full_suite_runs_attachment_lifecycle_after_creating_its_network_and_client():
    suite = function_block("run_full_suite", "run_virtual_network_suite")

    assert suite.index("create_external_ip_pool") < suite.index("run_external_ip_lifecycle")
    assert suite.index("run_subnet_dhcp_checks") < suite.index(
        "create_external_ip_attachment_test_network_and_client"
    )
    assert suite.index("create_external_ip_attachment_test_network_and_client") < suite.index(
        "run_external_ip_lifecycle"
    )
    assert suite.index("run_external_ip_lifecycle") < suite.index("run_nat_gateway_lifecycle")


def test_external_ip_suite_selects_attachment_dependencies_but_pool_suite_stays_scoped(tmp_path: Path) -> None:
    start = SOURCE.index('case "$VLAN_E2E_SUITE" in')
    end = SOURCE.index("\nREPO_ROOT=", start)
    suite_flags = SOURCE[start:end]

    def resolve(suite: str) -> subprocess.CompletedProcess[str]:
        return run_bash(
            tmp_path,
            "set -euo pipefail\n"
            f'VLAN_E2E_SUITE="{suite}"\n'
            f"{suite_flags}\n"
            "printf '%s\\n' \"$SUITE_USES_VN $SUITE_USES_SUBNET $SUITE_USES_SUBNET_DHCP "
            "$SUITE_USES_POOL $SUITE_USES_CLI $SUITE_USES_EXTERNAL_IP "
            '$SUITE_USES_EXTERNAL_IP_ATTACHMENT $SUITE_USES_NAT_GATEWAY"\n',
        )

    result = resolve("external-ip")
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "true true true true true true true false"

    result = resolve("external-ip-pool")
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "false false false true false false false false"


def test_external_ip_probe_uses_upstream_route_and_allocated_external_ip(tmp_path: Path) -> None:
    route = function_block("add_external_ip_client_route", "remove_external_ip_client_route")
    probe = function_block("probe_external_ip_response", "assert_external_ip_attachment_provider_absent")
    events = tmp_path / "external-ip-probe.log"
    script = f"""
set -euo pipefail
CONTAINERLAB_UPSTREAM_ROUTER=upstream-router
MGMT_PREFIX=192.0.2
EXTERNAL_IP_CLIENT_ROUTE_INTERFACE=eth0
EXTERNAL_IP_TEST_LINK_NODE_ADDRESS=192.0.2.1
EXTERNAL_IP_CLIENT_ROUTE_GATEWAY=
EXTERNAL_IP_CLIENT_ROUTE_ADDRESSES=()
EXTERNAL_IP_RESPONSE_PORT=18080
EVENTS={shlex.quote(str(events))}
docker() {{
    printf '%s\\n' "$*" >>"$EVENTS"
    if [[ "$*" == *"wget "* ]]; then printf 'response-token\\n'; fi
}}
{route}
{probe}
add_external_ip_client_route 198.51.100.21
[[ "$(probe_external_ip_response 198.51.100.21)" == response-token ]]
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    operations = events.read_text().splitlines()
    assert any("ip route add 198.51.100.21/32 via 192.0.2.1 dev eth0" in line for line in operations)
    assert any("http://198.51.100.21:18080/osac-eia-response" in line for line in operations)
    assert all("10.250." not in line for line in operations)


def test_external_ip_cleanup_orders_detach_before_dependent_resources() -> None:
    cleanup = function_block("cleanup_created_virtual_networks", "on_exit")

    positions = [
        cleanup.index("cleanup_created_external_ip_attachments"),
        cleanup.index("remove_external_ip_client_routes"),
        cleanup.index("cleanup_created_external_ips"),
        cleanup.index("cleanup_created_external_ip_pool"),
        cleanup.index("cleanup_created_bare_metal_instances"),
        cleanup.index("cleanup_created_subnets"),
        cleanup.index('delete virtualnetwork "$id"'),
    ]
    assert positions == sorted(positions)


def test_nat_gateway_cleanup_precedes_clients_and_all_network_dependencies() -> None:
    cleanup = function_block("cleanup_created_virtual_networks", "export_dhcp_debug_artifacts")
    positions = [
        cleanup.index("cleanup_created_nat_gateways"),
        cleanup.index("cleanup_nat_gateway_endpoint"),
        cleanup.index("cleanup_created_external_ip_attachments"),
        cleanup.index("remove_external_ip_client_routes"),
        cleanup.index("cleanup_created_external_ips"),
        cleanup.index("cleanup_created_external_ip_pool"),
        cleanup.index("cleanup_created_subnets"),
        cleanup.index('delete virtualnetwork "$id"'),
        cleanup.index("restore_nat_gateway_uplink"),
        cleanup.index("restore_provider_inventory_config"),
    ]
    assert positions == sorted(positions)

    start = SOURCE.index("on_exit() {")
    end = SOURCE.index("\ntrap on_exit EXIT", start)
    on_exit = SOURCE[start:end]
    assert on_exit.index("cleanup_created_nat_gateways") < on_exit.index(
        "cleanup_dhcp_clients_and_attachments"
    )


def test_nat_gateway_cleanup_discovery_scopes_crs_and_provider_identity() -> None:
    cleanup = function_block("prepare_suite_cleanup", "supervisor_service_status_is_absent")

    assert "nat_gateway_filter='this.metadata.name.startsWith(\"agentless-natgw-\")'" in cleanup
    assert 'nat_gateway_cr_json "$nat_gateway_id"' in cleanup
    assert '"osac.openshift.io/natgateway-contract-version"] == "v1"' in SOURCE
    assert ".[0].virtual_network_uid == $vn_uid" in cleanup
    assert ".[0].external_ip_uid == $eip_uid" in cleanup
    assert "test NATGateway provider row without a matching test CR" in cleanup


def test_nat_gateway_uplink_override_and_restore_are_guarded() -> None:
    configure = function_block("configure_nat_gateway_uplink", "restore_nat_gateway_uplink")
    restore = function_block("restore_nat_gateway_uplink", "remove_netnode_public_key")

    assert '"/metadata/resourceVersion",value:$rv' in configure
    assert '"/data/AGENTLESS_NET_EXTERNAL_INTERFACE",value:"eth2"' in configure
    assert "original_annotations_present" in configure
    assert '"/metadata/resourceVersion",value:$rv' in restore
    assert '"/data/AGENTLESS_NET_EXTERNAL_INTERFACE",value:"eth2"' in restore
    assert "$backup[0].original_present" in restore
    assert "annotations_empty_after_restore" in restore
    assert "NATGateway uplink override changed; preserving its current ConfigMap value" in restore


@pytest.mark.parametrize("original_value", [None, "eth1"])
def test_nat_gateway_uplink_override_restores_the_original_configmap(
    tmp_path: Path, original_value: str | None
) -> None:
    configure = function_block("configure_nat_gateway_uplink", "restore_nat_gateway_uplink")
    restore = function_block("restore_nat_gateway_uplink", "remove_netnode_public_key")
    temp_dir = tmp_path / "uplink-override"
    temp_dir.mkdir()
    data = {"OTHER_SETTING": "preserve"}
    if original_value is not None:
        data["AGENTLESS_NET_EXTERNAL_INTERFACE"] = original_value
    initial = json.dumps({"metadata": {"resourceVersion": "10"}, "data": data})
    script = f"""
set -euo pipefail
SUITE_USES_NAT_GATEWAY=true
CLEANUP_MODE=false
DHCP_CLIENT_PREFIX=test-run
NAT_GATEWAY_UPLINK_OWNER_ANNOTATION=osac.openshift.io/vlan-e2e-natgw-uplink-owner
NAT_GATEWAY_UPLINK_BACKUP_ANNOTATION=osac.openshift.io/vlan-e2e-natgw-uplink-original
NAT_GATEWAY_UPLINK_CHANGED_BY_RUN=false
NAT_GATEWAY_UPLINK_BACKUP=
NAT_GATEWAY_UPLINK_OWNER=
NAT_GATEWAY_UPLINK_EXPECTED=
AAP_NETWORKING_SECRET=network-fulfillment-ig
OSAC_NAMESPACE=osac-e2e-ci
TEMP_DIR={shlex.quote(str(temp_dir))}
PATCH_COUNT=0
CONFIG_PATCH_FILE=
RESTORE_PATCH_FILE=
OWNER_PATCH_PATH=/metadata/annotations/osac.openshift.io~1vlan-e2e-natgw-uplink-owner
BACKUP_PATCH_PATH=/metadata/annotations/osac.openshift.io~1vlan-e2e-natgw-uplink-original
die() {{ printf '%s\\n' "$*" >&2; exit 1; }}
info() {{ :; }}
oc() {{
    if [[ "$1" == get ]]; then
        case "$PATCH_COUNT" in
            0|2) jq -c . <<<"$INITIAL_CONFIG_MAP" ;;
            1)
                owner="$(jq -r --arg path "$OWNER_PATCH_PATH" \
                    '[.[] | select(.path == $path)][0].value' "$CONFIG_PATCH_FILE")"
                backup="$(jq -r --arg path "$BACKUP_PATCH_PATH" \
                    '[.[] | select(.path == $path)][0].value' "$CONFIG_PATCH_FILE")"
                jq -cn --argjson initial "$INITIAL_CONFIG_MAP" --arg owner "$owner" --arg backup "$backup" '
                  $initial
                  | .metadata.resourceVersion = "12"
                  | .metadata.annotations = ((.metadata.annotations // {{}}) + {{
                      "osac.openshift.io/vlan-e2e-natgw-uplink-owner": $owner,
                      "osac.openshift.io/vlan-e2e-natgw-uplink-original": $backup
                    }})
                  | .data.AGENTLESS_NET_EXTERNAL_INTERFACE = "eth2"'
                ;;
        esac
    elif [[ "$1" == patch ]]; then
        PATCH_COUNT=$((PATCH_COUNT + 1))
        for argument in "$@"; do
            case "$argument" in
                --patch-file=*)
                    if [[ "$PATCH_COUNT" == 1 ]]; then
                        CONFIG_PATCH_FILE="${{argument#*=}}"
                    else
                        RESTORE_PATCH_FILE="${{argument#*=}}"
                    fi
                    ;;
            esac
        done
    else
        return 1
    fi
}}
{configure}
{restore}
configure_nat_gateway_uplink
restore_nat_gateway_uplink
[[ "$NAT_GATEWAY_UPLINK_CHANGED_BY_RUN" == false ]]
[[ "$PATCH_COUNT" == 2 ]]
jq -e --arg rv 10 'any(.[]; .op == "test" and .path == "/metadata/resourceVersion" and .value == $rv)' \
    "$CONFIG_PATCH_FILE" >/dev/null
jq -e --arg rv 12 'any(.[]; .op == "test" and .path == "/metadata/resourceVersion" and .value == $rv)' \
    "$RESTORE_PATCH_FILE" >/dev/null
"""
    result = run_bash(tmp_path, script, {"INITIAL_CONFIG_MAP": initial})

    assert result.returncode == 0, result.stderr
    restore_patch = json.loads((temp_dir / "nat-gateway-uplink-restore.json").read_text())
    data_path = "/data/AGENTLESS_NET_EXTERNAL_INTERFACE"
    if original_value is None:
        assert any(
            operation.get("op") == "remove" and operation.get("path") == data_path
            for operation in restore_patch
        )
        assert any(
            operation.get("op") == "remove" and operation.get("path") == "/metadata/annotations"
            for operation in restore_patch
        )
    else:
        assert any(
            operation.get("op") == "replace"
            and operation.get("path") == data_path
            and operation.get("value") == original_value
            for operation in restore_patch
        )


def test_failed_nat_gateway_cleanup_preserves_all_dependencies(tmp_path: Path) -> None:
    cleanup = function_block("cleanup_created_virtual_networks", "export_dhcp_debug_artifacts")
    events = tmp_path / "failed-nat-gateway-cleanup.log"
    script = f"""
set -euo pipefail
CLEANUP_MODE=false
CLEANUP_DISCOVERY_COMPLETE=false
CLEANUP_PENDING_POOL_IDS=()
SUITE_USES_NAT_GATEWAY=true
CREATED_NAT_GATEWAY_IDS=(natgateway-id)
CREATED_EXTERNAL_IP_ATTACHMENT_IDS=()
CREATED_EXTERNAL_IP_IDS=(external-ip-id)
CREATED_BARE_METAL_INSTANCE_IDS=(bmi-id)
CREATED_SUBNET_IDS=(subnet-id)
CREATED_IDS=()
TEMP_DIR=/tmp
CLI_BIN=/bin/true
CLI_CONFIG_DIR=/tmp
EXTERNAL_IP_POOL_PENDING_CLEANUP=true
PRESERVE_E2E_RECOVERY_ARTIFACTS=false
EVENTS={shlex.quote(str(events))}
cleanup_created_nat_gateways() {{ printf 'nat-gateway\\n' >>"$EVENTS"; return 1; }}
cleanup_nat_gateway_endpoint() {{ printf 'endpoint\\n' >>"$EVENTS"; return 0; }}
cleanup_created_external_ip_attachments() {{ printf 'attachment\\n' >>"$EVENTS"; return 0; }}
remove_external_ip_client_routes() {{ printf 'route\\n' >>"$EVENTS"; return 0; }}
cleanup_created_external_ips() {{ printf 'external-ip\\n' >>"$EVENTS"; return 0; }}
cleanup_created_external_ip_pool() {{ printf 'pool\\n' >>"$EVENTS"; return 0; }}
cleanup_created_bare_metal_instances() {{ printf 'bmi\\n' >>"$EVENTS"; return 0; }}
cleanup_created_subnets() {{ printf 'subnet\\n' >>"$EVENTS"; return 0; }}
restore_nat_gateway_uplink() {{ printf 'uplink\\n' >>"$EVENTS"; return 0; }}
restore_provider_inventory_config() {{ printf 'inventory\\n' >>"$EVENTS"; return 0; }}
info() {{ :; }}
{cleanup}
if cleanup_created_virtual_networks 0; then exit 1; fi
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    assert events.read_text().splitlines() == ["nat-gateway"]


def test_failed_attachment_detach_preserves_all_dependent_resources(tmp_path: Path) -> None:
    cleanup = function_block("cleanup_created_virtual_networks", "on_exit")
    events = tmp_path / "failed-attachment-cleanup.log"
    script = f"""
set -euo pipefail
CLEANUP_MODE=false
CLEANUP_DISCOVERY_COMPLETE=false
CLEANUP_PENDING_POOL_IDS=()
SUITE_USES_NAT_GATEWAY=false
CREATED_EXTERNAL_IP_ATTACHMENT_IDS=(attachment-id)
CREATED_NAT_GATEWAY_IDS=()
CREATED_EXTERNAL_IP_IDS=(external-ip-id)
CREATED_BARE_METAL_INSTANCE_IDS=(bmi-id)
CREATED_SUBNET_IDS=(subnet-id)
CREATED_IDS=(vn-id)
TEMP_DIR=/tmp
CLI_BIN=
CLI_CONFIG_DIR=
EXTERNAL_IP_POOL_PENDING_CLEANUP=true
PRESERVE_E2E_RECOVERY_ARTIFACTS=false
EVENTS={shlex.quote(str(events))}
cleanup_created_external_ip_attachments() {{ printf 'detach\\n' >>"$EVENTS"; return 1; }}
remove_external_ip_client_routes() {{ printf 'route\\n' >>"$EVENTS"; return 0; }}
cleanup_created_external_ips() {{ printf 'external-ip\\n' >>"$EVENTS"; return 0; }}
cleanup_created_external_ip_pool() {{ printf 'pool\\n' >>"$EVENTS"; return 0; }}
cleanup_created_bare_metal_instances() {{ printf 'bmi\\n' >>"$EVENTS"; return 0; }}
cleanup_created_subnets() {{ printf 'subnet\\n' >>"$EVENTS"; return 0; }}
info() {{ :; }}
{cleanup}
if cleanup_created_virtual_networks 0; then exit 1; fi
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    assert events.read_text().splitlines() == ["detach"]


def test_standalone_external_ip_cleanup_is_idempotent_for_absent_attachment(tmp_path: Path) -> None:
    remove_id = function_block("external_ip_attachment_remove_created_id", "delete_external_ip_attachment_and_verify")
    cleanup = function_block("cleanup_created_external_ip_attachments", "remove_external_ip_client_routes")
    script = f"""
set -euo pipefail
CLI_BIN=/bin/true
CLI_CONFIG_DIR=/tmp
CREATED_EXTERNAL_IP_ATTACHMENT_IDS=(already-removed)
CREATED_SYNTHETIC_EXTERNAL_IP_ATTACHMENT_IDS=()
CREATED_SYNTHETIC_EXTERNAL_IP_ATTACHMENT_UIDS=()
CREATED_EXTERNAL_IP_IDS=()
CREATED_BARE_METAL_INSTANCE_IDS=()
state_snapshot() {{ printf '{{"external_ip_attachments":[]}}\\n'; }}
external_ip_attachment_crs_json() {{ printf '{{"items":[]}}\\n'; }}
{remove_id}
{cleanup}
cleanup_created_external_ip_attachments
[[ "${{#CREATED_EXTERNAL_IP_ATTACHMENT_IDS[@]}}" == 0 ]]
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr


def test_external_ip_state_snapshot_and_peer_checks_include_attachments() -> None:
    assert '"external_ip_attachments": attachment_entries' in SOURCE
    assert "external_ip_attachments external_ip_attachments" not in SOURCE
    assert "for collection in virtual_networks subnets external_ip_pools external_ips external_ip_attachments" in SOURCE
    assert 'peer_state="$(external_ip_attachment_state_entry' in SOURCE
    assert "changed its peer attachment state" in SOURCE


def test_external_ip_attachment_uses_a_synthetic_dhcp_client_target() -> None:
    setup = function_block(
        "create_external_ip_attachment_test_network_and_client", "cleanup_created_bare_metal_instances"
    )

    assert 'client="$EXTERNAL_IP_SYNTHETIC_CLIENT"' in setup
    assert 'attach_client_to_subnet "$client" "$EXTERNAL_IP_ATTACHMENT_SUBNET_ID"' in setup
    assert 'discover_client_dhcp_lease "$client"' in setup
    assert 'EXTERNAL_IP_SYNTHETIC_TARGET_UID="${CLIENT_BMI_UID[$client]:-}"' in setup
    assert 'EXTERNAL_IP_SYNTHETIC_TARGET_IP=' in setup
    assert 'create baremetalinstance' not in setup
    assert 'catalog-item' not in setup
    assert '"kind": "BareMetalInstance"' not in setup


def test_external_ip_synthetic_target_serves_the_expected_response() -> None:
    setup = function_block(
        "create_external_ip_attachment_test_network_and_client", "cleanup_created_bare_metal_instances"
    )

    assert 'docker cp "$response_file" "$container:/tmp/osac-eia-response"' in setup
    assert 'docker exec -d "$container" busybox httpd' in setup
    assert '"http://127.0.0.1:${EXTERNAL_IP_RESPONSE_PORT}/osac-eia-response"' in setup
    assert '[[ "$response" == "$EXTERNAL_IP_RESPONSE_TOKEN" ]]' in setup


def test_attachment_cleanup_discovery_checks_prefix_tenant_and_parent_scope() -> None:
    cleanup = function_block("prepare_suite_cleanup", "supervisor_service_status_is_absent")

    assert "bmi_filter='this.metadata.name.startsWith(\"agentless-eip-bmi-\")'" in cleanup
    assert "attachment_filter='this.metadata.name.startsWith(\"agentless-eip-attach-\")'" in cleanup
    assert "all(.[]; .metadata.tenant == $tenant" in cleanup
    assert "references an ExternalIP outside the test name scope" in cleanup
    assert "references a BMI outside the test name scope" in cleanup


def test_state_snapshot_includes_attachment_rows_and_accepts_existing_schema_v1(tmp_path: Path) -> None:
    helper = function_block("state_snapshot", "save_current_state")
    body_start = helper.index("<<'PY'\n") + len("<<'PY'\n")
    body_end = helper.index("\nPY\n", body_start)
    snapshot_code = helper[body_start:body_end]

    def create_state(
        path: Path, *, attachments: bool, nat_gateways: bool = False, unknown_table: bool = False
    ) -> None:
        connection = sqlite3.connect(path)
        connection.executescript(
            """
            CREATE TABLE virtual_networks (uid TEXT, tenant_id TEXT, virtual_network_cidr TEXT,
              namespace_name TEXT, namespace_interface TEXT, host_interface TEXT,
              transit_cidr TEXT, transit_start TEXT, payload TEXT);
            CREATE TABLE subnets (uid TEXT, virtual_network_uid TEXT, tenant_id TEXT, vlan_id INTEGER,
              vlan_interface TEXT, ipv4_cidr TEXT, phase TEXT, payload TEXT);
            CREATE TABLE external_ip_pools (uid TEXT, fulfillment_id TEXT, tenant_id TEXT,
              ip_family TEXT, ipv4_cidr TEXT);
            CREATE TABLE external_ips (uid TEXT, fulfillment_id TEXT, tenant_id TEXT,
              pool_uid TEXT, address TEXT);
            """
        )
        if attachments:
            connection.executescript(
                """
                CREATE TABLE attachments (uid TEXT, fulfillment_id TEXT, tenant_id TEXT,
                  external_ip_uid TEXT, virtual_network_uid TEXT, subnet_uid TEXT,
                  external_address TEXT, phase TEXT, payload TEXT);
                """
            )
            connection.execute(
                "INSERT INTO attachments VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    "attachment-uid",
                    "attachment-id",
                    "test-tenant",
                    "eip-uid",
                    "vn-uid",
                    "subnet-uid",
                    "198.51.100.21",
                    "ready",
                    json.dumps({"context": {"target": {"ip_address": "10.250.1.5"}}}),
                ),
            )
        if nat_gateways:
            connection.executescript(
                """
                CREATE TABLE nat_gateways (uid TEXT, fulfillment_id TEXT, tenant_id TEXT,
                  external_ip_uid TEXT, virtual_network_uid TEXT, external_address TEXT,
                  phase TEXT, payload TEXT);
                """
            )
            connection.execute(
                "INSERT INTO nat_gateways VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    "nat-gateway-uid",
                    "nat-gateway-id",
                    "test-tenant",
                    "eip-uid",
                    "vn-uid",
                    "198.51.100.22",
                    "ready",
                    json.dumps({"source_cidrs": [{"subnet_uid": "subnet-uid", "cidr": "10.250.1.0/24"}]}),
                ),
            )
        if unknown_table:
            connection.execute("CREATE TABLE unexpected (value TEXT)")
        connection.execute("PRAGMA user_version=1")
        connection.commit()
        connection.close()

    def read_state(path: Path) -> dict[str, object]:
        result = subprocess.run(
            [sys.executable, "-", str(path)], input=snapshot_code, capture_output=True, text=True, check=True
        )
        return json.loads(result.stdout)

    current_schema = tmp_path / "current.sqlite3"
    create_state(current_schema, attachments=True, nat_gateways=True)
    snapshot = read_state(current_schema)
    assert snapshot["external_ip_attachments"] == [
        {
            "uid": "attachment-uid",
            "fulfillment_id": "attachment-id",
            "tenant_id": "test-tenant",
            "external_ip_uid": "eip-uid",
            "virtual_network_uid": "vn-uid",
            "subnet_uid": "subnet-uid",
            "external_address": "198.51.100.21",
            "phase": "ready",
            "payload": {"context": {"target": {"ip_address": "10.250.1.5"}}},
        }
    ]
    assert snapshot["nat_gateways"] == [
        {
            "uid": "nat-gateway-uid",
            "fulfillment_id": "nat-gateway-id",
            "tenant_id": "test-tenant",
            "external_ip_uid": "eip-uid",
            "virtual_network_uid": "vn-uid",
            "external_address": "198.51.100.22",
            "phase": "ready",
            "payload": {"source_cidrs": [{"subnet_uid": "subnet-uid", "cidr": "10.250.1.0/24"}]},
        }
    ]

    attachment_schema = tmp_path / "attachment-schema.sqlite3"
    create_state(attachment_schema, attachments=True)
    assert read_state(attachment_schema)["nat_gateways"] == []

    previous_schema = tmp_path / "previous.sqlite3"
    create_state(previous_schema, attachments=False)
    assert read_state(previous_schema)["external_ip_attachments"] == []
    assert read_state(previous_schema)["nat_gateways"] == []

    unknown_schema = tmp_path / "unknown-schema.sqlite3"
    create_state(unknown_schema, attachments=False, unknown_table=True)
    result = subprocess.run(
        [sys.executable, "-", str(unknown_schema)],
        input=snapshot_code,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode != 0


def test_suite_flags_select_the_same_scope_for_run_and_cleanup(tmp_path):
    start = SOURCE.index("SUITE_SELECTED=false")
    end = SOURCE.index('\ncase "$VLAN_E2E_SUITE" in', start)
    parser = SOURCE[start:end]

    def parse(args):
        quoted_args = " ".join(shlex.quote(arg) for arg in args)
        script = (
            "set -euo pipefail\n"
            "VLAN_E2E_SUITE=full\n"
            "CLEANUP_MODE=false\n"
            "usage() { :; }\n"
            "argument_error() { printf 'ERROR: %s\\n' \"$1\" >&2; exit 2; }\n"
            f"set -- {quoted_args}\n"
            f"{parser}\n"
            "printf 'cleanup=%s suite=%s\\n' \"$CLEANUP_MODE\" \"$VLAN_E2E_SUITE\"\n"
        )
        return run_bash(tmp_path, script)

    result = parse(["--subnet-dhcp"])
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "cleanup=false suite=subnet-dhcp"

    result = parse(["--cleanup", "--subnet-dhcp"])
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "cleanup=true suite=subnet-dhcp"

    result = parse(["--virtual-network"])
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "cleanup=false suite=virtual-network"

    result = parse(["--cleanup", "--virtual-network"])
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "cleanup=true suite=virtual-network"

    result = parse(["--external-ip"])
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "cleanup=false suite=external-ip"

    result = parse(["--cleanup", "--external-ip"])
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "cleanup=true suite=external-ip"

    result = parse(["--nat-gateway"])
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "cleanup=false suite=nat-gateway"

    result = parse(["--cleanup", "--nat-gateway"])
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "cleanup=true suite=nat-gateway"

    result = parse(["--cleanup", "--suite", "external-ip-pool"])
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "cleanup=true suite=external-ip-pool"

    result = parse(["--external-ip-pool"])
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "cleanup=false suite=external-ip-pool"

    result = parse(["--cleanup", "--external-ip-pool"])
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "cleanup=true suite=external-ip-pool"

    result = parse(["--subnet"])
    assert result.returncode == 2
    assert "unexpected argument: --subnet" in result.stderr


def test_cleanup_name_filter_scopes_to_runner_prefix_and_explicit_network_name(tmp_path):
    helper = function_block("cleanup_name_filter", "cleanup_array_json")
    script = (
        "set -euo pipefail\n"
        f"{helper}\n"
        "cleanup_name_filter agentless-smoke-vn- custom-vn\n"
    )
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == (
        '(this.metadata.name.startsWith("agentless-smoke-vn-") || '
        'this.metadata.name.startsWith("custom-vn"))'
    )


def test_cleanup_subnet_parent_id_accepts_fulfillment_and_kubernetes_field_names(tmp_path):
    helper = function_block("cleanup_subnet_parent_id", "cleanup_name_filter")
    fixtures = (
        {"spec": {"virtual_network": {"id": "fulfillment-vn"}}},
        {"spec": {"virtualNetwork": "legacy-vn"}},
    )
    calls = "\n".join(
        f"cleanup_subnet_parent_id {shlex.quote(json.dumps(fixture))}"
        for fixture in fixtures
    )
    result = run_bash(tmp_path, f"set -euo pipefail\n{helper}\n{calls}\n")

    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines() == ["fulfillment-vn", "legacy-vn"]


def test_cleanup_mode_is_standalone_and_skips_deployment_stages():
    setup_start = SOURCE.index(
        'if [[ "$CLEANUP_MODE" != true ]]; then\n# Step 1: deploy or reuse the SNO'
    )
    setup_end = SOURCE.index("\nfi\n\nnetnode() {", setup_start)
    deployment_block = SOURCE[setup_start:setup_end]
    cleanup_start = SOURCE.index(
        "# Standalone cleanup uses the current deployment and fabric only."
    )
    cleanup_end = SOURCE.index('step "STEP 5 OF 5: Running', cleanup_start)
    cleanup_block = SOURCE[cleanup_start:cleanup_end]

    for marker in (
        'step "STEP 1 OF 5:',
        'step "STEP 2 OF 5:',
        'step "STEP 3 OF 5:',
        'step "STEP 4 OF 5:',
    ):
        assert marker in deployment_block
    assert "prepare_suite_cleanup" in cleanup_block
    assert cleanup_block.index("prepare_suite_cleanup") < cleanup_block.index("exit 0")
    assert "containerlab deploy" not in cleanup_block
    assert "configure_containerlab_fabric" not in cleanup_block
    assert "helm get values osac" in cleanup_block
    assert "configure_aap_execution_environment" not in cleanup_block
    assert 'step "STEP 5 OF 5: Running' in SOURCE
    assert 'IMAGE_SOURCE_COMMIT="$RUNTIME_SOURCE_COMMIT"' in SOURCE


def test_cleanup_provider_verifier_resolves_dynamic_state_collections():
    verifier = function_block(
        "verify_suite_cleanup_provider_state", "cleanup_created_virtual_networks"
    )

    assert "baseline_uids=\"$(jq -r --arg collection \"$collection\"" in verifier
    assert "if (.[$collection] | type) != \"array\" then error" in verifier
    assert '".[$collection][].uid"' not in verifier


def test_cleanup_supervisor_verifier_treats_no_such_process_as_absent(tmp_path):
    helper = function_block(
        "supervisor_service_status_is_absent", "verify_suite_cleanup_provider_state"
    )
    script = (
        "set -euo pipefail\n"
        f"{helper}\n"
        "supervisor_service_status_is_absent agentless-dhcp-test "
        '"agentless-dhcp-test: ERROR (no such process)"\n'
        "if supervisor_service_status_is_absent agentless-dhcp-test "
        '"agentless-dhcp-test: STOPPED"; then exit 1; fi\n'
    )
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    assert "service_file=\"/etc/agentless-net/supervisor.d/${uid}.ini\"" in SOURCE


def test_standalone_subnet_cleanup_offboards_saved_test_bmis_before_removing_clients():
    helper = function_block("cleanup_interrupted_dhcp_clients", "prepare_suite_cleanup")
    cleanup = function_block("prepare_suite_cleanup", "verify_suite_cleanup_provider_state")
    on_exit_start = SOURCE.index("on_exit() {")
    on_exit_end = SOURCE.index("\n}\ntrap on_exit EXIT", on_exit_start) + 2
    on_exit = SOURCE[on_exit_start:on_exit_end]

    assert helper.index("CLEANUP_CLIENTS_COMPLETE=false") < helper.index("offboard_client_from_subnet")
    assert helper.index("offboard_client_from_subnet") < helper.index('docker rm -f "$container"')
    assert "osac.openshift.io/owner-reference\"] == \"vlan-e2e-run\"" in helper
    assert 'candidate_subnet" == "$subnet_ref"' in helper
    assert 'switch_exec "$CLIENT_SWITCH" bridge -j vlan show dev "$CLIENT_SWITCH_PORT"' in helper
    assert 'index("Egress Untagged") != null' in helper
    assert cleanup.index("CLEANUP_DISCOVERY_COMPLETE=true") < cleanup.index(
        "cleanup_interrupted_dhcp_clients"
    )
    assert '"${CLEANUP_CLIENTS_COMPLETE:-true}" != true' in on_exit
