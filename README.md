# Production Ready SIEM Deployment

> Wazuh multi node cluster lab (distributed architecture)


A complete, distributed Wazuh deployment lab built on the official Wazuh documentation
(current release 4.14.0). This is not the all in one quickstart. It builds a full
distributed architecture: a 3 node Wazuh indexer cluster, a Wazuh server cluster
(1 master, 2 workers), a dedicated dashboard, an HAProxy load balancer for agent
traffic, 4 endpoint agents (2 Windows, 2 Ubuntu) with automatic group assignment,
centralized configuration, mass deployment simulation, and full index and shard
management.

Reference: https://documentation.wazuh.com/current/

## Topology

| VM | IP | FQDN | Role |
|----|-----|------|------|
| wazuh-indexer-01 | 10.10.10.11 | wazuh-indexer-01.lab.local | Indexer node (cluster manager eligible) |
| wazuh-indexer-02 | 10.10.10.12 | wazuh-indexer-02.lab.local | Indexer node (cluster manager eligible) |
| wazuh-indexer-03 | 10.10.10.13 | wazuh-indexer-03.lab.local | Indexer node (cluster manager eligible) |
| wazuh-master-01 | 10.10.10.21 | wazuh-master-01.lab.local | Server cluster master |
| wazuh-worker-01 | 10.10.10.22 | wazuh-worker-01.lab.local | Server cluster worker |
| wazuh-worker-02 | 10.10.10.23 | wazuh-worker-02.lab.local | Server cluster worker |
| wazuh-dashboard-01 | 10.10.10.31 | wazuh-dashboard.lab.local | Dashboard |
| wazuh-lb-01 | 10.10.10.40 | wazuh-lb.lab.local | HAProxy load balancer |
| win-agent-01 | 10.10.10.101 | win-agent-01.lab.local | Windows endpoint |
| win-agent-02 | 10.10.10.102 | win-agent-02.lab.local | Windows endpoint |
| ubuntu-agent-01 | 10.10.10.111 | ubuntu-agent-01.lab.local | Ubuntu endpoint |
| ubuntu-agent-02 | 10.10.10.112 | ubuntu-agent-02.lab.local | Ubuntu endpoint |

## Project structure

```
wazuh-multinode-lab/
  README.md                         This file
  01-overview/                      Architecture overview and ASCII diagram
  02-resource-planning/             CPU, RAM, disk sizing (min lab and prod like)
  03-network/                       Firewall matrix, UFW and iptables examples
  04-checklist/                     Pre deployment checklist and /etc/hosts
  05-deployment-sequence/           Ordered deployment plan with rationale
  06-indexer-cluster/               3 node indexer cluster deployment
  07-server-cluster/                Master and worker cluster configuration
  08-dashboard/                     Dashboard deployment and validation
  09-load-balancer/                 HAProxy primary, NGINX stream alternative
  10-agent-grouping/                windows and linux groups
  11-centralized-config/            Per group agent.conf
  12-rules-decoders/                Custom rules and decoders management
  13-windows-deployment/            GPO startup script and PowerShell Remoting
  14-linux-ansible/                 Ansible inventory and playbook
  15-index-shard-management/        Index, shard, retention, ISM, capacity, runbook
  16-validation/                    End to end validation and success criteria
  configs/                          Ready to copy config files
  scripts/                          Ready to copy scripts
```

## How to use

Read the numbered folders in order. Each folder is self contained and maps to a
deployment stage. The `configs/` and `scripts/` folders hold the same files in
copy ready form so you can deploy without extracting them from the docs.

## Conventions

- All agents enroll and report through the load balancer FQDN `wazuh-lb.lab.local`,
  never directly to a worker.
- Windows endpoints land in the `windows` group automatically via `WAZUH_AGENT_GROUP`.
- Ubuntu endpoints land in the `linux` group automatically via `WAZUH_AGENT_GROUP`.
- Rules and decoders live only on the manager. Agents only ship logs.
- All cluster configuration changes are made on the master and replicated manually.
- Snapshots of every VM are taken before installation.
