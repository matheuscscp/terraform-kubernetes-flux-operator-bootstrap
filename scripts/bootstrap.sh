#!/busybox/busybox sh
set -eu

flux_instance_file="${FLUX_INSTANCE_FILE:?FLUX_INSTANCE_FILE is required}"
prerequisites_dir="${PREREQUISITES_DIR:-/bootstrap}"
secrets_file="${SECRETS_FILE:-}"
wait_for_instance="${WAIT_FOR_INSTANCE:-true}"
timeout="${TIMEOUT:-5m}"
bootstrap_namespace="${BOOTSTRAP_NAMESPACE:?BOOTSTRAP_NAMESPACE is required}"
service_account_name="${SERVICE_ACCOUNT_NAME:?SERVICE_ACCOUNT_NAME is required}"
cluster_role_binding_name="${CLUSTER_ROLE_BINDING_NAME:?CLUSTER_ROLE_BINDING_NAME is required}"
debug_fault_injection_message="${DEBUG_FAULT_INJECTION_MESSAGE:-}"
field_manager="flux-operator-bootstrap"

log() {
  printf '%s\n' "$*" >&2
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
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

extract_top_level_value() {
  manifest_file="$1"
  key="$2"

  /busybox/busybox awk -v wanted="${key}" '
    $1 == wanted ":" {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      print $0
      exit
    }
  ' "${manifest_file}"
}

extract_manifest_metadata_value() {
  manifest_file="$1"
  key="$2"

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
  ' "${manifest_file}"
}

split_yaml_documents() {
  input_file="$1"
  output_dir="$2"
  prefix="$3"

  /busybox/busybox mkdir -p "${output_dir}"

  /busybox/busybox awk -v output_dir="${output_dir}" -v prefix="${prefix}" '
    function flush() {
      if (has_content) {
        file = sprintf("%s/%s-%03d.yaml", output_dir, prefix, count++)
        print document > file
        close(file)
      }
      document = ""
      has_content = 0
    }

    /^---[[:space:]]*$/ {
      flush()
      next
    }

    {
      document = document $0 ORS
      trimmed = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", trimmed)
      if (trimmed != "" && trimmed !~ /^#/) {
        has_content = 1
      }
    }

    END {
      flush()
    }
  ' "${input_file}"
}

manifest_details() {
  manifest_file="$1"
  kubectl create --dry-run=client -f "${manifest_file}" -o jsonpath='{.kind}|{.metadata.name}|{.metadata.namespace}'
}

format_manifest_details() {
  manifest_info="$1"
  manifest_kind="$(printf '%s' "${manifest_info}" | /busybox/busybox cut -d'|' -f1)"
  manifest_name="$(printf '%s' "${manifest_info}" | /busybox/busybox cut -d'|' -f2)"
  manifest_namespace="$(printf '%s' "${manifest_info}" | /busybox/busybox cut -d'|' -f3)"

  if [ -n "${manifest_namespace}" ]; then
    printf '%s %s/%s' "${manifest_kind}" "${manifest_namespace}" "${manifest_name}"
  else
    printf '%s %s' "${manifest_kind}" "${manifest_name}"
  fi
}

apply_prerequisite_document() {
  manifest_file="$1"
  manifest_info="$(manifest_details "${manifest_file}")"
  manifest_label="$(format_manifest_details "${manifest_info}")"

  if kubectl get -f "${manifest_file}" >/dev/null 2>&1; then
    log "- skip ${manifest_label}"
    return 0
  fi

  log "+ apply ${manifest_label}"
  kubectl apply -f "${manifest_file}" >/dev/null
}

apply_prerequisites() {
  scratch_dir="$1"
  found_prerequisite="false"

  for prerequisite_file in "${prerequisites_dir}"/prerequisite-*.yaml; do
    if [ ! -f "${prerequisite_file}" ]; then
      continue
    fi

    found_prerequisite="true"
    split_dir="${scratch_dir}/$(/busybox/busybox basename "${prerequisite_file}" .yaml)"
    split_yaml_documents "${prerequisite_file}" "${split_dir}" "doc"

    for manifest_file in "${split_dir}"/doc-*.yaml; do
      if [ ! -f "${manifest_file}" ]; then
        continue
      fi

      apply_prerequisite_document "${manifest_file}"
    done
  done

  if [ "${found_prerequisite}" = "false" ]; then
    log "No prerequisites"
  fi
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

reconcile_secret_document() {
  manifest_file="$1"
  manifest_kind="$(extract_top_level_value "${manifest_file}" kind)"
  manifest_name="$(extract_manifest_metadata_value "${manifest_file}" name)"
  manifest_namespace="$(extract_manifest_metadata_value "${manifest_file}" namespace)"

  if [ "${manifest_kind}" != "Secret" ]; then
    fail "secrets_yaml must only contain Secret objects, got ${manifest_kind:-<unknown>}"
    return 1
  fi

  if [ -z "${manifest_name}" ]; then
    fail "secrets_yaml contains a Secret without metadata.name"
    return 1
  fi

  if [ -n "${manifest_namespace}" ] && [ "${manifest_namespace}" != "${namespace}" ]; then
    fail "Secret ${manifest_name} must omit metadata.namespace or set it to ${namespace}"
    return 1
  fi

  if ! dry_run_output="$(kubectl apply --server-side --dry-run=server --force-conflicts --field-manager="${field_manager}" -f "${manifest_file}" -n "${namespace}" 2>&1)"; then
    printf '%s\n' "${dry_run_output}" >&2
    fail "Failed to dry-run apply Secret ${namespace}/${manifest_name}"
    return 1
  fi

  case "${dry_run_output}" in
    *"unchanged (server dry run)"*)
      secret_state="in-sync"
      ;;
    *"created (server dry run)"*)
      secret_state="missing"
      ;;
    *"configured (server dry run)"*)
      secret_state="drifted"
      ;;
    *"serverside-applied (server dry run)"*)
      secret_state="drifted"
      ;;
    *)
      fail "Unexpected dry-run result for Secret ${namespace}/${manifest_name}: ${dry_run_output}"
      return 1
      ;;
  esac

  if [ "${secret_state}" = "in-sync" ]; then
    log "= Secret ${namespace}/${manifest_name}"
    return 0
  fi

  log "~ Secret ${namespace}/${manifest_name} (${secret_state})"
  kubectl apply --server-side --force-conflicts --field-manager="${field_manager}" -f "${manifest_file}" -n "${namespace}" >/dev/null
}

