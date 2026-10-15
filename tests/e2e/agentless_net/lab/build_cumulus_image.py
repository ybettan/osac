#!/usr/bin/env python3
"""Package a supplied Cumulus VX disk as a Boxen image for Containerlab."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

try:
    import yaml
except ImportError as error:  # pragma: no cover - exercised by the CLI
    raise SystemExit("PyYAML is required; install it with the OSAC e2e Python environment") from error


BOXEN_VERSION = "0.3.0"
BOXEN_SOURCE_TAG = "v0.3.0"
BOXEN_SOURCE_URL = (
    "https://github.com/carlmontanari/boxen/archive/refs/tags/v0.3.0.tar.gz"
)
BOXEN_SOURCE_SHA256 = "0c6feefe294c2e8e10de3478316caebd0dcb4d495b6957df84cb7fa811557b8d"
DEFAULT_BUILDER_IMAGE = "ghcr.io/carlmontanari/boxen:0.3.0"
GO_VERSION = "1.27.1"
PROFILE_FILES = (
    "nvidia_cumulusvx_breakout.star",
    "nvidia_cumulusvx_breakout.sh.tmpl",
)
SUDOERS_PATH = "/etc/sudoers.d/osac-cumulus-lab-bootstrap"
SUDOERS_CONTENT = "cumulus ALL=(ALL) NOPASSWD: ALL"
VERSION_RE = re.compile(r"^5\.\d+\.\d+$")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_boxen_source(source_archive: Path | None) -> tuple[bytes, str]:
    if source_archive:
        archive = source_archive.read_bytes()
    else:
        with urllib.request.urlopen(BOXEN_SOURCE_URL, timeout=60) as response:
            archive = response.read()
    digest = sha256_bytes(archive)
    if digest != BOXEN_SOURCE_SHA256:
        raise ValueError(
            f"Boxen {BOXEN_SOURCE_TAG} source archive checksum mismatch: {digest}"
        )
    return archive, digest


def read_member(archive: tarfile.TarFile, suffix: str) -> bytes:
    matches = [
        member
        for member in archive.getmembers()
        if member.isfile() and member.name.endswith(suffix)
    ]
    if len(matches) != 1:
        raise ValueError(f"Expected one Boxen source member ending in {suffix!r}")
    stream = archive.extractfile(matches[0])
    if stream is None:
        raise ValueError(f"Could not read Boxen source member {matches[0].name}")
    return stream.read()


def extract_source_tree(source_archive: bytes, destination: Path) -> Path:
    with tarfile.open(fileobj=io.BytesIO(source_archive), mode="r:gz") as archive:
        members = archive.getmembers()
        roots = {Path(member.name).parts[0] for member in members if Path(member.name).parts}
        if len(roots) != 1:
            raise ValueError("Pinned Boxen source archive has an unexpected directory layout")
        root_name = roots.pop()
        root = destination / root_name
        root.mkdir(parents=True)
        destination_resolved = destination.resolve()
        for member in members:
            target = (destination / member.name).resolve()
            if target != destination_resolved and destination_resolved not in target.parents:
                raise ValueError("Boxen source archive contains a path outside its extraction directory")
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                stream = archive.extractfile(member)
                if stream is None:
                    raise ValueError(f"Could not extract Boxen source member {member.name}")
                target.write_bytes(stream.read())
                target.chmod(member.mode & 0o777)
            else:
                raise ValueError(f"Unsupported Boxen source archive entry: {member.name}")
    return root


def ensure_builder_image(source_archive: bytes, image: str) -> tuple[str, str]:
    image_id_result = subprocess.run(
        ["docker", "image", "inspect", "--format", "{{.Id}}", image],
        capture_output=True,
        text=True,
    )
    image_id = image_id_result.stdout.strip() if image_id_result.returncode == 0 else ""
    if image_id:
        version_result = subprocess.run(
            ["docker", "run", "--rm", "--entrypoint", "/boxen/boxen", image, "--version"],
            capture_output=True,
            text=True,
        )
        if version_result.returncode == 0 and BOXEN_VERSION in version_result.stdout:
            return image_id, version_result.stdout.strip()

    with tempfile.TemporaryDirectory(prefix="osac-boxen-source-") as temp_dir:
        source_root = extract_source_tree(source_archive, Path(temp_dir))
        dockerfile = source_root / "build" / "agent.Dockerfile"
        dockerfile_text = dockerfile.read_text()
        old_copy = "RUN cp /root/.cache/scrapli/libscrapli.so.* /root/.cache/scrapli/libscrapli.so"
        new_copy = "RUN cp /root/.cache/scrapli/libscrapli-*.so.* /root/.cache/scrapli/libscrapli.so"
        if dockerfile_text.count(old_copy) != 1:
            raise ValueError("Pinned Boxen builder Dockerfile no longer has the expected libscrapli copy line")
        dockerfile.write_text(dockerfile_text.replace(old_copy, new_copy))
        subprocess.run(
            [
                "docker",
                "build",
                "--build-arg",
                f"GO_VERSION={GO_VERSION}",
                "--build-arg",
                f"VERSION={BOXEN_VERSION}",
                "-f",
                str(dockerfile),
                "-t",
                image,
                str(source_root),
            ],
            check=True,
        )
    image_id = run_checked(["docker", "image", "inspect", "--format", "{{.Id}}", image])
    version = run_checked(
        ["docker", "run", "--rm", "--entrypoint", "/boxen/boxen", image, "--version"]
    )
    if BOXEN_VERSION not in version:
        raise ValueError(f"Built Boxen agent version does not match CLI {BOXEN_VERSION}: {version!r}")
    return image_id, version


def sudo_baseline_steps(password: str) -> list[dict[str, object]]:
    bootstrap_command = (
        "sudo -S sh -c 'printf \"%s\\n\" \"# OSAC Cumulus lab baseline\" "
        f"\"{SUDOERS_CONTENT}\" > {SUDOERS_PATH} && "
        f"chmod 0440 {SUDOERS_PATH} && visudo -cf {SUDOERS_PATH} && "
        f"grep -Fqx \"{SUDOERS_CONTENT}\" {SUDOERS_PATH}' "
        "&& printf 'BOXEN_' && printf 'SUDOERS_OK\\n'"
    )
    return [
        {"type": "write", "write": {"content": bootstrap_command + "\n"}},
        {
            "type": "prompts",
            "prompts": {
                "timeout": "2m",
                "initialInput": "\r",
                "prompts": [
                    {
                        "name": "install OSAC lab sudo baseline",
                        "prompt": {"contains": "[sudo] password for cumulus"},
                        "response": password,
                        "hidden": True,
                        "once": True,
                    },
                    {
                        "name": "finish OSAC lab sudo baseline",
                        "prompt": {"contains": "BOXEN_SUDOERS_OK"},
                        "response": "",
                        "hidden": True,
                        "once": True,
                        "completes": True,
                    },
                ],
            },
        },
    ]


def adapt_profile(source: str) -> tuple[str, int]:
    profile = yaml.safe_load(source)
    if not isinstance(profile, dict) or profile.get("name") != "nvidia_cumulusvx":
        raise ValueError("Pinned Boxen source does not contain the expected Cumulus VX profile")

    removed_ipv6 = 0
    for step in profile.get("run", {}).get("process", []):
        content = step.get("write", {}).get("content")
        if not isinstance(content, str):
            continue
        lines = content.splitlines()
        kept = [line for line in lines if "ipv6" not in line.lower()]
        removed_ipv6 += len(lines) - len(kept)
        if len(kept) != len(lines):
            step["write"]["content"] = "\n".join(kept) + "\n"
    if removed_ipv6 != 5:
        raise ValueError(
            "Expected the pinned profile's five optional IPv6 management commands; "
            f"removed {removed_ipv6}"
        )

    packaging_steps = profile.get("packaging", {}).get("process", [])
    prompt_index = next(
        (index for index, step in enumerate(packaging_steps) if step.get("type") == "prompts"),
        None,
    )
    if prompt_index is None:
        raise ValueError("Pinned Cumulus profile has no first-boot credential prompt step")

    first_boot_prompts = packaging_steps[prompt_index].get("prompts", {}).get("prompts", [])
    sudo_password = next(
        (
            prompt.get("response")
            for prompt in first_boot_prompts
            if prompt.get("name") == "confirm ztp disable"
        ),
        None,
    )
    if not isinstance(sudo_password, str) or not sudo_password:
        raise ValueError("Pinned Cumulus profile has no hidden ZTP sudo credential to reuse")

    packaging_steps.extend(sudo_baseline_steps(sudo_password))

    run_prompts = next(
        (
            step.get("prompts", {}).get("prompts", [])
            for step in profile.get("run", {}).get("process", [])
            if step.get("type") == "prompts"
        ),
        [],
    )
    run_password = next(
        (prompt.get("response") for prompt in run_prompts if prompt.get("name") == "enter password"),
        None,
    )
    if not isinstance(run_password, str) or not run_password:
        raise ValueError("Pinned Cumulus profile has no hidden runtime login credential to reuse")
    config_steps = profile.get("run", {}).get("configProcess")
    if not isinstance(config_steps, list):
        raise ValueError("Pinned Cumulus profile has no startup-config processing sequence")
    config_steps.extend(sudo_baseline_steps(run_password))
    return yaml.safe_dump(profile, sort_keys=False), removed_ipv6


def run_checked(args: list[str], *, env: dict[str, str] | None = None) -> str:
    try:
        result = subprocess.run(args, check=True, capture_output=True, text=True, env=env)
    except subprocess.CalledProcessError as error:
        details = (error.stderr or error.stdout or "").strip()
        suffix = f": {details}" if details else ""
        raise RuntimeError(f"Command failed with exit code {error.returncode}{suffix}") from error
    return result.stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--disk", type=Path, required=True, help="Cumulus VX qcow2 supplied by the user")
    parser.add_argument("--version", required=True, help="Exact guest release, for example 5.16.5")
    parser.add_argument("--boxen", default="boxen", help="Path to the pinned Boxen CLI")
    parser.add_argument("--builder-image", default=os.environ.get("BOXEN_BUILDER_IMAGE", DEFAULT_BUILDER_IMAGE))
    parser.add_argument("--source-archive", type=Path, help="Verified Boxen v0.3.0 source archive")
    parser.add_argument("--artifact-dir", type=Path, help="Output directory (must not already exist)")
    args = parser.parse_args()

    if not VERSION_RE.fullmatch(args.version):
        parser.error("--version must be an exact Cumulus 5.x.y release, not a wildcard or alias")
    disk = args.disk.resolve()
    if not disk.is_file():
        parser.error(f"Cumulus disk does not exist: {disk}")
    if not shutil.which(args.boxen) and not Path(args.boxen).is_file():
        parser.error(f"Boxen CLI was not found: {args.boxen}")

    repo_root = Path(__file__).resolve().parents[4]
    artifact_dir = args.artifact_dir
    if artifact_dir is None:
        artifact_dir = repo_root / ".artifacts" / "agentless-net-lab" / f"boxen-{BOXEN_VERSION}-{args.version}-build"
    artifact_dir = artifact_dir.resolve()
    if artifact_dir.exists():
        parser.error(f"Artifact directory already exists; refusing to overwrite it: {artifact_dir}")
    artifact_dir.mkdir(parents=True, mode=0o700)

    try:
        source_archive, source_digest = read_boxen_source(args.source_archive)
        with tarfile.open(fileobj=io.BytesIO(source_archive), mode="r:gz") as archive:
            profile_source = read_member(archive, "assets/profiles/nvidia_cumulusvx.yaml").decode()
            companions = {
                name: read_member(archive, f"assets/profiles/{name}") for name in PROFILE_FILES
            }
        adapted_profile, removed_ipv6 = adapt_profile(profile_source)
        profile_path = artifact_dir / "nvidia_cumulusvx.yaml"
        profile_path.write_text(adapted_profile)
        for name, content in companions.items():
            (artifact_dir / name).write_bytes(content)

        version_match = re.search(r"(?i)\d+\.\d+\.\d+", disk.name)
        if not version_match or version_match.group(0) != args.version:
            raise ValueError(
                f"Disk filename must contain the requested exact release {args.version}: {disk.name}"
            )
        builder_image_id, builder_version = ensure_builder_image(source_archive, args.builder_image)
        cli_version = run_checked([args.boxen, "--version"])
        if BOXEN_VERSION not in cli_version:
            raise ValueError(f"Expected Boxen CLI {BOXEN_VERSION}; got {cli_version!r}")

        env = os.environ.copy()
        env["BOXEN_BUILDER_IMAGE"] = args.builder_image
        subprocess.run(
            [
                args.boxen,
                "build",
                "--disk",
                str(disk),
                "--profile",
                str(profile_path),
                "--tag",
                args.version,
            ],
            check=True,
            env=env,
        )
        image_ref = f"boxen-nvidia_cumulusvx:{args.version}"
        image_id = run_checked(
            ["docker", "image", "inspect", "--format", "{{.Id}}", image_ref]
        )
        manifest = {
            "built_at_utc": datetime.now(timezone.utc).isoformat(),
            "cumulus_version": args.version,
            "disk": {
                "basename": disk.name,
                "size_bytes": disk.stat().st_size,
                "sha256": sha256_file(disk),
            },
            "boxen": {
                "cli_version": cli_version,
                "source_tag": BOXEN_SOURCE_TAG,
                "source_archive_sha256": source_digest,
                "builder_image": args.builder_image,
                "builder_image_id": builder_image_id,
                "builder_version": builder_version,
            },
            "profile": {
                "sha256": sha256_bytes(adapted_profile.encode()),
                "ipv6_management_commands_removed": removed_ipv6,
                "sudoers_baseline": SUDOERS_PATH,
            },
            "docker_image": {"reference": image_ref, "image_id": image_id},
        }
        (artifact_dir / "provenance.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(f"Built {image_ref} ({image_id})")
        print(f"Provenance: {artifact_dir / 'provenance.json'}")
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError, tarfile.TarError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
