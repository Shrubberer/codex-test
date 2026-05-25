# codex-test

Spring Boot failover demo for OpenShift, Service Mesh 2, and Argo CD app-of-apps.

## What is in this repo

- One Spring Boot image that can run as either a primary or secondary instance.
- Health and Prometheus endpoints for Kubernetes and mesh visibility.
- A fault trigger so the primary instance can intentionally return a chosen HTTP error.
- A Helm chart for the runtime resources.
- A second Helm chart for the mesh resources.
- Argo CD app-of-apps manifests for the `test` environment.

## Runtime behavior

The app replies on:

```text
GET /
GET /details
```

With the default config, the primary instance returns `503` for:

```text
GET /?input=fail-primary
```

## Repo layout

- `charts/hello-failover`
  - runtime chart for the two deployments, services, and routes
- `charts/hello-failover-mesh`
  - mesh chart for `ServiceMeshMember`, `VirtualService`, `DestinationRule`, and the optional `mesh-client`
- `argocd/bootstrap/test-root-app.yaml`
  - one-time bootstrap manifest you can `oc apply`
- `argocd/environments/test`
  - the app-of-apps payload for the `test` environment
- `openshift/build-resources.yaml`
  - manual build resources kept outside Argo because the build is still binary S2I
- `istio/smcp.yaml`
  - lightweight SM2 control plane for CRC

## Build and image flow

Argo manages deployment state, not the binary S2I build. For now the build stays separate:

```bash
oc apply -f openshift/build-resources.yaml -n codex-test
oc start-build hello-world --from-dir=. --follow --wait -n codex-test
```

When you move to a pipeline later, the pipeline should publish a tagged image and Git should update the Helm values that Argo watches.

## Argo CD flow

The `test` environment is defined by:

- cluster: `https://kubernetes.default.svc`
- namespace: `codex-test`
- runtime values: `charts/hello-failover/values-test.yaml`
- mesh values: `charts/hello-failover-mesh/values-test.yaml`

Bootstrap the app-of-apps with:

```bash
oc apply -n openshift-gitops -f argocd/bootstrap/test-root-app.yaml
```

That root application creates:

- the `codex-test` `AppProject`
- the runtime child application
- the mesh child application
- the minimal `istio-system` role binding Argo needs to manage `ServiceMeshMember`

If the repo is private, add the repo credentials in Argo CD first. If it is already reachable from Argo CD, the single bootstrap apply is enough.

## Updating versions

To roll out a new application version through Argo CD, update the Helm values in Git:

- `charts/hello-failover/values-test.yaml`
  - `image.tag`
  - `app.version`
  - instance reply strings if you want them to reflect the version

Once that Git change is pushed, Argo CD syncs the new desired state.

## Failover model

The current mesh policy prefers the primary instance using the custom `failover-role` label, then fails over to secondary when the primary returns `503` and is ejected by outlier detection.

Later we can replace that label-based preference with true Kubernetes locality such as `topology.kubernetes.io/region` and `topology.kubernetes.io/zone`.
