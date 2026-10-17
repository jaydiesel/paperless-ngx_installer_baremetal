#!/usr/bin/env bash
# =============================================================================
#  install-paperless-ai.sh
#  Bare-metal (NO Docker) installer for Paperless-AI on Debian 13 "trixie"
#  Project: https://github.com/clusterzx/paperless-ai
# =============================================================================
#
#  What it installs
#    * Paperless-AI from GitHub (latest release by default)
#    * Node.js 22 LTS from NodeSource (or Debian's own Node.js 20 with
#      NODE_SOURCE=debian)
#    * The optional RAG service behind "chat with your documents" (Python,
#      CPU-only PyTorch), listening on 127.0.0.1 only
#    * systemd services: paperless-ai.service and paperless-ai-rag.service
#
#  After installing, open http://<this-server>:3000 to run the setup wizard.
#
#  Heads-up: the Paperless-AI README currently says the project is not
#  maintained. Paperless-ngx 3.x has built-in AI features (PAPERLESS_AI_*
#  settings in paperless.conf) that may cover the same needs.
#
#  Usage (as root)
#      bash install-paperless-ai.sh
#
#  Customise by editing the SETTINGS block below, or override any setting
#  from the command line, e.g.:
#      DATA_DIR=/srv/paperless-ai INSTALL_RAG=no bash install-paperless-ai.sh
#
#  Re-running the script upgrades Paperless-AI; your data folder is kept.
# =============================================================================

set -Eeuo pipefail

# =============================================================================
#  SETTINGS: edit these to customise the installation
# =============================================================================
PAPERLESS_AI_VERSION="${PAPERLESS_AI_VERSION:-latest}"   # "latest" or a release tag such as v3.0.9

# --- Directories -------------------------------------------------------------
INSTALL_DIR="${INSTALL_DIR:-/opt/paperless-ai}"          # program files, Node modules, Python venv
DATA_DIR="${DATA_DIR:-$INSTALL_DIR/data}"                # settings (.env), database, RAG index
TMP_DIR="${TMP_DIR:-$INSTALL_DIR/tmp}"                   # scratch space (on disk: /tmp is RAM on Debian 13)

# --- Service -----------------------------------------------------------------
SERVICE_USER="${SERVICE_USER:-paperless-ai}"
WEB_PORT="${WEB_PORT:-3000}"                             # web UI port, all interfaces
INSTALL_RAG="${INSTALL_RAG:-yes}"                        # chat / semantic search (~2 GB disk, 1-2 GB RAM)
RAG_PORT="${RAG_PORT:-8001}"                             # internal, 127.0.0.1 only

# --- Node.js -----------------------------------------------------------------
NODE_SOURCE="${NODE_SOURCE:-nodesource}"                 # nodesource | debian
NODE_MAJOR="${NODE_MAJOR:-22}"                           # NodeSource major version (22 = what upstream's image uses)

# --- Escape hatches ----------------------------------------------------------
FORCE="${FORCE:-no}"                                     # yes = run on something other than Debian 13
REINSTALL="${REINSTALL:-no}"                             # yes = reinstall even if this version is installed

# =============================================================================
#  End of settings
# =============================================================================

VENV="$INSTALL_DIR/venv"
VERSION_FILE="$INSTALL_DIR/.installed-version"
REPO_URL=https://github.com/clusterzx/paperless-ai
TORCH_INDEX=https://download.pytorch.org/whl/cpu

