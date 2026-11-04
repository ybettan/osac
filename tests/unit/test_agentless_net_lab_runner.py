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
BMAAS_RUNNER = REPO_ROOT / "vlan-e2e-bmaas.sh"
BMAAS_SOURCE = BMAAS_RUNNER.read_text()


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


def render_provider_inventory(
    tmp_path: Path, inventory_path: Path, bmaas_ports_path: Path | None = None
):
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
        AGENTLESS_NET_BMAAS_HOST_PORTS_FILE="" if bmaas_ports_path is None else str(bmaas_ports_path),
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


def test_external_ip_result_matches_the_typed_address_artifact(tmp_path: Path) -> None:
    helper = function_block("external_ip_assert_result", "external_ip_assert_state")
    valid = json.dumps({"osac_result": {"external_ip": {"address": "198.18.1.10"}}})
    invalid = json.dumps({"osac_result": {"external_ip": {"address": "198.18.1.11"}}})
    script = f"""
set -euo pipefail
{helper}
external_ip_assert_result {shlex.quote(valid)} 198.18.1.10
if external_ip_assert_result {shlex.quote(invalid)} 198.18.1.10; then exit 1; fi
if external_ip_assert_result '{{}}' 198.18.1.10; then exit 1; fi
"""

    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr


def test_external_ip_replay_checks_saved_api_id_and_typed_address(tmp_path: Path) -> None:
    helper = function_block("external_ip_assert_result", "external_ip_assert_state")
    task_input = json.dumps({"resource": {"id": "external-ip-api-id"}})
    result_file = tmp_path / "replay-result.json"
    result_file.write_text(
        json.dumps(
            {
                "artifacts": {
                    "osac_result": {"external_ip": {"address": "198.18.1.10"}}
                }
            }
        )
    )
    script = f"""
set -euo pipefail
TASK_INPUT={shlex.quote(task_input)}
RESULT_FILE={shlex.quote(str(result_file))}
{helper}
external_ip_assert_replay_result "$TASK_INPUT" "$RESULT_FILE" external-ip-api-id 198.18.1.10
if external_ip_assert_replay_result "$TASK_INPUT" "$RESULT_FILE" other-id 198.18.1.10; then exit 1; fi
if external_ip_assert_replay_result "$TASK_INPUT" "$RESULT_FILE" external-ip-api-id 198.18.1.11; then exit 1; fi
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
    assert 'run_agentless_net_aap_job apply_network_attachment' in SOURCE
    assert 'run_agentless_net_aap_job query_dhcp_lease' in SOURCE
    assert 'run_agentless_net_aap_job delete_network_attachment' in SOURCE
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


def test_provider_inventory_merges_inspected_bmaas_hosts(tmp_path: Path) -> None:
    bmaas_ports = tmp_path / "bmaas-host-ports.json"
    bmaas_ports.write_text(
        json.dumps(
            {
                "virtual-bmh-test-01": {
                    "data-0": {"switch": "clab-agentless-net-lab-leaf-1", "port": "swp5"}
                },
                "virtual-bmh-test-02": {
                    "data-0": {"switch": "clab-agentless-net-lab-leaf-2", "port": "swp5"}
                },
            }
        )
    )

    result, output_path, _ = render_provider_inventory(
        tmp_path, REPO_ROOT / "tests/e2e/agentless_net/lab/inventory.yml", bmaas_ports
    )

    assert result.returncode == 0, result.stderr
    rendered = yaml.safe_load(output_path.read_text())
    ports = rendered["all"]["vars"]["agentless_net_host_ports"]
    assert ports["virtual-bmh-test-01"]["data-0"] == {
        "switch": "clab-agentless-net-lab-leaf-1",
        "port": "swp5",
    }
    assert ports["virtual-bmh-test-02"]["data-0"]["switch"] == "clab-agentless-net-lab-leaf-2"
    assert rendered["all"]["vars"]["agentless_net_bmaas_switch_ports"] == {
        "clab-agentless-net-lab-leaf-1": ["swp5"],
        "clab-agentless-net-lab-leaf-2": ["swp5"],
    }


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


def test_generic_network_attachment_tasks_need_no_aap_kubernetes_credential() -> None:
    assert 'run_agentless_net_aap_job apply_network_attachment' in SOURCE
    assert 'run_agentless_net_aap_job query_dhcp_lease' in SOURCE
    assert 'run_agentless_net_aap_job delete_network_attachment' in SOURCE
    assert 'configure_aap_subnet_reader' not in SOURCE
    assert 'cleanup_aap_subnet_reader' not in SOURCE
    assert 'vlan-e2e-subnet-reader' not in SOURCE
    assert 'create serviceaccount' not in SOURCE
    assert 'network_attachment_macs' not in SOURCE
    assert '.status.taskInput' in SOURCE
    assert 'status.jobs' in SOURCE


def test_client_gateway_uses_the_saved_subnet_ipam_plan(tmp_path: Path) -> None:
    helper = function_block("assert_client_gateway", "assert_same_subnet_l2")
    capture = tmp_path / "gateway-ping.txt"
    subnet = {"ipam": {"gateway_ipv4": "10.250.0.1"}}
    script = f"""
set -euo pipefail
CAPTURE={shlex.quote(str(capture))}
client_container() {{ printf 'container-%s' "$1"; }}
docker() {{ printf '%s\\n' "$*" >"$CAPTURE"; }}
die() {{ printf 'ERROR: %s\\n' "$*" >&2; exit 1; }}
{helper}
assert_client_gateway a1 {shlex.quote(json.dumps(subnet))}
"""

    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    assert capture.read_text().strip() == "exec container-a1 ping -n -c 3 -W 2 10.250.0.1"


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
write_client_network_attachment_extra_vars() {{ :; }}
assert_network_attachment_state() {{ :; }}
run_agentless_net_aap_job() {{
    [[ "$1" == query_dhcp_lease ]]
    printf '%s\n' "$3" >>"$CAPTURE"
    printf '%s\n' '{{"artifacts":{{"osac_result":{{"dhcp_lease":{{"ip_address":"10.0.0.2","mac_address":"02:00:00:00:00:01"}}}}}}}}' >"$3"
}}
info() {{ :; }}
die() {{ printf 'ERROR: %s\n' "$*" >&2; exit 1; }}
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


def test_network_attachment_vars_use_stored_subnet_snapshots(tmp_path: Path) -> None:
    helper = function_block("write_client_network_attachment_extra_vars", "attach_client_to_subnet")
    variables = tmp_path / "client-vars"
    subnet_id = "11234567-89ab-cdef-0123-456789abcdef"
    target_id = "01234567-89ab-cdef-0123-456789abcdef"
    attachment_uid = "21234567-89ab-cdef-0123-456789abcdef"
    subnet_input = {
        "resource": {
            "apiVersion": "osac.openshift.io/v1alpha1",
            "kind": "Subnet",
            "id": subnet_id,
            "metadata": {"name": "subnet-test", "namespace": "osac-e2e-ci", "uid": "31234567-89ab-cdef-0123-456789abcdef", "generation": 1},
            "spec": {"ipv4Cidr": "10.0.0.0/28"},
        },
        "tenant": "osac-e2e-ci",
        "virtual_network": {
            "apiVersion": "osac.openshift.io/v1alpha1",
            "kind": "VirtualNetwork",
            "id": "41234567-89ab-cdef-0123-456789abcdef",
            "metadata": {"name": "vn-test", "namespace": "osac-e2e-ci", "uid": "51234567-89ab-cdef-0123-456789abcdef", "generation": 1},
            "spec": {"ipv4Cidr": "10.0.0.0/16"},
        },
        "ipam": {"gateway_ipv4": "10.0.0.1", "overlay_ipv4_cidrs": [], "physical_ipv4_cidrs": ["10.0.0.0/28"], "lb_vip_ipv4_cidrs": []},
    }
    subnet_cr = {"status": {"taskInput": subnet_input}}
    script = f"""
