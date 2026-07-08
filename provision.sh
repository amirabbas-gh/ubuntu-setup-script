#!/usr/bin/env bash
#
# provision.sh
#
# Fully provisions a brand-new Ubuntu 24.04 LTS server with:
#   Nginx, Docker (Engine + Compose plugin), PHP 8.x (WordPress-ready extensions),
#   Node.js LTS + npm, PM2 (with boot persistence), Git credential storage,
#   C/C++ build tooling (gcc/g++/make), and a locked-down UFW firewall.
#
# Design goals: idempotent, non-interactive, fail-fast, verbose progress output,
# latest stable software from official upstream repositories.
#
# Usage:
#   sudo bash provision.sh
#
# Tested target: Ubuntu 24.04 LTS ("Noble Numbat"), fresh install.

set -Eeuo pipefail

# --------------------------------------------------------------------------
# Globals / non-interactive apt behaviour
# --------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a   # auto-restart services after lib upgrades, no prompts

readonly LOG_PREFIX="[provision]"
readonly UBUNTU_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-noble}")"
readonly REAL_USER="${SUDO_USER:-$USER}"
readonly REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"

# --------------------------------------------------------------------------
# Logging & error handling
# --------------------------------------------------------------------------
log()  { printf '%s [%s] %s\n' "${LOG_PREFIX}" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
step() { printf '\n%s ==== %s ====\n' "${LOG_PREFIX}" "$*"; }
die()  { printf '%s [ERROR] %s\n' "${LOG_PREFIX}" "$*" >&2; exit 1; }

on_error() {
    local exit_code=$?
    local line_no=${1:-unknown}
    printf '%s [FATAL] Script failed at line %s (exit code %s). Aborting.\n' \
        "${LOG_PREFIX}" "${line_no}" "${exit_code}" >&2
    exit "${exit_code}"
}
trap 'on_error ${LINENO}' ERR

# --------------------------------------------------------------------------
# Pre-flight checks
# --------------------------------------------------------------------------
step "Pre-flight checks"

if [[ "${EUID}" -ne 0 ]]; then
    die "This script must be run as root (e.g. 'sudo bash provision.sh')."
fi

if [[ ! -f /etc/os-release ]] || ! grep -qi "ubuntu" /etc/os-release; then
    die "This script is intended for Ubuntu only."
fi

if ! grep -q "24.04" /etc/os-release; then
    log "WARNING: This script was designed for Ubuntu 24.04. Detected a different version; continuing anyway."
fi

log "Running as root. Target user for user-scoped config: ${REAL_USER} (home: ${REAL_HOME})"

# --------------------------------------------------------------------------
# Helper: idempotent apt package installer
# --------------------------------------------------------------------------
apt_install() {
    # Installs any packages not already installed. No-op if all present.
    local pkgs=("$@")
    local to_install=()
    for pkg in "${pkgs[@]}"; do
        if ! dpkg -s "${pkg}" >/dev/null 2>&1; then
            to_install+=("${pkg}")
        fi
    done
    if [[ ${#to_install[@]} -gt 0 ]]; then
        log "Installing packages: ${to_install[*]}"
        apt-get install -y --no-install-recommends "${to_install[@]}"
    else
        log "All requested packages already installed: ${pkgs[*]}"
    fi
}

# Helper: add an apt keyring + repo definition idempotently
add_apt_repo() {
    local name="$1" gpg_url="$2" keyring_path="$3" repo_line="$4" list_path="$5"

    if [[ ! -f "${keyring_path}" ]]; then
        log "Adding GPG key for ${name}"
        curl -fsSL "${gpg_url}" | gpg --dearmor -o "${keyring_path}"
        chmod a+r "${keyring_path}"
    else
        log "GPG key for ${name} already present, skipping"
    fi

    if [[ ! -f "${list_path}" ]] || ! grep -qF "${repo_line}" "${list_path}" 2>/dev/null; then
        log "Writing apt source list for ${name}"
        echo "${repo_line}" > "${list_path}"
    else
        log "Apt source for ${name} already configured, skipping"
    fi
}

# ==========================================================================
# 1. SYSTEM PREPARATION
# ==========================================================================
step "1/9 System preparation: update, upgrade, base dependencies"

log "Refreshing package lists"
apt-get update -y

log "Upgrading installed packages to latest versions"
apt-get upgrade -y
apt-get dist-upgrade -y

log "Installing common base dependencies"
apt_install \
    ca-certificates \
    curl \
    wget \
    gnupg \
    lsb-release \
    software-properties-common \
    apt-transport-https \
    unzip \
    tar \
    git \
    ufw \
    build-essential \
    gcc \
    g++ \
    make \
    cmake \
    pkg-config \
    jq \
    cron

log "Ensuring /etc/apt/keyrings exists for keyring-based repos"
install -m 0755 -d /etc/apt/keyrings

# ==========================================================================
# 2. NGINX (official nginx.org mainline/stable repo for latest version)
# ==========================================================================
step "2/9 Installing Nginx (official nginx.org repository)"

if ! command -v nginx >/dev/null 2>&1 || ! apt-cache policy nginx | grep -q "nginx.org"; then
    add_apt_repo \
        "nginx" \
        "https://nginx.org/keys/nginx_signing.key" \
        "/etc/apt/keyrings/nginx-archive-keyring.gpg" \
        "deb [signed-by=/etc/apt/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu ${UBUNTU_CODENAME} nginx" \
        "/etc/apt/sources.list.d/nginx.list"

    # Prefer the official nginx.org package over the distro's for the latest stable build
    cat > /etc/apt/preferences.d/99-nginx <<'EOF'
Package: nginx*
Pin: origin nginx.org
Pin-Priority: 900
EOF

    apt-get update -y
    apt_install nginx
else
    log "Nginx already installed from nginx.org repo"
fi

log "Enabling and starting Nginx"
systemctl enable nginx
systemctl restart nginx

# ==========================================================================
# 3. DOCKER (official Docker CE repository)
# ==========================================================================
step "3/9 Installing Docker Engine, CLI, Buildx, Compose plugin"

if ! command -v docker >/dev/null 2>&1; then
    add_apt_repo \
        "docker" \
        "https://download.docker.com/linux/ubuntu/gpg" \
        "/etc/apt/keyrings/docker.gpg" \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
        "/etc/apt/sources.list.d/docker.list"

    apt-get update -y
    apt_install \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
else
    log "Docker already installed"
fi

log "Enabling and starting Docker"
systemctl enable docker
systemctl restart docker

log "Verifying Docker functions correctly (hello-world)"
if ! docker run --rm hello-world >/dev/null 2>&1; then
    die "Docker verification failed: 'docker run hello-world' did not succeed."
fi
log "Docker verified successfully."

if ! docker compose version >/dev/null 2>&1; then
    die "Docker Compose plugin is not available ('docker compose version' failed)."
fi
log "Docker Compose plugin verified: $(docker compose version)"

# Allow the invoking non-root user to run docker without sudo
if id "${REAL_USER}" >/dev/null 2>&1 && [[ "${REAL_USER}" != "root" ]]; then
    if ! id -nG "${REAL_USER}" | grep -qw docker; then
        log "Adding ${REAL_USER} to the docker group"
        usermod -aG docker "${REAL_USER}"
        log "NOTE: ${REAL_USER} must log out/in (or run 'newgrp docker') for group membership to take effect."
    fi
fi

# ==========================================================================
# 4. PHP 8.x for WordPress (ondrej/php PPA -- the de-facto official source
#    of current PHP releases for Debian/Ubuntu, maintained by a PHP core
#    packaging contributor; Ubuntu's own repos lag far behind upstream PHP)
# ==========================================================================
step "4/9 Installing PHP 8.x with WordPress-required extensions"

if ! apt-cache policy | grep -q "ondrej/php"; then
    log "Adding ondrej/php PPA for latest stable PHP 8.x"
    add-apt-repository -y ppa:ondrej/php
    apt-get update -y
else
    log "ondrej/php PPA already configured"
fi

# Determine latest available PHP 8.x version from the PPA
PHP_VERSION="$(apt-cache madison php 2>/dev/null | awk '{print $3}' | grep -oP '^8\.\d+' | sort -V | uniq | tail -1 || true)"
if [[ -z "${PHP_VERSION}" ]]; then
    PHP_VERSION="8.3"
    log "Could not auto-detect latest PHP version, defaulting to ${PHP_VERSION}"
else
    log "Latest available PHP 8.x version detected: ${PHP_VERSION}"
fi

apt_install \
    "php${PHP_VERSION}" \
    "php${PHP_VERSION}-fpm" \
    "php${PHP_VERSION}-cli" \
    "php${PHP_VERSION}-common" \
    "php${PHP_VERSION}-mysql" \
    "php${PHP_VERSION}-curl" \
    "php${PHP_VERSION}-xml" \
    "php${PHP_VERSION}-mbstring" \
    "php${PHP_VERSION}-zip" \
    "php${PHP_VERSION}-gd" \
    "php${PHP_VERSION}-intl" \
    "php${PHP_VERSION}-bcmath" \
    "php${PHP_VERSION}-soap" \
    "php${PHP_VERSION}-opcache" \
    "php${PHP_VERSION}-readline" \
    "php${PHP_VERSION}-xmlrpc" \
    "php${PHP_VERSION}-imap"

# imagick is not always packaged for every PHP version in the PPA; install best-effort
if apt-cache show "php${PHP_VERSION}-imagick" >/dev/null 2>&1; then
    apt_install "php${PHP_VERSION}-imagick"
else
    log "php${PHP_VERSION}-imagick not available in repos; skipping (install via PECL if required)"
fi

log "Enabling and starting PHP-FPM ${PHP_VERSION}"
systemctl enable "php${PHP_VERSION}-fpm"
systemctl restart "php${PHP_VERSION}-fpm"

# ==========================================================================
# 5. NODE.JS (official NodeSource repository, latest LTS)
# ==========================================================================
step "5/9 Installing Node.js LTS + npm (NodeSource official repository)"

if ! command -v node >/dev/null 2>&1; then
    log "Setting up NodeSource repository for latest LTS Node.js"
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    apt_install nodejs
else
    log "Node.js already installed: $(node -v)"
fi

command -v node >/dev/null 2>&1 || die "Node.js installation failed."
command -v npm  >/dev/null 2>&1 || die "npm installation failed."
log "Node.js version: $(node -v)"
log "npm version: $(npm -v)"

# ==========================================================================
# 6. PM2 (global npm install + boot persistence)
# ==========================================================================
step "6/9 Installing PM2 and configuring startup persistence"

if ! command -v pm2 >/dev/null 2>&1; then
    log "Installing PM2 globally via npm"
    npm install -g pm2
else
    log "PM2 already installed: $(pm2 -v)"
fi

log "Configuring PM2 to launch on boot for user '${REAL_USER}'"
# pm2 startup prints a command that must be executed as root; env -u strips
# nothing needed here since we're already root. We generate and apply it directly.
PM2_BIN="$(command -v pm2)"
env PATH="$PATH" "${PM2_BIN}" startup systemd -u "${REAL_USER}" --hp "${REAL_HOME}" >/tmp/pm2_startup_output.log 2>&1 || true

STARTUP_CMD="$(grep -Eo '^sudo .*pm2 .*$' /tmp/pm2_startup_output.log || true)"
if [[ -n "${STARTUP_CMD}" ]]; then
    log "Applying PM2 startup command"
    eval "${STARTUP_CMD#sudo }"
else
    log "PM2 startup command not detected in output; systemd unit may already exist. Continuing."
fi

# Persist current (possibly empty) process list so 'pm2 resurrect' works after reboot
sudo -u "${REAL_USER}" env PATH="$PATH" "${PM2_BIN}" save --force || true

# ==========================================================================
# 7. GIT CONFIGURATION (credential storage)
# ==========================================================================
step "7/9 Configuring Git credential storage"

configure_git_for_user() {
    local user="$1"
    local home_dir
    home_dir="$(getent passwd "${user}" | cut -d: -f6)"
    if [[ -z "${home_dir}" ]]; then
        log "Could not resolve home directory for ${user}; skipping git config"
        return
    fi
    log "Setting git credential.helper=store for user ${user}"
    sudo -u "${user}" git config --global credential.helper store
}

configure_git_for_user "${REAL_USER}"
# Also configure for root, in case automation runs as root later
git config --global credential.helper store

# ==========================================================================
# 8. UFW FIREWALL
# ==========================================================================
step "8/9 Configuring UFW firewall"

log "Setting default policies: deny incoming, allow outgoing"
ufw default deny incoming
ufw default allow outgoing

log "Allowing SSH (to avoid lockout)"
ufw allow OpenSSH

log "Allowing Nginx (HTTP/HTTPS)"
ufw allow 80/tcp
ufw allow 443/tcp

log "Enabling UFW (non-interactive)"
ufw --force enable

# ==========================================================================
# 9. FINAL VERIFICATION
# ==========================================================================
step "9/9 Final verification"

check_service_active() {
    local svc="$1"
    if systemctl is-active --quiet "${svc}"; then
        log "OK: ${svc} is running"
    else
        die "${svc} is NOT running as expected."
    fi
}

echo
echo "=================== INSTALLED VERSIONS ==================="
printf 'Nginx:           %s\n' "$(nginx -v 2>&1 | sed -E 's/^nginx version: //')"
printf 'Docker:          %s\n' "$(docker --version)"
printf 'Docker Compose:  %s\n' "$(docker compose version --short 2>/dev/null || docker compose version)"
printf 'PHP:             %s\n' "$(php -v | head -n1)"
printf 'Node.js:         %s\n' "$(node -v)"
printf 'npm:             %s\n' "$(npm -v)"
printf 'PM2:             %s\n' "$(pm2 -v)"
printf 'Git:             %s\n' "$(git --version)"
echo "============================================================"
echo

echo "=================== SERVICE STATUS ========================"
check_service_active "nginx"
check_service_active "docker"
check_service_active "php${PHP_VERSION}-fpm"

if ufw status | grep -q "Status: active"; then
    log "OK: UFW is enabled"
else
    die "UFW is not enabled as expected."
fi
echo "============================================================"
echo

log "Provisioning completed successfully."
log "Reminder: if ${REAL_USER} was newly added to the 'docker' group, they must re-login for it to take effect."
