#!/bin/sh

set -eu

SCRIPT_NAME=${0##*/}
WIREPROXY_VERSION=${WIREPROXY_VERSION:-1.1.1}
WIREPROXY_ARCHIVE_URL=${WIREPROXY_ARCHIVE_URL:-https://github.com/pufferffish/wireproxy/releases/download/v${WIREPROXY_VERSION}/wireproxy_linux_amd64.tar.gz}
STATE_DIR=/etc/wireproxy-warp
CONFIG_FILE=$STATE_DIR/proxy.conf
ACCOUNT_FILE=$STATE_DIR/account.json
SERVICE_NAME=wireproxy-warp
SERVICE_FILE=/etc/init.d/$SERVICE_NAME
WIREPROXY_BIN=/usr/local/bin/wireproxy-warp
MANAGER_BIN=/usr/local/bin/warp
SCRIPT_URL=${WIREPROXY_SCRIPT_URL:-https://raw.githubusercontent.com/BlackCatCmx/alpine-wireproxy/main/wireproxy-warp.sh}
DEFAULT_PORT=41360

die() {
    printf '%s\n' "ERROR: $*" >&2
    exit 1
}

info() {
    printf '%s\n' "$*"
}

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME install [options]
  $SCRIPT_NAME menu
  $SCRIPT_NAME status
  $SCRIPT_NAME restart
  $SCRIPT_NAME switch 4|dual
  $SCRIPT_NAME uninstall

Install options:
  --stack 4|dual       WARP egress mode (default: dual)
  --ipv4-only          Same as --stack 4
  --dual-stack         Same as --stack dual
  --port PORT          SOCKS5 listen port (default: $DEFAULT_PORT)
  --username USER      Required SOCKS5 username
  --password PASSWORD  Required SOCKS5 password

The proxy listens on 0.0.0.0 by design. Username and password are mandatory.
Only amd64 Alpine Linux with OpenRC is supported by this installer.
EOF
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "run this script as root"
}

require_alpine_openrc() {
    [ -r /etc/alpine-release ] || die "this installer supports Alpine Linux only"
    [ "$(uname -m)" = x86_64 ] || die "this installer supports amd64 only"
    command -v rc-service >/dev/null 2>&1 || die "OpenRC rc-service was not found"
    command -v rc-update >/dev/null 2>&1 || die "OpenRC rc-update was not found"
}

validate_port() {
    case "$1" in
        ''|*[!0-9]*) die "invalid port: $1" ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || die "port must be between 1 and 65535"
}

validate_credential() {
    value=$1
    label=$2
    [ -n "$value" ] || die "$label must not be empty"
    if printf '%s' "$value" | grep -q '[[:space:]#=]'; then
        die "$label must not contain whitespace, #, or ="
    fi
}

install_dependencies() {
    packages=
    command -v curl >/dev/null 2>&1 || packages="$packages curl"
    command -v openssl >/dev/null 2>&1 || packages="$packages openssl"
    [ -r /etc/ssl/certs/ca-certificates.crt ] || packages="$packages ca-certificates"

    if [ -n "$packages" ]; then
        # BusyBox already provides tar, base64, install, awk, sed and mktemp.
        apk add --no-cache $packages || die "failed to install required Alpine packages"
    fi

    command -v curl >/dev/null 2>&1 || die "curl is unavailable after package installation"
    command -v openssl >/dev/null 2>&1 || die "openssl is unavailable after package installation"
    command -v tar >/dev/null 2>&1 || die "tar is unavailable"
    command -v base64 >/dev/null 2>&1 || die "base64 is unavailable"
    command -v mktemp >/dev/null 2>&1 || die "mktemp is unavailable"
}

port_is_listening() {
    # ss is optional; do not install a large network-tools package only for this check.
    command -v ss >/dev/null 2>&1 || return 0
    ss -ltnH 2>/dev/null | awk -v port=":$1" '$4 ~ port "$" {found=1} END {exit !found}'
}

load_proxy_settings() {
    PORT=$(sed -n 's/^BindAddress = 0.0.0.0:\([0-9]*\)$/\1/p' "$CONFIG_FILE" | head -n 1)
    USERNAME=$(sed -n 's/^Username = //p' "$CONFIG_FILE" | head -n 1)
    PASSWORD=$(sed -n 's/^Password = //p' "$CONFIG_FILE" | head -n 1)
    [ -n "$PORT" ] || die "WireProxy config has no SOCKS5 port"
    [ -n "$USERNAME" ] || die "WireProxy config has no SOCKS5 username"
    [ -n "$PASSWORD" ] || die "WireProxy config has no SOCKS5 password"
}

wait_for_warp() {
    attempt=1
    while [ "$attempt" -le 18 ]; do
        if curl $CURL_FAMILY -fsS --max-time 8 \
            --proxy "socks5://127.0.0.1:$PORT" \
            --proxy-user "$USERNAME:$PASSWORD" \
            https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null |
            grep -q '^warp=on$'; then
            return 0
        fi
        [ "$attempt" -eq 18 ] || sleep 2
        attempt=$((attempt + 1))
    done
    return 1
}

stop_service() {
    [ -x "$SERVICE_FILE" ] || return 0
    rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
    rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
}

generate_keypair() {
    key_file=$1
    openssl genpkey -algorithm X25519 -outform DER -out "$key_file" >/dev/null 2>&1 ||
        die "failed to generate a WireGuard private key"

    PRIVATE_KEY=$(openssl pkey -inform DER -in "$key_file" -outform DER 2>/dev/null |
        tail -c 32 | base64 | tr -d '\n')
    PUBLIC_KEY=$(openssl pkey -inform DER -in "$key_file" -pubout -outform DER 2>/dev/null |
        tail -c 32 | base64 | tr -d '\n')

    [ "${#PRIVATE_KEY}" -eq 44 ] || die "generated private key has an invalid length"
    [ "${#PUBLIC_KEY}" -eq 44 ] || die "generated public key has an invalid length"
}

random_alnum() {
    length=$1
    head -c 256 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$length"
}

register_warp_account() {
    account_file=$1
    install_id=$(random_alnum 22)
    fcm_token="$install_id:APA91b$(random_alnum 134)"
    tos=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')

    cat > "$TMP_DIR/register.json" <<EOF
{"key":"$PUBLIC_KEY","install_id":"$install_id","fcm_token":"$fcm_token","tos":"$tos","model":"PC","serial_number":"$install_id","locale":"en_US"}
EOF

    if ! curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 8 --max-time 30 \
        -A 'okhttp/3.12.1' \
        -H 'CF-Client-Version: a-6.10-2158' \
        -H 'Content-Type: application/json' \
        --data-binary @"$TMP_DIR/register.json" \
        -o "$account_file" \
        https://api.cloudflareclient.com/v0a2158/reg; then
        printf '%s\n' 'Cloudflare WARP registration failed.' >&2
        [ ! -s "$account_file" ] || sed -n '1,20p' "$account_file" >&2
        die "check outbound HTTPS and try again"
    fi

    grep -q '"account"' "$account_file" || {
        sed -n '1,40p' "$account_file" >&2
        die "Cloudflare returned an unexpected registration response"
    }
}

extract_account_values() {
    ADDRESS4=$(sed -n 's/.*"v4"[[:space:]]*:[[:space:]]*"\(172\.[^"]*\)".*/\1/p' "$ACCOUNT_FILE" | head -n 1)
    ADDRESS6=$(sed -n 's/.*"v6"[[:space:]]*:[[:space:]]*"\(2606:[^"]*\)".*/\1/p' "$ACCOUNT_FILE" | head -n 1)
    PEER_PUBLIC_KEY=$(sed -n 's/.*"public_key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ACCOUNT_FILE" | head -n 1)
    ENDPOINT4=$(sed -n 's/.*"endpoint"[[:space:]]*:[[:space:]]*{[^}]*"v4"[[:space:]]*:[[:space:]]*"\([0-9.]*\):[0-9]*".*/\1:2408/p' "$ACCOUNT_FILE" | head -n 1)

    [ -n "$ADDRESS4" ] || die "registration response has no WARP IPv4 address"
    [ -n "$PEER_PUBLIC_KEY" ] || die "registration response has no WARP peer key"
    [ -n "$ENDPOINT4" ] || die "registration response has no IPv4 endpoint"

    if [ "$STACK" = dual ] && [ -z "$ADDRESS6" ]; then
        die "dual-stack registration response has no WARP IPv6 address"
    fi
}

download_wireproxy() {
    archive=$TMP_DIR/wireproxy.tar.gz
    curl -fL --retry 2 --retry-delay 1 --connect-timeout 8 --max-time 60 \
        -o "$archive" "$WIREPROXY_ARCHIVE_URL" ||
        die "failed to download WireProxy $WIREPROXY_VERSION"

    mkdir "$TMP_DIR/extracted"
    tar -xzf "$archive" -C "$TMP_DIR/extracted" wireproxy ||
        die "WireProxy archive did not contain the expected wireproxy file"
    [ -x "$TMP_DIR/extracted/wireproxy" ] || die "downloaded WireProxy is not executable"
}

write_config() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    {
        printf '%s\n' '[Interface]'
        if [ "$STACK" = dual ]; then
            printf 'Address = %s/32, %s/128\n' "$ADDRESS4" "$ADDRESS6"
        else
            printf 'Address = %s/32\n' "$ADDRESS4"
        fi
        printf 'MTU = 1280\nPrivateKey = %s\n\n' "$PRIVATE_KEY"
        printf '%s\n' '[Peer]'
        printf 'PublicKey = %s\n' "$PEER_PUBLIC_KEY"
        if [ "$STACK" = dual ]; then
            printf '%s\n' 'AllowedIPs = 0.0.0.0/0, ::/0'
        else
            printf '%s\n' 'AllowedIPs = 0.0.0.0/0'
        fi
        printf 'Endpoint = %s\nPersistentKeepalive = 25\n\n' "$ENDPOINT4"
        printf '%s\n' '[Socks5]'
        printf 'BindAddress = 0.0.0.0:%s\n' "$PORT"
        printf 'Username = %s\nPassword = %s\n' "$USERNAME" "$PASSWORD"
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" "$ACCOUNT_FILE"
}

write_service() {
    cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run

description="WireProxy WARP SOCKS5 proxy"
command="$WIREPROXY_BIN"
command_args="-c $CONFIG_FILE"
command_background=true
pidfile="/run/$SERVICE_NAME.pid"

depend() {
    need net
}
EOF
    chmod 755 "$SERVICE_FILE"
}

install_wireproxy() {
    stop_service
    install -m 0755 "$TMP_DIR/extracted/wireproxy" "$WIREPROXY_BIN"
    write_config
    write_service
    install_manager

    rc-update add "$SERVICE_NAME" default >/dev/null || die "failed to enable OpenRC service"
    rc-service "$SERVICE_NAME" start || die "WireProxy failed to start; inspect $CONFIG_FILE"
    sleep 1
    port_is_listening "$PORT" || die "WireProxy started but port $PORT is not listening"

    if [ "$STACK" = 4 ]; then
        CURL_FAMILY=-4
    else
        CURL_FAMILY=
    fi

    if ! wait_for_warp; then
        info "WARP handshake was not ready; restarting WireProxy once."
        rc-service "$SERVICE_NAME" restart || die "WireProxy restart failed; inspect $CONFIG_FILE"
        wait_for_warp || die "WireProxy is listening but WARP did not become ready; inspect $CONFIG_FILE"
    fi
}

install_manager() {
    manager_source=$TMP_DIR/manager.sh

    case "$0" in
        /*|./*|../*)
            if [ -f "$0" ]; then
                cp "$0" "$manager_source"
            fi
            ;;
    esac
    if [ ! -s "$manager_source" ]; then
        curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 8 --max-time 30 \
            -o "$manager_source" "$SCRIPT_URL" ||
            die "failed to install the WireProxy management command"
    fi
    install -m 0755 "$manager_source" "$MANAGER_BIN"
}

install_proxy() {
    require_root
    require_alpine_openrc
    install_dependencies

    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    TMP_DIR=$(mktemp -d /run/wireproxy-warp.XXXXXX)
    trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

    generate_keypair "$TMP_DIR/key.der"
    register_warp_account "$ACCOUNT_FILE"
    extract_account_values
    download_wireproxy
    install_wireproxy

    info "WireProxy WARP SOCKS5 is running."
    info "Listen: 0.0.0.0:$PORT"
    info "Stack: $STACK"
    info "Config: $CONFIG_FILE"
}

status_proxy() {
    require_root
    if [ -x "$SERVICE_FILE" ]; then
        rc-service "$SERVICE_NAME" status || true
    else
        info "WireProxy WARP is not installed."
    fi
    if [ -f "$CONFIG_FILE" ]; then
        sed -n '/^\[Socks5\]/,/^$/p' "$CONFIG_FILE" |
            sed -E 's/^(Username|Password)[[:space:]]*=.*/\1 = <redacted>/'
    fi
}

uninstall_proxy() {
    require_root
    require_alpine_openrc
    stop_service
    rm -f "$SERVICE_FILE" "$WIREPROXY_BIN" "$MANAGER_BIN"
    rm -rf "$STATE_DIR"
    info "WireProxy WARP local files and service were removed."
}

restart_proxy() {
    require_root
    require_alpine_openrc
    [ -x "$SERVICE_FILE" ] || die "WireProxy WARP is not installed"
    load_proxy_settings
    if grep -q '^AllowedIPs = .*::/0' "$CONFIG_FILE"; then
        proxy_stack=dual
    else
        proxy_stack=4
    fi
    restart_and_wait "$proxy_stack"
    info "WireProxy WARP service restarted."
}

restart_and_wait() {
    if [ "$1" = 4 ]; then
        CURL_FAMILY=-4
    else
        CURL_FAMILY=
    fi
    rc-service "$SERVICE_NAME" restart || die "failed to restart WireProxy WARP"
    if ! wait_for_warp; then
        info "WARP handshake was not ready; restarting WireProxy once."
        rc-service "$SERVICE_NAME" restart || die "WireProxy restart failed"
        wait_for_warp || die "WireProxy restarted but WARP is not ready"
    fi
}

switch_stack_proxy() {
    require_root
    require_alpine_openrc
    [ -f "$CONFIG_FILE" ] || die "WireProxy WARP is not installed"
    [ -f "$ACCOUNT_FILE" ] || die "WARP account data is missing"

    address4=$(sed -n 's/.*"v4"[[:space:]]*:[[:space:]]*"\(172\.[^"]*\)".*/\1/p' "$ACCOUNT_FILE" | head -n 1)
    address6=$(sed -n 's/.*"v6"[[:space:]]*:[[:space:]]*"\(2606:[^"]*\)".*/\1/p' "$ACCOUNT_FILE" | head -n 1)
    [ -n "$address4" ] || die "WARP account has no IPv4 address"

    case "$1" in
        4)
            new_address=$address4/32
            new_allowed='0.0.0.0/0'
            ;;
        dual)
            [ -n "$address6" ] || die "WARP account has no IPv6 address"
            new_address="$address4/32, $address6/128"
            new_allowed='0.0.0.0/0, ::/0'
            ;;
        *)
            die "stack must be 4 or dual"
            ;;
    esac

    sed -i "s#^Address = .*#Address = $new_address#; s#^AllowedIPs = .*#AllowedIPs = $new_allowed#" "$CONFIG_FILE"
    "$WIREPROXY_BIN" -c "$CONFIG_FILE" -n >/dev/null 2>&1 ||
        die "updated WireProxy configuration is invalid"
    load_proxy_settings
    restart_and_wait "$1"
    info "WARP stack switched to $1."
}

