#!/usr/bin/env bats
# Layer 1 orchestration tests for the uninstall paths.
#
# Runs the real last9-otel-setup.sh uninstall flows with kubectl/helm/sleep
# replaced by recording stubs (tests/integration/stubs). No cluster required.
# `yes` feeds the interactive "(y/N)" confirmation prompts; SIMULATE_INSTALLED=1
# makes the helm stub report the script's releases so the real `helm uninstall`
# branch is taken.
#
# Run: bats tests/integration/uninstall.bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    STUBS="$BATS_TEST_DIRNAME/stubs"
    SCRIPT="$REPO_ROOT/last9-otel-setup.sh"

    export PATH="$STUBS:$PATH"
    export REPO_SRC="$REPO_ROOT"

    export KUBECTL_CALLS_LOG="$BATS_TEST_TMPDIR/kubectl.log"
    export HELM_CALLS_LOG="$BATS_TEST_TMPDIR/helm.log"
    : > "$KUBECTL_CALLS_LOG"
    : > "$HELM_CALLS_LOG"

    cd "$BATS_TEST_TMPDIR"
}

# Confirm every prompt with "y". The functions use `read -n 1`, so feed a
# newline-free stream of "y" — plain `yes` emits "y\n" and the stray newlines
# would satisfy alternate prompts with an empty reply (read as "cancel").
run_uninstall_yes() {
    run bash -c "yes | tr -d '\n' | bash '$SCRIPT' $*"
}

# ---------------------------------------------------------------------------
# uninstall → uninstall_opentelemetry
# ---------------------------------------------------------------------------

@test "uninstall removes the collector, operator and monitoring helm releases" {
    export SIMULATE_INSTALLED=1
    run_uninstall_yes uninstall
    [ "$status" -eq 0 ]
    grep -q "uninstall last9-opentelemetry-collector" "$HELM_CALLS_LOG"
    grep -q "uninstall opentelemetry-operator" "$HELM_CALLS_LOG"
    grep -q "uninstall last9-k8s-monitoring" "$HELM_CALLS_LOG"
}

@test "uninstall cancelled at the prompt removes nothing" {
    export SIMULATE_INSTALLED=1
    run bash -c "printf 'n\n' | bash '$SCRIPT' uninstall"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Uninstall cancelled"* ]]
    ! grep -q "uninstall " "$HELM_CALLS_LOG"
}

@test "uninstall when nothing is installed takes the not-found path, no helm uninstall" {
    # SIMULATE_INSTALLED unset → helm list reports nothing
    run_uninstall_yes uninstall
    [ "$status" -eq 0 ]
    ! grep -q "uninstall last9-opentelemetry-collector" "$HELM_CALLS_LOG"
    [[ "$output" == *"not found"* ]]
}

# ---------------------------------------------------------------------------
# uninstall-all → uninstall_all (monitoring + events + opentelemetry)
# ---------------------------------------------------------------------------

@test "uninstall-all removes monitoring, events agent and opentelemetry releases" {
    export SIMULATE_INSTALLED=1
    run_uninstall_yes uninstall-all
    [ "$status" -eq 0 ]
    grep -q "uninstall last9-k8s-monitoring" "$HELM_CALLS_LOG"
    grep -q "uninstall last9-kube-events-agent" "$HELM_CALLS_LOG"
    grep -q "uninstall last9-opentelemetry-collector" "$HELM_CALLS_LOG"
    grep -q "uninstall opentelemetry-operator" "$HELM_CALLS_LOG"
}

# ---------------------------------------------------------------------------
# function=uninstall_last9_monitoring
# ---------------------------------------------------------------------------

@test "uninstall function=uninstall_last9_monitoring removes the monitoring release and secret" {
    export SIMULATE_INSTALLED=1
    # main routes a named uninstall function only when UNINSTALL_MODE is set,
    # i.e. the `uninstall` keyword must accompany function=.
    run_uninstall_yes uninstall function=uninstall_last9_monitoring
    [ "$status" -eq 0 ]
    grep -q "uninstall last9-k8s-monitoring" "$HELM_CALLS_LOG"
    grep -q "delete secret last9-remote-write-secret" "$KUBECTL_CALLS_LOG"
}

# ---------------------------------------------------------------------------
# function=uninstall_events_agent
# ---------------------------------------------------------------------------

@test "uninstall function=uninstall_events_agent removes the events agent release" {
    export SIMULATE_INSTALLED=1
    run_uninstall_yes uninstall function=uninstall_events_agent
    [ "$status" -eq 0 ]
    grep -q "uninstall last9-kube-events-agent" "$HELM_CALLS_LOG"
}
