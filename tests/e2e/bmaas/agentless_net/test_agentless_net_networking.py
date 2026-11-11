from __future__ import annotations

import json
import os
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any

import pytest

from tests.e2e.bmaas.conftest import BMI_DISK_IMAGE_SOURCE_REF
from tests.e2e.core.grpc_client import PRIVATE_API, GRPCClient
from tests.e2e.core.helpers import (
    wait_for_bmh_available,
    wait_for_bmi_cr,
    wait_for_bmi_deletion,
    wait_for_bmi_external_host,
    wait_for_bmi_grpc_removal,
    wait_for_grpc_security_group_ready,
    wait_for_grpc_subnet_ready,
    wait_for_grpc_virtual_network_ready,
    wait_for_security_group_cr,
    wait_for_security_group_grpc_removal,
    wait_for_security_group_ready,
    wait_for_subnet_cr,
    wait_for_subnet_grpc_removal,
    wait_for_subnet_ready,
    wait_for_virtual_network_cr,
    wait_for_virtual_network_grpc_removal,
    wait_for_virtual_network_ready,
)
from tests.e2e.core.k8s_client import K8sClient
from tests.e2e.core.osac_cli import OsacCLI
from tests.e2e.core.runner import env
from tests.e2e.core.sanitize import sanitize_obj

pytestmark = [pytest.mark.requires_bmaas, pytest.mark.serial]

_MAC_ANNOTATION = "osac.openshift.io/interface-macs"


def _write_private_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.write_text(json.dumps(sanitize_obj(value), indent=2) + "\n")
    path.chmod(0o600)


def _journal_path() -> Path:
    evidence_dir = Path(env("OSAC_BMAAS_EVIDENCE_DIR", ".artifacts/agentless-net-bmaas/runs"))
    return evidence_dir / f"{env('OSAC_BMAAS_RUN_ID', 'agentless-bmaas')}.json"


def _job_summary(cr: dict[str, Any]) -> list[dict[str, str]]:
    status = cr.get("status", {})
    jobs: list[dict[str, str]] = []
    for field in ("networkingJobs", "ipDiscoveryJobs"):
        for job in status.get(field, []) or []:
            jobs.append(
                {
                    "phase": field,
                    "job_id": str(job.get("jobID", "")),
                    "state": str(job.get("state", "")),
                    "message": str(job.get("message", "")),
                }
            )
    return jobs


def _safe_extra_vars(raw: object) -> dict[str, Any]:
    """Keep only network identity fields from a job payload for the report."""
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except json.JSONDecodeError:
            return {"parse_error": True}
    if not isinstance(raw, dict):
        return {"present": False}
    job_vars = raw.get("osac_job_vars", {})
    if not isinstance(job_vars, dict):
        return {"osac_job_vars_present": False}
    resource = job_vars.get("resource", {})
    if not isinstance(resource, dict):
        resource = {}
    target = job_vars.get("target", {})
    if not isinstance(target, dict):
        target = {}
    network_attachment = job_vars.get("network_attachment", {})
    if not isinstance(network_attachment, dict):
        network_attachment = {}
    interface = network_attachment.get("interface", {})
    if not isinstance(interface, dict):
        interface = {}
    spec = resource.get("spec", {})
    if not isinstance(spec, dict):
        spec = {}
    legacy_attachments = spec.get("networkAttachments", spec.get("network_attachments", []))
    legacy_summary = []
    if isinstance(legacy_attachments, list):
        for attachment in legacy_attachments:
            if not isinstance(attachment, dict):
                continue
            legacy_summary.append(
                {
                    "subnet": attachment.get("subnetRef", attachment.get("subnet_ref", "")),
                    "interface": attachment.get("interface", ""),
                }
            )
    return {
        "task": job_vars.get("task", ""),
        "manager": job_vars.get("manager", {}),
        "tenant_present": bool(job_vars.get("tenant")),
        "resource_kind": resource.get("kind", ""),
        "resource_id": resource.get("id", ""),
        "target": {
            "kind": target.get("kind", ""),
            "id": target.get("id", ""),
            "host_name": target.get("host_name", ""),
        },
        "network_attachment": {
            "subnet": network_attachment.get("subnet", ""),
            "interface": {
                "type": interface.get("type", ""),
                "name": interface.get("name", ""),
                "mac_address": interface.get("mac_address", ""),
            },
        },
        "subnet_id": (job_vars.get("subnet") or {}).get("id", "") if isinstance(job_vars.get("subnet"), dict) else "",
        "network_attachment_macs": job_vars.get("network_attachment_macs", {}),
        "legacy_bmi_network_attachments": legacy_summary,
    }


