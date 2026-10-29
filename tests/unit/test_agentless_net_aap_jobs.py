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


class FakeNATGatewayJobController:
    def __init__(self, *, job: dict[str, Any] | None = None) -> None:
        self.requests: list[str] = []
        self.job = job or {
            "status": "successful",
            "scm_revision": REVISION,
            "project": 23,
            "execution_environment": 34,
            "extra_vars": json.dumps(
                {
                    "osac_job_vars": {
                        "resource": {
                            "apiVersion": "osac.openshift.io/v1alpha1",
                            "kind": "NATGateway",
                            "metadata": {
                                "name": "natgateway-hgwmf",
                                "namespace": "osac-e2e-ci",
                                "uid": "10000000-0000-4000-8000-000000000011",
                                "generation": 4,
                                "labels": {"osac.openshift.io/natgateway-uuid": "10000000-0000-4000-8000-000000000010"},
                                "annotations": {
                                    "osac.openshift.io/tenant": "osac-e2e-ci",
                                    "osac.openshift.io/implementation-strategy": "agentless_net",
                                    "osac.openshift.io/natgateway-contract-version": "v1",
                                },
                            },
                            "spec": {
                                "virtualNetwork": "10000000-0000-4000-8000-000000000002",
                                "externalIP": "10000000-0000-4000-8000-000000000006",
                            },
                        },
                        "nat_gateway_context": {
                            "external_ip": {
                                "name": "agentless-eip-run-a",
                                "namespace": "osac-e2e-ci",
                                "fulfillment_id": "10000000-0000-4000-8000-000000000006",
                                "kubernetes_uid": "10000000-0000-4000-8000-000000000005",
                                "tenant_id": "osac-e2e-ci",
                                "address": "198.51.100.21",
                                "state": "Allocated",
                                "phase": "Ready",
                            },
                            "virtual_network": {
                                "name": "agentless-smoke-vn-run-a",
                                "namespace": "osac-e2e-ci",
                                "fulfillment_id": "10000000-0000-4000-8000-000000000002",
                                "kubernetes_uid": "10000000-0000-4000-8000-000000000003",
                                "tenant_id": "osac-e2e-ci",
                                "ipv4_cidr": "10.250.0.0/16",
                                "phase": "Ready",
                            },
                        },
                    }
                }
            ),
            "artifacts": {
                "osac_result": {
                    "schemaVersion": "v1",
                    "operation": "nat_gateway.ensure",
                    "resourceUID": "10000000-0000-4000-8000-000000000011",
                    "observedGeneration": 4,
                    "data": {},
                }
            },
        }

    def request(self, endpoint: str, *, body: dict[str, Any] | None = None) -> dict[str, Any]:
        del body
        self.requests.append(endpoint)
        if endpoint == "/jobs/55/":
            return self.job
        if endpoint == "/projects/23/":
            return {"name": "osac", "scm_revision": REVISION}
        if endpoint == "/execution_environments/34/":
            return {"name": "osac-ee", "image": "quay.io/osac/aap:natgw"}
        raise AssertionError(f"unexpected Controller endpoint {endpoint}")