set -euo pipefail
TEMP_DIR={shlex.quote(str(tmp_path))}
OSAC_NAMESPACE=osac-e2e-ci
declare -A CLIENT_BMI_API_ID=([a1]={target_id})
declare -A CLIENT_ATTACHMENT_UID=([a1]={attachment_uid})
declare -A CLIENT_PRESERVED_MAC=([a1]=02:00:00:00:00:01)
SUBNET_CR_JSON={shlex.quote(json.dumps(subnet_cr))}
subnet_cr_json() {{ printf '%s' "$SUBNET_CR_JSON"; }}
{helper}
write_client_network_attachment_extra_vars a1 {subnet_id} apply_network_attachment {shlex.quote(str(variables / 'apply-network-attachment.json'))}
write_client_network_attachment_extra_vars a1 {subnet_id} query_dhcp_lease {shlex.quote(str(variables / 'query-dhcp-lease.json'))}
write_client_network_attachment_extra_vars a1 {subnet_id} delete_network_attachment {shlex.quote(str(variables / 'delete-network-attachment.json'))}
for path in {shlex.quote(str(variables / 'apply-network-attachment.json'))} {shlex.quote(str(variables / 'query-dhcp-lease.json'))} {shlex.quote(str(variables / 'delete-network-attachment.json'))}; do
  jq -e --arg task "$(basename "$path" .json | tr '-' '_')"     --arg target {target_id} --arg na_uid {attachment_uid} --arg subnet {subnet_id} '
      .osac_job_vars.task == $task
      and .osac_job_vars.manager == {{"name":"agentless_net","type":"fabric","ansible_role":"osac.templates.agentless_net"}}
      and .osac_job_vars.resource.kind == "NetworkAttachment"
      and .osac_job_vars.resource.id == $target
      and .osac_job_vars.resource.metadata.uid == $na_uid
      and .osac_job_vars.target.id == $target
      and .osac_job_vars.target.host_name == "osac-e2e-a1"
      and .osac_job_vars.network_attachment.subnet == $subnet
      and .osac_job_vars.network_attachment.interface == {{"type":"physical","name":"eth0","mac_address":"02:00:00:00:00:01"}}
      and .osac_job_vars.subnet.id == $subnet
      and .osac_job_vars.virtual_network.id == "41234567-89ab-cdef-0123-456789abcdef"
      and .osac_job_vars.ipam.physical_ipv4_cidrs == ["10.0.0.0/28"]
      and (.osac_job_vars | has("network_attachment_macs") | not)
    ' "$path" >/dev/null
done
"""
    variables.mkdir()
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    for name in ("apply-network-attachment.json", "query-dhcp-lease.json", "delete-network-attachment.json"):
        assert (variables / name).stat().st_mode & 0o777 == 0o600


def test_client_attachment_is_idempotent_and_offboard_reuses_api_id(tmp_path: Path) -> None:
    helpers = (
        function_block("attach_client_to_subnet", "discover_client_dhcp_lease")
        + "\n"
        + function_block("offboard_client_from_subnet", "write_agentless_e2e_helpers")
    )
    subnet_id = "11234567-89ab-cdef-0123-456789abcdef"
    (tmp_path / "client-a1.mac").write_text("02:00:00:00:00:01\n")
    script = f"""
