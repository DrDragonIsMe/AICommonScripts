#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.local/bin"
CONFIG_DIR="${HOME}/.config/v2ray"
SHARE_DIR="${HOME}/.local/share/v2ray"
LOG_DIR="${SHARE_DIR}/logs"
CONFIG_FILE="${CONFIG_DIR}/config.json"
PID_FILE="${CONFIG_DIR}/.v2ray.pid"

V2RAY_BIN="${INSTALL_DIR}/v2ray"
GEOIP_FILE="${SHARE_DIR}/geoip.dat"
GEOSITE_FILE="${SHARE_DIR}/geosite.dat"

PROXY_HOST="127.0.0.1"
PROXY_PORT="1080"

get_arch() {
    local arch
    arch=$(uname -m)
    case "${arch}" in
        x86_64|amd64)
            echo "64"
            ;;
        aarch64|arm64)
            echo "arm64-v8a"
            ;;
        armv7l|armv7)
            echo "arm32-v7a"
            ;;
        i386|i686)
            echo "32"
            ;;
        *)
            echo "Unsupported architecture: ${arch}" >&2
            exit 1
            ;;
    esac
}

get_latest_release_url() {
    local arch
    arch=$(get_arch)
    local api_url="https://api.github.com/repos/v2fly/v2ray-core/releases/latest"
    local download_url

    if command -v curl &> /dev/null; then
        download_url=$(curl -sL "${api_url}" | grep -oP "https://[^\"]+v2ray-linux-${arch}\.zip" | head -n 1)
    elif command -v wget &> /dev/null; then
        download_url=$(wget -qO- "${api_url}" | grep -oP "https://[^\"]+v2ray-linux-${arch}\.zip" | head -n 1)
    else
        echo "Error: curl or wget is required." >&2
        exit 1
    fi

    if [ -z "${download_url}" ]; then
        echo "Error: Could not find download URL for architecture: ${arch}" >&2
        exit 1
    fi

    echo "${download_url}"
}

install_v2ray() {
    echo "Installing v2ray to user directory..."

    if [ -f "${V2RAY_BIN}" ]; then
        echo "v2ray is already installed: $(${V2RAY_BIN} version 2>/dev/null | head -n 1 || echo 'version unknown')"
        echo "Use '$0 uninstall' first if you want to reinstall."
        return 0
    fi

    local download_url tmp_dir arch
    download_url=$(get_latest_release_url)
    arch=$(get_arch)

    echo "Downloading v2ray for linux-${arch}..."
    echo "URL: ${download_url}"

    tmp_dir=$(mktemp -d)
    trap "rm -rf ${tmp_dir}" EXIT

    if command -v curl &> /dev/null; then
        curl -L -o "${tmp_dir}/v2ray.zip" "${download_url}"
    elif command -v wget &> /dev/null; then
        wget -O "${tmp_dir}/v2ray.zip" "${download_url}"
    fi

    if command -v unzip &> /dev/null; then
        unzip -q "${tmp_dir}/v2ray.zip" -d "${tmp_dir}/extracted"
    else
        echo "Error: unzip is required to extract v2ray." >&2
        exit 1
    fi

    mkdir -p "${INSTALL_DIR}" "${SHARE_DIR}" "${LOG_DIR}"

    cp "${tmp_dir}/extracted/v2ray" "${V2RAY_BIN}"
    chmod +x "${V2RAY_BIN}"

    [ -f "${tmp_dir}/extracted/geoip.dat" ] && cp "${tmp_dir}/extracted/geoip.dat" "${GEOIP_FILE}"
    [ -f "${tmp_dir}/extracted/geosite.dat" ] && cp "${tmp_dir}/extracted/geosite.dat" "${GEOSITE_FILE}"

    # Add to PATH if needed
    if ! echo "$PATH" | grep -q "${INSTALL_DIR}"; then
        local shell_rc
        case "${SHELL##*/}" in
            zsh)
                shell_rc="${HOME}/.zshrc"
                ;;
            bash)
                shell_rc="${HOME}/.bashrc"
                ;;
            *)
                shell_rc=""
                ;;
        esac

        if [ -n "${shell_rc}" ] && [ -f "${shell_rc}" ]; then
            if ! grep -q "export PATH=\"\${HOME}/.local/bin:\${PATH}\"" "${shell_rc}" 2>/dev/null; then
                echo "export PATH=\"\${HOME}/.local/bin:\${PATH}\"" >> "${shell_rc}"
                echo "Added ${INSTALL_DIR} to PATH in ${shell_rc}. Please run: source ${shell_rc}"
            fi
        fi
    fi

    echo "v2ray installed successfully to ${V2RAY_BIN}"
    echo ""
    "${V2RAY_BIN}" version | head -n 1 || true
}

