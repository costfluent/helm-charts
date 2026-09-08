# Costfluent Helm Charts

Official Helm charts for deploying Costfluent components to Kubernetes.

## Available Charts

| Chart | Description | Version |
|-------|-------------|---------|
| [costfluent-k8s-agent](./costfluent-k8s-agent) | Kubernetes cost metrics agent | 0.1.0 |

## Quick Start

### Add Repository

```bash
helm repo add costfluent https://costfluent.github.io/helm-charts
helm repo update
```

### Install Agent

```bash
# Get token from Costfluent UI: Settings → Integrations → Kubernetes → Add Cluster

helm upgrade costfluent-agent costfluent/costfluent-k8s-agent \
  --install \
  --namespace costfluent \
  --create-namespace \
  --set agent.token=cf_k8s_xxxxx \
  --set agent.clusterId=cl_xxxxx \
  --set agent.clusterName=production
```

### Verify Installation

```bash
# Check pod status
kubectl -n costfluent get pods

# View logs
kubectl -n costfluent logs -l app.kubernetes.io/name=costfluent-k8s-agent -f
```

## Charts

### costfluent-k8s-agent

Deploys the Costfluent Kubernetes agent for container cost tracking.

**Features:**
- Container CPU/memory metrics via metrics-server
- Pod metadata collection (labels, annotations, controllers)
- Node capacity and pricing information
- On-prem pricing via node annotations
- Spot/preemptible instance detection
- Hourly batch reporting
- Offline buffering with PV

See [costfluent-k8s-agent/README.md](./costfluent-k8s-agent/README.md) for details.

## Development

### Local Testing

```bash
# Lint chart
helm lint ./costfluent-k8s-agent

# Template without installing
helm template costfluent-agent ./costfluent-k8s-agent \
  --set agent.token=test \
  --set agent.clusterId=test

# Install locally
helm upgrade costfluent-agent ./costfluent-k8s-agent \
  --install \
  --namespace costfluent \
  --create-namespace \
  --set agent.token=$COSTFLUENT_TOKEN \
  --set agent.clusterId=$CLUSTER_ID
```

### Package Chart

```bash
helm package ./costfluent-k8s-agent
```

## Requirements

- Kubernetes 1.24+
- Helm 3.0+
- metrics-server installed in cluster

## Support

- Documentation: https://docs.costfluent.com/kubernetes
- Issues: https://github.com/costfluent/helm-charts/issues
- Email: support@costfluent.com
