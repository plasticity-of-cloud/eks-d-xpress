# System Architecture

## High-Level Architecture

```mermaid
graph TB
    subgraph "Pre-Build Phase (CDK sole purpose)"
        A[CDK Stack] --> B[IAM Roles / OIDC Trust]
        B --> C[Instance Profiles]
        C --> D[GitHub Actions → AWS Connection]
    end
    
    subgraph "AMI Build Phase"
        D --> E[Packer Triggered via GitHub Actions]
        E --> F[Golden AMIs]
    end
    
    subgraph "Runtime Deployment"
        F --> G[EKS-D Installation]
        G --> H[Kubernetes Cluster]
    end
    
    subgraph "Cluster Components"
        H --> I[Karpenter]
        H --> J[AWS VPC CNI]
        H --> K[EBS CSI Driver]
        H --> L[CloudWatch Agent]
        H --> M[Metrics Server]
    end
```

## Deployment Pattern

The system uses a sequential, numbered installation approach:

```mermaid
sequenceDiagram
    participant U as User
    participant C as CDK (pre-build only)
    participant GH as GitHub Actions
    participant P as Packer
    participant I as Installer
    participant K as Kubernetes
    
    U->>C: cdk deploy (one-time IAM setup)
    C->>GH: IAM roles / OIDC trust ready
    GH->>P: Trigger AMI build (authenticated via CDK-provisioned IAM)
    P->>GH: AMI ready
    U->>I: Run setup-eks-d.sh
    I->>K: Install components 05-17
    K->>U: Cluster ready (< 3 min)
```

## Component Layers

```mermaid
graph LR
    subgraph "Infrastructure Layer"
        A1[EC2 Instances]
        A2[VPC/Networking]
        A3[Security Groups]
        A4[IAM Roles]
    end
    
    subgraph "Platform Layer"
        B1[EKS-D Control Plane]
        B2[etcd]
        B3[containerd]
        B4[CNI Plugins]
    end
    
    subgraph "Service Layer"
        C1[Karpenter]
        C2[AWS Load Balancer Controller]
        C3[EBS CSI Driver]
        C4[CloudWatch Agent]
    end
    
    A1 --> B1
    A2 --> B4
    A3 --> B1
    A4 --> C1
    B1 --> C1
    B3 --> C2
    B4 --> C3
```

## Security Architecture

The system implements defense-in-depth security:
- **IAM**: Pod Identity and IRSA for workload authentication
- **Network**: VPC isolation with security groups
- **Authentication**: AWS IAM Authenticator integration
- **Authorization**: Kubernetes RBAC
- **Secrets**: CSR approval automation for certificate management
