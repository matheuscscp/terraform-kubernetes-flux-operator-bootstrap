FROM ghcr.io/controlplaneio-fluxcd/flux-operator-cli:v0.44.0@sha256:63521eeb823e79abd6874d6e1b4b13e92e2df6f873fd036bc34e48a5e8a8a147 AS flux-operator-cli

FROM alpine:3.23@sha256:25109184c71bdad752c8312a8623239686a9a2071e8825f20acb8f2198c3f659 AS builder

ARG KUBECTL_VERSION=v1.35.0
ARG HELM_VERSION=v4.1.3
ARG TARGETOS=linux
ARG TARGETARCH=amd64

COPY --from=flux-operator-cli /usr/local/bin/flux-operator /out/usr/local/bin/flux-operator

RUN apk add --no-cache bash ca-certificates curl tar gzip && \
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-${TARGETOS}-${TARGETARCH}.tar.gz" | tar -xz -C /tmp && \
    mv "/tmp/${TARGETOS}-${TARGETARCH}/helm" /out/usr/local/bin/helm && \
    curl -fsSL -o /out/usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${TARGETOS}/${TARGETARCH}/kubectl" && \
    chmod +x /out/usr/local/bin/flux-operator /out/usr/local/bin/helm /out/usr/local/bin/kubectl

COPY scripts/bootstrap.sh /out/usr/local/bin/bootstrap.sh
RUN chmod +x /out/usr/local/bin/bootstrap.sh

FROM busybox:1.37.0-musl@sha256:19b646668802469d968a05342a601e78da4322a414a7c09b1c9ee25165042138 AS busybox

FROM gcr.io/distroless/static-debian12:nonroot@sha256:a9329520abc449e3b14d5bc3a6ffae065bdde0f02667fa10880c49b35c109fd1

COPY --from=builder --chown=nonroot:nonroot /out/ /
COPY --from=busybox --chown=nonroot:nonroot /bin/busybox /busybox/busybox

RUN ["/usr/local/bin/helm", "version", "--short"]
RUN ["/usr/local/bin/kubectl", "version", "--client"]
RUN ["/usr/local/bin/flux-operator", "--version"]
RUN ["/busybox/busybox", "sh", "-n", "/usr/local/bin/bootstrap.sh"]

ENTRYPOINT ["/busybox/busybox", "sh", "/usr/local/bin/bootstrap.sh"]
