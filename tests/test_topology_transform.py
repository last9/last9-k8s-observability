"""Behavioral test for the transform/topology OTTL processor.

Extracts the transform/topology processor verbatim from
last9-kube-events-agent-values.yaml, runs it in a real
otelcol-contrib container (OTLP HTTP in -> transform -> file out),
sends synthetic k8sobjects *pull-mode* payloads (the object IS the
log body, no "object" wrapper), and asserts topology attributes are
extracted.

Regression test for the pull-vs-watch body shape bug where every
statement read body["object"][...] and silently no-op'd.

Requires docker. Skipped if docker is unavailable.
"""

import json
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
VALUES_FILE = REPO_ROOT / "last9-kube-events-agent-values.yaml"
COLLECTOR_IMAGE = "otel/opentelemetry-collector-contrib:0.126.0"
OTLP_PORT = 24318
CONTAINER_NAME = "topology-transform-test"

docker = shutil.which("docker")
pytestmark = pytest.mark.skipif(docker is None, reason="docker not available")


# ---------------------------------------------------------------------------
# OTLP JSON helpers: convert a plain dict/list/str/int into OTLP AnyValue
# ---------------------------------------------------------------------------

def to_any_value(v):
    if isinstance(v, dict):
        return {"kvlistValue": {"values": [
            {"key": k, "value": to_any_value(val)} for k, val in v.items()
        ]}}
    if isinstance(v, list):
        return {"arrayValue": {"values": [to_any_value(i) for i in v]}}
    if isinstance(v, bool):
        return {"boolValue": v}
    if isinstance(v, int):
        return {"intValue": str(v)}
    return {"stringValue": str(v)}


def otlp_log_payload(bodies):
    """Build an OTLP/HTTP JSON logs payload; each body is one log record."""
    return json.dumps({
        "resourceLogs": [{
            "resource": {"attributes": []},
            "scopeLogs": [{
                "logRecords": [
                    {"timeUnixNano": "0", "body": to_any_value(b)} for b in bodies
                ]
            }],
        }]
    }).encode()


# ---------------------------------------------------------------------------
# Synthetic pull-mode k8sobjects bodies (object at body root, no wrapper)
# ---------------------------------------------------------------------------

POD_BODY = {
    "kind": "Pod",
    "apiVersion": "v1",
    "metadata": {
        "name": "web-6d4b75cb6d-abcde",
        "namespace": "default",
        "uid": "pod-uid-123",
        "creationTimestamp": "2026-01-01T00:00:00Z",
        "labels": {"app": "web", "tier": "frontend"},
        "ownerReferences": [{
            "kind": "ReplicaSet",
            "name": "web-6d4b75cb6d",
            "uid": "rs-uid-456",
        }],
    },
    "spec": {"nodeName": "node-1", "serviceAccountName": "web-sa"},
    "status": {"phase": "Running"},
}

DEPLOYMENT_BODY = {
    "kind": "Deployment",
    "apiVersion": "apps/v1",
    "metadata": {
        "name": "web",
        "namespace": "default",
        "uid": "deploy-uid-789",
        "creationTimestamp": "2026-01-01T00:00:00Z",
    },
    "spec": {"replicas": 3},
    "status": {"availableReplicas": 3},
}


# ---------------------------------------------------------------------------
# Collector fixture
# ---------------------------------------------------------------------------

def extract_topology_processor():
    values = yaml.safe_load(VALUES_FILE.read_text())
    proc = values["config"]["processors"]["transform/topology"]
    assert proc, "transform/topology missing from values file"
    return proc


@pytest.fixture(scope="module")
def collector():
    workdir = Path(tempfile.mkdtemp(prefix="topology-test-"))
    outdir = workdir / "out"
    outdir.mkdir()
    outdir.chmod(0o777)  # collector container runs as uid 10001

    config = {
        "receivers": {"otlp": {"protocols": {"http": {"endpoint": "0.0.0.0:4318"}}}},
        "processors": {"transform/topology": extract_topology_processor()},
        "exporters": {"file": {"path": "/out/logs.json", "flush_interval": "100ms"}},
        "service": {
            "pipelines": {
                "logs": {
                    "receivers": ["otlp"],
                    "processors": ["transform/topology"],
                    "exporters": ["file"],
                }
            }
        },
    }
    config_path = workdir / "config.yaml"
    config_path.write_text(yaml.safe_dump(config))

    subprocess.run([docker, "rm", "-f", CONTAINER_NAME],
                   capture_output=True, check=False)
    subprocess.run(
        [docker, "run", "-d", "--name", CONTAINER_NAME,
         "-p", f"{OTLP_PORT}:4318",
         "-v", f"{config_path}:/etc/otelcol/config.yaml",
         "-v", f"{outdir}:/out",
         COLLECTOR_IMAGE, "--config", "/etc/otelcol/config.yaml"],
        check=True, capture_output=True,
    )
    try:
        wait_for_collector_ready()
        yield outdir / "logs.json"
    finally:
        logs = subprocess.run([docker, "logs", CONTAINER_NAME],
                              capture_output=True, text=True, check=False)
        subprocess.run([docker, "rm", "-f", CONTAINER_NAME],
                       capture_output=True, check=False)
        shutil.rmtree(workdir, ignore_errors=True)
        # OTTL statement failures are warn-level, not fatal: surface them.
        assert "failed to execute statement" not in logs.stderr, (
            "transform/topology statements failed at runtime:\n" + logs.stderr
        )


