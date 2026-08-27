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
DNS_ADDRESS=1.1.1.1
SELECT_PID_FILE=/run/wireproxy-warp-select.pid
SELECT_LOCK_DIR=/run/wireproxy-warp-select.lock
SELECT_STATUS_FILE=$STATE_DIR/endpoint-selection.status
SELECT_LOG_FILE=$STATE_DIR/endpoint-selection.log
SELECT_ROUNDS=8
SELECT_RETRY_DELAY=15
WATCHDOG_ENABLED_FILE=$STATE_DIR/watchdog.enabled
WATCHDOG_STATUS_FILE=$STATE_DIR/watchdog.status
WATCHDOG_INTERVAL=900
WATCHDOG_PROBE_ATTEMPTS=3
WATCHDOG_RETRY_DELAY=10

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
  $SCRIPT_NAME test
  $SCRIPT_NAME retry
  $SCRIPT_NAME restart
  $SCRIPT_NAME dns cloudflare|native
  $SCRIPT_NAME watchdog on|off|status
  $SCRIPT_NAME switch 4|dual
  $SCRIPT_NAME uninstall

Install options:
  --stack 4|dual       WARP egress mode (default: dual)
  --ipv4-only          Same as --stack 4
  --dual-stack         Same as --stack dual
  --port PORT          SOCKS5 listen port (default: $DEFAULT_PORT)
  --username USER      Required SOCKS5 username
  --password PASSWORD  Required SOCKS5 password
  --dns cloudflare|native
                       DNS mode (default: cloudflare / $DNS_ADDRESS)

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
    command -v supervise-daemon >/dev/null 2>&1 || die "OpenRC supervise-daemon was not found"
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

validate_dns_mode() {
    case "$1" in
        cloudflare|native) ;;
        *) die "DNS mode must be cloudflare or native" ;;
    esac
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

stop_service() {
    [ -x "$SERVICE_FILE" ] || return 0
    rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
    rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
}

selector_is_running() {
    selector_pid=$1
    [ -n "$selector_pid" ] && [ -r "/proc/$selector_pid/cmdline" ] || return 1
    tr '\000' ' ' < "/proc/$selector_pid/cmdline" | grep -Fq "$MANAGER_BIN _select"
}

stop_endpoint_selection() {
    if [ -r "$SELECT_PID_FILE" ]; then
        selector_pid=$(sed -n '1p' "$SELECT_PID_FILE")
        if selector_is_running "$selector_pid"; then
            kill "$selector_pid" 2>/dev/null || true
            wait_count=0
            while selector_is_running "$selector_pid" && [ "$wait_count" -lt 10 ]; do
                sleep 1
                wait_count=$((wait_count + 1))
            done
        fi
    fi
    rm -f "$SELECT_PID_FILE"
    rmdir "$SELECT_LOCK_DIR" 2>/dev/null || true
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
    ENDPOINT6=$(sed -n 's/.*"endpoint"[[:space:]]*:[[:space:]]*{[^}]*"v6"[[:space:]]*:[[:space:]]*"\[\([^]]*\)\]:[0-9]*".*/[\1]:2408/p' "$ACCOUNT_FILE" | head -n 1)

    [ -n "$ADDRESS4" ] || die "registration response has no WARP IPv4 address"
    [ -n "$PEER_PUBLIC_KEY" ] || die "registration response has no WARP peer key"
    [ -n "$ENDPOINT4" ] || die "registration response has no IPv4 endpoint"

    if [ "$STACK" = dual ] && [ -z "$ADDRESS6" ]; then
        die "dual-stack registration response has no WARP IPv6 address"
    fi
}

warp_proxy_ready() {
    curl --fail --silent --connect-timeout 5 --max-time 8 \
        --proxy "socks5://127.0.0.1:$PORT" \
        --proxy-user "$USERNAME:$PASSWORD" \
        https://1.1.1.1/cdn-cgi/trace 2>/dev/null |
        grep -q '^warp=on$'
}

direct_network_ready() {
    http_status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
        --connect-timeout 5 --max-time 8 \
        https://cp.cloudflare.com/generate_204 2>/dev/null || true)
    [ "$http_status" = 204 ]
}

