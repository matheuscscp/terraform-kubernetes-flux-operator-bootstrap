#!/busybox/busybox sh
set -eu

flux_instance_file="${FLUX_INSTANCE_FILE:?FLUX_INSTANCE_FILE is required}"
wait_for_instance="${WAIT_FOR_INSTANCE:-true}"
timeout="${TIMEOUT:-5m}"
bootstrap_namespace="${BOOTSTRAP_NAMESPACE:?BOOTSTRAP_NAMESPACE is required}"
service_account_name="${SERVICE_ACCOUNT_NAME:?SERVICE_ACCOUNT_NAME is required}"
cluster_role_binding_name="${CLUSTER_ROLE_BINDING_NAME:?CLUSTER_ROLE_BINDING_NAME is required}"
debug_fault_injection_message="${DEBUG_FAULT_INJECTION_MESSAGE:-}"

log() {
  printf '[bootstrap] %s\n' "$*"
}

fail() {
  printf '[bootstrap] ERROR: %s\n' "$*" >&2
}

extract_metadata_value() {
  key="$1"
  /busybox/busybox awk -v wanted="${key}" '
    $1 == "metadata:" { in_metadata = 1; next }
    in_metadata && $0 ~ /^[^[:space:]]/ { exit }
    in_metadata {
      gsub(/^[[:space:]]+/, "", $0)
      if ($1 == wanted ":") {
        sub(/^[^:]+:[[:space:]]*/, "", $0)
        print $0
        exit
      }
    }
  ' "${flux_instance_file}"
}

wait_for_flux_instance_crd() {
  end_time=$(( $(/busybox/busybox date +%s) + 300 ))
  while [ "$(/busybox/busybox date +%s)" -lt "${end_time}" ]; do
    if kubectl get crd fluxinstances.fluxcd.controlplane.io >/dev/null 2>&1; then
      log "CRD found; waiting for Established"
      kubectl wait --for=condition=Established crd/fluxinstances.fluxcd.controlplane.io --timeout="${timeout}" >/dev/null
      return 0
    fi
    sleep 2
  done

  fail "Timed out waiting for FluxInstance CRD to be created"
  return 1
}

cleanup() {
  log "Cleaning up bootstrap access"
  kubectl delete serviceaccount "${service_account_name}" -n "${bootstrap_namespace}" --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete clusterrolebinding "${cluster_role_binding_name}" --ignore-not-found=true >/dev/null 2>&1 || true
}

namespace="$(extract_metadata_value namespace)"
instance_name="$(extract_metadata_value name)"

if [ -z "${namespace}" ] || [ -z "${instance_name}" ]; then
  fail "Failed to determine FluxInstance namespace or name from ${flux_instance_file}"
  exit 1
fi

log "Target: ${namespace}/${instance_name}"
log "Bootstrap ns: ${bootstrap_namespace}"

trap cleanup EXIT

if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
  log "Target namespace ${namespace} already exists"
else
  log "Creating target namespace ${namespace}"
  kubectl create namespace "${namespace}" >/dev/null
fi

if ! helm status flux-operator -n "${namespace}" >/dev/null 2>&1; then
  log "Installing Flux Operator in ${namespace}"
  helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
    -n "${namespace}"
else
  log "Flux Operator already installed; skip"
fi

log "Waiting for FluxInstance CRD"
wait_for_flux_instance_crd

instance_created="false"
if ! kubectl get fluxinstance.fluxcd.controlplane.io "${instance_name}" -n "${namespace}" >/dev/null 2>&1; then
  log "FluxInstance missing; apply manifest"
  kubectl apply -f "${flux_instance_file}" >/dev/null
  instance_created="true"
else
  log "FluxInstance exists; skip apply"
fi

if [ "${instance_created}" = "true" ] && [ "${wait_for_instance}" = "true" ]; then
  log "Waiting for FluxInstance readiness"
  flux-operator wait instance "${instance_name}" -n "${namespace}" --timeout="${timeout}"
else
  log "Skip FluxInstance wait"
fi

if [ -n "${debug_fault_injection_message}" ]; then
  fail "Fault injection triggered: ${debug_fault_injection_message}"
  exit 1
fi

log "Bootstrap completed successfully"
