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

variable "kubernetes" {
  description = "Kubernetes API access used by the host-side watcher when wait and use_kubectl_watcher are true."
  type = object({
    host                   = optional(string)
    cluster_ca_certificate = optional(string)
    token                  = optional(string)
  })
  default  = {}
  nullable = false

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
