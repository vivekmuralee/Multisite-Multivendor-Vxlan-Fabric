# Multisite-Multivendor-Vxlan-Fabric
Ansible and Python program files for deploying Vxlan Fabric and Telemetry 

This project will help in deploying a Multisite Multivendor Vxlan BGP-EVPN on a GNS3 platform 

The project will have a Vxlan fabric running on several different platforms with individual fabric running on different vendor platforms

Platforms Listed below 

1.Cisco NXOS 9K  
2.Arista EOS
3.Cumulus OS


All the above mentioned platforms will have a datacenter fabric running Vxlan EVPN 

All the different fabric will be interconnected over an MPLS Routing backbone running on Cisco IOS platform 

Phase-1 

Phase-1 will be to built Vxlan fabric on all the different platform and advertising the different overlay networks to the routing backbone

Phase-2

To deploy an MPLS backbone on Cisco IOS platform with OSPF underlay and BGP vpnv4 overlay 

Advertise the learned routes from the different VXlan fabric between each other using BGP vnpv4 and Route-Target

Phase-3

Define a Multisite network which is supported between 2 different Vxlan fabrics using BGP underlay and testing failover.

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
