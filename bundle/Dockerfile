FROM public.ecr.aws/amazoncorretto/amazoncorretto:25.0.3-al2023-headless

RUN dnf install -y nodejs22 npm maven unzip tar gzip findutils python3 && dnf clean all

# AWS CLI v2
RUN curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscli.zip \
    && unzip -q /tmp/awscli.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscli.zip

# CDK CLI + Helm
RUN npm install -g aws-cdk \
    && curl -sL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

WORKDIR /opt/eks-dx

# Infra: tarball includes pre-synthesized cdk.out + helper scripts
COPY infra-cdk/ ./

# Control-plane: source only — build and synthesize at image build time
COPY control-plane-cdk/ ./control-plane/
RUN cd /opt/eks-dx/control-plane/infra \
    && mvn package -q -DskipTests \
    && cdk synth --output /opt/eks-dx/control-plane/cdk.out

# AMI manifest
COPY ami-manifest.json ./ami-manifest.json

# Helm charts
COPY helm/ ./helm/

# CLI binary (arch-matched via buildx)
COPY eks-dx-cli ./bin/eks-dx
RUN chmod +x ./bin/eks-dx

# Orchestrator
COPY deploy.sh ./deploy.sh
RUN chmod +x ./deploy.sh

ENV PATH="/opt/eks-dx/bin:${PATH}"

ENTRYPOINT ["/opt/eks-dx/deploy.sh"]
CMD ["--help"]
