#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${1:-codex-test}"
FAULT_INPUT="${2:-fail-primary}"
RECOVERY_WAIT_SECONDS="${RECOVERY_WAIT_SECONDS:-35}"
INGRESS_NAMESPACE="${INGRESS_NAMESPACE:-istio-system}"
INGRESS_GATEWAY_NAME="${INGRESS_GATEWAY_NAME:-hello-mesh-ingress}"
LAST_CURL_RESPONSE=""
PRIMARY_ROUTE_HOST=""
MESH_ROUTE_HOST=""

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
  local namespace="${3:-${NAMESPACE}}"
  oc get "$kind" "$name" -n "${namespace}" >/dev/null 2>&1 || fail "Expected ${kind}/${name} in namespace ${namespace}"
}

extract_instance_name() {
  sed -n 's/.*"instanceName":"\([^"]*\)".*/\1/p'
}

extract_header_value() {
  local header_name="$1"
  awk -v target="${header_name}" 'BEGIN { IGNORECASE = 1 } $1 == target ":" { gsub("\r", "", $2); print $2 }'
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
  response="$(curl -sS "$@")"
  LAST_CURL_RESPONSE="${response}"
  printf '%s\n' "${response}"
  printf '\n'
}

mesh_details() {
  curl -sS "http://${MESH_ROUTE_HOST}/details"
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

    note "  Attempt ${attempt}/${max_attempts}: mesh ingress is still routing to ${instance:-unknown}. Waiting ${sleep_seconds}s..."
    sleep "${sleep_seconds}"
  done

  return 1
}

require_command oc
require_command curl

step "Preflight"
oc whoami >/dev/null 2>&1 || fail "oc is not logged in or cannot reach the cluster"
oc get namespace "${NAMESPACE}" >/dev/null 2>&1 || fail "Namespace ${NAMESPACE} does not exist"
require_namespaced_resource deployment hello-primary
require_namespaced_resource deployment hello-secondary
require_namespaced_resource route hello-primary
require_namespaced_resource gateway "${INGRESS_GATEWAY_NAME}"
require_namespaced_resource virtualservice "${INGRESS_GATEWAY_NAME}"
require_namespaced_resource virtualservice hello-mesh
require_namespaced_resource destinationrule hello-mesh
require_namespaced_resource smm default

PRIMARY_ROUTE_HOST="$(oc get route hello-primary -n "${NAMESPACE}" -o jsonpath='{.spec.host}')"
MESH_ROUTE_HOST="$(oc get route -n "${INGRESS_NAMESPACE}" -l "app.kubernetes.io/name=${INGRESS_GATEWAY_NAME}" -o jsonpath='{.items[0].spec.host}')"

[[ -n "${PRIMARY_ROUTE_HOST}" ]] || fail "Could not determine the hello-primary route host"
[[ -n "${MESH_ROUTE_HOST}" ]] || fail "Could not determine the mesh ingress route host in ${INGRESS_NAMESPACE}"

note "OK: primary-route=${PRIMARY_ROUTE_HOST}"
note "OK: mesh-route=${MESH_ROUTE_HOST}"
note "All curl commands below run from your terminal."

step "Warmup"
note "Making sure the mesh ingress route is back on primary before the demo starts."
wait_for_primary_on_mesh >/dev/null || fail "Timed out waiting for the mesh ingress route to return to primary"
show_curl "Baseline mesh ingress route, should hit primary" "http://${MESH_ROUTE_HOST}/details"

step "Failover"
show_curl "Direct call to the primary route, expect the intentional 503" -i "http://${PRIMARY_ROUTE_HOST}/?input=${FAULT_INPUT}"
show_curl "Same input through the mesh ingress route, expect Istio to fail over to secondary" -i "http://${MESH_ROUTE_HOST}/?input=${FAULT_INPUT}"
mesh_fault_response="${LAST_CURL_RESPONSE}"
mesh_instance="$(printf '%s' "${mesh_fault_response}" | extract_header_value x-codex-instance)"
if [[ -n "${mesh_instance}" ]]; then
  note "Result: mesh response came from ${mesh_instance}"
fi

step "While Primary Is Ejected"
show_curl "Immediate follow-up through the mesh ingress route, should still hit secondary" "http://${MESH_ROUTE_HOST}/details"
followup_response="${LAST_CURL_RESPONSE}"
followup_instance="$(printf '%s' "${followup_response}" | extract_instance_name)"
if [[ -n "${followup_instance}" ]]; then
  note "Result: mesh is currently routing to ${followup_instance}"
fi

step "Recovery"
note "Waiting ${RECOVERY_WAIT_SECONDS}s for the outlier ejection window to expire..."
sleep "${RECOVERY_WAIT_SECONDS}"
wait_for_primary_on_mesh 6 5 >/dev/null || fail "Primary did not return to the mesh ingress route after the recovery wait"
show_curl "Mesh ingress route after recovery, should be back on primary" "http://${MESH_ROUTE_HOST}/details"
note "Done."
