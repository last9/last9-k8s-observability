#!/usr/bin/env python3
"""
Render-level tests for the OTel metrics scraper Helm values.

Run: uv run --with pyyaml python3 -m unittest tests/test_metrics_scraper_values.py -v
"""

import contextlib
import http.server
import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
import unittest

import yaml

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
TA_CHART = "open-telemetry/opentelemetry-target-allocator"
TA_VERSION = "0.156.0"
COL_CHART = "open-telemetry/opentelemetry-collector"
COL_VERSION = "0.165.0"
COL_IMAGE = "otel/opentelemetry-collector-contrib:0.156.0"
TA_URL = "http://last9-target-allocator-ta.last9.svc:80"
METRICS_VALUES = "last9-otel-metrics-values.yaml"
FIXTURE = os.path.join(ROOT, "tests", "fixtures", "k8s-monitoring-values.e1ad5c9.yaml")
KPS_REPO = "https://prometheus-community.github.io/helm-charts"


def render(chart, version, values, release="rel"):
    path = values if os.path.isabs(values) else os.path.join(ROOT, values)
    out = subprocess.run(
        ["helm", "template", release, chart, "--version", version,
         "--namespace", "last9", "-f", path],
        check=True, capture_output=True, text=True,
    ).stdout
    return [d for d in yaml.safe_load_all(out) if d]


def helm_schema_flag():
    # Same detection as the installer: the flag exists only from Helm 3.16; CI pins 3.14.
    help_text = subprocess.run(["helm", "template", "--help"], capture_output=True, text=True).stdout
    return ["--skip-schema-validation"] if "--skip-schema-validation" in help_text else []


def kind(docs, k):
    return [d for d in docs if d["kind"] == k]


def ta_config(docs):
    cms = [d for d in kind(docs, "ConfigMap") if "targetallocator.yaml" in d["data"]]
    return yaml.safe_load(cms[0]["data"]["targetallocator.yaml"])


def read_fixture():
    with open(FIXTURE) as f:
        return f.read()


def main_ec2_job():
    src = read_fixture()
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
        jobs = [j for j in self.cfg["config"]["scrape_configs"] if j["job_name"] == "ec2-metadata"]
        self.assertEqual(len(jobs), 1)
        want = main_ec2_job()
        for k in ("ec2_sd_configs", "relabel_configs", "scrape_interval", "scrape_timeout"):
            self.assertEqual(jobs[0][k], want[k], k)
        self.assertEqual(jobs[0]["scrape_interval"], "5m")
        self.assertEqual(jobs[0]["scrape_timeout"], "10s")

    def test_ta_kubelet_jobs_match_kps_servicemonitor(self):
        # Source of truth: kps 75.15.1 kubelet ServiceMonitor rendered from the frozen old values.
        src = read_fixture().replace("{{YOUR_MONITORING_ENDPOINT}}", "https://x/w")
        with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
            f.write(src)
        try:
            # --repo, not a repo alias: CI only adds the open-telemetry repo.
            out = subprocess.run(
                ["helm", "template", "last9-k8s-monitoring", "kube-prometheus-stack", "--repo", KPS_REPO,
                 "--version", "75.15.1", "--namespace", "last9", "-f", f.name, *helm_schema_flag()],
                check=True, capture_output=True, text=True).stdout
        finally:
            os.unlink(f.name)
        sm = [d for d in yaml.safe_load_all(out) if d and d["kind"] == "ServiceMonitor"
              and d["metadata"]["name"] == "last9-k8s-monitoring-kube-kubelet"][0]
        eps = sm["spec"]["endpoints"]
        jobs = [j for j in self.cfg["config"]["scrape_configs"] if j["job_name"].startswith("kubelet")]
        self.assertEqual(len(jobs), len(eps))
        snake = lambda r: {"action": r["action"], "source_labels": r["sourceLabels"], "regex": r["regex"]}
        for ep, job in zip(eps, jobs):
            self.assertEqual(job["metrics_path"], ep.get("path", "/metrics"))
            self.assertEqual(job["scheme"], ep["scheme"])
            self.assertEqual(job["authorization"]["credentials_file"], ep["bearerTokenFile"])
            self.assertEqual(job["tls_config"], {"ca_file": ep["tlsConfig"]["caFile"],
                                                 "insecure_skip_verify": ep["tlsConfig"]["insecureSkipVerify"]})
            self.assertEqual(job["metric_relabel_configs"], [snake(r) for r in ep.get("metricRelabelings", [])])
            self.assertEqual(job.get("track_timestamps_staleness", False), ep.get("trackTimestampsStaleness", False))
            self.assertEqual(job["kubernetes_sd_configs"], [{"role": "node"}])
            self.assertEqual(job["scrape_interval"], ep["interval"])
            self.assertIs(job["honor_labels"], True)
            rel = job["relabel_configs"]
            static = {r["target_label"]: r["replacement"] for r in rel if "source_labels" not in r}
            self.assertEqual(static, {"job": "kubelet", "namespace": "kube-system",
                                      "service": "last9-k8s-monitoring-kube-kubelet",
                                      "endpoint": ep["port"]})
            self.assertIn({"source_labels": ["__meta_kubernetes_node_name"], "target_label": "node"}, rel)
            self.assertIn({"source_labels": ["__metrics_path__"], "target_label": "metrics_path"}, rel)
            self.assertIn({"source_labels": ["__address__"], "target_label": "instance"}, rel)
        self.assertEqual(jobs[0]["job_name"], "kubelet")
        self.assertEqual([j["metrics_path"] for j in jobs],
                         ["/metrics", "/metrics/cadvisor", "/metrics/probes", "/metrics/resource/v1alpha1"])

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
        # secret values are redacted by the TA without mTLS, so no secrets access is granted
        self.assertFalse(granted("", "secrets"))
        self.assertEqual([d for d in kind(self.docs, "ClusterRole") if "secrets" in d["metadata"]["name"]], [])

    def test_ta_service_name(self):
        # chart hardcodes the "-ta" suffix on the Service name (<fullname>-ta)
        self.assertIn("last9-target-allocator-ta", [s["metadata"]["name"] for s in kind(self.docs, "Service")])


