#!/usr/bin/env bash
set -euo pipefail

export NO_COLOR=1

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cluster_name="flux-operator-bootstrap-e2e"
image_repository="terraform-kubernetes-flux-operator-bootstrap"
image_tag="dev"
image="${image_repository}:${image_tag}"
success_tf_dir="$(mktemp -d)"
provider_wait_tf_dir="$(mktemp -d)"
no_wait_tf_dir="$(mktemp -d)"
failure_tf_dir="$(mktemp -d)"
failure_apply_log=""
kubernetes_host=""
kubernetes_cluster_ca_certificate=""
kubernetes_token=""

section() {
  title="$1"
  printf '\n========== %s ==========\n' "${title}"
}

note() {
  printf '[e2e] %s\n' "$1"
}

kubectl_get_flux_operator_resources() {
  kubectl --context "kind-${cluster_name}" get \
    fluxinstances.fluxcd.controlplane.io,fluxreports.fluxcd.controlplane.io \
    -A || true
}

assert_flux_runtime_ready() {
  kubectl --context "kind-${cluster_name}" -n flux-system wait \
    --for=condition=Ready \
    fluxinstance.fluxcd.controlplane.io/flux \
    --timeout=120s >/dev/null

  kubectl --context "kind-${cluster_name}" -n flux-system rollout status \
    deployment/flux-operator \
    --timeout=120s >/dev/null

  kubectl --context "kind-${cluster_name}" -n flux-system rollout status \
    deployment/source-controller \
    --timeout=120s >/dev/null
}

dump_bootstrap_logs() {
  namespace="$1"

  kubectl --context "kind-${cluster_name}" -n "${namespace}" get jobs,pods || true

  if kubectl --context "kind-${cluster_name}" -n "${namespace}" get job flux-operator-bootstrap >/dev/null 2>&1; then
    kubectl --context "kind-${cluster_name}" -n "${namespace}" logs job/flux-operator-bootstrap || true
    kubectl --context "kind-${cluster_name}" -n "${namespace}" describe job flux-operator-bootstrap || true
  fi
}

cleanup() {
  kind delete cluster --name "${cluster_name}" || true
  rm -rf "${success_tf_dir}" "${provider_wait_tf_dir}" "${no_wait_tf_dir}" "${failure_tf_dir}"
}

trap cleanup EXIT

render_root_module() {
  tf_dir="$1"
  bootstrap_namespace="$2"
  fault_injection_message="$3"
  use_kubectl_watcher="$4"
  ttl_after_finished="$5"
  wait="$6"
  watcher_inputs=""

  if [ "${use_kubectl_watcher}" = "true" ] && [ "${wait}" = "true" ]; then
    watcher_inputs=$(cat <<EOF
  kubernetes_host = "${kubernetes_host}"
  kubernetes_cluster_ca_certificate = <<PEM
${kubernetes_cluster_ca_certificate}
PEM
  kubernetes_token = "${kubernetes_token}"
EOF
)
  fi

  cat > "${tf_dir}/main.tf" <<EOF
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.38.0"
    }
  }
}

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "kind-${cluster_name}"
}

module "bootstrap" {
  source = "${repo_root}"

  bootstrap_namespace = "${bootstrap_namespace}"
  use_kubectl_watcher = ${use_kubectl_watcher}
  wait                = ${wait}
  ttl_after_finished  = "${ttl_after_finished}"
${watcher_inputs}

  image = {
    repository = "${image_repository}"
    tag        = "${image_tag}"
  }

  debug_fault_injection_message = "${fault_injection_message}"

  flux_instance_yaml = <<YAML
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
spec:
  components:
  - source-controller
  distribution:
    version: 2.x
    registry: ghcr.io/fluxcd
YAML
}
EOF
}

section "Cluster Setup"
note "Resetting kind cluster ${cluster_name}"
kind delete cluster --name "${cluster_name}" || true
note "Creating kind cluster ${cluster_name}"
kind create cluster --name "${cluster_name}"
note "Loading locally built image ${image}"
kind load docker-image "${image}" --name "${cluster_name}"
note "Creating short-lived watcher credentials"
kubectl --context "kind-${cluster_name}" create namespace watcher-auth --dry-run=client -o yaml | kubectl --context "kind-${cluster_name}" apply -f -
kubectl --context "kind-${cluster_name}" -n watcher-auth create serviceaccount terraform-watcher --dry-run=client -o yaml | kubectl --context "kind-${cluster_name}" apply -f -
kubectl --context "kind-${cluster_name}" create clusterrolebinding terraform-watcher-cluster-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=watcher-auth:terraform-watcher \
  --dry-run=client -o yaml | kubectl --context "kind-${cluster_name}" apply -f -
kubernetes_host="$(kubectl config view --raw -o jsonpath='{.clusters[?(@.name=="kind-'"${cluster_name}"'")].cluster.server}')"
kubernetes_cluster_ca_certificate="$(kubectl config view --raw -o jsonpath='{.clusters[?(@.name=="kind-'"${cluster_name}"'")].cluster.certificate-authority-data}' | base64 --decode)"
kubernetes_token="$(kubectl --context "kind-${cluster_name}" -n watcher-auth create token terraform-watcher)"

