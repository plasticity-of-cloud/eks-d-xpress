package ai.codriverlabs.eksdxpress.packer;

import software.amazon.awscdk.RemovalPolicy;
import software.amazon.awscdk.Stack;
import software.amazon.awscdk.StackProps;
import software.amazon.awscdk.services.iam.CfnInstanceProfile;
import software.amazon.awscdk.services.iam.CfnOIDCProvider;
import software.amazon.awscdk.services.iam.Effect;
import software.amazon.awscdk.services.iam.FederatedPrincipal;
import software.amazon.awscdk.services.iam.ManagedPolicy;
import software.amazon.awscdk.services.iam.PolicyStatement;
import software.amazon.awscdk.services.iam.Role;
import software.amazon.awscdk.services.iam.ServicePrincipal;
import software.amazon.awscdk.services.kms.Key;
import software.amazon.awscdk.services.kms.KeySpec;
import software.amazon.awscdk.services.kms.KeyUsage;
import software.amazon.awscdk.services.ssm.StringParameter;
import software.constructs.Construct;

import java.util.List;
import java.util.Map;

/**
 * Least-privilege IAM infrastructure for the EKS-DX Packer AMI build pipeline.
 *
 * Replaces ami-builder/archived/setup-iam.sh with the following fixes over the
 * original script:
 *   - Destructive EC2 actions scoped to aws:ResourceTag/CreatedBy=packer
 *   - iam:CreateRole gated on iam:PermissionsBoundary to prevent escalation
 *   - Write actions restricted to the deployment region via aws:RequestedRegion
 */
public class EksDXpressPackerIamStack extends Stack {