def filled_values(alt=""):
    """Metrics values file with Task 3's placeholders substituted; returns temp path."""
    with open(os.path.join(ROOT, METRICS_VALUES)) as f:
        src = f.read()
    for k, v in (("{{LAST9_METRICS_ENDPOINT}}", "https://rw.example/write"),
                 ("{{CLUSTER_NAME}}", "test-cluster"),
                 ("{{APP_METRICS_KEEP_ALT}}", alt)):
        src = src.replace(k, v)
    f = tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False)
    f.write(src)
    f.close()
    return f.name


def collector_config(docs):
    cms = [d for d in kind(docs, "ConfigMap") if "relay" in d["data"]]
    return yaml.safe_load(cms[0]["data"]["relay"])


def main_rw_regexes():
    src = read_fixture()
    cfgs = yaml.safe_load(src)["prometheus"]["prometheusSpec"]["remoteWrite"][0]["writeRelabelConfigs"]
    assert [c["action"] for c in cfgs] == ["keep", "drop"]
    return cfgs[0]["regex"], cfgs[1]["regex"]


class MetricsCollectorValues(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.vals = filled_values()
        cls.docs = render(COL_CHART, COL_VERSION, cls.vals, release="last9-otel-metrics")
        cls.cfg = collector_config(cls.docs)

    @classmethod
    def tearDownClass(cls):
        os.unlink(cls.vals)

    def test_no_collector_service(self):
        self.assertEqual(kind(self.docs, "Service"), [])

    def test_exporter_parity(self):
        e = self.cfg["exporters"]["prometheusremotewrite/last9"]
        self.assertEqual(e["translation_strategy"], "UnderscoreEscapingWithoutSuffixes")
        self.assertEqual(e["target_info"], {"enabled": False})
        self.assertIs(e["disable_scope_info"], True)
        self.assertEqual(e["external_labels"], {"cluster": "test-cluster"})
        self.assertEqual(e.get("resource_to_telemetry_conversion", {"enabled": False}), {"enabled": False})

    def test_receiver_uses_target_allocator(self):
        r = self.cfg["receivers"]["prometheus"]
        ta = r["target_allocator"]
        self.assertEqual(ta["endpoint"], TA_URL)
        self.assertEqual(ta["interval"], "30s")
        self.assertEqual(ta["collector_id"], "${env:POD_NAME}")
        self.assertFalse(r.get("config", {}).get("scrape_configs"))

    def test_keep_drop_match_origin_main(self):
        keep, drop = main_rw_regexes()
        conds = self.cfg["processors"]["filter/last9_keep"]["metrics"]["metric"]
        self.assertEqual(conds, [
            'not IsMatch(name, "^(' + keep + ')$")',
            'IsMatch(name, "^(' + drop + ')$")',
        ])
        with open(os.path.join(ROOT, METRICS_VALUES)) as f:
            raw = f.read()
        self.assertIn("^(" + keep + "{{APP_METRICS_KEEP_ALT}})$", raw)
        self.assertIn("^(" + drop + ")$", raw)

    def test_pipeline_order(self):
        p = self.cfg["service"]["pipelines"]
        self.assertEqual(list(p), ["metrics"])
        self.assertEqual(p["metrics"], {
            "receivers": ["prometheus"],
            "processors": ["memory_limiter", "filter/last9_keep", "filter/last9_kubelet_dedup", "batch"],
            "exporters": ["prometheusremotewrite/last9"],
        })

    def test_credentials_from_secret(self):
        sts = kind(self.docs, "StatefulSet")[0]
        env = {e["name"]: e for e in sts["spec"]["template"]["spec"]["containers"][0]["env"]}
        for name, key in (("LAST9_RW_USERNAME", "username"), ("LAST9_RW_PASSWORD", "password")):
            self.assertEqual(env[name]["valueFrom"]["secretKeyRef"],
                             {"name": "last9-remote-write-secret", "key": key})
        self.assertEqual(env["POD_NAME"]["valueFrom"]["fieldRef"]["fieldPath"], "metadata.name")
        ba = self.cfg["extensions"]["basicauth/last9_metrics"]["client_auth"]
        self.assertEqual(ba, {"username": "${env:LAST9_RW_USERNAME}", "password": "${env:LAST9_RW_PASSWORD}"})

    def test_statefulset_identity(self):
        sts = kind(self.docs, "StatefulSet")[0]
        self.assertEqual(sts["metadata"]["name"], "last9-otel-metrics")
        self.assertEqual(sts["spec"]["replicas"], 1)

    def test_kubelet_scrape_rbac(self):
        rules = [r for cr in kind(self.docs, "ClusterRole") for r in cr["rules"]]
        self.assertTrue(any("nodes/metrics" in r.get("resources", []) and "get" in r["verbs"] for r in rules))
        self.assertFalse(any("nodes/proxy" in r.get("resources", []) for r in rules))
        sas = [d for d in kind(self.docs, "ServiceAccount")]
        self.assertTrue(sas)
        sts = kind(self.docs, "StatefulSet")[0]
        self.assertIsNot(sts["spec"]["template"]["spec"].get("automountServiceAccountToken"), False)
        self.assertIsNot(sas[0].get("automountServiceAccountToken"), False)


ENV = ["-e", "MY_POD_IP=127.0.0.1", "-e", "POD_NAME=t-0", "-e", "LAST9_RW_USERNAME=u",
       "-e", "LAST9_RW_PASSWORD=p"]
HAVE_DOCKER = shutil.which("docker") is not None


@contextlib.contextmanager
def mount_dir():
    """Temp dir for bind-mounting into the collector, which runs as a non-root uid (10001):
    TemporaryDirectory is 0700, so open it up or the container cannot read its config."""
    with tempfile.TemporaryDirectory() as d:
        os.chmod(d, 0o755)
        yield d


@unittest.skipUnless(HAVE_DOCKER, "docker not available")
class MetricsCollectorContainer(unittest.TestCase):
    def test_config_validates(self):
        vals = filled_values()
        try:
            cfg = collector_config(render(COL_CHART, COL_VERSION, vals, release="last9-otel-metrics"))
        finally:
            os.unlink(vals)
        with mount_dir() as d:
            with open(os.path.join(d, "config.yaml"), "w") as f:
                yaml.safe_dump(cfg, f)
            r = subprocess.run(["docker", "run", "--rm", *ENV, "-v", f"{d}:/c", COL_IMAGE,
                                "validate", "--config=/c/config.yaml"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_config_with_server_name_validates(self):
        # Render through the real install_metrics_scraper (stub helm captures the values file).
        stubs = os.path.join(ROOT, "tests", "integration", "stubs")
        with mount_dir() as w:
            env = {**os.environ, "PATH": f"{stubs}:{os.environ['PATH']}", "REPO_SRC": ROOT,
                   "HELM_CALLS_LOG": f"{w}/helm.log", "HELM_INSTALL_RETRY_DELAY": "0"}
            subprocess.run(["bash", os.path.join(ROOT, "last9-otel-setup.sh"), "function=install_metrics_scraper",
                            "token=t", "endpoint=https://e.example", "monitoring-endpoint=https://rw.example/write",
                            "cluster=test-cluster", "server-name=ingest.example.internal"],
                           cwd=w, env=env, check=True, capture_output=True)
            vals = f"{w}/helm.log.values.last9-otel-metrics"
            cfg = collector_config(render(COL_CHART, COL_VERSION, vals, release="last9-otel-metrics"))
            self.assertEqual(cfg["exporters"]["prometheusremotewrite/last9"]["tls"],
                             {"server_name_override": "ingest.example.internal"})
            with open(f"{w}/config.yaml", "w") as f:
                yaml.safe_dump(cfg, f)
            r = subprocess.run(["docker", "run", "--rm", *ENV, "-v", f"{w}:/c", COL_IMAGE,
                                "validate", "--config=/c/config.yaml"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def _survivors(self, alt):
        vals = filled_values(alt)
        try:
            flt = collector_config(render(COL_CHART, COL_VERSION, vals, release="x"))["processors"]["filter/last9_keep"]
        finally:
            os.unlink(vals)
        names = ["kube_pod_info", "node_cpu_seconds_total", "container_memory_failcnt", "my_app_requests_total"]
        gauge = lambda n: {"name": n, "gauge": {"dataPoints": [{"asInt": "1", "timeUnixNano": "1700000000000000000"}]}}
        otlp = {"resourceMetrics": [{"scopeMetrics": [{"metrics": [gauge(n) for n in names]}]}]}
        # ponytail: otlpjsonfile receiver instead of a prometheus scrape; the filter keys on metric name only
        cfg = {
            "receivers": {"otlpjsonfile": {"include": ["/in/m.json"], "start_at": "beginning"}},
            "processors": {"filter/last9_keep": flt},
            "exporters": {"file": {"path": "/out/out.json"}},
            "service": {"pipelines": {"metrics": {"receivers": ["otlpjsonfile"],
                                                  "processors": ["filter/last9_keep"],
                                                  "exporters": ["file"]}}},
        }
        with mount_dir() as d:
            os.makedirs(f"{d}/in"); os.makedirs(f"{d}/out"); os.chmod(f"{d}/out", 0o777)
            with open(f"{d}/in/m.json", "w") as f:
                f.write(json.dumps(otlp) + "\n")
            with open(f"{d}/config.yaml", "w") as f:
                yaml.safe_dump(cfg, f)
            name = f"l9-filter-test-{os.getpid()}-{int(time.time())}"
            subprocess.run(["docker", "run", "-d", "--name", name, "-v", f"{d}:/c", "-v", f"{d}/in:/in",
                            "-v", f"{d}/out:/out", COL_IMAGE, "--config=/c/config.yaml"],
                           check=True, capture_output=True)
            try:
                out = ""
                for _ in range(30):
                    time.sleep(1)
                    p = f"{d}/out/out.json"
                    out = ""
                    if os.path.exists(p):
                        with open(p) as f:
                            out = f.read()
                    if out.strip():
                        break
                logs = subprocess.run(["docker", "logs", name], capture_output=True, text=True)
                self.assertTrue(out.strip(), logs.stdout + logs.stderr)
            finally:
                subprocess.run(["docker", "rm", "-f", name], capture_output=True)
        return set(re.findall(r'"name":"([^"]+)"', out))

    def test_filter_semantics(self):
        self.assertEqual(self._survivors(""), {"kube_pod_info", "node_cpu_seconds_total"})
        self.assertEqual(self._survivors("|my_app_.*"),
                         {"kube_pod_info", "node_cpu_seconds_total", "my_app_requests_total"})

    def test_kubelet_dedup_semantics(self):
        # Real prometheus receiver scraping a host HTTP target: proves job->service.name and
        # label `service`->datapoint attribute, and that the dedup filter keys on them correctly.
        vals = filled_values()
        try:
            flt = collector_config(render(COL_CHART, COL_VERSION, vals, release="x"))["processors"]["filter/last9_kubelet_dedup"]
        finally:
            os.unlink(vals)

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = b"# TYPE probe_metric gauge\nprobe_metric 1\n"
                self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        srv = http.server.ThreadingHTTPServer(("0.0.0.0", 0), H)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        target = f"host.docker.internal:{srv.server_address[1]}"

        def job(name, job, service):
            return {"job_name": name, "scrape_interval": "1s", "static_configs": [{"targets": [target]}],
                    "relabel_configs": [{"target_label": "job", "replacement": job},
                                        {"target_label": "service", "replacement": service}]}

        cfg = {
            "receivers": {"prometheus": {"config": {"scrape_configs": [
                job("a", "kubelet", "last9-k8s-monitoring-kube-kubelet"),
                job("b", "kubelet", "other-kube-prometheus-stack-kubelet"),
                job("c", "app", "other-kube-prometheus-stack-kubelet"),
            ]}}},
            "processors": {"filter/last9_kubelet_dedup": flt},
            "exporters": {"file": {"path": "/out/out.json"}},
            "service": {"pipelines": {"metrics": {"receivers": ["prometheus"],
                                                  "processors": ["filter/last9_kubelet_dedup"],
                                                  "exporters": ["file"]}}},
        }
        with mount_dir() as d:
            os.makedirs(f"{d}/out"); os.chmod(f"{d}/out", 0o777)
            with open(f"{d}/config.yaml", "w") as f:
                yaml.safe_dump(cfg, f)
            name = f"l9-dedup-test-{os.getpid()}-{int(time.time())}"
            subprocess.run(["docker", "run", "-d", "--name", name, "--add-host", "host.docker.internal:host-gateway",
                            "-v", f"{d}:/c", "-v", f"{d}/out:/out", COL_IMAGE, "--config=/c/config.yaml"],
                           check=True, capture_output=True)
            got = set()
            try:
                for _ in range(40):
                    time.sleep(1)
                    p = f"{d}/out/out.json"
                    got = set()
                    if os.path.exists(p):
                        with open(p) as f:
                            for line in f:
                                if not line.strip():
                                    continue
                                try:
                                    doc = json.loads(line)
                                except ValueError:
                                    continue  # file exporter mid-write
                                for rm in doc["resourceMetrics"]:
                                    res = {a["key"]: a["value"].get("stringValue") for a in rm["resource"]["attributes"]}
                                    for sm in rm["scopeMetrics"]:
                                        for m in sm["metrics"]:
                                            if m["name"] != "probe_metric":
                                                continue
                                            for dp in m["gauge"]["dataPoints"]:
                                                at = {a["key"]: a["value"].get("stringValue") for a in dp["attributes"]}
                                                got.add((res.get("service.name"), at.get("service")))
                    # job "c" and the kept kubelet series both present => at least one full scrape cycle
                    if ("app", "other-kube-prometheus-stack-kubelet") in got and \
                            ("kubelet", "last9-k8s-monitoring-kube-kubelet") in got:
                        time.sleep(3)
                        break
                logs = subprocess.run(["docker", "logs", name], capture_output=True, text=True)
            finally:
                subprocess.run(["docker", "rm", "-f", name], capture_output=True)
                srv.shutdown()
        self.assertEqual(
            got, {("kubelet", "last9-k8s-monitoring-kube-kubelet"), ("app", "other-kube-prometheus-stack-kubelet")},
            logs.stdout[-2000:] + logs.stderr[-2000:])


if __name__ == "__main__":
    unittest.main()
