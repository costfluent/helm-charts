# Costfluent Kubernetes Agent Helm Chart

Helm chart for deploying the Costfluent Kubernetes agent for container cost tracking.

## Prerequisites

- Kubernetes 1.24+
- Helm 3.0+
- metrics-server installed
- Costfluent account with cluster token

## Installation

### From Repository

```bash
helm repo add costfluent https://costfluent.github.io/helm-charts
helm repo update

helm upgrade costfluent-agent costfluent/costfluent-k8s-agent \
  --install \
  --namespace costfluent \
  --create-namespace \
  --set agent.token=cf_k8s_xxxxx \
  --set agent.clusterId=cl_xxxxx
```

### From Source

```bash
helm upgrade costfluent-agent ./costfluent-k8s-agent \
  --install \
  --namespace costfluent \
  --create-namespace \
  --set agent.token=cf_k8s_xxxxx \
  --set agent.clusterId=cl_xxxxx
```

### Using External Secret

```bash
# Create secret manually
kubectl create secret generic costfluent-token \
  --namespace costfluent \
  --from-literal=token=cf_k8s_xxxxx

# Install with external secret
helm upgrade costfluent-agent costfluent/costfluent-k8s-agent \
  --install \
  --namespace costfluent \
  --set agent.clusterId=cl_xxxxx \
  --set existingSecret.enabled=true \
  --set existingSecret.name=costfluent-token
```

## What the agent reads and sends

