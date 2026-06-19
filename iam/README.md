# IAM for the `ec2-metadata` scrape job (ENG-1308)

The `ec2_sd` scrape job in `k8s-monitoring-values.yaml` calls `ec2:DescribeInstances`. The Prometheus pod needs AWS creds for that call. Helm cannot create IAM (it's an AWS control-plane resource), so provision the role/policy with **one** of the two paths below, then point the values file at it.

`ec2:DescribeInstances` does **not** support resource-level or tag conditions — `Resource` must be `*`; the only meaningful scope is `aws:RequestedRegion` (see `ec2-metadata-policy.json`). Replace all `<PLACEHOLDERS>`.

## Permission policy (both paths)

```bash
sed "s/<AWS_REGION>/$REGION/" ec2-metadata-policy.json > /tmp/perm.json
POLICY_ARN=$(aws iam create-policy --policy-name last9-prom-ec2sd \
  --policy-document file:///tmp/perm.json --query Policy.Arn --output text)
```

## Path A — EKS Pod Identity (recommended; simplest, no OIDC JSON)

Trust is trivial (`trust-pod-identity.json`) and scoping is done by the association, not a per-SA `sub` condition. Pin the Prometheus SA name in the values file (`prometheus.serviceAccount.name: last9-prometheus`) so the association is deterministic.

```bash
# 1. role with the Pod Identity trust
ROLE_ARN=$(aws iam create-role --role-name last9-prom-ec2sd \
  --assume-role-policy-document file://trust-pod-identity.json --query Role.Arn --output text)
aws iam attach-role-policy --role-name last9-prom-ec2sd --policy-arn "$POLICY_ARN"

# 2. enable the Pod Identity Agent addon (once per cluster)
aws eks create-addon --cluster-name "$CLUSTER" --addon-name eks-pod-identity-agent

# 3. associate the role to the Prometheus SA — no values-file annotation needed
aws eks create-pod-identity-association --cluster-name "$CLUSTER" \
  --namespace "$NS" --service-account last9-prometheus --role-arn "$ROLE_ARN"
```

With Pod Identity the `eks.amazonaws.com/role-arn` SA annotation in `k8s-monitoring-values.yaml` is **not** required (remove/ignore it). Restart the Prometheus pod after associating.

## Path B — IRSA (OIDC; if Pod Identity addon isn't available)

```bash
# ensure the cluster has an IAM OIDC provider
eksctl utils associate-iam-oidc-provider --cluster "$CLUSTER" --approve
# fill <ACCOUNT_ID>/<AWS_REGION>/<OIDC_ID>/<NAMESPACE>/<PROM_SA_NAME> in trust-irsa.json
#   OIDC_ID: aws eks describe-cluster --name "$CLUSTER" --query identity.oidc.issuer --output text
ROLE_ARN=$(aws iam create-role --role-name last9-prom-ec2sd \
  --assume-role-policy-document file://trust-irsa.json --query Role.Arn --output text)
aws iam attach-role-policy --role-name last9-prom-ec2sd --policy-arn "$POLICY_ARN"
# then set <IRSA_ROLE_ARN> in k8s-monitoring-values.yaml (prometheus.serviceAccount.annotations)
```

Pin `prometheus.serviceAccount.name` so the trust `sub` (`system:serviceaccount:<NS>:<name>`) matches the chart's SA. Restart the Prometheus pod after the annotation lands.

## Verify

```bash
kubectl get sa <PROM_SA_NAME> -n "$NS" -o yaml   # Pod Identity: association handles it; IRSA: annotation present
# Prometheus pod logs should show no AccessDenied / NoCredentialProviders on the ec2-metadata target
```

## Can this be automated in our setup?

Not by Helm directly. The realistic automation is to ship these artifacts (done) plus a one-command provisioner; for new installs, **Path A (Pod Identity)** is the smallest footprint — one `create-pod-identity-association`, no OIDC plumbing, no values-file annotation. A future `last9-k8s-infra` onboarding step could wrap Path A behind a single script / Terraform module.
