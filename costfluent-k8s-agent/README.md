# Costfluent Kubernetes agent

Installs the Costfluent agent, which reports a cluster's resource usage to Costfluent so the cost
of its nodes can be allocated to namespaces, workloads and labels. One agent per cluster, one pod
per agent. The full guide is at <https://docs.costfluent.com/connect/kubernetes>.

## Prerequisites

- Kubernetes 1.24 or later and Helm 3.
- Outbound HTTPS from the cluster to `https://api.costfluent.com`, directly or through
  `agent.reportHTTPProxy`.
- No metrics-server: the agent reads each kubelet's `/metrics/resource` endpoint itself.

## Install

1. **Create a token.** In Costfluent, open **Settings**, then **API tokens**, and create an
   organization token with only the **Report Kubernetes usage** capability
   (`ReportKubernetesUsage`). It allows the one upload the agent makes and nothing else; workspace
   tokens are refused.
2. **Pick a cluster ID.** It names the cluster in Costfluent and must be unique in your
   organization: 1 to 63 letters, digits, `.`, `_` or `-`, starting with a letter or digit. The
   first report registers it; there is nothing to create beforehand.
3. **Install the chart.**

   ```bash
   helm repo add costfluent https://costfluent.github.io/helm-charts
   helm upgrade -n costfluent cfa costfluent/costfluent-k8s-agent --install --create-namespace \
     --set agent.token=$COSTFLUENT_API_TOKEN,agent.clusterID=$CLUSTER_ID
   ```

The first report arrives about two minutes after the pod starts, and the cluster then shows under
**Settings**, **Integrations**, **Kubernetes**.

To keep the token out of Helm values, store it in a Secret and point the chart at it:

```bash
kubectl -n costfluent create secret generic costfluent-token --from-literal=token=$COSTFLUENT_API_TOKEN
helm upgrade -n costfluent cfa costfluent/costfluent-k8s-agent --install --create-namespace \
  --set agent.clusterID=$CLUSTER_ID,agent.secret.name=costfluent-token
```

Rendering fails when `agent.clusterID` is missing or malformed, or when neither `agent.token` nor
`agent.secret.name` is set.

## Values