This runs in your cluster with cluster-wide read access, so you should be able to check that claim
rather than take it. The agent source is at
[costfluent/k8s-agent](https://github.com/costfluent/k8s-agent); everything below is enforced in
`internal/collector/metadata.go`.

**Cluster permissions** (`templates/clusterrole.yaml`, all read-only — `get`, `list`, `watch`):
nodes and node metrics, pods, namespaces, persistent volumes and claims, deployments, replicasets,
statefulsets, daemonsets, jobs, cronjobs, and the metrics API. No write verbs, no `secrets`, no
`configmaps`.

**What leaves the cluster** (`api/v1/report.go` is the whole wire contract):

| Sent | Detail |
|---|---|
| Node identity and shape | name, instance type, region, zone, CPU/memory/GPU capacity, spot flag, provider ID |
| Node labels | every label, minus `pod-template-hash`, `controller-revision-hash` and `statefulset.kubernetes.io/pod-name` |
| Node annotations | **only** the four `costfluent.com/*-rate` pricing keys — a strict allowlist, nothing else |
| Pod identity | namespace, pod name, controller name and kind, node name, phase, start time |
| Pod labels | same rule as node labels |
| Pod annotations | none by default — see below |
| Container usage | container name, CPU and memory requests and limits, and CPU/memory usage samples |

**What never leaves the cluster:** container images, environment variables, commands or arguments,
secrets, configmaps, volume contents, logs, network traffic, and any pod contents. The `Container`
type carries a name, its resource requests and limits, and usage samples — there is no field for
anything else.

> **No pod annotations are sent unless you ask for them.** `agent.collectAnnotations` is `false` by
> default, because annotations often hold internal configuration and this agent runs in your cluster,
> not ours. Labels alone drive allocation for most clusters.
>
> To allocate cost by annotation, turn it on *and* name the prefixes you want — anything outside them
> is never read:
>
> ```yaml
> agent:
>   collectAnnotations: true
>   allowedAnnotations:
>     - team.example.com/
>     - cost-center.example.com/
> ```
>
> Turning it on with an empty `allowedAnnotations` collects every annotation except `kubernetes.io/*`
> and `kubectl.kubernetes.io/*`, capped at `maxAnnotations` (10) per pod with values truncated to
> `maxAnnotationLength` (100) characters. Prefer the allowlist: truncation is a size limit, not a
> security control, and a short secret fits in 100 characters.

Namespace labels are collected when `agent.collectNamespaceLabels` is true (the default).

## Configuration

### Required Values

| Parameter | Description |
|-----------|-------------|
| `agent.token` | Costfluent API token |
| `agent.clusterId` | Cluster identifier from Costfluent |

### Common Values

| Parameter | Description | Default |
|-----------|-------------|---------|
| `agent.clusterName` | Display name for cluster | `""` |
| `agent.apiEndpoint` | Costfluent API URL | `https://api.costfluent.com` |
| `agent.pollingInterval` | Metric scrape interval (seconds) | `60` |
| `agent.reportingInterval` | Report interval (seconds) | `3600` |
| `agent.namespaceExclude` | Namespaces to exclude | `[kube-system, kube-public]` |

### Resource Limits

| Parameter | Description | Default |
|-----------|-------------|---------|
| `resources.limits.cpu` | CPU limit | `100m` |
| `resources.limits.memory` | Memory limit | `128Mi` |
| `resources.requests.cpu` | CPU request | `50m` |
| `resources.requests.memory` | Memory request | `64Mi` |

### Persistence

| Parameter | Description | Default |
|-----------|-------------|---------|
| `persistence.enabled` | Enable PV for buffering | `true` |
| `persistence.size` | PV size | `1Gi` |
| `persistence.storageClass` | Storage class | `""` |

### Metrics

| Parameter | Description | Default |
|-----------|-------------|---------|
| `metrics.enabled` | Enable Prometheus metrics | `true` |
| `metrics.port` | Metrics port | `9010` |
| `metrics.serviceMonitor.enabled` | Create ServiceMonitor | `false` |

### Full Values Reference

See [values.yaml](./values.yaml) for all configuration options.

## Examples

### Basic Installation

```bash
helm upgrade costfluent-agent costfluent/costfluent-k8s-agent \
  --install \
  --namespace costfluent \
  --create-namespace \
  --set agent.token=cf_k8s_xxxxx \
  --set agent.clusterId=cl_xxxxx \
  --set agent.clusterName=production-eks
```

### Large Cluster (>50 nodes)

```bash
helm upgrade costfluent-agent costfluent/costfluent-k8s-agent \
  --install \
  --namespace costfluent \
  --create-namespace \
  --set agent.token=cf_k8s_xxxxx \
  --set agent.clusterId=cl_xxxxx \
  --set resources.limits.cpu=200m \
  --set resources.limits.memory=256Mi \
  --set resources.requests.cpu=100m \
  --set resources.requests.memory=128Mi
```

### With ServiceMonitor (Prometheus Operator)

```bash
helm upgrade costfluent-agent costfluent/costfluent-k8s-agent \
  --install \
  --namespace costfluent \
  --create-namespace \
  --set agent.token=cf_k8s_xxxxx \
  --set agent.clusterId=cl_xxxxx \
  --set metrics.serviceMonitor.enabled=true \
  --set metrics.serviceMonitor.labels.release=prometheus
```

### Specific Namespaces Only

```bash
helm upgrade costfluent-agent costfluent/costfluent-k8s-agent \
  --install \
  --namespace costfluent \
  --create-namespace \
  --set agent.token=cf_k8s_xxxxx \
  --set agent.clusterId=cl_xxxxx \
  --set agent.namespaceInclude='{production,staging}'
```

### On-Premise Cluster

For on-prem clusters, add pricing annotations to nodes:

```bash
# Add pricing to nodes
kubectl annotate node worker-1 \
  costfluent.com/vcpu-hourly-rate="0.05" \
  costfluent.com/ram-gb-hourly-rate="0.007"

# Install agent
helm upgrade costfluent-agent costfluent/costfluent-k8s-agent \
  --install \
  --namespace costfluent \
  --create-namespace \
  --set agent.token=cf_k8s_xxxxx \
  --set agent.clusterId=cl_xxxxx
```

## Upgrading

```bash
helm repo update
helm upgrade costfluent-agent costfluent/costfluent-k8s-agent \
  --namespace costfluent \
  --reuse-values
```

## Uninstalling

```bash
helm uninstall costfluent-agent --namespace costfluent
kubectl delete namespace costfluent
```

## Troubleshooting

### Check Agent Status

```bash
kubectl -n costfluent get pods
kubectl -n costfluent describe pod costfluent-agent-0
```

### View Logs

```bash
kubectl -n costfluent logs costfluent-agent-0 -f
```

### Verify Token

```bash
kubectl -n costfluent get secret costfluent-agent -o jsonpath='{.data.token}' | base64 -d
```

### Check Metrics

```bash
kubectl -n costfluent port-forward svc/costfluent-agent 9010:9010
curl http://localhost:9010/metrics
```

### Common Issues

**Pod stuck in Pending:**
- Check PVC status: `kubectl -n costfluent get pvc`
- Verify storage class exists

**No data in Costfluent:**
- Check logs for API errors
- Verify token is correct
- Check network connectivity to API

**High memory usage:**
- Increase memory limit for large clusters
- Reduce polling interval

## RBAC

The chart creates a ClusterRole with read-only permissions:

- Nodes, pods, namespaces (get, list, watch)
- Deployments, replicasets, statefulsets, daemonsets (get, list)
- Jobs, cronjobs (get, list)
- PVs, PVCs (get, list)
- metrics.k8s.io resources (get, list)

## Support

- Documentation: https://docs.costfluent.com/kubernetes
- Issues: https://github.com/costfluent/helm-charts/issues
