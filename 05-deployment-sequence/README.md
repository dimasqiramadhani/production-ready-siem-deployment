# 5. Deployment Sequence

The order below is deliberate. Each stage depends on the one before it being healthy.

1. Prepare all VMs (OS, updates, snapshot).
2. Configure hostname and DNS / /etc/hosts.
3. Configure time sync.
4. Configure firewall baseline.
5. Generate Wazuh certificates (one central node, then distribute).
6. Deploy Wazuh indexer cluster (install on all 3 nodes).
7. Initialize Wazuh indexer cluster (run securityadmin once).
8. Validate Wazuh indexer cluster (health green, 3 nodes).
9. Deploy Wazuh master.
10. Deploy Wazuh workers.
11. Configure Wazuh server cluster (cluster block on each node).
12. Validate Wazuh server cluster (cluster_control shows workers).
13. Deploy Wazuh dashboard.
14. Validate dashboard access (login over HTTPS).
15. Deploy load balancer (HAProxy).
16. Validate load balancer port forwarding (listen on 1514/1515, backends up).
17. Create Wazuh agent groups (windows, linux).
18. Create centralized agent configuration (agent.conf per group).
19. Deploy Windows agents using mass deployment simulation (GPO or PS Remoting).
20. Deploy Ubuntu agents using Ansible.
21. Validate agent enrollment (agents appear, correct groups).
22. Validate event ingestion (events arrive at workers, alerts generated).
23. Validate dashboard visibility (alerts searchable).
24. Configure index management and retention (ISM policies, templates).
25. Configure snapshot / backup strategy (repository, schedule, restore test).
26. Final validation and lab report.

## Why this order matters

- **Certificates first (step 5).** Every component (indexer, server, dashboard,
  Filebeat) relies on the same certificate authority. Generating all certs up front
  avoids mismatched CAs that block cluster join and Filebeat shipping.
- **Indexer before server (steps 6 to 8).** The server's Filebeat ships alerts to
  the indexer. If the indexer cluster is not healthy first, Filebeat has nowhere to
  send data and you will chase false alarms.
- **Server cluster before dashboard (steps 9 to 12).** The dashboard reads the
  server API and the indexer. Standing up the server cluster first means the
  dashboard has both backends ready at first login.
- **Load balancer before agents (steps 15 to 16).** Agents are configured to enroll
  and report only through the load balancer. If the LB is not forwarding correctly,
  enrollment fails and you cannot tell whether the problem is the agent, the LB, or
  the server.
- **Groups and centralized config before agent deployment (steps 17 to 18).** The
  `windows` and `linux` groups must exist before mass deployment so that
  `WAZUH_AGENT_GROUP` lands each agent in the right group on first enrollment and
  immediately receives the correct `agent.conf`.
- **Validate ingestion before index management (steps 22 to 24).** Confirm real data
  flows end to end before you start applying retention, rollover, and shard policies,
  so you are tuning against actual indices.
- **Snapshots last but not optional (step 25).** Once data and configuration exist,
  protect them. The indexer cluster is not a backup of itself.