section "Happy Path"
note "Rendering success scenario Terraform root"
render_root_module "${success_tf_dir}" "flux-operator-bootstrap" "" "true" "5m" "true"
note "Initializing success scenario"
terraform -chdir="${success_tf_dir}" init -no-color -backend=false

note "Running initial bootstrap apply"
terraform -chdir="${success_tf_dir}" apply -no-color -auto-approve
note "Verifying FluxInstance and Flux workloads are ready"
assert_flux_runtime_ready

section "Idempotency"
note "Running second bootstrap apply to verify idempotent rerun"
terraform -chdir="${success_tf_dir}" apply -no-color -auto-approve
note "Re-verifying Flux runtime after idempotent rerun"
assert_flux_runtime_ready

section "Destroy Behavior"
note "Capturing Flux resources before destroy"
before_destroy_log="${success_tf_dir}/before-destroy.log"
after_destroy_log="${success_tf_dir}/after-destroy.log"
kubectl_get_flux_operator_resources | tee "${before_destroy_log}"
kubectl --context "kind-${cluster_name}" -n flux-system get fluxinstance.fluxcd.controlplane.io/flux >/dev/null

note "Destroying happy-path bootstrap root"
terraform -chdir="${success_tf_dir}" destroy -no-color -auto-approve

note "Capturing Flux resources after destroy"
kubectl_get_flux_operator_resources | tee "${after_destroy_log}"
kubectl --context "kind-${cluster_name}" -n flux-system get fluxinstance.fluxcd.controlplane.io/flux >/dev/null

if kubectl --context "kind-${cluster_name}" get namespace flux-operator-bootstrap >/dev/null 2>&1; then
  echo "Happy-path bootstrap namespace still exists after destroy" >&2
  exit 1
fi

section "Provider Wait Mode"
note "Rendering provider-wait scenario Terraform root"
render_root_module "${provider_wait_tf_dir}" "flux-operator-bootstrap-provider-wait" "" "false" "5s" "true"
note "Initializing provider-wait scenario"
terraform -chdir="${provider_wait_tf_dir}" init -no-color -backend=false
note "Running provider-wait bootstrap apply"
terraform -chdir="${provider_wait_tf_dir}" apply -no-color -auto-approve
note "Waiting for provider-wait bootstrap Job to be garbage-collected by TTL"
for _ in $(seq 1 15); do
  if ! kubectl --context "kind-${cluster_name}" -n flux-operator-bootstrap-provider-wait get job flux-operator-bootstrap >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
if kubectl --context "kind-${cluster_name}" -n flux-operator-bootstrap-provider-wait get job flux-operator-bootstrap >/dev/null 2>&1; then
  echo "Provider-wait bootstrap job was not deleted by TTL" >&2
  exit 1
fi

section "No Wait Mode"
note "Rendering no-wait scenario Terraform root"
render_root_module "${no_wait_tf_dir}" "flux-operator-bootstrap-no-wait" "" "true" "5s" "false"
note "Initializing no-wait scenario"
terraform -chdir="${no_wait_tf_dir}" init -no-color -backend=false
note "Running no-wait bootstrap apply"
terraform -chdir="${no_wait_tf_dir}" apply -no-color -auto-approve
note "Waiting for no-wait bootstrap Job to be garbage-collected by TTL"
for _ in $(seq 1 15); do
  if ! kubectl --context "kind-${cluster_name}" -n flux-operator-bootstrap-no-wait get job flux-operator-bootstrap >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
if kubectl --context "kind-${cluster_name}" -n flux-operator-bootstrap-no-wait get job flux-operator-bootstrap >/dev/null 2>&1; then
  echo "No-wait bootstrap job was not deleted by TTL" >&2
  exit 1
fi
if kubectl --context "kind-${cluster_name}" -n flux-operator-bootstrap-no-wait get serviceaccount flux-operator-bootstrap >/dev/null 2>&1; then
  echo "No-wait bootstrap service account still exists after TTL cleanup window" >&2
  exit 1
fi

section "Failure Path"
note "Rendering failure scenario Terraform root"
render_root_module "${failure_tf_dir}" "flux-operator-bootstrap-failure" "intentional e2e fault injection" "true" "5m" "true"
note "Initializing failure scenario"
terraform -chdir="${failure_tf_dir}" init -no-color -backend=false

note "Running fault-injected bootstrap apply to verify failure logging"
failure_apply_log="${failure_tf_dir}/apply.log"
set +e
terraform -chdir="${failure_tf_dir}" apply -no-color -auto-approve >"${failure_apply_log}" 2>&1
failure_status=$?
set -e
cat "${failure_apply_log}"

if [ "${failure_status}" -eq 0 ]; then
  echo "Fault-injected apply unexpectedly succeeded" >&2
  exit 1
fi

grep -F "Fault injection triggered: intentional e2e fault injection" "${failure_apply_log}" >/dev/null
grep -F "=== bootstrap job failed ===" "${failure_apply_log}" >/dev/null

section "Assertions"
note "Verified Flux readiness, idempotent rerun, destroy behavior, provider-wait mode, no-wait mode, and failure log wiring"
