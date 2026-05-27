#!/usr/bin/env python3
"""
Tests for adopt_otel_crds function in last9-otel-setup.sh

Uses a mock kubectl binary (PATH override) — no cluster needed.
Run: python3 tests/test_adopt_otel_crds.py
"""

import os
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "last9-otel-setup.sh")
SCRIPT = os.path.abspath(SCRIPT)

MOCK_KUBECTL = textwrap.dedent("""\
    #!/bin/bash
    MOCK_DIR="$(cd "$(dirname "$0")" && pwd)"
    echo "$*" >> "$MOCK_DIR/calls.log"
    SCENARIO="$(cat "$MOCK_DIR/scenario")"
    case "$*" in
        "get crd -o name")
            [ "$SCENARIO" = "no_crds" ] && exit 0
            printf 'crd/opampbridges.opentelemetry.io\\ncrd/opentelemetrycollectors.opentelemetry.io\\n'
            ;;
        *"metadata.labels.app"*)
            [ "$SCENARIO" = "already_owned" ] && echo "Helm" || echo ""
            ;;
        *"metadata.annotations.meta"*)
            [ "$SCENARIO" = "already_owned" ] && echo "opentelemetry-operator" || echo ""
            ;;
        "label --overwrite"*|"annotate --overwrite"*)
            exit 0
            ;;
        *)
            exit 0
            ;;
    esac
""")

RUNNER = textwrap.dedent("""\
    #!/bin/bash
    source '{script}'
    adopt_otel_crds
""")


def run_adopt(scenario: str) -> list[str]:
    """Run adopt_otel_crds with mocked kubectl, return list of kubectl calls."""
    with tempfile.TemporaryDirectory() as mock_dir:
        # Write scenario
        with open(f"{mock_dir}/scenario", "w") as f:
            f.write(scenario)
        open(f"{mock_dir}/calls.log", "w").close()  # touch

        # Write mock kubectl
        kubectl_path = f"{mock_dir}/kubectl"
        with open(kubectl_path, "w") as f:
            f.write(MOCK_KUBECTL)
        os.chmod(kubectl_path, os.stat(kubectl_path).st_mode | stat.S_IEXEC)

        # Write runner script
        runner_path = f"{mock_dir}/run.sh"
        with open(runner_path, "w") as f:
            f.write(RUNNER.format(script=SCRIPT))
        os.chmod(runner_path, os.stat(runner_path).st_mode | stat.S_IEXEC)

        # Run with mock kubectl first in PATH
        env = os.environ.copy()
        env["PATH"] = f"{mock_dir}:{env['PATH']}"
        env["NAMESPACE"] = "last9"

        result = subprocess.run(
            ["bash", runner_path],
            env=env,
            capture_output=True,
            text=True,
        )

        # Read call log
        with open(f"{mock_dir}/calls.log") as f:
            calls = f.read().splitlines()

    if result.returncode != 0:
        raise RuntimeError(
            f"adopt_otel_crds failed (exit {result.returncode})\n"
            f"stderr: {result.stderr[:500]}"
        )
    return calls


class TestAdoptOtelCRDs(unittest.TestCase):

    def test_unowned_crds_get_labeled(self):
        """CRDs without Helm ownership get label + annotate calls."""
        calls = run_adopt("unowned_crds")

        label_calls = [c for c in calls if c.startswith("label --overwrite")]
        annotate_calls = [c for c in calls if c.startswith("annotate --overwrite")]

        self.assertEqual(len(label_calls), 2, f"Expected 2 label calls, got {len(label_calls)}")
        self.assertEqual(len(annotate_calls), 2, f"Expected 2 annotate calls, got {len(annotate_calls)}")

    def test_unowned_crds_correct_label_value(self):
        """Label sets app.kubernetes.io/managed-by=Helm."""
        calls = run_adopt("unowned_crds")
        label_calls = [c for c in calls if c.startswith("label --overwrite")]
        self.assertTrue(
            all("app.kubernetes.io/managed-by=Helm" in c for c in label_calls),
            f"Expected Helm label in all label calls: {label_calls}",
        )

    def test_unowned_crds_correct_release_name(self):
        """Annotate sets meta.helm.sh/release-name=opentelemetry-operator."""
        calls = run_adopt("unowned_crds")
        annotate_calls = [c for c in calls if c.startswith("annotate --overwrite")]
        self.assertTrue(
            all("meta.helm.sh/release-name=opentelemetry-operator" in c for c in annotate_calls),
            f"Expected release-name annotation: {annotate_calls}",
        )

    def test_unowned_crds_correct_release_namespace(self):
        """Annotate sets meta.helm.sh/release-namespace=last9."""
        calls = run_adopt("unowned_crds")
        annotate_calls = [c for c in calls if c.startswith("annotate --overwrite")]
        self.assertTrue(
            all("meta.helm.sh/release-namespace=last9" in c for c in annotate_calls),
            f"Expected release-namespace annotation: {annotate_calls}",
        )

    def test_already_owned_crds_not_patched(self):
        """CRDs already owned by correct Helm release are not re-patched."""
        calls = run_adopt("already_owned")
        label_calls = [c for c in calls if c.startswith("label --overwrite")]
        annotate_calls = [c for c in calls if c.startswith("annotate --overwrite")]
        self.assertEqual(len(label_calls), 0, f"Should not re-label owned CRDs: {label_calls}")
        self.assertEqual(len(annotate_calls), 0, f"Should not re-annotate owned CRDs: {annotate_calls}")

    def test_no_crds_exits_cleanly(self):
        """No OTel CRDs in cluster — function exits 0 without any kubectl patch calls."""
        calls = run_adopt("no_crds")
        label_calls = [c for c in calls if c.startswith("label --overwrite")]
        self.assertEqual(len(label_calls), 0, f"No patch calls when no CRDs: {label_calls}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
