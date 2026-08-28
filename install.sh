#!/bin/sh
# FaPost Core installer.
#
#     sh -c "$(curl -fsSL https://get.fapost.in/install.sh)"
#
# Asks what it cannot work out, generates what should never be typed by hand,
# and leaves a running stack behind. Everything it asks can also be given as a
# flag, so the same script installs unattended:
#
#     sh install.sh --yes --domain fapost.example.com --admin-email ops@example.com
#
# It writes only inside the installation directory it creates, and touches
# nothing else on the host: no packages, no services, no files under /etc.
#
# POSIX sh on purpose. `sh -c "$(curl …)"` runs under /bin/sh, which is dash on
# Debian and Ubuntu, and a bashism here would fail on the systems this is most
# likely to run on.
set -eu

VERSION="1.0.0"

# Where the compose file and the environment template are fetched from. The
# compose file lives in the application repository rather than this one on
# purpose: it describes the topology, and a copy here would drift from the
# images it is supposed to start.
RAW_BASE="${FAPOST_RAW_BASE:-https://raw.githubusercontent.com/fapost-lab/core}"
REF="main"

INSTALL_DIR="fapost"
DOMAIN=""
TENANT_SLUG="app"
ADMIN_EMAIL=""
ADMIN_PASSWORD=""
ADMIN_PASSWORD_FILE=""
ADMIN_PASSWORD_GENERATED="no"
APP_VERSION="latest"
USE_TLS=""
USE_GATEWAY="no"
HTTP_PORT="8000"
ASSUME_YES="no"

# ─── Output ──────────────────────────────────────────────────────────────────

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m')
    RED=$(printf '\033[31m'); GREEN=$(printf '\033[32m')
    YELLOW=$(printf '\033[33m'); RESET=$(printf '\033[0m')
else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi

info()    { printf '%s\n' "$*"; }
step()    { printf '\n%s==>%s %s%s%s\n' "$GREEN" "$RESET" "$BOLD" "$*" "$RESET"; }
detail()  { printf '    %s%s%s\n' "$DIM" "$*" "$RESET"; }
warn()    { printf '%swarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()     { printf '\n%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
FaPost Core installer.

Usage:
  install.sh [options]

Options:
  --domain DOMAIN          Base domain of the installation, e.g. fapost.example.com.
                           The panel is served from TENANT_SLUG prefixed to it.
  --admin-email EMAIL      Email address of the first administrator.
  --tenant-slug SLUG       Slug of the first tenant. Default: app
  --install-dir PATH       Directory to install into. Default: ./fapost
  --app-version TAG        Image tag to run. Default: latest
  --http-port PORT         Port for plain HTTP. Default: 8000
  --tls / --no-tls         Terminate TLS with the bundled Caddy, or not.
  --gateway                Also run the optional Go webhook gateway.
  --ref REF                Branch or tag to fetch compose.yaml from. Default: main
  --admin-password-file F  Read the administrator's password from a file, or from
                           standard input when given as -. Also accepted in the
                           FAPOST_ADMIN_PASSWORD environment variable. Generated
                           when neither is given.
  -y, --yes                Do not ask anything; requires --domain and --admin-email.
  -h, --help               Show this message.
  --version                Show the installer version.
EOF
}

# ─── Argument parsing ────────────────────────────────────────────────────────

need_value() {
    [ -n "${2:-}" ] || die "$1 needs a value."
}

while [ $# -gt 0 ]; do
    case "$1" in
        --domain)              need_value "$1" "${2:-}"; DOMAIN=$2; shift 2 ;;
        --admin-email)         need_value "$1" "${2:-}"; ADMIN_EMAIL=$2; shift 2 ;;
        --tenant-slug)         need_value "$1" "${2:-}"; TENANT_SLUG=$2; shift 2 ;;
        --install-dir)         need_value "$1" "${2:-}"; INSTALL_DIR=$2; shift 2 ;;
        --app-version)         need_value "$1" "${2:-}"; APP_VERSION=$2; shift 2 ;;
        --http-port)           need_value "$1" "${2:-}"; HTTP_PORT=$2; shift 2 ;;
        --ref)                 need_value "$1" "${2:-}"; REF=$2; shift 2 ;;
        --admin-password-file) need_value "$1" "${2:-}"; ADMIN_PASSWORD_FILE=$2; shift 2 ;;
        --tls)                 USE_TLS="yes"; shift ;;
        --no-tls)              USE_TLS="no"; shift ;;
        --gateway)             USE_GATEWAY="yes"; shift ;;
        -y|--yes)              ASSUME_YES="yes"; shift ;;
        -h|--help)             usage; exit 0 ;;
        --version)             printf 'fapost-install %s\n' "$VERSION"; exit 0 ;;
        *)                     die "Unknown option: $1 (try --help)" ;;
    esac
