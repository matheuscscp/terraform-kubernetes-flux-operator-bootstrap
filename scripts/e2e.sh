#!/usr/bin/env bash
set -euo pipefail

export NO_COLOR=1

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cluster_name="flux-operator-bootstrap-e2e"
image_repository="terraform-kubernetes-flux-operator-bootstrap"
image_tag="dev"
image="${image_repository}:${image_tag}"
module_image="ghcr.io/matheuscscp/terraform-kubernetes-flux-operator-bootstrap:${image_tag}"
inventory_secret_name="inventory"
success_tf_dir="$(mktemp -d)"
failure_tf_dir="$(mktemp -d)"
failure_apply_log=""

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

  kubectl --context "kind-${cluster_name}" -n "${bootstrap_namespace}" get "secret/${inventory_secret_name}" \
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

    if grep -F "rotated" "${state_file}" >/dev/null; then
      echo "Rotated managed Secret payload leaked into Terraform state: ${state_file}" >&2
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
  rm -rf "${success_tf_dir}" "${failure_tf_dir}"
}

trap cleanup EXIT

render_root_module() {
  tf_dir="$1"
  bootstrap_namespace="$2"
  fault_injection_message="$3"
  secrets_mode="$4"
  fixtures_dir="${tf_dir}-fixtures"
  fixture_root_name="$(basename "${fixtures_dir}")"
  prerequisites_dir="${fixtures_dir}/tenants"
  flux_instance_dir="${fixtures_dir}/clusters/test/flux-system"

  mkdir -p "${prerequisites_dir}" "${flux_instance_dir}"

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
    elif [ "${secrets_mode}" = "rotated" ]; then
      cat <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-managed
type: Opaque
stringData:
  value: rotated
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
  required_version = ">= 1.11.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0.0"
    }
  }
}

provider "helm" {
  kubernetes = {
    config_path    = "~/.kube/config"
    config_context = "kind-${cluster_name}"
  }
}

module "bootstrap" {
  source = "${repo_root}"

  bootstrap_namespace = "${bootstrap_namespace}"

  image = {
    tag = "${image_tag}"
  }

  debug_fault_injection_message = "${fault_injection_message}"

  gitops_resources = {
    flux_instance_path = "\${path.root}/../${fixture_root_name}/clusters/test/flux-system/flux-instance.yaml"
    prerequisites_paths = [
      "\${path.root}/../${fixture_root_name}/tenants/00-namespace.yaml",
      "\${path.root}/../${fixture_root_name}/tenants/01-configmap.yaml",
    ]
  }

  managed_resources = {
    secrets_yaml = <<YAML
${managed_secrets_yaml}
YAML
  }
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

section "Happy Path"
note "Rendering success scenario Terraform root"
render_root_module "${success_tf_dir}" "flux-operator-bootstrap" "" "two"
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
note "Verifying bootstrap ClusterRoleBinding was removed by the job"
if kubectl --context "kind-${cluster_name}" get clusterrolebinding flux-operator-bootstrap-flux-operator-bootstrap >/dev/null 2>&1; then
  echo "Bootstrap ClusterRoleBinding still exists after job completion" >&2
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
render_root_module "${success_tf_dir}" "flux-operator-bootstrap" "" "one"

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

section "Secret Rotation"
note "Rotating managed secret value"
render_root_module "${success_tf_dir}" "flux-operator-bootstrap" "" "rotated"
terraform -chdir="${success_tf_dir}" apply -no-color -auto-approve
if [ "$(secret_value bootstrap-managed)" != "rotated" ]; then
  echo "Managed Secret was not updated after rotation" >&2
  exit 1
fi
note "Verifying rotated secret material did not land in Terraform state"
assert_no_secret_material_in_state "${success_tf_dir}"

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

note "Verifying Helm release was removed"
if helm --kube-context "kind-${cluster_name}" -n flux-operator-bootstrap list -q | grep -Fx flux-operator-bootstrap >/dev/null; then
  echo "Helm release still exists after destroy" >&2
  exit 1
fi

section "Failure Path"
note "Rendering failure scenario Terraform root"
render_root_module "${failure_tf_dir}" "flux-operator-bootstrap-failure" "intentional e2e fault injection" "one"
note "Initializing failure scenario"
terraform -chdir="${failure_tf_dir}" init -no-color -backend=false

note "Running fault-injected bootstrap apply to verify failure"
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

note "Re-rendering failure scenario without fault injection to verify recovery"
render_root_module "${failure_tf_dir}" "flux-operator-bootstrap-failure" "" "one"
terraform -chdir="${failure_tf_dir}" apply -no-color -auto-approve
assert_flux_runtime_ready
assert_no_secret_material_in_state "${failure_tf_dir}"

section "Assertions"
note "Verified prerequisites, managed secret reconciliation, secret rotation, RBAC cleanup, Flux readiness, idempotent rerun, destroy behavior, and failure recovery"
