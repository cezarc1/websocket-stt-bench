# stt-bench Helm chart

This chart renders the Kubernetes benchmark setup used for the
`websocket-stt-bench` k3s runs: inference server, gateway deployments,
suspended benchmark jobs, and a results PVC.

The chart is inert by default. Gateway deployments render with `replicas: 0`,
and loadgen/inferbench jobs render with `spec.suspend: true`.

## Local validation

```sh
helm lint charts/stt-bench
helm template stt-bench charts/stt-bench \
  -n stt-bench \
  -f charts/stt-bench/values-homelab-example.yaml \
  -f charts/stt-bench/values-edge-runs.yaml
```

## Install shape

If your image registry is private (default for GHCR), create a pull secret in
the target namespace and pass it through `imagePullSecrets`:

```yaml
imagePullSecrets:
  - name: ghcr-pull-secret
```

For an example homelab profile, use:

```sh
helm upgrade --install stt-bench charts/stt-bench \
  -n stt-bench --create-namespace \
  -f charts/stt-bench/values-homelab-example.yaml \
  -f charts/stt-bench/values-edge-runs.yaml
```

The bundled `chart.yml` workflow publishes the chart to:

```text
oci://ghcr.io/<github-owner>/websocket-stt-bench/charts/stt-bench:<version>
```

Flux users can consume the OCI chart with an `OCIRepository` plus a
`HelmRelease`.

## Running one point

Scale exactly one gateway, wait for rollout, then unsuspend one matching job:

```sh
kubectl -n stt-bench scale deploy/stt-rust-axum-gateway --replicas=1
kubectl -n stt-bench rollout status deploy/stt-rust-axum-gateway
kubectl -n stt-bench patch job stt-loadgen-rust-3450 \
  --type merge -p '{"spec":{"suspend":false}}'
kubectl -n stt-bench logs -f job/stt-loadgen-rust-3450
```

Jobs write paired files to the results PVC:

- `/results/<run>.summary.json`
- `/results/<run>.samples.csv`

Scale the gateway back to zero before switching runtimes.

## Cleanup

Safe cleanup keeps evidence and credentials:

```sh
kubectl -n stt-bench scale deploy \
  stt-rust-axum-gateway \
  stt-go-nethttp-gateway \
  stt-go-nethttp-2vcpu-gateway \
  stt-typescript-bun-gateway \
  stt-elixir-phoenix-gateway \
  stt-python-fastapi-ft-gateway \
  stt-python-fastapi-gil-gateway \
  --replicas=0
kubectl -n stt-bench delete job -l app=stt-benchmark --ignore-not-found
```

Only delete `stt-benchmark-results` after copying or intentionally discarding
the raw benchmark artifacts.
