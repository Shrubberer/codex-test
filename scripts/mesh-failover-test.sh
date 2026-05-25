#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${1:-codex-test}"
HOST="${2:-hello-mesh}"
FAULT_INPUT="${3:-fail-primary}"

oc apply -f istio/smcp.yaml
oc wait --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True smcp/codex-mesh -n istio-system --timeout=600s

oc apply -f openshift/build-resources.yaml -n "${NAMESPACE}"

oc start-build hello-world --from-dir=. --follow --wait -n "${NAMESPACE}"

helm template hello-failover charts/hello-failover --namespace "${NAMESPACE}" -f charts/hello-failover/values-test.yaml | oc apply -n "${NAMESPACE}" -f -
helm template hello-failover-mesh charts/hello-failover-mesh --namespace "${NAMESPACE}" -f charts/hello-failover-mesh/values-test.yaml | oc apply -n "${NAMESPACE}" -f -

oc wait --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True smm/default -n "${NAMESPACE}" --timeout=180s

oc rollout status deployment/hello-primary -n "${NAMESPACE}" --timeout=180s
oc rollout status deployment/hello-secondary -n "${NAMESPACE}" --timeout=180s
oc rollout status deployment/mesh-client -n "${NAMESPACE}" --timeout=180s

echo "Normal response:"
oc exec -n "${NAMESPACE}" -c hello-world deploy/hello-primary -- curl -sS "http://${HOST}:8080/"
echo
echo

echo "Instance details:"
oc exec -n "${NAMESPACE}" -c hello-world deploy/hello-primary -- curl -sS "http://${HOST}:8080/details"
echo
echo

echo "Fault trigger requests:"
oc exec -n "${NAMESPACE}" -c hello-world deploy/hello-primary -- sh -lc "for i in 1 2 3 4; do echo request-\$i; curl -sS -i 'http://${HOST}:8080/?input=${FAULT_INPUT}'; echo; sleep 2; done"