uninstall_v2ray() {
    echo "Uninstalling v2ray..."
    stop_v2ray 2>/dev/null || true

    rm -f "${V2RAY_BIN}"
    rm -f "${GEOIP_FILE}" "${GEOSITE_FILE}"
    rm -rf "${SHARE_DIR}"
    rm -rf "${CONFIG_DIR}"

    echo "v2ray uninstalled."
}

ensure_config() {
    if [ ! -d "${CONFIG_DIR}" ]; then
        echo "Creating config directory: ${CONFIG_DIR}"
        mkdir -p "${CONFIG_DIR}"
    fi

    local need_fix=false
    if [ -f "${CONFIG_FILE}" ]; then
        if grep -q '/var/log' "${CONFIG_FILE}" 2>/dev/null; then
            echo "Detected /var/log paths in existing config (requires root). Will regenerate..."
            need_fix=true
        fi
        if grep -q '"routings"' "${CONFIG_FILE}" 2>/dev/null; then
            echo "Detected invalid 'routings' key in existing config. Will regenerate..."
            need_fix=true
        fi
        if ! grep -q '"inbounds"' "${CONFIG_FILE}" 2>/dev/null; then
            echo "Detected missing inbounds in existing config. Will regenerate..."
            need_fix=true
        fi
    fi

    if [ ! -f "${CONFIG_FILE}" ] || [ "${need_fix}" = true ]; then
        if [ -f "${CONFIG_FILE}" ] && [ "${need_fix}" = true ]; then
            mv "${CONFIG_FILE}" "${CONFIG_FILE}.backup.$(date +%Y%m%d%H%M%S)"
            echo "Old config backed up."
        fi

        echo "Creating config file: ${CONFIG_FILE}"
        cat > "${CONFIG_FILE}" << 'EOF'
{
  "log": {
    "access": "${LOG_DIR}/access.log",
    "error": "${LOG_DIR}/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 1080,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": {
        "udp": true,
        "auth": "noauth"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    },
    {
      "port": 1081,
      "listen": "127.0.0.1",
      "protocol": "http",
      "settings": {},
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vmess",
      "settings": {
        "vnext": [
          {
            "address": "c36s5.portablesubmarines.com",
            "port": 17680,
            "users": [
              {
                "id": "50a67ef6-b806-403e-875c-894b7ad90861",
                "alterId": 0,
                "security": "auto",
                "level": 0
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none",
        "tcpSettings": {
          "header": {
            "type": "none"
          }
        }
      },
      "mux": {
        "enabled": false,
        "concurrency": 8
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    },
    {
      "tag": "block",
      "protocol": "blackhole",
      "settings": {
        "response": {
          "type": "http"
        }
      }
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": [
          "geoip:private",
          "geoip:cn"
        ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "domain": [
          "geosite:cn",
          "localhost"
        ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "port": "0-65535",
        "outboundTag": "proxy"
      }
    ]
  }
}
EOF
        # Replace LOG_DIR placeholder in the heredoc
        sed -i "s|\\${LOG_DIR}|${LOG_DIR}|g" "${CONFIG_FILE}"
    fi
}

get_v2ray_bin() {
    if [ -f "${V2RAY_BIN}" ]; then
        echo "${V2RAY_BIN}"
    elif command -v v2ray &> /dev/null; then
        command -v v2ray
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

    mkdir -p "${LOG_DIR}"

    echo "Starting v2ray with config: ${CONFIG_FILE}"
    nohup "${v2ray_bin}" run -config "${CONFIG_FILE}" -format jsonv5 > /dev/null 2>&1 &
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
        "${v2ray_bin}" version 2>/dev/null | head -n 1 || echo "  (version check failed)"
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

    echo "Data directory: ${SHARE_DIR}"
    echo "Log directory: ${LOG_DIR}"
}

show_help() {
    cat << 'EOF'
Usage: ./install-v2ray.sh <command>

Commands:
  install      Install v2ray to ~/.local/bin and initialize config
  uninstall    Stop v2ray and remove user installation
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
