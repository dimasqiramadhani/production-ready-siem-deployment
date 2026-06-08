# 6. Wazuh Indexer Cluster Deployment

Three indexer nodes: wazuh-indexer-01 (10.10.10.11), wazuh-indexer-02 (10.10.10.12),
wazuh-indexer-03 (10.10.10.13). Reference:
https://documentation.wazuh.com/current/user-manual/wazuh-indexer-cluster/

## 6.1 Concepts

- **Certificate**: all indexer nodes share a common root CA. Each node has its own
  node certificate whose common name matches its node name. There is also an admin
  certificate used to run the security init. Mismatched CN or CA is the most common
  reason a node will not join.
- **Cluster name**: `cluster.name` must be identical on all three nodes
  (`wazuh-cluster`). Nodes with different cluster names will not form one cluster.
- **Node name**: `node.name` must be unique per node and must match the CN in that
  node's certificate and the entry in `plugins.security.nodes_dn`.

## 6.2 Certificate generation (run once, on wazuh-indexer-01)

Use the Wazuh certificate tool with a `config.yml` describing all nodes. See
`configs/wazuh-install-config.yml` for the full file. Then:

```bash
# Download tool and config
curl -sO https://packages.wazuh.com/4.14/wazuh-certs-tool.sh
curl -sO https://packages.wazuh.com/4.14/config.yml   # then edit to match configs/wazuh-install-config.yml
bash ./wazuh-certs-tool.sh -A
# Produces wazuh-certificates.tar in ./wazuh-certificates/
tar -cvf ./wazuh-certificates.tar -C ./wazuh-certificates/ .
```

Copy `wazuh-certificates.tar` to every node before installing that node's packages.

## 6.3 Install (run on each indexer node)

```bash
# Add the Wazuh GPG key and repository
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | sudo gpg --no-default-keyring \
  --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import
sudo chmod 644 /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
  | sudo tee /etc/apt/sources.list.d/wazuh.list
sudo apt update
sudo apt -y install wazuh-indexer
```

## 6.4 Key configuration file: /etc/wazuh-indexer/opensearch.yml

Example for wazuh-indexer-01 (full files for all three in
`configs/opensearch-indexer-0X.yml`):

```yaml
network.host: "10.10.10.11"
node.name: "wazuh-indexer-01"
cluster.name: "wazuh-cluster"
node.max_local_storage_nodes: "3"
path.data: /var/lib/wazuh-indexer
path.logs: /var/log/wazuh-indexer

discovery.seed_hosts:
  - "10.10.10.11"
  - "10.10.10.12"
  - "10.10.10.13"

cluster.initial_master_nodes:
  - "wazuh-indexer-01"
  - "wazuh-indexer-02"
  - "wazuh-indexer-03"

plugins.security.nodes_dn:
  - "CN=wazuh-indexer-01,OU=Wazuh,O=Wazuh,L=California,C=US"
  - "CN=wazuh-indexer-02,OU=Wazuh,O=Wazuh,L=California,C=US"
  - "CN=wazuh-indexer-03,OU=Wazuh,O=Wazuh,L=California,C=US"

plugins.security.ssl.http.pemcert_filepath: /etc/wazuh-indexer/certs/wazuh-indexer.pem
plugins.security.ssl.http.pemkey_filepath: /etc/wazuh-indexer/certs/wazuh-indexer-key.pem
plugins.security.ssl.http.pemtrustedcas_filepath: /etc/wazuh-indexer/certs/root-ca.pem
plugins.security.ssl.transport.pemcert_filepath: /etc/wazuh-indexer/certs/wazuh-indexer.pem
plugins.security.ssl.transport.pemkey_filepath: /etc/wazuh-indexer/certs/wazuh-indexer-key.pem
plugins.security.ssl.transport.pemtrustedcas_filepath: /etc/wazuh-indexer/certs/root-ca.pem
plugins.security.ssl.http.enabled: true
plugins.security.ssl.transport.enforce_hostname_verification: false
```

On each node deploy that node's certs:

```bash
NODE_NAME=wazuh-indexer-01   # change per node
mkdir -p /etc/wazuh-indexer/certs
tar -xf ./wazuh-certificates.tar -C /etc/wazuh-indexer/certs/ ./$NODE_NAME.pem ./$NODE_NAME-key.pem ./admin.pem ./admin-key.pem ./root-ca.pem
mv -n /etc/wazuh-indexer/certs/$NODE_NAME.pem /etc/wazuh-indexer/certs/wazuh-indexer.pem
mv -n /etc/wazuh-indexer/certs/$NODE_NAME-key.pem /etc/wazuh-indexer/certs/wazuh-indexer-key.pem
chmod 500 /etc/wazuh-indexer/certs
chmod 400 /etc/wazuh-indexer/certs/*
chown -R wazuh-indexer:wazuh-indexer /etc/wazuh-indexer/certs
```

## 6.5 Enable and start (each node)

```bash
sudo systemctl daemon-reload
sudo systemctl enable wazuh-indexer
sudo systemctl start wazuh-indexer
```

## 6.6 Initialize the cluster (run once, on any one indexer node)

```bash
sudo /usr/share/wazuh-indexer/bin/indexer-security-init.sh
```

The output reports the number of nodes connected. Run this only once for the whole
cluster after all three nodes are up.

## 6.7 Validation curl commands

Replace credentials as needed; default is `admin` with the generated password.

```bash
# Cluster health
curl -k -u admin:<PASSWORD> "https://10.10.10.11:9200/_cluster/health?pretty"

# Nodes in the cluster
curl -k -u admin:<PASSWORD> "https://10.10.10.11:9200/_cat/nodes?v"

# Indices
curl -k -u admin:<PASSWORD> "https://10.10.10.11:9200/_cat/indices?v"

# Shards
curl -k -u admin:<PASSWORD> "https://10.10.10.11:9200/_cat/shards?v"

# Allocation per node
curl -k -u admin:<PASSWORD> "https://10.10.10.11:9200/_cat/allocation?v"
```

Healthy result: `status` is green, `number_of_nodes` is 3, `unassigned_shards` is 0,
and `_cat/nodes` lists all three with one marked cluster_manager.

## 6.8 Troubleshooting: node will not join

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| MasterNotDiscoveredException | seed hosts or initial master names wrong | Confirm `discovery.seed_hosts` IPs and `cluster.initial_master_nodes` names match `node.name` exactly on all nodes |
| Node forms its own single node cluster | `cluster.name` differs | Make `cluster.name` identical on all nodes |
| TLS handshake / no certificates found | CN mismatch or wrong CA | Ensure each node cert CN equals its `node.name` and equals its entry in `plugins.security.nodes_dn`; same `root-ca.pem` everywhere |
| securityadmin cannot connect | run before nodes up | Start all nodes first, then run `indexer-security-init.sh` once |
| Cluster stuck yellow with replicas | only one node up | Start the remaining nodes; replicas need at least 2 nodes |

Check logs at `/var/log/wazuh-indexer/wazuh-cluster.log`. Time drift between nodes
also blocks join, so verify NTP.
