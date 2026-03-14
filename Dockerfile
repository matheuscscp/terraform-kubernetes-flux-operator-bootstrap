FROM ghcr.io/controlplaneio-fluxcd/flux-operator-cli:v0.43.0@sha256:60fb838282d605c9bdb417b830e8e690ec9300989b1a7ceaf6bbbf4589362355 AS flux-operator-cli

FROM alpine:3.20@sha256:a4f4213abb84c497377b8544c81b3564f313746700372ec4fe84653e4fb03805 AS builder

ARG HELM_VERSION=v4.1.3
ARG KUBECTL_VERSION=v1.35.2
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

FROM busybox:1.36.1-musl@sha256:3c6ae8008e2c2eedd141725c30b20d9c36b026eb796688f88205845ef17aa213 AS busybox

FROM gcr.io/distroless/static-debian12:nonroot@sha256:a9329520abc449e3b14d5bc3a6ffae065bdde0f02667fa10880c49b35c109fd1

COPY --from=builder --chown=nonroot:nonroot /out/ /
COPY --from=busybox --chown=nonroot:nonroot /bin/busybox /busybox/busybox

RUN ["/usr/local/bin/helm", "version", "--short"]
RUN ["/usr/local/bin/kubectl", "version", "--client"]
RUN ["/usr/local/bin/flux-operator", "--version"]
RUN ["/busybox/busybox", "sh", "-n", "/usr/local/bin/bootstrap.sh"]

ENTRYPOINT ["/busybox/busybox", "sh", "/usr/local/bin/bootstrap.sh"]
