# terraform-kubernetes-flux-operator-bootstrap

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
- a `ConfigMap` containing the `FluxInstance` manifest, prerequisite manifests, and optional runtime info
- an optional write-only `Secret` containing the managed secrets YAML (managed by `kubernetes_secret_v1` with `data_wo`, never stored in Terraform state)
- a `Job` (Helm hook: post-install, post-upgrade) that:
  - applies prerequisite manifests with create-if-missing semantics
  - creates the `FluxInstance` target namespace if missing
  - reconciles managed resources (secrets and runtime-info `ConfigMap`) into the target namespace with server-side apply, stripping disallowed field managers (`kubectl`, `before-first-apply`) before applying; tracks them in an inventory `ConfigMap` and garbage-collects removed entries
  - if `runtime_info` is provided, substitutes `${variable}` references in the `FluxInstance` manifest using `flux envsubst`
  - unlocks the `flux-operator` Helm release if stuck in a pending state from a previous failed attempt
  - installs the `flux-operator` Helm release if missing, or deletes and reinstalls if in a failed state
  - applies the `FluxInstance` manifest with create-if-missing semantics
  - waits for the `FluxInstance` to become ready
  - cleans up bootstrap transport resources (`ConfigMap`, `ServiceAccount`, `ClusterRoleBinding`) leaving only the completed `Job`, inventory `ConfigMap`, and managed `Secret` in the bootstrap namespace

The Helm release is upgraded (re-running the bootstrap `Job`) when any input
content changes or when the `revision` input is bumped. When all inputs are
unchanged, `terraform plan` shows zero diff. Helm waits for the hook `Job` to
complete (or fail) before returning.

The module does not use `upgrade_install`, which means the Helm provider does
not need to connect to the cluster during planning. This allows the module to
be used in the same Terraform root module that creates the cluster.

`gitops_resources` are resources meant to be reconciled by Flux after bootstrap,
such as the `FluxInstance` manifest and scheduling prerequisites (e.g. Karpenter
`NodePool`s). These are applied with create-if-missing semantics so that Flux
can take ownership for steady-state reconciliation.

`managed_resources` are resources that remain under Terraform's ownership and
are reconciled on every bootstrap run. `managed_resources.secrets_yaml` is
reconciled into the target namespace with server-side apply.
`managed_resources.runtime_info` is applied as a `ConfigMap` named
`runtime-info` in the target namespace and its key-value pairs are substituted
into the `FluxInstance` manifest before the initial apply. This enables
Flux's `Kustomization.spec.postBuild` variable substitution for the
`FluxInstance` itself by referencing the same `ConfigMap` via
`spec.postBuild.substituteFrom`.

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
  version = "0.0.18"

  revision = var.bootstrap_revision

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
    runtime_info = {
      cluster_name = "staging"
      cluster_region = "eu-west-2"
    }
  }
}
```

### Runtime info and variable substitution

When `managed_resources.runtime_info` is set, the bootstrap job:

1. Creates a `ConfigMap` named `runtime-info` in the `FluxInstance` target
   namespace with the provided key-value pairs
2. Substitutes `${variable}` references in the `FluxInstance` manifest using
   `flux envsubst --strict` before the initial apply

This allows the `FluxInstance` manifest to use variable references like
`${cluster_name}` that are resolved at bootstrap time. For steady-state
reconciliation, configure the Flux sync `Kustomization` to reference the same
`ConfigMap` via `spec.postBuild.substituteFrom`.

### Same-module cluster creation

The module can be used in the same Terraform root module that creates the
cluster. Since `upgrade_install` is disabled, the Helm provider does not
require cluster connectivity during planning:

```hcl
module "eks" {
  source = "terraform-aws-modules/eks/aws"
  # ...
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

module "flux_operator_bootstrap" {
  depends_on = [module.eks]
  source     = "matheuscscp/flux-operator-bootstrap/kubernetes"
  version    = "0.0.18"
  revision   = 1
  # ...
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

- `revision` (`Required`): revision number for manually triggering a bootstrap re-run; the bootstrap job also runs automatically when any input content changes (secrets, runtime info, gitops resources); bump revision to force a re-run without changing content; when all inputs are unchanged, `terraform plan` shows zero diff
- `gitops_resources` (`Required`): resources applied with create-if-missing semantics, meant to be reconciled by Flux after bootstrap
  - `.flux_instance_path` (`Required`): path to the `FluxInstance` manifest file; normalized with `abspath()` and loaded with `file()`; may contain `${variable}` references that are substituted using `runtime_info` values
  - `.prerequisites_paths` (`Default: []`): ordered list of paths to prerequisite manifest files; each normalized with `abspath()` and loaded with `file()`
- `managed_resources` (`Default: {}`): resources reconciled by the bootstrap job on every run
  - `.secrets_yaml` (`Default: ""`): multi-document Secret manifest YAML reconciled into the target namespace with server-side apply; all documents must be `Secret` objects and their namespace must be omitted or equal the `FluxInstance` namespace
  - `.runtime_info` (`Default: {}`): key-value pairs applied as a `ConfigMap` named `runtime-info` in the target namespace and substituted into the `FluxInstance` manifest via `flux envsubst`; tracked in inventory and garbage-collected when removed
- `bootstrap_namespace` (`Default: "flux-operator-bootstrap"`): namespace for the bootstrap transport resources
- `image` (`Default: {}`): bootstrap job container image
  - `.repository` (`Default: "ghcr.io/matheuscscp/terraform-kubernetes-flux-operator-bootstrap"`): image repository; override for mirrored or air-gapped environments
  - `.tag` (`Default: module version`): image tag; defaults to the module version
  - `.pullPolicy` (`Default: "IfNotPresent"`): image pull policy
- `timeout` (`Default: "5m"`): timeout for `FluxInstance` readiness waiting and the Helm release

**Note**: Secrets are not stored in the Terraform state. Managed resources
(secrets and runtime-info `ConfigMap`) are reconciled with server-side apply
and disallowed field managers (`kubectl`, `before-first-apply`) are
automatically stripped before applying, following the same approach as
Flux's kustomize-controller.
