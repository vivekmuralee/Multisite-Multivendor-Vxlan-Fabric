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
- Ansible from the repo venv (`make venv`). The pinned `ansible==9.2.0` already bundles the
  two collections the playbook uses; with bare ansible-core, install
  [requirements.yml](requirements.yml).

## Building the VMs (manual, before the playbook)
The VMs are not created by Ansible. They are Ubuntu 24.04.5 clones on libvirt, and their
exported definitions are in [libvirt/](libvirt/):

| File | What |
|---|---|
| `libvirt/network.xml` | libvirt network `network` (virbr0, NAT, 192.168.122.0/24, DHCP .128-.240) |
| `libvirt/kubemaster-{1..3}.xml` | 2 vCPU, 8 GiB, 50 GB qcow2 in `/var/lib/libvirt/images/` |
| `libvirt/kubeworker-{1..3}.xml` | 8 vCPU, 32 GiB, 50 GB qcow2 |
| `libvirt/netplan-50-cloud-init.yaml.example` | static IP per node (.91-.96) |

To rebuild from scratch:
```
virsh net-define libvirt/network.xml && virsh net-start network && virsh net-autostart network
# Create each disk (clone of the Ubuntu base image) at the path in the XML, then:
virsh define libvirt/kubemaster-1.xml && virsh start kubemaster-1     # repeat per node
# On each console: set the static IP from the netplan example, `sudo netplan apply`,
# and add your SSH key for vivekmuralee.
```
The exported XMLs carry each VM's UUID and MAC; drop those lines if you define them next
to the existing VMs. kubemaster-1 uses an e1000e NIC (`enp8s0`); the rest use virtio (`enp1s0`).
The playbook's first play then gives each clone a unique machine-id and SSH host keys.