menu_proxy() {
    require_root
    require_alpine_openrc

    while :; do
        printf '%s\n' '' 'WireProxy WARP menu' \
            '1) Show status' \
            '2) Restart service' \
            '3) Switch to IPv4-only' \
            '4) Switch to dual-stack' \
            '5) Uninstall' \
            '0) Exit'
        printf '%s' 'Select: '
        IFS= read -r choice || return 0
        case "$choice" in
            1) status_proxy ;;
            2) restart_proxy ;;
            3) switch_stack_proxy 4 ;;
            4) switch_stack_proxy dual ;;
            5) uninstall_proxy; return 0 ;;
            0) return 0 ;;
            *) info "Invalid selection." ;;
        esac
    done
}

if [ "$SCRIPT_NAME" = warp ]; then
    ACTION=menu
else
    ACTION=install
fi
STACK=dual
PORT=$DEFAULT_PORT
USERNAME=
PASSWORD=
SWITCH_STACK=

if [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ]; then
    ACTION=$1
    shift
fi

if [ "$ACTION" = menu ] && [ "$#" -gt 0 ]; then
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
fi

case "$ACTION" in
    install|menu|status|restart|uninstall) ;;
    switch)
        [ "$#" -ge 1 ] || die "switch requires 4 or dual"
        SWITCH_STACK=$1
        shift
        ;;
    -h|--help|help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