done

if [ "$ASSUME_YES" = "yes" ]; then
    # Without a terminal there is nothing to fall back to, and a question with no
    # sensible default would otherwise loop forever asking an empty prompt.
    [ -n "$DOMAIN" ]      || die "--yes needs --domain."
    [ -n "$ADMIN_EMAIL" ] || die "--yes needs --admin-email."
    [ -n "$USE_TLS" ]     || USE_TLS="yes"
fi

# ─── Preflight ───────────────────────────────────────────────────────────────

step "Checking the host"

command -v docker >/dev/null 2>&1 \
    || die "Docker is not installed. See https://docs.docker.com/engine/install/"

docker info >/dev/null 2>&1 \
    || die "The Docker daemon is not reachable. Start it, or add your user to the docker group."

COMPOSE_VERSION=$(docker compose version --short 2>/dev/null) \
    || die "The Docker Compose plugin is missing. This needs \`docker compose\`, not \`docker-compose\`."

# The compose file carries its services' configuration inline, which Compose
# only understands from 2.23 onwards. Checked here rather than left to fail
# later, because the failure it produces otherwise points at the wrong thing.
compose_major=${COMPOSE_VERSION#v}
compose_minor=${compose_major#*.}
compose_major=${compose_major%%.*}
compose_minor=${compose_minor%%.*}

case "$compose_major$compose_minor" in
    *[!0-9]*) warn "Could not read the Compose version ($COMPOSE_VERSION); continuing." ;;
    *)
        if [ "$compose_major" -lt 2 ] || { [ "$compose_major" -eq 2 ] && [ "$compose_minor" -lt 23 ]; }; then
            die "Docker Compose v2.23 or newer is required; this host has $COMPOSE_VERSION."
        fi
        ;;
esac

command -v curl >/dev/null 2>&1 || die "curl is required to fetch the compose file."

detail "docker compose $COMPOSE_VERSION"

# Interactive prompts need a terminal to read from. `curl … | sh` hands the
# script itself to stdin, leaving nothing to answer with — so say what to run
# instead of reading EOF for every question and installing a set of defaults
# nobody chose.
if [ "$ASSUME_YES" = "no" ] && [ ! -t 0 ]; then
    die "No terminal to ask questions on.

Run it so the script keeps your terminal on stdin:
    sh -c \"\$(curl -fsSL https://get.fapost.in/install.sh)\"

Or pass everything and skip the questions:
    … --yes --domain example.com --admin-email you@example.com"
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────

ask() { # ask <question> <default>; answer on stdout
    _question=$1
    _default=$2

    if [ "$ASSUME_YES" = "yes" ]; then
        printf '%s' "$_default"
        return 0
    fi

    if [ -n "$_default" ]; then
        printf '%s [%s]: ' "$_question" "$_default" >&2
    else
        printf '%s: ' "$_question" >&2
    fi

    if ! IFS= read -r _answer; then
        _answer=""
    fi

    printf '%s' "${_answer:-$_default}"
}

confirm() { # confirm <question> <yes|no default>
    _default=$2

    # Spelled out rather than `[ "$_default" = yes ]; return $?`, which under
    # `set -e` exits the script on the false branch instead of returning it.
    if [ "$ASSUME_YES" = "yes" ]; then
        if [ "$_default" = "yes" ]; then return 0; else return 1; fi
    fi

    case "$(ask "$1 (y/n)" "$_default")" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

read_env() { # read_env <key>; value on stdout, empty when absent
    [ -f "$ENV_PATH" ] || return 0
    awk -v key="$1" 'index($0, key "=") == 1 { sub("^" key "=", ""); gsub(/^"|"$/, ""); print; exit }' "$ENV_PATH"
}

random_hex() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$1"
    else
        od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'
    fi
}

