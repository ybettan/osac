import argparse
import importlib.util
import json
import sys
from pathlib import Path
from typing import Any

import pytest

MODULE_PATH = Path(__file__).resolve().parents[1] / "e2e/agentless_net/lab/aap_jobs.py"
MODULE_SPEC = importlib.util.spec_from_file_location("agentless_net_aap_jobs", MODULE_PATH)
assert MODULE_SPEC is not None and MODULE_SPEC.loader is not None
aap_jobs = importlib.util.module_from_spec(MODULE_SPEC)
sys.modules[MODULE_SPEC.name] = aap_jobs
MODULE_SPEC.loader.exec_module(aap_jobs)


REVISION = "a" * 40


class FakeController:
    def __init__(
        self,
        *,
        job_status: str = "successful",
        revision: str | None = REVISION,
        artifacts: dict[str, Any] | None = None,
    ) -> None:
        self.job_status = job_status
        self.revision = revision
        self.artifacts = artifacts
        self.requests: list[tuple[str, dict[str, Any] | None]] = []

    def list_named(self, endpoint: str, name: str) -> dict[str, Any]:
        assert endpoint == "/job_templates/"
        return {"id": 12, "name": name}

    def request(self, endpoint: str, *, body: dict[str, Any] | None = None) -> dict[str, Any]:
        self.requests.append((endpoint, body))
        if endpoint == "/job_templates/12/":
            return {"project": 23, "execution_environment": 34}
        if endpoint == "/projects/23/":
            return {"name": "osac", "scm_revision": REVISION}
        if endpoint == "/execution_environments/34/":
            return {"name": "osac-ee", "image": "quay.io/osac/aap:fix"}
        if endpoint == "/job_templates/12/launch/":
            assert json.loads(body["extra_vars"]) == {"osac_job_vars": {"resource": {"metadata": {}}}}
            return {"job": 55}
        if endpoint == "/jobs/55/":
            return {"status": self.job_status, "scm_revision": self.revision, "artifacts": self.artifacts}
        raise AssertionError(f"unexpected Controller endpoint {endpoint}")


def args_for(tmp_path: Path) -> argparse.Namespace:
    extra_vars = tmp_path / "extra-vars.json"
    extra_vars.write_text(json.dumps({"osac_job_vars": {"resource": {"metadata": {}}}}))
    return argparse.Namespace(
        job_template="osac-query-dhcp-lease",
        extra_vars=str(extra_vars),
        output=str(tmp_path / "result.json"),
        project_name="osac",
        project_revision=REVISION,
        ee_name="osac-ee",
        ee_image="quay.io/osac/aap:fix",
        timeout=10,
    )


def test_launch_verifies_project_ee_and_returns_job_artifacts(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    controller = FakeController(
        artifacts={"osac_result": {"dhcp_lease": {"ip_address": "10.0.1.2", "mac_address": "02:00:00:00:00:01"}}}
    )
    monkeypatch.setattr(aap_jobs, "Controller", lambda: controller)

    result = aap_jobs.launch(args_for(tmp_path))

    assert result["job_id"] == 55
    assert result["job_template"] == "osac-query-dhcp-lease"
    assert result["project_revision"] == REVISION
    assert result["artifacts"]["osac_result"]["dhcp_lease"]["ip_address"] == "10.0.1.2"
    assert any(endpoint == "/job_templates/12/launch/" for endpoint, _ in controller.requests)


def test_launch_accepts_successful_move_job_without_artifacts(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    controller = FakeController()
    monkeypatch.setattr(aap_jobs, "Controller", lambda: controller)
    args = args_for(tmp_path)
    args.job_template = "osac-apply-network-attachment"

    result = aap_jobs.launch(args)

    assert result["status"] == "successful"
    assert result["artifacts"] == {}


@pytest.mark.parametrize(
    ("job_status", "revision", "message"),
    [
        ("failed", REVISION, "ended with status failed"),
        ("successful", "b" * 40, "did not use the expected source revision"),
        ("successful", None, "did not use the expected source revision"),
    ],
)
def test_launch_rejects_failed_jobs_and_wrong_job_revision(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, job_status: str, revision: str | None, message: str
) -> None:
    controller = FakeController(job_status=job_status, revision=revision)
    monkeypatch.setattr(aap_jobs, "Controller", lambda: controller)

    with pytest.raises(aap_jobs.AAPError, match=message):
        aap_jobs.launch(args_for(tmp_path))


def test_launch_rejects_unsynchronized_project(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    controller = FakeController()
    original_request = controller.request

    def request(endpoint: str, *, body: dict[str, Any] | None = None) -> dict[str, Any]:
        result = original_request(endpoint, body=body)
        if endpoint == "/projects/23/":
            result["scm_revision"] = "b" * 40
        return result

    controller.request = request
    monkeypatch.setattr(aap_jobs, "Controller", lambda: controller)

    with pytest.raises(aap_jobs.AAPError, match="not synchronized"):
        aap_jobs.launch(args_for(tmp_path))


def test_main_writes_private_output_and_does_not_print_artifacts(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    output = tmp_path / "result.json"
    result = {"job_id": 55, "status": "successful", "artifacts": {"osac_result": {"dhcp_lease": {"ip_address": "10.0.1.2"}}}}
    monkeypatch.setattr(aap_jobs, "launch", lambda _args: result)
    monkeypatch.setattr(
        "sys.argv",
        [
            "aap_jobs.py",
            "launch",
            "--job-template",
            "osac-query-dhcp-lease",
            "--extra-vars",
            str(tmp_path / "vars.json"),
            "--output",
            str(output),
            "--project-name",
            "osac",
            "--project-revision",
            REVISION,
            "--ee-name",
            "osac-ee",
            "--ee-image",
            "quay.io/osac/aap:fix",
        ],
    )

    assert aap_jobs.main() == 0
    assert output.stat().st_mode & 0o777 == 0o600
    assert "artifacts" not in capsys.readouterr().out
    original_output = output.read_text()
    assert aap_jobs.main() == 1
    assert output.read_text() == original_output
    assert "Could not create the private AAP job result file" in capsys.readouterr().err
