import os
import re
import shutil
import subprocess
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SETUP_SCRIPT = os.path.join(REPO_ROOT, "last9-otel-setup.sh")
VALUES_FILE = os.path.join(REPO_ROOT, "k8s-monitoring-values.yaml")


def _read_monitoring_version():
    with open(SETUP_SCRIPT) as f:
        content = f.read()
    m = re.search(r'MONITORING_VERSION="([^"]+)"', content)
    assert m, "MONITORING_VERSION pin not found in last9-otel-setup.sh"
    return m.group(1)


def _resolve_endpoint_placeholder(values_path):
    """Mirror what last9-otel-setup.sh does at install time (see its
    "Replace placeholder with actual endpoint" step): before ever running
    `helm template`, it sed-replaces the shipped `{{YOUR_MONITORING_ENDPOINT}}`
    placeholder in remoteWrite.url with a literal endpoint string. The chart
    runs `tpl` over `prometheusSpec.remoteWrite`, so the raw `{{ }}` literal
    placeholder is not valid on its own and must be resolved first — this
    helper does that resolution so tests render the file the way the real
    installer flow does, not the un-substituted shipped copy.
    """
    with open(values_path) as f:
        content = f.read()
    content = content.replace(
        "{{YOUR_MONITORING_ENDPOINT}}", "https://example-endpoint.last9.io/v1/metrics"
    )
    with open(values_path, "w") as f:
        f.write(content)


def _inject_namespace_filter(tmpdir, include=None, exclude=None):
    values_copy = os.path.join(tmpdir, "k8s-monitoring-values.yaml")
    shutil.copy(VALUES_FILE, values_copy)
    _resolve_endpoint_placeholder(values_copy)

    script = f"""
        cd {tmpdir}
        log_info() {{ :; }}; log_warn() {{ :; }}; log_error() {{ exit 1; }}
        {subprocess.run(
            ["awk", "/^build_namespace_regex\\(\\)/,/^}}/", SETUP_SCRIPT],
            capture_output=True, text=True
        ).stdout}
        {subprocess.run(
            ["awk", "/^inject_metrics_namespace_filter\\(\\)/,/^}}/", SETUP_SCRIPT],
            capture_output=True, text=True
        ).stdout}
        METRICS_NAMESPACE_INCLUDE='{include or ""}'
        METRICS_NAMESPACE_EXCLUDE='{exclude or ""}'
        inject_metrics_namespace_filter
    """
    result = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    assert result.returncode == 0, f"injection failed: {result.stderr}"
    return values_copy


class TestNamespaceFilterHelmRender(unittest.TestCase):
    def setUp(self):
        if shutil.which("helm") is None:
            self.skipTest("helm not installed")
        self.version = _read_monitoring_version()
        subprocess.run(
            ["helm", "repo", "add", "prometheus-community",
             "https://prometheus-community.github.io/helm-charts"],
            capture_output=True
        )
        subprocess.run(["helm", "repo", "update", "prometheus-community"], capture_output=True)

    def _render(self, values_file):
        result = subprocess.run(
            ["helm", "template", "test-release",
             "prometheus-community/kube-prometheus-stack",
             "--version", self.version,
             "-f", values_file],
            capture_output=True, text=True
        )
        return result

    def test_renders_with_no_namespace_filter(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            values_copy = os.path.join(tmpdir, "k8s-monitoring-values.yaml")
            shutil.copy(VALUES_FILE, values_copy)
            _resolve_endpoint_placeholder(values_copy)
            result = self._render(values_copy)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_renders_with_include_filter(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            values_copy = _inject_namespace_filter(tmpdir, include="production,prod-apps")
            result = self._render(values_copy)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('regex: "^(production|prod-apps)?$"', open(values_copy).read())

    def test_renders_with_exclude_filter(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            values_copy = _inject_namespace_filter(tmpdir, exclude="dev,staging")
            result = self._render(values_copy)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('regex: "^(dev|staging)$"', open(values_copy).read())


if __name__ == "__main__":
    unittest.main()