def _read_aap_job(job_id: str) -> dict[str, Any]:
    route = os.environ.get("OSAC_BMAAS_AAP_ROUTE", "").rstrip("/")
    token = os.environ.get("OSAC_BMAAS_AAP_TOKEN", "")
    ca_path = os.environ.get("OSAC_BMAAS_AAP_CA_FILE", "")
    if not route or not token or not ca_path:
        return {"available": False}
    import ssl

    context = ssl.create_default_context(cafile=ca_path)
    request = urllib.request.Request(
        f"{route}/api/controller/v2/jobs/{job_id}/", headers={"Authorization": f"Bearer {token}"}
    )
    try:
        with urllib.request.urlopen(request, context=context, timeout=15) as response:
            job = json.loads(response.read())
    except (OSError, urllib.error.URLError, json.JSONDecodeError):
        return {"available": False}
    artifacts = job.get("artifacts", {})
    if not isinstance(artifacts, dict):
        artifacts = {}
    error = artifacts.get("osac_error", {})
    result = artifacts.get("osac_result", {})
    return {
        "available": True,
        "id": str(job.get("id", job_id)),
        "status": str(job.get("status", "")),
        "extra_vars": _safe_extra_vars(job.get("extra_vars", "")),
        "osac_error": error.get("message", "") if isinstance(error, dict) else "",
        "osac_result_keys": sorted(result) if isinstance(result, dict) else [],
    }


def _collect_reproduction(
    *, grpc: GRPCClient, k8s: K8sClient, bmi_id: str, bmh_namespace: str, subnet_id: str, run_id: str
) -> Path:
    api = grpc.get_baremetal_instance(bmi_id=bmi_id).get("object", {})
    cr_name = k8s.get_baremetal_instance_name(uuid=bmi_id, checked=False)
    cr = k8s.get_json(resource="baremetalinstance", name=cr_name) if cr_name else {}
    external_host_id = str(cr.get("spec", {}).get("externalHostID", ""))
    bmh_name = external_host_id.split("/", 1)[-1]
    bmh = k8s.get_json(resource="baremetalhost", name=bmh_name, namespace=bmh_namespace) if bmh_name else {}
    annotations = bmh.get("metadata", {}).get("annotations", {})
    raw_mapping = annotations.get(_MAC_ANNOTATION, "")
    try:
        mac_mapping = json.loads(raw_mapping) if raw_mapping else {}
    except json.JSONDecodeError:
        mac_mapping = {"malformed": True}
    nics = bmh.get("status", {}).get("hardware", {}).get("nics", [])
    jobs = _job_summary(cr)
    aap_jobs = [_read_aap_job(job["job_id"]) for job in jobs if job.get("job_id")]
    report = {
        "run_id": run_id,
        "source_sha": os.environ.get("OSAC_BMAAS_SOURCE_SHA", ""),
        "aap_project_revision": os.environ.get("OSAC_BMAAS_AAP_REVISION", ""),
        "aap_image": os.environ.get("OSAC_BMAAS_AAP_IMAGE", ""),
        "aap_image_id": os.environ.get("OSAC_BMAAS_AAP_IMAGE_ID", ""),
        "bmf_image": os.environ.get("OSAC_BMAAS_BMF_IMAGE", ""),
        "bmf_image_id": os.environ.get("OSAC_BMAAS_BMF_IMAGE_ID", ""),
        "test_infra_sha": os.environ.get("OSAC_BMAAS_TEST_INFRA_SHA", ""),
        "expected_test_infra_sha": os.environ.get("OSAC_BMAAS_TEST_INFRA_EXPECTED_SHA", ""),
        "bmi": {
            "id": bmi_id,
            "state": api.get("status", {}).get("state", ""),
            "network_attachment_statuses": api.get("status", {}).get(
                "networkAttachmentStatuses", api.get("status", {}).get("network_attachment_statuses", [])
            ),
            "conditions": cr.get("status", {}).get("conditions", []),
            "jobs": jobs,
        },
        "bmh": {
            "namespace": external_host_id.split("/", 1)[0] if "/" in external_host_id else bmh_namespace,
            "name": bmh_name,
            "interface_macs": mac_mapping,
            "hardware_nics": [
                {"name": nic.get("name", ""), "mac": str(nic.get("mac", "")).lower()}
                for nic in nics
                if isinstance(nic, dict)
            ],
        },
        "expected": {"subnet_id": subnet_id, "interface": "data-0"},
        "aap_jobs": aap_jobs,
    }
    evidence_dir = Path(os.environ.get("OSAC_BMAAS_EVIDENCE_DIR", ".artifacts/agentless-net-bmaas/runs"))
    path = evidence_dir / run_id / "reproduction.json"
    _write_private_json(path, report)
    return path


