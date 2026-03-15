#!/usr/bin/env bash
set -euo pipefail

export NO_COLOR=1

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cluster_name="flux-operator-bootstrap-e2e"
image_repository="terraform-kubernetes-flux-operator-bootstrap"
image_tag="dev"
image="${image_repository}:${image_tag}"
module_image="ghcr.io/matheuscscp/terraform-kubernetes-flux-operator-bootstrap:${image_tag}"
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

secret_value() {
  secret_name="$1"

  kubectl --context "kind-${cluster_name}" -n flux-system get "secret/${secret_name}" \
    -o jsonpath='{.data.value}' | base64 --decode
}

secret_uid() {
  secret_name="$1"

  kubectl --context "kind-${cluster_name}" -n flux-system get "secret/${secret_name}" \
    -o jsonpath='{.metadata.uid}'
}

prerequisite_configmap_value() {
  kubectl --context "kind-${cluster_name}" -n bootstrap-prereq get configmap/bootstrap-prereq \
    -o jsonpath='{.data.value}'
}

inventory_secret_names() {
  bootstrap_namespace="$1"

  kubectl --context "kind-${cluster_name}" -n "${bootstrap_namespace}" get secret/flux-operator-bootstrap-inventory \
    -o go-template='{{index .data "secret-names"}}' | base64 --decode
}

target_secret_exists() {
  secret_name="$1"

  kubectl --context "kind-${cluster_name}" -n flux-system get "secret/${secret_name}" >/dev/null 2>&1
}

secret_has_field_manager() {
  manager="$1"

  kubectl --context "kind-${cluster_name}" -n flux-system get secret/bootstrap-managed \
    -o jsonpath='{range .metadata.managedFields[*]}{.manager}{"\n"}{end}' | grep -Fx "${manager}" >/dev/null
}

assert_no_secret_material_in_state() {
  tf_dir="$1"

  while IFS= read -r state_file; do
    if grep -F "bootstrap-managed" "${state_file}" >/dev/null; then
      echo "Managed Secret manifest name leaked into Terraform state: ${state_file}" >&2
      exit 1
    fi

    if grep -F "bootstrap-managed-removed" "${state_file}" >/dev/null; then
      echo "Removed managed Secret manifest name leaked into Terraform state: ${state_file}" >&2
      exit 1
    fi

    if grep -F "value\":\"expected" "${state_file}" >/dev/null || grep -F "expected" "${state_file}" >/dev/null; then
      echo "Managed Secret payload leaked into Terraform state: ${state_file}" >&2
      exit 1
    fi

    if grep -F "temporary" "${state_file}" >/dev/null; then
      echo "Removed managed Secret payload leaked into Terraform state: ${state_file}" >&2
      exit 1
    fi
  done < <(find "${tf_dir}" -maxdepth 1 -type f \( -name 'terraform.tfstate' -o -name 'terraform.tfstate.*' \) | sort)
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

assert_bootstrap_inputs_applied() {
  kubectl --context "kind-${cluster_name}" get namespace bootstrap-prereq >/dev/null

  if [ "$(prerequisite_configmap_value)" != "initial" ]; then
    echo "Prerequisite ConfigMap did not contain the expected initial value" >&2
    exit 1
  fi

  if [ "$(secret_value bootstrap-managed)" != "expected" ]; then
    echo "Managed Secret did not contain the expected initial value" >&2
    exit 1
  fi

  if [ "$(secret_value bootstrap-managed-removed)" != "temporary" ]; then
    echo "Managed Secret slated for removal did not contain the expected initial value" >&2
    exit 1
  fi
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
  secrets_mode="$7"
  watcher_inputs=""
  fixtures_dir="${tf_dir}-fixtures"
  fixture_root_name="$(basename "${fixtures_dir}")"
  prerequisites_dir="${fixtures_dir}/tenants"
  flux_instance_dir="${fixtures_dir}/clusters/test/flux-system"

  if [ "${use_kubectl_watcher}" = "true" ] && [ "${wait}" = "true" ]; then
    watcher_inputs=$(cat <<EOF
  kubernetes = {
    host = "${kubernetes_host}"
    cluster_ca_certificate = <<PEM
${kubernetes_cluster_ca_certificate}
PEM
    token = "${kubernetes_token}"
  }
EOF
)
  fi

  managed_secrets_yaml="$(
    if [ "${secrets_mode}" = "two" ]; then
      cat <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-managed
type: Opaque
stringData:
  value: expected
---
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-managed-removed
type: Opaque
stringData:
  value: temporary
YAML
    else
      cat <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-managed
type: Opaque
stringData:
  value: expected
YAML
    fi
  )"

  mkdir -p "${prerequisites_dir}" "${flux_instance_dir}"

  cat > "${prerequisites_dir}/00-namespace.yaml" <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: bootstrap-prereq
EOF

  cat > "${prerequisites_dir}/01-configmap.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: bootstrap-prereq
  namespace: bootstrap-prereq
data:
  value: initial
EOF

  cat > "${flux_instance_dir}/flux-instance.yaml" <<'EOF'
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
EOF

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

  image_tag = "${image_tag}"

  debug_fault_injection_message = "${fault_injection_message}"

  prerequisites_paths = [
    "\${path.root}/../${fixture_root_name}/tenants/00-namespace.yaml",
    "\${path.root}/../${fixture_root_name}/tenants/01-configmap.yaml",
  ]

  secrets_yaml = <<YAML
${managed_secrets_yaml}
YAML

  flux_instance_path = "\${path.root}/../${fixture_root_name}/clusters/test/flux-system/flux-instance.yaml"
}
EOF
}

