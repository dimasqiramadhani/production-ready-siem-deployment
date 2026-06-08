# 4. Pre deployment Checklist

Complete every item before installing any Wazuh package.

## 4.1 Checklist

- [ ] **OS baseline**: Ubuntu 22.04/24.04 LTS on all Linux nodes, fully updated
      (`apt update && apt upgrade`). Windows Server 2019/2022 or Windows 10/11 on
      agents.
- [ ] **Hostname**: set each node hostname to match the topology
      (`hostnamectl set-hostname wazuh-indexer-01`).
- [ ] **Static IP**: assign the fixed IP from the topology table to each node.
- [ ] **DNS or /etc/hosts**: every node must resolve every other node by FQDN. Use
      the shared `/etc/hosts` below if you have no internal DNS.
- [ ] **NTP / time sync**: enable `systemd-timesyncd` or chrony on all nodes. Clock
      drift breaks TLS and cluster sync.
- [ ] **Firewall**: open the ports from section 3 before install, or temporarily
      disable and re enable after.
- [ ] **Package dependencies**: `curl`, `apt-transport-https`, `gnupg`, `lsb-release`
      on Linux nodes.
- [ ] **Certificate planning**: decide node names now; they must match the cert
      common names. Generate certs centrally on one node and copy out.
- [ ] **Disk planning**: confirm indexer data path has the planned disk; mount a
      separate volume on `/var/lib/wazuh-indexer` if possible.
- [ ] **VM snapshot**: snapshot every VM in a clean post OS state before installing
      Wazuh. This is your rollback point.
- [ ] **Internet access / repo**: nodes can reach `packages.wazuh.com` or you have a
      local mirror for offline install.
- [ ] **User privilege / sudo**: an admin user with sudo on every Linux node.
- [ ] **SSH access between nodes**: at least from the node you run cert generation
      and Ansible on, to all others, ideally key based.
- [ ] **Browser access**: a workstation that can reach
      `https://wazuh-dashboard.lab.local` on 443.
- [ ] **Validate ports between nodes**: test reachability before install with
      `nc -vz <host> <port>`.
- [ ] **Enrollment password planning**: decide whether to enable an enrollment
      password. If yes, set it on the master and distribute via `WAZUH_REGISTRATION_PASSWORD`.
- [ ] **Backup directory planning**: decide the snapshot repository path and a config
      backup location (see section 15-I).

## 4.2 Shared /etc/hosts for all Linux servers

Place this in `/etc/hosts` on every Linux node (also see `configs/hosts`).

```
127.0.0.1   localhost

# Wazuh indexer cluster
10.10.10.11 wazuh-indexer-01.lab.local wazuh-indexer-01
10.10.10.12 wazuh-indexer-02.lab.local wazuh-indexer-02
10.10.10.13 wazuh-indexer-03.lab.local wazuh-indexer-03

# Wazuh server cluster
10.10.10.21 wazuh-master-01.lab.local wazuh-master-01
10.10.10.22 wazuh-worker-01.lab.local wazuh-worker-01
10.10.10.23 wazuh-worker-02.lab.local wazuh-worker-02

# Dashboard and load balancer
10.10.10.31 wazuh-dashboard.lab.local wazuh-dashboard-01
10.10.10.40 wazuh-lb.lab.local wazuh-lb-01

# Agents
10.10.10.101 win-agent-01.lab.local win-agent-01
10.10.10.102 win-agent-02.lab.local win-agent-02
10.10.10.111 ubuntu-agent-01.lab.local ubuntu-agent-01
10.10.10.112 ubuntu-agent-02.lab.local ubuntu-agent-02
```

On Windows agents add the same entries to
`C:\Windows\System32\drivers\etc\hosts`, at minimum the load balancer line:

```
10.10.10.40 wazuh-lb.lab.local
```
