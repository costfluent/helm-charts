# Costfluent Kubernetes agent

Installs the Costfluent agent, which reports a cluster's resource usage to Costfluent so the cost
of its nodes can be allocated to namespaces, workloads and labels. One agent per cluster, one pod
per agent. The full guide is at <https://docs.costfluent.com/connect/kubernetes>.

## Prerequisites

- Kubernetes 1.31 or later and Helm 3.
- Outbound HTTPS from the cluster to `https://api.costfluent.com`, directly or through
  `agent.reportHTTPProxy`.
- No metrics-server: the agent reads each kubelet's `/metrics/resource` endpoint itself.

## Install

1. **Add the cluster.** In Costfluent, open **Settings**, **Integrations**, **Kubernetes**, and
   choose **Add cluster**. Give it a cluster ID, unique in your organization: 1 to 63 letters,
   digits, `.`, `_` or `-`, starting with a letter or digit. Costfluent shows the cluster's token
   once. It reports for that cluster and nothing else, so a leaked token can neither post for
   another cluster nor read anything. **Mint token** on the cluster issues another.
2. **Install the chart** with that token. The agent reads its cluster from the token at start and
   exits with the reason in its log when the token is refused or is not a cluster token. It keeps
   that cluster on its volume, so a later start while Costfluent is unreachable reports for it
   rather than exiting until the API answers.

   ```bash
   helm repo add costfluent https://costfluent.github.io/helm-charts
   helm upgrade -n costfluent cfa costfluent/costfluent-k8s-agent --install --create-namespace \
     --set agent.token=$COSTFLUENT_CLUSTER_TOKEN
   ```

The first report arrives about two minutes after the pod starts, and the cluster's last report then
shows under **Settings**, **Integrations**, **Kubernetes**.

To keep the token out of Helm values, store it in a Secret and point the chart at it:

```bash
kubectl -n costfluent create secret generic costfluent-token --from-literal=token=$COSTFLUENT_CLUSTER_TOKEN
helm upgrade -n costfluent cfa costfluent/costfluent-k8s-agent --install --create-namespace \
  --set agent.secret.name=costfluent-token
```

Rendering fails when a value is not one the chart knows, such as a misspelt key or a polling
interval the agent does not support (`values.schema.json` lists them), when `agent.clusterID` is
malformed, or when neither `agent.token` nor `agent.secret.name` is set.

## Rotate the token

A cluster token does not expire. It stops working when it is revoked, or when the account that
minted it is disabled or deleted; the API then refuses it with 401, the agent stops sending and,
after its next restart, exits at start. Replace it whenever it may have leaked, and before the
account that minted it leaves.

1. In Costfluent, open **Settings**, **Integrations**, **Kubernetes**, and choose **Mint token** on
   the cluster's row. Earlier tokens keep working until revoked.
2. Give it to the agent. With `agent.token`, upgrade the release with the new value. The chart
   rewrites its Secret, and a checksum of the token on the pod template rolls the agent pod:

   ```bash
   helm upgrade -n costfluent cfa costfluent/costfluent-k8s-agent --reuse-values \
     --set agent.token=$NEW_COSTFLUENT_CLUSTER_TOKEN
   ```

   With `agent.secret.name`, replace the token in that Secret and restart the agent yourself. The
   agent reads the token from its environment when it starts, so a changed Secret alone does not
   reach a running pod:

   ```bash
   kubectl -n costfluent create secret generic costfluent-token \
     --from-literal=token=$NEW_COSTFLUENT_CLUSTER_TOKEN --dry-run=client -o yaml | kubectl apply -f -
   kubectl -n costfluent rollout restart statefulset/cfa-costfluent-k8s-agent
   ```

3. Check the agent's log for a clean start, then revoke the old token under **Settings**,
   **API tokens**, with **Revoke token** on its row.

Reports the agent buffered while the token was refused are sent once it runs with the new one.

## Values