set -euo pipefail
TEMP_DIR={shlex.quote(str(tmp_path))}
AAP_JOB_RESULT_SEQUENCE=0
OSAC_NAMESPACE=osac-e2e-ci
OSAC_TENANT=osac-e2e-ci
declare -A CLIENT_ATTACHMENT_ACTIVE=()
declare -A CLIENT_ATTACHMENT_PENDING=()
declare -A CLIENT_ATTACHMENT_SUBNET=()
declare -A CLIENT_BMI_API_ID=()
declare -A CLIENT_ATTACHMENT_UID=()
declare -A CLIENT_PRESERVED_MAC=()
JOB_CALLS=0
write_client_network_attachment_extra_vars() {{
  local client="$1" subnet="$2" task="$3" output="$4"
  jq -n --arg task "$task" --arg subnet "$subnet" --arg id "${{CLIENT_BMI_API_ID[$client]}}" \
    '{{osac_job_vars:{{task:$task,resource:{{id:$id}},network_attachment:{{subnet:$subnet}}}}}}' >"$output"
}}
assert_network_attachment_state_absent() {{ :; }}
run_agentless_net_aap_job() {{
  local task="$1" vars="$2" output="$3"
  jq -e --arg task "$task" '.osac_job_vars.task == $task' "$vars" >/dev/null
  JOB_CALLS=$((JOB_CALLS + 1))
  cp "$vars" "$TEMP_DIR/job-$JOB_CALLS.json"
  printf '%s\n' "$output" >>"$TEMP_DIR/result-paths.txt"
  printf '{{"job_id":%d,"status":"successful","artifacts":{{}}}}\n' "$JOB_CALLS" >"$output"
}}
info() {{ :; }}
die() {{ printf 'ERROR: %s\n' "$*" >&2; exit 1; }}
{helpers}
attach_client_to_subnet a1 {subnet_id}
first_id="${{CLIENT_BMI_API_ID[a1]}}"
attach_client_to_subnet a1 {subnet_id}
[[ "$JOB_CALLS" == 1 && "${{CLIENT_ATTACHMENT_ACTIVE[a1]}}" == true ]]
[[ "${{CLIENT_ATTACHMENT_PENDING[a1]}}" == false ]]
offboard_client_from_subnet a1
[[ "$JOB_CALLS" == 2 && "${{CLIENT_ATTACHMENT_ACTIVE[a1]}}" == false ]]
[[ -z "${{CLIENT_BMI_API_ID[a1]:-}}" && -z "${{CLIENT_ATTACHMENT_SUBNET[a1]:-}}" ]]
attach_client_to_subnet a1 {subnet_id}
[[ "$JOB_CALLS" == 3 && "${{CLIENT_ATTACHMENT_ACTIVE[a1]}}" == true ]]
[[ "${{CLIENT_BMI_API_ID[a1]}}" != "$first_id" ]]
[[ "$(sort -u "$TEMP_DIR/result-paths.txt" | wc -l)" == 3 ]]
jq -e '.osac_job_vars.task == "delete_network_attachment"' "$TEMP_DIR/job-2.json" >/dev/null
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
    git("checkout", "-b", "osac-6752-agentless-contract")
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
resolve_runtime_source {shlex.quote(str(repository))} osac-6752-agentless-contract
"""
    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines() == ["osac-6752-agentless-contract", implementation_commit]
    assert git("merge-base", "osac-6752-agentless-contract", "HEAD") == implementation_commit
    assert subprocess.run(
        ["git", "-C", str(repository), "diff", "--quiet", "osac-6752-agentless-contract", "HEAD", "--", "osac-aap"]
    ).returncode == 0

    git("checkout", "osac-6752-agentless-contract")
    production_file.write_text("implementation advanced\n")
    git("commit", "-am", "advance implementation")
    git("checkout", "e2e")
    assert subprocess.run(
        ["git", "-C", str(repository), "diff", "--quiet", "osac-6752-agentless-contract", "HEAD", "--", "osac-aap"]
    ).returncode == 1
    advanced = run_bash(tmp_path, script)
    assert advanced.returncode != 0


def test_runtime_source_check_allows_only_declared_lab_overlays(tmp_path: Path) -> None:
    repository = tmp_path / "repository"
    installer = repository / "osac-installer"
    overlay = installer / "values" / "agentless-net-stub.yaml"
    chart_source = installer / "charts" / "osac" / "templates" / "deployment.yaml"
    infra_role = installer / "charts" / "osac-infra" / "templates" / "keycloak" / "resources.yaml"
    infra_test = installer / "scripts" / "test-service-account-idp-render.py"
    overlay.parent.mkdir(parents=True)
    chart_source.parent.mkdir(parents=True)
    infra_role.parent.mkdir(parents=True)
    infra_test.parent.mkdir(parents=True)
    overlay.write_text("base overlay\n")
    chart_source.write_text("base chart\n")
    infra_role.write_text("base infra role\n")
    infra_test.write_text("base infra test\n")

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
    git("add", "osac-installer")
    git("commit", "-m", "base")
    git("checkout", "-b", "osac-6752-agentless-contract")
    chart_source.write_text("implementation chart\n")
    git("commit", "-am", "implementation")
    source_commit = git("rev-parse", "HEAD")
    git("checkout", "-b", "e2e")
    overlay.write_text("lab-specific overlay\n")
    infra_role.write_text("lab Keycloak role fix\n")
    infra_test.write_text("lab infra assertion\n")

    helper_start = SOURCE.index("assert_runtime_source_clean() {")
    helper_end = SOURCE.index("\n}\n", helper_start) + 3
    helper = SOURCE[helper_start:helper_end]
    command = (
        f"set -euo pipefail\n{helper}\n"
        f"assert_runtime_source_clean {shlex.quote(str(repository))} "
        f"{shlex.quote(source_commit)} osac-installer\n"
    )
    disallowed_without_infra_reuse = run_bash(tmp_path, command)
    assert disallowed_without_infra_reuse.returncode != 0
    assert "uncommitted changes" in disallowed_without_infra_reuse.stderr

    allowed_reuse_overlays = run_bash(tmp_path, f"VLAN_E2E_REUSE_INFRA=true\n{command}")
    assert allowed_reuse_overlays.returncode == 0, allowed_reuse_overlays.stderr

    chart_source.write_text("uncommitted chart change\n")
    changed_chart = run_bash(tmp_path, f"VLAN_E2E_REUSE_INFRA=true\n{command}")
    assert changed_chart.returncode != 0
    assert "uncommitted changes" in changed_chart.stderr


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
        "osac-6752-agentless-contract\n",
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
    assert 'IMPLEMENTATION_BRANCH_NAME="${VLAN_E2E_RUNTIME_BRANCH:-e2e}"' in SOURCE
    assert 'OSAC_PROFILE="${OSAC_PROFILE:-bmaas-ci}"' in SOURCE


def test_bmaas_activates_ironic_before_osac_install_preflight() -> None:
    api_ready = SOURCE.index('oc wait nodes --all --for=condition=Ready')
    bmaas_activation = SOURCE.index("    bmaas_activate_ironic\n", api_ready)
    osac_install = SOURCE.index('step "STEP 2 OF 5:', bmaas_activation)
    activation_helper = BMAAS_SOURCE[
        BMAAS_SOURCE.index("    bmaas_activate_ironic() {"):BMAAS_SOURCE.index(
            "    bmaas_host_state_file() {"
        )
    ]

    assert api_ready < bmaas_activation < osac_install
    assert "kind: Provisioning" in activation_helper
    assert 'provisioningNetwork: "Disabled"' in activation_helper
    assert "disableVirtualMediaTLS: true" in activation_helper
    assert "watchAllNamespaces: true" in activation_helper
    assert "for ((attempt = 1; attempt <= 60; attempt++))" in activation_helper
    assert 'oc wait --for=condition=Ready pods' in activation_helper
    assert "baremetal-operator-webhook-service" in activation_helper


def test_bmaas_upgrade_syncs_aap_before_template_publication() -> None:
    setup_start = SOURCE.index(
        'if [[ "$BMAAS_MODE" == true && -n "$EXISTING_OSAC_RELEASE"'
    )
    setup_end = SOURCE.index('if [[ "$OSAC_DEPLOYMENT_NEEDED" == false ]]', setup_start)
    aap_sync = SOURCE[setup_start:setup_end]
    upgrade = SOURCE.index('helm upgrade osac "${INSTALLER_DIR}/charts/osac"', setup_end)

    assert '"$OSAC_DEPLOYMENT_NEEDED" == true' in aap_sync
    assert aap_sync.index("prepare_aap_ca_bundle") < aap_sync.index("sync_aap_project_revision")
    assert aap_sync.index("sync_aap_project_revision") < aap_sync.index("configure_aap_execution_environment")
    assert aap_sync.index("configure_aap_execution_environment") < upgrade


def test_agentless_overlay_is_bmaas_only_with_physical_ipam_and_fresh_state() -> None:
    overlay = yaml.safe_load((REPO_ROOT / "osac-installer/values/agentless-net-stub.yaml").read_text())
    profile = yaml.safe_load((REPO_ROOT / "osac-installer/values/bmaas-ci/instance.yaml").read_text())

    networking = overlay["global"]["networking"]
    assert networking["provisioningEnabled"] is True
    assert networking["fabricManager"] == "agentless_net"
    assert networking["k8sManager"] == ""
    assert networking["networkClass"]["addressPlan"] == {"overlay": 0, "fabric": 1, "lbVip": 0}
    assert overlay["aap"]["instanceGroups"]["networkFulfillment"]["config"] == {
        "AGENTLESS_NET_STATE_FILE": "/etc/osac/agentless_network_state_osac_6752.sqlite3",
        "AGENTLESS_NET_EXTERNAL_INTERFACE": "eth2",
    }
    assert overlay["operator"]["tenants"] == [{"name": "shared"}]
    assert overlay["global"]["services"]["bmaas"]["enabled"] is True
    assert overlay["bmf"]["replicaCount"] == 1
    assert overlay["bmf"]["metal3"]["enabled"] is True
    assert overlay["bmf"]["metal3"]["namespace"] == "host-inventory"
    assert profile["global"]["services"] == {
        "caas": {"enabled": False},
        "vmaas": {"enabled": False},
        "bmaas": {"enabled": True},
        "maas": {"enabled": False},
    }


def test_bootstrap_pool_precedes_default_networking_and_keeps_existing_rows() -> None:
    setup_start = SOURCE.index('step "STEP 4 OF 5: Initializing provider and fabric"')
    setup_end = SOURCE.index('step "STEP 5 OF 5: Running', setup_start)
    setup = SOURCE[setup_start:setup_end]

    assert setup.index("ensure_bootstrap_external_ip_pool") < setup.index("ensure_osac_tenant")
    assert setup.index("ensure_osac_tenant") < setup.index("wait_for_tenant_default_networking")
    assert "BOOTSTRAP_EXTERNAL_IP_POOL_NAME" in SOURCE
    assert 'metadata.tenant == "shared"' in function_block("ensure_bootstrap_external_ip_pool", "external_ip_pool_rpc_error_is_not_found")
    assert "assert_baseline_state_unchanged" in SOURCE
    assert "assert_legacy_provider_state_unchanged" in SOURCE


def test_tenant_default_networking_wait_reads_private_tenant_status(tmp_path: Path) -> None:
    private_get = function_block("tenant_private_get", "wait_for_tenant_default_networking")
    waiter = function_block("wait_for_tenant_default_networking", "external_ip_pool_list_items")
    tenant = {
        "object": {
            "id": "osac-e2e-ci",
            "status": {
                "state": "TENANT_STATE_SYNCED",
                "conditions": [
                    {
                        "type": "TENANT_CONDITION_TYPE_DEFAULT_NETWORKING_READY",
                        "status": "CONDITION_STATUS_TRUE",
                        "reason": "AllResourcesReady",
                        "message": "All default networking resources are ready",
                    }
                ],
            },
        }
    }
    script = f"""