def _wait_for_running_or_failed(
    *, grpc: GRPCClient, k8s: K8sClient, bmi_id: str, bmh_namespace: str, subnet_id: str, run_id: str
) -> dict[str, Any]:
    state = ""
    for _ in range(180):
        state = grpc.get_baremetal_instance_state(bmi_id=bmi_id)
        if state == "BARE_METAL_INSTANCE_STATE_RUNNING" or "FAILED" in state:
            break
        time.sleep(10)
    if state != "BARE_METAL_INSTANCE_STATE_RUNNING":
        path = _collect_reproduction(
            grpc=grpc, k8s=k8s, bmi_id=bmi_id, bmh_namespace=bmh_namespace, subnet_id=subnet_id, run_id=run_id
        )
        raise AssertionError(
            f"BareMetalInstance {bmi_id} ended in {state or 'an unknown state'}; sanitized boundary evidence: {path}"
        )
    return grpc.get_baremetal_instance(bmi_id=bmi_id).get("object", {})


def _create_owned_resources(*, grpc: GRPCClient, run_id: str) -> dict[str, Any]:
    prefix = f"agentless-bmaas-{run_id}"
    vn_name = f"{prefix}-vn"
    vn_id = grpc.create_virtual_network(name=vn_name, ipv4_cidr="10.251.0.0/16")
    return {"prefix": prefix, "virtual_network_id": vn_id, "virtual_network_name": vn_name}


