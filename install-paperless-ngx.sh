#!/usr/bin/env bash
# =============================================================================
#  install-paperless-ngx.sh
#  Bare-metal (NO Docker) installer for Paperless-ngx on Debian 13 "trixie"
# =============================================================================
#
#  What it installs
#    * Paperless-ngx from the official release tarball (latest by default)
#    * A Python virtualenv with CPU-only PyTorch (skips the multi-GB CUDA build)
#    * PostgreSQL (default) or SQLite, and Redis as the task broker
#    * OCR tools: Tesseract, Ghostscript, unpaper, qpdf, pngquant, jbig2enc
#    * systemd services: web server(s), consumer, task queue, scheduler
#
#  Web access: Paperless-ngx's own web server (Granian) listens directly on
#  port 80 (HTTP) and, if enabled, port 443 (HTTPS). No reverse proxy. With
#  HTTPS on and no certificate given, a self-signed certificate is created.
#
#  Usage (as root)
#      bash install-paperless-ngx.sh
#
#  Customise by editing the SETTINGS block below, or override any setting
#  from the command line, e.g.:
#      MEDIA_DIR=/srv/paperless/media OCR_LANGUAGES="eng deu" bash install-paperless-ngx.sh
#
#  Re-running the script upgrades Paperless-ngx to the newest release and
#  applies changed settings. Documents, database and secrets are kept.
# =============================================================================

set -Eeuo pipefail

# =============================================================================
#  SETTINGS: edit these to customise the installation
# =============================================================================

# --- Version -----------------------------------------------------------------
PAPERLESS_VERSION="${PAPERLESS_VERSION:-latest}"     # "latest" or a release tag such as v3.3.2

# --- Directories -------------------------------------------------------------
# The paperless user must be able to write to all of these. If you point one
# at a network share (NFS/SMB), also set PAPERLESS_CONSUMER_POLLING_INTERVAL in
# paperless.conf for the consume folder, because file-change events don't work there.
INSTALL_DIR="${INSTALL_DIR:-/opt/paperless}"           # program files, Python venv, paperless.conf
DATA_DIR="${DATA_DIR:-$INSTALL_DIR/data}"              # SQLite DB (if used), search index, classifier
MEDIA_DIR="${MEDIA_DIR:-$INSTALL_DIR/media}"           # your documents: originals, archived PDFs, thumbnails
CONSUME_DIR="${CONSUME_DIR:-$INSTALL_DIR/consume}"     # drop files here to import them
EXPORT_DIR="${EXPORT_DIR:-$INSTALL_DIR/export}"        # target folder for document_exporter backups
LOG_DIR="${LOG_DIR:-$DATA_DIR/log}"                    # Paperless log files
TMP_DIR="${TMP_DIR:-$INSTALL_DIR/tmp}"                 # OCR scratch space (on disk: /tmp is RAM on Debian 13)
SSL_DIR="${SSL_DIR:-/etc/paperless/ssl}"               # where the HTTPS certificate and key are kept

# --- Service account ---------------------------------------------------------
PAPERLESS_USER="${PAPERLESS_USER:-paperless}"

# --- Web server --------------------------------------------------------------
ENABLE_HTTP="${ENABLE_HTTP:-yes}"                      # serve plain HTTP
HTTP_PORT="${HTTP_PORT:-80}"
ENABLE_HTTPS="${ENABLE_HTTPS:-yes}"                    # serve HTTPS
HTTPS_PORT="${HTTPS_PORT:-443}"
SSL_CERT_FILE="${SSL_CERT_FILE:-}"                     # your certificate (PEM, full chain); empty = self-signed
SSL_KEY_FILE="${SSL_KEY_FILE:-}"                       # your private key (PEM); empty = self-signed
SELF_SIGNED_DAYS="${SELF_SIGNED_DAYS:-3650}"           # validity of the generated self-signed certificate
PAPERLESS_DOMAIN="${PAPERLESS_DOMAIN:-}"               # main hostname; empty = this machine's FQDN (hostname -f)
EXTRA_HOSTS="${EXTRA_HOSTS:-}"                         # other names/IPs used to reach the server, comma-separated
BIND_ADDRESS="${BIND_ADDRESS:-auto}"                   # auto = all interfaces (IPv6 + IPv4 when available)
WEB_WORKERS="${WEB_WORKERS:-1}"                        # Granian workers per port; each loads the whole app

# --- Database (used on the FIRST install only; later, edit paperless.conf) ---
DB_ENGINE="${DB_ENGINE:-postgresql}"                   # postgresql | sqlite
DB_HOST="${DB_HOST:-localhost}"                        # localhost = install PostgreSQL on this machine
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-paperless}"
DB_USER="${DB_USER:-paperless}"
DB_PASS="${DB_PASS:-}"                                 # empty = generate a random password

# --- OCR and locale ----------------------------------------------------------
OCR_LANGUAGES="${OCR_LANGUAGES:-eng}"                  # Tesseract codes: "eng", "eng deu", "deu+eng+fra"
TIME_ZONE="${TIME_ZONE:-}"                             # e.g. Europe/Berlin; empty = the system's time zone

# --- Extras ------------------------------------------------------------------
INSTALL_JBIG2ENC="${INSTALL_JBIG2ENC:-yes}"            # smaller PDFs; prebuilt .deb from the paperless-ngx project
PYTHON_VERSION="${PYTHON_VERSION:-system}"             # system (Debian's 3.13) or e.g. 3.14 (downloaded by uv)