set -euo pipefail
OSAC_TENANT=osac-e2e-ci
tenant_private_get() {{ printf '%s\\n' "$TENANT_RESPONSE"; }}
info() {{ :; }}
die() {{ printf '%s\\n' "$1" >&2; exit 1; }}
{waiter}
wait_for_tenant_default_networking
"""
    result = run_bash(tmp_path, script, {"TENANT_RESPONSE": json.dumps(tenant)})

    assert result.returncode == 0, result.stderr
    assert "osac.private.v1.Tenants/Get" in private_get
    assert "--output json" not in waiter
    assert '.object.status.conditions[]?' in waiter


def test_networking_status_uses_conditions_and_task_jobs_without_resetting_history() -> None:
    assert ".status.phase" not in SOURCE
    assert ".status.provisioningJobs" not in SOURCE
    assert "--subresource=status" not in SOURCE
    assert 'select(.task == $task and .manager == $manager)' in SOURCE
    assert '.status.conditions[]? | select(.type == "Ready")' in SOURCE


def test_deployment_comparison_uses_only_supported_networkclass_values() -> None:
    settings = function_block("deployment_settings", "prepare_upgrade_values")
    expected_start = SOURCE.index("EXPECTED_DEPLOYMENT_SETTINGS=")
    expected_end = SOURCE.index("OSAC_DEPLOYMENT_NEEDED=", expected_start)
    expected = SOURCE[expected_start:expected_end]

    assert ".global.networking.networkClass.title" not in settings
    assert "networkClassTitle" not in expected
    assert "networkClass.addressPlan" in settings
    assert "addressPlan:{overlay:0,fabric:1,lbVip:0}" in expected


def test_deployment_uses_the_source_pinned_aap_image_for_bootstrap_and_jobs() -> None:
    settings = function_block("deployment_settings", "prepare_upgrade_values")
    expected_start = SOURCE.index("EXPECTED_DEPLOYMENT_SETTINGS=")
    expected_end = SOURCE.index("OSAC_DEPLOYMENT_NEEDED=", expected_start)
    expected = SOURCE[expected_start:expected_end]

    assert "bootstrapImage: .aap.bootstrap.image" in settings
    assert "--set-string aap.bootstrap.image=${AAP_IMAGE}" in SOURCE
    assert '--set-string "aap.bootstrap.image=${AAP_IMAGE}"' in SOURCE
    assert "bootstrapImage:$ee" in expected


def test_runner_can_adopt_osac_crds_for_a_fresh_namespace_reinstall() -> None:
    assert 'VLAN_E2E_TAKE_OWNERSHIP="${VLAN_E2E_TAKE_OWNERSHIP:-false}"' in SOURCE
    assert 'EXTRA_HELM_ARGS+=" --take-ownership"' in SOURCE
    assert 'INFRA_HELM_ARGS="--take-ownership"' in SOURCE
    assert '"INFRA_HELM_ARGS=${INFRA_HELM_ARGS}"' in SOURCE
    assert "VLAN_E2E_TAKE_OWNERSHIP must be true or false" in SOURCE


def test_runner_can_reinstall_osac_without_upgrading_healthy_infra() -> None:
    assert 'VLAN_E2E_REUSE_INFRA="${VLAN_E2E_REUSE_INFRA:-false}"' in SOURCE
    assert '[[ "$VLAN_E2E_REUSE_INFRA" == true ]]' in SOURCE
    assert "INSTALL_TARGET=install-osac" in SOURCE
    assert 'make -C "$INSTALLER_DIR" "$INSTALL_TARGET"' in SOURCE


@pytest.mark.parametrize(
    ("legacy_dns_class", "expected_dns_class"), [("", "dns.noop.dns"), ("dns.route53.dns", "dns.route53.dns")]
)
def test_upgrade_values_normalize_empty_legacy_dns_class(
    tmp_path: Path, legacy_dns_class: str, expected_dns_class: str
) -> None:
    helper = function_block("prepare_upgrade_values", "tenant_exists")
    installer = tmp_path / "installer"
    profile = installer / "values" / "bmaas-ci" / "instance.yaml"
    profile.parent.mkdir(parents=True)
    profile.write_text("clusterVersions:\n  versions: []\n")
    previous_values = tmp_path / "previous-values.json"
    previous_values.write_text(
        json.dumps({"aap": {"instanceGroups": {"clusterFulfillment": {"config": {"DNS_CLASS": legacy_dns_class}}}}})
    )
    script = f"""
set -euo pipefail
TEMP_DIR={shlex.quote(str(tmp_path))}
INSTALLER_DIR={shlex.quote(str(installer))}
OSAC_NAMESPACE=osac-e2e-ci
OSAC_PROFILE=bmaas-ci
helm() {{ cat {shlex.quote(str(previous_values))}; }}
die() {{ printf '%s\\n' "$*" >&2; exit 1; }}
{helper}
prepare_upgrade_values
"""

    result = run_bash(tmp_path, script)
    assert result.returncode == 0, result.stderr
    upgraded = yaml.safe_load((tmp_path / "previous-helm-values.yaml").read_text())
    assert upgraded["aap"]["instanceGroups"]["clusterFulfillment"]["config"]["DNS_CLASS"] == expected_dns_class


def test_upgrade_values_translate_legacy_networking_for_the_bmaas_lab(tmp_path: Path) -> None:
    helper = function_block("prepare_upgrade_values", "tenant_exists")
    installer = tmp_path / "installer"
    profile = installer / "values" / "bmaas-ci" / "instance.yaml"
    profile.parent.mkdir(parents=True)
    profile.write_text(
        "global:\n"
        "  services:\n"
        "    caas: {enabled: false}\n"
        "    vmaas: {enabled: false}\n"
        "    bmaas: {enabled: true}\n"
        "    maas: {enabled: false}\n"
        "clusterVersions:\n  versions: []\n"
    )
    previous_values = tmp_path / "previous-values.json"
    previous_values.write_text(
        json.dumps(
            {
                "global": {
                    "expertOverrides": {"networkClass": True},
                    "services": {"caas": {"enabled": True}, "bmaas": {"enabled": True}},
                    "networking": {
                        "fabricManager": "agentless_net",
                        "k8sManager": "",
                        "netris": {"controllerUrl": "https://old.example.invalid"},
                        "networkClass": {"title": "old title", "description": "old description"},
                    },
                },
                "networkClass": {
                    "enabled": False,
                    "isDefault": True,
                    "defaults": {
                        "virtualNetworkIPv4Cidr": "10.200.0.0/16",
                        "subnetIPv4Cidr": "10.200.0.0/20",
                        "egressRules": [{"protocol": "PROTOCOL_ALL", "ipv4Cidr": "0.0.0.0/0"}],
                        "enableNatGateway": False,
                    },
                },
                "operator": {"controllers": {"networking": True, "networkingProvisioning": True}},
            }
        )
    )
    script = f"""
