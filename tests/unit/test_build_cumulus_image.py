import importlib.util
from pathlib import Path

import pytest


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "e2e"
    / "agentless_net"
    / "lab"
    / "build_cumulus_image.py"
)
SPEC = importlib.util.spec_from_file_location("build_cumulus_image", SCRIPT)
build_cumulus_image = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(build_cumulus_image)


def profile_with_ipv6_commands(count=5):
    lines = [f"nv set interface eth0 ipv6 test-{index}" for index in range(count)]
    return f"""
name: nvidia_cumulusvx
packaging:
  process:
    - type: prompts
      prompts:
        prompts:
          - name: confirm ztp disable
            response: test-only-password
run:
  process:
    - type: prompts
      prompts:
        prompts:
          - name: enter password
            response: test-runtime-password
    - type: write
      write:
        content: |
{chr(10).join(f'          {line}' for line in lines)}
          nv set system hostname {{{{ .hostname }}}}
  configProcess:
    - type: write
      write:
        content: nv config apply -y
"""


def test_adapt_profile_removes_ipv6_and_adds_lab_sudo_baseline():
    adapted, removed_ipv6 = build_cumulus_image.adapt_profile(profile_with_ipv6_commands())
    profile = build_cumulus_image.yaml.safe_load(adapted)
    sudo_command = profile["packaging"]["process"][1]["write"]["content"]
    sudo_prompts = profile["packaging"]["process"][2]["prompts"]
    sudo_password_prompt, sudo_success_prompt = sudo_prompts["prompts"]
    runtime_sudo_command = profile["run"]["configProcess"][-2]["write"]["content"]

    assert removed_ipv6 == 5
    assert "ipv6" not in adapted
    assert build_cumulus_image.SUDOERS_PATH in sudo_command
    assert build_cumulus_image.SUDOERS_CONTENT in sudo_command
    assert "sudo -S" in sudo_command
    assert "BOXEN_" in sudo_command and "SUDOERS_OK" in sudo_command
    assert "BOXEN_SUDOERS_OK" not in sudo_command
    assert "hidden: true" in adapted
    assert "test-only-password" in adapted
    assert "test-runtime-password" in adapted
    assert "sudo -S" in runtime_sudo_command
    assert "BOXEN_" in runtime_sudo_command and "SUDOERS_OK" in runtime_sudo_command
    assert "BOXEN_SUDOERS_OK" not in runtime_sudo_command
    assert sudo_prompts["initialInput"] == "\r"
    assert sudo_password_prompt["response"] == "test-only-password"
    assert sudo_password_prompt["hidden"] is True
    assert sudo_password_prompt.get("completes", False) is False
    assert sudo_success_prompt["prompt"] == {"contains": "BOXEN_SUDOERS_OK"}
    assert sudo_success_prompt["completes"] is True


def test_adapt_profile_rejects_unexpected_upstream_ipv6_shape():
    with pytest.raises(ValueError, match="Expected.*five optional IPv6"):
        build_cumulus_image.adapt_profile(profile_with_ipv6_commands(count=4))
