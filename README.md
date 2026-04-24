# codex-test

Spring Boot hello-world application for OpenShift CRC.

## Version

`0.1.0`

## Endpoints

- `/` returns `hello from version 0.1.0`
- `/actuator/health/liveness`
- `/actuator/health/readiness`
- `/actuator/prometheus`

## OpenShift

Apply the OpenShift objects and start a binary build from this directory:

```bash
oc new-project codex-test
oc apply -f openshift.yaml -n codex-test
oc start-build hello-world --from-dir=. --follow --wait -n codex-test
```