reconcile_secrets() {
  scratch_dir="$1"

  if [ -z "${secrets_file}" ] || [ ! -f "${secrets_file}" ]; then
    log "No managed secrets to reconcile"
    return 0
  fi

  split_dir="${scratch_dir}/managed-secrets"
  split_yaml_documents "${secrets_file}" "${split_dir}" "secret"

  found_secret="false"
  for manifest_file in "${split_dir}"/secret-*.yaml; do
    if [ ! -f "${manifest_file}" ]; then
      continue
    fi

    found_secret="true"
    reconcile_secret_document "${manifest_file}"
  done

  if [ "${found_secret}" = "false" ]; then
    log "No managed secrets"
  fi
}

cleanup() {
  log "Cleanup bootstrap RBAC"
  if [ -n "${scratch_dir:-}" ] && [ -d "${scratch_dir}" ]; then
    /busybox/busybox rm -rf "${scratch_dir}"
  fi
  if ! kubectl delete serviceaccount "${service_account_name}" -n "${bootstrap_namespace}" --ignore-not-found=true >/dev/null; then
    log "Failed to delete ServiceAccount ${bootstrap_namespace}/${service_account_name}"
  fi
  if ! kubectl delete clusterrolebinding "${cluster_role_binding_name}" --ignore-not-found=true >/dev/null; then
    log "Failed to delete ClusterRoleBinding ${cluster_role_binding_name}"
  fi
}

namespace="$(extract_metadata_value namespace)"
instance_name="$(extract_metadata_value name)"

if [ -z "${namespace}" ] || [ -z "${instance_name}" ]; then
  fail "Failed to determine FluxInstance namespace or name from ${flux_instance_file}"
  exit 1
fi

log "Target: ${namespace}/${instance_name}"
log "Bootstrap namespace: ${bootstrap_namespace}"

trap cleanup EXIT
scratch_dir="$(/busybox/busybox mktemp -d)"

log "Prerequisites"
apply_prerequisites "${scratch_dir}"

if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
  log "Namespace exists: ${namespace}"
else
  log "Create namespace: ${namespace}"
  kubectl create namespace "${namespace}" >/dev/null
fi

log "Managed secrets"
reconcile_secrets "${scratch_dir}"

if ! helm status flux-operator -n "${namespace}" >/dev/null 2>&1; then
  log "Install Flux Operator"
  helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
    -n "${namespace}"
else
  log "Flux Operator exists"
fi

log "FluxInstance CRD"
wait_for_flux_instance_crd

instance_created="false"
if ! kubectl get fluxinstance.fluxcd.controlplane.io "${instance_name}" -n "${namespace}" >/dev/null 2>&1; then
  log "Create FluxInstance"
  kubectl apply -f "${flux_instance_file}" >/dev/null
  instance_created="true"
else
  log "FluxInstance exists"
fi

if [ "${instance_created}" = "true" ] && [ "${wait_for_instance}" = "true" ]; then
  log "Wait for FluxInstance"
  flux-operator wait instance "${instance_name}" -n "${namespace}" --timeout="${timeout}"
else
  log "FluxInstance wait skipped"
fi

if [ -n "${debug_fault_injection_message}" ]; then
  fail "Fault injection triggered: ${debug_fault_injection_message}"
  exit 1
fi

log "Done"
