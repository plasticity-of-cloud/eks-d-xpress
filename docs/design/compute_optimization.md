# Compute Optimization Design

## TODO List

### 1. Spot Instances with Hibernation for Control Plane
**Priority**: High  
**Impact**: 57% cost reduction ($132 → $57/month)

- [ ] **AWS Instance Scheduler Integration**
  - Leverage AWS Instance Scheduler solution for automated start/stop
  - Support business hours scheduling (9-5 weekdays)
  
- [ ] **Hibernation Support**
  - Enable hibernation on m6g.xlarge instances
  - EBS-backed hibernation for instant resume (~30 seconds)
  - Preserve etcd state and cluster configuration
  
- [ ] **Spot Instance Migration**
  - Convert control plane to Spot instances (60-90% savings)
  - Implement Spot interruption handling with 2-minute warning
  - Automatic fallback to On-Demand if Spot unavailable
  
- [ ] **Fully Managed by AWS**
  - Use AWS Instance Scheduler CloudFormation template
  - CloudWatch Events + Lambda for automation
  - No custom scripts or manual intervention required

### 2. State Persistence During Hibernation
- [ ] Ensure etcd data survives hibernation cycles
- [ ] Preserve Karpenter state and node registrations  
- [ ] Maintain cluster certificates and tokens
- [ ] Handle certificate rotation during extended hibernation

### 3. Developer Experience Optimization
- [ ] Resume time <60 seconds from hibernation
- [ ] Integration with developer calendars for predictive start
- [ ] Slack/Teams notifications for cluster status
- [ ] Git activity-based intelligent scheduling

## Success Metrics
- **Cost Reduction**: 50-60% savings vs. always-on
- **Resume Time**: <60 seconds from hibernation
- **Availability**: >99% during business hours
- **Automation**: 95% hands-off operation

## Implementation Timeline
- **Phase 1**: Basic hibernation support (Q2 2026)
- **Phase 2**: Spot integration with AWS Instance Scheduler (Q3 2026)
- **Phase 3**: Intelligent scheduling and optimization (Q4 2026)
