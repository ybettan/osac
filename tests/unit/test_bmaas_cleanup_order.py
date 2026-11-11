from __future__ import annotations

import pathlib
from typing import Any
from unittest.mock import Mock

import pytest

from tests.e2e.bmaas.agentless_net import test_agentless_net_networking as scenario
from tests.e2e.core.grpc_client import GRPCClient
from tests.e2e.core.k8s_client import K8sClient
from tests.e2e.core.osac_cli import OsacCLI


def _recorder(events: list[str], name: str):
    return lambda **kwargs: events.append(f"{name}:{kwargs['uuid']}")


def test_cleanup_waits_for_each_network_record_before_the_next_delete(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    prefix = "agentless-bmaas-test"
    events: list[str] = []
    grpc = Mock(spec=GRPCClient)
    grpc.list_baremetal_instance_ids.return_value = []
    grpc.list_subnet_ids.return_value = ["subnet-id"]
    grpc.list_security_group_ids.return_value = ["security-group-id"]
    grpc.list_virtual_network_ids.return_value = ["virtual-network-id"]
    grpc.get_subnet.return_value = {"object": {"metadata": {"name": f"{prefix}-subnet-a"}}}
    grpc.get_security_group.return_value = {"object": {"metadata": {"name": f"{prefix}-sg"}}}
    grpc.get_virtual_network.return_value = {"object": {"metadata": {"name": f"{prefix}-vn"}}}

    for method, label in (
        ("delete_subnet", "delete-subnet"),
        ("delete_security_group", "delete-security-group"),
        ("delete_virtual_network", "delete-virtual-network"),
    ):
        getattr(grpc, method).side_effect = lambda *args, _label=label, **kwargs: events.append(_label)

    for wait in (
        "wait_for_subnet_grpc_removal",
        "wait_for_security_group_grpc_removal",
        "wait_for_virtual_network_grpc_removal",
    ):
        monkeypatch.setattr(scenario, wait, _recorder(events, wait))

    monkeypatch.setattr(scenario, "_write_private_json", lambda path, value: None)
    monkeypatch.setattr(scenario, "_journal_path", lambda: pathlib.Path("/tmp/journal.json"))

    resources: dict[str, Any] = {
        "prefix": prefix,
        "bmis": [],
        "subnet_id": "subnet-id",
        "subnet_name": f"{prefix}-subnet-a",
        "security_group_id": "security-group-id",
        "security_group_name": f"{prefix}-sg",
        "virtual_network_id": "virtual-network-id",
        "virtual_network_name": f"{prefix}-vn",
    }

    scenario._cleanup_run(
        grpc=grpc,
        private_grpc=Mock(spec=GRPCClient),
        cli=Mock(spec=OsacCLI),
        k8s=Mock(spec=K8sClient),
        bmh_namespace="host-inventory",
        resources=resources,
    )

    assert events == [
        "delete-subnet",
        "wait_for_subnet_grpc_removal:subnet-id",
        "delete-security-group",
        "wait_for_security_group_grpc_removal:security-group-id",
        "delete-virtual-network",
        "wait_for_virtual_network_grpc_removal:virtual-network-id",
    ]
    assert resources["cleaned"] is True


def test_cleanup_refuses_a_record_whose_name_left_the_test_prefix(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    grpc = Mock(spec=GRPCClient)
    grpc.list_baremetal_instance_ids.return_value = []
    grpc.list_subnet_ids.return_value = ["subnet-id"]
    grpc.get_subnet.return_value = {"object": {"metadata": {"name": "another-tenant-subnet"}}}
    monkeypatch.setattr(scenario, "_write_private_json", lambda path, value: None)
    monkeypatch.setattr(scenario, "_journal_path", lambda: pathlib.Path("/tmp/journal.json"))

    with pytest.raises(RuntimeError, match="no longer resolves"):
        scenario._cleanup_run(
            grpc=grpc,
            private_grpc=Mock(spec=GRPCClient),
            cli=Mock(spec=OsacCLI),
            k8s=Mock(spec=K8sClient),
            bmh_namespace="host-inventory",
            resources={
                "prefix": "agentless-bmaas-test",
                "bmis": [],
                "subnet_id": "subnet-id",
                "subnet_name": "agentless-bmaas-test-subnet-a",
            },
        )

    grpc.delete_subnet.assert_not_called()