watchdog_is_enabled() {
    [ -f "$WATCHDOG_ENABLED_FILE" ]
}

write_watchdog_status() {
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" > "$WATCHDOG_STATUS_FILE"
}

run_watchdog_check() {
    require_root
    require_alpine_openrc

    watchdog_is_enabled || return 0

    if [ -r "$SELECT_PID_FILE" ]; then
        selector_pid=$(sed -n '1p' "$SELECT_PID_FILE")
        if selector_is_running "$selector_pid"; then
            write_watchdog_status "skipped endpoint-selection-running"
            return 0
        fi
    fi

    load_proxy_values
    attempt=1
    while [ "$attempt" -le "$WATCHDOG_PROBE_ATTEMPTS" ]; do
        if warp_proxy_ready; then
            write_watchdog_status "healthy socks5"
            return 0
        fi
        attempt=$((attempt + 1))
        [ "$attempt" -gt "$WATCHDOG_PROBE_ATTEMPTS" ] || sleep "$WATCHDOG_RETRY_DELAY"
    done

    if ! direct_network_ready; then
        write_watchdog_status "degraded proxy-unavailable direct-network-unavailable no-restart"
        return 0
    fi

    write_watchdog_status "unhealthy proxy-unavailable direct-network-ready restart-requested"
    return 1
}

record_watchdog_restart() {
    require_root
    write_watchdog_status "recovering wireproxy-restart"
}

set_peer_endpoint() {
    endpoint=$1
    sed -i "s#^Endpoint = .*#Endpoint = $endpoint#" "$CONFIG_FILE"
    "$WIREPROXY_BIN" -c "$CONFIG_FILE" -n >/dev/null 2>&1 ||
        die "generated WireProxy endpoint configuration is invalid"
}

load_proxy_values() {
    [ -f "$CONFIG_FILE" ] || die "WireProxy WARP is not installed"
    PORT=$(sed -n 's/^BindAddress[[:space:]]*=[[:space:]]*.*:\([0-9][0-9]*\)$/\1/p' "$CONFIG_FILE" | head -n 1)
    USERNAME=$(sed -n 's/^Username[[:space:]]*=[[:space:]]*//p' "$CONFIG_FILE" | head -n 1)
    PASSWORD=$(sed -n 's/^Password[[:space:]]*=[[:space:]]*//p' "$CONFIG_FILE" | head -n 1)
    [ -n "$PORT" ] && [ -n "$USERNAME" ] && [ -n "$PASSWORD" ] ||
        die "WireProxy SOCKS5 configuration is incomplete"
}

load_account_endpoints() {
    [ -f "$ACCOUNT_FILE" ] || die "WARP account data is missing"
    ENDPOINT4=$(sed -n 's/.*"endpoint"[[:space:]]*:[[:space:]]*{[^}]*"v4"[[:space:]]*:[[:space:]]*"\([0-9.]*\):[0-9]*".*/\1:2408/p' "$ACCOUNT_FILE" | head -n 1)
    ENDPOINT6=$(sed -n 's/.*"endpoint"[[:space:]]*:[[:space:]]*{[^}]*"v6"[[:space:]]*:[[:space:]]*"\[\([^]]*\)\]:[0-9]*".*/[\1]:2408/p' "$ACCOUNT_FILE" | head -n 1)
    [ -n "$ENDPOINT4" ] || die "WARP account has no IPv4 endpoint"
}

write_selection_status() {
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" > "$SELECT_STATUS_FILE"
}

try_endpoint() {
    endpoint=$1
    transport=$2
    current_endpoint=$(sed -n 's/^Endpoint[[:space:]]*=[[:space:]]*//p' "$CONFIG_FILE" | head -n 1)
    if [ "$current_endpoint" != "$endpoint" ]; then
        set_peer_endpoint "$endpoint"
        rc-service "$SERVICE_NAME" restart >/dev/null 2>&1 || return 1
        sleep 1
    fi
    if warp_proxy_ready; then
        write_selection_status "success transport=$transport endpoint=$endpoint"
        return 0
    fi
    return 1
}

