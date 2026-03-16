# Custom image for Red Hat Connectivity Link NS Delegation Job
# Combines: oc (OpenShift CLI) + aws-cli + jq

FROM registry.redhat.io/openshift4/ose-cli:latest

LABEL maintainer="Red Hat Connectivity Link"
LABEL description="OpenShift CLI with AWS CLI and jq for Route53 automation"

USER root

# Install AWS CLI v2
RUN curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscli.zip && \
    python3 -m zipfile -e /tmp/awscli.zip /tmp && \
    /tmp/aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli && \
    rm -rf /tmp/aws /tmp/awscli.zip

# Install jq
RUN curl -sL "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64" -o /usr/local/bin/jq && \
    chmod +x /usr/local/bin/jq

# Verify installations
RUN echo "=== Installed Tools ===" && \
    aws --version && \
    jq --version && \
    oc version --client --short

USER 1001

# Default to bash
CMD ["/bin/bash"]
