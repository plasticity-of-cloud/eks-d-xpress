# Karpenter Installation

## EKS-D Requirement: `clusterEndpoint` Must Be Set Explicitly

On EKS managed clusters, Karpenter discovers the API server endpoint by calling
`DescribeCluster` on the EKS API. On EKS-D there is no EKS managed control plane, so this
call has nothing to hit. Karpenter will fail to start if `settings.clusterEndpoint` is not
set.

Additionally, `settings.eksControlPlane` must be set to `false` to prevent Karpenter from
attempting EKS-specific API calls.

```bash
CLUSTER_ENDPOINT="https://$(hostname -I | awk '{print $1}'):6443"

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --set settings.clusterName=${CLUSTER_NAME} \
  --set settings.clusterEndpoint=${CLUSTER_ENDPOINT} \
  --set settings.eksControlPlane=false \
  ...
```

---

## OCI Registry Migration

Karpenter moved its Helm chart from a traditional Helm repository to an OCI registry.
The old repository (`https://charts.karpenter.sh`) is no longer maintained and `helm repo add`
against it will fail or return stale/missing chart versions.

**Old (broken):**
```bash
helm repo add karpenter https://charts.karpenter.sh
helm install karpenter karpenter/karpenter --version v1.10.0 ...
```

**Correct:**
```bash
helm registry logout public.ecr.aws  # allow unauthenticated pull from public ECR
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "1.10.0" \
  --namespace kube-system \
  ...
```

Note: the OCI version tag does not use a `v` prefix (`1.10.0`, not `v1.10.0`).

Source: [Karpenter Getting Started](https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/)

---

## Default Namespace Change

Since Karpenter v1.0, the chart defaults to installing into `kube-system` rather than a
dedicated `karpenter` namespace. This aligns with Kubernetes priority class requirements —
Karpenter uses `system-cluster-critical` which requires the pod to be in `kube-system` to
benefit from the `kube-system-service-accounts` FlowSchema for API server priority.

Installing into a custom namespace requires additional FlowSchema resources to prevent
API server throttling under load.

---

## AMI Pre-pull

The AMI builder pre-pulls the Karpenter chart for offline use. This must also use the OCI
pull path:

```bash
helm registry logout public.ecr.aws 2>/dev/null || true
helm pull oci://public.ecr.aws/karpenter/karpenter --version "1.10.0" --destination /tmp
```

The pre-pulled `.tgz` is stored at `/opt/eks-d/charts/karpenter-1.10.0.tgz`. At boot time,
`11-install-karpenter.sh` uses the OCI install path directly (not the pre-pulled chart) since
the OCI pull is fast and avoids version mismatch issues with cached charts.

---

## Verification

```bash
# Karpenter pods should be Running in kube-system
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter

# Confirm correct version
helm list -n kube-system | grep karpenter
# Expected: karpenter  kube-system  1  ...  deployed  karpenter-1.10.0
```