Every `agent.*` value sets one `COSTFLUENT_*` environment variable on the agent; the
[agent README](https://github.com/costfluent/k8s-agent#configuration) lists them.

| Value | Default | Purpose |
|---|---|---|
| `agent.token` | `""` | The cluster token. The chart stores it in a Secret it creates, and changing it rolls the pod. Set it, or `agent.secret.name`. |
| `agent.secret.name`, `agent.secret.key` | `""`, `token` | An existing Secret holding the token, used instead of `agent.token`. |
| `agent.clusterID` | the token's cluster | Optional: when set, the agent exits unless it is the token's cluster. |
| `agent.apiEndpoint` | `https://api.costfluent.com` | Where reports are sent. |
| `agent.pollingInterval` | `60` | Seconds between usage samples: 5, 10, 15, 30 or 60. |
| `agent.nodeAddressTypes` | `InternalIP,InternalDNS,Hostname,ExternalIP,ExternalDNS` | The node address types tried, in order, to reach each kubelet on port 10250. |
| `agent.disableKubeTLSverify` | `false` | Skip verifying kubelet serving certificates, for clusters whose kubelets serve self-signed ones (kind, Talos). |
| `agent.allowedLabels` | `[]` | Pod label keys to send. Empty sends every pod label. |
| `agent.allowedAnnotations` | `[]` | Pod annotation keys to send, at most 10. Empty sends none. |
| `agent.collectNamespaceLabels` | `false` | Send each namespace's labels with its pods. |
| `agent.collectPVCLabels` | `false` | Send each bound volume's claim labels. Grants `persistentvolumeclaims` `list`. |
| `agent.kubeAPIQPS`, `agent.kubeAPIBurst` | `50`, `100` | Requests a second, and the burst, the agent may make to the Kubernetes API server. |
| `agent.scrapeConcurrency` | `20` | The most kubelets scraped at once. The agent scrapes one at a time per 20 nodes, at least 10, up to this. |
| `agent.ownerCacheSize` | `20000` | How many resolved ReplicaSet and Job owners the agent remembers; size it above the cluster's ReplicaSets and Jobs that run pods. |
| `agent.reportHTTPProxy` | `""` | An HTTP proxy for report traffic only. |
| `agent.logLevel` | `info` | `debug`, `info`, `warn` or `error`. |
| `agent.extraEnv` | `[]` | Extra environment variables for the agent container. |
| `persist.mountPath` | `/var/lib/costfluent` | Where the unsent-report buffer, the open window's snapshot, the agent instance ID and the token's cluster live. |
| `persist.size`, `persist.storageClassName` | `1Gi`, `""` | The volume claim. Set `persist` to `null` for an emptyDir, which loses all of them when the pod is rescheduled. See **Persistence**. |
| `image.repository`, `image.tag`, `image.pullPolicy` | `ghcr.io/costfluent/k8s-agent`, the chart's `appVersion`, `IfNotPresent` | The agent image. |
| `resources` | requests `50m` CPU and `64Mi`, limit `256Mi` | See **Sizing**. |
| `nodeSelector`, `tolerations`, `affinity`, `priorityClassName` | empty | Scheduling. |
| `podLabels`, `podAnnotations` | `{}` | Added to the agent pod. |
| `serviceAccount.create`, `serviceAccount.name`, `serviceAccount.annotations` | `true`, the release name, `{}` | The agent's service account. |
| `service.port` | `9010` | Serves `/metrics`, `/healthz` and `/readyz`. |
| `serviceMonitor.enabled`, `serviceMonitor.interval`, `serviceMonitor.labels` | `false`, `60s`, `{}` | A Prometheus Operator ServiceMonitor for `/metrics`. |

[values.yaml](./values.yaml) holds the rest, including the pod and container security contexts.

### Persistence

`persist.size` and `persist.storageClassName`, and whether `persist` is `null`, are fixed at
install. They become the StatefulSet's volume claim template, which Kubernetes does not let an
upgrade change, so a `helm upgrade` that changes them fails. To change them, uninstall, delete the
claim as **Uninstall** shows, and install again; reports still buffered on the old volume are lost
with it. `persist.mountPath` only says where the volume is mounted, and an upgrade may change it.

An install checks the claim against the cluster's StorageClasses and stops before creating anything
when none would provision it: `persist.storageClassName` names a class the cluster does not have,
or is empty in a cluster with no default class. Such a claim would stay Pending, and the pod with
it, before the agent could log why. Name one of the cluster's classes (`kubectl get storageclass`),
or set `persist` to `null`. A render without a cluster, such as `helm template` or Argo CD, cannot
see the classes and is not checked.

With `persist: null` the agent's data lives in an emptyDir, which survives a container restart but
not the pod being rescheduled or deleted. The cluster the agent kept from its token goes with it,
so a rescheduled pod that cannot reach Costfluent at start exits until the API answers, unless
`agent.clusterID` is set.

## Sizing

The agent is one pod whatever the size of the cluster; its memory grows with the number of
containers it tracks. Measured in a kind cluster with 61 pods at a 5 second polling interval, the
agent's working set averaged 11.4 MiB with a 12.8 MiB peak, using under 0.001 CPU cores. The
defaults (`64Mi` requested, `256Mi` limit) also hold a cluster at the limits below: the agent's load
test (`make load`), against a fake API server and kubelets with 1,000 nodes, 50,000 realistic
pods and 1,000 persistent volumes, peaks at 165 MiB of Go heap and sends a 53 MiB report, 1.2 MiB
compressed. The chart passes
the container's memory limit to the agent, which keeps its heap under three quarters of it; raise
the limit if the pod is restarted for exceeding it.

Costfluent collects clusters of up to 1,000 nodes and 50,000 pods in one hourly report. The 50,000
counts every pod seen on a node during the hour, so short-lived pods such as Job runs count too, and
a pod that moved node counts once per node. A pod carries at most 100 containers. The agent does not
send a window over these limits: it logs that the cluster exceeds the size Costfluent collects and
sets `costfluent_agent_over_supported_size` to 1. Persistent volumes never hold a window back: past
50,000 volumes it sends the first by name and counts the rest in
`costfluent_agent_volumes_dropped_total`, and a pod mounting more than 32 claims sends its first 32
by name.

A label or annotation map carries at most 128 entries, with keys of at most 317 characters and
values of at most 1,024. The agent keeps the first 128 entries in key order that fit, drops the
rest, and counts them in `costfluent_agent_map_entries_dropped_total`.

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
| `persistentvolumes`, `storageclasses` (storage.k8s.io) | `list`, `watch` | Each volume's size, class and cloud disk, to price it and give it to the pods mounting its claim. |
| `persistentvolumeclaims` | `list` | Claim labels, only when `agent.collectPVCLabels` is true. |
| `namespaces` | `list` | Namespace labels, only when `agent.collectNamespaceLabels` is true. |
| `replicasets` (apps), `jobs` (batch) | `get` | Resolving a pod's ReplicaSet to its Deployment and a Job to its CronJob. |

No write verbs, no `secrets`, no `configmaps`, no `nodes/proxy`.

**What leaves the cluster.** The agent posts one gzip JSON report per window to
`{agent.apiEndpoint}/v1/kubernetes/reports`. Windows are UTC clock hours, except a first window
that closes about two minutes after start. **Fields** names each row's keys in the report JSON, inside
the array named before the colon.

| Sent | Detail | Fields |
|---|---|---|
| Report header | schema version, cluster ID, agent version, a random agent instance ID kept on the volume, window start and end | `schema_version`, `cluster_id`, `agent_version`, `agent_instance_id`, `window_start`, `window_end` |
| Node identity and shape | name, provider ID, instance type, region, zone, spot flag, seconds observed, CPU and memory capacity, allocatable CPU and memory | `nodes[]`: `name`, `provider_id`, `instance_type`, `region`, `zone`, `spot`, `observed_seconds`, `capacity_cpu_cores`, `capacity_memory_bytes`, `allocatable_cpu_cores`, `allocatable_memory_bytes` |
| Node GPUs | the capacity of each GPU resource of the families `nvidia.com/gpu`, `nvidia.com/gpu.shared`, `nvidia.com/mig-*` and `amd.com/gpu`, and **only** the GPU Feature Discovery labels `nvidia.com/mig.strategy`, `nvidia.com/gpu.product`, `nvidia.com/gpu.count`, `nvidia.com/gpu.replicas` and `nvidia.com/gpu.slices.gi`, sent apart from the node labels so their cap never drops them | `nodes[]`: `capacity_gpu`, `gpu_resources`, `gpu_labels` |
| Node labels | every node label | `nodes[]`: `labels` |
| Node annotations | **only** `costfluent.com/vcpu-hourly-rate`, `costfluent.com/ram-gb-hourly-rate`, `costfluent.com/gpu-hourly-rate` and `costfluent.com/physical-gpu-count`; nothing else | `nodes[]`: `annotations` |
| Pod identity | namespace, pod name, node name, controller kind and name | `pods[]`: `namespace`, `name`, `node`, `controller_kind`, `controller` |
| Pod labels | every label, minus `pod-template-hash`, `controller-revision-hash` and `statefulset.kubernetes.io/pod-name`; only the keys in `agent.allowedLabels` when it is set | `pods[]`: `labels` |
| Pod annotations | none, unless named in `agent.allowedAnnotations` (at most 10 keys, values cut to 100 characters) | `pods[]`: `annotations` |
| Namespace labels | none, unless `agent.collectNamespaceLabels` is true | `pods[]`: `namespace_labels` |
| Pod volume claims | the names of the persistent volume claims each pod mounts, a generic ephemeral volume's as `<pod>-<volume>` | `pods[]`: `claims` |
| Container usage | container name, seconds observed, CPU and memory requests, the request of each GPU resource of those families (its limit when it sets no request), CPU and memory usage and allocation integrated over the window, and peak CPU and memory usage | `pods[].containers[]`: `name`, `observed_seconds`, `cpu_request_cores`, `memory_request_bytes`, `gpu_request`, `gpu_requests`, `cpu_usage_core_seconds`, `memory_usage_byte_seconds`, `cpu_allocated_core_seconds`, `memory_allocated_byte_seconds`, `cpu_usage_peak_cores`, `memory_usage_peak_bytes` |
| Persistent volumes | for each volume in any phase: name, capacity, storage class, CSI driver (or the in-tree plugin `kubernetes.io/aws-ebs`, `azure-disk` or `gce-pd`), volume handle **only** for an AWS EBS, Azure Disk or GCP Persistent Disk volume (the cloud disk's id, to match it to its bill; no other driver's handle, so an NFS or SMB server and share never leave the cluster), phase, the claim's namespace and name when Bound, and seconds observed | `volumes[]`: `name`, `capacity_bytes`, `storage_class`, `csi_driver`, `volume_handle`, `phase`, `claim_namespace`, `claim_name`, `observed_seconds` |
| Storage class annotations | **only** `costfluent.com/storage-gb-hourly-rate`, with each volume of that class | `volumes[]`: `storage_class_annotations` |
| Claim labels | none, unless `agent.collectPVCLabels` is true; then every label of each Bound volume's claim | `volumes[]`: `claim_labels` |

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

## GPU nodes

A GPU's cost is shared by its MIG devices and time-sliced replicas, each counted as its share of a
physical GPU, from the labels the NVIDIA GPU Operator's GPU Feature Discovery writes. A node without
those labels counts each device as a GPU; state its physical GPUs instead:

```bash
kubectl annotate node gpu-1 costfluent.com/physical-gpu-count=1
```

## Troubleshooting

```bash
kubectl -n costfluent get pods -l app.kubernetes.io/instance=cfa
kubectl -n costfluent logs -l app.kubernetes.io/instance=cfa -f
kubectl -n costfluent port-forward svc/cfa-costfluent-k8s-agent 9010:9010 && curl -s localhost:9010/metrics
```

- **401 or 403 in the logs, or "is not a cluster token":** the token is wrong, revoked, or not the
  cluster's own token. At start the agent exits with the reason and the pod restarts; use **Mint
  token** on the cluster, update the token, restart the pod, and the buffered reports are sent.
- **"is not the cluster ... the API token belongs to":** `agent.clusterID` names another cluster
  than the token's; remove it, or use that cluster's token.
- **410 in the logs:** the cluster was deleted in Costfluent; add it again and install its new
  token, or uninstall the agent.
- **400 in the logs:** the report was refused, and the log names the reason. When it says the
  cluster has more nodes or pods than Costfluent collects, contact support. When it says the node's
  clock is ahead of Costfluent's, the report was refused as ending in the future: the agent keeps it
  and retries until it is accepted, for up to 96 hours, and the log names the skew; fix the node's time sync (NTP).
  Otherwise upgrade the agent.
- **Kubelet scrapes failing with a certificate error:** the kubelets serve self-signed
  certificates; set `agent.disableKubeTLSverify=true`.
- **Install stops with "no default StorageClass" or "which this cluster does not have":** no
  class would provision the agent's volume; see **Persistence**.
- **Pod pending:** check the volume claim (`kubectl -n costfluent get pvc`) or set `persist=null`.

## Uninstall

```bash
helm uninstall -n costfluent cfa
kubectl -n costfluent delete pvc -l app.kubernetes.io/instance=cfa
```

## Support

- Documentation: <https://docs.costfluent.com/connect/kubernetes>
- Issues: <https://github.com/costfluent/helm-charts/issues>