set -euo pipefail
TEMP_DIR={shlex.quote(str(tmp_path))}
INSTALLER_DIR={shlex.quote(str(installer))}
OSAC_NAMESPACE=osac-e2e-ci
OSAC_PROFILE=bmaas-ci
helm() {{ cat {shlex.quote(str(previous_values))}; }}
die() {{ printf '%s\\n' "$*" >&2; exit 1; }}
{helper}
prepare_upgrade_values
"""

    result = run_bash(tmp_path, script)
    assert result.returncode == 0, result.stderr
    upgraded = yaml.safe_load((tmp_path / "previous-helm-values.yaml").read_text())
    assert "expertOverrides" not in upgraded["global"]
    assert "netris" not in upgraded["global"]["networking"]
    network_class = upgraded["global"]["networking"]["networkClass"]
    assert "title" not in network_class and "description" not in network_class
    assert network_class["defaults"]["virtualNetworkIPv4Cidr"] == "10.200.0.0/16"
    assert network_class["defaults"]["subnetIPv4Cidr"] == "10.200.0.0/20"
    assert "enableNatGateway" not in network_class["defaults"]
    assert "networkClass" not in upgraded
    assert upgraded["global"]["services"] == {
        "caas": {"enabled": False},
        "vmaas": {"enabled": False},
        "bmaas": {"enabled": True},
        "maas": {"enabled": False},
    }
    assert "networkingProvisioning" not in upgraded["operator"]["controllers"]


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
        cleanup.index("cleanup_created_bare_metal_instances"),
        cleanup.index("cleanup_created_subnets"),
        cleanup.index('delete virtualnetwork "$id"'),
        cleanup.index("cleanup_created_external_ip_pool"),
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
        cleanup.index("cleanup_created_subnets"),
        cleanup.index('delete virtualnetwork "$id"'),
        cleanup.index("cleanup_created_external_ip_pool"),
        cleanup.index("restore_nat_gateway_uplink"),
        cleanup.index("restore_provider_inventory_config"),
    ]
    assert positions == sorted(positions)

    start = SOURCE.index("on_exit() {")
    end = SOURCE.index("\ntrap on_exit EXIT", start)
    on_exit = SOURCE[start:end]
    assert on_exit.index("cleanup_created_nat_gateways") < on_exit.index("cleanup_dhcp_clients_and_attachments")


def test_nat_gateway_subnet_readiness_is_independent_of_gateway_state() -> None:
    create = function_block("create_nat_gateway_subnet", "ensure_nat_gateway_dhcp_client")

    assert create.index("wait_for_subnet_cr_created") < create.index("wait_for_subnet_ready")
    assert "nat_gateway_wait_for_provider_sources" not in create
    assert "nat_gateway_assert_provider_rules" not in create


def test_nat_gateway_subnet_deletion_is_independent_of_gateway_state() -> None:
    delete = function_block("delete_subnet_by_id", "create_external_ip_pool")

    assert 'delete subnet "$id"' in delete
    assert delete.index('delete subnet "$id"') < delete.index("wait_for_subnet_deleted")
    assert "nat_gateway_wait_for_provider_sources" not in delete
    assert "nat_gateway_vlan_present_on_switches" not in delete


def test_nat_gateway_cleanup_discovery_scopes_crs_and_provider_identity() -> None:
    cleanup = function_block("prepare_suite_cleanup", "supervisor_service_status_is_absent")

    assert "nat_gateway_filter='this.metadata.name.startsWith(\"agentless-natgw-\")'" in cleanup
    assert 'nat_gateway_cr_json "$nat_gateway_id"' in cleanup
    nat_gateway_discovery = cleanup[cleanup.index("nat_gateway_items='[]'") : cleanup.index("pool_items='[]'")]
    assert 'external_ip_cr_json "$nat_gateway_eip_id" ""' in nat_gateway_discovery
    assert 'EXTERNAL_IP_POOL_ID="$pool_id"' in nat_gateway_discovery
    assert 'external_ip_pool_validate_cr_identity "$pool_cr" "$pool_id"' in nat_gateway_discovery
    assert 'external_ip_cr_json "$nat_gateway_eip_id" "$pool_id"' in nat_gateway_discovery
    assert '"osac.openshift.io/natgateway-contract-version"]' not in SOURCE
    assert ".[0].virtual_network_uid == $vn_uid" in cleanup
    assert ".[0].external_ip_uid == $eip_uid" in cleanup
    assert "test NATGateway provider row without a matching test CR" in cleanup


def test_nat_gateway_cleanup_uses_fulfillment_and_checks_provider_state() -> None:
    cleanup = function_block("delete_nat_gateway_and_verify", "cleanup_created_nat_gateways")

    assert 'network_task_entry "$gateway_cr" delete_nat_gateway' in cleanup
    assert 'if [[ "$job_state" == Failed || "$job_state" == Cancelled ]]' in cleanup
    assert '.status.taskInput' in cleanup
    assert 'delete natgateway "$id"' in cleanup
    assert 'nat_gateway_assert_provider_absent' in cleanup
    assert 'oc patch natgateway' not in cleanup
    assert 'hold_finalizer' not in cleanup
    assert 'nat_gateway_aap_job_details' not in cleanup


def test_external_ip_deletion_uses_fulfillment_without_direct_cr_patches() -> None:
    delete = function_block("delete_external_ip_and_verify", "run_external_ip_lifecycle")
    cleanup = function_block("cleanup_created_external_ips", "cleanup_created_external_ip_attachments")

    assert 'delete externalip "$id"' in delete
    assert 'external_ip_assert_state_absent "$uid" "$id"' in delete
    assert 'delete externalip "$id"' in cleanup
    assert 'oc patch externalip' not in delete
    assert 'oc patch externalip' not in cleanup
    assert 'hold_finalizer' not in delete
    assert 'hold_finalizer' not in cleanup


def test_nat_gateway_task_input_assertion_uses_dependency_snapshots(tmp_path: Path) -> None:
    helper = function_block("nat_gateway_assert_task_input", "nat_gateway_wait_for_ready")
    gateway_cr = {
        "metadata": {"generation": 3},
        "status": {
            "taskInput": {
                "resource": {
                    "kind": "NATGateway",
                    "id": "natgateway-id",
                    "metadata": {"generation": 3},
                    "spec": {},
                },
                "virtual_network": {
                    "id": "virtualnetwork-id",
                    "spec": {"ipv4Cidr": "10.250.0.0/16"},
                },
                "external_ip": {
                    "id": "externalip-id",
                    "address": "198.18.1.10",
                },
                "nat_gateway_context": {
                    "external_ip": {
                        "fulfillment_id": "externalip-id",
                        "address": "198.18.1.10",
                    },
                    "virtual_network": {
                        "fulfillment_id": "virtualnetwork-id",
                        "ipv4_cidr": "10.250.0.0/16",
                    },
                },
            }
        },
    }
    external_ip_cr = {"status": {"address": "198.18.1.10"}}
    virtual_network_cr = {"spec": {"ipv4Cidr": "10.250.0.0/16"}}
    malformed_gateway_cr = json.loads(json.dumps(gateway_cr))
    malformed_gateway_cr["status"]["taskInput"]["resource"]["spec"] = {
        "externalIP": "externalip-id"
    }
    valid_script = f"""
