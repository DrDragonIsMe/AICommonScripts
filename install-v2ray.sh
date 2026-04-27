#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config/v2ray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
PID_FILE="${SCRIPT_DIR}/.v2ray.pid"

PROXY_HOST="127.0.0.1"
PROXY_PORT="1080"

get_config_port() {
    if command -v jq &> /dev/null && [ -f "${CONFIG_FILE}" ]; then
        local port
        port=$(jq -r '.inbounds[0].port // 1080' "${CONFIG_FILE}")
        PROXY_PORT="${port}"
    elif [ -f "${CONFIG_FILE}" ]; then
        local port
        port=$(grep -oP '"port":\s*\K[0-9]+' "${CONFIG_FILE}" | head -n 1)
        [ -n "${port}" ] && PROXY_PORT="${port}"
    fi
}

install_v2ray() {
    echo "Installing v2ray..."
    if command -v v2ray &> /dev/null; then
        echo "v2ray is already installed: $(v2ray version 2>/dev/null | head -n 1 || echo 'version unknown')"
        return 0
    fi

    if command -v curl &> /dev/null; then
        bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)
    elif command -v wget &> /dev/null; then
        bash <(wget -qO- https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)
    else
        echo "Error: curl or wget is required to install v2ray."
        exit 1
    fi

    echo "v2ray installed successfully."
}

uninstall_v2ray() {
    echo "Uninstalling v2ray..."
    stop_v2ray 2>/dev/null || true

    if command -v v2ray &> /dev/null || [ -f /usr/local/bin/v2ray ]; then
        if command -v curl &> /dev/null; then
            bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh) --remove
        elif command -v wget &> /dev/null; then
            bash <(wget -qO- https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh) --remove
        else
            echo "Warning: curl or wget not found, cannot run official uninstaller."
            rm -f /usr/local/bin/v2ray /usr/local/bin/v2ctl
            rm -rf /usr/local/share/v2ray /usr/local/etc/v2ray /var/log/v2ray
        fi
    else
        echo "v2ray is not installed."
    fi

    rm -f "${PID_FILE}"
    echo "v2ray uninstalled."
}