random_key() {
    if command -v openssl >/dev/null 2>&1; then
        printf 'base64:%s' "$(openssl rand -base64 32)"
    else
        printf 'base64:%s' "$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
    fi
}

# Rewrite one key in the environment file, appending it when the template does
# not carry it. awk rather than sed: a password or a base64 key contains
# characters sed would read as part of its replacement syntax.
#
# Note that this replaces the file rather than editing it in place, so the
# caller's umask decides the mode of every rewrite — see where it is tightened
# before the first call. A chmod here would be undone by the next one.
set_env() {
    awk -v key="$1" -v value="$2" '
        BEGIN { written = 0 }
        !written && index($0, key "=") == 1 { print key "=" value; written = 1; next }
        { print }
        END { if (!written) print key "=" value }
    ' "$ENV_PATH" > "$ENV_PATH.tmp" && mv "$ENV_PATH.tmp" "$ENV_PATH"
}

fetch() { # fetch <url> <destination>
    curl -fsSL "$1" -o "$2" || die "Could not download $1

If this is a 404, the repository or the ref does not exist — check --ref, or
whether the repository is public yet."
}

port_busy() {
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | grep -q ":$1[[:space:]]"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -an 2>/dev/null | grep -q "[.:]$1[[:space:]].*LISTEN"
    else
        return 1
    fi
}

# Run from inside the installation directory, exactly as the operator will
# afterwards: the compose file resolves its .env relative to where it sits, and
# driving it from elsewhere would work here while the documented commands did not.
compose() {
    (cd "$INSTALL_DIR" && docker compose "$@")
}

# ─── Questions ───────────────────────────────────────────────────────────────

step "Configuration"

INSTALL_DIR=$(ask "Install into which directory" "$INSTALL_DIR")
[ -n "$INSTALL_DIR" ] || die "An installation directory is required."

ENV_PATH="$INSTALL_DIR/.env"

REUSE_ENV="no"
if [ -f "$INSTALL_DIR/.env" ]; then
    if [ "$ASSUME_YES" = "yes" ]; then
        die "$INSTALL_DIR/.env already exists. Remove it, or point --install-dir elsewhere."
    fi

    warn "$INSTALL_DIR/.env already exists."
    if confirm "Keep it and just start the stack?" "yes"; then
        REUSE_ENV="yes"
    else
        die "Nothing changed. Move the directory aside and run this again."
    fi
fi

if [ "$REUSE_ENV" = "no" ]; then
    info ""
    info "The base domain carries the welcome page. The admin panel is served from"
    info "the tenant's own host — the tenant slug prefixed to that domain — so both"
    info "names must resolve to this machine."
    info ""

    while [ -z "$DOMAIN" ]; do
        DOMAIN=$(ask "Base domain (e.g. fapost.example.com)" "")
        [ -n "$DOMAIN" ] || warn "A domain is required."
    done

    TENANT_SLUG=$(ask "Tenant slug" "$TENANT_SLUG")

    while [ -z "$ADMIN_EMAIL" ]; do
        ADMIN_EMAIL=$(ask "Administrator email" "")
        [ -n "$ADMIN_EMAIL" ] || warn "An email address is required."
    done

    if [ -z "$USE_TLS" ]; then
        info ""
        info "Caddy can obtain and renew Let's Encrypt certificates for both names."
        info "Say no if a load balancer or another proxy already terminates TLS here."
        info ""
        if confirm "Terminate TLS with the bundled Caddy?" "yes"; then
            USE_TLS="yes"
        else
            USE_TLS="no"
        fi
    fi

    if [ "$USE_TLS" = "no" ]; then
        HTTP_PORT=$(ask "Port to serve plain HTTP on" "$HTTP_PORT")
    fi
fi

