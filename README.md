# Ubuntu 24.04 Provision Script

This repository contains a single script, `provision.sh`, that fully prepares a fresh **Ubuntu 24.04 LTS** server for **production** use.

## What It Does
- Fully updates the system and installs required dependencies
- Installs and enables `Nginx` (official repository)
- Installs `Docker Engine` + `Docker CLI` + `Buildx` + `Compose Plugin` (official Docker repository)
- Installs `PHP 8.x` (latest stable available) with common WordPress extensions
- Installs `Node.js LTS` + `npm` (NodeSource) and `PM2`
- Installs C/C++ build tools (`gcc`, `g++`, `make`, `cmake`, `pkg-config`)
- Configures `Git credential.helper store`
- Configures `UFW` to allow only `SSH` and `Nginx`
- Runs final version and service checks

## Script Guarantees
- Non-interactive
- Idempotent as much as reasonably possible (safe to re-run)
- Fail-fast with `set -Eeuo pipefail`
- Clear step-by-step logs and meaningful errors

## Usage
```bash
sudo bash provision.sh
```

> Recommended: run this on a fresh server.
