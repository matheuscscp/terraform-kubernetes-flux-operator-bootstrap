variable "flux_instance_yaml" {
  description = "The FluxInstance manifest YAML to bootstrap."
  type        = string
  nullable    = false

  validation {
    condition = (
      can(yamldecode(var.flux_instance_yaml)) &&
      try(yamldecode(var.flux_instance_yaml).apiVersion, "") == "fluxcd.controlplane.io/v1" &&
      try(yamldecode(var.flux_instance_yaml).kind, "") == "FluxInstance" &&
      try(length(yamldecode(var.flux_instance_yaml).metadata.name) > 0, false) &&
      try(length(yamldecode(var.flux_instance_yaml).metadata.namespace) > 0, false)
    )
    error_message = "flux_instance_yaml must be a FluxInstance manifest with metadata.name and metadata.namespace."
  }
}

variable "use_kubectl_watcher" {
  description = "Whether to use the host-side kubectl watcher when wait is true, instead of relying on the Terraform Kubernetes provider to wait for Job completion."
  type        = bool
  default     = true
}

variable "kubernetes_host" {
  description = "Kubernetes API server host used by the host-side watcher when wait and use_kubectl_watcher are true."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = !(var.wait && var.use_kubectl_watcher) || var.kubernetes_host != null
    error_message = "kubernetes_host must be set when wait and use_kubectl_watcher are true."
  }
}

variable "kubernetes_cluster_ca_certificate" {
  description = "PEM-encoded Kubernetes cluster CA certificate used by the host-side watcher when wait and use_kubectl_watcher are true."
  type        = string
  default     = null
  nullable    = true
  sensitive   = true

  validation {
    condition     = !(var.wait && var.use_kubectl_watcher) || var.kubernetes_cluster_ca_certificate != null
    error_message = "kubernetes_cluster_ca_certificate must be set when wait and use_kubectl_watcher are true."
  }
}

variable "kubernetes_token" {
  description = "Bearer token used by the host-side watcher when wait and use_kubectl_watcher are true."
  type        = string
  default     = null
  nullable    = true
  sensitive   = true

  validation {
    condition     = !(var.wait && var.use_kubectl_watcher) || var.kubernetes_token != null
    error_message = "kubernetes_token must be set when wait and use_kubectl_watcher are true."
  }
}

variable "bootstrap_namespace" {
  description = "Namespace where the Terraform-managed bootstrap resources are created."
  type        = string
  default     = "flux-operator-bootstrap"
  nullable    = false
}

variable "image" {
  description = "Bootstrap job container image configuration."
  type = object({
    repository = optional(string, "ghcr.io/controlplaneio-fluxcd/terraform-kubernetes-flux-operator-bootstrap")
    tag        = optional(string, "latest")
  })
  default  = {}
  nullable = false
}

variable "wait" {
  description = "Whether Terraform should wait for bootstrap completion. When true, the bootstrap script waits for a newly-created FluxInstance to become ready and Terraform waits via the kubectl watcher or provider-side Job waiting."
  type        = bool
  default     = true
}

variable "timeout" {
  description = "Timeout passed to 'flux-operator wait instance' and the Terraform job resource timeouts."
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
  description = "Testing-only fault injection message. When non-empty, the bootstrap job prints it and exits non-zero."
  type        = string
  default     = ""
  nullable    = false
}