def test_agentless_bmaas_existing_flow(
    grpc: GRPCClient,
    private_grpc: GRPCClient,
    jwt_cli_user: OsacCLI,
    jwt_grpc_tenant1: GRPCClient,
    k8s_hub_client: K8sClient,
    bmh_namespace: str,
    bmi_template: str,
    test_run_id: str,
) -> None:
    """Run the existing BMaaS lifecycle through an AgentlessNet physical attachment."""
    run_id = f"{test_run_id}-{uuid.uuid4().hex[:6]}"
    prefix = f"agentless-bmaas-{run_id}"
    resources: dict[str, Any] = {"prefix": prefix, "bmis": []}
    key_dir: tempfile.TemporaryDirectory[str] | None = None
    try:
        resources.update(_create_owned_resources(grpc=grpc, run_id=run_id))
        _write_private_json(_journal_path(), resources)

        image_name = f"{prefix}-image"
        image_id = private_grpc.create_disk_image(
            name=image_name, source_ref=BMI_DISK_IMAGE_SOURCE_REF, architecture=["ARCHITECTURE_AMD64"], api=PRIVATE_API
        )
        resources.update(disk_image_id=image_id, disk_image_name=image_name)
        _write_private_json(_journal_path(), resources)

        instance_type_name = f"{prefix}-type"
        instance_type_id = private_grpc.create_bare_metal_instance_type(
            name=instance_type_name,
            network_ports=[{"name": "data-0", "role": "fabric", "type": "Ethernet", "speed": "10Gbps"}],
        )
        resources.update(instance_type_id=instance_type_id, instance_type_name=instance_type_name)
        _write_private_json(_journal_path(), resources)

        key_dir = tempfile.TemporaryDirectory(prefix="agentless-bmaas-key-")
        key_path = Path(key_dir.name) / "id_ed25519"
        subprocess.run(
            ["ssh-keygen", "-t", "ed25519", "-f", str(key_path), "-N", "", "-C", "agentless-bmaas-e2e"],
            check=True,
            capture_output=True,
            text=True,
        )
        key_name = f"{prefix}-key"
        jwt_cli_user.create_secret(
            name=key_name, from_files={"public_key": str(key_path.with_suffix(".pub"))}, secret_type="ssh-public-key"
        )
        resources["ssh_key_name"] = key_name
        _write_private_json(_journal_path(), resources)

        catalog_name = f"{prefix}-catalog"
        catalog_id = grpc.create_baremetal_instance_catalog_item(
            name=catalog_name,
            title=f"Agentless BMaaS E2E {run_id}",
            description="Temporary catalog item for the AgentlessNet BMaaS E2E",
            template=bmi_template,
            fields={
                "ssh_key": {"editable": {"default_value": {"name": key_name}}},
                "disk_image": {"editable": {"default_value": {"name": image_name, "shared": True}}},
                "instance_type": {"editable": {"default_value": {"name": instance_type_name, "shared": True}}},
            },
        )
        resources.update(catalog_id=catalog_id, catalog_name=catalog_name)
        _write_private_json(_journal_path(), resources)

        wait_for_virtual_network_ready(
            k8s=k8s_hub_client,
            name=wait_for_virtual_network_cr(k8s=k8s_hub_client, uuid=resources["virtual_network_id"]),
        )
        wait_for_grpc_virtual_network_ready(grpc=grpc, vn_id=resources["virtual_network_id"])

        sg_name = f"{prefix}-sg"
        sg_id = grpc.create_security_group_with_rules(
            name=sg_name,
            virtual_network=resources["virtual_network_id"],
            ingress=[
                {"protocol": "PROTOCOL_TCP", "port_from": 22, "port_to": 22, "ipv4_cidr": "0.0.0.0/0"},
                {"protocol": "PROTOCOL_TCP", "port_from": 18080, "port_to": 18080, "ipv4_cidr": "0.0.0.0/0"},
            ],
            egress=[{"protocol": "PROTOCOL_ALL", "ipv4_cidr": "0.0.0.0/0"}],
        )
        resources.update(security_group_id=sg_id, security_group_name=sg_name)
        wait_for_security_group_ready(
            k8s=k8s_hub_client, name=wait_for_security_group_cr(k8s=k8s_hub_client, uuid=sg_id)
        )
        wait_for_grpc_security_group_ready(grpc=grpc, sg_id=sg_id)

        subnet_name = f"{prefix}-subnet-a"
        subnet_id = grpc.create_subnet(
            name=subnet_name, virtual_network=resources["virtual_network_id"], ipv4_cidr="10.251.1.0/24"
        )
        resources.update(subnet_id=subnet_id, subnet_name=subnet_name)
        wait_for_subnet_ready(k8s=k8s_hub_client, name=wait_for_subnet_cr(k8s=k8s_hub_client, uuid=subnet_id))
        wait_for_grpc_subnet_ready(grpc=grpc, subnet_id=subnet_id)
        hosts = json.loads(Path(env("OSAC_BMAAS_HOSTS_FILE")).read_text()).get("hosts", [])
        assert len(hosts) == 2, f"Expected exactly two reusable BMaaS hosts, found {len(hosts)}"
        host_by_name = {host["name"]: host for host in hosts}
        for index in range(1, 3):
            bmi_name = f"{prefix}-bmi-{index}"
            bmi_id, _ = jwt_cli_user.create_baremetal_instance(
                name=bmi_name,
                catalog_item=catalog_name,
                instance_type=instance_type_name,
                ssh_key=key_name,
                disk_image=image_name,
                network_attachments=[f"subnet={subnet_id},interface=data-0,primary,security-groups={sg_id}"],
            )
            resources["bmis"].append({"id": bmi_id, "name": bmi_name})
            _write_private_json(_journal_path(), resources)
            bmi_cr_name = wait_for_bmi_cr(k8s=k8s_hub_client, uuid=bmi_id)
            bmh_ns, bmh_name = wait_for_bmi_external_host(k8s=k8s_hub_client, bmi_id=bmi_id, bmi_cr_name=bmi_cr_name)
            assert bmh_name in host_by_name, f"BMI {bmi_id} was allocated to an unowned BMH: {bmh_name}"
            resources["bmis"][-1].update(cr_name=bmi_cr_name, bmh_name=bmh_name, bmh_namespace=bmh_ns)
            _write_private_json(_journal_path(), resources)
            bmh = k8s_hub_client.get_json(resource="baremetalhost", name=bmh_name, namespace=bmh_ns)
            mac_mapping = json.loads(bmh.get("metadata", {}).get("annotations", {}).get(_MAC_ANNOTATION, "{}"))
            expected_mac = host_by_name[bmh_name]["fabric_mac"].lower()
            assert mac_mapping.get("data-0", "").lower() == expected_mac, (
                f"BMH {bmh_name} data-0 mapping does not match the fabric NIC"
            )
            discovered_macs = {
                str(nic.get("mac", "")).lower()
                for nic in bmh.get("status", {}).get("hardware", {}).get("nics", [])
                if isinstance(nic, dict)
            }
            assert expected_mac in discovered_macs, f"BMH {bmh_name} inspection does not include data-0"

            result = _wait_for_running_or_failed(
                grpc=jwt_grpc_tenant1,
                k8s=k8s_hub_client,
                bmi_id=bmi_id,
                bmh_namespace=bmh_namespace,
                subnet_id=subnet_id,
                run_id=run_id,
            )
            interface_statuses = result.get("status", {}).get(
                "networkAttachmentStatuses", result.get("status", {}).get("network_attachment_statuses", [])
            )
            assert interface_statuses, f"BMI {bmi_id} reached RUNNING without an attachment IP status"
            ip_status = interface_statuses[0].get("ipAddress", interface_statuses[0].get("ip_address", ""))
            assert ip_status, f"BMI {bmi_id} has no network attachment IP after RUNNING"
            assert ip_status.startswith("10.251.1."), f"BMI {bmi_id} IP {ip_status} is outside its test Subnet"

        _cleanup_run(
            grpc=grpc,
            private_grpc=private_grpc,
            cli=jwt_cli_user,
            k8s=k8s_hub_client,
            bmh_namespace=bmh_namespace,
            resources=resources,
        )
    except BaseException:
        _write_private_json(_journal_path(), resources)
        raise
    finally:
        if key_dir is not None:
            key_dir.cleanup()


