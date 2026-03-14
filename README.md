# terraform-kubernetes-flux-operator-bootstrap

Terraform module to bootstrap Flux Operator in a Kubernetes cluster with a Kubernetes Job.

The module creates:

- a dedicated bootstrap namespace
- a `ServiceAccount` for the bootstrap pod
- a `ClusterRoleBinding` granting `cluster-admin` to that `ServiceAccount`
- a `ConfigMap` containing the provided `FluxInstance` YAML
- a `Job` that:
  - installs the `flux-operator` Helm release if missing
  - applies the `FluxInstance` if missing
  - optionally waits for the instance to become ready
  - deletes its temporary `ServiceAccount` and `ClusterRoleBinding` before exiting
- a host-side watcher that:
  - polls the Job every 2 seconds until it succeeds or fails
  - prints pod logs before failing Terraform if the Job fails or times out
  - deletes the completed Job so the next apply can recreate it

The namespace referenced by the provided `FluxInstance` manifest is created by
the bootstrap Job if it does not already exist. Terraform does not manage that
target namespace directly.

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

## Usage

With the default host-side `kubectl` watcher:

```hcl
module "flux_operator_bootstrap" {
  source = "github.com/matheuscscp/terraform-kubernetes-flux-operator-bootstrap"

  kubernetes_host                   = data.aws_eks_cluster.this.endpoint
  kubernetes_cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  kubernetes_token                  = data.aws_eks_cluster_auth.this.token
  flux_instance_yaml                = file("${path.root}/clusters/staging/flux-system/flux-instance.yaml")
}
```

Without the host-side `kubectl` watcher:

```hcl
module "flux_operator_bootstrap" {
  source = "github.com/matheuscscp/terraform-kubernetes-flux-operator-bootstrap"

  use_kubectl_watcher = false
  ttl_after_finished  = "5m"

  flux_instance_yaml = file("${path.root}/clusters/staging/flux-system/flux-instance.yaml")
}
```

## Inputs

- `flux_instance_yaml`: FluxInstance manifest YAML text
- `use_kubectl_watcher`: when `wait` is true, use the host-side `kubectl` watcher instead of provider-side Job waiting
- `kubernetes_host`: Kubernetes API server host for the watcher when `wait` and `use_kubectl_watcher` are true
- `kubernetes_cluster_ca_certificate`: PEM-encoded cluster CA certificate for the watcher when `wait` and `use_kubectl_watcher` are true
- `kubernetes_token`: bearer token for the watcher when `wait` and `use_kubectl_watcher` are true
- `bootstrap_namespace`: namespace for Terraform-managed bootstrap resources
- `image.repository`: bootstrap job image repository
- `image.tag`: bootstrap job image tag
- `wait`: master switch for waiting; enables `flux-operator wait instance` in the Job and Terraform-side waiting via the watcher or provider
- `timeout`: global bootstrap wait timeout used by the script, watcher, and provider-side Job waiting
- `ttl_after_finished`: TTL for finished bootstrap Jobs when `use_kubectl_watcher` is false
- `debug_fault_injection_message`: testing-only fault injection that forces the job to fail after printing the supplied message
