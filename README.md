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
- a `ConfigMap` containing the manifest contents loaded from `flux_instance_path` and `prerequisites_paths`
- an optional write-only `Secret` in the bootstrap namespace containing `secrets_yaml`
- a `Job` that (in this order):
  - applies manifests from `prerequisites_paths` in the provided order with create-if-missing semantics
  - creates the target namespace from the manifest loaded from `flux_instance_path` if missing
  - reconciles `secrets_yaml` into the target namespace with server-side apply
  - installs the `flux-operator` Helm release if missing
  - applies the manifest loaded from `flux_instance_path` with create-if-missing semantics
  - optionally waits for the instance to become ready
  - deletes its temporary `ServiceAccount` and `ClusterRoleBinding` before exiting
- a host-side watcher that:
  - polls the Job every 2 seconds until it succeeds or fails
  - prints pod logs before failing Terraform if the Job fails or times out
  - deletes the Job after a watched run so the next apply can recreate it

`prerequisites_paths` and `secrets_yaml` exist to cover the bootstrap-time
resources that must be present inside the cluster before Flux, while still
keeping the long-term ownership boundaries explicit.

`prerequisites_paths` is intentionally create-if-missing only. It is meant for
bootstrap prerequisites that will later be adopted and managed by Flux or Flux
Operator, such as node pools or other scheduling prerequisites (e.g. when you
need a Karpenter `NodePool` dedicated for Flux).

`secrets_yaml` is different on purpose. Secrets passed through that input are
fully reconciled into the target namespace with server-side apply, so later
Terraform applies will correct drift for those Secrets instead of only creating
them once. This managed approach is intentional for bootstrap secrets, which
often include credentials that need to be rotated and kept up to date. It's
assumed that the source-of-truth for those Secrets is wired into Terraform
variables that ultimately feed into the `secrets_yaml` input, and the same
Secrets are **not applied** by Flux's kustomize-controller SOPS integration,
hence they require reconciliation. This design choice is based on the fact
that wiring SOPS-managed secrets into this Terraform input field could be
hard, impose chicken-and-egg problems, etc. It's recommended to keep the
secrets managed here as simple as possible, only secrets strictly required
for the `FluxInstance` to come up healthy.

The `kubernetes` input is only used by the default (but optional) host-side
`kubectl` watcher. Regardless of whether you use that watcher, callers must
still configure the HashiCorp Kubernetes provider for the module itself,
because the module creates Kubernetes resources such as the bootstrap
namespace, ConfigMap, and Job through that provider.

When `wait = true` and `use_kubectl_watcher = true` (the default), the machine
running Terraform must have `kubectl` and `bash` available in `PATH`. In this
mode the module uses a `null_resource` to watch the bootstrap Job, wire pod
logs into Terraform failures, and delete the Job at the end (the Job is deleted
so it can be recreated on the next apply, which allows it to run as a reconciler).

When `wait = true` and `use_kubectl_watcher = false`, the module skips the
host-side watcher and relies on the Terraform Kubernetes provider to wait for
Job completion. In that mode the Job gets a TTL and no host `kubectl` or
credentials are required (the HashiCorp Kubernetes provider still needs
credentials).

When `wait = false`, the module does not wait at all. The host-side watcher
is skipped, provider-side Job waiting is disabled, and the Job gets a TTL
for automatic cleanup.

TTL cleanup starts only after the Job reaches a terminal state (`Complete` or
`Failed`), not immediately after Terraform creates it.

## Usage

With the default host-side `kubectl` watcher:

```hcl
locals {
  ghcr_auth_dockerconfigjson = jsonencode({
    auths = {
      "ghcr.io" = {
        username = "flux"
        password = var.ghcr_token
        auth     = base64encode("flux:${var.ghcr_token}")
      }
    }
  })
}

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

  prerequisites_paths = [
    "${path.root}/clusters/staging/flux-system/eks-nodepools.yaml",
  ]

  secrets_yaml = <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: ghcr-auth
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: '${replace(local.ghcr_auth_dockerconfigjson, "'", "''")}'
YAML

  flux_instance_path = "${path.root}/clusters/staging/flux-system/flux-instance.yaml"
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
  ttl_after_finished  = "10m"

  prerequisites_paths = [
    "${path.root}/clusters/staging/flux-system/eks-nodepools.yaml",
  ]

  flux_instance_path = "${path.root}/clusters/staging/flux-system/flux-instance.yaml"
}
```

If your Terraform root module lives below the Git repo root, anchor manifest
paths from `path.root`, for example:

```text
repo/
├── clusters/staging/flux-system/flux-instance.yaml
└── terraform/
    └── main.tf  # path.root
```

```hcl
flux_instance_path = "${path.root}/../clusters/staging/flux-system/flux-instance.yaml"
```

## Inputs

- `flux_instance_path` (`Required`): absolute path to the FluxInstance manifest file; the module loads this file with `file()`
- `prerequisites_paths` (`Default: []`): ordered list of absolute paths to prerequisite manifest files; the module loads each file with `file()` and applies them with create-if-missing semantics before the target namespace is created
- `secrets_yaml` (`Default: ""`): optional multi-document Secret manifest YAML reconciled into the target namespace with server-side apply; all documents must be `Secret` objects and their namespace must be omitted or equal the FluxInstance namespace
- `use_kubectl_watcher` (`Default: true`): when `wait` is true, use the host-side `kubectl` watcher instead of provider-side Job waiting
- `kubernetes.host` (`Conditionally required`): Kubernetes API server host for the optional host-side watcher when `wait` and `use_kubectl_watcher` are true
- `kubernetes.cluster_ca_certificate` (`Conditionally required`): PEM-encoded cluster CA certificate for the optional host-side watcher when `wait` and `use_kubectl_watcher` are true
- `kubernetes.token` (`Conditionally required`): bearer token for the optional host-side watcher when `wait` and `use_kubectl_watcher` are true
- `bootstrap_namespace` (`Default: "flux-operator-bootstrap"`): namespace where the Terraform-managed bootstrap transport resources are created
- `image_repository` (`Default: "ghcr.io/matheuscscp/terraform-kubernetes-flux-operator-bootstrap"`): bootstrap job container image repository; override this for mirrored or air-gapped environments
- `image_tag` (`Required`): bootstrap job container image tag; keep this aligned with the module version and include the leading `v`
- `wait` (`Default: true`): master switch for waiting; enables `flux-operator wait instance` in the Job and Terraform-side waiting via the watcher or provider
- `timeout` (`Default: "5m"`): shared timeout for FluxInstance readiness waiting and Terraform Job resource timeouts
- `ttl_after_finished` (`Default: "5m"`): TTL for finished bootstrap Jobs whenever the host-side watcher will not delete the Job
- `debug_fault_injection_message` (`Default: ""`): testing-only fault injection that forces the Job to fail after printing the supplied message

**Note**: No sensitive inputs are stored in Terraform state.