def _cleanup_run(
    *,
    grpc: GRPCClient,
    private_grpc: GRPCClient,
    cli: OsacCLI,
    k8s: K8sClient,
    bmh_namespace: str,
    resources: dict[str, Any],
) -> None:
    cleanup_errors: list[str] = []
    live_bmis = set(grpc.list_baremetal_instance_ids())
    for bmi in resources.get("bmis", []):
        try:
            if bmi["id"] in live_bmis:
                current = grpc.get_baremetal_instance(bmi_id=bmi["id"]).get("object", {})
                metadata = current.get("metadata", {})
                if metadata.get("name") != bmi.get("name") or not metadata.get("name", "").startswith(
                    resources["prefix"]
                ):
                    raise RuntimeError("BMI id no longer resolves to the recorded test-owned name")
                cli.delete_baremetal_instance(uuid=bmi["id"])
            cr_name = bmi.get("cr_name") or k8s.get_baremetal_instance_name(uuid=bmi["id"], checked=False)
            if cr_name:
                wait_for_bmi_deletion(k8s=k8s, name=cr_name)
            wait_for_bmi_grpc_removal(grpc=grpc, uuid=bmi["id"])
            if bmi.get("bmh_name"):
                wait_for_bmh_available(
                    k8s=k8s, name=bmi["bmh_name"], bmh_namespace=bmi.get("bmh_namespace", bmh_namespace)
                )
        except Exception as error:  # Preserve parents if provider offboarding has not completed.
            cleanup_errors.append(f"BMI {bmi.get('id', '')}: {type(error).__name__}")
    if cleanup_errors:
        resources["cleanup_errors"] = cleanup_errors
        _write_private_json(_journal_path(), resources)
        raise RuntimeError("BMaaS teardown did not complete; preserving Subnet and VirtualNetwork")

    if resources.get("subnet_id") and resources["subnet_id"] in grpc.list_subnet_ids():
        subnet = grpc.get_subnet(subnet_id=resources["subnet_id"]).get("object", {})
        if subnet.get("metadata", {}).get("name") != resources.get("subnet_name"):
            raise RuntimeError("Subnet id no longer resolves to the recorded test-owned name")
        grpc.delete_subnet(subnet_id=resources["subnet_id"])
        wait_for_subnet_grpc_removal(grpc=grpc, uuid=resources["subnet_id"])
    if resources.get("security_group_id") and resources["security_group_id"] in grpc.list_security_group_ids():
        group = grpc.get_security_group(sg_id=resources["security_group_id"]).get("object", {})
        if group.get("metadata", {}).get("name") != resources.get("security_group_name"):
            raise RuntimeError("SecurityGroup id no longer resolves to the recorded test-owned name")
        grpc.delete_security_group(sg_id=resources["security_group_id"])
        wait_for_security_group_grpc_removal(grpc=grpc, uuid=resources["security_group_id"])
    if resources.get("virtual_network_id") and resources["virtual_network_id"] in grpc.list_virtual_network_ids():
        network = grpc.get_virtual_network(vn_id=resources["virtual_network_id"]).get("object", {})
        if network.get("metadata", {}).get("name") != resources.get("virtual_network_name"):
            raise RuntimeError("VirtualNetwork id no longer resolves to the recorded test-owned name")
        grpc.delete_virtual_network(vn_id=resources["virtual_network_id"])
        wait_for_virtual_network_grpc_removal(grpc=grpc, uuid=resources["virtual_network_id"])
    if resources.get("catalog_id"):
        grpc.delete_baremetal_instance_catalog_item(item_id=resources["catalog_id"])
    if resources.get("disk_image_id"):
        private_grpc.delete_disk_image(disk_image_id=resources["disk_image_id"], api=PRIVATE_API)
    if resources.get("instance_type_id"):
        private_grpc.delete_baremetal_instance_type(type_id=resources["instance_type_id"])
    if resources.get("ssh_key_name"):
        cli.delete_secret(name=resources["ssh_key_name"])
    resources["cleaned"] = True
    _write_private_json(_journal_path(), resources)


def test_cleanup_owned_agentless_bmaas(
    grpc: GRPCClient, private_grpc: GRPCClient, jwt_cli_admin: OsacCLI, k8s_hub_client: K8sClient, bmh_namespace: str
) -> None:
    if os.environ.get("OSAC_BMAAS_CLEANUP") != "true":
        pytest.skip("standalone BMaaS cleanup only")
    journal = _journal_path()
    if not journal.exists():
        return
    resources = json.loads(journal.read_text())
    if resources.get("cleaned") is True:
        return
    # The journal contains only IDs and test-owned names. Live deletion is
    # still guarded by the test prefix and tenant metadata before each request.
    if not str(resources.get("prefix", "")).startswith("agentless-bmaas-"):
        raise AssertionError("Refusing cleanup: resource journal is outside the AgentlessNet BMaaS prefix")
    # Use the normal BMI finalizer path first. If the current production flow
    # cannot offboard, retain all parent resources for diagnosis.
    _cleanup_run(
        grpc=grpc,
        private_grpc=private_grpc,
        cli=jwt_cli_admin,
        k8s=k8s_hub_client,
        bmh_namespace=bmh_namespace,
        resources=resources,
    )
