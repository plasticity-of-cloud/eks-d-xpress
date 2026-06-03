# CoreDNS External DNS Forwarding — EXTERNALSNAT Requirement

## Status

**Resolved.** The EXTERNALSNAT workaround was incorrect. See resolution below.

## Symptom

After installing aws-vpc-cni on EKS-D, pods cannot resolve external DNS names
(e.g. `ec2.us-east-1.amazonaws.com`, `google.com`). CoreDNS returns `NOERROR`
with an empty answer section for all external queries. Internal cluster DNS
(`*.cluster.local`) works correctly.

Affected components: EBS CSI controller, Karpenter, CloudWatch agent — all fail
with DNS resolution errors on startup.

## Resolution (2026-04-20)

The `EXTERNALSNAT=true` workaround was incorrect and caused a worse problem:
pod-to-internet connectivity was broken because secondary ENI IPs (pod IPs)
have no public IP, so internet-bound packets were dropped.

The loop plugin does NOT trigger with `EXTERNALSNAT=false` because:
- CoreDNS forwards to `10.0.0.2` (VPC DNS resolver)
- `10.0.0.2` is intra-VPC traffic — SNAT only applies to traffic leaving the VPC CIDR
- The probe packet is never SNAT'd, so the response comes back to the pod IP directly
- No loop is detected

**Correct configuration: `EXTERNALSNAT=false` (default) with no CoreDNS changes.**

The previous observation that EXTERNALSNAT=true "fixed" DNS was likely due to
CoreDNS being restarted at the same time, which cleared whatever transient state
was causing the issue.

## Applied Fix

Reverted `EXTERNALSNAT` to `false` in `07-install-cni.sh`.
Removed `dnsPolicy: Default` patch from `10-install-ebs-csi.sh`.

## Original Investigation (2026-04-17)

### What we ruled out

- **Network connectivity**: CoreDNS pod CAN reach `10.0.0.2:53` via raw UDP
  socket from its network namespace. `nslookup google.com 10.0.0.2` works.
- **iptables DNAT**: The `KUBE-SEP-*` DNAT rules only match traffic destined
  for `10.96.0.10:53`, not all UDP/53 traffic.
- **CoreDNS binary**: Reproduced with both EKS-D image
  (`public.ecr.aws/eks-distro/coredns/coredns:v1.13.2-eks-1-35-8`) and
  standard upstream `coredns/coredns:1.11.3`.
- **CoreDNS config**: Reproduced with minimal Corefile (`.:53 { forward . 10.0.0.2 }`).
- **hostNetwork**: Reproduced even with `hostNetwork: true` on CoreDNS pods.
- **SNAT rules**: `AWS-SNAT-CHAIN-0` has 0 references after setting
  `EXTERNALSNAT=true` — SNAT is disabled but DNS still broken until CoreDNS restart.

### What we observed

Using `strace` on the CoreDNS process, when a query for `google.com` arrives:

1. CoreDNS receives the UDP packet on fd=8
2. CoreDNS **immediately** sends back a response (88 bytes, AA=1, NOERROR, 0 answers)
3. **No outbound syscalls** (`sendto`, `connect`) to `10.0.0.2` are made

The response has `AA=1` (authoritative) — meaning the kubernetes plugin is
handling the query and returning a response before the forward plugin is reached.

The kubernetes plugin is configured for `cluster.local in-addr.arpa ip6.arpa`
but is intercepting `google.com` queries. This should not happen per CoreDNS
documentation, but is observed in practice on this self-managed single-node setup.

### Suspected root cause

The `loop` plugin in CoreDNS detects forwarding loops by sending a probe query
to the configured upstream (`10.0.0.2`). On this setup:

1. CoreDNS pod sends probe UDP to `10.0.0.2:53`
2. With default VPC CNI SNAT, the packet is SNAT'd to the node IP (`10.0.2.207`)
3. `10.0.0.2` responds to `10.0.2.207`
4. The response traverses iptables, which may route it back through CoreDNS
5. Loop detected → **forward plugin silently disabled**

When the forward plugin is disabled, the kubernetes plugin handles all queries
and returns NOERROR (empty answer) for names outside its zones.

Setting `AWS_VPC_K8S_CNI_EXTERNALSNAT=true` disables SNAT for pod traffic,
breaking the loop. After restarting CoreDNS with EXTERNALSNAT enabled, external
DNS resolution works.

### Why the kubernetes plugin returns NOERROR for external names

This is a secondary issue. Even without the loop problem, the kubernetes plugin
in CoreDNS 1.13.x appears to return `NOERROR` (instead of `NXDOMAIN`) for names
outside its configured zones when running in a `.:53` server block. This causes
`ndots:5` resolvers to stop searching after the first search domain attempt.

The `fallthrough in-addr.arpa ip6.arpa` directive should cause the kubernetes
plugin to return `NXDOMAIN` for non-existent `cluster.local` names, allowing
the resolver to try the bare name. However, this behavior was not observed —
the plugin returns `NOERROR` regardless.

**This secondary issue requires further investigation** with CoreDNS 1.13.x
source code and may require a different `fallthrough` configuration or a
CoreDNS version downgrade.

## Applied Fix

In `07-install-cni.sh`, after installing aws-vpc-cni:

```bash
kubectl set env daemonset aws-node -n kube-system AWS_VPC_K8S_CNI_EXTERNALSNAT=true
```

This must be set **before** CoreDNS starts (or CoreDNS must be restarted after).

## Remaining Work

1. Confirm that `EXTERNALSNAT=true` + CoreDNS restart fully resolves external
   DNS for EBS CSI and Karpenter on a fresh deployment.
2. Investigate the CoreDNS 1.13.x kubernetes plugin `NOERROR` behavior for
   external names — may need `fallthrough` without zone restrictions or a
   different CoreDNS configuration.
3. Consider NodeLocal DNSCache as a longer-term solution to avoid the loop
   detection issue entirely.