run_endpoint_selection() {
    require_root
    require_alpine_openrc
    load_proxy_values
    load_account_endpoints
    trap 'selection_code=$?; if [ "$selection_code" -ne 0 ]; then write_selection_status "failed worker-exit=$selection_code; see $SELECT_LOG_FILE"; fi; rm -f "$SELECT_PID_FILE"; rmdir "$SELECT_LOCK_DIR" 2>/dev/null || true' EXIT
    trap 'exit 1' INT TERM

    round=1
    while [ "$round" -le "$SELECT_ROUNDS" ]; do
        write_selection_status "running round=$round/$SELECT_ROUNDS transport=IPv4"
        if try_endpoint "$ENDPOINT4" IPv4; then
            exit 0
        fi
        if [ -n "$ENDPOINT6" ]; then
            write_selection_status "running round=$round/$SELECT_ROUNDS transport=IPv6"
            if try_endpoint "$ENDPOINT6" IPv6; then
                exit 0
            fi
        fi
        round=$((round + 1))
        [ "$round" -gt "$SELECT_ROUNDS" ] || sleep "$SELECT_RETRY_DELAY"
    done

    write_selection_status "failed after=$SELECT_ROUNDS-rounds; run 'warp retry' to try again"
    exit 0
}

start_endpoint_selection() {
    require_root
    require_alpine_openrc
    load_proxy_values
    load_account_endpoints

    if [ -r "$SELECT_PID_FILE" ]; then
        selector_pid=$(sed -n '1p' "$SELECT_PID_FILE")
        if selector_is_running "$selector_pid"; then
            info "WARP endpoint selection is already running (PID $selector_pid)."
            return 0
        fi
    fi

    rm -f "$SELECT_PID_FILE"
    rmdir "$SELECT_LOCK_DIR" 2>/dev/null || true
    mkdir "$SELECT_LOCK_DIR" || die "another WARP endpoint selection is starting"
    write_selection_status "starting"
    nohup "$MANAGER_BIN" _select > "$SELECT_LOG_FILE" 2>&1 &
    selector_pid=$!
    printf '%s\n' "$selector_pid" > "$SELECT_PID_FILE"
    info "WARP endpoint selection started in the background (PID $selector_pid)."
    info "A new WARP account may take a few minutes to become usable."
    info "Use 'warp status' or 'warp test' later to check it."
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
        printf 'MTU = 1280\nPrivateKey = %s\n' "$PRIVATE_KEY"
        if [ "$DNS_MODE" = cloudflare ]; then
            printf 'DNS = %s\n' "$DNS_ADDRESS"
        fi
        printf '\n'
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
supervisor=supervise-daemon
pidfile="/run/$SERVICE_NAME.pid"
respawn_delay=3
respawn_max=5
respawn_period=60
healthcheck_delay=$WATCHDOG_INTERVAL
healthcheck_timer=$WATCHDOG_INTERVAL

healthcheck() {
    "$MANAGER_BIN" _watchdog_check
}

unhealthy() {
    "$MANAGER_BIN" _watchdog_restarting
}

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
    stop_endpoint_selection

    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    TMP_DIR=$(mktemp -d /run/wireproxy-warp.XXXXXX)
    trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

    generate_keypair "$TMP_DIR/key.der"
    register_warp_account "$ACCOUNT_FILE"
    extract_account_values
    download_wireproxy
    : > "$WATCHDOG_ENABLED_FILE"
    chmod 600 "$WATCHDOG_ENABLED_FILE"
    write_watchdog_status "enabled awaiting-first-check"
    install_wireproxy
    start_endpoint_selection

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
        current_endpoint=$(sed -n 's/^Endpoint[[:space:]]*=[[:space:]]*//p' "$CONFIG_FILE" | head -n 1)
        [ -z "$current_endpoint" ] || info "Endpoint = $current_endpoint"
        dns_mode=$(current_dns_mode)
        if [ "$dns_mode" = cloudflare ]; then
            info "DNS: Cloudflare ($DNS_ADDRESS)"
        else
            info "DNS: native system resolver"
        fi
    fi
    if [ -r "$SELECT_PID_FILE" ]; then
        selector_pid=$(sed -n '1p' "$SELECT_PID_FILE")
        if selector_is_running "$selector_pid"; then
            info "Endpoint selection: running (PID $selector_pid)"
        else
            info "Endpoint selection: not running (stale PID file)"
        fi
    else
        info "Endpoint selection: not running"
    fi
    [ ! -r "$SELECT_STATUS_FILE" ] || info "Last selection result: $(sed -n '1p' "$SELECT_STATUS_FILE")"
    if watchdog_is_enabled; then
        info "Watchdog: enabled (interval: 15 minutes)"
    else
        info "Watchdog: disabled"
    fi
    [ ! -r "$WATCHDOG_STATUS_FILE" ] || info "Last watchdog result: $(sed -n '1p' "$WATCHDOG_STATUS_FILE")"
}

