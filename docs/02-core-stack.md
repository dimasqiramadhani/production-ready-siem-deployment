# Part 2: Core Stack Deployment

This part covers the indexer cluster, the server cluster (master and workers),
the dashboard, and the HAProxy load balancer. Deploy in this order.

---

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
`configs/shared/wazuh-install-config.yml` for the full file. Then:

```bash
# Download tool and config
curl -sO https://packages.wazuh.com/4.14/wazuh-certs-tool.sh
curl -sO https://packages.wazuh.com/4.14/config.yml   # then edit to match configs/shared/wazuh-install-config.yml
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

---

# 7. Wazuh Server Cluster Configuration

Three server nodes: wazuh-master-01 (master, 192.168.90.115), wazuh-worker-01
(worker, 192.168.90.116), wazuh-worker-02 (worker, 192.168.90.117).
Wazuh 4.14.5 stable version (install pinned as 4.14.5-1). Reference:
https://documentation.wazuh.com/current/user-manual/wazuh-server-cluster/

## 7.1 Install wazuh-manager (each node)

```bash
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | \
  gpg --no-default-keyring \
  --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg \
  --import
chmod 644 /usr/share/keyrings/wazuh.gpg

echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] \
https://packages.wazuh.com/4.x/apt/ stable main" | \
  tee /etc/apt/sources.list.d/wazuh.list

apt update && apt install -y wazuh-manager=4.14.5-1
```

> Pin the exact stable version (`=4.14.5-1`) so the manager, indexer, dashboard, and all
> agents run one consistent build. Verify with `apt-cache policy wazuh-manager` before
> installing.

## 7.2 Deploy Filebeat certificates (each node)

Filebeat cert names differ per node. Replace NODE with master, worker-01, or
worker-02 accordingly.

```bash
mkdir -p /etc/filebeat/certs
tar -xf ~/wazuh-certificates.tar -C /etc/filebeat/certs/ \
  ./wazuh-manager-<NODE>.pem \
  ./wazuh-manager-<NODE>-key.pem \
  ./root-ca.pem
