# Evaluation

Every document in this repository was checked against the configuration files it describes, and the configuration files were checked against each other. This document records what disagreed, what was corrected, and what still needs confirmation from the running cluster.

The method matters here. The configuration files are treated as the authority, because they are what was applied to the nodes. Where a document and a config disagreed, the document was corrected rather than the other way around.

## What Was Checked

Two sources of truth were used and they are not the same thing. The **configuration files** are what was applied to the nodes. The **screenshots** are what the running cluster returned. Where a document disagreed with a config, the document was corrected. Where a config and a screenshot disagreed, the screenshot won and the disagreement is recorded as a finding rather than edited away.

| Check                          | Method                                                                                                        | Result                                                                         |
|--------------------------------|---------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------|
| Documentation against evidence | every claim in the README and the deployment log against the nine screenshots                                 | 4 contradictions, corrected                                                    |
| Hostname consistency           | every hostname in every file mapped back to `configs/shared/hosts` and to the shell prompt in the screenshots | 2 naming layers, both real, now documented                                     |
| IP consistency                 | every occurrence of a `192.168.90.x` address mapped to the hostnames used beside it                           | consistent, no address used for two nodes                                      |
| Version consistency            | every version string across docs, configs, and scripts                                                        | consistent, `4.14.5` pinned as `4.14.5-1`, Filebeat `7.10.2`, HAProxy `2.4.30` |
| Port consistency               | ports in the docs against `configs/lb/haproxy.cfg`, the indexer and dashboard configs                         | consistent                                                                     |
| Cross references               | every file path mentioned in a document                                                                       | 3 broken paths, corrected                                                      |
| Placeholder naming             | every credential placeholder against the README table                                                         | 1 placeholder named two ways, unified                                          |
| Credential exposure            | the whole repository, including scripts and configs                                                           | 2 live secrets in 17 places, redacted                                          |
| Orphan files                   | every config, script, and screenshot against the text of all documents                                        | 10 unreferenced files, now referenced                                          |

## Finding 1: The Server Nodes Carry Two Names, and Both Are Correct

An earlier pass through this repository treated the README topology table as wrong, because it named the three server nodes `wazuh-manager-master`, `wazuh-manager-worker-01`, and `wazuh-manager-worker-02` while every configuration file calls them `wazuh-master-01`, `wazuh-worker-01`, and `wazuh-worker-02`. The screenshots show that conclusion was mistaken and that both names are real.

| Evidence                                  | Shows                         | Name                                                    |
|-------------------------------------------|-------------------------------|---------------------------------------------------------|
| shell prompt in four screenshots          | operating system hostname     | `root@wazuh-manager-master`                             |
| `manager.name` field in Discover          | which manager wrote the alert | `wazuh-manager-worker-01`                               |
| `cluster_control -l`                      | Wazuh cluster node name       | `wazuh-master-01`, `wazuh-worker-01`, `wazuh-worker-02` |
| `configs/shared/wazuh_install_config.yml` | certificate subject           | `wazuh-master-01`, `wazuh-worker-01`, `wazuh-worker-02` |
| `configs/shared/hosts`                    | what resolves in DNS          | `wazuh-master-01.lab.local` and siblings                |

So the operating system hostname and the Wazuh cluster node name diverge on the three server nodes, while on the indexers they match. The README table now lists both columns rather than picking one.

This is not merely tidy. Alerts are attributed by `manager.name`, which carries the operating system hostname, so a search for `wazuh-master-01` in the alert data returns nothing at all while `wazuh-manager-master` returns everything. Anyone writing a dashboard filter or a correlation rule against manager identity needs to know which of the two strings the field actually holds.

Worth aligning the two on a rebuild, since nothing here depends on them differing.

## Finding 2: FQDN and Short Hostname Differ for Two Nodes

In `configs/shared/hosts`, two entries pair an FQDN with a short name that is not its prefix.

```
<DASHBOARD_IP> wazuh-dashboard.lab.local wazuh-dashboard-01
<LB_IP> wazuh-lb.lab.local wazuh-lb-01
```

For the load balancer this is harmless, since HAProxy holds no certificate and agents reach it by IP. For the dashboard it is not, because `configs/shared/wazuh_install_config.yml` issues the dashboard certificate to the name `wazuh-dashboard`. The certificate matches the FQDN and not the short name, so browsing to `https://wazuh-dashboard-01.lab.local` raises a warning while the FQDN does not.

Left as deployed, because correcting it means reissuing the dashboard certificate. It is now stated in the README topology table instead of left for a reader to trip over.

## Finding 3: Agent Names Do Not Match Endpoint Hostnames

