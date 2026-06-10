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
192.168.90.111 wazuh-indexer-01.lab.local wazuh-indexer-01
192.168.90.113 wazuh-indexer-02.lab.local wazuh-indexer-02
192.168.90.114 wazuh-indexer-03.lab.local wazuh-indexer-03

# Wazuh server cluster
192.168.90.115 wazuh-master-01.lab.local wazuh-master-01
192.168.90.116 wazuh-worker-01.lab.local wazuh-worker-01
192.168.90.117 wazuh-worker-02.lab.local wazuh-worker-02

# Dashboard and load balancer
192.168.90.118 wazuh-dashboard.lab.local wazuh-dashboard-01
192.168.90.112 wazuh-lb.lab.local wazuh-lb-01

# Endpoints
192.168.90.121 windows-ad-dc.lab.local windows-ad-dc
192.168.90.122 win-agent-01.lab.local win-agent-01
192.168.90.123 win-agent-02.lab.local win-agent-02
192.168.90.119 ubuntu-agent-01.lab.local ubuntu-agent-01
192.168.90.120 ubuntu-agent-02.lab.local ubuntu-agent-02
```

On Windows agents add the same entries to
`C:\Windows\System32\drivers\etc\hosts`, at minimum the load balancer line:

```
192.168.90.112 wazuh-lb.lab.local
```

## 4.3 Stage 0 executed procedures (this lab)

These are the exact baseline steps run on the 8 server side nodes before any Wazuh
package was installed. Run on every node unless noted.

### Step 1: Update OS

```bash
sudo apt update && sudo apt upgrade -y
```

### Step 2: Set hostname (per node)

```bash
sudo hostnamectl set-hostname wazuh-indexer-01   # 192.168.90.111
sudo hostnamectl set-hostname wazuh-indexer-02   # 192.168.90.113
sudo hostnamectl set-hostname wazuh-indexer-03   # 192.168.90.114
sudo hostnamectl set-hostname wazuh-master-01    # 192.168.90.115
sudo hostnamectl set-hostname wazuh-worker-01    # 192.168.90.116
sudo hostnamectl set-hostname wazuh-worker-02    # 192.168.90.117
sudo hostnamectl set-hostname wazuh-lb-01        # 192.168.90.112
sudo hostnamectl set-hostname wazuh-dashboard-01 # 192.168.90.118
```

### Step 3: /etc/hosts (append on every node)

```bash
sudo tee -a /etc/hosts <<'EOF'

# Wazuh lab nodes
192.168.90.111  wazuh-indexer-01.lab.local  wazuh-indexer-01
192.168.90.113  wazuh-indexer-02.lab.local  wazuh-indexer-02
192.168.90.114  wazuh-indexer-03.lab.local  wazuh-indexer-03
192.168.90.115  wazuh-master-01.lab.local   wazuh-master-01
192.168.90.116  wazuh-worker-01.lab.local   wazuh-worker-01
192.168.90.117  wazuh-worker-02.lab.local   wazuh-worker-02
192.168.90.112  wazuh-lb.lab.local          wazuh-lb-01
192.168.90.118  wazuh-dashboard.lab.local   wazuh-dashboard-01
EOF
```

### Step 4: Time sync with chrony

```bash
sudo apt install -y chrony
sudo systemctl enable chrony
sudo systemctl start chrony
chronyc tracking   # confirm System time offset under 1 second
```

### Step 5: Swap 4 GB (mandatory, compensates 2 GB RAM)

```bash
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
free -h
```

### Step 6: Kernel tuning for OpenSearch (indexer nodes only)

```bash
echo 'vm.max_map_count=262144' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
sysctl vm.max_map_count   # must report 262144
```

### Step 7: Base dependencies

```bash
sudo apt install -y curl gnupg apt-transport-https lsb-release ca-certificates wget
```

### Step 8: Firewall (UFW) per role

Indexer (111, 113, 114):
```bash
sudo ufw allow 22/tcp
sudo ufw allow 9200/tcp
sudo ufw allow 9300:9400/tcp
sudo ufw --force enable
```

Master (115):
```bash
sudo ufw allow 22/tcp
sudo ufw allow 1514/tcp
sudo ufw allow 1515/tcp
sudo ufw allow 1516/tcp
sudo ufw allow 55000/tcp
sudo ufw --force enable
```

Workers (116, 117):
```bash
sudo ufw allow 22/tcp
sudo ufw allow 1514/tcp
sudo ufw allow 1516/tcp
sudo ufw allow 55000/tcp
sudo ufw --force enable
```

Load balancer (112):
```bash
sudo ufw allow 22/tcp
sudo ufw allow 1514/tcp
sudo ufw allow 1515/tcp
sudo ufw --force enable
```

Dashboard (118):
```bash
sudo ufw allow 22/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable
```

### Step 9: Validate connectivity between nodes

From wazuh-master-01:
```bash
nc -vz 192.168.90.111 22   # use port 22 before Wazuh is installed
nc -vz 192.168.90.113 22
nc -vz 192.168.90.114 22
```

Note: before Wazuh packages are installed, ports like 9200, 1514, 1515, and 443
will return "Connection refused" because nothing is listening yet. That is expected.
"Connection refused" means the network path is fine but no service is bound;
contrast with "No route to host" or "timed out" which indicate a real network or
firewall problem. Test against port 22 (SSH) to confirm reachability at this stage.

Stage 0 is complete when every node resolves all FQDNs, chrony offset is under one
second, swap is active, indexer nodes report `vm.max_map_count = 262144`, UFW is
enabled per role, and SSH connectivity between nodes succeeds.