Every `agent.*` value sets one `COSTFLUENT_*` environment variable on the agent; the
[agent README](https://github.com/costfluent/k8s-agent#configuration) lists them.

| Value | Default | Purpose |
|---|---|---|
| `agent.token` | `""` | The organization API token. The chart stores it in a Secret it creates. Set it, or `agent.secret.name`. |
| `agent.secret.name`, `agent.secret.key` | `""`, `token` | An existing Secret holding the token, used instead of `agent.token`. |
| `agent.clusterID` | none, required | The cluster's ID in Costfluent. |
| `agent.apiEndpoint` | `https://api.costfluent.com` | Where reports are sent. |
| `agent.pollingInterval` | `60` | Seconds between usage samples: 5, 10, 15, 30 or 60. |
| `agent.nodeAddressTypes` | `InternalIP,InternalDNS,Hostname,ExternalIP,ExternalDNS` | The node address types tried, in order, to reach each kubelet on port 10250. |
| `agent.disableKubeTLSverify` | `false` | Skip verifying kubelet serving certificates, for clusters whose kubelets serve self-signed ones (kind, Talos). |
| `agent.allowedLabels` | `[]` | Pod label keys to send. Empty sends every pod label. |
| `agent.allowedAnnotations` | `[]` | Pod annotation keys to send, at most 10. Empty sends none. |
| `agent.collectNamespaceLabels` | `false` | Send each namespace's labels with its pods. |
| `agent.reportHTTPProxy` | `""` | An HTTP proxy for report traffic only. |
| `agent.logLevel` | `info` | `debug`, `info`, `warn` or `error`. |
| `agent.extraEnv` | `[]` | Extra environment variables for the agent container. |
| `persist.mountPath` | `/var/lib/costfluent` | Where the unsent-report buffer and the open window's snapshot live. |
| `persist.size`, `persist.storageClassName` | `1Gi`, `""` | The volume claim. Set `persist` to `null` for an emptyDir, which loses both on rescheduling. |
| `image.repository`, `image.tag`, `image.pullPolicy` | `ghcr.io/costfluent/k8s-agent`, the chart's `appVersion`, `IfNotPresent` | The agent image. |
| `resources` | requests `50m` CPU and `64Mi`, limit `256Mi` | See **Sizing**. |
| `nodeSelector`, `tolerations`, `affinity`, `priorityClassName` | empty | Scheduling. |
| `podLabels`, `podAnnotations` | `{}` | Added to the agent pod. |
| `serviceAccount.create`, `serviceAccount.name`, `serviceAccount.annotations` | `true`, the release name, `{}` | The agent's service account. |
| `service.port` | `9010` | Serves `/metrics`, `/healthz` and `/readyz`. |
| `serviceMonitor.enabled`, `serviceMonitor.interval`, `serviceMonitor.labels` | `false`, `60s`, `{}` | A Prometheus Operator ServiceMonitor for `/metrics`. |

[values.yaml](./values.yaml) holds the rest, including the pod and container security contexts.

## Sizing

The agent is one pod whatever the size of the cluster; its memory grows with the number of
containers it tracks. Measured in a kind cluster with 61 pods at a 5 second polling interval, the
agent's working set averaged 11.4 MiB with a 12.8 MiB peak, using under 0.001 CPU cores. The
defaults (`64Mi` requested, `256Mi` limit) leave room for clusters many times that size; raise the
limit if the pod is restarted for exceeding it.

## What the agent reads and sends

This runs in your cluster with cluster-wide read access, so you should be able to check what it
does rather than take a claim on trust. The agent source is at
[costfluent/k8s-agent](https://github.com/costfluent/k8s-agent), and `api/v1/report.go` there is the
whole wire contract.

**Cluster permissions** (`templates/clusterrole.yaml`, read-only):

| Resource | Verbs | Why |
|---|---|---|
| `nodes`, `pods` | `list`, `watch` | Node shape and the pods running on each node. |
| `nodes/metrics` | `get` | Each kubelet's `/metrics/resource` endpoint: container CPU and memory usage. |
| `namespaces` | `list` | Namespace labels, only when `agent.collectNamespaceLabels` is true. |
| `replicasets` (apps), `jobs` (batch) | `get` | Resolving a pod's ReplicaSet to its Deployment and a Job to its CronJob. |

No write verbs, no `secrets`, no `configmaps`, no `nodes/proxy`.

**What leaves the cluster.** The agent posts one gzip JSON report per window to
`{agent.apiEndpoint}/v1/kubernetes/reports`. Windows are UTC clock hours, except a first window
that closes about two minutes after start.

| Sent | Detail |
|---|---|
| Report header | schema version, cluster ID, agent version, a random agent instance ID kept on the volume, window start and end |
| Node identity and shape | name, provider ID, instance type, region, zone, spot flag, seconds observed, CPU, memory and GPU capacity, allocatable CPU and memory |
| Node labels | every node label |
| Node annotations | **only** `costfluent.com/vcpu-hourly-rate`, `costfluent.com/ram-gb-hourly-rate`, `costfluent.com/gpu-hourly-rate` and `costfluent.com/storage-gb-hourly-rate`; nothing else |
| Pod identity | namespace, pod name, node name, controller kind and name |
| Pod labels | every label, minus `pod-template-hash`, `controller-revision-hash` and `statefulset.kubernetes.io/pod-name`; only the keys in `agent.allowedLabels` when it is set |
| Pod annotations | none, unless named in `agent.allowedAnnotations` (at most 10 keys, values cut to 100 characters) |
| Namespace labels | none, unless `agent.collectNamespaceLabels` is true |
| Container usage | container name, seconds observed, CPU, memory and GPU requests, CPU and memory usage and allocation integrated over the window, and peak CPU and memory usage |

**What never leaves the cluster:** container images, commands, arguments, environment variables,
secrets, config maps, volume contents, logs, network traffic, and any other pod or node annotation.
The `Container` type carries a name, its requests and usage figures, and nothing else.

Prefer `agent.allowedAnnotations` over widening collection: annotations often hold internal
configuration, and a short secret fits in 100 characters.

Reports that cannot be delivered are kept on the agent's volume, for up to 96 hours or 50 MB, and
sent once Costfluent is reachable again.

## Nodes without a cloud bill

A node that matches a connected AWS, Azure or GCP account is priced from that bill. Otherwise, set
hourly rates on the node, or default rates in the cluster's settings in Costfluent:

```bash
kubectl annotate node worker-1 \
  costfluent.com/vcpu-hourly-rate=0.05 \
  costfluent.com/ram-gb-hourly-rate=0.007
```

## Troubleshooting

```bash
kubectl -n costfluent get pods -l app.kubernetes.io/instance=cfa
kubectl -n costfluent logs -l app.kubernetes.io/instance=cfa -f
kubectl -n costfluent port-forward svc/cfa-costfluent-k8s-agent 9010:9010 && curl -s localhost:9010/metrics
```

- **401 or 403 in the logs:** the token is wrong, revoked, a workspace token, or lacks **Report
  Kubernetes usage**. Reports stay buffered, so fixing the token recovers them.
- **Kubelet scrapes failing with a certificate error:** the kubelets serve self-signed
  certificates; set `agent.disableKubeTLSverify=true`.
- **Pod pending:** check the volume claim (`kubectl -n costfluent get pvc`) or set `persist=null`.

## Uninstall

```bash
helm uninstall -n costfluent cfa
kubectl -n costfluent delete pvc -l app.kubernetes.io/instance=cfa
```

## Support

- Documentation: <https://docs.costfluent.com/connect/kubernetes>
- Issues: <https://github.com/costfluent/helm-charts/issues>
