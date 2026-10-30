#!/usr/bin/env python3
"""
Tests for detect_existing_prometheus_operator in last9-otel-setup.sh

Uses a mock kubectl (PATH override) that returns a canned
`get deployment -A -o jsonpath=...` listing. Detection must key off the
operator image, since real installs (kube-prometheus-stack, Bitnami, jsonnet)
label the operator Deployment differently.

Run: python3 tests/test_detect_prometheus_operator.py
"""

import os
import stat
import subprocess
import tempfile
import textwrap
import unittest

SCRIPT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "last9-otel-setup.sh"))

MOCK_KUBECTL = textwrap.dedent("""\
    #!/bin/bash
    MOCK_DIR="$(cd "$(dirname "$0")" && pwd)"
    case "$*" in
        "get deployment -A -o jsonpath="*) cat "$MOCK_DIR/deployments" ;;
    esac
""")

RUNNER = textwrap.dedent("""\
    #!/bin/bash
    source '{script}'
    if detect_existing_prometheus_operator; then
        echo "FOUND=$EXISTING_PROMETHEUS_OPERATOR"
    else
        echo "FOUND="
    fi
""")


def detect(deployments: str) -> str:
    with tempfile.TemporaryDirectory() as d:
        with open(f"{d}/deployments", "w") as f:
            f.write(deployments)
        for name, body in (("kubectl", MOCK_KUBECTL), ("run.sh", RUNNER.format(script=SCRIPT))):
            path = f"{d}/{name}"
            with open(path, "w") as f:
                f.write(body)
            os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)
        env = os.environ.copy()
        env["PATH"] = f"{d}:{env['PATH']}"
        out = subprocess.run(["bash", f"{d}/run.sh"], env=env, capture_output=True, text=True, timeout=30)
        for line in out.stdout.splitlines():
            if line.startswith("FOUND="):
                return line[len("FOUND="):]
        raise AssertionError(f"runner produced no result:\n{out.stdout}\n{out.stderr}")


class TestDetectExistingPrometheusOperator(unittest.TestCase):
    def test_kube_prometheus_stack_operator(self):
        # The case that slipped through label-based detection: kube-prometheus-stack
        # labels it app.kubernetes.io/name=kube-prometheus-stack-prometheus-operator.
        self.assertEqual(
            detect("prometheus\tprom-kube-prometheus-operator\tquay.io/prometheus-operator/prometheus-operator:v0.81.0 \n"),
            "prometheus/prom-kube-prometheus-operator",
        )

    def test_bitnami_operator(self):
        self.assertEqual(
            detect("monitoring\tkp-operator\tdocker.io/bitnami/prometheus-operator:0.81.0-debian-12-r0 \n"),
            "monitoring/kp-operator",
        )

    def test_digest_pinned_and_private_registry_with_port(self):
        self.assertEqual(
            detect("obs\top\tregistry.local:5000/mirror/prometheus-operator@sha256:abc \n"),
            "obs/op",
        )

    def test_ignores_own_namespace(self):
        self.assertEqual(
            detect("last9\tlast9-k8s-monitoring-kube-operator\tquay.io/prometheus-operator/prometheus-operator:v0.83.0 \n"),
            "",
        )

    def test_ignores_non_operator_images(self):
        self.assertEqual(
            detect(
                "prometheus\tprom-server\tquay.io/prometheus/prometheus:v3.5.0 quay.io/prometheus-operator/prometheus-config-reloader:v0.81.0 \n"
                "prometheus\twebhook\tquay.io/prometheus-operator/admission-webhook:v0.81.0 \n"
                "kube-system\tcoredns\tregistry.k8s.io/coredns/coredns:v1.11.1 \n"
            ),
            "",
        )

    def test_operator_in_sidecar_position(self):
        self.assertEqual(
            detect("prometheus\top\tbusybox:1.36 quay.io/prometheus-operator/prometheus-operator:v0.81.0 \n"),
            "prometheus/op",
        )

    def test_no_deployments(self):
        self.assertEqual(detect(""), "")


if __name__ == "__main__":
    unittest.main()
