# Engineering guidelines

- When an installer helper gains a chart, file, or other dependency, find every caller, including `function=` dispatch and `GCP-Autopilot/` installers, and cover each entrypoint in orchestration tests.
- Keep Helm-invoking tests compatible with CI's pinned Helm 3.14: use `--repo <url>` instead of aliases, and detect version-gated flags such as `--skip-schema-validation` from `--help`.
- Split `--set` argument strings with `read -r -a`, never `xargs`, which strips `\.` escapes; test a dotted key such as `kubernetes.io/os`.
- Run cleanup only for resources whose creation succeeded in the current run; test prerequisite refusal, pre-existing resources, creation failure, later setup failure, and explicit preservation.
- Health gates must read every sharded replica and compare exporter counters per process identity across complete polls. Unreadable, replaced, restarted, or reset sources invalidate the baseline.
