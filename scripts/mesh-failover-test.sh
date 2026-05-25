#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${1:-codex-test}"
HOST="${2:-hello-mesh}"
FAULT_INPUT="${3:-fail-primary}"
RECOVERY_WAIT_SECONDS="${RECOVERY_WAIT_SECONDS:-35}"
SOURCE_DEPLOYMENT="${SOURCE_DEPLOYMENT:-hello-primary}"
SOURCE_CONTAINER="${SOURCE_CONTAINER:-hello-world}"
LAST_CURL_RESPONSE=""

step() {
  printf '\n== %s ==\n' "$1"
}

note() {
  printf '%s\n' "$1"
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_namespaced_resource() {
  local kind="$1"
  local name="$2"
  oc get "$kind" "$name" -n "${NAMESPACE}" >/dev/null 2>&1 || fail "Expected ${kind}/${name} in namespace ${NAMESPACE}"
}

run_from_source() {
  oc exec -n "${NAMESPACE}" "deploy/${SOURCE_DEPLOYMENT}" -c "${SOURCE_CONTAINER}" -- "$@"
}

curl_from_source() {
  run_from_source curl -sS "$@"
}

extract_instance_name() {
  sed -n 's/.*"instanceName":"\([^"]*\)".*/\1/p'
}

extract_header_value() {
  local header_name="$1"
  awk -v target="${header_name}" 'BEGIN { IGNORECASE = 1 } $1 == target ":" { gsub("\r", "", $2); print $2 }'
}

mesh_details() {
  curl_from_source "http://${HOST}:8080/details"
}

show_curl() {
  local description="$1"
  shift
  local response

  note "# ${description}"
  printf '$ curl -sS'
  for arg in "$@"; do
    printf ' %q' "$arg"
  done
  printf '\n'
  response="$(run_from_source curl -sS "$@")"
  LAST_CURL_RESPONSE="${response}"
  printf '%s\n' "${response}"
  printf '\n'
}

wait_for_primary_on_mesh() {
  local max_attempts="${1:-12}"
  local sleep_seconds="${2:-5}"
  local attempt response instance

  for attempt in $(seq 1 "${max_attempts}"); do
    response="$(mesh_details)"
    instance="$(printf '%s' "${response}" | extract_instance_name)"

    if [[ "${instance}" == "primary" ]]; then
      printf '%s\n' "${response}"
      return 0
    fi

    note "  Attempt ${attempt}/${max_attempts}: ${HOST} is still routing to ${instance:-unknown}. Waiting ${sleep_seconds}s..."
    sleep "${sleep_seconds}"
  done

  return 1
}

require_command oc

step "Preflight"
oc whoami >/dev/null 2>&1 || fail "oc is not logged in or cannot reach the cluster"
oc get namespace "${NAMESPACE}" >/dev/null 2>&1 || fail "Namespace ${NAMESPACE} does not exist"
require_namespaced_resource deployment hello-primary
require_namespaced_resource deployment hello-secondary
require_namespaced_resource service "${HOST}"
require_namespaced_resource virtualservice "${HOST}"
require_namespaced_resource destinationrule "${HOST}"
require_namespaced_resource smm default
oc rollout status deployment/hello-primary -n "${NAMESPACE}" --timeout=180s >/dev/null
oc rollout status deployment/hello-secondary -n "${NAMESPACE}" --timeout=180s >/dev/null

if ! oc get pods -n "${NAMESPACE}" -l app=hello-world,failover-role=primary \
  -o jsonpath='{range .items[*]}{.status.phase} {.spec.containers[*].name}{"\n"}{end}' | grep -q 'Running .*istio-proxy'; then
  fail "No running hello-primary pod with an istio-proxy sidecar was found"
fi

note "OK: namespace=${NAMESPACE}, source=${SOURCE_DEPLOYMENT}, mesh-service=${HOST}"
note "All curl commands below run inside ${SOURCE_DEPLOYMENT} via oc exec."

step "Warmup"
note "Making sure ${HOST} is back on primary before the demo starts."
wait_for_primary_on_mesh >/dev/null || fail "Timed out waiting for ${HOST} to route to primary again"
show_curl "Readiness check on the source pod" "http://127.0.0.1:8080/actuator/health/readiness"
show_curl "Baseline mesh route, should hit primary" "http://${HOST}:8080/details"

step "Failover"
show_curl "Direct call to primary, bypassing the mesh, expect the intentional 503" -i "http://127.0.0.1:8080/?input=${FAULT_INPUT}"
show_curl "Same input through ${HOST}, expect Istio to fail over to secondary" -i "http://${HOST}:8080/?input=${FAULT_INPUT}"
mesh_fault_response="${LAST_CURL_RESPONSE}"
mesh_instance="$(printf '%s' "${mesh_fault_response}" | extract_header_value x-codex-instance)"
if [[ -n "${mesh_instance}" ]]; then
  note "Result: mesh response came from ${mesh_instance}"
fi

step "While Primary Is Ejected"
show_curl "Immediate follow-up through ${HOST}, should still hit secondary" "http://${HOST}:8080/details"
followup_response="${LAST_CURL_RESPONSE}"
followup_instance="$(printf '%s' "${followup_response}" | extract_instance_name)"
if [[ -n "${followup_instance}" ]]; then
  note "Result: mesh is currently routing to ${followup_instance}"
fi

step "Recovery"
note "Waiting ${RECOVERY_WAIT_SECONDS}s for the outlier ejection window to expire..."
sleep "${RECOVERY_WAIT_SECONDS}"
wait_for_primary_on_mesh 6 5 >/dev/null || fail "Primary did not return to the mesh after the recovery wait"
show_curl "Mesh route after recovery, should be back on primary" "http://${HOST}:8080/details"
note "Done."
