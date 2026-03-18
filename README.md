# terraform-kubernetes-flux-operator-bootstrap

Terraform module to bootstrap Flux Operator in a Kubernetes cluster with a Helm chart and a Kubernetes Job.

This module exists to solve the bootstrap ownership problem cleanly:
Terraform needs to get Flux Operator and a `FluxInstance` into the cluster, but
those resources are supposed to be continuously reconciled by Flux and Flux
Operator afterwards, not by Terraform.

The module keeps Terraform ownership limited to bootstrap-only transport
resources deployed via a local Helm chart: the bootstrap namespace, RBAC,
mounted manifests, and a bootstrap Job implemented as a Helm hook. The Job then
performs the one-time bootstrap actions that let Flux and Flux Operator take
over steady-state reconciliation inside the cluster.

That split is intentional:

- Terraform manages the bootstrap mechanism
- Flux and Flux Operator manage the steady-state GitOps resources afterwards

## Overview

The module deploys a local Helm chart via `helm_release` that creates:

- a dedicated bootstrap namespace
- a `ServiceAccount` for the bootstrap pod
- a `ClusterRoleBinding` granting `cluster-admin` to that `ServiceAccount`
- a `ConfigMap` containing the manifest contents loaded from `gitops_resources.flux_instance_path` and `gitops_resources.prerequisites_paths`
- an optional `Secret` in the bootstrap namespace containing `managed_resources.secrets_yaml` (passed via write-only Helm values, never stored in Terraform state)
- a `Job` (Helm hook: post-install, post-upgrade) that (in this order):
  - applies manifests from `gitops_resources.prerequisites_paths` in the provided order with create-if-missing semantics
  - creates the target namespace from the manifest loaded from `gitops_resources.flux_instance_path` if missing
  - reconciles `managed_resources.secrets_yaml` into the target namespace with server-side apply
  - installs the `flux-operator` Helm release if missing
  - applies the manifest loaded from `gitops_resources.flux_instance_path` with create-if-missing semantics
  - waits for the FluxInstance to become ready
  - deletes its temporary `ServiceAccount` and `ClusterRoleBinding` before exiting

The Helm release is upgraded on every `terraform apply`, which triggers the
post-upgrade hook and re-runs the bootstrap Job. Helm natively waits for the
hook Job to complete (or fail), so no external watcher is needed.

`gitops_resources` contains resources that will be reconciled by Flux after
bootstrap. They are applied with create-if-missing semantics so that Flux can
take ownership for steady-state reconciliation, such as node pools or other
scheduling prerequisites (e.g. when you need a Karpenter `NodePool` dedicated
for Flux).

`managed_resources` contains resources that are applied and reconciled by
Terraform on every apply. Unlike `gitops_resources`, these remain under
Terraform's ownership and will be updated to match the desired state on each
run. `managed_resources.secrets_yaml` is fully reconciled into the target
namespace with server-side apply, so later Terraform applies will correct
drift for those Secrets instead of only creating them once. This managed
approach is intentional for bootstrap secrets, which often include credentials
that need to be rotated and kept up to date. It's assumed that the
source-of-truth for those Secrets is wired into Terraform variables that
ultimately feed into `managed_resources.secrets_yaml`, and the same Secrets are
**not applied** by Flux's kustomize-controller SOPS integration, hence they
require reconciliation. This design choice is based on the fact that wiring
SOPS-managed secrets into this Terraform input field could be hard, impose
chicken-and-egg problems, etc. It's recommended to keep the secrets managed
here as simple as possible, only secrets strictly required for the
`FluxInstance` to come up healthy.

Callers must configure the HashiCorp Helm provider for the module, because
the module deploys the bootstrap Helm chart through that provider.

## Usage

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

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

module "flux_operator_bootstrap" {
  source  = "matheuscscp/flux-operator-bootstrap/kubernetes"

  gitops_resources = {
    flux_instance_path = "${path.root}/clusters/staging/flux-system/flux-instance.yaml"
    prerequisites_paths = [
      "${path.root}/clusters/staging/flux-system/eks-nodepools.yaml",
    ]
  }

  managed_resources = {
    secrets_yaml = <<-YAML
      apiVersion: v1
      kind: Secret
      metadata:
        name: ghcr-auth
      type: kubernetes.io/dockerconfigjson
      stringData:
        .dockerconfigjson: '${replace(local.ghcr_auth_dockerconfigjson, "'", "''")}'
    YAML
  }
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
gitops_resources = {
  flux_instance_path = "${path.root}/../clusters/staging/flux-system/flux-instance.yaml"
}
```

## Inputs

- `gitops_resources` (`Required`): resources that will be reconciled by Flux after bootstrap; applied with create-if-missing semantics so that Flux can take ownership for steady-state reconciliation
  - `.flux_instance_path` (`Required`): path to the FluxInstance manifest file; the module normalizes this path with `abspath()` and loads the file with `file()`
  - `.prerequisites_paths` (`Default: []`): ordered list of paths to prerequisite manifest files; the module normalizes each path with `abspath()` and loads each file with `file()`
- `managed_resources` (`Default: {}`): resources that are applied and reconciled by Terraform on every apply; unlike `gitops_resources`, these remain under Terraform's ownership and will be updated to match the desired state on each run
  - `.secrets_yaml` (`Default: ""`): optional multi-document Secret manifest YAML reconciled into the target namespace with server-side apply; all documents must be `Secret` objects and their namespace must be omitted or equal the FluxInstance namespace
- `bootstrap_namespace` (`Default: "flux-operator-bootstrap"`): namespace where the Terraform-managed bootstrap transport resources are created
- `image` (`Default: {}`): bootstrap job container image
  - `.repository` (`Default: "ghcr.io/matheuscscp/terraform-kubernetes-flux-operator-bootstrap"`): image repository; override for mirrored or air-gapped environments
  - `.tag` (`Default: module version`): image tag; defaults to the module version
  - `.pullPolicy` (`Default: "IfNotPresent"`): image pull policy
- `timeout` (`Default: "5m"`): shared timeout for FluxInstance readiness waiting and the Helm release timeout
- `debug_fault_injection_message` (`Default: ""`): testing-only fault injection that forces the Job to fail after printing the supplied message

**Note**: No sensitive inputs are stored in Terraform state.
