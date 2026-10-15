import json
import os
import shlex
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
RUNNER = REPO_ROOT / "vlan-e2e.sh"
SOURCE = RUNNER.read_text()


def function_block(start: str, end: str) -> str:
    start_index = SOURCE.index(f"{start}() {{")
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


def test_cumulus_ssh_config_has_only_named_lab_aliases(tmp_path):
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


def test_per_run_key_cleanup_preserves_admin_key(tmp_path):
    helpers = function_block("remove_containerlab_switch_keys", "restore_containerlab_switch_access")
    ssh_dir = tmp_path / "guest-home" / ".ssh"
    ssh_dir.mkdir(parents=True)
    admin_key = "ssh-ed25519 AAAAC3Nza-admin osac-admin"
    provider_key = "ssh-ed25519 AAAAC3Nza-provider osac-provider"
    authorized_keys = ssh_dir / "authorized_keys"
    authorized_keys.write_text(f"{admin_key}\n{provider_key}\n")
    key_file = tmp_path / "provider.pub"
    key_file.write_text(provider_key + "\n")
    key_file.chmod(0o600)
    script = f"""
set -euo pipefail
SWITCH_ACCESS_CONFIGURED=true
SSH_PUBLIC_KEY_FILE={shlex.quote(str(key_file))}
SWITCH_MANIFEST_FILE=/tmp/ignored-switches.json
declare -A SWITCH_PUBLIC_KEY_INSTALLED_BY_RUN=([clab-agentless-net-lab-leaf-1]=true)
declare -A SWITCH_AUTHORIZED_KEYS_EXISTED=([clab-agentless-net-lab-leaf-1]=true)
jq() {{ printf '%s\\n' clab-agentless-net-lab-leaf-1; }}
switch_admin_exec() {{
    local switch="$1"
    shift
    [[ "$switch" == clab-agentless-net-lab-leaf-1 && "$1" == sh && "$2" == -c ]]
    local remote_script="$3"
    shift 3
    [[ "$remote_script" == *'awk -v key='* && "$2" == "$PROVIDER_PUBLIC_KEY" ]]
    awk -v key="$2" '$0 != key' "$TEST_AUTHORIZED_KEYS" >"$TEST_AUTHORIZED_KEYS.tmp"
    if [[ -s "$TEST_AUTHORIZED_KEYS.tmp" || "$3" == true ]]; then
        mv "$TEST_AUTHORIZED_KEYS.tmp" "$TEST_AUTHORIZED_KEYS"
    else
        rm -f "$TEST_AUTHORIZED_KEYS.tmp" "$TEST_AUTHORIZED_KEYS"
    fi
}}
{helpers}
remove_containerlab_switch_keys
[[ "${{SWITCH_PUBLIC_KEY_INSTALLED_BY_RUN[clab-agentless-net-lab-leaf-1]}}" == false ]]
"""
    env = os.environ.copy()
    env["TEST_AUTHORIZED_KEYS"] = str(authorized_keys)
    env["PROVIDER_PUBLIC_KEY"] = provider_key
    result = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
        env=env,
        timeout=5,
    )

    assert result.returncode == 0, result.stderr
    remaining = authorized_keys.read_text().splitlines()
    assert remaining == [admin_key]
