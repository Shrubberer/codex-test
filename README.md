# codex-test

Spring Boot failover demo for OpenShift CRC and Istio service mesh testing.

## What is in this repo

- One Spring Boot image that can run as either a primary or secondary instance.
- Health and Prometheus endpoints for Kubernetes and mesh visibility.
- A fault trigger so the primary instance can intentionally return a chosen HTTP error.
- OpenShift manifests for two app deployments plus a stable in-mesh service.
- Istio manifests for retries, outlier detection, and failover priority testing.

## Runtime behavior

The root endpoint returns the configured reply message:

```text
GET /
```

The app can also expose which instance handled the request:

```text
GET /details
```

The fault trigger uses the `input` query parameter. With the default config, the
primary instance returns `503` when it receives:

```text
GET /?input=fail-primary
```

## OpenShift resources

The base manifest creates:

- one shared binary build and image stream
- `hello-primary`
- `hello-secondary`
- `hello-mesh` as the stable in-mesh service name
- direct debug routes for `hello-primary` and `hello-secondary`

Apply the base resources and build from this directory:

```bash
oc new-project codex-test
oc apply -f openshift.yaml -n codex-test
oc start-build hello-world --from-dir=. --follow --wait -n codex-test
```

## Istio resources

The `istio/` folder contains the mesh-specific resources:

- `failover.yaml` with `VirtualService` and `DestinationRule`
- `mesh-client.yaml` with a simple injected test client
- `README.md` with the mesh prerequisites and test flow

Apply them only after the service mesh control plane and namespace membership are ready.

## Failover model

The first pass uses a custom label, `failover-role`, instead of Kubernetes
locality. The `mesh-client` pod is labeled `failover-role=primary`, which lets
Istio prefer the primary endpoint first and fall back to the secondary endpoint
after outlier detection ejects the failing primary endpoint.

Later we can swap this from label-based priority to true topology labels such as
`topology.kubernetes.io/region` and `topology.kubernetes.io/zone`.