test_proxy() {
    require_root
    require_alpine_openrc
    load_proxy_values
    if warp_proxy_ready; then
        info "WARP proxy test passed (warp=on)."
    else
        die "WARP proxy test failed"
    fi
}

uninstall_proxy() {
    require_root
    require_alpine_openrc
    stop_endpoint_selection
    stop_service
    rm -f "$SERVICE_FILE" "$WIREPROXY_BIN" "$MANAGER_BIN"
    rm -rf "$STATE_DIR"
    info "WireProxy WARP local files and service were removed."
}

restart_proxy() {
    require_root
    require_alpine_openrc
    [ -x "$SERVICE_FILE" ] || die "WireProxy WARP is not installed"
    rc-service "$SERVICE_NAME" restart || die "failed to restart WireProxy WARP"
    info "WireProxy WARP service restarted in background."
    info "Initial WARP handshake may take a few minutes."
}

watchdog_proxy() {
    require_root
    require_alpine_openrc
    [ -x "$SERVICE_FILE" ] || die "WireProxy WARP is not installed"

    case "$1" in
        on)
            : > "$WATCHDOG_ENABLED_FILE"
            chmod 600 "$WATCHDOG_ENABLED_FILE"
            write_watchdog_status "enabled awaiting-next-check"
            info "WireProxy WARP watchdog enabled (interval: 15 minutes)."
            ;;
        off)
            rm -f "$WATCHDOG_ENABLED_FILE"
            write_watchdog_status "disabled"
            info "WireProxy WARP watchdog disabled."
            info "OpenRC process crash recovery remains enabled."
            ;;
        status)
            if watchdog_is_enabled; then
                info "Watchdog: enabled (interval: 15 minutes)"
            else
                info "Watchdog: disabled"
            fi
            [ ! -r "$WATCHDOG_STATUS_FILE" ] || info "Last watchdog result: $(sed -n '1p' "$WATCHDOG_STATUS_FILE")"
            ;;
        *)
            die "watchdog action must be on, off, or status"
            ;;
    esac
}

current_dns_mode() {
    dns_value=$(sed -n 's/^DNS[[:space:]]*=[[:space:]]*//p' "$CONFIG_FILE" | head -n 1)
    if [ "$dns_value" = "$DNS_ADDRESS" ]; then
        printf '%s\n' cloudflare
    else
        printf '%s\n' native
    fi
}

switch_dns_proxy() {
    require_root
    require_alpine_openrc
    [ -f "$CONFIG_FILE" ] || die "WireProxy WARP is not installed"
    validate_dns_mode "$1"

    new_config=$(mktemp "$STATE_DIR/proxy.conf.XXXXXX") ||
        die "failed to create temporary DNS configuration"
    if [ "$1" = cloudflare ]; then
        awk -v dns="$DNS_ADDRESS" '
            /^DNS[[:space:]]*=/ { print "DNS = " dns; found=1; next }
            { print }
            /^PrivateKey[[:space:]]*=/ && !found { print "DNS = " dns; found=1 }
        ' "$CONFIG_FILE" > "$new_config"
    else
        sed '/^DNS[[:space:]]*=/d' "$CONFIG_FILE" > "$new_config"
    fi
    "$WIREPROXY_BIN" -c "$new_config" -n >/dev/null 2>&1 || {
        rm -f "$new_config"
        die "updated WireProxy DNS configuration is invalid"
    }
    chmod 600 "$new_config"
    mv "$new_config" "$CONFIG_FILE"
    rc-service "$SERVICE_NAME" restart || die "failed to restart WireProxy WARP"
    if [ "$1" = cloudflare ]; then
        info "DNS switched to Cloudflare ($DNS_ADDRESS)."
    else
        info "DNS switched to native system resolver."
    fi
    info "Initial WARP handshake runs in the background and may take a few minutes."
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
    rc-service "$SERVICE_NAME" restart || die "failed to restart WireProxy WARP"
    info "WARP stack switched to $1."
    info "Initial WARP handshake runs in the background and may take a few minutes."
}

