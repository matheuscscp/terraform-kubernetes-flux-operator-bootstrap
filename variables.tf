variable "flux_instance_path" {
  description = "Absolute path to the FluxInstance manifest file. The module loads this file with file() and bootstraps exactly that manifest."
  type        = string
  nullable    = false

  validation {
    condition = (
      var.flux_instance_path == abspath(var.flux_instance_path) &&
      can(file(var.flux_instance_path)) &&
      can(yamldecode(file(var.flux_instance_path))) &&
      try(yamldecode(file(var.flux_instance_path)).apiVersion, "") == "fluxcd.controlplane.io/v1" &&
      try(yamldecode(file(var.flux_instance_path)).kind, "") == "FluxInstance" &&
      try(length(yamldecode(file(var.flux_instance_path)).metadata.name) > 0, false) &&
      try(length(yamldecode(file(var.flux_instance_path)).metadata.namespace) > 0, false)
    )
    error_message = "flux_instance_path must be an absolute path to a readable FluxInstance manifest file with metadata.name and metadata.namespace."
  }
}

variable "prerequisites_paths" {
  description = "Ordered list of absolute paths to prerequisite manifest files. Each file is loaded with file() and applied with create-if-missing semantics before the target namespace is created."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([
      for path in var.prerequisites_paths :
      path == abspath(path) && can(file(path))
    ])
    error_message = "prerequisites_paths must contain only absolute paths to readable manifest files."
  }
}

variable "secrets_yaml" {
  description = "Optional multi-document Secret manifest YAML to reconcile into the Flux target namespace with server-side apply semantics. Each document must be a Secret, and its namespace must be omitted or match the FluxInstance namespace."
  type        = string
  default     = ""
  sensitive   = true
  nullable    = false
}

variable "use_kubectl_watcher" {
  description = "When wait is true, use the host-side kubectl watcher instead of relying on the Terraform Kubernetes provider to wait for Job completion."
  type        = bool
  default     = true
}

variable "kubernetes" {
  description = "Kubernetes API access for the optional host-side kubectl watcher. This is only used when wait and use_kubectl_watcher are both true."
  type = object({
    host                   = optional(string)
    cluster_ca_certificate = optional(string)
    token                  = optional(string)
  })
  sensitive = true
  default   = {}
  nullable  = false

  validation {
    condition = (
      !(var.wait && var.use_kubectl_watcher) || (
        try(var.kubernetes.host, null) != null &&
        try(var.kubernetes.cluster_ca_certificate, null) != null &&
        try(var.kubernetes.token, null) != null
      )
    )
    error_message = "kubernetes.host, kubernetes.cluster_ca_certificate, and kubernetes.token must be set when wait and use_kubectl_watcher are true."
  }
}

variable "bootstrap_namespace" {
  description = "Namespace where the Terraform-managed bootstrap transport resources are created."
  type        = string
  default     = "flux-operator-bootstrap"
  nullable    = false
}

variable "image_repository" {
  description = "Bootstrap job container image repository. Override this for mirrored or air-gapped environments."
  type        = string
  default     = "ghcr.io/matheuscscp/terraform-kubernetes-flux-operator-bootstrap"
  nullable    = false
}

variable "image_tag" {
  description = "Bootstrap job container image tag. Keep this aligned with the module version and include the leading v, for example v0.0.2."
  type        = string
  nullable    = false
}

variable "wait" {
  description = "Whether Terraform should wait for bootstrap completion. When true, the bootstrap Job waits for a newly-created FluxInstance to become ready and Terraform waits via the kubectl watcher or provider-side Job waiting."
  type        = bool
  default     = true
}

variable "timeout" {
  description = "Shared timeout for FluxInstance readiness waiting and the Terraform Job resource timeouts."
  type        = string
  default     = "5m"
}

variable "ttl_after_finished" {
  description = "TTL for finished bootstrap Jobs whenever the host-side kubectl watcher is not responsible for deleting the Job."
  type        = string
  default     = "5m"

  validation {
    condition     = length(regexall("^[0-9]+[smh]$", var.ttl_after_finished)) > 0
    error_message = "ttl_after_finished must be a duration like 30s, 5m, or 1h."
  }
}

variable "debug_fault_injection_message" {
  description = "Testing-only fault injection message. When non-empty, the bootstrap Job prints it and exits non-zero."
  type        = string
  default     = ""
  nullable    = false
}
