# 2. Resource Planning

Two reference profiles are provided below (minimum lab and production like). The
actual lab is deployed on a third, tighter profile documented first.

## 2.0 Actual deployed profile (this lab)

All 8 server side nodes run Ubuntu 22.04 with 2 GB RAM and 128 GB disk each, due to
resource limits.

| VM | IP | vCPU | RAM | Disk |
|----|-----|------|-----|------|
| wazuh-indexer-01 | 192.168.90.111 | shared | 2 GB | 128 GB |
| wazuh-indexer-02 | 192.168.90.113 | shared | 2 GB | 128 GB |
| wazuh-indexer-03 | 192.168.90.114 | shared | 2 GB | 128 GB |
| wazuh-master-01 | 192.168.90.115 | shared | 2 GB | 128 GB |
| wazuh-worker-01 | 192.168.90.116 | shared | 2 GB | 128 GB |
| wazuh-worker-02 | 192.168.90.117 | shared | 2 GB | 128 GB |
| wazuh-dashboard-01 | 192.168.90.118 | shared | 2 GB | 128 GB |
| wazuh-lb-01 | 192.168.90.112 | shared | 2 GB | 128 GB |

### Constraint warning: 2 GB RAM is below the Wazuh recommended minimum

The Wazuh documentation recommends 4 GB minimum for an indexer node. Running indexer
and worker nodes at 2 GB will boot and is fine for a low volume proof of concept, but
expect memory pressure once ingestion rises or during search. Mandatory mitigations
already applied in Stage 0:

- **Swap**: 4 GB swapfile on every node, with `vm.swappiness=10` so swap is used only
  under pressure. This is a safety net against the out of memory killer terminating
  the indexer or manager, not a substitute for RAM.
- **JVM heap**: set the indexer heap explicitly to about half of RAM and equal min and
  max. For 2 GB nodes use 1 GB heap. Edit `/etc/wazuh-indexer/jvm.options`:
  ```
  -Xms1g
  -Xmx1g
  ```
  Do the same caution for the Wazuh server JVM if you tune it; leave headroom for the
  OS and filesystem cache.
- **vm.max_map_count=262144** on indexer nodes (required for OpenSearch to start).

If you can raise RAM later, prioritize the three indexer nodes first (to 4 GB), then
the two workers. The dashboard and load balancer tolerate 2 GB more comfortably.

## 2.1 Profile A: Minimum lab version

Suitable for a laptop or resource constrained host. The whole lab fits in roughly
32 GB RAM if you are careful, but 48 to 64 GB is comfortable.


| VM | vCPU | RAM | Disk | Notes |
|----|------|-----|------|-------|
| wazuh-indexer-01 | 2 | 4 GB | 50 GB | JVM heap 2 GB |
| wazuh-indexer-02 | 2 | 4 GB | 50 GB | JVM heap 2 GB |
| wazuh-indexer-03 | 2 | 4 GB | 50 GB | JVM heap 2 GB |
| wazuh-master-01 | 2 | 4 GB | 40 GB | Coordination, enrollment |
| wazuh-worker-01 | 2 | 4 GB | 40 GB | Event analysis |
| wazuh-worker-02 | 2 | 4 GB | 40 GB | Event analysis |
| wazuh-dashboard-01 | 2 | 4 GB | 30 GB | Node and OpenSearch Dashboards |
| wazuh-lb-01 | 1 | 1 GB | 20 GB | HAProxy only |
| win-agent-01 | 2 | 4 GB | 40 GB | Windows Server or 10/11 |
| win-agent-02 | 2 | 4 GB | 40 GB | Windows Server or 10/11 |
| ubuntu-agent-01 | 1 | 2 GB | 20 GB | Ubuntu 22.04/24.04 |
| ubuntu-agent-02 | 1 | 2 GB | 20 GB | Ubuntu 22.04/24.04 |

## 2.2 Profile B: Production like lab version

Realistic for simulating an enterprise rollout and for index/shard testing under
load.

| VM | vCPU | RAM | Disk | Notes |
|----|------|-----|------|-------|
| wazuh-indexer-01 | 8 | 16 GB | 500 GB SSD | JVM heap 8 GB, data tier |
| wazuh-indexer-02 | 8 | 16 GB | 500 GB SSD | JVM heap 8 GB, data tier |
| wazuh-indexer-03 | 8 | 16 GB | 500 GB SSD | JVM heap 8 GB, data tier |
| wazuh-master-01 | 4 | 8 GB | 100 GB | Coordination, enrollment |
| wazuh-worker-01 | 8 | 16 GB | 200 GB | High event throughput |
| wazuh-worker-02 | 8 | 16 GB | 200 GB | High event throughput |
| wazuh-dashboard-01 | 4 | 8 GB | 100 GB | Dedicated, not on indexer |
| wazuh-lb-01 | 2 | 2 GB | 40 GB | HAProxy, lightweight but critical |
| win-agent-01 | 2 | 4 GB | 60 GB | Windows endpoint |
| win-agent-02 | 2 | 4 GB | 60 GB | Windows endpoint |
| ubuntu-agent-01 | 2 | 4 GB | 40 GB | Ubuntu endpoint |
| ubuntu-agent-02 | 2 | 4 GB | 40 GB | Ubuntu endpoint |

## 2.3 Sizing notes

- The indexer needs the most disk and RAM. It stores all indexed data and runs a
  JVM whose heap should be roughly half the node RAM and never above about 26 to 32
  GB. Set heap equal on min and max in `jvm.options`.
- Workers need enough CPU and RAM for event decoding and rule matching, since they
  carry the agent event stream. Scale workers, not the master, when event volume
  grows.
- The dashboard must not share a host with an indexer node in a production ready
  lab. Dashboard rendering and OpenSearch heap will contend for the same memory and
  IO and cause slow searches.
- The load balancer is lightweight on CPU and RAM but is critical to availability.
  If it dies, all agent enrollment and reporting stops. Consider a second HAProxy
  with keepalived for a real production design.
- Disk on indexers should be SSD. Spinning disk will bottleneck indexing and search
  latency once volume rises.
