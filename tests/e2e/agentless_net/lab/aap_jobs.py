#!/usr/bin/env python3
"""Launch and verify an AgentlessNet AAP job for the VLAN lab."""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import pathlib
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


class AAPError(Exception):
    """An AAP launch or validation step failed."""


class Controller:
    def __init__(self) -> None:
        route = os.environ.get("AAP_API_ROUTE", "").rstrip("/")
        token = os.environ.get("AAP_API_TOKEN", "")
        ca_file = os.environ.get("AAP_API_CA_FILE", "")
        if not route or not token or not ca_file or not pathlib.Path(ca_file).is_file():
            raise AAPError("AAP route, API token, or CA bundle is unavailable")
        self.base = route + "/api/controller/v2"
        self.token = token
        try:
            self.context = ssl.create_default_context(cafile=ca_file)
        except (OSError, ssl.SSLError) as error:
            raise AAPError("AAP CA bundle could not be loaded") from error

    def request(
        self,
        endpoint: str,
        *,
        body: dict[str, Any] | None = None,
        method: str | None = None,
    ) -> dict[str, Any]:
        url = endpoint if endpoint.startswith("https://") else self.base + endpoint
        data = None if body is None else json.dumps(body).encode("utf-8")
        headers = {"Authorization": f"Bearer {self.token}"}
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, context=self.context, timeout=20) as response:
                payload = response.read()
        except (urllib.error.URLError, TimeoutError) as error:
            raise AAPError("AAP Controller request failed") from error
        try:
            value = json.loads(payload) if payload else {}
        except json.JSONDecodeError as error:
            raise AAPError("AAP Controller returned invalid JSON") from error
        if not isinstance(value, dict):
            raise AAPError("AAP Controller returned an unexpected response")
        return value

    def list_named_items(self, endpoint: str, name: str) -> list[dict[str, Any]]:
        url = self.base + endpoint + "?page_size=200"
        matches: list[dict[str, Any]] = []
        while url:
            result = self.request(url)
            results = result.get("results", [])
            if not isinstance(results, list):
                raise AAPError(f"AAP returned invalid results for {endpoint}")
            matches.extend(item for item in results if isinstance(item, dict) and item.get("name") == name)
            next_url = result.get("next")
            url = urllib.parse.urljoin(self.base + "/", next_url) if next_url else ""
        return matches

    def list_named(self, endpoint: str, name: str) -> dict[str, Any]:
        matches = self.list_named_items(endpoint, name)
        if len(matches) != 1:
            raise AAPError(f"AAP must contain exactly one {endpoint} named {name}")
        return matches[0]


K8S_CREDENTIAL_INPUTS: dict[str, Any] = {
    "fields": [
        {"id": "api_host", "label": "Kubernetes API host", "type": "string"},
        {"id": "api_token", "label": "Kubernetes API token", "type": "string", "secret": True},
        {
            "id": "ca_bundle",
            "label": "Kubernetes API CA bundle",
            "type": "string",
            "secret": True,
            "multiline": True,
        },
    ],
    "required": ["api_host", "api_token", "ca_bundle"],
}
K8S_CREDENTIAL_TYPE_DESCRIPTION = "OSAC VLAN E2E Kubernetes API access."
K8S_CREDENTIAL_DESCRIPTION = "Temporary Subnet and V-Net lock access for vlan-e2e.sh."
K8S_CREDENTIAL_LEGACY_DESCRIPTION = "Temporary read-only Subnet access for vlan-e2e.sh."
K8S_CREDENTIAL_INJECTORS: dict[str, Any] = {
    "env": {
        "K8S_AUTH_HOST": "{{ api_host }}",
        "K8S_AUTH_API_KEY": "{{ api_token }}",
        "K8S_AUTH_SSL_CA_CERT": "{{ tower.filename.ca_bundle }}",
        "K8S_AUTH_VERIFY_SSL": "true",
    },
    "file": {"template.ca_bundle": "{{ ca_bundle }}"},
}


