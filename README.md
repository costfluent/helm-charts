# Costfluent Helm charts

Helm charts for running Costfluent components in Kubernetes. The repository is served from this
repository's GitHub Pages site.

| Chart | What it installs |
|---|---|
| [costfluent-k8s-agent](./costfluent-k8s-agent) | The agent that reports a cluster's resource usage to Costfluent for cost allocation |

## Install the Kubernetes agent

Create an organization API token in Costfluent under **Settings**, **API tokens**, with only the
**Report Kubernetes usage** capability, pick a cluster ID, and install:

```bash
helm repo add costfluent https://costfluent.github.io/helm-charts
helm upgrade -n costfluent cfa costfluent/costfluent-k8s-agent --install --create-namespace \
  --set agent.token=$COSTFLUENT_API_TOKEN,agent.clusterID=$CLUSTER_ID
```

The cluster registers itself on its first report, a few minutes later. The
[chart README](./costfluent-k8s-agent/README.md) lists every value and exactly what the agent reads
and sends; the guide is at <https://docs.costfluent.com/connect/kubernetes>.

## Releases

Each `vX.Y.Z` tag runs `.github/workflows/release.yml`, which checks that the chart's version is
the tag and that its `appVersion` image exists, packages the chart onto the GitHub release, and
merges it into `index.yaml` on the `gh-pages` branch.

## Support

- Documentation: <https://docs.costfluent.com/connect/kubernetes>
- Issues: <https://github.com/costfluent/helm-charts/issues>
