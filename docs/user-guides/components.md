# Component Reference

## Core Components

### EKS-D Control Plane

The EKS-D control plane is the Kubernetes control plane running on a dedicated EC2 instance.

**Installation**: `eks-d-setup/07-install-eks-d.sh` (via `setup-eks-d.sh` step 3)

**Components**:
- `kube-apiserver` - REST API server for Kubernetes
- `kube-controller-manager` - Runs controller loops
- `kube-scheduler` - Assigns pods to nodes
- `etcd` - Cluster state database
- `kubelet` - Node agent

**Configuration**:
- Data directory: `/var/lib/etcd`
- Certificate directory: `/etc/kubernetes/pki`
- Manifest directory: `/etc/kubernetes/manifests`

### Karpenter

Karpenter is an open-source node provisioning project for Kubernetes.

**Installation**: `eks-d-setup/15-install-karpenter.sh` (via `setup-eks-d.sh` step 9)

**Resources**:

```yaml
# EC2NodeClass - defines instance configuration
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2023
  role: <tenant-id>-eks-d-worker-node-role
  subnetSelectorTerms:
    - id: <private-subnet-id>
  securityGroupSelectorTerms:
    - id: <worker-sg-id>
```

```yaml
# NodePool - defines capacity requirements
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      nodeClassRef:
        name: default
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
  limits:
    cpu: 100
    memory: 100Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
```

### VPC CNI

The VPC Container Network Interface provides pod networking.

**Installation**: `eks-d-setup/08-install-cni.sh` (via `setup-eks-d.sh` step 4)

**Purpose**: Assigns VPC IP addresses to pods

### CoreDNS

CoreDNS provides cluster DNS resolution. It is deployed automatically by `kubeadm init`
during step 3 (`07-install-eks-d.sh`) — there is no separate install script.

### EBS CSI Driver

The EBS Container Storage Interface driver enables EBS volume usage.

**Installation**: `eks-d-setup/13-install-ebs-csi.sh` (via `setup-eks-d.sh` step 7)

**Purpose**: Persistent storage for workloads

## Supporting Components

| Component | Where installed | Purpose |
|-----------|----------------|---------|
| containerd | AMI (`ami-builder/scripts/00-configure-containerd.sh`) | Container runtime |
| Helm | AMI (`ami-builder/scripts/04-install-helm.sh`) | Package manager |
| kubectl / kubeadm / kubelet | AMI (`ami-builder/scripts/install.sh`) | Kubernetes tooling |
| CloudWatch agent | `eks-d-setup/16-install-cloudwatch.sh` | Monitoring |
| cert-manager | `eks-d-setup/11-install-cert-manager.sh` | Certificate management |
| kubelet-csr-approver | `eks-d-setup/11b-install-kubelet-csr-approver.sh` | CSR automation |
| Metrics Server | `eks-d-setup/14-install-metrics-server.sh` | Resource metrics |

> Docker, kubectl, and Helm are baked into the AMI — they are not installed at cluster boot time.

## Component Relationships

```mermaid
classDiagram
    class ControlPlaneEC2 {
        +EKS-D Control Plane
        +Karpenter Controller
        +Kubelet
    }

    class WorkerNode {
        +Kubelet
        +VPC CNI
    }

    class NodePool {
        +EC2NodeClass
        +NodePool spec
    }

    class VPC {
        +Private Subnet
        +Security Groups
    }

    ControlPlaneEC2 --> VPC: Deploys in
    NodePool --> VPC: Provisions nodes in
    WorkerNode --> ControlPlaneEC2: Joins cluster
    Karpenter --> WorkerNode: Provisions
```

## File Locations

| Component | Location |
|-----------|----------|
| Boot installation orchestrator | `eks-d-setup/setup-eks-d.sh` |
| Installation scripts (05–18) | `eks-d-setup/` |
| NodePool / EC2NodeClass definitions | `node-pools/` |
| AMI build scripts | `ami-builder/scripts/` |
| Monitoring manifests | `monitoring/` |