ARCH=""
INSTALLED_VERSION=""
CODE_UPDATED=no
WORK_DIR=""

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
log()  { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

on_error() {
  printf '\033[1;31mERROR:\033[0m command failed (exit %s) at line %s: %s\n' "$1" "$2" "$3" >&2
}
cleanup() {
  if [[ -n $WORK_DIR && -d $WORK_DIR ]]; then rm -rf "$WORK_DIR"; fi
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT

dir_has_files() { [[ -d $1 ]] && [[ -n "$(ls -A "$1" 2>/dev/null || true)" ]]; }

# Run a command as the service user from inside the install directory.
as_ai() {
  (cd "$INSTALL_DIR" && runuser -u "$SERVICE_USER" -- env HOME="$INSTALL_DIR" TMPDIR="$TMP_DIR" \
     npm_config_cache="$INSTALL_DIR/.npm" "$@")
}

# Create directories owned by the service user.
make_dir() {  # make_dir MODE DIR...
  local mode=$1 d
  shift
  for d in "$@"; do
    mkdir -p "$d"
    if ! chown "$SERVICE_USER:$SERVICE_USER" "$d" 2>/dev/null || ! chmod "$mode" "$d" 2>/dev/null; then
      warn "Could not set owner/permissions on $d (network share?). Make sure user '$SERVICE_USER' can write there."
    fi
  done
}

# Fail if PORT is already taken by another program.
check_port() {
  local port=$1 out
  command -v ss >/dev/null 2>&1 || return 0
  out=$(ss -Hltnp "sport = :$port" 2>/dev/null || true)
  if [[ -n $out ]]; then
    warn "Port $port is already in use:"
    printf '%s\n' "$out" >&2
    die "Free port $port first, or change the port in the settings."
  fi
}

# -----------------------------------------------------------------------------
# Steps
# -----------------------------------------------------------------------------
preflight() {
  [[ $EUID -eq 0 ]] || die "Please run this script as root, e.g.: sudo bash $0"

  local os_id os_codename os_name
  # shellcheck source=/dev/null
  os_id=$(. /etc/os-release && echo "${ID:-}")
  # shellcheck source=/dev/null
  os_codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
  # shellcheck source=/dev/null
  os_name=$(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")
  if [[ $os_id != debian || $os_codename != trixie ]]; then
    [[ $FORCE == yes ]] || die "This script is for Debian 13 (trixie), but this is $os_name. Set FORCE=yes to try anyway."
    warn "Not Debian 13 ($os_name). Continuing because FORCE=yes."
  fi

  local v
  for v in INSTALL_RAG FORCE REINSTALL; do
    case ${!v} in yes|no) ;; *) die "$v must be yes or no (got '${!v}')." ;; esac
  done
  for v in WEB_PORT RAG_PORT NODE_MAJOR; do
    [[ ${!v} =~ ^[0-9]+$ ]] || die "$v must be a number (got '${!v}')."
  done
  case $NODE_SOURCE in
    nodesource|debian) ;;
    *) die "NODE_SOURCE must be nodesource or debian (got '$NODE_SOURCE')." ;;
  esac
  [[ $WEB_PORT != "$RAG_PORT" ]] || die "WEB_PORT and RAG_PORT must be different."

  ARCH=$(dpkg --print-architecture)
  if [[ $INSTALL_RAG == yes && $ARCH != amd64 && $ARCH != arm64 ]]; then
    warn "PyTorch has no packages for '$ARCH'; skipping the RAG service."
    INSTALL_RAG=no
  fi

  if [[ -f $VERSION_FILE ]]; then INSTALLED_VERSION=$(<"$VERSION_FILE"); fi

  if ! systemctl is-active --quiet paperless-ai.service 2>/dev/null; then
    check_port "$WEB_PORT"
  fi
  if [[ $INSTALL_RAG == yes ]] && ! systemctl is-active --quiet paperless-ai-rag.service 2>/dev/null; then
    check_port "$RAG_PORT"
  fi
}

install_packages() {
  log "Installing system packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg tar gzip \
    python3 python3-venv python3-dev build-essential
}

install_node() {
  if [[ $NODE_SOURCE == nodesource ]]; then
    log "Installing Node.js $NODE_MAJOR from NodeSource"
    install -d -m 755 /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list
    # Prefer NodeSource's nodejs over Debian's.
    printf 'Package: nodejs\nPin: origin deb.nodesource.com\nPin-Priority: 600\n' > /etc/apt/preferences.d/nodesource
    apt-get update
    apt-get install -y nodejs
  else
    log "Installing Node.js from Debian"
    apt-get install -y --no-install-recommends nodejs npm
  fi

  local major
  major=$(node -p 'process.versions.node.split(".")[0]')
  (( major >= 20 )) || die "Node.js $major is too old; Paperless-AI needs 20 or newer."
  info "Node.js $(node --version), npm $(npm --version)"
}