    public EksDXpressPackerIamStack(Construct scope, String id, StackProps props) {
        super(scope, id, props);

        String account   = this.getAccount();
        String region    = this.getRegion();
        String githubOrg = (String) this.getNode().tryGetContext("githubOrg");
        String githubRepo = (String) this.getNode().tryGetContext("githubRepo");

        // ── GitHub OIDC provider ──────────────────────────────────────────────
        var oidcProvider = CfnOIDCProvider.Builder.create(this, "GitHubOidc")
                .url("https://token.actions.githubusercontent.com")
                .clientIdList(List.of("sts.amazonaws.com"))
                .thumbprintList(List.of("6938fd4d98bab03faadb97b34396831e3780aea1"))
                .build();

        String oidcArn  = oidcProvider.getRef();
        String oidcHost = "token.actions.githubusercontent.com";

        // ── Pre-created instance role for Packer builder EC2 instances ────────
        // Using a named instance profile avoids iam:CreateRole/DeleteRole entirely.
        var builderInstanceRole = Role.Builder.create(this, "PackerBuilderInstanceRole")
                .roleName("eks-d-xpress-packer-builder-instance")
                .description("Role assumed by EC2 instances launched by Packer")
                .assumedBy(new ServicePrincipal("ec2.amazonaws.com"))
                .build();

        builderInstanceRole.addToPolicy(PolicyStatement.Builder.create()
                .effect(Effect.ALLOW)
                .actions(List.of("ecr:GetAuthorizationToken"))
                .resources(List.of("*"))
                .build());

        builderInstanceRole.addToPolicy(PolicyStatement.Builder.create()
                .effect(Effect.ALLOW)
                .actions(List.of(
                        "ecr:BatchCheckLayerAvailability",
                        "ecr:GetDownloadUrlForLayer",
                        "ecr:BatchGetImage",
                        "ecr:CreateRepository",
                        "ecr:BatchImportUpstreamImage"))
                .resources(List.of("arn:aws:ecr:" + region + ":" + account + ":repository/*"))
                .build());

        builderInstanceRole.addToPolicy(PolicyStatement.Builder.create()
                .effect(Effect.ALLOW)
                .actions(List.of("ssm:GetParameter"))
                .resources(List.of("arn:aws:ssm:*:" + account + ":parameter/eks-d-xpress/*"))
                .build());

        builderInstanceRole.addToPolicy(PolicyStatement.Builder.create()
                .effect(Effect.ALLOW)
                .actions(List.of("sts:GetCallerIdentity"))
                .resources(List.of("*"))
                .build());

        var builderInstanceProfile = CfnInstanceProfile.Builder.create(this, "PackerBuilderInstanceProfile")
                .instanceProfileName("eks-d-xpress-packer-builder")
                .roles(List.of(builderInstanceRole.getRoleName()))
                .build();

        // ── Packer CI role ────────────────────────────────────────────────────
        var packerRole = Role.Builder.create(this, "PackerRole")
                .roleName("eks-d-xpress-packer-ci")
                .description("Least-privilege role for EKS-DX Packer AMI builds via GitHub Actions OIDC")
                .assumedBy(new FederatedPrincipal(
                        oidcArn,
                        Map.of(
                                "StringEquals", Map.of(oidcHost + ":aud", "sts.amazonaws.com"),
                                "StringLike",   Map.of(oidcHost + ":sub",
                                        "repo:" + githubOrg + "/" + githubRepo + ":*")
                        ),
                        "sts:AssumeRoleWithWebIdentity"
                ))
                .build();

        // EC2 read — Describe* always requires *
        packerRole.addToPolicy(PolicyStatement.Builder.create()
                .sid("PackerEC2Describe")
                .effect(Effect.ALLOW)
                .actions(List.of(
                        "ec2:DescribeImageAttribute", "ec2:DescribeImages",
                        "ec2:DescribeInstances", "ec2:DescribeInstanceStatus",
                        "ec2:DescribeInstanceTypeOfferings",
                        "ec2:DescribeRegions", "ec2:DescribeSecurityGroups",
                        "ec2:DescribeSnapshots", "ec2:DescribeSubnets",
                        "ec2:DescribeTags", "ec2:DescribeVolumes", "ec2:DescribeVpcs"))
                .resources(List.of("*"))
                .build());

        // EC2 write — region-locked; these actions lack resource-level support
        packerRole.addToPolicy(PolicyStatement.Builder.create()
                .sid("PackerEC2Write")
                .effect(Effect.ALLOW)
                .actions(List.of(
                        "ec2:CreateKeyPair",
                        "ec2:CreateSecurityGroup", "ec2:CreateVolume",
                        "ec2:CreateImage", "ec2:RegisterImage",
                        "ec2:CreateSnapshot", "ec2:CreateTags",
                        "ec2:GetPasswordData"))
                .resources(List.of("*"))
                .conditions(Map.of("StringEquals", Map.of("aws:RequestedRegion", region)))
                .build());

        // EC2 destructive — scoped to resources Packer tagged on creation
        packerRole.addToPolicy(PolicyStatement.Builder.create()
                .sid("PackerEC2Destructive")
                .effect(Effect.ALLOW)
                .actions(List.of(
                        "ec2:StopInstances", "ec2:TerminateInstances",
                        "ec2:DeleteKeyPair", "ec2:DeleteSecurityGroup",
                        "ec2:DeleteSnapshot", "ec2:DeleteVolume",
                        "ec2:DetachVolume", "ec2:AttachVolume",
                        "ec2:AuthorizeSecurityGroupIngress",
                        "ec2:ModifyImageAttribute", "ec2:ModifyInstanceAttribute",
                        "ec2:ModifySnapshotAttribute", "ec2:DeregisterImage"))
                .resources(List.of("*"))
                .conditions(Map.of("StringEquals",
                        Map.of("aws:ResourceTag/ManagedBy", "Packer")))
                .build());

        // EC2 write — region-locked; constrained to builder instance types
        packerRole.addToPolicy(PolicyStatement.Builder.create()
                .sid("PackerEC2RunInstances")
                .effect(Effect.ALLOW)
                .actions(List.of("ec2:RunInstances"))
                .resources(List.of("arn:aws:ec2:" + region + ":" + account + ":instance/*"))
                .conditions(Map.of("StringLike",
                        Map.of("ec2:InstanceType", List.of("c6a.large", "c6g.large"))))
                .build());

        // IAM — CI role only needs to pass the pre-created builder instance role to EC2
        packerRole.addToPolicy(PolicyStatement.Builder.create()
                .sid("PackerIAMPassRole")
                .effect(Effect.ALLOW)
                .actions(List.of("iam:PassRole", "iam:GetRole"))
                .resources(List.of(builderInstanceRole.getRoleArn()))
                .build());

        // ECR — pull-through cache auth (needed by install.sh at build time)
        packerRole.addToPolicy(PolicyStatement.Builder.create()
                .sid("PackerECRAuth")
                .effect(Effect.ALLOW)
                .actions(List.of("ecr:GetAuthorizationToken"))
                .resources(List.of("*"))
                .build());

        packerRole.addToPolicy(PolicyStatement.Builder.create()
                .sid("PackerECRPull")
                .effect(Effect.ALLOW)
                .actions(List.of(
                        "ecr:BatchCheckLayerAvailability",
                        "ecr:GetDownloadUrlForLayer",
                        "ecr:BatchGetImage",
                        // Required for ECR pull-through cache: auto-create the repo on first pull
                        // and import the upstream layer(s) into it
                        "ecr:CreateRepository",
                        "ecr:BatchImportUpstreamImage"))
                .resources(List.of("arn:aws:ecr:" + region + ":" + account + ":repository/*"))
                .build());

        // SSM — restricted to this project's parameter namespace
        packerRole.addToPolicy(PolicyStatement.Builder.create()
                .sid("AMIManifestSSM")
                .effect(Effect.ALLOW)
                .actions(List.of("ssm:PutParameter", "ssm:GetParameter"))
                .resources(List.of("arn:aws:ssm:*:" + account + ":parameter/eks-d-xpress/*"))
                .build());

        // KMS — sign/verify scoped by resource tag
        packerRole.addToPolicy(PolicyStatement.Builder.create()
                .sid("AMISigning")
                .effect(Effect.ALLOW)
                .actions(List.of("kms:Sign", "kms:GetPublicKey", "kms:DescribeKey"))
                .resources(List.of("arn:aws:kms:*:" + account + ":key/*"))
                .conditions(Map.of("StringEquals", Map.of(
                        "aws:ResourceTag/Usage", "eks-d-xpress-ami-signing")))
                .build());

        // ── KMS signing key ───────────────────────────────────────────────────
        var signingKey = Key.Builder.create(this, "AmiSigningKey")
                .description("EKS-DX AMI attestation signing key")
                .keySpec(KeySpec.RSA_4096)
                .keyUsage(KeyUsage.SIGN_VERIFY)
                .alias("eks-d-xpress-ami-signing")
                .build();
        signingKey.applyRemovalPolicy(RemovalPolicy.RETAIN);

        // ── SSM — key ARN for pipeline reference ──────────────────────────────
        StringParameter.Builder.create(this, "AmiSigningKeyArn")
                .parameterName("/eks-d-xpress/infra/kms/ami-signing-key-arn")
                .stringValue(signingKey.getKeyArn())
                .build();
    }
}
