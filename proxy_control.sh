#!/system/bin/sh
MODDIR=${0%/*}
BINDIR="$MODDIR/bin"
STUB_DIR=/dev/sysctl_stubs
PIDFILE="$STUB_DIR/run/xray.pid"
TUN2SOCKS_PIDFILE="$STUB_DIR/run/tun2socks.pid"

PIPE_FILE="$STUB_DIR/run/control.pipe"
DATADIR="/data/adb/magic_v2ray"
set -x >"$DATADIR/proxy_control.log" 2>&1

# Always using system binaries for critical operations to ensure compatibility and reliability
ip="/system/bin/ip"
iptables="/system/bin/iptables"
ip6tables="/system/bin/ip6tables"

get_status() {
    if [ -f "$PIDFILE" ]; then
        PID=$(cat "$PIDFILE")
        STAT_XRAY_EXE=$(stat -L -c "%D:%i" "/proc/$PID/exe")
        STAT_XRAY_BIN=$(stat -L -c "%D:%i" "$MODDIR/bin/xray")

        if kill -0 "$PID" 2>/dev/null && [ "$STAT_XRAY_EXE" = "$STAT_XRAY_BIN" ]; then
            echo "running"
            return 0
        fi
        echo "crashed"
        return 2
    fi
    echo "stopped"
    return 1
}

start_proxy() {
    if get_status; then
        echo "Proxy core is already running with PID $(cat "$PIDFILE")"
        return 0
    fi

    # Start xray core and tun2socks in the background
    echo start > "$PIPE_FILE"
    echo "wait" > "$PIPE_FILE"

    echo "Proxy core successfully running!"
}

stop_proxy() {
    # Stop xray core and tun2socks in the background
    echo stop > "$PIPE_FILE"
    echo "wait" > "$PIPE_FILE"

    echo "Proxy core successfully stopped!"
}

case "$1" in
    start) start_proxy ;;
    stop) stop_proxy; rm -rf "$DATADIR/config.json" ;;
    restart) stop_proxy; sleep 1; start_proxy ;;
    status) get_status ;;
esac