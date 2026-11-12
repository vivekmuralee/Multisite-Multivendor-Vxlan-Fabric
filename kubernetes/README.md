# Kubernetes lab cluster (kubeadm, HA)

3 control-plane + 3 worker VMs on the libvirt `network` (virbr0, 192.168.122.0/24).

| VM | vCPU | RAM (fixed, max = current) |
|---|---|---|
| kubemaster-1..3 | 2 | 8 GiB |
| kubeworker-1..3 | 8 | 32 GiB |

Keep worker RAM fixed (no balloon headroom): the kubelet reads memory at boot, so a
max > current setting makes Kubernetes schedule against RAM the VM doesn't have.
To resize a worker: `kubectl drain`, `virsh shutdown`, `virsh setmaxmem/setmem <vm> <N>G --config`,
`virsh start`, `kubectl uncordon`.

| Item | Value |
|---|---|
| Kubernetes | v1.37.2 (kubeadm, containerd 2.x from Docker's repo) |
| API VIP | 192.168.122.90:6443 (kube-vip, ARP, leader election) |
| CNI | Calico v3.33.0 via tigera-operator, VXLANCrossSubnet |
| Pod / Service CIDR | 10.244.0.0/16 / 10.96.0.0/12 |
| Metrics | metrics-server v0.9.1 (HA, 2 replicas), `kubectl top nodes/pods` |
| Storage | local-path-provisioner v0.0.37 (default StorageClass, node-local) |
| Monitoring | kube-prometheus-stack 93.2.2 (Prometheus, Alertmanager, Grafana 13) |
| Long-term metrics | Grafana Mimir 3.2.3 (chart mimir-distributed 6.2.2), tenant `infra`, 30d |
| LoadBalancer IPs | MetalLB v0.16.2, L2 mode, pool `lab-pool` 192.168.122.50-79 |

## Prerequisites
- SSH key login as `vivekmuralee` on every node, with passwordless sudo.

## Run
```
make run VENDOR=kubernetes                      # everything
make run VENDOR=kubernetes ARGS="--tags prep"   # identity|prep|kubevip|init|join|cni|metallb|kubelet|metrics|disk|cpmetrics|storage|monitoring|mimir
```
The first play regenerates `/etc/machine-id` and SSH host keys once (the VMs are clones)
and reboots each node; a marker in `/etc/k8s-node-identity-regenerated` prevents repeats.

Kubeconfig is fetched to `kubernetes/artifacts/kubeconfig` (git-ignored):
```
export KUBECONFIG=$PWD/kubernetes/artifacts/kubeconfig
kubectl get nodes -o wide
```
Every step is idempotent: already-initialized/joined nodes are skipped.

## Exposing an application (MetalLB)
Give the Service `type: LoadBalancer`; MetalLB assigns the next free IP from the pool and
answers ARP for it from one node (fails over to another node if that one goes down).
```
kubectl create deployment myapp --image=nginx:alpine
kubectl expose deployment myapp --port 80 --type LoadBalancer
kubectl get svc myapp            # EXTERNAL-IP 192.168.122.5x
```
To pin a specific address, add the annotation
`metallb.io/loadBalancerIPs: 192.168.122.60` to the Service.

The pool lives on the libvirt NAT network, so these IPs are reachable from this workstation
(and the VMs) only. To reach them from elsewhere on your LAN you need a route to
192.168.122.0/24 via this host, or a port-forward / reverse proxy on the host.

## Kubelet reservations and serving certs
Drop-in `/etc/kubernetes/kubelet.conf.d/50-reservations.conf` (enabled via
`KUBELET_EXTRA_ARGS=--config-dir=...` in `/etc/default/kubelet`), so `kubeadm upgrade` keeps it.

| Group | systemReserved | kubeReserved | evictionHard memory | Allocatable |
|---|---|---|---|---|
| masters | 250m / 512Mi | 250m / 512Mi | 300Mi | 1.5 CPU / ~6.5 GiB |
| workers | 500m / 1Gi | 500m / 1Gi | 500Mi (soft 1000Mi, 90s) | 7 CPU / ~28.9 GiB |

`serverTLSBootstrap: true` makes each kubelet request a CA-signed serving cert; the playbook
approves only `kubelet-serving` CSRs whose requester is `system:node:<inventory host>`.
metrics-server therefore verifies kubelet TLS normally (no `--kubelet-insecure-tls`).
Serving certs renew automatically about yearly; renewal CSRs need approval, so re-run
`make run VENDOR=kubernetes VENV=../../../.venv ARGS="--tags metrics"` (or
`kubectl certificate approve` after checking the requester) if `kubectl logs`/`top` start failing.

## Calico API mode
Calico v3.33 runs with native `projectcalico.org/v3` CRDs (`CALICO_API_GROUP=projectcalico.org/v3`).
Do **not** apply the legacy `crd.projectcalico.org/v1` CRDs (they're bundled in upstream
`operator-crds.yaml`; the playbook filters them out): if both groups exist, the operator
falls back to v1 mode on its next restart, deploys an unused `calico-apiserver`, and reports
`calico` Degraded with "waiting for enabled IP pools to be created". The `cni` stage asserts
they're absent. The `APIServer` CR stays: in v3 mode it only runs `calico-webhooks`
(validation for v3 resources).

## Monitoring (Prometheus + Grafana)
| UI | URL | Auth |
|---|---|---|
| Grafana | http://192.168.122.60 | `admin` / password in `kubernetes/artifacts/grafana-admin-password` (git-ignored; also secret `monitoring/grafana-admin`) |
| Prometheus | http://192.168.122.61:9090 | none |
| Alertmanager | http://192.168.122.62:9093 | none |

Prometheus keeps 15 days / 18 GB on a 20 Gi local-path volume. Grafana ships ~29 dashboards
(Kubernetes / Compute Resources, Node Exporter, etcd, API server, ...).

**Scraping your own apps:** Prometheus watches ServiceMonitors/PodMonitors/PrometheusRules in
*every* namespace (no Helm label needed). Expose `/metrics` and add e.g.:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata: { name: myapp, namespace: myapp }
spec:
  selector: { matchLabels: { app: myapp } }
  endpoints: [{ port: http, path: /metrics, interval: 30s }]
```

**Control-plane metrics:** the `cpmetrics` stage binds kube-controller-manager/scheduler
(HTTPS, authn/authz) and etcd's metrics listener (metrics only, port 2381) to 0.0.0.0, and
kube-proxy metrics to 0.0.0.0:10249, both in the static pod manifests and in the
`kubeadm-config` ConfigMap so `kubeadm upgrade` keeps them.

**Storage caveat:** local-path volumes live on one node's disk (`/opt/local-path-provisioner`).
If that node is lost, the volume's data is lost and the pod can't reschedule elsewhere until
the PVC is deleted. Fine for lab metrics; use replicated storage (e.g. Longhorn) for
anything you can't lose.

## Long-term metrics (Grafana Mimir)
Prometheus keeps 15 days locally and `remote_write`s every sample to Mimir under tenant
**`infra`** (`X-Scope-OrgID: infra`, external label `cluster=kube-lab`). Mimir keeps
**30 days** (`mimir_retention`) in object storage.

- **Grafana:** data source **"Mimir (infra)"** (uid `mimir-infra`) sits next to "Prometheus".
  Use it for long time ranges or for anything you want to survive a Prometheus volume loss.
  The 27 "Mimir / ..." dashboards monitor Mimir itself.
- **Endpoints (in-cluster only):** push `http://mimir-gateway.mimir.svc/api/v1/push`,
  query `http://mimir-gateway.mimir.svc/prometheus`. Every request needs `X-Scope-OrgID`;
  each tenant only sees its own data, so a new team/environment can use its own tenant ID.
- **Architecture (chart defaults):** Kafka ingest path, 3 zone-aware ingesters and store-gateways
  (one per worker), MinIO (single instance, 25 Gi local-path) as the S3 bucket store,
  plus self-monitoring ServiceMonitors, dashboards and alert/recording rules.
- **Secrets:** MinIO password in `kubernetes/artifacts/mimir-minio-password` (git-ignored);
  Mimir's config (which contains the S3 keys) is stored as Secret `mimir/mimir-config`.
- **Caveat:** MinIO and Kafka are single-instance on local-path volumes, so losing that worker
  loses the long-term history. For real durability point Mimir at external S3/MinIO
  (`mimir.structuredConfig.common.storage`) and disable the bundled MinIO.