def configure_k8s_credential(args: argparse.Namespace) -> dict[str, Any]:
    try:
        api_token = pathlib.Path(args.token_file).read_text(encoding="utf-8").strip()
        ca_bundle = pathlib.Path(args.ca_file).read_text(encoding="utf-8").strip()
    except OSError as error:
        raise AAPError("Could not read the temporary Kubernetes credential files") from error
    if not api_token or not ca_bundle:
        raise AAPError("Temporary Kubernetes token and CA bundle must be non-empty")
    if not args.api_host.startswith("https://"):
        raise AAPError("Kubernetes API host must use HTTPS")

    controller = Controller()
    template_ref = controller.list_named("/job_templates/", args.job_template)
    template_id = template_ref.get("id")
    template = controller.request(f"/job_templates/{template_id}/")
    organization_id = template.get("organization")
    if not isinstance(template_id, int) or not isinstance(organization_id, int):
        raise AAPError(f"AAP job template {args.job_template} has no organization")

    credential_types = controller.list_named_items("/credential_types/", args.credential_type_name)
    if len(credential_types) > 1:
        raise AAPError("AAP has duplicate OSAC Kubernetes credential types")
    credential_type_created = not credential_types
    if credential_type_created:
        credential_type = controller.request(
            "/credential_types/",
            body={
                "name": args.credential_type_name,
                "description": K8S_CREDENTIAL_TYPE_DESCRIPTION,
                "kind": "cloud",
                "inputs": K8S_CREDENTIAL_INPUTS,
                "injectors": K8S_CREDENTIAL_INJECTORS,
            },
        )
        credential_type_id = credential_type.get("id")
    else:
        credential_type_id = credential_types[0].get("id")
        credential_type = controller.request(f"/credential_types/{credential_type_id}/")
        if (
            credential_type.get("kind") != "cloud"
            or credential_type.get("description") != K8S_CREDENTIAL_TYPE_DESCRIPTION
            or credential_type.get("inputs") != K8S_CREDENTIAL_INPUTS
            or credential_type.get("injectors") != K8S_CREDENTIAL_INJECTORS
        ):
            raise AAPError("Existing OSAC Kubernetes credential type has an unexpected definition")
    if not isinstance(credential_type_id, int):
        raise AAPError("AAP did not return a Kubernetes credential type ID")

    credential_matches = controller.list_named_items("/credentials/", args.credential_name)
    if len(credential_matches) > 1:
        raise AAPError("AAP has duplicate OSAC VLAN E2E Kubernetes credentials")
    credential_body = {
        "name": args.credential_name,
        "description": K8S_CREDENTIAL_DESCRIPTION,
        "credential_type": credential_type_id,
        "organization": organization_id,
        "inputs": {
            "api_host": args.api_host,
            "api_token": api_token,
            "ca_bundle": ca_bundle,
        },
    }
    credential_created = not credential_matches
    if credential_created:
        credential = controller.request("/credentials/", body=credential_body)
        credential_id = credential.get("id")
    else:
        credential_id = credential_matches[0].get("id")
        existing = controller.request(f"/credentials/{credential_id}/")
        if (
            existing.get("credential_type") != credential_type_id
            or existing.get("organization") != organization_id
        ):
            raise AAPError("Existing OSAC VLAN E2E credential has an unexpected owner or type")
        controller.request(f"/credentials/{credential_id}/", body=credential_body, method="PUT")
    if not isinstance(credential_id, int):
        raise AAPError("AAP did not return a Kubernetes credential ID")

    relation = f"/job_templates/{template_id}/credentials/"
    associated = controller.request(relation)
    associated_ids = {item.get("id") for item in associated.get("results", []) if isinstance(item, dict)}
    if credential_id not in associated_ids:
        controller.request(relation, body={"id": credential_id})

    return {
        "template_id": template_id,
        "credential_id": credential_id,
        "credential_type_id": credential_type_id,
        "credential_created": credential_created,
        "credential_type_created": credential_type_created,
    }


def cleanup_k8s_credential(args: argparse.Namespace) -> dict[str, Any]:
    controller = Controller()
    template_ref = controller.list_named("/job_templates/", args.job_template)
    template_id = template_ref.get("id")
    if not isinstance(template_id, int):
        raise AAPError(f"AAP job template {args.job_template} has no ID")
    matches = controller.list_named_items("/credentials/", args.credential_name)
    if not matches:
        return {"template_id": template_id, "status": "already-removed"}
    if len(matches) != 1:
        raise AAPError("AAP has duplicate OSAC VLAN E2E Kubernetes credentials")
    credential_id = matches[0].get("id")
    if not isinstance(credential_id, int):
        raise AAPError("AAP Kubernetes credential has no ID")
    credential = controller.request(f"/credentials/{credential_id}/")
    if (
        credential.get("name") != args.credential_name
        or credential.get("description")
        not in {K8S_CREDENTIAL_DESCRIPTION, K8S_CREDENTIAL_LEGACY_DESCRIPTION}
    ):
        raise AAPError("Refusing to remove an unexpected AAP Kubernetes credential")
    credential_type_id = credential.get("credential_type")
    credential_type = controller.request(f"/credential_types/{credential_type_id}/")
    if (
        credential_type.get("name") != args.credential_type_name
        or credential_type.get("description") != K8S_CREDENTIAL_TYPE_DESCRIPTION
    ):
        raise AAPError("Refusing to remove an unexpected AAP Kubernetes credential type")

    relation = f"/job_templates/{template_id}/credentials/"
    associated = controller.request(relation)
    associated_ids = {item.get("id") for item in associated.get("results", []) if isinstance(item, dict)}
    if credential_id in associated_ids:
        controller.request(relation, body={"id": credential_id, "disassociate": True})
    controller.request(f"/credentials/{credential_id}/", method="DELETE")
    return {"template_id": template_id, "credential_id": credential_id, "status": "removed"}


