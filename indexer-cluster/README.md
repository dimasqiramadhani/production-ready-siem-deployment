# 6. Wazuh Indexer Cluster Deployment

Three indexer nodes: wazuh-indexer-01 (192.168.90.111), wazuh-indexer-02 (192.168.90.113),
wazuh-indexer-03 (192.168.90.114). Reference:
https://documentation.wazuh.com/current/user-manual/wazuh-indexer-cluster/

## 6.1 Concepts

- **Certificate**: all indexer nodes share a common root CA. Each node has its own
  node certificate whose common name matches its node name. There is also an admin
  certificate used to run the security init. The node certificate CN and CA must match
  across all nodes for them to form one cluster.
- **Cluster name**: `cluster.name` must be identical on all three nodes
  (`wazuh-cluster`) so they form a single cluster.
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
sudo apt -y install wazuh-indexer=4.14.5-1
```

> Pin the exact stable version (`=4.14.5-1`) so every node runs an identical build.
> Confirm the candidate before installing with `apt-cache policy wazuh-indexer`.

## 6.4 Key configuration file: /etc/wazuh-indexer/opensearch.yml

Example for wazuh-indexer-01 (full files for all three in
`configs/opensearch-indexer-0X.yml`):

```yaml
network.host: "192.168.90.111"
node.name: "wazuh-indexer-01"
cluster.name: "wazuh-cluster"
node.max_local_storage_nodes: "3"
path.data: /var/lib/wazuh-indexer
path.logs: /var/log/wazuh-indexer

discovery.seed_hosts:
  - "192.168.90.111"
  - "192.168.90.113"
  - "192.168.90.114"

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

## 6.5 Set JVM heap (each node, required for 2 GB RAM nodes)

On the 2 GB nodes in this lab, set the indexer heap explicitly to 1 GB with equal min
and max. Edit `/etc/wazuh-indexer/jvm.options`:

```
-Xms1g
-Xmx1g
```

Rule of thumb: heap is about half of node RAM and never above ~26 to 32 GB. Equal min
and max avoids runtime resizing.

## 6.5b Create the snapshot repository directory (each node)

The indexer config (`configs/opensearch-indexer-0X.yml`) already declares
`path.repo: ["/mnt/wazuh-snapshots"]`. Create that directory and set ownership on
every indexer node now, before first start, so the snapshot repository in section 15
works without any later restart:

```bash
sudo mkdir -p /mnt/wazuh-snapshots
sudo chown -R wazuh-indexer:wazuh-indexer /mnt/wazuh-snapshots
```

## 6.6 Enable and start (each node)

```bash
sudo systemctl daemon-reload
sudo systemctl enable wazuh-indexer
sudo systemctl start wazuh-indexer
```

## 6.7 Initialize the cluster (run once, on any one indexer node)

```bash
sudo /usr/share/wazuh-indexer/bin/indexer-security-init.sh
```

The output reports the number of nodes connected. Run this only once for the whole
cluster after all three nodes are up.

## 6.8 Validation curl commands

Replace credentials as needed; default is `admin` with the generated password.

```bash
# Cluster health
curl -k -u admin:<PASSWORD> "https://192.168.90.111:9200/_cluster/health?pretty"

# Nodes in the cluster
curl -k -u admin:<PASSWORD> "https://192.168.90.111:9200/_cat/nodes?v"

# Indices
curl -k -u admin:<PASSWORD> "https://192.168.90.111:9200/_cat/indices?v"

# Shards
curl -k -u admin:<PASSWORD> "https://192.168.90.111:9200/_cat/shards?v"

# Allocation per node
curl -k -u admin:<PASSWORD> "https://192.168.90.111:9200/_cat/allocation?v"
```

Healthy result: `status` is green, `number_of_nodes` is 3, `unassigned_shards` is 0,
and `_cat/nodes` lists all three with one marked cluster_manager.