if [ "$REUSE_ENV" = "yes" ]; then
    # Whatever the existing file says wins — the point of keeping it is not to
    # have this script's defaults quietly contradict it.
    DOMAIN=$(read_env TENANCY_BASE_DOMAIN)
    TENANT_SLUG=$(read_env TENANT_SLUG)
    HTTP_PORT=$(read_env HTTP_PORT)

    [ -n "$DOMAIN" ] || die "$ENV_PATH has no TENANCY_BASE_DOMAIN. Set it, or move the file aside and start over."
    [ -n "$TENANT_SLUG" ] || TENANT_SLUG="app"
    [ -n "$HTTP_PORT" ] || HTTP_PORT="8000"

    case "$(read_env APP_URL)" in
        https://*) [ -n "$USE_TLS" ] || USE_TLS="yes" ;;
        *)         [ -n "$USE_TLS" ] || USE_TLS="no" ;;
    esac

    while [ -z "$ADMIN_EMAIL" ]; do
        ADMIN_EMAIL=$(ask "Administrator email" "")
        [ -n "$ADMIN_EMAIL" ] || warn "An email address is required."
    done

    detail "reusing $ENV_PATH — $DOMAIN, tenant $TENANT_SLUG"
fi

PANEL_HOST="$TENANT_SLUG.$DOMAIN"

# ─── The administrator's password ────────────────────────────────────────────

if [ -n "${FAPOST_ADMIN_PASSWORD:-}" ]; then
    ADMIN_PASSWORD=$FAPOST_ADMIN_PASSWORD
elif [ -n "$ADMIN_PASSWORD_FILE" ]; then
    if [ "$ADMIN_PASSWORD_FILE" = "-" ]; then
        IFS= read -r ADMIN_PASSWORD || die "No password on standard input."
    else
        [ -f "$ADMIN_PASSWORD_FILE" ] || die "No such file: $ADMIN_PASSWORD_FILE"
        IFS= read -r ADMIN_PASSWORD < "$ADMIN_PASSWORD_FILE" || true
    fi
    [ -n "$ADMIN_PASSWORD" ] || die "The password file is empty."
else
    ADMIN_PASSWORD=$(random_hex 12)
    ADMIN_PASSWORD_GENERATED="yes"
fi

# ─── Ports ───────────────────────────────────────────────────────────────────

if [ "$USE_TLS" = "yes" ]; then
    for port in 80 443; do
        if port_busy "$port"; then
            warn "Something is already listening on port $port. Caddy needs it for certificates and will fail to start."
        fi
    done
elif port_busy "$HTTP_PORT"; then
    warn "Something is already listening on port $HTTP_PORT."
fi

# ─── Summary and confirmation ────────────────────────────────────────────────

if [ "$REUSE_ENV" = "no" ]; then
    info ""
    info "  ${BOLD}Directory${RESET}      $INSTALL_DIR"
    info "  ${BOLD}Base domain${RESET}    $DOMAIN"
    info "  ${BOLD}Panel${RESET}          $PANEL_HOST"
    info "  ${BOLD}Administrator${RESET}  $ADMIN_EMAIL"
    if [ "$USE_TLS" = "yes" ]; then
        info "  ${BOLD}TLS${RESET}            Caddy, automatic certificates"
    else
        info "  ${BOLD}TLS${RESET}            none — plain HTTP on port $HTTP_PORT"
    fi
    info "  ${BOLD}Images${RESET}         ghcr.io/fapost-lab/*:$APP_VERSION"
    info ""

    if ! confirm "Install with these settings?" "yes"; then
        die "Nothing changed."
    fi
fi

# ─── Files ───────────────────────────────────────────────────────────────────

mkdir -p "$INSTALL_DIR"

step "Fetching the compose file"
fetch "$RAW_BASE/$REF/docker/compose.yaml" "$INSTALL_DIR/compose.yaml"
detail "$INSTALL_DIR/compose.yaml"

