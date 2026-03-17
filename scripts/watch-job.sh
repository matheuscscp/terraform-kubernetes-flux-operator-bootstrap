#!/usr/bin/env bash
set -euo pipefail

job_name="${JOB_NAME:?JOB_NAME is required}"
job_namespace="${JOB_NAMESPACE:?JOB_NAMESPACE is required}"
timeout="${TIMEOUT:-5m}"
kubernetes_host="${KUBERNETES_HOST:?KUBERNETES_HOST is required}"
kubernetes_cluster_ca_certificate="${KUBERNETES_CLUSTER_CA_CERTIFICATE:?KUBERNETES_CLUSTER_CA_CERTIFICATE is required}"
kubernetes_token="${KUBERNETES_TOKEN:-}"
kubernetes_exec_api_version="${KUBERNETES_EXEC_API_VERSION:-}"
kubernetes_exec_command="${KUBERNETES_EXEC_COMMAND:-}"
kubernetes_exec_args="${KUBERNETES_EXEC_ARGS:-}"
kubernetes_exec_env="${KUBERNETES_EXEC_ENV:-}"
poll_interval=2
kubeconfig="$(mktemp)"
cluster_ca_file="$(mktemp)"

cleanup_files() {
  rm -f "${kubeconfig}" "${cluster_ca_file}"
}

trap cleanup_files EXIT

yaml_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

append_exec_config() {
  printf '%s\n' "  user:" >> "${kubeconfig}"
  printf '%s\n' "    exec:" >> "${kubeconfig}"
  printf '      apiVersion: %s\n' "$(yaml_quote "${kubernetes_exec_api_version}")" >> "${kubeconfig}"
  printf '      command: %s\n' "$(yaml_quote "${kubernetes_exec_command}")" >> "${kubeconfig}"

  if [ -n "${kubernetes_exec_args}" ]; then
    printf '%s\n' "      args:" >> "${kubeconfig}"
    while IFS= read -r arg; do
      printf '        - %s\n' "$(yaml_quote "${arg}")" >> "${kubeconfig}"
    done <<EOF
$(printf '%s' "${kubernetes_exec_args}" | base64 --decode)
EOF
  fi

  if [ -n "${kubernetes_exec_env}" ]; then
    printf '%s\n' "      env:" >> "${kubeconfig}"
    while IFS='=' read -r env_name env_value; do
      printf '        - name: %s\n' "$(yaml_quote "${env_name}")" >> "${kubeconfig}"
      printf '          value: %s\n' "$(yaml_quote "${env_value}")" >> "${kubeconfig}"
    done <<EOF
$(printf '%s' "${kubernetes_exec_env}" | base64 --decode)
EOF
  fi
}

if [ -z "${kubernetes_token}" ] && [ -z "${kubernetes_exec_command}" ]; then
  echo "Either KUBERNETES_TOKEN or KUBERNETES_EXEC_COMMAND is required" >&2
  exit 1
fi

printf '%s' "${kubernetes_cluster_ca_certificate}" > "${cluster_ca_file}"
cat > "${kubeconfig}" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: bootstrap-target
  cluster:
    server: ${kubernetes_host}
    certificate-authority: ${cluster_ca_file}
users:
- name: bootstrap-target
EOF

if [ -n "${kubernetes_token}" ]; then
  cat >> "${kubeconfig}" <<EOF
  user:
    token: $(yaml_quote "${kubernetes_token}")
EOF
else
  append_exec_config
fi

cat >> "${kubeconfig}" <<EOF
contexts:
- name: bootstrap-target
  context:
    cluster: bootstrap-target
    user: bootstrap-target
current-context: bootstrap-target
EOF

export KUBECONFIG="${kubeconfig}"

timeout_value="${timeout%[smh]}"
timeout_unit="${timeout##${timeout_value}}"

case "${timeout_unit}" in
  s) timeout_seconds="${timeout_value}" ;;
  m) timeout_seconds="$(( timeout_value * 60 ))" ;;
  h) timeout_seconds="$(( timeout_value * 3600 ))" ;;
  *)
    echo "Unsupported timeout format: ${timeout}" >&2
    exit 1
    ;;
esac

deadline=$(( $(date +%s) + timeout_seconds ))

get_first_pod() {
  kubectl -n "${job_namespace}" get pods -l "job-name=${job_name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

delete_job() {
  kubectl -n "${job_namespace}" delete job "${job_name}" --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
}

print_logs() {
  pod_name="$(get_first_pod)"
  if [ -n "${pod_name}" ]; then
    {
      echo "=== bootstrap job failed ==="
      echo "job: ${job_namespace}/${job_name}"
      echo "pod: ${pod_name}"
      echo "--- logs ---"
      kubectl -n "${job_namespace}" logs "${pod_name}" || true
      echo "--- end logs ---"
    } >&2
  else
    echo "Bootstrap job pod logs unavailable: no pod found for job ${job_name}" >&2
  fi
}

while [ "$(date +%s)" -lt "${deadline}" ]; do
  if ! kubectl -n "${job_namespace}" get job "${job_name}" >/dev/null 2>&1; then
    echo "Bootstrap job ${job_namespace}/${job_name} is missing before completion" >&2
    exit 1
  fi

  succeeded="$(kubectl -n "${job_namespace}" get job "${job_name}" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
  failed="$(kubectl -n "${job_namespace}" get job "${job_name}" -o jsonpath='{.status.failed}' 2>/dev/null || true)"

  if [ "${succeeded:-0}" = "1" ]; then
    delete_job
    exit 0
  fi

  if [ -n "${failed}" ] && [ "${failed}" != "0" ]; then
    print_logs
    delete_job
    exit 1
  fi

  sleep "${poll_interval}"
done

echo "Timed out waiting for bootstrap job ${job_namespace}/${job_name} to complete" >&2
print_logs
delete_job
exit 1
