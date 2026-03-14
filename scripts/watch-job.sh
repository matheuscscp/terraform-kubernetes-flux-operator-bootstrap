#!/usr/bin/env bash
set -euo pipefail

job_name="${JOB_NAME:?JOB_NAME is required}"
job_namespace="${JOB_NAMESPACE:?JOB_NAMESPACE is required}"
timeout="${TIMEOUT:-5m}"
kubernetes_host="${KUBERNETES_HOST:?KUBERNETES_HOST is required}"
kubernetes_cluster_ca_certificate="${KUBERNETES_CLUSTER_CA_CERTIFICATE:?KUBERNETES_CLUSTER_CA_CERTIFICATE is required}"
kubernetes_token="${KUBERNETES_TOKEN:?KUBERNETES_TOKEN is required}"
poll_interval=2
kubeconfig="$(mktemp)"
cluster_ca_file="$(mktemp)"

cleanup_files() {
  rm -f "${kubeconfig}" "${cluster_ca_file}"
}

trap cleanup_files EXIT

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
  user:
    token: ${kubernetes_token}
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
    kubectl -n "${job_namespace}" delete job "${job_name}" --ignore-not-found=true --wait=true
    exit 0
  fi

  if [ -n "${failed}" ] && [ "${failed}" != "0" ]; then
    print_logs
    exit 1
  fi

  sleep "${poll_interval}"
done

echo "Timed out waiting for bootstrap job ${job_namespace}/${job_name} to complete" >&2
print_logs
exit 1
