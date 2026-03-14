# terraform-kubernetes-flux-operator-bootstrap

Terraform module to bootstrap Flux Operator in a Kubernetes cluster with a Kubernetes Job.

This module exists to solve the bootstrap ownership problem cleanly:
Terraform needs to get Flux Operator and a `FluxInstance` into the cluster, but
those resources are supposed to be continuously reconciled by Flux and Flux
Operator afterwards, not by Terraform.

The module keeps Terraform ownership limited to bootstrap-only transport
resources such as the bootstrap namespace, RBAC, mounted manifests, and the
bootstrap Job itself. The Job then performs the one-time bootstrap actions that
let Flux and Flux Operator take over steady-state reconciliation inside the
cluster.

That split is intentional:

- Terraform manages the bootstrap mechanism
- Flux and Flux Operator manage the steady-state GitOps resources afterwards

## Overview

The module creates:

- a dedicated bootstrap namespace
- a `ServiceAccount` for the bootstrap pod
- a `ClusterRoleBinding` granting `cluster-admin` to that `ServiceAccount`
- a `ConfigMap` containing the provided `FluxInstance` YAML and `prerequisites_yaml`
- an optional write-only `Secret` in the bootstrap namespace containing `secrets_yaml`
- a `Job` that (in this order):
  - applies `prerequisites_yaml` in the provided order with create-if-missing semantics
  - creates the target namespace from the `FluxInstance` if missing
  - reconciles `secrets_yaml` into the target namespace with server-side apply
  - installs the `flux-operator` Helm release if missing
  - applies the `FluxInstance` if missing
  - optionally waits for the instance to become ready
  - deletes its temporary `ServiceAccount` and `ClusterRoleBinding` before exiting
- a host-side watcher that:
  - polls the Job every 2 seconds until it succeeds or fails
  - prints pod logs before failing Terraform if the Job fails or times out
  - deletes the Job after a successful watched run so the next apply can recreate it

The namespace referenced by the provided `FluxInstance` manifest is created by
the bootstrap Job if it does not already exist. Terraform does not manage that
target namespace directly.

`prerequisites_yaml` and `secrets_yaml` exist to cover the bootstrap-time
resources that must be present inside the cluster before Flux, while still
keeping the long-term ownership boundaries explicit.

`prerequisites_yaml` is intentionally create-if-missing only. It is meant for
bootstrap prerequisites that will later be adopted and managed by Flux or Flux
Operator, such as node pools or other scheduling prerequisites (e.g. when you
need a Karpenter `NodePool` dedicated for Flux).

`secrets_yaml` is different on purpose. Secrets passed through that input are
fully reconciled into the target namespace with server-side apply, so later
Terraform applies will correct drift for those Secrets instead of only creating
them once. This managed approach is intentional for bootstrap secrets, which
often include credentials that need to be rotated and kept up to date. It's
assumed that the source-of-truth for those Secrets is wired into Terraform
variables that ultimately feed into the `secrets_yaml` input and that the same
Secrets are **not applied** by Flux's kustomize-controller SOPS integration,
hence they require reconciliation.

The `kubernetes` input is only used by the optional host-side `kubectl`
watcher. Regardless of whether you use that watcher, callers must still
configure the HashiCorp Kubernetes provider for the module itself, because the
module creates Kubernetes resources such as the bootstrap namespace, ConfigMap,
and Job through that provider.

When `wait = true` and `use_kubectl_watcher = true` (the default), the machine
running Terraform must have `kubectl` and `bash` available in `PATH`. In this
mode the module uses a `null_resource` to watch the bootstrap Job and wire pod
logs into Terraform failures.

When `wait = true` and `use_kubectl_watcher = false`, the module skips the
host-side watcher and relies on the Terraform Kubernetes provider to wait for
Job completion. In that mode the Job gets a TTL and no host `kubectl`
credentials are required.

When `wait = false`, the module does not wait at all. The host-side watcher is
skipped, provider-side Job waiting is disabled, and the finished Job is cleaned
up by TTL.

TTL cleanup starts only after the Job reaches a terminal state (`Complete` or
`Failed`), not immediately after Terraform creates it.

## Usage

With the default host-side `kubectl` watcher:

```hcl
provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

module "flux_operator_bootstrap" {
  source    = "matheuscscp/flux-operator-bootstrap/kubernetes"
  version   = "0.0.2"
  image_tag = "v0.0.2" # Keep image_tag aligned with the module version.

  # Required for the kubectl watcher.
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }

  prerequisites_yaml = [
    file("${path.root}/clusters/staging/flux-system/eks-nodepools.yaml"),
  ]

  secrets_yaml = <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: ghcr-auth
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: ${jsonencode({
    auths = {
      "ghcr.io" = {
        username = "flux"
        password = var.ghcr_token
        auth     = base64encode("flux:${var.ghcr_token}")
      }
    }
  })}
YAML

  flux_instance_yaml = file("${path.root}/clusters/staging/flux-system/flux-instance.yaml")
}
```

Without the host-side `kubectl` watcher:

```hcl
provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

module "flux_operator_bootstrap" {
  source    = "matheuscscp/flux-operator-bootstrap/kubernetes"
  version   = "0.0.2"
  image_tag = "v0.0.2" # Keep image_tag aligned with the module version.

  use_kubectl_watcher = false
  ttl_after_finished  = "5m"

  prerequisites_yaml = [
    file("${path.root}/clusters/staging/flux-system/eks-nodepools.yaml"),
  ]

  secrets_yaml = file("${path.root}/clusters/staging/flux-system/bootstrap-secrets.yaml")
  flux_instance_yaml = file("${path.root}/clusters/staging/flux-system/flux-instance.yaml")
}
```

## Inputs

- `flux_instance_yaml`: FluxInstance manifest YAML text
- `prerequisites_yaml`: ordered list of manifest YAML strings to apply with create-if-missing semantics before the target namespace is created
- `secrets_yaml`: multi-document Secret manifest YAML reconciled into the target namespace with server-side apply; all documents must be `Secret` objects and their namespace must be omitted or equal the FluxInstance namespace
- `use_kubectl_watcher`: when `wait` is true, use the host-side `kubectl` watcher instead of provider-side Job waiting
- `kubernetes.host`: Kubernetes API server host for the optional host-side watcher when `wait` and `use_kubectl_watcher` are true
- `kubernetes.cluster_ca_certificate`: PEM-encoded cluster CA certificate for the optional host-side watcher when `wait` and `use_kubectl_watcher` are true
- `kubernetes.token`: bearer token for the optional host-side watcher when `wait` and `use_kubectl_watcher` are true
- `bootstrap_namespace`: namespace for Terraform-managed bootstrap resources
- `image_tag`: bootstrap job image tag; this should match the module version with a leading `v`
- `wait`: master switch for waiting; enables `flux-operator wait instance` in the Job and Terraform-side waiting via the watcher or provider
- `timeout`: global bootstrap wait timeout used by the script, watcher, and provider-side Job waiting
- `ttl_after_finished`: TTL for finished bootstrap Jobs whenever the host-side watcher will not delete the Job
- `debug_fault_injection_message`: testing-only fault injection that forces the job to fail after printing the supplied message

**Note**: No sensitive inputs are stored in Terraform state.