Confirmed by the dashboard agent list rather than inferred. Agents 001 and 002 are registered as `agent-linux-01` and `agent-linux-02` at addresses <UBUNTU_AGENT_01_IP> and <UBUNTU_AGENT_02_IP>, which are the hosts named `ubuntu-agent-01` and `ubuntu-agent-02` everywhere else in this repository.

The Windows agents do not have this problem, since 003, 004, and 005 are registered under their hostnames.

A fleet where the agent name and the hostname disagree is harder to work in than it looks. An analyst pivoting from an alert to the host carries a translation table in their head, and correlation against any other source keyed on hostname misses. The fix is on the Ansible side, where the enrollment name is set, and it is worth doing before the fleet grows.

## Finding 4: Five Agents and Three Groups, Not Four and Two

The documentation describes four agents in two groups. The dashboard shows five agents in three.

| ID  | Name           | Address              | Groups       | Reporting to    |
|-----|----------------|----------------------|--------------|-----------------|
| 001 | agent-linux-01 | <UBUNTU_AGENT_01_IP> | linux        | wazuh-worker-02 |
| 002 | agent-linux-02 | <UBUNTU_AGENT_02_IP> | linux        | wazuh-worker-01 |
| 003 | win-agent-02   | <WIN_AGENT_02_IP>    | windows      | wazuh-worker-01 |
| 004 | win-agent-01   | <WIN_AGENT_01_IP>    | windows, win | wazuh-worker-01 |
| 005 | windows-ad-dc  | <AD_DC_IP>           | win          | wazuh-worker-01 |

Two things were undocumented. The **domain controller runs an agent**, which is the right call for a DC and also means the machine that pushes the installer is itself in the fleet. And a **third group named `win`** exists, holding agent 005 and, alongside `windows`, agent 004. Stage 6 creates only `windows` and `linux`, so `win` came from somewhere else, most likely a `WAZUH_AGENT_GROUP` value in an early installer run before the group name was settled.

That matters for coverage rather than for tidiness. Centralized configuration is delivered per group, so agent 005 receives whatever `win` contains, which this repository does not document and Stage 6 never wrote. If `win` has no `agent.conf`, the domain controller is enrolled and active while collecting only its local default configuration, which is the quietest possible failure: the agent is green in the dashboard and the log sources it was meant to collect are missing.

Confirm with `agent_groups -s -g win` on the master, then either give `win` a config or move both agents into `windows` and delete it.

## Finding 5: Agent Distribution Was Described Wrongly

The deployment log states that both Ubuntu agents connect through the load balancer to `wazuh-worker-02`. The dashboard shows 001 on `wazuh-worker-02` and 002 on `wazuh-worker-01`.

The correction is worth making because the dashboard reading is the one that proves the design works. Round robin on port 1514 spreading two agents across two workers is exactly what the HAProxy backend is for, whereas both landing on one worker would have suggested the load balancing was not taking effect.

## Finding 6: Live Credentials Were Published

Two secrets were present in cleartext across 17 places in this repository, including the README, the deployment log, three cluster configuration files, the Ansible group variables, and both Windows installer scripts.

| Secret                    | Now shown as            | Why it matters                                                            |
|---------------------------|-------------------------|---------------------------------------------------------------------------|
| Wazuh cluster key         | `<CLUSTER_KEY>`         | it is the shared secret that authorizes a node to join the server cluster |
| Agent enrollment password | `<ENROLLMENT_PASSWORD>` | it is what `authd` checks before issuing an agent key                     |

Both are now redacted and both are listed in the placeholder table in the README, alongside the three password placeholders the repository already handled correctly. The inconsistency was the point: the repository already had a stated policy of using placeholders for passwords, and these two were the exception rather than an oversight nobody had considered.

Anyone reusing this repository should treat the previously published values as burned and generate new ones, `openssl rand -hex 16` for the cluster key.

## Finding 7: The Screenshots Use the Default Indexer Password

Every captured curl command runs as `-u admin:admin`. That is the shipped default for the indexer `admin` account, and it is the password the README explicitly tells a reader to change with the Wazuh password tool.

The documentation and the evidence therefore disagree about whether the passwords were rotated, and the evidence is the one that reflects the running cluster. This is a lab, so the exposure is contained, but a portfolio repository that says "change the shipped defaults" while showing them still in use undercuts the instruction.

Two things to do. Rotate the account with the password tool the README already documents, and recapture or crop those screenshots so the published evidence matches the published policy.

## Finding 8: Three Broken File Paths

Documents pointed at paths that do not exist.