def wait_for_collector_ready(timeout=30):
    deadline = time.time() + timeout
    last_err = None
    while time.time() < deadline:
        try:
            post_logs([])
            return
        except (urllib.error.URLError, ConnectionError) as e:
            last_err = e
            time.sleep(0.5)
    raise RuntimeError(f"collector not ready after {timeout}s: {last_err}")


def post_logs(bodies):
    req = urllib.request.Request(
        f"http://localhost:{OTLP_PORT}/v1/logs",
        data=otlp_log_payload(bodies),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        assert resp.status == 200


def read_records(outfile, expected_count, timeout=15):
    """Poll the file exporter output until expected_count records appear.

    Telemetry is flushed asynchronously -- never assume instant writes.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        records = []
        if outfile.exists():
            for line in outfile.read_text().splitlines():
                payload = json.loads(line)
                for rl in payload.get("resourceLogs", []):
                    res_attrs = {
                        a["key"]: a["value"].get("stringValue")
                        for a in rl.get("resource", {}).get("attributes", [])
                    }
                    for sl in rl.get("scopeLogs", []):
                        for lr in sl.get("logRecords", []):
                            attrs = {
                                a["key"]: list(a["value"].values())[0]
                                for a in lr.get("attributes", [])
                            }
                            records.append({
                                "resource": res_attrs,
                                "attributes": attrs,
                                "timeUnixNano": lr.get("timeUnixNano", "0"),
                            })
        if len(records) >= expected_count:
            return records
        time.sleep(0.5)
    raise AssertionError(
        f"expected {expected_count} records within {timeout}s, "
        f"got {len(records) if outfile.exists() else 'no output file'}"
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_pull_mode_pod_attributes_extracted(collector):
    post_logs([POD_BODY, DEPLOYMENT_BODY])
    records = read_records(collector, expected_count=2)

    pod = next(r for r in records
               if r["attributes"].get("k8s.resource.kind") == "Pod")
    deploy = next(r for r in records
                  if r["attributes"].get("k8s.resource.kind") == "Deployment")

    # Resource-level identity
    assert pod["resource"]["service.name"] == "k8s-topology"

    # Generic resource attributes
    assert pod["attributes"]["k8s.resource.name"] == "web-6d4b75cb6d-abcde"
    assert pod["attributes"]["k8s.namespace.name"] == "default"
    assert pod["attributes"]["k8s.resource.uid"] == "pod-uid-123"

    # ownerReferences chain (Pod -> ReplicaSet)
    assert pod["attributes"]["k8s.owner.kind"] == "ReplicaSet"
    assert pod["attributes"]["k8s.owner.name"] == "web-6d4b75cb6d"
    assert pod["attributes"]["k8s.owner.uid"] == "rs-uid-456"

    # Pod-specific attributes
    assert pod["attributes"]["k8s.pod.name"] == "web-6d4b75cb6d-abcde"
    assert pod["attributes"]["k8s.pod.phase"] == "Running"
    assert pod["attributes"]["k8s.pod.node"] == "node-1"
    assert pod["attributes"]["k8s.pod.serviceaccount"] == "web-sa"

    # Labels merged via merge_maps
    assert pod["attributes"]["app"] == "web"
    assert pod["attributes"]["tier"] == "frontend"

    # Deployment-specific attributes
    assert deploy["attributes"]["k8s.deployment.name"] == "web"
    assert deploy["attributes"]["k8s.deployment.replicas"] == "3"
    assert deploy["attributes"]["k8s.deployment.available_replicas"] == "3"

    # Timestamp must NOT be backdated to creationTimestamp (statement removed:
    # pull mode re-emits every interval; observed time is correct).
    assert pod["timeUnixNano"] == "0"
    assert deploy["timeUnixNano"] == "0"