if [ "$REUSE_ENV" = "no" ]; then
    step "Writing the environment"

    # Everything below this point writes secrets. Tightening the umask rather
    # than chmod-ing afterwards covers the temporary files each rewrite creates,
    # which would otherwise hold the passwords world-readable for an instant.
    previous_umask=$(umask)
    umask 077

    # The template is fetched rather than embedded here so that every knob stays
    # documented in one place, next to the compose file that reads it. This
    # script only overrides the values it actually knows.
    fetch "$RAW_BASE/$REF/.env.production.example" "$ENV_PATH"

    set_env APP_KEY "$(random_key)"
    set_env APP_URL "https://$DOMAIN"
    set_env TENANCY_BASE_DOMAIN "$DOMAIN"
    set_env TENANT_SLUG "$TENANT_SLUG"
    set_env DB_PASSWORD "$(random_hex 24)"
    set_env REDIS_PASSWORD "$(random_hex 24)"
    set_env APP_VERSION "$APP_VERSION"
    set_env GATEWAY_VERSION "$APP_VERSION"
    set_env MAIL_FROM_ADDRESS "\"fapost@$DOMAIN\""

    # Required to render the compose file whether or not Caddy runs: Compose
    # interpolates everything before it knows which profiles are active.
    set_env APP_DOMAIN "$DOMAIN"
    set_env ACME_EMAIL "$ADMIN_EMAIL"

    if [ "$USE_TLS" = "yes" ]; then
        # With Caddy in front, the plain-HTTP port stays on the loopback or it is
        # a way around TLS and the certificate entirely.
        set_env HTTP_BIND "127.0.0.1"
        set_env GATEWAY_BIND "127.0.0.1"
    else
        set_env APP_URL "http://$DOMAIN:$HTTP_PORT"
        set_env HTTP_PORT "$HTTP_PORT"
    fi

    umask "$previous_umask"
    chmod 600 "$ENV_PATH"

    detail "$ENV_PATH (mode 600 — it holds the database and Redis passwords)"
fi

# ─── Start ───────────────────────────────────────────────────────────────────

PROFILES=""
[ "$USE_TLS" = "yes" ] && PROFILES="$PROFILES --profile tls"
[ "$USE_GATEWAY" = "yes" ] && PROFILES="$PROFILES --profile gateway"

step "Starting the stack"
detail "first run pulls several images; this takes a while"

# shellcheck disable=SC2086 # PROFILES is a list of flags, and must word-split.
compose $PROFILES up -d || die "Compose could not start the stack. The output above says why."

step "Waiting for the application"

attempt=0
until compose exec -T app php artisan --version >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 60 ]; then
        info ""
        compose logs app --tail 30 || true
        die "The application container did not become usable. Its last log lines are above."
    fi
    sleep 5
done

detail "ready"

# ─── Provision ───────────────────────────────────────────────────────────────

step "Creating the first tenant"

# The password goes in on standard input rather than as an argument, so it never
# appears in a process list on this host or inside the container.
if ! printf '%s' "$ADMIN_PASSWORD" | compose exec -T app \
    php artisan platform:install \
        --tenant-slug="$TENANT_SLUG" \
        --admin-email="$ADMIN_EMAIL" \
        --admin-password-file=-
then
    die "Tenant provisioning failed. The stack is running, so fix what it reported and re-run:

    cd $INSTALL_DIR && docker compose exec app php artisan platform:install \\
        --tenant-slug=$TENANT_SLUG --admin-email=$ADMIN_EMAIL"
fi

# ─── Done ────────────────────────────────────────────────────────────────────

if [ "$USE_TLS" = "yes" ]; then
    PANEL_URL="https://$PANEL_HOST/admin"
else
    PANEL_URL="http://$PANEL_HOST:$HTTP_PORT/admin"
fi

printf '\n%sFaPost Core is installed.%s\n\n' "$BOLD" "$RESET"
printf '  Panel     %s\n' "$PANEL_URL"
printf '  Email     %s\n' "$ADMIN_EMAIL"

if [ "$ADMIN_PASSWORD_GENERATED" = "yes" ]; then
    printf '  Password  %s%s%s\n' "$BOLD" "$ADMIN_PASSWORD" "$RESET"
    printf '\n  %sThis password is not stored anywhere. Record it now.%s\n' "$YELLOW" "$RESET"
fi

cat <<EOF

  Both ${DOMAIN} and ${PANEL_HOST} must resolve to this host —
  the panel answers on the second one only.
EOF

if [ "$USE_TLS" = "yes" ]; then
    cat <<EOF

  Caddy is requesting certificates now. Until DNS points here it will keep
  retrying, and the site is not reachable over HTTPS:

      cd $INSTALL_DIR && docker compose logs -f caddy
EOF
fi

cat <<EOF

  Everything is in $INSTALL_DIR — run compose commands from there:

      cd $INSTALL_DIR
      docker compose ps
      docker compose logs -f horizon

  Documentation: https://docs.fapost.in/self-hosting/docker-compose

EOF
