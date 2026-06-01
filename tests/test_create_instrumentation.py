#!/usr/bin/env python3
"""
Tests for create_instrumentation in last9-otel-setup.sh

The Instrumentation custom resource is gated by the OpenTelemetry Operator's
mutating admission webhook. Applying it before the operator Deployment is
Available (and its webhook endpoints are populated) fails with errors like
"no endpoints available for service ...-webhook" or a TLS/x509 caBundle error.

The original implementation:
  - waited a fixed `sleep 30` after the operator install (a blind race that
    loses on slower clusters such as GKE Autopilot, which schedules a fresh
    node and injects resource requests), and
  - ran `kubectl apply ... 2>/dev/null`, discarding the real API-server
    rejection so the operator only ever saw "Attempt N failed".

The fix:
  - waits on the operator Deployment readiness condition BEFORE applying, and
  - captures stderr and surfaces the real error on persistent failure.

Uses mock kubectl/sleep binaries (PATH override) — no cluster needed.
Run: python3 tests/test_create_instrumentation.py
"""

import os
import stat
import subprocess
import tempfile
import textwrap
import unittest

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "last9-otel-setup.sh")
SCRIPT = os.path.abspath(SCRIPT)

# Mock kubectl: records every call, and controls the `apply -f instrumentation`
# outcome via the scenario file.
#   SCENARIO "ok"            -> apply succeeds immediately
#   SCENARIO "always_fail"   -> apply always fails, printing a realistic
#                               webhook error to stderr
# Any readiness wait (`wait`/`rollout status`) succeeds.
MOCK_KUBECTL = textwrap.dedent("""\
    #!/bin/bash
    MOCK_DIR="$(cd "$(dirname "$0")" && pwd)"
    echo "kubectl $*" >> "$MOCK_DIR/calls.log"
    SCENARIO="$(cat "$MOCK_DIR/scenario")"
    case "$1" in
        wait|rollout)
            exit 0
            ;;
        apply)
            case "$*" in
                *instrumentation.yaml*)
                    if [ "$SCENARIO" = "always_fail" ]; then
                        echo 'Error from server (InternalError): error when creating "instrumentation.yaml": Internal error occurred: failed calling webhook "minstrumentation.kb.io": failed to call webhook: no endpoints available for service "opentelemetry-operator-webhook"' >&2
                        exit 1
                    fi
                    exit 0
                    ;;
                *) exit 0 ;;
            esac
            ;;
        *) exit 0 ;;
    esac
""")

# sleep is mocked to no-op so the retry backoff does not slow the test.
MOCK_SLEEP = "#!/bin/bash\nexit 0\n"

RUNNER = textwrap.dedent("""\
    #!/bin/bash
    source '{script}'
    create_instrumentation
""")


def run_create(scenario: str) -> tuple[int, list[str], str]:
    """Run create_instrumentation with mocked kubectl/sleep.

    Returns (returncode, calls, combined_output)."""
    with tempfile.TemporaryDirectory() as mock_dir:
        with open(f"{mock_dir}/scenario", "w") as f:
            f.write(scenario)
        open(f"{mock_dir}/calls.log", "w").close()

        for name, body in (("kubectl", MOCK_KUBECTL), ("sleep", MOCK_SLEEP)):
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
        # Keep any readiness-wait timeout short so a future real `kubectl wait`
        # (if the mock is ever bypassed) cannot hang the suite.
        env["OPERATOR_READY_TIMEOUT"] = "1s"

        # instrumentation.yaml is resolved relative to CWD by the script.
        result = subprocess.run(
            ["bash", runner_path],
            env=env,
            cwd=os.path.dirname(SCRIPT),
            capture_output=True,
            text=True,
        )

        with open(f"{mock_dir}/calls.log") as f:
            calls = f.read().splitlines()

    return result.returncode, calls, result.stdout + result.stderr


class TestCreateInstrumentation(unittest.TestCase):

    def test_waits_for_operator_before_applying(self):
        """Readiness must be gated on the operator Deployment condition, not a
        blind sleep: a `kubectl wait`/`rollout status` for the operator must
        occur BEFORE the Instrumentation apply."""
        _, calls, _ = run_create("ok")
        wait_idx = next(
            (i for i, c in enumerate(calls)
             if c.startswith(("kubectl wait", "kubectl rollout"))),
            None,
        )
        apply_idx = next(
            (i for i, c in enumerate(calls)
             if c.startswith("kubectl apply") and "instrumentation.yaml" in c),
            None,
        )
        self.assertIsNotNone(wait_idx, f"Expected a readiness wait for the operator: {calls}")
        self.assertIsNotNone(apply_idx, f"Expected an instrumentation apply: {calls}")
        self.assertLess(
            wait_idx, apply_idx,
            f"Operator readiness must be awaited before applying Instrumentation: {calls}",
        )

    def test_surfaces_real_error_on_persistent_failure(self):
        """A persistent apply failure must surface the real kubectl/API-server
        error (stderr must NOT be discarded with 2>/dev/null)."""
        rc, _, output = run_create("always_fail")
        self.assertNotEqual(rc, 0, "Persistent failure must exit non-zero")
        self.assertIn(
            "no endpoints available",
            output,
            f"The real webhook error must be surfaced, not swallowed:\n{output}",
        )

    def test_succeeds_when_apply_succeeds(self):
        """Happy path: when the webhook is ready and apply succeeds, the
        function reports success and exits 0."""
        rc, calls, output = run_create("ok")
        self.assertEqual(rc, 0, f"Expected success exit 0:\n{output}")
        applied = [c for c in calls if c.startswith("kubectl apply") and "instrumentation.yaml" in c]
        self.assertTrue(applied, f"Expected an instrumentation apply: {calls}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