set -euo pipefail
die() {{ printf 'ERROR: %s\\n' "$*" >&2; exit 1; }}
{helper}
nat_gateway_assert_task_input {shlex.quote(json.dumps(gateway_cr))} \\
    {shlex.quote(json.dumps(external_ip_cr))} \\
    {shlex.quote(json.dumps(virtual_network_cr))} natgateway-id externalip-id virtualnetwork-id
"""
    malformed_script = f"""
set -euo pipefail
die() {{ printf 'ERROR: %s\\n' "$*" >&2; exit 1; }}
{helper}
nat_gateway_assert_task_input {shlex.quote(json.dumps(malformed_gateway_cr))} \\
    {shlex.quote(json.dumps(external_ip_cr))} \\
    {shlex.quote(json.dumps(virtual_network_cr))} natgateway-id externalip-id virtualnetwork-id
"""

    result = run_bash(tmp_path, valid_script)

    assert result.returncode == 0, result.stderr

    malformed_result = run_bash(tmp_path, malformed_script)

    assert malformed_result.returncode != 0
    assert "stored task input does not match" in malformed_result.stderr


def test_nat_gateway_endpoint_cleanup_matches_docker_resolved_router_id(tmp_path: Path) -> None:
    cleanup = function_block("cleanup_nat_gateway_endpoint", "assert_external_ip_attachment_provider_absent")
    events = tmp_path / "endpoint-cleanup.log"
    script = f"""
set -euo pipefail
CLEANUP_MODE=true
NAT_GATEWAY_ENDPOINT_CREATED_BY_RUN=false
NAT_GATEWAY_ENDPOINT_CONTAINER=osac-natgw-source-endpoint
NAT_GATEWAY_RESPONSE_TOKEN=test-token
CONTAINERLAB_UPSTREAM_ROUTER=clab-agentless-net-lab-upstream-router
EVENTS={shlex.quote(str(events))}
docker() {{
    if [[ "$1" == inspect && "$2" == -f ]]; then
        case "$4" in
            "$NAT_GATEWAY_ENDPOINT_CONTAINER")
                if [[ "$3" == *e2e-owner* ]]; then
                    printf 'agentless-natgateway'
                elif [[ "$3" == *NetworkMode* ]]; then
                    printf 'container:router-container-id'
                else
                    return 1
                fi
                ;;
            "$CONTAINERLAB_UPSTREAM_ROUTER") printf 'router-container-id' ;;
            *) return 1 ;;
        esac
    elif [[ "$1" == inspect && "$2" == "$NAT_GATEWAY_ENDPOINT_CONTAINER" ]]; then
        return 0
    elif [[ "$1" == rm && "$2" == -f ]]; then
        printf '%s\\n' "$*" >"$EVENTS"
    else
        return 1
    fi
}}
{cleanup}
cleanup_nat_gateway_endpoint
[[ "$NAT_GATEWAY_ENDPOINT_CREATED_BY_RUN" == false ]]
[[ -z "$NAT_GATEWAY_ENDPOINT_CONTAINER" ]]
[[ -z "$NAT_GATEWAY_RESPONSE_TOKEN" ]]
"""

    result = run_bash(tmp_path, script)

    assert result.returncode == 0, result.stderr
    assert events.read_text().strip() == "rm -f osac-natgw-source-endpoint"


def test_external_ip_cr_lookup_can_resolve_pool_during_recovery(tmp_path: Path) -> None:
    helper = function_block("external_ip_cr_json", "external_ip_attachment_crs_json")
    external_ip_id = "22222222-2222-4222-8222-222222222222"
    pool_id = "33333333-3333-4333-8333-333333333333"
    external_ip = {
        "items": [
            {
                "metadata": {
                    "name": "externalip-abcd1",
                    "namespace": "osac-e2e-ci",
                    "labels": {"osac.openshift.io/externalip-uuid": external_ip_id},
                    "annotations": {
                        "osac.openshift.io/tenant": "osac-e2e-ci",
                    },
                },
                "spec": {"pool": pool_id},
                "status": {"networkManagers": {"fabric": {"name": "agentless_net"}}},
            }
        ]
    }
    script = f"""
set -euo pipefail
OSAC_TENANT=osac-e2e-ci
NETWORKING_NAMESPACE=osac-e2e-ci
EXTERNAL_IP_POOL_ID=
external_ip_crs_json() {{ printf '%s\\n' "$EXTERNAL_IP_CR_JSON"; }}
die() {{ printf '%s\\n' "$*" >&2; exit 1; }}
{helper}
external_ip_cr_json {external_ip_id} ""
"""

    result = run_bash(tmp_path, script, {"EXTERNAL_IP_CR_JSON": json.dumps(external_ip)})

    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["spec"]["pool"] == pool_id


def test_nat_gateway_cr_lookup_accepts_controller_generated_cr_name(tmp_path: Path) -> None:
    nat_gateway_id = "11111111-1111-4111-8111-111111111111"
    resource = {
        "items": [
            {
                "metadata": {
                    "name": "natgateway-hgwmf",
                    "namespace": "osac-e2e-ci",
                    "labels": {"osac.openshift.io/natgateway-uuid": nat_gateway_id},
                    "annotations": {
                        "osac.openshift.io/tenant": "osac-e2e-ci",
                    },
                },
                "spec": {"virtualNetwork": "vn-id", "externalIP": "eip-id"},
                "status": {"networkManagers": {"fabric": {"name": "agentless_net"}}},
            }
        ]
    }
    helper = function_block("nat_gateway_cr_json", "baremetal_instance_crs_json")
    script = f"""
set -euo pipefail
OSAC_TENANT=osac-e2e-ci
NETWORKING_NAMESPACE=osac-e2e-ci
nat_gateway_crs_json() {{ printf '%s\\n' "$CR_JSON"; }}
die() {{ printf '%s\\n' "$*" >&2; exit 1; }}
{helper}
nat_gateway_cr_json {nat_gateway_id} vn-id eip-id
"""

    result = run_bash(tmp_path, script, {"CR_JSON": json.dumps(resource)})

    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["metadata"]["name"] == "natgateway-hgwmf"


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
def test_nat_gateway_cleanup_recovers_override_after_upgrade_restores_original(
    tmp_path: Path, original_value: str | None
) -> None:
    configure = function_block("configure_nat_gateway_uplink", "restore_nat_gateway_uplink")
    restore = function_block("restore_nat_gateway_uplink", "remove_netnode_public_key")
    temp_dir = tmp_path / "uplink-recovery"
    temp_dir.mkdir()
    owner_key = "osac.openshift.io/vlan-e2e-natgw-uplink-owner"
    backup_key = "osac.openshift.io/vlan-e2e-natgw-uplink-original"
    owner = "vlan-e2e-natgw-old-run"
    backup = {
        "owner": owner,
        "original_present": original_value is not None,
        "original_value": original_value or "",
        "original_annotations_present": False,
    }
    data = {"OTHER_SETTING": "preserve"}
    if original_value is not None:
        data["AGENTLESS_NET_EXTERNAL_INTERFACE"] = original_value
    initial = json.dumps(
        {
            "metadata": {"resourceVersion": "10", "annotations": {owner_key: owner, backup_key: json.dumps(backup)}},
            "data": data,
        }
    )
    script = f"""