ensure_config() {
    if [ ! -d "${CONFIG_DIR}" ]; then
        echo "Creating config directory: ${CONFIG_DIR}"
        mkdir -p "${CONFIG_DIR}"
    fi

    if [ ! -f "${CONFIG_FILE}" ]; then
        echo "Creating default config file: ${CONFIG_FILE}"
        cat > "${CONFIG_FILE}" << 'EOF'
{
  "log": {
    "access": "/var/log/v2ray/access.log",
    "error": "/var/log/v2ray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 1080,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": {
        "udp": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF
    fi
}

get_v2ray_bin() {
    if command -v v2ray &> /dev/null; then
        command -v v2ray
    elif [ -f /usr/local/bin/v2ray ]; then
        echo /usr/local/bin/v2ray
    elif [ -f /usr/bin/v2ray ]; then
        echo /usr/bin/v2ray
    else
        echo ""
    fi
}

run_v2ray() {
    local v2ray_bin
    v2ray_bin=$(get_v2ray_bin)

    if [ -z "${v2ray_bin}" ]; then
        echo "Error: v2ray binary not found. Run '$0 install' first."
        exit 1
    fi

    if [ -f "${PID_FILE}" ]; then
        local pid
        pid=$(cat "${PID_FILE}")
        if kill -0 "${pid}" 2>/dev/null; then
            echo "v2ray is already running (PID: ${pid})."
            exit 0
        else
            rm -f "${PID_FILE}"
        fi
    fi

    ensure_config
    get_config_port

    echo "Starting v2ray with config: ${CONFIG_FILE}"
    nohup "${v2ray_bin}" run -config "${CONFIG_FILE}" > /dev/null 2>&1 &
    local new_pid=$!
    echo "${new_pid}" > "${PID_FILE}"
    sleep 1

    if kill -0 "${new_pid}" 2>/dev/null; then
        echo "v2ray started (PID: ${new_pid})."
        proxy_on
    else
        echo "Error: v2ray failed to start."
        rm -f "${PID_FILE}"
        exit 1
    fi
}

stop_v2ray() {
    proxy_off

    if [ -f "${PID_FILE}" ]; then
        local pid
        pid=$(cat "${PID_FILE}")
        if kill -0 "${pid}" 2>/dev/null; then
            echo "Stopping v2ray (PID: ${pid})..."
            kill "${pid}" 2>/dev/null || true
            local count=0
            while kill -0 "${pid}" 2>/dev/null && [ ${count} -lt 10 ]; do
                sleep 0.5
                count=$((count + 1))
            done
            if kill -0 "${pid}" 2>/dev/null; then
                kill -9 "${pid}" 2>/dev/null || true
            fi
            echo "v2ray stopped."
        else
            echo "v2ray is not running."
        fi
        rm -f "${PID_FILE}"
    else
        local pid
        pid=$(pgrep -f "v2ray run -config ${CONFIG_FILE}" | head -n 1) || true
        if [ -n "${pid}" ]; then
            echo "Stopping v2ray (PID: ${pid})..."
            kill "${pid}" 2>/dev/null || true
            echo "v2ray stopped."
        else
            echo "v2ray is not running."
        fi
    fi
}

proxy_on() {
    get_config_port

    export http_proxy="http://${PROXY_HOST}:${PROXY_PORT}"
    export https_proxy="http://${PROXY_HOST}:${PROXY_PORT}"
    export HTTP_PROXY="http://${PROXY_HOST}:${PROXY_PORT}"
    export HTTPS_PROXY="http://${PROXY_HOST}:${PROXY_PORT}"
    export ALL_PROXY="socks5h://${PROXY_HOST}:${PROXY_PORT}"
    export all_proxy="socks5h://${PROXY_HOST}:${PROXY_PORT}"
    export NO_PROXY="localhost,127.0.0.1,::1"
    export no_proxy="localhost,127.0.0.1,::1"

    echo "Environment proxy variables set:"
    echo "  http_proxy=${http_proxy}"
    echo "  https_proxy=${https_proxy}"
    echo "  all_proxy=${all_proxy}"

    if command -v gsettings &> /dev/null && [ -n "${DISPLAY:-}" ]; then
        echo "Setting GNOME system proxy..."
        gsettings set org.gnome.system.proxy mode 'manual' 2>/dev/null || true
        gsettings set org.gnome.system.proxy.http host "${PROXY_HOST}" 2>/dev/null || true
        gsettings set org.gnome.system.proxy.http port "${PROXY_PORT}" 2>/dev/null || true
        gsettings set org.gnome.system.proxy.https host "${PROXY_HOST}" 2>/dev/null || true
        gsettings set org.gnome.system.proxy.https port "${PROXY_PORT}" 2>/dev/null || true
        gsettings set org.gnome.system.proxy.socks host "${PROXY_HOST}" 2>/dev/null || true
        gsettings set org.gnome.system.proxy.socks port "${PROXY_PORT}" 2>/dev/null || true
        gsettings set org.gnome.system.proxy ignore-hosts "['localhost', '127.0.0.0/8', '::1']" 2>/dev/null || true
        echo "GNOME proxy settings applied."
    fi
}

proxy_off() {
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy 2>/dev/null || true

    echo "Environment proxy variables cleared."

    if command -v gsettings &> /dev/null && [ -n "${DISPLAY:-}" ]; then
        echo "Clearing GNOME system proxy..."
        gsettings set org.gnome.system.proxy mode 'none' 2>/dev/null || true
        echo "GNOME proxy settings cleared."
    fi
}

show_status() {
    local v2ray_bin
    v2ray_bin=$(get_v2ray_bin)

    if [ -n "${v2ray_bin}" ]; then
        echo "v2ray binary: ${v2ray_bin}"
        ${v2ray_bin} version 2>/dev/null | head -n 1 || echo "  (version check failed)"
    else
        echo "v2ray binary: not found"
    fi

    if [ -f "${PID_FILE}" ]; then
        local pid
        pid=$(cat "${PID_FILE}")
        if kill -0 "${pid}" 2>/dev/null; then
            echo "v2ray status: running (PID: ${pid})"
        else
            echo "v2ray status: not running (stale PID file)"
        fi
    else
        local pid
        pid=$(pgrep -f "v2ray run -config ${CONFIG_FILE}" | head -n 1) || true
        if [ -n "${pid}" ]; then
            echo "v2ray status: running (PID: ${pid})"
        else
            echo "v2ray status: not running"
        fi
    fi

    echo "Config file: ${CONFIG_FILE}"
    if [ -f "${CONFIG_FILE}" ]; then
        get_config_port
        echo "  SOCKS/HTTP proxy port: ${PROXY_PORT}"
    else
        echo "  (not exists)"
    fi
}

show_help() {
    cat << 'EOF'
Usage: ./install-v2ray.sh <command>

Commands:
  install      Install v2ray and initialize config
  uninstall    Stop v2ray and remove installation
  run          Start v2ray (with auto proxy setup)
  stop         Stop v2ray (with auto proxy cleanup)
  proxy-on     Set environment and GNOME proxy only
  proxy-off    Unset environment and GNOME proxy only
  status       Show v2ray and config status
  help         Show this help message

Examples:
  ./install-v2ray.sh install
  ./install-v2ray.sh run
  ./install-v2ray.sh stop
  ./install-v2ray.sh uninstall
EOF
}

case "${1:-help}" in
    install)
        install_v2ray
        ensure_config
        echo ""
        show_status
        echo ""
        echo "Installation complete. Use '$0 run' to start."
        ;;
    uninstall)
        uninstall_v2ray
        ;;
    run)
        run_v2ray
        ;;
    stop)
        stop_v2ray
        ;;
    proxy-on)
        proxy_on
        ;;
    proxy-off)
        proxy_off
        ;;
    status)
        show_status
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
