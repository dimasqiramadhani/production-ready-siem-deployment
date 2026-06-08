# 9. Load Balancer Deployment

Node: wazuh-lb-01 (10.10.10.40), FQDN wazuh-lb.lab.local. HAProxy is the primary
choice; NGINX stream is the alternative. Reference:
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
`configs/haproxy.cfg`):

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
    server wazuh-master-01 10.10.10.21:1515 check

# Agent reporting -> workers, round robin with health checks
frontend wazuh_reporting
    bind *:1514
    default_backend wazuh_reporting_backend

backend wazuh_reporting_backend
    mode tcp
    balance roundrobin
    server wazuh-worker-01 10.10.10.22:1514 check
    server wazuh-worker-02 10.10.10.23:1514 check

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

## 9.7 NGINX stream alternative

If you prefer NGINX, use the stream module. Full file in `configs/nginx-stream.conf`.
Install `nginx` with stream support, then:

```nginx
stream {
    # Enrollment -> master
    upstream wazuh_enrollment {
        server 10.10.10.21:1515;
    }
    server {
        listen 1515;
        proxy_pass wazuh_enrollment;
    }

    # Reporting -> workers, consistent hash on client IP for sticky distribution
    upstream wazuh_reporting {
        hash $remote_addr consistent;
        server 10.10.10.22:1514;
        server 10.10.10.23:1514;
    }
    server {
        listen 1514;
        proxy_pass wazuh_reporting;
    }
}
```

`hash $remote_addr consistent` keeps a given agent on the same worker while still
rebalancing if a worker is removed. Reload with `sudo nginx -t && sudo systemctl reload nginx`.

## 9.8 Why TCP mode

Wazuh agent enrollment and reporting are raw TCP protocols, not HTTP. Both HAProxy
(`mode tcp`) and NGINX (`stream`) operate at layer 4 so they forward the byte stream
without trying to parse HTTP, which would break the connection.
