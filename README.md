# Multisite-Multivendor-Vxlan-Fabric

Ansible and Python files for deploying a multisite, multivendor VXLAN BGP-EVPN fabric and its telemetry, built on a GNS3 platform.

Each site runs its own VXLAN fabric on a different vendor platform:

1. Cisco NX-OS 9K
2. Arista EOS
3. Cumulus Linux

The fabrics are interconnected over an MPLS routing backbone running on Cisco IOS.

## Phases

**Phase 1:** Build a VXLAN fabric on each platform and advertise the overlay networks to the routing backbone.

**Phase 2:** Deploy an MPLS backbone on Cisco IOS with an OSPF underlay and a BGP vpnv4 overlay. Exchange the routes learned from each VXLAN fabric using BGP vpnv4 and route targets.

**Phase 3:** Define a multisite network between two VXLAN fabrics using a BGP underlay, and test failover.


## Repository layout

| Directory | What it contains |
|---|---|
| [arista/](arista/) | Arista EOS BGP-EVPN VXLAN fabric (Ansible, vault for secrets) |
| [cumulus/](cumulus/) | Cumulus Linux BGP-EVPN VXLAN fabric (Ansible roles, NVUE samples, runbook) |
| [kubernetes/](kubernetes/) | HA kubeadm Kubernetes lab cluster with MetalLB, Prometheus, Grafana and Mimir |
| [inventory/](inventory/) | Shared inventory |

## Getting started

```
make venv                                        # create .venv with the pinned Ansible
make run VENDOR=cumulus PLAYBOOK=site.yml        # run a vendor playbook
make run VENDOR=kubernetes                       # build the Kubernetes lab cluster
make check VENDOR=arista                         # dry-run with --check --diff
make help                                        # all targets
```

## Telemetry: Kubernetes monitoring cluster

A 6-VM Kubernetes cluster (3 control-plane, 3 workers) on libvirt hosts the monitoring stack
for the fabric. It is built by [kubernetes/site.yml](kubernetes/site.yml):

| Component | Detail |
|---|---|
| Kubernetes | kubeadm, containerd, HA API behind a kube-vip VIP (192.168.122.90) |
| CNI | Calico via tigera-operator |
| LoadBalancer | MetalLB L2, pool 192.168.122.50-79 |
| Storage | local-path-provisioner (default StorageClass) |
| Metrics | metrics-server, kube-prometheus-stack (Prometheus .61, Grafana .60, Alertmanager .62) |
| Long-term metrics | Grafana Mimir (tenant `infra`, 30d), fed by Prometheus remote_write |

The VM definitions (libvirt XML, netplan example) are in [kubernetes/libvirt/](kubernetes/libvirt/).
See [kubernetes/README.md](kubernetes/README.md) for prerequisites, run steps and rebuild instructions.
