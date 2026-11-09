"""Exercise parity-gate cleanup through its entrypoint without a live cluster."""

import os
from pathlib import Path
import subprocess

import pytest


SCRIPT = Path(__file__).parent / "integration" / "parity-gate.sh"


@pytest.mark.parametrize(
    "existing,keep,free_kb,create_status,expected_calls,message",
    [
        ("parity", "0", "20000000", "0", ["get clusters"], "already exists"),
        ("parity", "1", "20000000", "0", ["get clusters"], "already exists"),
        ("parity", "0", "1000000", "0", [], "need 6"),
        ("", "0", "20000000", "0", [
            "get clusters", "create cluster --name parity --wait 120s",
            "delete cluster --name parity",
        ], "cannot create namespace"),
        ("", "1", "20000000", "0", [
            "get clusters", "create cluster --name parity --wait 120s",
        ], "cannot create namespace"),
        ("", "0", "20000000", "1", [
            "get clusters", "create cluster --name parity --wait 120s",
        ], "### 1. kind cluster"),
    ],
    ids=["existing", "existing-kept", "low-disk", "created", "created-kept", "create-failed"],
)
def test_cleanup_only_deletes_owned_cluster(
    tmp_path, existing, keep, free_kb, create_status, expected_calls, message
):
    calls = tmp_path / "kind.calls"
    calls.touch()
    stubs = {
        "kind": '''printf '%s\\n' "$*" >> "$KIND_CALLS"
case "$*" in
    'get clusters') printf '%s\\n' "$EXISTING_CLUSTER" ;;
    'create cluster --name parity --wait 120s') exit "$CREATE_STATUS" ;;
esac
''',
        "df": '''printf 'Filesystem 1024-blocks Used Available Capacity Mounted\\n'
printf 'fixture 20000000 0 %s 0%% /\\n' "$FREE_KB"
''',
        # Stop immediately after creation to exercise cleanup on a later failure.
        "kubectl": "exit 1\n",
        "helm": "exit 1\n",
        "docker": "exit 1\n",
        "perl": "exit 1\n",
    }
    for name, body in stubs.items():
        stub = tmp_path / name
        stub.write_text("#!/bin/bash\n" + body)
        stub.chmod(0o755)
    env = dict(
        os.environ,
        PATH=f"{tmp_path}:{os.environ['PATH']}",
        TMPDIR=str(tmp_path),
        KIND_CALLS=str(calls),
        EXISTING_CLUSTER=existing,
        KEEP_CLUSTER=keep,
        FREE_KB=free_kb,
        CREATE_STATUS=create_status,
    )
    result = subprocess.run(
        ["bash", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=10
    )
    assert result.returncode == 2, result.stdout + result.stderr
    assert message in result.stdout
    assert calls.read_text().splitlines() == expected_calls
