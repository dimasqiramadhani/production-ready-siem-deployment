# 14. Ubuntu Linux Agent Mass Deployment with Ansible

Two Ubuntu endpoints: ubuntu-agent-01 (10.10.10.111), ubuntu-agent-02
(10.10.10.112). Deployed with Ansible, all enrollment variables pointing at the load
balancer.

Deployment variables:
- `WAZUH_MANAGER=wazuh-lb.lab.local`
- `WAZUH_REGISTRATION_SERVER=wazuh-lb.lab.local`
- `WAZUH_AGENT_GROUP=linux`
- `WAZUH_REGISTRATION_PASSWORD=<password>` (only if enrollment password enabled)

The `linux` group must already exist (section 10).

All four files below are also in `configs/ansible/`.

## 14.1 inventory.ini

```ini
[linux_agents]
ubuntu-agent-01 ansible_host=10.10.10.111
ubuntu-agent-02 ansible_host=10.10.10.112

[linux_agents:vars]
ansible_user=ubuntu
ansible_become=true
```

## 14.2 ansible.cfg

```ini
[defaults]
inventory = inventory.ini
host_key_checking = False
retry_files_enabled = False
deprecation_warnings = False

[privilege_escalation]
become = True
become_method = sudo
```

## 14.3 group_vars/linux_agents.yml

```yaml
wazuh_manager: "wazuh-lb.lab.local"
wazuh_registration_server: "wazuh-lb.lab.local"
wazuh_agent_group: "linux"
wazuh_registration_password: "ChangeMeEnrollPass"
wazuh_agent_version: "4.14.0-1"
```

## 14.4 install-wazuh-agent.yml

```yaml
---
- name: Deploy Wazuh agent to Ubuntu endpoints
  hosts: linux_agents
  become: true
  tasks:

    - name: Install dependencies
      apt:
        name:
          - curl
          - gnupg
          - apt-transport-https
          - lsb-release
        state: present
        update_cache: true

    - name: Add Wazuh GPG key
      ansible.builtin.shell: |
        curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | \
        gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import
        chmod 644 /usr/share/keyrings/wazuh.gpg
      args:
        creates: /usr/share/keyrings/wazuh.gpg

    - name: Add Wazuh repository
      ansible.builtin.apt_repository:
        repo: "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main"
        filename: wazuh
        state: present

    - name: Install wazuh-agent with enrollment variables
      ansible.builtin.apt:
        name: "wazuh-agent={{ wazuh_agent_version }}"
        state: present
        update_cache: true
      environment:
        WAZUH_MANAGER: "{{ wazuh_manager }}"
        WAZUH_REGISTRATION_SERVER: "{{ wazuh_registration_server }}"
        WAZUH_AGENT_GROUP: "{{ wazuh_agent_group }}"
        WAZUH_REGISTRATION_PASSWORD: "{{ wazuh_registration_password }}"

    - name: Reload systemd
      ansible.builtin.systemd:
        daemon_reload: true

    - name: Enable and start wazuh-agent
      ansible.builtin.systemd:
        name: wazuh-agent
        enabled: true
        state: started

    - name: Validate service is active
      ansible.builtin.command: systemctl is-active wazuh-agent
      register: agent_status
      changed_when: false

    - name: Show service status
      ansible.builtin.debug:
        msg: "wazuh-agent on {{ inventory_hostname }} is {{ agent_status.stdout }}"
```

## 14.5 Run the playbook

```bash
# Connectivity check
ansible -i inventory.ini linux_agents -m ping

# Deploy
ansible-playbook -i inventory.ini install-wazuh-agent.yml
```

## 14.6 Linux validation commands

Run on each Ubuntu endpoint:

```bash
systemctl status wazuh-agent
tail -f /var/ossec/logs/ossec.log
nc -vz wazuh-lb.lab.local 1514
nc -vz wazuh-lb.lab.local 1515
```

Healthy result: service active (running), ossec.log shows successful enrollment via
the registration server and connection to the manager, both nc tests succeed. The
agent appears in the `linux` group on the dashboard.

## 14.7 Note on enrollment via load balancer

Because enrollment (1515) is forwarded only to the master and reporting (1514) is
balanced across workers, `WAZUH_REGISTRATION_SERVER` and `WAZUH_MANAGER` can both be
`wazuh-lb.lab.local`. The agent registers through the LB to the master, then reports
through the LB to whichever worker the LB selects.
