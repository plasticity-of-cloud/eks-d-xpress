# containerd Configuration

## Required Configuration

Two containerd settings must be correct for EKS-D to work:

1. **Sandbox (pause) image** — must use the EKS-D pause image, not `registry.k8s.io/pause`
2. **Cgroup driver** — must be `systemd` to match kubelet

Neither is configured in the current setup. containerd is installed and started, but its
`/etc/containerd/config.toml` is either absent (containerd uses built-in defaults) or
contains the wrong values.

---

## Problem 1: Wrong pause image

Every pod in Kubernetes starts with a pause (infra) container that holds the network namespace.
containerd's default sandbox image is `registry.k8s.io/pause:3.x`.

EKS-D has its own pause image:
```
public.ecr.aws/eks-distro/kubernetes/pause:v1.33.x-eks-1-33-<release>
```

If containerd uses the upstream pause image:
- The pause container version may not match the EKS-D kubelet's expectations
- ECR credential provider is not invoked for `registry.k8s.io` images, so the pause image
  must be publicly accessible (it is, but it's the wrong image)
- On air-gapped or restricted environments, the wrong image will fail to pull

**Fix:** Set the sandbox image in `/etc/containerd/config.toml` to the EKS-D pause image.

---

## Problem 2: Cgroup driver mismatch

kubelet defaults to `cgroupDriver: systemd` on modern Linux (and kubeadm sets it explicitly).
containerd defaults to `SystemdCgroup = false` (uses cgroupfs driver).

When the cgroup drivers differ:
- kubelet and containerd disagree on cgroup hierarchy paths
- Pods may fail to start with errors like `failed to create containerd task`
- Resource limits (CPU, memory) may not be enforced correctly
- The node may report incorrect resource usage

**Fix:** Set `SystemdCgroup = true` in the containerd config.

---

## Fix

Add a containerd configuration step before `06-install-eks-d.sh`. This step requires the
EKS-D release manifest to be downloaded first (to extract the pause image tag).

```bash
# Download release manifest (if not already done)
curl -sL "https://distro.eks.amazonaws.com/kubernetes-${EKSD_VERSION}/kubernetes-${EKSD_VERSION}-eks-${EKSD_RELEASE}.yaml" \
  -o /tmp/eks-d-release.yaml

# Extract pause image URI from release manifest
PAUSE_IMAGE=$(grep -A2 "name: pause" /tmp/eks-d-release.yaml | grep "uri:" | head -1 | awk '{print $2}')

# Generate default config and apply overrides
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

sudo sed -i "s|sandbox_image = .*|sandbox_image = \"${PAUSE_IMAGE}\"|" /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl restart containerd
```

This should run before `kubeadm init` so that the correct pause image is used from the first
pod creation.

---

## Placement in Install Order

This configuration belongs in a new `00-configure-containerd.sh` script, called before
`06-install-eks-d.sh`. In the AMI builder (`ami-builder/scripts/install.sh`), it should run
after containerd is installed and before `kubeadm config images pull`.

---

## Verification

```bash
# Confirm sandbox image in containerd config
sudo grep sandbox_image /etc/containerd/config.toml
# Expected: sandbox_image = "public.ecr.aws/eks-distro/kubernetes/pause:v1.33.x-eks-1-33-..."

# Confirm SystemdCgroup
sudo grep SystemdCgroup /etc/containerd/config.toml
# Expected: SystemdCgroup = true

# Confirm kubelet cgroup driver matches
sudo cat /var/lib/kubelet/config.yaml | grep cgroupDriver
# Expected: cgroupDriver: systemd
```