set -euo pipefail
SUITE_USES_NAT_GATEWAY=true
CLEANUP_MODE=true
DHCP_CLIENT_PREFIX=old-run
NAT_GATEWAY_UPLINK_OWNER_ANNOTATION={shlex.quote(owner_key)}
NAT_GATEWAY_UPLINK_BACKUP_ANNOTATION={shlex.quote(backup_key)}
NAT_GATEWAY_UPLINK_CHANGED_BY_RUN=false
NAT_GATEWAY_UPLINK_BACKUP=
NAT_GATEWAY_UPLINK_OWNER=
NAT_GATEWAY_UPLINK_EXPECTED=
AAP_NETWORKING_SECRET=network-fulfillment-ig
OSAC_NAMESPACE=osac-e2e-ci
TEMP_DIR={shlex.quote(str(temp_dir))}
PATCH_COUNT=0
RECOVERY_PATCH_FILE=
RESTORE_PATCH_FILE=
die() {{ printf '%s\\n' "$*" >&2; exit 1; }}
info() {{ :; }}
oc() {{
    if [[ "$1" == get ]]; then
        case "$PATCH_COUNT" in
            0) jq -c . <<<"$INITIAL_CONFIG_MAP" ;;
            1) jq -cn --argjson initial "$INITIAL_CONFIG_MAP" '
                  $initial
                  | .metadata.resourceVersion = "12"
                  | .data.AGENTLESS_NET_EXTERNAL_INTERFACE = "eth2"' ;;
            2) jq -cn --argjson initial "$INITIAL_CONFIG_MAP" '
                  $initial
                  | .metadata.resourceVersion = "13"
                  | del(.metadata.annotations)' ;;
        esac
    elif [[ "$1" == patch ]]; then
        PATCH_COUNT=$((PATCH_COUNT + 1))
        for argument in "$@"; do
            case "$argument" in
                --patch-file=*)
                    if [[ "$PATCH_COUNT" == 1 ]]; then
                        RECOVERY_PATCH_FILE="${{argument#*=}}"
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
[[ "$NAT_GATEWAY_UPLINK_CHANGED_BY_RUN" == true ]]
restore_nat_gateway_uplink
[[ "$NAT_GATEWAY_UPLINK_CHANGED_BY_RUN" == false ]]
[[ "$PATCH_COUNT" == 2 ]]
jq -e --arg rv 10 'any(.[]; .op == "test" and .path == "/metadata/resourceVersion" and .value == $rv)' \\
    "$RECOVERY_PATCH_FILE" >/dev/null
jq -e --arg owner_key "/metadata/annotations/osac.openshift.io~1vlan-e2e-natgw-uplink-owner" \\
    --arg owner {shlex.quote(owner)} \\
    'any(.[]; .op == "test" and .path == $owner_key and .value == $owner)' \\
    "$RECOVERY_PATCH_FILE" >/dev/null
jq -e --arg backup_key "/metadata/annotations/osac.openshift.io~1vlan-e2e-natgw-uplink-original" \\
    --arg backup {shlex.quote(json.dumps(backup))} \\
    'any(.[]; .op == "test" and .path == $backup_key and .value == $backup)' \\
    "$RECOVERY_PATCH_FILE" >/dev/null
jq -e 'any(.[]; .op == "add" and .path == "/data/AGENTLESS_NET_EXTERNAL_INTERFACE" and .value == "eth2")' \\
    "$RECOVERY_PATCH_FILE" >/dev/null
jq -e --arg rv 12 'any(.[]; .op == "test" and .path == "/metadata/resourceVersion" and .value == $rv)' \\
    "$RESTORE_PATCH_FILE" >/dev/null