section "Cluster Setup"
note "Resetting kind cluster ${cluster_name}"
kind delete cluster --name "${cluster_name}" || true
note "Creating kind cluster ${cluster_name}"
kind create cluster --name "${cluster_name}"
note "Tagging local image ${image} as ${module_image} for module consumption"
docker tag "${image}" "${module_image}"
note "Loading locally built image ${module_image}"
kind load docker-image "${module_image}" --name "${cluster_name}"
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
render_root_module "${success_tf_dir}" "flux-operator-bootstrap" "" "true" "5m" "true" "two"
note "Initializing success scenario"
terraform -chdir="${success_tf_dir}" init -no-color -backend=false

note "Running initial bootstrap apply"
terraform -chdir="${success_tf_dir}" apply -no-color -auto-approve
note "Verifying FluxInstance and Flux workloads are ready"
assert_flux_runtime_ready
note "Verifying ordered prerequisites and managed secrets were applied"
assert_bootstrap_inputs_applied
initial_managed_secret_uid="$(secret_uid bootstrap-managed)"
if [ "$(inventory_secret_names flux-operator-bootstrap)" != "$(printf 'bootstrap-managed\nbootstrap-managed-removed')" ]; then
  echo "Managed secret inventory was not created with the expected entries" >&2
  exit 1
fi
note "Verifying managed secret material did not land in Terraform state"
assert_no_secret_material_in_state "${success_tf_dir}"

section "Idempotency"
note "Introducing drift, then removing one managed Secret from desired state"
kubectl --context "kind-${cluster_name}" apply --server-side --force-conflicts --field-manager=e2e-drift-manager -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-managed
  namespace: flux-system
type: Opaque
stringData:
  value: drifted
YAML
kubectl --context "kind-${cluster_name}" -n bootstrap-prereq patch configmap bootstrap-prereq \
  --type merge \
  -p '{"data":{"value":"drifted"}}' >/dev/null
if ! secret_has_field_manager "e2e-drift-manager"; then
  echo "Managed Secret was not updated with the e2e drift field manager" >&2
  exit 1