resolve_version() {
  if [[ $PAPERLESS_AI_VERSION == latest ]]; then
    local url
    url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$REPO_URL/releases/latest" || true)
    PAPERLESS_AI_VERSION=${url##*/}
  fi
  [[ $PAPERLESS_AI_VERSION =~ ^v?[0-9]+\.[0-9]+ ]] \
    || die "Could not determine the Paperless-AI version to install (got '$PAPERLESS_AI_VERSION'). Is GitHub reachable?"
}

create_user_and_dirs() {
  log "Creating the '$SERVICE_USER' system user and directories"
  if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --user-group --home-dir "$INSTALL_DIR" --no-create-home \
            --shell /usr/sbin/nologin "$SERVICE_USER"
  fi
  make_dir 755 "$INSTALL_DIR"
  make_dir 700 "$DATA_DIR" "$TMP_DIR"
}

install_release() {
  if [[ $INSTALLED_VERSION == "$PAPERLESS_AI_VERSION" && $REINSTALL != yes \
        && -f $INSTALL_DIR/server.js && -d $INSTALL_DIR/node_modules ]]; then
    log "Paperless-AI $PAPERLESS_AI_VERSION is already installed (REINSTALL=yes forces a reinstall)"
    return 0
  fi
  if [[ -n $INSTALLED_VERSION && $INSTALLED_VERSION != "$PAPERLESS_AI_VERSION" ]]; then
    log "Upgrading Paperless-AI $INSTALLED_VERSION -> $PAPERLESS_AI_VERSION"
  else
    log "Downloading Paperless-AI $PAPERLESS_AI_VERSION"
  fi

  WORK_DIR=$(mktemp -d)
  local src_dir item name
  curl -fL --retry 3 --progress-bar -o "$WORK_DIR/paperless-ai.tar.gz" \
    "$REPO_URL/archive/refs/tags/$PAPERLESS_AI_VERSION.tar.gz"
  mkdir "$WORK_DIR/extract"
  tar -xzf "$WORK_DIR/paperless-ai.tar.gz" -C "$WORK_DIR/extract"
  src_dir=$(find "$WORK_DIR/extract" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  [[ -n $src_dir && -f $src_dir/server.js && -f $src_dir/package.json && -f $src_dir/main.py ]] \
    || die "The downloaded archive does not have the expected layout."

  systemctl stop paperless-ai.service paperless-ai-rag.service >/dev/null 2>&1 || true
  shopt -s dotglob nullglob
  for item in "$src_dir"/*; do
    name=${item##*/}
    case $name in
      data|venv|node_modules|tmp|.cache|.npm|.local|nltk_data|logs|.installed-version)
        continue ;;   # never touch data, caches or installed dependencies
      *)
        rm -rf "${INSTALL_DIR:?}/$name"
        cp -a "$item" "$INSTALL_DIR/$name"
        chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/$name" ;;
    esac
  done
  shopt -u dotglob nullglob
  CODE_UPDATED=yes
}

# Paperless-AI always uses ./data, so a custom DATA_DIR is linked in as ./data.
link_data_dir() {
  local link="$INSTALL_DIR/data" old=""
  if [[ $DATA_DIR == "$link" ]]; then
    if [[ -L $link ]]; then
      old=$(readlink -f "$link")
      if dir_has_files "$old"; then
        die "$link is a link to $old, which still holds your data. Move it back into place first."
      fi
      rm -f "$link"
    fi
    make_dir 700 "$link"
    return 0
  fi

  if [[ -L $link ]]; then
    old=$(readlink -f "$link")
  elif [[ -d $link ]]; then
    old=$link
  fi
  if [[ -n $old && $old != "$(readlink -f "$DATA_DIR")" ]] && dir_has_files "$old" && ! dir_has_files "$DATA_DIR"; then
    die "DATA_DIR is now $DATA_DIR, but your data is still in $old.
       Stop Paperless-AI (systemctl stop paperless-ai), move the contents of $old
       to $DATA_DIR, then re-run this script. Or change DATA_DIR back."
  fi
  if [[ -d $link && ! -L $link ]]; then
    rmdir "$link"
  fi
  ln -sfn "$DATA_DIR" "$link"
  chown -h "$SERVICE_USER:$SERVICE_USER" "$link"
}

install_node_modules() {
  if [[ $CODE_UPDATED == no && -d $INSTALL_DIR/node_modules ]]; then
    return 0
  fi
  log "Installing Node.js packages"
  as_ai npm ci --omit=dev --no-audit --no-fund --loglevel=error
}

install_rag() {
  if [[ $INSTALL_RAG != yes ]]; then
    return 0
  fi
  if [[ $CODE_UPDATED == no && -x $VENV/bin/python3 ]] \
     && "$VENV/bin/python3" -m pip show -q torch >/dev/null 2>&1; then
    return 0
  fi

  log "Installing the RAG service (Python + CPU-only PyTorch, this takes a while)"
  if [[ ! -x $VENV/bin/python3 ]]; then
    as_ai python3 -m venv "$VENV"
  fi
  as_ai "$VENV/bin/pip" install --quiet --no-cache-dir --disable-pip-version-check --upgrade pip
  # CPU-only PyTorch first, so the requirements below don't pull the huge CUDA build.
  as_ai "$VENV/bin/pip" install --no-cache-dir --disable-pip-version-check \
    --index-url "$TORCH_INDEX" torch
  as_ai "$VENV/bin/pip" install --no-cache-dir --disable-pip-version-check \
    --extra-index-url "$TORCH_INDEX" -r "$INSTALL_DIR/requirements.txt"
}

