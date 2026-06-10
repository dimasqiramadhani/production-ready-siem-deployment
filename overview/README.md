# 1. Architecture Overview

## 1.1 Role of each VM

**Wazuh indexer cluster (wazuh-indexer-01/02/03)**
The indexer is the OpenSearch based data store and search engine. It receives alert
and event data from the Wazuh server via Filebeat over port 9200, stores it in
indices, and serves search queries to the dashboard. Three nodes provide high
availability and let primary and replica shards spread across the cluster, so a
single node loss does not stop search.

**Wazuh server cluster (wazuh-master-01, wazuh-worker-01, wazuh-worker-02)**
The server (manager) is the analysis engine. It decodes incoming agent logs,
matches them against rules, and generates alerts. In a cluster there is exactly one
master and one or more workers. The master coordinates and synchronizes shared state
(agent keys, rules, decoders, CDB lists, group files, centralized config). Workers
do the heavy lifting of receiving and analyzing agent events.

**Wazuh dashboard (wazuh-dashboard-01)**
The web UI. It reads alert data from the indexer over 9200 and reads management data
(agents, groups, rules, status) from the Wazuh server API over 55000. It is kept on
its own VM so dashboard load never competes with indexer JVM heap and disk IO.

**Load balancer (wazuh-lb-01)**
An HAProxy TCP load balancer in front of the server cluster. It terminates agent
enrollment (1515) toward the master and distributes agent reporting (1514) across
both workers, with health checks and automatic failover.

**Agents (win-agent-01/02, ubuntu-agent-01/02)**
The endpoint software. Agents collect logs and telemetry and ship them to the server
cluster through the load balancer. Agents never analyze; they only forward.

## 1.2 Difference between the components

| Component | Job | Data direction |
|-----------|-----|----------------|
| Agent | Collect and forward logs | Sends to LB then to workers |
| Load balancer | Distribute and fail over agent traffic | Forwards 1514 to workers, 1515 to master |
| Server cluster | Decode, rule match, generate alerts | Receives from agents, sends alerts via Filebeat to indexer |
| Indexer cluster | Store and search alert/event data | Receives from Filebeat, serves dashboard |
| Dashboard | Visualize and manage | Reads indexer (9200) and server API (55000) |

## 1.3 Why agents point to the load balancer

Pointing agents at a single worker creates a single point of failure and uneven
load. The Wazuh documentation recommends a load balancer so agents register and
report in a distributed way, the load balancer decides which worker handles each
connection, load is spread evenly, and if a worker fails its agents reconnect to a
surviving worker automatically. Agents never need to know the individual worker
addresses; they only know `wazuh-lb.lab.local`.

## 1.4 Why the master should not be the primary event receiver

The master centralizes and coordinates the cluster: agent registration and deletion,
and synchronization of rules, decoders, CDB lists, group files, and centralized
configuration to the workers. If the master also carried the full agent event load,
its synchronization and coordination duties would compete with event analysis,
hurting both. The standard pattern is: master handles enrollment (1515) and
coordination; workers handle the event stream (1514). This is why the load balancer
sends 1515 only to the master and 1514 only to the workers.

## 1.5 How workers receive agent events

Agents send keepalives and events to the load balancer on 1514/TCP. HAProxy forwards
each connection to one of the two workers using round robin with health checks. The
worker that receives the connection decodes the logs, runs them through the ruleset,
and produces alerts locally. All workers share the same rules and decoders because
the master synchronizes them across the cluster.

## 1.6 How Filebeat ships alerts to the indexer

Each server node runs Filebeat. Filebeat reads the manager alert output
(`/var/ossec/logs/alerts/alerts.json`) and ships it to the indexer cluster over
9200/TCP using the Wazuh template. Filebeat is configured with all three indexer
hosts so it can keep delivering if one indexer node is down.

## 1.7 How the dashboard reads data

The dashboard has two backend connections. For alert visualization and search it
queries the indexer cluster on 9200 (configured with all three indexer hosts in
`opensearch.hosts`). For management views (agent list, groups, rules, cluster status,
restarts) it calls the Wazuh server API on 55000. Both connections use TLS.

## 1.8 ASCII architecture diagram

```
                    Windows agents                Ubuntu agents
                  win-agent-01 .101              ubuntu-agent-01 .111
                  win-agent-02 .102              ubuntu-agent-02 .112
                        |                                |
                        |  1514/TCP event and keepalive  |
                        |  1515/TCP enrollment           |
                        +----------------+---------------+
                                         |
                                         v
                              +---------------------+
                              |    wazuh-lb-01      |
                              |   192.168.90.112       |
                              |   HAProxy (TCP)     |
                              +----------+----------+
                                         |
            1515/TCP -> master           |          1514/TCP -> workers (RR)
            +----------------------------+----------------------------+
            |                            |                            |
            v                            v                            v
   +------------------+        +------------------+        +------------------+
   | wazuh-master-01  |        | wazuh-worker-01  |        | wazuh-worker-02  |
   |   192.168.90.115    |<------>|   192.168.90.116    |<------>|   192.168.90.117    |
   |  master node     | 1516   |  worker node     | 1516   |  worker node     |
   +--------+---------+        +--------+---------+        +--------+---------+
            |                           |                           |
            |   Filebeat -> 9200/TCP (alerts.json to indexer cluster)
            +---------------------------+---------------------------+
                                        |
                                        v
   +------------------+   9300-9400  +------------------+   9300-9400  +------------------+
   | wazuh-indexer-01 |<------------>| wazuh-indexer-02 |<------------>| wazuh-indexer-03 |
   |   192.168.90.111    |   transport  |   192.168.90.113    |   transport  |   192.168.90.114    |
   +--------+---------+              +--------+---------+              +--------+---------+
            ^                                 ^                                 ^
            |                                 |                                 |
            +------------------ 9200/TCP search and index ---------------------+
                                        ^
                                        |
                              +---------+-----------+
                              | wazuh-dashboard-01  |
                              |   192.168.90.118       |
                              |  9200 -> indexer    |
                              |  55000 -> server API|
                              +---------+-----------+
                                        ^
                                        | 443/TCP HTTPS
                                        |
                                   Admin / User browser
                              https://wazuh-dashboard.lab.local
```
