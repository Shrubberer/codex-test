# Istio failover notes

The application mesh resources now live in the Helm chart at `charts/hello-failover-mesh`.

This folder only keeps the Service Mesh 2 control plane manifest for CRC:

- `smcp.yaml`
  - creates a lightweight `codex-mesh` control plane in `istio-system`
  - disables nonessential addons for CRC

## What Argo manages

The `codex-test-mesh` Argo application renders:

- `ServiceMeshMember`
- `VirtualService`
- `DestinationRule`
- optional `mesh-client`

Those resources are parameterized from:

- `charts/hello-failover-mesh/values.yaml`
- `charts/hello-failover-mesh/values-test.yaml`

## Why the custom label exists

CRC usually runs on a single node, so there is no meaningful Kubernetes locality difference yet. The first-pass failover uses `failover-role` to model priority without waiting for multi-zone topology.

Later we can replace that with true locality labels.