class FakeCredentialController:
    def __init__(self) -> None:
        self.job_templates = {"osac-move-network-attachment": 12, "osac-query-dhcp-lease": 13}
        self.credential_type: dict[str, Any] | None = None
        self.credential: dict[str, Any] | None = None
        self.associations: dict[int, set[int]] = {12: set(), 13: set()}
        self.requests: list[tuple[str, dict[str, Any] | None, str | None]] = []

    def list_named_items(self, endpoint: str, name: str) -> list[dict[str, Any]]:
        if endpoint == "/job_templates/":
            template_id = self.job_templates.get(name)
            return [] if template_id is None else [{"id": template_id, "name": name}]
        if endpoint == "/credential_types/":
            if self.credential_type and self.credential_type["name"] == name:
                return [self.credential_type]
            return []
        if endpoint == "/credentials/":
            if self.credential and self.credential["name"] == name:
                return [self.credential]
            return []
        raise AssertionError(f"unexpected list endpoint {endpoint}")

    def list_named(self, endpoint: str, name: str) -> dict[str, Any]:
        matches = self.list_named_items(endpoint, name)
        assert len(matches) == 1
        return matches[0]

    def request(
        self, endpoint: str, *, body: dict[str, Any] | None = None, method: str | None = None
    ) -> dict[str, Any]:
        self.requests.append((endpoint, body, method))
        if endpoint in {"/job_templates/12/", "/job_templates/13/"}:
            return {"organization": 3}
        if endpoint == "/credential_types/" and body is not None:
            self.credential_type = {"id": 44, **body}
            return self.credential_type
        if endpoint == "/credential_types/44/" and method is None:
            assert self.credential_type is not None
            return self.credential_type
        if endpoint == "/credentials/" and body is not None:
            self.credential = {"id": 55, **body}
            return self.credential
        if endpoint == "/credentials/55/" and method is None:
            assert self.credential is not None
            return self.credential
        if endpoint == "/credentials/55/" and method == "PUT":
            assert self.credential is not None
            self.credential.update(body or {})
            return self.credential
        if endpoint.endswith("/credentials/") and body is not None:
            template_id = int(endpoint.split("/")[2])
            if body.get("disassociate"):
                self.associations[template_id].discard(body["id"])
            else:
                self.associations[template_id].add(body["id"])
            return {}
        if endpoint.endswith("/credentials/") and method is None:
            template_id = int(endpoint.split("/")[2])
            return {"results": [{"id": item} for item in sorted(self.associations[template_id])]}
        if endpoint == "/credentials/55/" and method == "DELETE":
            self.credential = None
            return {}
        raise AssertionError(f"unexpected Controller request {endpoint} ({method})")


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


def credential_args(tmp_path: Path) -> argparse.Namespace:
    token_file = tmp_path / "subnet-reader.token"
    ca_file = tmp_path / "subnet-reader-ca.pem"
    token_file.write_text("private-service-account-token\n")
    ca_file.write_text("-----BEGIN CERTIFICATE-----\nca-data\n-----END CERTIFICATE-----\n")
    return argparse.Namespace(
        job_template=["osac-move-network-attachment", "osac-query-dhcp-lease"],
        credential_name="vlan-e2e-subnet-reader",
        credential_type_name="OSAC VLAN E2E Kubernetes API",
        api_host="https://kubernetes.default.svc",
        token_file=str(token_file),
        ca_file=str(ca_file),
    )


