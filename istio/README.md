# Istio failover notes

The application mesh resources now live in the Helm chart at `charts/hello-failover-mesh`.

This folder only keeps the Service Mesh 2 control plane manifest for CRC:

- `smcp.yaml`
  - creates a lightweight `codex-mesh` control plane in `istio-system`
  - disables nonessential addons for CRC
  - enables an ingress gateway and OpenShift route generation for the external failover demo

## What Argo manages

The `istio-failover-demo-mesh` Argo application renders:

- `ServiceMeshMember`
- `Gateway`
- `VirtualService`
- `DestinationRule`
- optional `mesh-client`

Those resources are parameterized from:

- `charts/hello-failover-mesh/values.yaml`
- `charts/hello-failover-mesh/values-test.yaml`

## Why the custom label exists

CRC usually runs on a single node, so there is no meaningful Kubernetes locality difference yet. The first-pass failover uses `failover-role` to model priority without waiting for multi-zone topology.

Later we can replace that with true locality labels.

## External terminal demo note

The external demo route uses the Service Mesh ingress gateway. For deterministic primary-first behavior, the ingress gateway pod needs the label `failover-role=primary`.

The SMCP file includes that intent, but in this CRC setup the generated gateway deployment may still need a one-time patch:

```bash
oc patch deployment istio-ingressgateway -n istio-system --type merge -p '{"spec":{"template":{"metadata":{"labels":{"failover-role":"primary"}}}}}'
```
