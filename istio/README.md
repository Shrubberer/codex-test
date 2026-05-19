# Istio failover notes

Apply these files only after the cluster has a working Istio or OpenShift Service
Mesh control plane and the `codex-test` namespace is enrolled in that mesh.

## Prerequisites

- The namespace must be a mesh member.
- Sidecar injection must be active for `codex-test`.
- The mesh control plane must expose the `networking.istio.io` CRDs.

## Files

- `failover.yaml`
  - creates the in-mesh `VirtualService`
  - creates the `DestinationRule`
  - enables retries for `503`
  - ejects unhealthy endpoints after a single `5xx`
- `mesh-client.yaml`
  - creates a simple in-mesh client pod
  - labels the client `failover-role=primary`
  - lets Istio prefer the primary endpoint before falling back

## Why the custom label exists

CRC usually runs on a single node, so there is no meaningful Kubernetes
locality difference yet. The first-pass failover uses `failover-role` to model
priority without waiting for multi-zone topology. Later we can replace this with
true locality labels.