def test_launch_verifies_project_ee_and_returns_job_artifacts(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    controller = FakeController(
        artifacts={
            "leases": [
                {
                    "subnet_ref": "1" * 36,
                    "interface": "eth0",
                    "ip_address": "10.0.1.2",
                    "mac_address": "02:00:00:00:00:01",
                }
            ]
        }
    )
    monkeypatch.setattr(aap_jobs, "Controller", lambda: controller)

    result = aap_jobs.launch(args_for(tmp_path))

    assert result["job_id"] == 55
    assert result["job_template"] == "osac-query-dhcp-lease"
    assert result["project_revision"] == REVISION
    assert result["artifacts"]["leases"][0]["ip_address"] == "10.0.1.2"
    assert any(endpoint == "/job_templates/12/launch/" for endpoint, _ in controller.requests)


def test_launch_accepts_successful_move_job_without_artifacts(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    controller = FakeController()
    monkeypatch.setattr(aap_jobs, "Controller", lambda: controller)
    args = args_for(tmp_path)
    args.job_template = "osac-move-network-attachment"

    result = aap_jobs.launch(args)

    assert result["status"] == "successful"
    assert result["artifacts"] == {}


def test_inspect_nat_gateway_job_returns_only_verified_input_and_result(monkeypatch: pytest.MonkeyPatch) -> None:
    controller = FakeNATGatewayJobController()
    submitted = json.loads(controller.job["extra_vars"])
    submitted["osac_job_vars"]["nat_gateway_context"]["api_token"] = "private-context-token"
    controller.job["extra_vars"] = json.dumps(submitted)
    monkeypatch.setattr(aap_jobs, "Controller", lambda: controller)
    args = argparse.Namespace(
        job_id=55,
        operation="nat_gateway.ensure",
        project_name="osac",
        project_revision=REVISION,
        ee_name="osac-ee",
        ee_image="quay.io/osac/aap:natgw",
    )

    result = aap_jobs.inspect_nat_gateway_job(args)

    assert result["job_id"] == 55
    assert result["project_revision"] == REVISION
    assert result["resource"]["metadata"]["generation"] == 4
    assert result["resource"]["metadata"]["name"] == "natgateway-hgwmf"
    assert result["resource"]["spec"]["externalIP"] == "10000000-0000-4000-8000-000000000006"
    assert result["nat_gateway_context"]["external_ip"]["address"] == "198.51.100.21"
    assert result["artifacts"]["osac_result"]["operation"] == "nat_gateway.ensure"
    assert "extra_vars" not in result
    assert "api_token" not in json.dumps(result)
    assert "private-context-token" not in json.dumps(result)
    assert controller.requests == ["/jobs/55/", "/projects/23/", "/execution_environments/34/"]


@pytest.mark.parametrize(
    ("change", "operation", "message"),
    [
        ("revision", "nat_gateway.ensure", "expected source revision"),
        ("context", "nat_gateway.ensure", "does not match"),
        ("artifact", "nat_gateway.ensure", "no NATGateway result artifact"),
        ("artifact-operation", "nat_gateway.ensure", "mismatched NATGateway result artifact"),
        ("project", "nat_gateway.ensure", "unexpected project"),
        ("ee", "nat_gateway.ensure", "unexpected execution environment"),
    ],
)
def test_inspect_nat_gateway_job_rejects_stale_or_malformed_evidence(
    monkeypatch: pytest.MonkeyPatch, change: str, operation: str, message: str
) -> None:
    controller = FakeNATGatewayJobController()
    if change == "revision":
        controller.job["scm_revision"] = "b" * 40
    elif change == "context":
        submitted = json.loads(controller.job["extra_vars"])
        submitted["osac_job_vars"]["nat_gateway_context"]["external_ip"]["fulfillment_id"] = "wrong-id"
        controller.job["extra_vars"] = json.dumps(submitted)
    elif change == "artifact":
        controller.job["artifacts"] = {}
    elif change == "artifact-operation":
        controller.job["artifacts"]["osac_result"]["operation"] = "nat_gateway.delete"
    elif change == "project":
        monkeypatch.setattr(
            controller,
            "request",
            lambda endpoint, body=None: (
                {"name": "other", "scm_revision": REVISION}
                if endpoint == "/projects/23/"
                else FakeNATGatewayJobController.request(controller, endpoint, body=body)
            ),
        )
    elif change == "ee":
        monkeypatch.setattr(
            controller,
            "request",
            lambda endpoint, body=None: (
                {"name": "other", "image": "quay.io/osac/aap:old"}
                if endpoint == "/execution_environments/34/"
                else FakeNATGatewayJobController.request(controller, endpoint, body=body)
            ),
        )
    monkeypatch.setattr(aap_jobs, "Controller", lambda: controller)
    args = argparse.Namespace(
        job_id=55,
        operation=operation,
        project_name="osac",
        project_revision=REVISION,
        ee_name="osac-ee",
        ee_image="quay.io/osac/aap:natgw",
    )

    with pytest.raises(aap_jobs.AAPError, match=message):
        aap_jobs.inspect_nat_gateway_job(args)


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
    result = {"job_id": 55, "status": "successful", "artifacts": {"leases": [{"ip_address": "10.0.1.2"}]}}
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


@pytest.mark.parametrize(
    ("command", "handler_name", "command_options"),
    [
        (
            "configure-k8s-credential",
            "configure_k8s_credential",
            ["--api-host", "https://kubernetes.default.svc", "--token-file", "token", "--ca-file", "ca"],
        ),
        ("cleanup-k8s-credential", "cleanup_k8s_credential", []),
    ],
)
def test_credential_commands_accept_multiple_job_templates(
    monkeypatch: pytest.MonkeyPatch, command: str, handler_name: str, command_options: list[str]
) -> None:
    captured: dict[str, argparse.Namespace] = {}

    def capture(args: argparse.Namespace) -> dict[str, str]:
        captured["args"] = args
        return {"status": "configured"}

    monkeypatch.setattr(aap_jobs, handler_name, capture)
    monkeypatch.setattr(
        "sys.argv",
        [
            "aap_jobs.py",
            command,
            "--job-template",
            "osac-move-network-attachment",
            "--job-template",
            "osac-query-dhcp-lease",
            "--credential-name",
            "vlan-e2e-subnet-reader",
            "--credential-type-name",
            "OSAC VLAN E2E Kubernetes API",
            *command_options,
        ],
    )

    assert aap_jobs.main() == 0
    assert captured["args"].job_template == ["osac-move-network-attachment", "osac-query-dhcp-lease"]


def test_configure_k8s_credential_attaches_secret_without_returning_it(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    controller = FakeCredentialController()
    monkeypatch.setattr(aap_jobs, "Controller", lambda: controller)

    result = aap_jobs.configure_k8s_credential(credential_args(tmp_path))

    assert result["template_ids"] == [12, 13]
    assert result["credential_id"] == 55
    assert result["credential_type_id"] == 44
    assert controller.associations == {12: {55}, 13: {55}}
    assert controller.credential is not None
    assert controller.credential["inputs"]["api_token"] == "private-service-account-token"
    assert "private-service-account-token" not in json.dumps(result)
    assert "K8S_AUTH_API_KEY" in controller.credential_type["injectors"]["env"]


@pytest.mark.parametrize(
    "description", [aap_jobs.K8S_CREDENTIAL_DESCRIPTION, aap_jobs.K8S_CREDENTIAL_LEGACY_DESCRIPTION]
)
def test_cleanup_k8s_credential_detaches_and_removes_secret(monkeypatch: pytest.MonkeyPatch, description: str) -> None:
    controller = FakeCredentialController()
    controller.credential_type = {
        "id": 44,
        "name": "OSAC VLAN E2E Kubernetes API",
        "description": aap_jobs.K8S_CREDENTIAL_TYPE_DESCRIPTION,
        "kind": "cloud",
        "inputs": aap_jobs.K8S_CREDENTIAL_INPUTS,
        "injectors": aap_jobs.K8S_CREDENTIAL_INJECTORS,
    }
    controller.credential = {
        "id": 55,
        "name": "vlan-e2e-subnet-reader",
        "description": description,
        "credential_type": 44,
    }
    controller.associations[12].add(55)
    controller.associations[13].add(55)
    monkeypatch.setattr(aap_jobs, "Controller", lambda: controller)
    args = argparse.Namespace(
        job_template=["osac-move-network-attachment", "osac-query-dhcp-lease"],
        credential_name="vlan-e2e-subnet-reader",
        credential_type_name="OSAC VLAN E2E Kubernetes API",
    )

    result = aap_jobs.cleanup_k8s_credential(args)

    assert result["status"] == "removed"
    assert controller.associations == {12: set(), 13: set()}
    assert controller.credential is None
    disassociate_requests = [
        request for request in controller.requests if request[1] == {"id": 55, "disassociate": True}
    ]
    delete_credential = ("/credentials/55/", None, "DELETE")
    assert disassociate_requests == [
        ("/job_templates/12/credentials/", {"id": 55, "disassociate": True}, None),
        ("/job_templates/13/credentials/", {"id": 55, "disassociate": True}, None),
    ]
    assert max(controller.requests.index(request) for request in disassociate_requests) < controller.requests.index(
        delete_credential
    )


def test_cleanup_k8s_credential_refuses_unrecognized_credential(monkeypatch: pytest.MonkeyPatch) -> None:
    controller = FakeCredentialController()
    controller.credential = {
        "id": 55,
        "name": "vlan-e2e-subnet-reader",
        "description": "unrelated credential",
        "credential_type": 44,
    }
    monkeypatch.setattr(aap_jobs, "Controller", lambda: controller)
    args = argparse.Namespace(
        job_template=["osac-move-network-attachment", "osac-query-dhcp-lease"],
        credential_name="vlan-e2e-subnet-reader",
        credential_type_name="OSAC VLAN E2E Kubernetes API",
    )

    with pytest.raises(aap_jobs.AAPError, match="unexpected AAP Kubernetes credential"):
        aap_jobs.cleanup_k8s_credential(args)

    assert not any(method == "DELETE" for _, _, method in controller.requests)
