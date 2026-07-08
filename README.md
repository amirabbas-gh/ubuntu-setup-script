# Ubuntu 24.04 Server Provisioning

This repository provisions a fresh **Ubuntu 24.04 LTS** server for **production** use with Ansible.

## What It Does
- Fully updates the system and installs required dependencies
- Installs and enables `Nginx` (official repository)
- Installs `Docker Engine` + `Docker CLI` + `Buildx` + `Compose Plugin` (official Docker repository)
- Installs `PHP 8.x` (latest stable available) with common WordPress extensions
- Installs `Node.js LTS` + `npm` (NodeSource) and `PM2`
- Installs C/C++ build tools (`gcc`, `g++`, `make`, `cmake`, `pkg-config`)
- Configures `Git credential.helper store`
- Configures `UFW` to allow only `SSH`, `Nginx`
- Runs final version and service checks

## Playbook Guarantees
- Non-interactive
- Idempotent as much as reasonably possible (safe to re-run)
- Fail-fast behavior (play stops immediately on task errors)
- Clear step-by-step logs and meaningful errors

## Ansible Usage
```bash
cp inventory.ini.example inventory.ini
# edit inventory.ini with your server IP and SSH user
ansible-playbook -i inventory.ini provision.yml
```

> Recommended: run this on a fresh server.