fi
render_root_module "${success_tf_dir}" "flux-operator-bootstrap" "" "true" "5m" "true" "one"

note "Running second bootstrap apply to verify idempotent rerun"
terraform -chdir="${success_tf_dir}" apply -no-color -auto-approve
note "Re-verifying Flux runtime after idempotent rerun"
assert_flux_runtime_ready
note "Re-verifying managed secret material did not land in Terraform state"
assert_no_secret_material_in_state "${success_tf_dir}"
if [ "$(secret_value bootstrap-managed)" != "expected" ]; then
  echo "Managed Secret drift was not corrected by the second apply" >&2
  exit 1
fi
if [ "$(secret_uid bootstrap-managed)" = "${initial_managed_secret_uid}" ]; then
  echo "Managed Secret was not recreated after detecting a foreign field manager" >&2
  exit 1
fi
if secret_has_field_manager "e2e-drift-manager"; then
  echo "Managed Secret still contains the e2e drift field manager after reconciliation" >&2
  exit 1
fi
if target_secret_exists "bootstrap-managed-removed"; then
  echo "Removed managed Secret was not garbage-collected by the second apply" >&2
  exit 1
fi
if [ "$(inventory_secret_names flux-operator-bootstrap)" != "bootstrap-managed" ]; then
  echo "Managed secret inventory was not updated after removing a Secret from desired state" >&2
  exit 1
fi
if [ "$(prerequisite_configmap_value)" != "drifted" ]; then
  echo "Prerequisite drift was unexpectedly reconciled" >&2
  exit 1
fi

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
render_root_module "${provider_wait_tf_dir}" "flux-operator-bootstrap-provider-wait" "" "false" "5s" "true" "one"
note "Initializing provider-wait scenario"
terraform -chdir="${provider_wait_tf_dir}" init -no-color -backend=false
note "Running provider-wait bootstrap apply"
terraform -chdir="${provider_wait_tf_dir}" apply -no-color -auto-approve
note "Verifying provider-wait state is also free of managed secret material"
assert_no_secret_material_in_state "${provider_wait_tf_dir}"
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
render_root_module "${no_wait_tf_dir}" "flux-operator-bootstrap-no-wait" "" "true" "5s" "false" "one"
note "Initializing no-wait scenario"
terraform -chdir="${no_wait_tf_dir}" init -no-color -backend=false
note "Running no-wait bootstrap apply"
terraform -chdir="${no_wait_tf_dir}" apply -no-color -auto-approve
note "Verifying no-wait state is also free of managed secret material"
assert_no_secret_material_in_state "${no_wait_tf_dir}"
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
render_root_module "${failure_tf_dir}" "flux-operator-bootstrap-failure" "intentional e2e fault injection" "true" "5m" "true" "one"
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

note "Verifying failed watched Job was deleted after logs were captured"
if kubectl --context "kind-${cluster_name}" -n flux-operator-bootstrap-failure get job flux-operator-bootstrap >/dev/null 2>&1; then
  echo "Failed watched bootstrap Job still exists after failure log capture" >&2
  exit 1
fi

note "Re-rendering failure scenario without fault injection to verify the watched Job is recreated"
render_root_module "${failure_tf_dir}" "flux-operator-bootstrap-failure" "" "true" "5m" "true" "one"
terraform -chdir="${failure_tf_dir}" apply -no-color -auto-approve
assert_flux_runtime_ready
assert_no_secret_material_in_state "${failure_tf_dir}"
if kubectl --context "kind-${cluster_name}" -n flux-operator-bootstrap-failure get job flux-operator-bootstrap >/dev/null 2>&1; then
  echo "Recovered watched bootstrap Job still exists after successful rerun" >&2
  exit 1
fi

section "Assertions"
note "Verified prerequisites, managed secret reconciliation, Flux readiness, idempotent rerun, destroy behavior, provider-wait mode, no-wait mode, failure log wiring, and watched Job recreation after failure"
