#!/usr/bin/env python3
"""
Tests for verify_existing_operator_reconciles_agent in last9-otel-setup.sh

When the bundled operator is disabled, the customer's operator must take over
our PrometheusAgent. On an upgrade the StatefulSet already exists from the
bundled operator, so its mere presence must NOT count as a successful handoff.

Mock kubectl (PATH override), driven by files in the mock dir:
  args      - operator container args, one per line
  sts       - agent StatefulSet config-reloader images, one per successive read;
              the last line repeats. Absent file = StatefulSet does not exist.

Run: python3 tests/test_verify_operator_reconcile.py
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
    D="$(cd "$(dirname "$0")" && pwd)"
    case "$*" in
        "get deployment "*) [ -f "$D/args" ] && cat "$D/args" ;;
        "get statefulset "*)
            [ -f "$D/sts" ] || exit 1
            case "$*" in
                *jsonpath*)
                    n=$(( $(cat "$D/reads" 2>/dev/null || echo 0) + 1 ))
                    echo "$n" > "$D/reads"
                    total=$(wc -l < "$D/sts")
                    [ "$n" -gt "$total" ] && n=$total
                    sed -n "${n}p" "$D/sts" | tr -d '\\n'
                    ;;
            esac
            ;;
    esac
""")

RUNNER = textwrap.dedent("""\
    #!/bin/bash
    source '{script}'
    AGENT_RECONCILE_TRIES=3
    AGENT_RECONCILE_INTERVAL=0
    EXISTING_PROMETHEUS_OPERATOR=monitoring/customer-operator
    EXISTING_PROMETHEUS_OPERATOR_IMAGE='{op_image}'
    prior=$(agent_reloader_tag)
    {mutate}
    verify_existing_operator_reconciles_agent "$prior"
""")

R = "quay.io/prometheus-operator/prometheus-config-reloader:"
OP = "quay.io/prometheus-operator/prometheus-operator:v0.81.0"
SUCCESS = "Existing operator is reconciling"


def verify(sts_before=None, sts_after=None, args="", op_image=OP) -> str:
    """sts_before: images seen when capturing the prior tag (None = no StatefulSet).
    sts_after: images seen during verification (None = unchanged)."""
    with tempfile.TemporaryDirectory() as d:
        with open(f"{d}/args", "w") as f:
            f.write(args)
        if sts_before is not None:
            with open(f"{d}/sts", "w") as f:
                f.write("\n".join(sts_before) + "\n")
        mutate = ""
        if sts_after is not None:
            with open(f"{d}/sts_after", "w") as f:
                f.write("\n".join(sts_after) + "\n")
            mutate = f"mv '{d}/sts_after' '{d}/sts'; rm -f '{d}/reads'"
        for name, body in (
            ("kubectl", MOCK_KUBECTL),
            ("run.sh", RUNNER.format(script=SCRIPT, op_image=op_image, mutate=mutate)),
        ):
            path = f"{d}/{name}"
            with open(path, "w") as f:
                f.write(body)
            os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)
        env = os.environ.copy()
        env["PATH"] = f"{d}:{env['PATH']}"
        out = subprocess.run(["bash", f"{d}/run.sh"], env=env, capture_output=True, text=True, timeout=30)
        return out.stdout + out.stderr


class TestVerifyExistingOperatorReconcilesAgent(unittest.TestCase):
    def test_fresh_install_statefulset_created(self):
        self.assertIn(SUCCESS, verify(sts_before=None, sts_after=[R + "v0.81.0"]))

    def test_fresh_install_never_created(self):
        out = verify(sts_before=None)
        self.assertNotIn(SUCCESS, out)
        self.assertIn("has not reconciled", out)

    def test_upgrade_takeover_moves_reloader_to_external_tag(self):
        out = verify(sts_before=[R + "v0.83.0"], sts_after=[R + "v0.83.0", R + "v0.81.0"])
        self.assertIn(SUCCESS, out)

    def test_upgrade_retained_statefulset_not_taken_over(self):
        # Reviewer's P1 scenario: StatefulSet left from the bundled operator, nobody reconciles it.
        out = verify(sts_before=[R + "v0.83.0"])
        self.assertNotIn(SUCCESS, out)
        self.assertIn("has not reconciled", out)

    def test_upgrade_same_version_is_inconclusive(self):
        out = verify(sts_before=[R + "v0.81.0"])
        self.assertNotIn(SUCCESS, out)
        self.assertIn("Could not confirm", out)

    def test_upgrade_digest_pinned_reloader_is_inconclusive(self):
        out = verify(sts_before=[R.rstrip(":") + "@sha256:abc"])
        self.assertNotIn(SUCCESS, out)
        self.assertIn("Could not confirm", out)

    def test_namespaces_flag_excludes_last9(self):
        out = verify(sts_before=[R + "v0.83.0"], args="--kubelet-service=kube-system/kubelet\n--namespaces=monitoring,apps\n")
        self.assertNotIn(SUCCESS, out)
        self.assertIn("does not watch namespace 'last9'", out)

    def test_instance_namespaces_overrides_namespaces(self):
        out = verify(
            sts_before=None,
            sts_after=[R + "v0.81.0"],
            args="--namespaces=monitoring\n--prometheus-instance-namespaces=monitoring,last9\n",
        )
        self.assertIn(SUCCESS, out)

    def test_deny_namespaces_excludes_last9(self):
        out = verify(sts_before=None, sts_after=[R + "v0.81.0"], args="--deny-namespaces=kube-system,last9\n")
        self.assertNotIn(SUCCESS, out)
        self.assertIn("does not watch namespace 'last9'", out)


if __name__ == "__main__":
    unittest.main()