mv /etc/filebeat/certs/wazuh-manager-<NODE>.pem /etc/filebeat/certs/filebeat.pem
mv /etc/filebeat/certs/wazuh-manager-<NODE>-key.pem /etc/filebeat/certs/filebeat-key.pem
chmod 500 /etc/filebeat/certs
chmod 400 /etc/filebeat/certs/*
chown -R root:root /etc/filebeat/certs
```

## 7.3 Cluster key

Generated once on master and used identically on all three nodes:

```
65eee392122e08d63ee68141da37398b
```

To generate a new key: `openssl rand -hex 16`

## 7.4 Cluster block in ossec.conf

Use this Python snippet to replace the cluster block safely on each node:

```bash
python3 - <<'PYEOF'
import re
conf_path = "/var/ossec/etc/ossec.conf"
with open(conf_path, "r") as f:
    content = f.read()

# Change node_name and node_type per node
cluster_block = """<cluster>
  <name>wazuh</name>
  <node_name>wazuh-master-01</node_name>
  <node_type>master</node_type>
  <key>65eee392122e08d63ee68141da37398b</key>
  <port>1516</port>
  <bind_addr>0.0.0.0</bind_addr>
  <nodes>
    <node>192.168.90.115</node>
  </nodes>
  <hidden>no</hidden>
  <disabled>no</disabled>
</cluster>"""

new_content = re.sub(r'<cluster>.*?</cluster>', cluster_block, content, flags=re.DOTALL)
with open(conf_path, "w") as f:
    f.write(new_content)
print("Done")
PYEOF
```

For workers change `node_name` to `wazuh-worker-01` or `wazuh-worker-02` and
`node_type` to `worker`.

## 7.4b Disable the update check on the master

The Wazuh API runs a once a day background task on the master node that queries the
Wazuh Cloud Threat Intelligence (CTI) update service. In an isolated lab there is no
need to reach that service, so disable the check to keep the Server APIs page clean
and remove an outbound dependency.

The default `ossec.conf` ships `<update_check>yes</update_check>` inside the
`<global>` block. On the master, set it to `no` so the task is never spawned:

```bash
sed -i 's#<update_check>yes</update_check>#<update_check>no</update_check>#' \
  /var/ossec/etc/ossec.conf

grep update_check /var/ossec/etc/ossec.conf   # confirm it now reads no
```

If the line is missing entirely, add it inside the first `<global>` block (see
`configs/server/ossec-global-master.conf`). This only applies to the master; workers do not
run the update task.

## 7.5 Enrollment password (master only)

```bash
echo "WazuhEnroll2024!" > /var/ossec/etc/authd.pass
chmod 640 /var/ossec/etc/authd.pass
chown root:wazuh /var/ossec/etc/authd.pass
```

Enable in ossec.conf auth block (master only, use_password yes):

```bash
python3 - <<'PYEOF'
import re
conf_path = "/var/ossec/etc/ossec.conf"
with open(conf_path, "r") as f:
    content = f.read()

auth_block = """<auth>
  <disabled>no</disabled>
  <port>1515</port>
  <use_password>yes</use_password>
  <ciphers>HIGH:!ADH:!EXP:!MD5:!RC4:!3DES:!CAMELLIA:@STRENGTH</ciphers>
  <ssl_verify_host>no</ssl_verify_host>
  <ssl_manager_cert>/var/ossec/etc/sslmanager.cert</ssl_manager_cert>
  <ssl_manager_key>/var/ossec/etc/sslmanager.key</ssl_manager_key>
  <ssl_auto_negotiate>no</ssl_auto_negotiate>
</auth>"""

new_content = re.sub(r'<auth>.*?</auth>', auth_block, content, flags=re.DOTALL)
with open(conf_path, "w") as f:
    f.write(new_content)
print("Done")
PYEOF
```

## 7.6 Install and configure Filebeat (each node)

Install Filebeat, then write the verified working config directly. Writing the full
file in one step keeps it clean and avoids any leftover or duplicated keys from the
shipped template:

```bash
apt install -y filebeat

cat > /etc/filebeat/filebeat.yml <<'CONF'
# Wazuh - Filebeat configuration file
output.elasticsearch:
  hosts: ["https://192.168.90.111:9200", "https://192.168.90.113:9200", "https://192.168.90.114:9200"]
  protocol: https
  username: "admin"
  password: "<INDEXER_ADMIN_PASSWORD>"
  ssl.certificate_authorities:
    - /etc/filebeat/certs/root-ca.pem
  ssl.certificate: "/etc/filebeat/certs/filebeat.pem"
  ssl.key: "/etc/filebeat/certs/filebeat-key.pem"

setup.template.json.enabled: true
setup.template.json.path: '/etc/filebeat/wazuh-template.json'
setup.template.json.name: 'wazuh'
setup.ilm.overwrite: true
setup.ilm.enabled: false

filebeat.modules:
  - module: wazuh
    alerts:
      enabled: true
    archives:
      enabled: false

logging.level: info
logging.to_files: true
logging.files:
  path: /var/log/filebeat
  name: filebeat
  keepfiles: 7
  permissions: 0644
CONF
```

Download module and template:

```bash
curl -s https://packages.wazuh.com/4.x/filebeat/wazuh-filebeat-0.4.tar.gz \
  | tar -xvz -C /usr/share/filebeat/module

curl -so /etc/filebeat/wazuh-template.json \
  https://raw.githubusercontent.com/wazuh/wazuh/v4.14.5/extensions/elasticsearch/7.x/wazuh-template.json
chmod go+r /etc/filebeat/wazuh-template.json
```

## 7.7 Start services (each node)

```bash
systemctl daemon-reload
systemctl enable wazuh-manager
systemctl start wazuh-manager
systemctl enable filebeat
systemctl start filebeat
filebeat test output
```

All three indexer hosts must show `talk to server... OK` and `TLS version: TLSv1.3`.

## 7.8 Validate cluster

```bash
/var/ossec/bin/cluster_control -l
```

Expected output:

```
NAME             TYPE    VERSION  ADDRESS
wazuh-master-01  master  4.14.5   192.168.90.115
wazuh-worker-01  worker  4.14.5   192.168.90.116
wazuh-worker-02  worker  4.14.5   192.168.90.117
```

## 7.9 Validate the Wazuh API

The dashboard talks to the manager over the API on 55000. Confirm it authenticates
before moving on:

```bash
curl -sk -u wazuh-wui:wazuh-wui \
  -X POST https://192.168.90.115:55000/security/user/authenticate | python3 -m json.tool
```

A healthy response contains a `token`, which confirms the dashboard will be able to
reach the manager API on 55000.

---

# 8. Wazuh Dashboard Deployment

Node: wazuh-dashboard-01 (192.168.90.118), accessible at https://192.168.90.118.
Wazuh 4.14.5 stable version (install pinned as 4.14.5-1). Reference:
https://documentation.wazuh.com/current/user-manual/wazuh-dashboard/

## 8.1 Install

```bash
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | \
  gpg --no-default-keyring \
  --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg \
  --import
chmod 644 /usr/share/keyrings/wazuh.gpg

echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] \
https://packages.wazuh.com/4.x/apt/ stable main" | \
  tee /etc/apt/sources.list.d/wazuh.list

apt update && apt install -y wazuh-dashboard=4.14.5-1
```

> Pin the exact stable version (`=4.14.5-1`) and verify with
> `apt-cache policy wazuh-dashboard` before installing, so the dashboard matches the
> manager and indexer build.

When apt prompts about `opensearch_dashboards.yml` during install or upgrade, answer N
to keep your configured version.

## 8.2 Deploy certificates

```bash
mkdir -p /etc/wazuh-dashboard/certs
tar -xf ~/wazuh-certificates.tar -C /etc/wazuh-dashboard/certs/ \
  ./wazuh-dashboard.pem \
  ./wazuh-dashboard-key.pem \
  ./root-ca.pem
chmod 500 /etc/wazuh-dashboard/certs
chmod 400 /etc/wazuh-dashboard/certs/*
chown -R wazuh-dashboard:wazuh-dashboard /etc/wazuh-dashboard/certs
ls -lh /etc/wazuh-dashboard/certs/
```

## 8.3 Configure opensearch_dashboards.yml

```bash
cat > /etc/wazuh-dashboard/opensearch_dashboards.yml <<'CONF'
server.host: 0.0.0.0
server.port: 443
opensearch.hosts:
  - "https://192.168.90.111:9200"
  - "https://192.168.90.113:9200"
  - "https://192.168.90.114:9200"
opensearch.ssl.verificationMode: certificate
opensearch.username: kibanaserver
opensearch.password: "<KIBANASERVER_PASSWORD>"
opensearch.requestHeadersAllowlist: ["securitytenant","Authorization"]
opensearch_security.multitenancy.enabled: false
opensearch.ssl.certificateAuthorities: ["/etc/wazuh-dashboard/certs/root-ca.pem"]
server.ssl.enabled: true
server.ssl.key: "/etc/wazuh-dashboard/certs/wazuh-dashboard-key.pem"
server.ssl.certificate: "/etc/wazuh-dashboard/certs/wazuh-dashboard.pem"
uiSettings.overrides.defaultRoute: /app/wz-home
CONF
```

## 8.4 Configure Wazuh API connection

```bash
mkdir -p /usr/share/wazuh-dashboard/data/wazuh/config

cat > /usr/share/wazuh-dashboard/data/wazuh/config/wazuh.yml <<'CONF'
hosts:
  - default:
      url: https://192.168.90.115
      port: 55000
      username: wazuh-wui
      password: "<WAZUH_WUI_PASSWORD>"
      run_as: false
CONF
```

## 8.5 Fix ownership and start

```bash
chown -R wazuh-dashboard:wazuh-dashboard /usr/share/wazuh-dashboard/data
systemctl daemon-reload
systemctl enable wazuh-dashboard
systemctl start wazuh-dashboard
systemctl status wazuh-dashboard --no-pager | head -5
```

Dashboard loading on first start takes 3 to 5 minutes on a 2 GB RAM node. Do not
refresh the browser during initial load.

## 8.6 Access

Browse to `https://192.168.90.118`. Accept the self signed certificate warning.
Login with `admin` / `admin`.

On first login the dashboard shows a health check page. A warning about
`wazuh-alerts-*` index pattern is expected at this stage because no agents have
enrolled yet and no alerts index exists. Click Continue to proceed to the main
dashboard.

## 8.7 Validation

After login confirm:
- Top right shows API status indicator green (proves 55000 connection to master OK)
- Wazuh app menu loads (Overview, Agents, etc.)
- No red errors in the health check other than the alerts index pattern warning

## 8.8 Notes on Wazuh 4.14.x

Wazuh 4.14.x serves bundle assets from `src/*/target/public/` via Node.js internals,
not from a top level `bundles/` folder like older versions. This is by design. The
`contentLength: 9` in server logs for bundle requests is an artifact of how the
response headers are reported, not an indication of missing files. The files are
served correctly as confirmed by direct curl test returning 1014K JS files.

First load over VPN or high latency connections can take 5 to 10 minutes because
the browser loads many large JS bundles sequentially.

---

# 9. Load Balancer Deployment

Node: wazuh-lb-01 (192.168.90.112), FQDN wazuh-lb.lab.local. HAProxy in TCP mode
balances agent enrollment and reporting across the cluster. Reference:
https://documentation.wazuh.com/current/user-manual/wazuh-server-cluster/load-balancers.html

## 9.1 Design

- Enrollment (1515/TCP) is forwarded only to the master, because the master handles
  agent registration.
- Reporting (1514/TCP) is balanced across both workers with health checks, because
  workers carry the event load and provide failover.
- Mode is TCP, since Wazuh agent traffic is not HTTP.

## 9.2 HAProxy install

```bash
sudo apt update
sudo apt -y install haproxy
sudo cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak   # backup default
```

## 9.3 HAProxy configuration

Replace `/etc/haproxy/haproxy.cfg` content with the following (full file in
`configs/lb/haproxy.cfg`):

```
global
    log /dev/log local0
    maxconn 4096
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    timeout connect 5s
    timeout client  600s
    timeout server  600s
    retries 3

