#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${1:-istio-failover-demo}"
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

compact_http_response() {
  awk '
    BEGIN { status_printed = 0; in_body = 0 }
    /^HTTP\// && !status_printed {
      sub(/\r$/, "")
      print
      status_printed = 1
      next
    }
    in_body {
      sub(/\r$/, "")
      print
    }
    /^\r?$/ { in_body = 1 }
  '
}

show_curl() {
  local description="$1"
  local mode="$2"
  shift
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
  if [[ "${mode}" == "status-and-body" ]]; then
    printf '%s\n' "${response}" | compact_http_response
  else
    printf '%s\n' "${response}"
  fi
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
require_namespaced_resource gateway.networking.istio.io "${INGRESS_GATEWAY_NAME}"
require_namespaced_resource virtualservice "${INGRESS_GATEWAY_NAME}"
require_namespaced_resource virtualservice hello-mesh
require_namespaced_resource destinationrule hello-mesh
require_namespaced_resource smm default

ingress_failover_role="$(oc get pods -n "${INGRESS_NAMESPACE}" -l app=istio-ingressgateway -o jsonpath='{.items[0].metadata.labels.failover-role}')"
if [[ "${ingress_failover_role}" != "primary" ]]; then
  fail "Ingress gateway pod label failover-role=primary is missing. Run: oc patch deployment istio-ingressgateway -n ${INGRESS_NAMESPACE} --type merge -p '{\"spec\":{\"template\":{\"metadata\":{\"labels\":{\"failover-role\":\"primary\"}}}}}'"
fi

PRIMARY_ROUTE_HOST="$(oc get route hello-primary -n "${NAMESPACE}" -o jsonpath='{.spec.host}')"
MESH_ROUTE_HOST="$(oc get route -n "${INGRESS_NAMESPACE}" -l "app.kubernetes.io/name=${INGRESS_GATEWAY_NAME},maistra.io/gateway-namespace=${NAMESPACE}" -o jsonpath='{.items[0].spec.host}')"

[[ -n "${PRIMARY_ROUTE_HOST}" ]] || fail "Could not determine the hello-primary route host"
[[ -n "${MESH_ROUTE_HOST}" ]] || fail "Could not determine the mesh ingress route host in ${INGRESS_NAMESPACE}"

note "OK: primary-route=${PRIMARY_ROUTE_HOST}"
note "OK: mesh-route=${MESH_ROUTE_HOST}"

wait_for_primary_on_mesh >/dev/null || fail "Timed out waiting for the mesh ingress route to return to primary"
note "ingress route is on primary: ok"

step "Failover"
show_curl "Direct call to the primary route, expect the intentional 503" "status-and-body" -i "http://${PRIMARY_ROUTE_HOST}/?input=${FAULT_INPUT}"
show_curl "Same input through the mesh ingress route, expect Istio to fail over to secondary" "status-and-body" -i "http://${MESH_ROUTE_HOST}/?input=${FAULT_INPUT}"
mesh_fault_response="${LAST_CURL_RESPONSE}"
mesh_instance="$(printf '%s' "${mesh_fault_response}" | extract_header_value x-failover-instance)"
if [[ -n "${mesh_instance}" ]]; then
  note "Result: mesh response came from ${mesh_instance}"
fi

step "While Primary Is Ejected"
show_curl "Immediate follow-up through the mesh ingress route, should still hit secondary" "body" "http://${MESH_ROUTE_HOST}/details"
followup_response="${LAST_CURL_RESPONSE}"
followup_instance="$(printf '%s' "${followup_response}" | extract_instance_name)"
if [[ -n "${followup_instance}" ]]; then
  note "Result: mesh is currently routing to ${followup_instance}"
fi

step "Recovery"
note "Waiting ${RECOVERY_WAIT_SECONDS}s for the outlier ejection window to expire..."
sleep "${RECOVERY_WAIT_SECONDS}"
wait_for_primary_on_mesh 6 5 >/dev/null || fail "Primary did not return to the mesh ingress route after the recovery wait"
show_curl "Mesh ingress route after recovery, should be back on primary" "body" "http://${MESH_ROUTE_HOST}/details"
note "Done."
