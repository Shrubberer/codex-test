#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${1:-codex-test}"
HOST="${2:-hello-mesh}"
FAULT_INPUT="${3:-fail-primary}"

oc project "${NAMESPACE}" >/dev/null

oc apply -f openshift.yaml -n "${NAMESPACE}"
oc apply -f istio/mesh-client.yaml -n "${NAMESPACE}"
oc apply -f istio/failover.yaml -n "${NAMESPACE}"

oc start-build hello-world --from-dir=. --follow --wait -n "${NAMESPACE}"
oc rollout status deployment/hello-primary -n "${NAMESPACE}" --timeout=180s
oc rollout status deployment/hello-secondary -n "${NAMESPACE}" --timeout=180s
oc rollout status deployment/mesh-client -n "${NAMESPACE}" --timeout=180s

CLIENT_POD="$(oc get pod -n "${NAMESPACE}" -l app=mesh-client -o jsonpath='{.items[0].metadata.name}')"

echo "Normal response:"
oc exec -n "${NAMESPACE}" "${CLIENT_POD}" -- curl -sS "http://${HOST}:8080/"
echo
echo

echo "Instance details:"
oc exec -n "${NAMESPACE}" "${CLIENT_POD}" -- curl -sS "http://${HOST}:8080/details"
echo
echo

echo "Fault trigger requests:"
oc exec -n "${NAMESPACE}" "${CLIENT_POD}" -- sh -lc "for i in 1 2 3 4; do echo request-\$i; curl -sS -i 'http://${HOST}:8080/?input=${FAULT_INPUT}'; echo; sleep 2; done"
