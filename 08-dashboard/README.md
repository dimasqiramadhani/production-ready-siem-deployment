# 8. Wazuh Dashboard Deployment

Single dashboard node: wazuh-dashboard-01 (10.10.10.31), accessed at
https://wazuh-dashboard.lab.local. Reference:
https://documentation.wazuh.com/current/user-manual/wazuh-dashboard/

## 8.1 Install

```bash
sudo apt -y install wazuh-dashboard
```

## 8.2 Deploy certificates

Extract the dashboard certificate from the shared tarball:

```bash
mkdir -p /etc/wazuh-dashboard/certs
tar -xf ./wazuh-certificates.tar -C /etc/wazuh-dashboard/certs/ \
  ./wazuh-dashboard.pem ./wazuh-dashboard-key.pem ./root-ca.pem
chmod 500 /etc/wazuh-dashboard/certs
chmod 400 /etc/wazuh-dashboard/certs/*
chown -R wazuh-dashboard:wazuh-dashboard /etc/wazuh-dashboard/certs
```

## 8.3 Connect the dashboard to the indexer cluster

Edit `/etc/wazuh-dashboard/opensearch_dashboards.yml`. Full file in
`configs/opensearch_dashboards.yml`. Point at all three indexer nodes for HA:

```yaml
server.host: 0.0.0.0
server.port: 443
opensearch.hosts:
  - "https://10.10.10.11:9200"
  - "https://10.10.10.12:9200"
  - "https://10.10.10.13:9200"
opensearch.ssl.verificationMode: certificate
opensearch.username: kibanaserver
opensearch.password: kibanaserver
opensearch.ssl.certificateAuthorities: ["/etc/wazuh-dashboard/certs/root-ca.pem"]
server.ssl.enabled: true
server.ssl.key: "/etc/wazuh-dashboard/certs/wazuh-dashboard-key.pem"
server.ssl.certificate: "/etc/wazuh-dashboard/certs/wazuh-dashboard.pem"
uiSettings.overrides.defaultRoute: /app/wz-home
```

## 8.4 Connect the dashboard to the Wazuh server API

The Wazuh app config is `/usr/share/wazuh-dashboard/data/wazuh/config/wazuh.yml`.
Point the dashboard at the master node API on 55000. Full file in
`configs/wazuh.yml`:

```yaml
hosts:
  - default:
      url: https://10.10.10.21
      port: 55000
      username: wazuh-wui
      password: "<WAZUH_WUI_PASSWORD>"
      run_as: false
```

## 8.5 Enable and start

```bash
sudo systemctl daemon-reload
sudo systemctl enable wazuh-dashboard
sudo systemctl start wazuh-dashboard
```

## 8.6 Access and validate login

Browse to `https://wazuh-dashboard.lab.local`. Log in with the admin credentials
generated during install (default user `admin`). On first login confirm:

- The Wazuh app loads (not just OpenSearch Dashboards).
- Server management views populate (agents, cluster status, rules), which proves the
  API connection on 55000 works.
- The Discover / alerts views return data, which proves the indexer connection on
  9200 works.

## 8.7 Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Dashboard loads but no alerts | indexer connection failing | Verify `opensearch.hosts`, that 9200 is reachable, and `root-ca.pem` matches the indexer CA |
| Management views error / API not reachable | server API connection failing | Verify 55000 open to master, `wazuh.yml` URL and credentials, master `wazuh-manager` API running |
| TLS error on login page | dashboard cert/key wrong | Confirm `server.ssl.certificate` and key paths and ownership |
| 401 from indexer | wrong `kibanaserver` password | Reset internal user password and update `opensearch_dashboards.yml` |

Logs: `/var/log/wazuh-dashboard/wazuh-dashboard.log` and `journalctl -u wazuh-dashboard`.