while [ "$#" -gt 0 ]; do
    case "$1" in
        --stack)
            [ "$#" -ge 2 ] || die "--stack requires 4 or dual"
            STACK=$2
            shift 2
            ;;
        --stack=*)
            STACK=${1#*=}
            shift
            ;;
        --ipv4-only)
            STACK=4
            shift
            ;;
        --dual-stack)
            STACK=dual
            shift
            ;;
        --port)
            [ "$#" -ge 2 ] || die "--port requires a value"
            PORT=$2
            shift 2
            ;;
        --port=*)
            PORT=${1#*=}
            shift
            ;;
        --username)
            [ "$#" -ge 2 ] || die "--username requires a value"
            USERNAME=$2
            shift 2
            ;;
        --username=*)
            USERNAME=${1#*=}
            shift
            ;;
        --password)
            [ "$#" -ge 2 ] || die "--password requires a value"
            PASSWORD=$2
            shift 2
            ;;
        --password=*)
            PASSWORD=${1#*=}
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

case "$ACTION" in
    install)
        case "$STACK" in
            4|dual) ;;
            *) die "--stack must be 4 or dual" ;;
        esac
        validate_port "$PORT"
        validate_credential "$USERNAME" username
        validate_credential "$PASSWORD" password
        install_proxy
        ;;
    menu)
        menu_proxy
        ;;
    status)
        status_proxy
        ;;
    restart)
        restart_proxy
        ;;
    switch)
        switch_stack_proxy "$SWITCH_STACK"
        ;;
    uninstall)
        uninstall_proxy
        ;;
esac