"""
    result = run_bash(tmp_path, script, {"INITIAL_CONFIG_MAP": initial})

    assert result.returncode == 0, result.stderr
    recovery_patch = json.loads((temp_dir / "nat-gateway-uplink-recovery-patch.json").read_text())
    if original_value is not None:
        assert any(
            operation.get("op") == "test"
            and operation.get("path") == "/data/AGENTLESS_NET_EXTERNAL_INTERFACE"
            and operation.get("value") == original_value
            for operation in recovery_patch
        )
    restore_patch = json.loads((temp_dir / "nat-gateway-uplink-restore.json").read_text())
    assert (
        any(
            operation.get("op") == "remove" and operation.get("path") == "/data/AGENTLESS_NET_EXTERNAL_INTERFACE"
            for operation in restore_patch
        )
        if original_value is None
        else any(
            operation.get("op") == "replace"
            and operation.get("path") == "/data/AGENTLESS_NET_EXTERNAL_INTERFACE"
            and operation.get("value") == original_value
            for operation in restore_patch
        )
    )


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
    assert '"external_ip_attachments": attachments' in SOURCE
    assert "external_ip_attachments external_ip_attachments" not in SOURCE
    assert "network_attachment_ports" in SOURCE
    assert "deleted_resources" in SOURCE
    assert '"state_contract": metadata[0][1]' in SOURCE
    assert 'peer_state="$(external_ip_attachment_state_entry' in SOURCE
    assert "changed its peer attachment state" in SOURCE


def test_external_ip_attachment_uses_a_synthetic_dhcp_client_target() -> None:
    setup = function_block(
        "create_external_ip_attachment_test_network_and_client", "cleanup_created_bare_metal_instances"
    )

    assert 'client="$EXTERNAL_IP_SYNTHETIC_CLIENT"' in setup
    assert 'attach_client_to_subnet "$client" "$EXTERNAL_IP_ATTACHMENT_SUBNET_ID"' in setup
    assert 'discover_client_dhcp_lease "$client"' in setup
    assert 'EXTERNAL_IP_SYNTHETIC_TARGET_UID="$EXTERNAL_IP_SYNTHETIC_TARGET_ID"' in setup
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


def test_state_snapshot_enforces_api_id_schema_and_reports_new_tables(tmp_path: Path) -> None:
    helper = function_block("state_snapshot", "save_current_state")
    body_start = helper.index("<<'PY'\n") + len("<<'PY'\n")
    body_end = helper.index("\nPY\n", body_start)
    snapshot_code = helper[body_start:body_end]

    def create_state(path: Path, *, marker: str = "network-manager-api-id-v1", unknown_table: bool = False) -> None:
        connection = sqlite3.connect(path)
        connection.executescript(
            """
            CREATE TABLE virtual_networks (uid TEXT, tenant_id TEXT, virtual_network_cidr TEXT,
              namespace_name TEXT, namespace_interface TEXT, host_interface TEXT,
              transit_cidr TEXT, transit_start INTEGER, payload TEXT);
            CREATE TABLE subnets (uid TEXT, virtual_network_uid TEXT, tenant_id TEXT, vlan_id INTEGER,
              vlan_interface TEXT, ipv4_cidr TEXT, phase TEXT, payload TEXT);
            CREATE TABLE external_ip_pools (uid TEXT, fulfillment_id TEXT, tenant_id TEXT,
              ip_family TEXT, ipv4_cidr TEXT);
            CREATE TABLE external_ips (uid TEXT, fulfillment_id TEXT, tenant_id TEXT,
              pool_uid TEXT, address TEXT);
            CREATE TABLE attachments (uid TEXT, fulfillment_id TEXT, tenant_id TEXT,
              external_ip_uid TEXT, virtual_network_uid TEXT, subnet_uid TEXT,
              external_address TEXT, phase TEXT, payload TEXT);
            CREATE TABLE nat_gateways (uid TEXT, fulfillment_id TEXT, tenant_id TEXT,
              external_ip_uid TEXT, virtual_network_uid TEXT, external_address TEXT,
              phase TEXT, payload TEXT);
            CREATE TABLE network_attachments (uid TEXT, tenant_id TEXT, virtual_network_uid TEXT,
              subnet_uid TEXT, host_name TEXT, interface_name TEXT, mac_address TEXT,
              address TEXT, phase TEXT, payload TEXT);
            CREATE TABLE network_attachment_ports (switch_name TEXT, port_name TEXT, attachment_uid TEXT);
            CREATE TABLE deleted_resources (kind TEXT, uid TEXT, tenant_id TEXT);
            CREATE TABLE state_metadata (key TEXT, value TEXT);
            """
        )
        connection.execute("INSERT INTO state_metadata VALUES ('contract', ?)", (marker,))
        attachment = {
            "uid": "attachment-id",
            "tenant_id": "test-tenant",
            "virtual_network_uid": "vn-api-id",
            "subnet_uid": "subnet-api-id",
            "host_name": "osac-e2e-a1",
            "interface_name": "eth0",
            "mac_address": "02:00:00:00:00:01",
            "address": "10.0.1.2",
            "phase": "ready",
            "ports": [{"switch_name": "leaf-1", "port_name": "swp2", "selected": True, "fabric": True}],
        }
        connection.execute(
            "INSERT INTO network_attachments VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (attachment["uid"], attachment["tenant_id"], attachment["virtual_network_uid"],
             attachment["subnet_uid"], attachment["host_name"], attachment["interface_name"],
             attachment["mac_address"], attachment["address"], attachment["phase"], json.dumps(attachment)),
        )
        connection.execute("INSERT INTO network_attachment_ports VALUES (?, ?, ?)", ("leaf-1", "swp2", "attachment-id"))
        connection.execute("INSERT INTO deleted_resources VALUES (?, ?, ?)", ("Subnet", "deleted-subnet-id", "test-tenant"))
        connection.execute(
            "INSERT INTO attachments VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            ("eia-api-id", "eia-api-id", "test-tenant", "eip-api-id", "vn-api-id", "subnet-api-id",
             "198.51.100.21", "ready", json.dumps({"context": {"destination": {"address": "10.0.1.2"}}})),
        )
        connection.execute(
            "INSERT INTO nat_gateways VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            ("nat-api-id", "nat-api-id", "test-tenant", "eip-api-id", "vn-api-id",
             "198.51.100.22", "ready", json.dumps({"phase": "ready"})),
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
    create_state(current_schema)
    snapshot = read_state(current_schema)
    assert snapshot["state_contract"] == "network-manager-api-id-v1"
    assert snapshot["identity_semantics"] == "api-id"
    assert snapshot["network_attachments"][0]["api_id"] == "attachment-id"
    assert snapshot["network_attachment_ports"] == [
        {"switch_name": "leaf-1", "port_name": "swp2", "attachment_uid": "attachment-id", "attachment_api_id": "attachment-id"}
    ]
    assert snapshot["deleted_resources"] == [
        {"kind": "Subnet", "uid": "deleted-subnet-id", "api_id": "deleted-subnet-id", "tenant_id": "test-tenant"}
    ]
    assert snapshot["external_ip_attachments"][0]["api_id"] == "eia-api-id"
    assert snapshot["nat_gateways"][0]["api_id"] == "nat-api-id"

    missing = read_state(tmp_path / "missing.sqlite3")
    assert missing["schema_version"] == 0
    assert missing["network_attachments"] == []
    assert missing["deleted_resources"] == []

    bad_marker = tmp_path / "bad-marker.sqlite3"
    create_state(bad_marker, marker="legacy-uid-v1")
    result = subprocess.run(
        [sys.executable, "-", str(bad_marker)], input=snapshot_code, capture_output=True, text=True, check=False
    )
    assert result.returncode != 0
    assert "contract marker" in result.stderr

    unknown_schema = tmp_path / "unknown-schema.sqlite3"
    create_state(unknown_schema, unknown_table=True)
    result = subprocess.run(
        [sys.executable, "-", str(unknown_schema)], input=snapshot_code, capture_output=True, text=True, check=False
    )
    assert result.returncode != 0
    assert "tables do not match" in result.stderr


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
            "BMAAS_MODE=false\n"
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
    assert cleanup_block.index("prepare_suite_cleanup") < cleanup_block.rindex("exit 0")
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

    assert "deleted_resources" in verifier
    assert "assert_baseline_state_unchanged || return 1" in verifier
    assert '.kind != "VirtualNetwork"' in verifier
    assert '.kind != "Subnet"' in verifier


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
    assert '.task == "apply_network_attachment" or .task == "delete_network_attachment"' in helper
    assert '.target.host_name == ("osac-e2e-" + $client)' in helper
    assert '.network_attachment.interface.mac_address' in helper
    assert 'candidate_subnet" == "$subnet_ref"' in helper
    assert 'switch_exec "$CLIENT_SWITCH" bridge -j vlan show dev "$CLIENT_SWITCH_PORT"' in helper
    assert 'index("Egress Untagged") != null' in helper
    assert cleanup.index("CLEANUP_DISCOVERY_COMPLETE=true") < cleanup.index(
        "cleanup_interrupted_dhcp_clients"
    )
    assert '"${CLEANUP_CLIENTS_COMPLETE:-true}" != true' in on_exit


def test_dhcp_lease_uniqueness_is_scoped_to_virtual_network(tmp_path):
    helper_block = function_block("write_agentless_e2e_helpers", "nvue_interface_config")
    source_start = helper_block.index("<<'PY'\n") + len("<<'PY'\n")
    source_end = helper_block.index('\nPY\n    cat >"$DHCP_CLIENT_HOOK"', source_start)
    helper_path = tmp_path / "dhcp_clients.py"
    helper_path.write_text(helper_block[source_start:source_end])

    client_macs = {
        "a1": "02:00:00:00:00:01",
        "b1": "02:00:00:00:00:02",
    }
    dnsmasq_leases = tmp_path / "dnsmasq.leases"
    dnsmasq_leases.write_text(
        "".join(f"0 {mac} 10.250.0.2 {name} *\n" for name, mac in client_macs.items())
    )

    def run_case(virtual_network_ids: dict[str, str]):
        expected_clients = []
        args = [
            sys.executable,
            str(helper_path),
            "assert-client-leases",
            "--expected",
            str(tmp_path / "expected.json"),
            "--dnsmasq-leases",
            str(dnsmasq_leases),
        ]
        for name, mac in client_macs.items():
            lease_path = tmp_path / f"{name}.json"
            lease_path.write_text(
                json.dumps(
                    {
                        "address": "10.250.0.2",
                        "netmask": "255.255.255.0",
                        "router": "10.250.0.1",
                        "mac": mac,
                    }
                )
            )
            expected_clients.append(
                {
                    "name": name,
                    "mac": mac,
                    "subnet": {
                        "uid": f"subnet-{name}",
                        "virtual_network_uid": virtual_network_ids[name],
                        "ipv4_cidr": "10.250.0.0/24",
                        "ipam": {
                            "gateway_ipv4": "10.250.0.1",
                            "physical_ipv4_cidrs": ["10.250.0.0/24"],
                            "lb_vip_ipv4_cidrs": [],
                        },
                    },
                }
            )
            args.extend(["--lease", f"{name}={lease_path}"])
        (tmp_path / "expected.json").write_text(json.dumps({"clients": expected_clients}))
        return subprocess.run(args, capture_output=True, text=True, timeout=5)

    overlapping_networks = run_case({"a1": "vn-a", "b1": "vn-b"})
    assert overlapping_networks.returncode == 0, overlapping_networks.stderr

    same_network = run_case({"a1": "vn-a", "b1": "vn-a"})
    assert same_network.returncode != 0
    assert "duplicate address 10.250.0.2 in VirtualNetwork vn-a" in same_network.stderr
