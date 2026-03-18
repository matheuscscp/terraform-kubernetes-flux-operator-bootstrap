variable "gitops_resources" {
  description = "Resources that will be reconciled by Flux after bootstrap. These are applied with create-if-missing semantics so that Flux can take ownership of them for steady-state reconciliation."
  type = object({
    flux_instance_path  = string
    prerequisites_paths = optional(list(string), [])
  })
  nullable = false

  validation {
    condition = (
      can(file(abspath(var.gitops_resources.flux_instance_path))) &&
      can(yamldecode(file(abspath(var.gitops_resources.flux_instance_path)))) &&
      try(yamldecode(file(abspath(var.gitops_resources.flux_instance_path))).apiVersion, "") == "fluxcd.controlplane.io/v1" &&
      try(yamldecode(file(abspath(var.gitops_resources.flux_instance_path))).kind, "") == "FluxInstance" &&
      try(length(yamldecode(file(abspath(var.gitops_resources.flux_instance_path))).metadata.name) > 0, false) &&
      try(length(yamldecode(file(abspath(var.gitops_resources.flux_instance_path))).metadata.namespace) > 0, false)
    )
    error_message = "gitops_resources.flux_instance_path must point to a readable FluxInstance manifest file with metadata.name and metadata.namespace."
  }

  validation {
    condition = alltrue([
      for path in var.gitops_resources.prerequisites_paths :
      can(file(abspath(path)))
    ])
    error_message = "gitops_resources.prerequisites_paths must contain only readable manifest files."
  }
}

variable "managed_resources" {
  description = "Resources that are applied and reconciled by Terraform on every apply. Unlike gitops_resources, these remain under Terraform's ownership and will be updated to match the desired state on each run."
  type = object({
    secrets_yaml = optional(string, "")
  })
  sensitive = true
  default   = {}
  nullable  = false
}

variable "bootstrap_namespace" {
  description = "Namespace where the Terraform-managed bootstrap transport resources are created."
  type        = string
  default     = "flux-operator-bootstrap"
  nullable    = false
}

variable "image" {
  description = "Bootstrap job container image."
  type = object({
    repository = optional(string, "ghcr.io/matheuscscp/terraform-kubernetes-flux-operator-bootstrap")
    tag        = optional(string)
    pullPolicy = optional(string, "IfNotPresent")
  })
  default  = {}
  nullable = false
}

variable "timeout" {
  description = "Shared timeout for FluxInstance readiness waiting and the Helm release timeout."
  type        = string
  default     = "5m"
}

variable "debug_fault_injection_message" {
  description = "Testing-only fault injection message. When non-empty, the bootstrap Job prints it and exits non-zero."
  type        = string
  default     = ""
  nullable    = false
}
