# terraform-kubernetes-flux-operator-bootstrap
test
Terraform module that bootstraps Flux Operator in a Kubernetes cluster using a
local Helm chart with a bootstrap `Job`.

This module solves the bootstrap ownership problem: Terraform needs to get Flux
Operator and a `FluxInstance` into the cluster, but those resources should be
continuously reconciled by Flux afterwards, not by Terraform.

The module keeps Terraform ownership limited to ephemeral bootstrap transport
resources: the bootstrap namespace, RBAC, mounted manifests, and a bootstrap
`Job` implemented as a Helm hook. The `Job` performs the idempotent bootstrap
actions that let Flux and Flux Operator take over steady-state reconciliation.

- Terraform manages the bootstrap mechanism
- Flux and Flux Operator manage the steady-state GitOps resources afterwards

## Overview

The module deploys a local Helm chart via `helm_release` that creates:

- a dedicated bootstrap namespace
- a `ServiceAccount` for the bootstrap pod
- a `ClusterRoleBinding` granting `cluster-admin` to that `ServiceAccount`
- a `ConfigMap` containing the `FluxInstance` manifest and prerequisite manifests
- an optional write-only `Secret` containing the managed secrets YAML (managed by `kubernetes_secret_v1` with `data_wo`, never stored in Terraform state)
- a `Job` (Helm hook: post-install, post-upgrade) that:
  - applies prerequisite manifests with create-if-missing semantics
  - creates the `FluxInstance` target namespace if missing
  - reconciles managed secrets into the target namespace with server-side apply
  - unlocks the `flux-operator` Helm release if stuck in a pending state from a previous failed attempt
  - installs the `flux-operator` Helm release if missing, or deletes and reinstalls if in a failed state
  - applies the `FluxInstance` manifest with create-if-missing semantics
  - waits for the `FluxInstance` to become ready
  - cleans up all bootstrap transport resources (`ConfigMap`, `Secret`, `ServiceAccount`, `ClusterRoleBinding`) leaving only the completed `Job` and inventory `ConfigMap` in the bootstrap namespace

The Helm release is upgraded on every `terraform apply`, which re-runs the
bootstrap `Job`. Helm waits for the hook `Job` to complete (or fail) before
returning.

`gitops_resources` are resources meant to be reconciled by Flux after bootstrap,
such as the `FluxInstance` manifest and scheduling prerequisites (e.g. Karpenter
`NodePool`s). These are applied with create-if-missing semantics so that Flux
can take ownership for steady-state reconciliation.

`managed_resources` are resources that remain under Terraform's ownership and
are reconciled on every apply. `managed_resources.secrets_yaml` is fully
reconciled into the target namespace with server-side apply, so Terraform
applies will correct drift. This is intended for bootstrap secrets such as
registry credentials that need to be rotated and kept up to date. Keep the
secrets managed here minimal — only what is strictly required for the
`FluxInstance` to come up healthy.

Callers must configure the HashiCorp Helm and Kubernetes providers for the
module.

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

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

module "flux_operator_bootstrap" {
  source  = "matheuscscp/flux-operator-bootstrap/kubernetes"
  version = "0.0.16"

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
paths with `path.root`, for example:

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

- `gitops_resources` (`Required`): resources applied with create-if-missing semantics, meant to be reconciled by Flux after bootstrap
  - `.flux_instance_path` (`Required`): path to the `FluxInstance` manifest file; normalized with `abspath()` and loaded with `file()`
  - `.prerequisites_paths` (`Default: []`): ordered list of paths to prerequisite manifest files; each normalized with `abspath()` and loaded with `file()`
- `managed_resources` (`Default: {}`): resources reconciled by Terraform on every apply
  - `.secrets_yaml` (`Default: ""`): multi-document Secret manifest YAML reconciled into the target namespace with server-side apply; all documents must be `Secret` objects and their namespace must be omitted or equal the `FluxInstance` namespace
- `bootstrap_namespace` (`Default: "flux-operator-bootstrap"`): namespace for the bootstrap transport resources
- `image` (`Default: {}`): bootstrap job container image
  - `.repository` (`Default: "ghcr.io/matheuscscp/terraform-kubernetes-flux-operator-bootstrap"`): image repository; override for mirrored or air-gapped environments
  - `.tag` (`Default: module version`): image tag; defaults to the module version
  - `.pullPolicy` (`Default: "IfNotPresent"`): image pull policy
- `timeout` (`Default: "5m"`): timeout for `FluxInstance` readiness waiting and the Helm release

**Note**: Secrets are not stored in the Terraform state.
