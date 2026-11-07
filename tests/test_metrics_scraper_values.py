#!/usr/bin/env python3
"""
Render-level tests for the OTel metrics scraper Helm values.

Run: uv run --with pyyaml python3 -m unittest tests/test_metrics_scraper_values.py -v
"""

import os
import subprocess
import unittest

import yaml

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
TA_CHART = "open-telemetry/opentelemetry-target-allocator"
TA_VERSION = "0.156.0"


def render(chart, version, values):
    out = subprocess.run(
        ["helm", "template", "rel", chart, "--version", version,
         "--namespace", "last9", "-f", os.path.join(ROOT, values)],
        check=True, capture_output=True, text=True,
    ).stdout
    return [d for d in yaml.safe_load_all(out) if d]


def kind(docs, k):
    return [d for d in docs if d["kind"] == k]


def ta_config(docs):
    cms = [d for d in kind(docs, "ConfigMap") if "targetallocator.yaml" in d["data"]]
    return yaml.safe_load(cms[0]["data"]["targetallocator.yaml"])


def main_ec2_job():
    src = subprocess.run(
        ["git", "show", "origin/main:k8s-monitoring-values.yaml"],
        check=True, capture_output=True, text=True, cwd=ROOT,
    ).stdout
    return yaml.safe_load(src)["prometheus"]["prometheusSpec"]["additionalScrapeConfigs"][0]


class TargetAllocatorValues(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.docs = render(TA_CHART, TA_VERSION, "last9-target-allocator-values.yaml")
        cls.cfg = ta_config(cls.docs)

    def test_ta_selects_all_monitors(self):
        pcr = self.cfg["prometheus_cr"]
        self.assertIs(pcr["enabled"], True)
        self.assertEqual(pcr["service_monitor_selector"], {})
        self.assertEqual(pcr["pod_monitor_selector"], {})
        self.assertEqual(pcr.get("scrape_interval", pcr.get("scrapeInterval")), "60s")

    def test_ta_collector_selector(self):
        self.assertEqual(self.cfg["collector_selector"]["matchlabels"],
                         {"app.kubernetes.io/instance": "last9-otel-metrics"})
        self.assertEqual(self.cfg["allocation_strategy"], "consistent-hashing")

    def test_ta_carries_ec2_metadata_job(self):
        jobs = self.cfg["config"]["scrape_configs"]
        self.assertEqual([j["job_name"] for j in jobs], ["ec2-metadata"])
        want = main_ec2_job()
        for k in ("ec2_sd_configs", "relabel_configs", "scrape_interval", "scrape_timeout"):
            self.assertEqual(jobs[0][k], want[k], k)
        self.assertEqual(jobs[0]["scrape_interval"], "5m")
        self.assertEqual(jobs[0]["scrape_timeout"], "10s")

    def test_ta_rbac(self):
        rules = [r for cr in kind(self.docs, "ClusterRole") for r in cr["rules"]]

        def granted(group, resource):
            return any(group in r.get("apiGroups", []) and resource in r.get("resources", [])
                       and ("*" in r["verbs"] or {"get", "list", "watch"} <= set(r["verbs"])) for r in rules)

        for res in ("servicemonitors", "podmonitors"):
            self.assertTrue(granted("monitoring.coreos.com", res), res)
        for res in ("pods", "services", "endpoints", "nodes", "namespaces"):
            self.assertTrue(granted("", res), res)
        self.assertTrue(granted("discovery.k8s.io", "endpointslices"))

    def test_ta_service_name(self):
        # chart hardcodes the "-ta" suffix on the Service name (<fullname>-ta)
        self.assertIn("last9-target-allocator-ta", [s["metadata"]["name"] for s in kind(self.docs, "Service")])


if __name__ == "__main__":
    unittest.main()