# --- First admin account (optional; otherwise you are prompted) -------------
ADMIN_USER="${ADMIN_USER:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"

# --- Escape hatches ----------------------------------------------------------
FORCE="${FORCE:-no}"                                   # yes = run on something other than Debian 13
REINSTALL="${REINSTALL:-no}"                           # yes = reinstall even if this version is installed

# =============================================================================
#  End of settings
# =============================================================================

CONFIG_FILE="$INSTALL_DIR/paperless.conf"
VERSION_FILE="$INSTALL_DIR/.installed-version"
VENV="$INSTALL_DIR/.venv"
UV_HOME="$INSTALL_DIR/.uv"
STATIC_DIR="$INSTALL_DIR/static"
REPO_URL=https://github.com/paperless-ngx/paperless-ngx
TORCH_INDEX=https://download.pytorch.org/whl/cpu
JBIG2ENC_VERSION=0.30
ALL_SERVICES=(paperless-webserver paperless-webserver-https paperless-consumer paperless-task-queue paperless-scheduler)

ARCH=""
INSTALLED_VERSION=""
CODE_UPDATED=no
CERT_KIND=""
NEED_ADMIN=no
WORK_DIR=""
SERVICES=()
WEB_HOSTS=()
OCR_LANG_LIST=()
PAPERLESS_OCR_LANGUAGE=""

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

ensure_workdir() {
  if [[ -z $WORK_DIR ]]; then
    WORK_DIR=$(mktemp -d)
    chmod 755 "$WORK_DIR"   # lets apt's sandbox user read local .deb files
  fi
}

