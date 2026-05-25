#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${1:-codex-test}"
HOST="${2:-hello-mesh}"
FAULT_INPUT="${3:-fail-primary}"
RECOVERY_WAIT_SECONDS="${RECOVERY_WAIT_SECONDS:-35}"
SOURCE_DEPLOYMENT="${SOURCE_DEPLOYMENT:-hello-primary}"
SOURCE_CONTAINER="${SOURCE_CONTAINER:-hello-world}"

step() {
  printf '\n[%s] %s\n' "$1" "$2"
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

mesh_fault() {
  curl_from_source -i "http://${HOST}:8080/?input=${FAULT_INPUT}"
}

local_primary_fault() {
  curl_from_source -i "http://127.0.0.1:8080/?input=${FAULT_INPUT}"
}

local_primary_readiness() {
  curl_from_source "http://127.0.0.1:8080/actuator/health/readiness"
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

step "1/7" "Checking cluster access and the already-deployed demo resources"
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

note "  Cluster access works."
note "  Namespace ${NAMESPACE} already has the failover app and mesh resources."
note "  Readiness from inside ${SOURCE_DEPLOYMENT}: $(local_primary_readiness)"

step "2/7" "Explaining the traffic path"
note "  This script does not install or modify anything."
note "  It uses ${SOURCE_DEPLOYMENT} as the in-mesh client, so requests to ${HOST} go through the pod's istio-proxy sidecar."
note "  First we will show the primary's real 503 directly, then we will send the same input through the mesh service."

step "3/7" "Making sure the primary is back in rotation before the demo"
note "  Istio temporarily ejects the failing primary for about ${RECOVERY_WAIT_SECONDS}s after a fault."
note "  If you ran the demo recently, traffic may still be on secondary. We will wait until ${HOST} returns to primary again."
baseline_response="$(wait_for_primary_on_mesh)" || fail "Timed out waiting for ${HOST} to route to primary again"
note "  Baseline response through ${HOST}:"
printf '%s\n' "${baseline_response}"

step "4/7" "Showing the forced 503 directly on the primary"
note "  This call goes to 127.0.0.1 inside the primary pod, so it bypasses failover and shows the application's intentional fault."
direct_fault_response="$(local_primary_fault)"
printf '%s\n' "${direct_fault_response}"

step "5/7" "Triggering the same input through the mesh service"
note "  Now the request goes to ${HOST}. Istio should observe the 503 from primary, retry, and return the secondary response."
mesh_fault_response="$(mesh_fault)"
printf '%s\n' "${mesh_fault_response}"
mesh_instance="$(printf '%s' "${mesh_fault_response}" | extract_header_value x-codex-instance)"
if [[ -n "${mesh_instance}" ]]; then
  note "  The mesh-visible response came from: ${mesh_instance}"
fi

step "6/7" "Watching temporary failover while the primary stays ejected"
note "  The next few mesh requests should continue to hit secondary while the primary is still out of rotation."
for request_number in 1 2 3; do
  response="$(mesh_details)"
  instance="$(printf '%s' "${response}" | extract_instance_name)"
  note "  Mesh details request ${request_number}: instance=${instance:-unknown}"
  printf '%s\n' "${response}"
  echo
  sleep 2
done

step "7/7" "Waiting for recovery and confirming traffic returns to primary"
note "  Waiting ${RECOVERY_WAIT_SECONDS}s for the outlier ejection window to expire..."
sleep "${RECOVERY_WAIT_SECONDS}"
recovery_response="$(wait_for_primary_on_mesh 6 5)" || fail "Primary did not return to the mesh after the recovery wait"
note "  Traffic through ${HOST} is back on primary:"
printf '%s\n' "${recovery_response}"

note ""
note "Demo complete."