# Agent enrollment -> master only
frontend wazuh_enrollment
    bind *:1515
    default_backend wazuh_enrollment_backend

backend wazuh_enrollment_backend
    mode tcp
    server wazuh-master-01 192.168.90.115:1515 check

# Agent reporting -> workers, round robin with health checks
frontend wazuh_reporting
    bind *:1514
    default_backend wazuh_reporting_backend

backend wazuh_reporting_backend
    mode tcp
    balance roundrobin
    server wazuh-worker-01 192.168.90.116:1514 check
    server wazuh-worker-02 192.168.90.117:1514 check

# Optional HAProxy stats UI
frontend stats
    mode http
    bind *:8404
    stats enable
    stats uri /stats
    stats refresh 10s
```

Validate config and restart:

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
sudo systemctl enable haproxy
sudo systemctl restart haproxy
```

If you want to reach the stats page on 8404 from other hosts, open it in the
firewall (the Stage 0 baseline only opened 1514, 1515, and 22 on the LB):

```bash
sudo ufw allow 8404/tcp comment 'haproxy stats'
```

## 9.4 Validate listening ports

```bash
sudo ss -lntp | grep -E '1514|1515'
```

You should see HAProxy bound on 0.0.0.0:1514 and 0.0.0.0:1515.

## 9.5 Test connectivity from an agent host

```bash
nc -vz wazuh-lb.lab.local 1514
nc -vz wazuh-lb.lab.local 1515
```

Both must succeed before deploying agents.

## 9.6 Test worker failover

1. Confirm both workers are up in the stats page (`http://wazuh-lb.lab.local:8404/stats`).
2. Stop one worker: `sudo systemctl stop wazuh-manager` on wazuh-worker-01.
3. The reporting backend marks wazuh-worker-01 DOWN; agents that were on it reconnect
   and report to wazuh-worker-02.
4. Confirm agents still active on the dashboard and in `cluster_control -a`.
5. Restart wazuh-worker-01; it returns to the backend pool.

## 9.7 Why TCP mode

Wazuh agent enrollment and reporting are raw TCP protocols, not HTTP. HAProxy runs in
`mode tcp` so it operates at layer 4 and forwards the byte stream without trying to
parse HTTP, which would break the connection.
