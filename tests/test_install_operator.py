#!/usr/bin/env python3
"""
Tests for install_operator CRD-conflict handling in last9-otel-setup.sh

Reproduces the cert-manager-cainjector SSA field-conflict on
.spec.conversion.webhook.clientConfig.caBundle: when OTel CRDs already exist,
Helm's server-side apply collides with cert-manager-cainjector and the install
fails. The fix mirrors the kube-prometheus path: apply chart CRDs out-of-band
with --force-conflicts and pass --skip-crds to Helm.

Uses mock kubectl/helm/sleep binaries (PATH override) — no cluster needed.
Run: python3 tests/test_install_operator.py
"""

import os
import stat
import subprocess
import tempfile
import textwrap
import unittest

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "last9-otel-setup.sh")
SCRIPT = os.path.abspath(SCRIPT)

# Mock kubectl: drives adopt_otel_crds + the pre-existing-CRD detection.
# SCENARIO "crds_exist"  -> `get crd opentelemetrycollectors...` exits 0 (present)
# SCENARIO "no_crds"     -> that probe exits 1 (absent), and `get crd -o name` empty
MOCK_KUBECTL = textwrap.dedent("""\
    #!/bin/bash
    MOCK_DIR="$(cd "$(dirname "$0")" && pwd)"
    echo "kubectl $*" >> "$MOCK_DIR/calls.log"
    SCENARIO="$(cat "$MOCK_DIR/scenario")"
    case "$*" in
        "get crd opentelemetrycollectors.opentelemetry.io")
            [ "$SCENARIO" = "crds_exist" ] && exit 0 || exit 1
            ;;
        "get crd -o name")
            [ "$SCENARIO" = "no_crds" ] && exit 0
            printf 'crd/opentelemetrycollectors.opentelemetry.io\\n'
            ;;
        *"metadata.labels.app"*) echo "" ;;
        *"metadata.annotations.meta"*) echo "" ;;
        *"-o yaml"*)
            echo "apiVersion: apiextensions.k8s.io/v1"
            echo "kind: CustomResourceDefinition"
            ;;
        *) exit 0 ;;
    esac
""")

# Mock helm: record every invocation, succeed. `template` emits a CRD doc plus a
# non-CRD doc, so the awk CRD-only filter in install_operator is exercised.
MOCK_HELM = textwrap.dedent("""\
    #!/bin/bash
    MOCK_DIR="$(cd "$(dirname "$0")" && pwd)"
    echo "helm $*" >> "$MOCK_DIR/calls.log"
    case "$*" in
        "template"*)
            printf -- '---\\n'
            printf 'apiVersion: apiextensions.k8s.io/v1\\n'
            printf 'kind: CustomResourceDefinition\\n'
            printf 'metadata:\\n  name: opentelemetrycollectors.opentelemetry.io\\n'
            printf -- '---\\n'
            printf 'apiVersion: apps/v1\\n'
            printf 'kind: Deployment\\n'
            printf 'metadata:\\n  name: opentelemetry-operator\\n'
            ;;
        *) exit 0 ;;
    esac
""")

MOCK_SLEEP = "#!/bin/bash\nexit 0\n"

RUNNER = textwrap.dedent("""\
    #!/bin/bash
    source '{script}'
    install_operator
""")


def run_install(scenario: str) -> list[str]:
    """Run install_operator with mocked kubectl/helm/sleep, return all CLI calls."""
    with tempfile.TemporaryDirectory() as mock_dir:
        with open(f"{mock_dir}/scenario", "w") as f:
            f.write(scenario)
        open(f"{mock_dir}/calls.log", "w").close()

        for name, body in (
            ("kubectl", MOCK_KUBECTL),
            ("helm", MOCK_HELM),
            ("sleep", MOCK_SLEEP),
        ):
            p = f"{mock_dir}/{name}"
            with open(p, "w") as f:
                f.write(body)
            os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)

        runner_path = f"{mock_dir}/run.sh"
        with open(runner_path, "w") as f:
            f.write(RUNNER.format(script=SCRIPT))
        os.chmod(runner_path, os.stat(runner_path).st_mode | stat.S_IEXEC)

        env = os.environ.copy()
        env["PATH"] = f"{mock_dir}:{env['PATH']}"
        env["NAMESPACE"] = "last9"
        env["OPERATOR_VERSION"] = "0.90.0"
        env["TOLERATIONS_FILE_PATH"] = ""
        env["HELM_SCHEMA_FLAG"] = ""

        result = subprocess.run(
            ["bash", runner_path], env=env, capture_output=True, text=True
        )

        with open(f"{mock_dir}/calls.log") as f:
            calls = f.read().splitlines()

    if result.returncode != 0:
        raise RuntimeError(
            f"install_operator failed (exit {result.returncode})\n"
            f"stderr: {result.stderr[:500]}"
        )
    return calls


class TestInstallOperator(unittest.TestCase):

    def test_preexisting_crds_rendered_from_template(self):
        """The opentelemetry-operator chart ships CRDs as templates (not crds/),
        so they must be rendered with `helm template --include-crds`, NOT
        `helm show crds` (which is empty for this chart)."""
        calls = run_install("crds_exist")
        tmpl = [c for c in calls if c.startswith("helm template") and "--include-crds" in c]
        self.assertTrue(tmpl, f"Expected 'helm template --include-crds': {calls}")
        self.assertFalse(
            [c for c in calls if c.startswith("helm show crds")],
            f"Must NOT use 'helm show crds' (empty for this chart): {calls}",
        )

    def test_preexisting_crds_applied_with_force_conflicts(self):
        """Rendered CRDs are force-applied out-of-band to steal caBundle ownership
        from cert-manager-cainjector and upgrade schema before Helm runs."""
        calls = run_install("crds_exist")
        force_applies = [
            c
            for c in calls
            if c.startswith("kubectl apply --server-side") and "--force-conflicts" in c
        ]
        self.assertTrue(
            force_applies, f"Expected an out-of-band force-conflicts apply: {calls}"
        )

    def test_preexisting_crds_helm_disables_crd_creation(self):
        """When OTel CRDs pre-exist, the helm install must pass crds.create=false
        (NOT --skip-crds, which is a no-op for template-rendered CRDs) so Helm
        does not re-conflict with cert-manager-cainjector on caBundle."""
        calls = run_install("crds_exist")
        install = [c for c in calls if c.startswith("helm upgrade --install")]
        self.assertEqual(len(install), 1, f"Expected one helm install: {install}")
        self.assertIn(
            "crds.create=false", install[0], f"Helm install must disable CRDs: {install[0]}"
        )
        self.assertNotIn(
            "--skip-crds", install[0],
            f"--skip-crds is ineffective for this chart, must not be used: {install[0]}",
        )

    def test_no_crds_helm_owns_crds(self):
        """When no OTel CRDs pre-exist, Helm installs CRDs itself — no
        crds.create=false and no out-of-band CRD render/apply."""
        calls = run_install("no_crds")
        install = [c for c in calls if c.startswith("helm upgrade --install")]
        self.assertEqual(len(install), 1, f"Expected one helm install: {install}")
        self.assertNotIn(
            "crds.create=false", install[0],
            f"Fresh install should let Helm create CRDs: {install[0]}",
        )
        self.assertFalse(
            [c for c in calls if c.startswith("helm template")],
            f"No out-of-band CRD render when CRDs absent: {calls}",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