menu_proxy() {
    require_root
    require_alpine_openrc

    while :; do
        if [ -f "$CONFIG_FILE" ]; then
            dns_mode=$(current_dns_mode)
        else
            dns_mode=cloudflare
        fi
        if [ "$dns_mode" = cloudflare ]; then
            dns_menu_label='7) Switch DNS to native resolver (currently Cloudflare)'
            dns_menu_action=native
        else
            dns_menu_label='7) Switch DNS to Cloudflare 1.1.1.1 (currently native)'
            dns_menu_action=cloudflare
        fi
        if watchdog_is_enabled; then
            watchdog_menu_label='9) Disable watchdog (currently enabled)'
            watchdog_menu_action=off
        else
            watchdog_menu_label='9) Enable watchdog (currently disabled)'
            watchdog_menu_action=on
        fi
        printf '%s\n' '' 'WireProxy WARP menu' \
            '1) Show status' \
            '2) Test WARP proxy' \
            '3) Retry endpoint selection' \
            '4) Restart service' \
            '5) Switch to IPv4-only' \
            '6) Switch to dual-stack' \
            "$dns_menu_label" \
            '8) Uninstall' \
            "$watchdog_menu_label" \
            '0) Exit'
        printf '%s' 'Select: '
        IFS= read -r choice || return 0
        case "$choice" in
            1) status_proxy ;;
            2) test_proxy ;;
            3) start_endpoint_selection ;;
            4) restart_proxy ;;
            5) switch_stack_proxy 4 ;;
            6) switch_stack_proxy dual ;;
            7) switch_dns_proxy "$dns_menu_action" ;;
            8) uninstall_proxy; return 0 ;;
            9) watchdog_proxy "$watchdog_menu_action" ;;
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
DNS_MODE=cloudflare
USERNAME=
PASSWORD=
SWITCH_STACK=
DNS_MODE_ACTION=
WATCHDOG_ACTION=status

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
    install|menu|status|test|retry|restart|uninstall|_select|_watchdog_check|_watchdog_restarting) ;;
    watchdog)
        if [ "$#" -gt 0 ]; then
            WATCHDOG_ACTION=$1
            shift
        fi
        ;;
    switch)
        [ "$#" -ge 1 ] || die "switch requires 4 or dual"
        SWITCH_STACK=$1
        shift
        ;;
    dns)
        [ "$#" -ge 1 ] || die "dns requires cloudflare or native"
        DNS_MODE_ACTION=$1
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
        --dns)
            [ "$#" -ge 2 ] || die "--dns requires cloudflare or native"
            DNS_MODE=$2
            shift 2
            ;;
        --dns=*)
            DNS_MODE=${1#*=}
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
        validate_dns_mode "$DNS_MODE"
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
    test)
        test_proxy
        ;;
    retry)
        start_endpoint_selection
        ;;
    restart)
        restart_proxy
        ;;
    watchdog)
        watchdog_proxy "$WATCHDOG_ACTION"
        ;;
    switch)
        switch_stack_proxy "$SWITCH_STACK"
        ;;
    dns)
        switch_dns_proxy "$DNS_MODE_ACTION"
        ;;
    uninstall)
        uninstall_proxy
        ;;
    _select)
        run_endpoint_selection
        ;;
    _watchdog_check)
        run_watchdog_check
        ;;
    _watchdog_restarting)
        record_watchdog_restart
        ;;
esac