## Run
```
make run VENDOR=kubernetes                      # everything
make run VENDOR=kubernetes ARGS="--tags prep"   # identity|prep|kubevip|init|join|cni|metallb|kubelet|metrics|disk|cpmetrics|storage|monitoring|mimir|snmp|bgp|gnmi
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

## SNMP monitoring of the Cumulus fabric
`--tags snmp` installs prometheus-snmp-exporter (chart 9.21.1) in `monitoring`, with one
ServiceMonitor per switch (`snmp_targets`, 192.168.122.32-39, module `if_mib`, SNMPv2c).
Prometheus picks them up and remote_writes to Mimir like everything else.

- The switches must have SNMP enabled first: step "SNMP monitoring" in each
  `cumulus/samples/*_sample_config.txt` (or the `cumulus_underlay` role).
- `snmp_community` here must match `cumulus/group_vars/all/vars.yml`. v2c is clear text, so it
  is read-only and limited to 192.168.122.0/24; use SNMPv3 beyond a lab.
- Check: Prometheus -> Status -> Targets (`snmp-prometheus-snmp-exporter-*`), then query
  `ifHCInOctets{target="cl-lf-1"}`. More modules: add names to `snmp_modules`
  (the bundled `/etc/snmp_exporter/snmp.yml` is loaded alongside the custom auth).
- **Dashboard:** "Cumulus VXLAN Fabric" (uid `cumulus-fabric`) is deployed from
  `dashboards/cumulus-fabric.json` as a labelled ConfigMap that Grafana's sidecar picks up:
  http://192.168.122.60/d/cumulus-fabric. Tiles for reachability, port state, traffic and errors;
  BGP sessions (see below); per-switch traffic, SVI (VLAN 10/20/30) and VXLAN (vxlan48/vxlan99)
  traffic; CPU, memory, load and uptime; and a per-port UP/DOWN table. Edit the JSON and re-run
  `--tags snmp` (the dashboard ships with that tag).

## BGP session monitoring (NVUE REST API)
SNMP cannot report the fabric's BGP sessions: the underlay is BGP unnumbered, and FRR's BGP4-MIB
peer table only lists peers with an IPv4 address. `--tags bgp` installs prometheus-json-exporter
(chart 0.20.2) in `monitoring`, with one ServiceMonitor per switch (plus one for VRF `TENANT_A` on
the border leafs, where the PE peers will appear), reading
`https://<switch>:8765/nvue_v1/vrf/<vrf>/router/bgp/neighbor`.

- **Metrics:** `bgp_peer_info{target,peer,vrf,remote_as,state}` (constant 1; state is a label),
  `bgp_peer_uptime_msec`, `bgp_peer_connections_dropped`, `bgp_peer_prefixes_ipv4_unicast`,
  `bgp_peer_prefixes_l2vpn_evpn`. Sessions up = `count(bgp_peer_info{state="established"})`
  (24 in this fabric: 6+6 on the spines, 2 on each leaf and border leaf).
- **Switches first:** the REST API is off on Cumulus 5.4. Each sample's "NVUE REST API" step (or the
  `cumulus_underlay` role) creates the read-only `monitor` user (role `nvue-monitor`) and enables
  the API's nginx site on :8765. `nvue_api_password` here must match the hash in
  `cumulus/group_vars/all/vars.yml`. Basic auth over self-signed HTTPS (certificate not verified);
  lab-grade.
- The exporter pod is restarted on every run (the chart does not roll pods on config changes).
- Dashboard row "BGP sessions": established / not established / resets (1h) tiles, EVPN routes
  received per switch, a per-peer table (state, uptime, IPv4 and EVPN prefixes) and an UP/DOWN timeline.

## gNMI telemetry of the Arista fabric
`--tags gnmi` runs one `gnmic` pod (`ghcr.io/openconfig/gnmic:0.49.1`) in `monitoring`. It holds a
gNMI `Subscribe` stream (sample, 30s) to each of the 6 Arista switches (`gnmi_targets`,
192.168.122.24-29:6030, user `monitor`) and serves the result as Prometheus metrics on `:9804`
(ServiceMonitor `gnmic`, so Prometheus and, via remote_write, Mimir get them too).

- **Subscriptions** (in `templates/gnmic.yaml.j2`): `/interfaces/interface/state/{oper-status,admin-status,description,counters}`,
  BGP `.../neighbors/neighbor/state` and `.../afi-safis/afi-safi/state/prefixes` (all VRFs), and
  `/system/cpus/cpu[index=ALL]/state/idle/instant`, `/system/memory/state`.
- **Metrics:** `gnmi_<path>` with `source` = switch name. Strings become labels
  (`oper_status="UP"`, `session_state="ESTABLISHED"`), so state is a label on a constant 1.
  Examples: `gnmi_interfaces_interface_state_counters_in_octets{source,interface_name}`,
  `gnmi_network_instances_..._neighbor_state_session_state{source,network_instance_name,neighbor_neighbor_address,session_state}`.
  Series expire 150s after a switch stops streaming.
- **Switches first:** `arista/` role `arista_base`, tag `telemetry` (see [arista/README.md](../arista/README.md)).
  The password in `group_vars/all.yml` (`gnmi_password`) must match the hash in
  `arista/group_vars/all/vars.yml`. It sits in Secret `gnmic-config`.
- **Dashboard:** "Arista VXLAN Fabric" (uid `arista-fabric`, from `dashboards/arista-fabric.json`),
  http://192.168.122.60/d/arista-fabric: reachability, cabled-port state, traffic and errors; BGP
  sessions (tiles, per-peer table with state/uptime/prefixes, UP/DOWN timeline, EVPN routes per
  switch); CPU, memory, youngest-session age. Port panels only list ports that have a
  description (spare EOS ports are admin-up and would otherwise read as faults).
- The pod is restarted on every run (the config is a mounted Secret, read only at start).

### Arista VXLAN Statistics dashboard

"Arista VXLAN Statistics" (uid `arista-vxlan`, `dashboards/arista-vxlan.json`,
http://192.168.122.60/d/arista-vxlan): overview tiles, **L2 VNI** and **L3 VNI** status tables, remote
VTEPs, EVPN prefixes, an **IP table** of every IPv4 address with its interface state, and Vxlan1/SVI traffic.

- **IP table** comes from gNMI (`ipaddr` subscription in `templates/gnmic.yaml.j2`).
- **VNI / VTEP data** comes from the switches' eAPI, polled by json-exporter (module `eos_vxlan`, POST
  `/command-api` with `show vxlan vni` + `show vxlan vtep`), because EOS has no OpenConfig VXLAN model.
  Targets and the expected VNIs are `arista_eapi_targets`, `arista_l2_vnis`, `arista_l3_vnis` in
  `group_vars/all.yml`; keep the VNIs in step with `arista/group_vars/all/vars.yml`.
- **Switch prerequisite (manual, VTEPs):** enable eAPI in the mgmt VRF
  ```
  management api http-commands
     protocol https
     no shutdown
     !
     vrf mgmt
        no shutdown
  ```
- Deploy: `ansible-playbook site.yml --tags gnmi,bgp`. The JSON paths in the `eos_vxlan` module were written
  from the documented EOS `show vxlan vni | json` layout and are not yet validated against a live switch.