join_by() { local IFS=$1; shift; printf '%s' "$*"; }
is_ipv4() { [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }
dir_has_files() { [[ -d $1 ]] && [[ -n "$(ls -A "$1" 2>/dev/null || true)" ]]; }

# "https://host" or "https://host:8443" depending on whether the port is the default one.
origin() {  # origin SCHEME HOST PORT
  if [[ ($1 == http && $3 == 80) || ($1 == https && $3 == 443) ]]; then
    printf '%s://%s' "$1" "$2"
  else
    printf '%s://%s:%s' "$1" "$2" "$3"
  fi
}

# Run a command as the paperless user from inside the install directory.
as_paperless() {
  (cd "$INSTALL_DIR" && runuser -u "$PAPERLESS_USER" -- env HOME="$INSTALL_DIR" \
     TMPDIR="$TMP_DIR" PAPERLESS_CONFIGURATION_PATH="$CONFIG_FILE" "$@")
}

# Run a Django management command (manage.py) as the paperless user.
manage() {
  (cd "$INSTALL_DIR/src" && runuser -u "$PAPERLESS_USER" -- env HOME="$INSTALL_DIR" \
     TMPDIR="$TMP_DIR" PAPERLESS_CONFIGURATION_PATH="$CONFIG_FILE" \
     "$VENV/bin/python3" manage.py "$@")
}

# Read KEY from paperless.conf (surrounding quotes removed).
conf_get() {
  [[ -f $CONFIG_FILE ]] || return 0
  sed -n -E "s/^$1=//p" "$CONFIG_FILE" | tail -n 1 | sed -E "s/^'(.*)'$/\1/; s/^\"(.*)\"$/\1/"
}

# Replace the KEY= line in paperless.conf, or append it if missing.
set_conf() {
  local tmp
  tmp=$(mktemp)
  KEY="$1" VALUE="$2" awk '
    BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VALUE"]; done = 0 }
    index($0, k "=") == 1 { if (!done) print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$CONFIG_FILE" > "$tmp"
  cat "$tmp" > "$CONFIG_FILE"   # keeps the file's owner and permissions
  rm -f "$tmp"
}

# Create directories owned by the paperless user (tolerates network shares).
make_dir() {  # make_dir MODE DIR...
  local mode=$1 d
  shift
  for d in "$@"; do
    mkdir -p "$d"
    if ! chown "$PAPERLESS_USER:$PAPERLESS_USER" "$d" 2>/dev/null || ! chmod "$mode" "$d" 2>/dev/null; then
      warn "Could not set owner/permissions on $d (network share?). Make sure user '$PAPERLESS_USER' can write there."
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
    die "Free port $port first (e.g. stop/remove nginx or apache2), or change the port in the settings."
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

  ARCH=$(dpkg --print-architecture)
  case $ARCH in
    amd64|arm64) ;;
    *) die "Unsupported CPU architecture '$ARCH'. Paperless-ngx needs PyTorch, which is only published for amd64 and arm64." ;;
  esac

  if [[ -f $VERSION_FILE ]]; then INSTALLED_VERSION=$(<"$VERSION_FILE"); fi

  # An existing paperless.conf decides the database engine.
  if [[ -f $CONFIG_FILE ]]; then
    local existing
    existing=$(conf_get PAPERLESS_DBENGINE)
    DB_ENGINE=${existing:-sqlite}
  else
    case $DB_ENGINE in
      postgresql|sqlite) ;;
      *) die "DB_ENGINE must be postgresql or sqlite (got '$DB_ENGINE')." ;;
    esac
  fi

  local v
  for v in ENABLE_HTTP ENABLE_HTTPS INSTALL_JBIG2ENC; do
    case ${!v} in yes|no) ;; *) die "$v must be yes or no (got '${!v}')." ;; esac
  done
  if [[ $ENABLE_HTTP == no && $ENABLE_HTTPS == no ]]; then
    die "ENABLE_HTTP and ENABLE_HTTPS are both 'no'; enable at least one."
  fi
  for v in HTTP_PORT HTTPS_PORT WEB_WORKERS SELF_SIGNED_DAYS DB_PORT; do
    [[ ${!v} =~ ^[0-9]+$ ]] || die "$v must be a number (got '${!v}')."
  done
  if [[ $ENABLE_HTTP == yes && $ENABLE_HTTPS == yes && $HTTP_PORT == "$HTTPS_PORT" ]]; then
    die "HTTP_PORT and HTTPS_PORT must be different."
  fi
  if [[ -n $SSL_CERT_FILE || -n $SSL_KEY_FILE ]]; then
    [[ -r $SSL_CERT_FILE && -r $SSL_KEY_FILE ]] || die "SSL_CERT_FILE and SSL_KEY_FILE must both point to readable files."
  fi

  if [[ $BIND_ADDRESS == auto ]]; then
    if [[ -e /proc/net/if_inet6 ]]; then BIND_ADDRESS="::"; else BIND_ADDRESS="0.0.0.0"; fi
  fi

  # OCR languages -> tesseract packages (checked after apt update) and the config value.
  read -r -a OCR_LANG_LIST <<< "${OCR_LANGUAGES//[,+]/ }"
  ((${#OCR_LANG_LIST[@]})) || die "OCR_LANGUAGES is empty."
  PAPERLESS_OCR_LANGUAGE=$(join_by + "${OCR_LANG_LIST[@]}")

  if [[ -z $TIME_ZONE ]]; then
    TIME_ZONE=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
    if [[ -z $TIME_ZONE ]]; then
      TIME_ZONE=$(readlink -f /etc/localtime 2>/dev/null || true)
      TIME_ZONE=${TIME_ZONE#/usr/share/zoneinfo/}
    fi
  fi
  if [[ -z $TIME_ZONE || ! -f /usr/share/zoneinfo/$TIME_ZONE ]]; then TIME_ZONE=UTC; fi

  compute_web_hosts

  # Ports: skip the check for ports our own (running) web servers already hold.
  if [[ $ENABLE_HTTP == yes ]] && ! systemctl is-active --quiet paperless-webserver.service 2>/dev/null; then
    check_port "$HTTP_PORT"
  fi
  if [[ $ENABLE_HTTPS == yes ]] && ! systemctl is-active --quiet paperless-webserver-https.service 2>/dev/null; then
    check_port "$HTTPS_PORT"
  fi

  local mem_mb disk_mb parent
  mem_mb=$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 1024 ))
  if (( mem_mb < 2000 )); then
    warn "Only ${mem_mb} MB of RAM. Paperless-ngx wants at least 2 GB (4 GB or more with AI features)."
  fi
  parent=$(dirname "$INSTALL_DIR")
  mkdir -p "$parent"
  disk_mb=$(df -Pm "$parent" | awk 'NR == 2 {print $4}')
  if (( disk_mb < 6000 )); then
    warn "Only ${disk_mb} MB free under $parent. The software alone needs about 4 GB."
  fi
}

# Names and IPs the web UI will answer to (Django ALLOWED_HOSTS, CSRF, certificate).
compute_web_hosts() {
  local ip h short
  local -a ips=() extra=()
  read -r -a ips <<< "$(hostname -I 2>/dev/null || true)"

  if [[ -z $PAPERLESS_DOMAIN ]]; then
    PAPERLESS_DOMAIN=$(hostname -f 2>/dev/null || hostname)
  fi
  if [[ -z $PAPERLESS_DOMAIN || $PAPERLESS_DOMAIN == localhost* ]]; then
    for ip in "${ips[@]}"; do
      if is_ipv4 "$ip"; then PAPERLESS_DOMAIN=$ip; break; fi
    done
  fi
  [[ -n $PAPERLESS_DOMAIN ]] || die "Could not work out a hostname or IP address. Set PAPERLESS_DOMAIN."

  WEB_HOSTS=("$PAPERLESS_DOMAIN")
  short=$(hostname -s 2>/dev/null || true)
  if [[ -n $short ]]; then WEB_HOSTS+=("$short"); fi
  for ip in "${ips[@]}"; do
    if is_ipv4 "$ip"; then WEB_HOSTS+=("$ip"); fi
  done
  read -r -a extra <<< "${EXTRA_HOSTS//,/ }"
  for h in "${extra[@]}"; do WEB_HOSTS+=("$h"); done
  WEB_HOSTS+=(localhost 127.0.0.1)
  mapfile -t WEB_HOSTS < <(printf '%s\n' "${WEB_HOSTS[@]}" | awk 'NF && !seen[$0]++')
}

install_packages() {
  log "Installing system packages (this can take a few minutes)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update

  local lang pkg tess=() pkgs=()
  for lang in "${OCR_LANG_LIST[@]}"; do
    pkg="tesseract-ocr-${lang,,}"
    pkg=${pkg//_/-}
    apt-cache show "$pkg" >/dev/null 2>&1 \
      || die "No package '$pkg' for OCR language '$lang'. See the list with: apt-cache search tesseract-ocr-"
    tess+=("$pkg")
  done

  pkgs=(
    ca-certificates curl xz-utils openssl gnupg tzdata
    python3 python3-venv python3-dev build-essential pkg-config
    libpq-dev default-libmysqlclient-dev
    redis-server
    imagemagick ghostscript fonts-liberation gettext icc-profiles-free
    poppler-utils unpaper qpdf pngquant jbig2dec
    libxml2 libxslt1.1 zlib1g file libmagic1 libmagic-dev media-types
    tesseract-ocr tesseract-ocr-osd "${tess[@]}"
  )
  if [[ $DB_ENGINE == postgresql && ($DB_HOST == localhost || $DB_HOST == 127.0.0.1) ]]; then
    pkgs+=(postgresql postgresql-client)
  fi

  apt-get install -y --no-install-recommends "${pkgs[@]}"
}

resolve_version() {
  if [[ $PAPERLESS_VERSION == latest ]]; then
    local url
    url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$REPO_URL/releases/latest" || true)
    PAPERLESS_VERSION=${url##*/}
  fi
  if [[ $PAPERLESS_VERSION != v* ]]; then PAPERLESS_VERSION="v$PAPERLESS_VERSION"; fi
  [[ $PAPERLESS_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] \
    || die "Could not determine the Paperless-ngx version to install (got '$PAPERLESS_VERSION'). Is GitHub reachable?"
  if [[ $PAPERLESS_VERSION != v3.* ]]; then
    warn "This script was written for Paperless-ngx 3.x; $PAPERLESS_VERSION may need adjustments."
  fi
}

create_user_and_dirs() {
  log "Creating the '$PAPERLESS_USER' system user and directories"
  if ! id "$PAPERLESS_USER" >/dev/null 2>&1; then
    useradd --system --user-group --home-dir "$INSTALL_DIR" --no-create-home \
            --shell /usr/sbin/nologin "$PAPERLESS_USER"
  fi
  make_dir 755  "$INSTALL_DIR"
  make_dir 750  "$DATA_DIR" "$MEDIA_DIR" "$EXPORT_DIR" "$LOG_DIR"
  make_dir 2770 "$CONSUME_DIR"
  make_dir 700  "$TMP_DIR" "$INSTALL_DIR/.cache"
}

setup_redis() {
  log "Enabling Redis"
  systemctl enable --now --quiet redis-server
}

stop_services() {
  systemctl stop paperless.target "${ALL_SERVICES[@]/%/.service}" >/dev/null 2>&1 || true
}

install_release() {
  if [[ $INSTALLED_VERSION == "$PAPERLESS_VERSION" && $REINSTALL != yes \
        && -f $INSTALL_DIR/src/manage.py && -x $VENV/bin/python3 ]]; then
    log "Paperless-ngx $PAPERLESS_VERSION is already installed (REINSTALL=yes forces a reinstall)"
    return 0
  fi

  if [[ -n $INSTALLED_VERSION && $INSTALLED_VERSION != "$PAPERLESS_VERSION" ]]; then
    local newest
    newest=$(printf '%s\n' "${INSTALLED_VERSION#v}" "${PAPERLESS_VERSION#v}" | sort -V | tail -n 1)
    if [[ $newest == "${INSTALLED_VERSION#v}" ]]; then
      die "Installed $INSTALLED_VERSION is newer than $PAPERLESS_VERSION; downgrades are not supported."
    fi
    log "Upgrading Paperless-ngx $INSTALLED_VERSION -> $PAPERLESS_VERSION"
    info "Release notes: $REPO_URL/releases"
  else
    log "Downloading Paperless-ngx $PAPERLESS_VERSION"
  fi

  ensure_workdir
  local tarball="$WORK_DIR/paperless-ngx.tar.xz" src_dir item name
  curl -fL --retry 3 --progress-bar -o "$tarball" \
    "$REPO_URL/releases/download/$PAPERLESS_VERSION/paperless-ngx-$PAPERLESS_VERSION.tar.xz"
  mkdir "$WORK_DIR/extract"
  tar -xJf "$tarball" -C "$WORK_DIR/extract"
  src_dir=$(find "$WORK_DIR/extract" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  [[ -n $src_dir && -f $src_dir/src/manage.py && -f $src_dir/requirements.txt ]] \
    || die "The release archive does not have the expected layout."

  stop_services
  shopt -s dotglob nullglob
  for item in "$src_dir"/*; do
    name=${item##*/}
    case $name in
      data|media|consume|export|tmp|.venv|.uv|.cache|.local|.gnupg|.installed-version)
        continue ;;   # never touch documents, data or the virtualenv
      paperless.conf)
        cp -f "$item" "$INSTALL_DIR/paperless.conf.example"
        chown "$PAPERLESS_USER:$PAPERLESS_USER" "$INSTALL_DIR/paperless.conf.example" ;;
      *)
        rm -rf "${INSTALL_DIR:?}/$name"
        cp -a "$item" "$INSTALL_DIR/$name"
        chown -R "$PAPERLESS_USER:$PAPERLESS_USER" "$INSTALL_DIR/$name" ;;
    esac
  done
  shopt -u dotglob nullglob
  CODE_UPDATED=yes
}

# Refuse to silently point Paperless at an empty folder when a data path changes.
check_path_change() {  # check_path_change CONFIG_KEY NEW_PATH
  local old
  old=$(conf_get "$1")
  if [[ -n $old && $old != "$2" ]] && dir_has_files "$old" && ! dir_has_files "$2"; then
    die "$1 changed from $old to $2, but your files are still in $old.
       Stop Paperless (systemctl stop paperless.target), move the contents of $old to $2,
       then re-run this script. Or change the setting back."
  fi
}

write_config() {
  if [[ -f $CONFIG_FILE ]]; then
    log "Updating $CONFIG_FILE"
    check_path_change PAPERLESS_DATA_DIR "$DATA_DIR"
    check_path_change PAPERLESS_MEDIA_ROOT "$MEDIA_DIR"
  else
    log "Writing $CONFIG_FILE"
    local db_block secret_key today
    secret_key=$(openssl rand -hex 32)
    today=$(date '+%Y-%m-%d')
    if [[ $DB_ENGINE == postgresql ]]; then
      db_block="PAPERLESS_DBENGINE=postgresql
PAPERLESS_DBHOST=$DB_HOST
PAPERLESS_DBPORT=$DB_PORT
PAPERLESS_DBNAME=$DB_NAME
PAPERLESS_DBUSER=$DB_USER
PAPERLESS_DBPASS=${DB_PASS:-$(openssl rand -hex 24)}"
    else
      db_block="PAPERLESS_DBENGINE=sqlite"
    fi

    cat > "$CONFIG_FILE" <<EOF
# Paperless-ngx configuration
# Generated by install-paperless-ngx.sh on $today.
# All settings: https://docs.paperless-ngx.com/configuration/
# Apply changes with:  systemctl restart paperless.target

# --- Services ---
PAPERLESS_REDIS=redis://localhost:6379
$db_block

# --- Security ---
PAPERLESS_SECRET_KEY=$secret_key

# --- Managed by install-paperless-ngx.sh -------------------------------------
# The settings below are rewritten from the script's SETTINGS block every time
# it runs. Change them there and re-run the script, not here.
PAPERLESS_CONSUMPTION_DIR=
PAPERLESS_DATA_DIR=
PAPERLESS_MEDIA_ROOT=
PAPERLESS_LOGGING_DIR=
PAPERLESS_STATICDIR=
PAPERLESS_SCRATCH_DIR=
PAPERLESS_CONVERT_TMPDIR=
PAPERLESS_URL=
PAPERLESS_ALLOWED_HOSTS=
PAPERLESS_CSRF_TRUSTED_ORIGINS=
PAPERLESS_OCR_LANGUAGE=
PAPERLESS_TIME_ZONE=
# ------------------------------------------------------------------------------

# --- Your own settings (kept across re-runs) ---
#PAPERLESS_CONSUMER_POLLING_INTERVAL=10
#PAPERLESS_TASK_WORKERS=1

# --- Built-in AI features (Paperless-ngx 3.x). Read the docs before enabling.
#PAPERLESS_AI_ENABLED=true
#PAPERLESS_AI_LLM_BACKEND=ollama
#PAPERLESS_AI_LLM_ENDPOINT=http://localhost:11434
#PAPERLESS_AI_LLM_MODEL=llama3.1
EOF
  fi
  chown "root:$PAPERLESS_USER" "$CONFIG_FILE"
  chmod 640 "$CONFIG_FILE"

  local url origins=() h
  if [[ $ENABLE_HTTPS == yes ]]; then
    url=$(origin https "$PAPERLESS_DOMAIN" "$HTTPS_PORT")
  else
    url=$(origin http "$PAPERLESS_DOMAIN" "$HTTP_PORT")
  fi
  for h in "${WEB_HOSTS[@]}"; do
    if [[ $ENABLE_HTTPS == yes ]]; then origins+=("$(origin https "$h" "$HTTPS_PORT")"); fi
    if [[ $ENABLE_HTTP == yes ]]; then origins+=("$(origin http "$h" "$HTTP_PORT")"); fi
  done

  set_conf PAPERLESS_CONSUMPTION_DIR "$CONSUME_DIR"
  set_conf PAPERLESS_DATA_DIR "$DATA_DIR"
  set_conf PAPERLESS_MEDIA_ROOT "$MEDIA_DIR"
  set_conf PAPERLESS_LOGGING_DIR "$LOG_DIR"
  set_conf PAPERLESS_STATICDIR "$STATIC_DIR"
  set_conf PAPERLESS_SCRATCH_DIR "$TMP_DIR"
  set_conf PAPERLESS_CONVERT_TMPDIR "$TMP_DIR"
  set_conf PAPERLESS_URL "$url"
  set_conf PAPERLESS_ALLOWED_HOSTS "$(join_by , "${WEB_HOSTS[@]}")"
  set_conf PAPERLESS_CSRF_TRUSTED_ORIGINS "$(join_by , "${origins[@]}")"
  set_conf PAPERLESS_OCR_LANGUAGE "$PAPERLESS_OCR_LANGUAGE"
  set_conf PAPERLESS_TIME_ZONE "$TIME_ZONE"
}

pg_query() {
  (cd / && runuser -u postgres -- psql -X -q -t -A -v ON_ERROR_STOP=1 -c "$1")
}

setup_database() {
  if [[ $DB_ENGINE != postgresql ]]; then
    log "Using the $DB_ENGINE database configured in $CONFIG_FILE"
    return 0
  fi
  local db_host db_name db_user db_pass role_exists db_exists
  db_host=$(conf_get PAPERLESS_DBHOST)
  if [[ -n $db_host && $db_host != localhost && $db_host != 127.0.0.1 ]]; then
    log "Using the external PostgreSQL server at $db_host (create the database there yourself)"
    return 0
  fi

  log "Setting up PostgreSQL"
  systemctl enable --now --quiet postgresql
  db_name=$(conf_get PAPERLESS_DBNAME)
  db_user=$(conf_get PAPERLESS_DBUSER)
  db_pass=$(conf_get PAPERLESS_DBPASS)
  db_name=${db_name:-paperless}
  db_user=${db_user:-paperless}
  [[ -n $db_pass ]] || die "PAPERLESS_DBPASS is missing from $CONFIG_FILE."
  db_pass=${db_pass//\'/\'\'}

  role_exists=$(pg_query "SELECT 1 FROM pg_roles WHERE rolname = '$db_user'")
  if [[ $role_exists == 1 ]]; then
    pg_query "ALTER ROLE \"$db_user\" WITH LOGIN PASSWORD '$db_pass'" >/dev/null
  else
    pg_query "CREATE ROLE \"$db_user\" WITH LOGIN PASSWORD '$db_pass'" >/dev/null
  fi
  db_exists=$(pg_query "SELECT 1 FROM pg_database WHERE datname = '$db_name'")
  if [[ $db_exists != 1 ]]; then
    (cd / && runuser -u postgres -- createdb --owner="$db_user" --encoding=UTF8 --template=template0 "$db_name") \
      || (cd / && runuser -u postgres -- createdb --owner="$db_user" --encoding=UTF8 --template=template0 \
                                                   --locale=C.UTF-8 "$db_name")
  fi
}

install_python_deps() {
  local want have
  if [[ $PYTHON_VERSION == system ]]; then
    want=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
  else
    want=$(cut -d. -f1-2 <<< "$PYTHON_VERSION")
  fi
  have=$("$VENV/bin/python3" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)
  if [[ $CODE_UPDATED == no && $have == "$want" ]]; then
    return 0
  fi

  log "Installing Python packages (PyTorch is large, expect several minutes)"
  if [[ ! -x $UV_HOME/bin/uv ]]; then
    as_paperless python3 -m venv "$UV_HOME"
  fi
  as_paperless "$UV_HOME/bin/pip" install --quiet --disable-pip-version-check --upgrade uv
  local uv="$UV_HOME/bin/uv"

  if [[ $have != "$want" ]]; then
    rm -rf "$VENV"
    if [[ $PYTHON_VERSION == system ]]; then
      as_paperless "$uv" venv --quiet --python /usr/bin/python3 "$VENV"
    else
      as_paperless "$uv" venv --quiet --python "$PYTHON_VERSION" --python-preference only-managed "$VENV"
    fi
  fi

  # Same index setup as the official Docker image: PyPI plus the CPU-only PyTorch index.
  as_paperless UV_CACHE_DIR="$INSTALL_DIR/.cache/uv" "$uv" pip sync \
    --python "$VENV/bin/python3" \
    --extra-index-url "$TORCH_INDEX" \
    --index-strategy unsafe-best-match \
    "$INSTALL_DIR/requirements.txt"
  rm -rf "$INSTALL_DIR/.cache/uv"
}

configure_imagemagick() {
  local policy_dir="" d src
  for d in /etc/ImageMagick-7 /etc/ImageMagick-6; do
    if [[ -f $d/policy.xml ]]; then policy_dir=$d; break; fi
  done
  if [[ -z $policy_dir ]]; then
    warn "No ImageMagick policy.xml found; skipping (thumbnails fall back to Ghostscript)."
    return 0
  fi
  src=$(find "$INSTALL_DIR/docker" -name paperless-policy.xml -print -quit 2>/dev/null || true)
  if [[ -z $src ]]; then
    warn "paperless-policy.xml not found in the release; leaving the ImageMagick policy unchanged."
    return 0
  fi

  log "Allowing ImageMagick to read PDFs ($policy_dir/policy.xml)"
  if [[ ! -f $policy_dir/policy.xml.orig ]]; then
    cp -a "$policy_dir/policy.xml" "$policy_dir/policy.xml.orig"
  fi
  install -m 644 "$src" "$policy_dir/policy.xml"

  if ! command -v convert >/dev/null 2>&1 && command -v magick >/dev/null 2>&1; then
    set_conf PAPERLESS_CONVERT_BINARY "$(command -v magick)"
  fi
}

install_jbig2enc() {
  if [[ $INSTALL_JBIG2ENC != yes ]] || command -v jbig2 >/dev/null 2>&1; then
    return 0
  fi
  log "Installing jbig2enc $JBIG2ENC_VERSION (better PDF compression)"
  ensure_workdir
  local deb="$WORK_DIR/jbig2enc_${JBIG2ENC_VERSION}-1_${ARCH}.deb"
  local url="https://github.com/paperless-ngx/builder/releases/download/jbig2enc-trixie-v${JBIG2ENC_VERSION}/jbig2enc_${JBIG2ENC_VERSION}-1_${ARCH}.deb"
  if curl -fsSL --retry 3 -o "$deb" "$url" && apt-get install -y --no-install-recommends "$deb"; then
    info "jbig2enc installed"
  else
    warn "Could not install jbig2enc. Continuing without it (PDFs are just a little larger)."
  fi
}

setup_certificate() {
  if [[ $ENABLE_HTTPS != yes ]]; then return 0; fi
  install -d -m 755 "$SSL_DIR"

  if [[ -n $SSL_CERT_FILE ]]; then
    log "Installing your certificate into $SSL_DIR"
    install -m 644 "$SSL_CERT_FILE" "$SSL_DIR/paperless.crt"
    # Granian only accepts PKCS#8 keys, so convert whatever format was given.
    openssl pkey -in "$SSL_KEY_FILE" -out "$SSL_DIR/paperless.key"
    chmod 600 "$SSL_DIR/paperless.key"
    rm -f "$SSL_DIR/san.txt"
    CERT_KIND=custom
    return 0
  fi

  CERT_KIND=selfsigned
  local san=() h san_str
  for h in "${WEB_HOSTS[@]}"; do
    if is_ipv4 "$h"; then san+=("IP:$h"); else san+=("DNS:$h"); fi
  done
  san_str=$(join_by , "${san[@]}")
  if [[ -f $SSL_DIR/paperless.crt && -f $SSL_DIR/paperless.key && -f $SSL_DIR/san.txt ]] \
     && [[ "$(<"$SSL_DIR/san.txt")" == "$san_str" ]]; then
    info "Keeping the existing self-signed certificate in $SSL_DIR"
    return 0
  fi
  log "Creating a self-signed certificate ($SELF_SIGNED_DAYS days) for: ${WEB_HOSTS[*]}"
  openssl req -x509 -newkey rsa:3072 -sha256 -days "$SELF_SIGNED_DAYS" -nodes \
    -keyout "$SSL_DIR/paperless.key" -out "$SSL_DIR/paperless.crt" \
    -subj "/CN=$PAPERLESS_DOMAIN" -addext "subjectAltName=$san_str" 2>/dev/null
  chmod 600 "$SSL_DIR/paperless.key"
  printf '%s\n' "$san_str" > "$SSL_DIR/san.txt"
}

install_helper() {
  cat > /usr/local/bin/paperless-manage <<EOF
#!/bin/sh
# Run Paperless-ngx management commands as the '$PAPERLESS_USER' user, e.g.:
#   paperless-manage createsuperuser
#   paperless-manage document_exporter $EXPORT_DIR
set -e
if [ "\$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo paperless-manage \$*" >&2
  exit 1
fi
cd "$INSTALL_DIR/src"
exec runuser -u "$PAPERLESS_USER" -- env HOME="$INSTALL_DIR" TMPDIR="$TMP_DIR" \\
  PAPERLESS_CONFIGURATION_PATH="$CONFIG_FILE" "$VENV/bin/python3" manage.py "\$@"
EOF
  chmod 755 /usr/local/bin/paperless-manage
}

run_migrations() {
  log "Applying database migrations"
  manage migrate --no-input
}

write_unit() {  # write_unit NAME DESCRIPTION EXECSTART [EXTRA_SERVICE_LINES]
  local after="network-online.target redis-server.service" wants="Wants=network-online.target"
  if [[ $DB_ENGINE == postgresql ]]; then
    after+=" postgresql.service"
    wants+=" postgresql.service"
  fi
  cat > "/etc/systemd/system/$1.service" <<EOF
[Unit]
Description=$2
After=$after
Requires=redis-server.service
$wants
PartOf=paperless.target

[Service]
Type=simple
User=$PAPERLESS_USER
Group=$PAPERLESS_USER
WorkingDirectory=$INSTALL_DIR/src
Environment=PAPERLESS_CONFIGURATION_PATH=$CONFIG_FILE
Environment=HOME=$INSTALL_DIR
Environment=TMPDIR=$TMP_DIR
Environment=PATH=$VENV/bin:/usr/local/bin:/usr/bin:/bin
${4:-}
ExecStart=$3
Restart=on-failure
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=paperless.target
EOF
  SERVICES+=("$1")
}

# Extra [Service] lines for a Granian web server on PORT.
web_env() {  # web_env PORT
  printf 'Environment=GRANIAN_HOST=%s\nEnvironment=GRANIAN_PORT=%s\nEnvironment=GRANIAN_WORKERS=%s' \
    "$BIND_ADDRESS" "$1" "$WEB_WORKERS"
  if (( $1 < 1024 )); then
    # Lets the unprivileged paperless user bind ports below 1024 (80, 443).
    printf '\nAmbientCapabilities=CAP_NET_BIND_SERVICE\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE'
  fi
}

remove_unit() {
  systemctl disable --now --quiet "$1.service" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$1.service"
}

write_systemd_units() {
  log "Creating systemd services"
  local granian="$VENV/bin/granian --interface asginl --ws --loop uvloop"
  SERVICES=()

  if [[ $ENABLE_HTTP == yes ]]; then
    write_unit paperless-webserver "Paperless-ngx web server (HTTP, port $HTTP_PORT)" \
      "$granian paperless.asgi:application" "$(web_env "$HTTP_PORT")"
  else
    remove_unit paperless-webserver
  fi

  if [[ $ENABLE_HTTPS == yes ]]; then
    # systemd hands the certificate to the service at %d (its credentials folder),
    # so the private key itself can stay readable by root only.
    write_unit paperless-webserver-https "Paperless-ngx web server (HTTPS, port $HTTPS_PORT)" \
      "$granian --ssl-certificate %d/paperless.crt --ssl-keyfile %d/paperless.key paperless.asgi:application" \
      "$(web_env "$HTTPS_PORT")
LoadCredential=paperless.crt:$SSL_DIR/paperless.crt
LoadCredential=paperless.key:$SSL_DIR/paperless.key"
  else
    remove_unit paperless-webserver-https
  fi

  write_unit paperless-consumer "Paperless-ngx consumer (watches $CONSUME_DIR)" \
    "$VENV/bin/python3 manage.py document_consumer"
  write_unit paperless-task-queue "Paperless-ngx task queue (Celery worker)" \
    "$VENV/bin/celery --app paperless worker --loglevel INFO"
  write_unit paperless-scheduler "Paperless-ngx scheduler (Celery beat)" \
    "$VENV/bin/celery --app paperless beat --loglevel INFO"

  cat > /etc/systemd/system/paperless.target <<EOF
[Unit]
Description=Paperless-ngx (all services)
Wants=${SERVICES[*]/%/.service}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

wait_for_url() {  # wait_for_url URL NAME
  local i
  for ((i = 0; i < 90; i++)); do
    if curl -ks -o /dev/null --max-time 5 "$1"; then
      info "$2 is up: $1"
      return 0
    fi
    sleep 2
  done
  return 1
}

start_services() {
  log "Starting Paperless-ngx"
  systemctl enable --quiet paperless.target
  systemctl restart paperless.target
  info "Waiting for the web server (the first start can take a minute)..."
  if [[ $ENABLE_HTTP == yes ]] && ! wait_for_url "http://127.0.0.1:$HTTP_PORT/" "HTTP"; then
    journalctl -u paperless-webserver --no-pager -n 40 >&2 || true
    die "The HTTP web server did not come up. Check: journalctl -u paperless-webserver -e"
  fi
  if [[ $ENABLE_HTTPS == yes ]] && ! wait_for_url "https://127.0.0.1:$HTTPS_PORT/" "HTTPS"; then
    journalctl -u paperless-webserver-https --no-pager -n 40 >&2 || true
    die "The HTTPS web server did not come up. Check: journalctl -u paperless-webserver-https -e"
  fi
}

create_admin() {
  local has_admin
  has_admin=$(manage shell -c "from django.contrib.auth.models import User; print(User.objects.filter(is_superuser=True).exists())" 2>/dev/null | tail -n 1 || true)
  if [[ $has_admin == True ]]; then
    return 0
  fi

  if [[ -n $ADMIN_USER && -n $ADMIN_PASSWORD ]]; then
    log "Creating admin account '$ADMIN_USER'"
    (export DJANGO_SUPERUSER_PASSWORD="$ADMIN_PASSWORD"
     manage createsuperuser --no-input --username "$ADMIN_USER" --email "$ADMIN_EMAIL")
  elif [[ -t 0 && -t 1 ]]; then
    log "Create your Paperless-ngx admin account"
    manage createsuperuser || { warn "No admin created. Run later: paperless-manage createsuperuser"; NEED_ADMIN=yes; }
  else
    NEED_ADMIN=yes
  fi
}

summary() {
  local h urls=() local_url cert_note="" admin_note=""
  printf '%s\n' "$PAPERLESS_VERSION" > "$VERSION_FILE"

  for h in "${WEB_HOSTS[@]}"; do
    case $h in localhost|127.0.0.1) continue ;; esac
    if [[ $ENABLE_HTTPS == yes ]]; then urls+=("$(origin https "$h" "$HTTPS_PORT")"); fi
    if [[ $ENABLE_HTTP == yes ]]; then urls+=("$(origin http "$h" "$HTTP_PORT")"); fi
  done
  if [[ $ENABLE_HTTP == yes ]]; then
    local_url=$(origin http localhost "$HTTP_PORT")
  else
    local_url="$(origin https localhost "$HTTPS_PORT")  (self-signed: Paperless-AI must be told to trust it)"
  fi
  case $CERT_KIND in
    selfsigned) cert_note="
 HTTPS uses a self-signed certificate ($SSL_DIR/paperless.crt). Browsers warn
 about it once; that is expected. To use your own certificate, set
 SSL_CERT_FILE and SSL_KEY_FILE and re-run the script.
" ;;
    custom) cert_note="
 HTTPS uses your certificate (copied to $SSL_DIR). After renewing it, re-run
 the script (or copy the new files there) and: systemctl restart paperless.target
" ;;
  esac
  if [[ $NEED_ADMIN == yes ]]; then
    admin_note="
 No admin account yet: open the web UI to create one, or run
   paperless-manage createsuperuser
"
  fi

  cat <<EOF

=============================================================================
 Paperless-ngx $PAPERLESS_VERSION is installed and running
=============================================================================
 Open in your browser:
$(printf '   %s\n' "${urls[@]}")
$cert_note$admin_note
 Folders
   Program + config ... $INSTALL_DIR   (settings: $CONFIG_FILE)
   Drop files here .... $CONSUME_DIR   (add users to group '$PAPERLESS_USER' to write)
   Documents .......... $MEDIA_DIR
   Data / index ....... $DATA_DIR
   Logs ............... $LOG_DIR
   Backups (export) ... $EXPORT_DIR

 Commands
   systemctl status paperless.target          all services
   systemctl restart paperless.target         after editing paperless.conf
   journalctl -u paperless-webserver -f       live log (also -webserver-https, -consumer, -task-queue, -scheduler)
   paperless-manage document_exporter $EXPORT_DIR    full backup
   bash $0                                    upgrade to the newest release later

 Paperless-AI on this machine: use $local_url as the Paperless URL.
 If a firewall (ufw/nftables) is active, open the web port(s).
=============================================================================
EOF
}

main() {
  preflight
  install_packages
  resolve_version
  create_user_and_dirs
  setup_redis
  install_release
  write_config
  setup_database
  install_python_deps
  configure_imagemagick
  install_jbig2enc
  setup_certificate
  install_helper
  run_migrations
  write_systemd_units
  start_services
  create_admin
  summary
}

main "$@"