| Written as                                                            | Actually at                           |
|-----------------------------------------------------------------------|---------------------------------------|
| `DEPLOYMENT-LOG.md` in the README project structure                   | `docs/DEPLOYMENT_LOG.md`              |
| `configs/opensearch-indexer-0X.yml`, twice in the core stack document | `configs/indexer/`, one file per node |
| `configs/ansible/` in the agents document                             | `configs/agents/ansible/`             |

All three were corrected. The README also described a project root named `wazuh-multinode-lab/`, which is not the name of this repository, and that block was rewritten to match the real tree.

## Finding 9: One Placeholder Had Two Names

The README defines `<INDEXER_ADMIN_PASSWORD>` for the indexer `admin` account, and the configuration files use that name. The operations document used a bare `<PASSWORD>` for the same secret in 24 curl examples.

A reader working through the operations document alone has no way to tell which of the three passwords in this stack that is, and the three are not interchangeable: the indexer admin, the dashboard service account, and the Wazuh API account are separate credentials. All 24 occurrences now use `<INDEXER_ADMIN_PASSWORD>`.

## Finding 10: Ten Files Were Never Referenced

Nine of the ten screenshots and one script existed in the repository without a single mention in any document. A screenshot nobody links to is invisible, and the evidence they carry, namely a green cluster, four active agents, a successful Filebeat test, is exactly what a reader wants to see.

A screenshots table was added to the README. `scripts/validate_cluster.sh` is now referenced from the validation section it belongs to.

Three indexer configs and three server cluster configs were also unreferenced, which turned out to be a side effect of finding 8: the documents did reference them, through paths that were wrong.

## Finding 11: Naming Conventions Were Mixed

File names used four conventions at once: numeric prefixes with hyphens in `docs/`, hyphens in `configs/`, underscores in some config files, spaces in screenshots, and PascalCase with a hyphen in one PowerShell script.

Everything is now lower case with underscores, no ordering prefix, and no spaces. Reading order moved from the file names into the README, and the internal stage numbering, Stage 0 through Stage 9, was left untouched because cross references between documents depend on it.

One Indonesian word also appeared in a file name, `ISM dan Snapshot.png`, in an otherwise English repository. It is now `ISM_and_Snapshot.png`.

## Finding 12: Environment Specific Values Were Published Throughout

Beyond the two secrets in finding 6, the repository carried the deployment's own addressing in 258 places across 24 files: thirteen node addresses, the subnet, and the Active Directory domain, in documents, configs, and scripts alike.

None of that is sensitive in the way a cluster key is, since the range is private and the lab is not reachable. It is still the wrong default for a repository meant to be reused, for two reasons. Anyone reproducing this has to find and replace an address that appears nowhere in a list, and a reader cannot tell at a glance which values are structural and which are local.

Every address is now a named placeholder, defined once in the README and set once in `configs/shared/hosts`. The trade is that no command in this repository can be pasted into a shell unchanged. That is deliberate: a command that runs but points at the wrong cluster is worse than one that visibly refuses to run.

The domain `lab.local` was kept as written, because it is already an example value rather than a real one, and replacing it with a placeholder would make the Active Directory instructions in `docs/AGENTS.md` considerably harder to follow.

## What Was Not Changed

Stating the boundaries matters, because the gaps are where the next pass begins.

**The 2 GB RAM constraint.** Every server node runs on 2 GB, which the planning document already flags as below the Wazuh recommended minimum. That is a lab constraint rather than a documentation defect, and it is documented honestly, including the effect on first dashboard load.

**The snapshot repository is not shared storage.** Each indexer writes to its own local `/mnt/wazuh-snapshots`, so the repository is registered with `verify=false`. The deployment log already says this and already names the production fix, namely NFS or S3. It is a known limitation, not an inconsistency.

**No troubleshooting document.** This deployment ran clean through all ten stages and the log records no repeatable symptom, so a troubleshooting document would have to be invented rather than written from experience. If a later run does hit something worth recording, that is when the document earns its place.

**Agent name mismatch in finding 3.** Recorded rather than renamed, because renaming an enrolled agent means re enrolling it. The fix belongs in the Ansible playbook before the next agent is deployed.

**The `win` group in finding 4.** Not deleted and not populated, because either action changes what a live agent collects. Confirm what the group contains first.

**The two naming layers in finding 1.** Not reconciled, because changing an operating system hostname on a running Wazuh node means regenerating certificates and rejoining the cluster. Documented instead.

**The screenshots.** They still show the real addresses and the default indexer password, because they are captures of a session rather than text that can be edited. Recapturing them after rotating the password, per finding 7, would fix both at once. Until then the README says plainly that the images predate the substitution, so a reader is not left wondering why the pictures and the text disagree.
