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