write_units() {
  log "Creating systemd services"
  local caps="" rag_enabled=false rag_deps="" node_bin
  node_bin=$(command -v node)
  if (( WEB_PORT < 1024 )); then
    # Lets the unprivileged service user bind a port below 1024.
    caps=$'AmbientCapabilities=CAP_NET_BIND_SERVICE\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE'
  fi

  if [[ $INSTALL_RAG == yes ]]; then
    rag_enabled=true
    rag_deps=" paperless-ai-rag.service"
    cat > /etc/systemd/system/paperless-ai-rag.service <<EOF
[Unit]
Description=Paperless-AI RAG service (document chat and semantic search)
After=network-online.target
Wants=network-online.target
# Restarting paperless-ai restarts this service too.
PartOf=paperless-ai.service

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
Environment=HOME=$INSTALL_DIR
Environment=TMPDIR=$TMP_DIR
ExecStart=$VENV/bin/python3 main.py --host 127.0.0.1 --port $RAG_PORT --initialize
Restart=on-failure
RestartSec=10
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  else
    systemctl disable --now --quiet paperless-ai-rag.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/paperless-ai-rag.service
  fi

  cat > /etc/systemd/system/paperless-ai.service <<EOF
[Unit]
Description=Paperless-AI (web UI on port $WEB_PORT)
After=network-online.target$rag_deps
Wants=network-online.target$rag_deps

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
Environment=NODE_ENV=production
Environment=HOME=$INSTALL_DIR
Environment=TMPDIR=$TMP_DIR
Environment=PAPERLESS_AI_PORT=$WEB_PORT
Environment=RAG_SERVICE_ENABLED=$rag_enabled
Environment=RAG_SERVICE_URL=http://127.0.0.1:$RAG_PORT
$caps
ExecStart=$node_bin server.js
Restart=always
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

start_services() {
  log "Starting Paperless-AI"
  systemctl enable --quiet paperless-ai.service
  if [[ $INSTALL_RAG == yes ]]; then systemctl enable --quiet paperless-ai-rag.service; fi
  systemctl restart paperless-ai.service

  local i code
  for ((i = 0; i < 60; i++)); do
    code=$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "http://127.0.0.1:$WEB_PORT/" || true)
    if [[ -n $code && $code != 000 ]]; then
      info "Web UI is up on port $WEB_PORT"
      return 0
    fi
    sleep 2
  done
  journalctl -u paperless-ai --no-pager -n 40 >&2 || true
  die "Paperless-AI did not come up. Check: journalctl -u paperless-ai -e"
}

summary() {
  printf '%s\n' "$PAPERLESS_AI_VERSION" > "$VERSION_FILE"

  local host="" ip rag_note=""
  for ip in $(hostname -I 2>/dev/null || true); do
    if [[ $ip =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then host=$ip; break; fi
  done
  host=${host:-$(hostname -f 2>/dev/null || hostname)}
  if [[ $INSTALL_RAG == yes ]]; then
    rag_note="
 The RAG service downloads its language models (roughly 0.5 GB) from Hugging
 Face the first time it starts with your settings, so chat needs a few minutes.
   journalctl -u paperless-ai-rag -f          RAG service log
"
  fi

  cat <<EOF

=============================================================================
 Paperless-AI $PAPERLESS_AI_VERSION is installed and running
=============================================================================
 Open the setup wizard:   http://$host:$WEB_PORT

 In the wizard
   Paperless-ngx URL ... http://localhost  (Paperless-ngx on this machine;
                         use the URL install-paperless-ngx.sh printed)
   API token ........... in Paperless-ngx: user menu (top right) > My Profile
                         > API Auth Token
 When the wizard is done, run:  systemctl restart paperless-ai
 (this also restarts the RAG service so it picks up the new settings)
$rag_note
 Folders
   Program ............ $INSTALL_DIR
   Data / settings .... $DATA_DIR

 Commands
   systemctl status paperless-ai              service status
   journalctl -u paperless-ai -f              live log
   bash $0                                    upgrade to the newest release later

 If a firewall (ufw/nftables) is active, open TCP port $WEB_PORT.
=============================================================================
EOF
}

main() {
  preflight
  install_packages
  install_node
  resolve_version
  create_user_and_dirs
  install_release
  link_data_dir
  install_node_modules
  install_rag
  write_units
  start_services
  summary
}

main "$@"