def launch(args: argparse.Namespace) -> dict[str, Any]:
    try:
        extra_vars = json.loads(pathlib.Path(args.extra_vars).read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise AAPError("Could not read the AAP job extra-vars file") from error
    if not isinstance(extra_vars, dict):
        raise AAPError("AAP job extra-vars must be a JSON object")
    if args.timeout <= 0:
        raise AAPError("AAP job timeout must be positive")
    if len(args.project_revision) != 40 or any(
        character not in "0123456789abcdef" for character in args.project_revision
    ):
        raise AAPError("AAP expected project revision must be a full lowercase Git SHA")

    controller = Controller()
    template_ref = controller.list_named("/job_templates/", args.job_template)
    template = controller.request(f"/job_templates/{template_ref['id']}/")
    project_id = template.get("project")
    ee_id = template.get("execution_environment")
    if not isinstance(project_id, int) or not isinstance(ee_id, int):
        raise AAPError(f"AAP job template {args.job_template} lacks a project or execution environment")
    project = controller.request(f"/projects/{project_id}/")
    environment = controller.request(f"/execution_environments/{ee_id}/")
    if project.get("name") != args.project_name:
        raise AAPError(f"AAP job template {args.job_template} uses an unexpected project")
    if project.get("scm_revision") != args.project_revision:
        raise AAPError(f"AAP project is not synchronized to the expected source revision for {args.job_template}")
    if environment.get("name") != args.ee_name or environment.get("image") != args.ee_image:
        raise AAPError(f"AAP job template {args.job_template} uses an unexpected execution environment")

    launched = controller.request(
        f"/job_templates/{template_ref['id']}/launch/",
        body={"extra_vars": json.dumps(extra_vars, separators=(",", ":"))},
    )
    job_id = launched.get("job") or launched.get("id")
    if not isinstance(job_id, int):
        raise AAPError(f"AAP did not return a job ID for {args.job_template}")

    deadline = time.monotonic() + args.timeout
    terminal = {"successful", "failed", "error", "canceled"}
    job: dict[str, Any] = {}
    while time.monotonic() < deadline:
        job = controller.request(f"/jobs/{job_id}/")
        if job.get("status") in terminal:
            break
        time.sleep(5)
    else:
        with contextlib.suppress(AAPError):
            controller.request(f"/jobs/{job_id}/cancel/", body={})
        cancel_deadline = time.monotonic() + 120
        while time.monotonic() < cancel_deadline:
            job = controller.request(f"/jobs/{job_id}/")
            if job.get("status") in terminal:
                break
            time.sleep(2)
        raise AAPError(f"AAP job {job_id} timed out and was canceled")

    if job.get("status") != "successful":
        raise AAPError(f"AAP job {job_id} ended with status {job.get('status', 'unknown')}")
    job_revision = job.get("scm_revision")
    if job_revision != args.project_revision:
        raise AAPError(f"AAP job {job_id} did not use the expected source revision")
    artifacts = job.get("artifacts")
    if artifacts is None:
        artifacts = {}
    if not isinstance(artifacts, dict):
        raise AAPError(f"AAP job {job_id} returned malformed artifacts")
    return {
        "job_id": job_id,
        "job_template": args.job_template,
        "status": job["status"],
        "project": args.project_name,
        "project_revision": job_revision,
        "execution_environment": args.ee_name,
        "execution_environment_image": environment["image"],
        "artifacts": artifacts,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    launch_parser = subparsers.add_parser("launch")
    launch_parser.add_argument("--job-template", required=True)
    launch_parser.add_argument("--extra-vars", required=True)
    launch_parser.add_argument("--output", required=True)
    launch_parser.add_argument("--project-name", required=True)
    launch_parser.add_argument("--project-revision", required=True)
    launch_parser.add_argument("--ee-name", required=True)
    launch_parser.add_argument("--ee-image", required=True)
    launch_parser.add_argument("--timeout", type=int, default=1200)
    configure_parser = subparsers.add_parser("configure-k8s-credential")
    configure_parser.add_argument("--job-template", required=True)
    configure_parser.add_argument("--credential-name", required=True)
    configure_parser.add_argument("--credential-type-name", required=True)
    configure_parser.add_argument("--api-host", required=True)
    configure_parser.add_argument("--token-file", required=True)
    configure_parser.add_argument("--ca-file", required=True)
    cleanup_parser = subparsers.add_parser("cleanup-k8s-credential")
    cleanup_parser.add_argument("--job-template", required=True)
    cleanup_parser.add_argument("--credential-name", required=True)
    cleanup_parser.add_argument("--credential-type-name", required=True)
    args = parser.parse_args()

    try:
        if args.command == "launch":
            result = launch(args)
            output = pathlib.Path(args.output)
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
            try:
                output_fd = os.open(output, flags, 0o600)
            except OSError as error:
                raise AAPError("Could not create the private AAP job result file") from error
            with os.fdopen(output_fd, "w", encoding="utf-8") as stream:
                stream.write(json.dumps(result, indent=2) + "\n")
            print(json.dumps({key: value for key, value in result.items() if key != "artifacts"}))
        elif args.command == "configure-k8s-credential":
            print(json.dumps(configure_k8s_credential(args)))
        else:
            print(json.dumps(cleanup_k8s_credential(args)))
    except AAPError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
