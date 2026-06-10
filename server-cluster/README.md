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
`configs/ossec-global-master.conf`). This only applies to the master; workers do not
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
