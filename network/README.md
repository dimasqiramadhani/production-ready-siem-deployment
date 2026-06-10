# 3. Network and Firewall Matrix

## 3.1 Port matrix

| Source | Destination | Port | Protocol | Function | Required |
|--------|-------------|------|----------|----------|----------|
| Agents | wazuh-lb-01 | 1514 | TCP | Agent event and keepalive reporting | Required |
| Agents | wazuh-lb-01 | 1515 | TCP | Agent enrollment | Required |
| wazuh-lb-01 | wazuh-master-01 | 1515 | TCP | Enrollment forward to master | Required |
| wazuh-lb-01 | wazuh-worker-01 | 1514 | TCP | Event forward to worker | Required |
| wazuh-lb-01 | wazuh-worker-02 | 1514 | TCP | Event forward to worker | Required |
| Server nodes | Server nodes | 1516 | TCP | Wazuh server cluster communication | Required |
| Server nodes (Filebeat) | Indexer nodes | 9200 | TCP | Ship alerts to indexer | Required |
| Indexer nodes | Indexer nodes | 9300-9400 | TCP | Indexer inter node transport | Required |
| wazuh-dashboard-01 | Server API (master) | 55000 | TCP | Management data | Required |
| wazuh-dashboard-01 | Indexer nodes | 9200 | TCP | Alert search | Required |
| Admin/User | wazuh-dashboard-01 | 443 | TCP | Dashboard HTTPS | Required |
| Admin | All Linux nodes | 22 | TCP | SSH administration | Optional |
| Admin | Windows agents | 3389 | TCP | RDP administration | Optional |
| Admin | Windows agents | 5985/5986 | TCP | WinRM (PowerShell Remoting) | Optional |
| Agents | wazuh-master-01 | 1514/1515 | TCP | Direct failover if LB down (not used by default) | Optional |

Notes on the API port: the dashboard connects to the Wazuh server API on 55000. In a
cluster the API runs on every node; point the dashboard at the master for a stable
management endpoint, or front the API with the load balancer if you want HA on it
too.

## 3.2 UFW examples

### Indexer node (each of wazuh-indexer-01/02/03)

```bash
sudo ufw allow 9200/tcp comment 'indexer http api'
sudo ufw allow 9300:9400/tcp comment 'indexer transport'
sudo ufw allow 22/tcp comment 'ssh admin'
sudo ufw enable
sudo ufw status numbered
```

### Master node (wazuh-master-01)

```bash
sudo ufw allow 1515/tcp comment 'agent enrollment from LB'
sudo ufw allow 1516/tcp comment 'server cluster'
sudo ufw allow 55000/tcp comment 'wazuh api'
sudo ufw allow 9200/tcp comment 'filebeat to indexer'  # egress; needed on indexer side
sudo ufw allow 22/tcp
sudo ufw enable
```

### Worker node (wazuh-worker-01/02)

```bash
sudo ufw allow 1514/tcp comment 'agent events from LB'
sudo ufw allow 1516/tcp comment 'server cluster'
sudo ufw allow 55000/tcp comment 'wazuh api'
sudo ufw allow 22/tcp
sudo ufw enable
```

### Load balancer (wazuh-lb-01)

```bash
sudo ufw allow 1514/tcp comment 'agent events in'
sudo ufw allow 1515/tcp comment 'agent enrollment in'
sudo ufw allow 22/tcp
sudo ufw enable
```

### Dashboard (wazuh-dashboard-01)

```bash
sudo ufw allow 443/tcp comment 'dashboard https'
sudo ufw allow 22/tcp
sudo ufw enable
```

## 3.3 iptables example (indexer node)

If you prefer raw iptables instead of UFW on the indexers:

```bash
# Allow established
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
# Indexer HTTP API (restrict to server cluster + dashboard + other indexers)
iptables -A INPUT -p tcp --dport 9200 -s 192.168.90.0/24 -j ACCEPT
# Indexer transport between indexer nodes only
iptables -A INPUT -p tcp --dport 9300:9400 -s 192.168.90.111 -j ACCEPT
iptables -A INPUT -p tcp --dport 9300:9400 -s 192.168.90.113 -j ACCEPT
iptables -A INPUT -p tcp --dport 9300:9400 -s 192.168.90.114 -j ACCEPT
# SSH
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
# Loopback
iptables -A INPUT -i lo -j ACCEPT
# Default drop
iptables -P INPUT DROP
```

Tighten the source addresses to the actual subnet in production. In this lab all
nodes share `192.168.90.0/24`.
