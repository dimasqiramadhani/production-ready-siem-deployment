#!/usr/bin/env bash
# Quick end to end validation for the Wazuh multi node lab.
# Usage: INDEXER=192.168.90.111 PASS=yourpass ./validate-cluster.sh
set -u
INDEXER="${INDEXER:-192.168.90.111}"
PASS="${PASS:-admin}"
USER="${USER_IDX:-admin}"

echo "== Indexer cluster health =="
curl -sk -u "$USER:$PASS" "https://$INDEXER:9200/_cluster/health?pretty"

echo "== Indexer nodes =="
curl -sk -u "$USER:$PASS" "https://$INDEXER:9200/_cat/nodes?v"

echo "== Indices =="
curl -sk -u "$USER:$PASS" "https://$INDEXER:9200/_cat/indices?v"

echo "== Shards (verify spread across 3 nodes) =="
curl -sk -u "$USER:$PASS" "https://$INDEXER:9200/_cat/shards?v"

echo "== Allocation =="
curl -sk -u "$USER:$PASS" "https://$INDEXER:9200/_cat/allocation?v"

echo "== Server cluster (run on master) =="
echo "  sudo /var/ossec/bin/cluster_control -l"
echo "  sudo /var/ossec/bin/cluster_control -a"

echo "== Wazuh API health (run on master, must return a token) =="
MASTER="${MASTER:-192.168.90.115}"
echo "  Testing API authenticate on $MASTER:55000 ..."
curl -sk -u wazuh-wui:wazuh-wui -X POST \
  "https://$MASTER:55000/security/user/authenticate" \
  | grep -q '"token"' \
  && echo "  API OK: token returned" \
  || echo "  API FAIL: no token returned from $MASTER:55000"

echo "== Agents and groups (run on master) =="
echo "  sudo /var/ossec/bin/agent_control -l"
echo "  sudo /var/ossec/bin/agent_groups -l -g windows"
echo "  sudo /var/ossec/bin/agent_groups -l -g linux"
