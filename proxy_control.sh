#!/system/bin/sh
MODDIR=${0%/*}
BINDIR="$MODDIR/bin"
STUB_DIR=/dev/sysctl_stubs
XRAY_PROC="$STUB_DIR/proc/xray"

PIPE_FILE="$STUB_DIR/run/control.pipe"
DATADIR="/data/adb/magic_v2ray"
set -x >"$DATADIR/proxy_control.log" 2>&1

# Always using system binaries for critical operations to ensure compatibility and reliability
ip="/system/bin/ip"
iptables="/system/bin/iptables"
ip6tables="/system/bin/ip6tables"

get_status() {
    if [ -d "$XRAY_PROC" ]; then
        if [ -e "$XRAY_PROC/exe" ]; then
            echo "running"
            return 0
        fi
        # This means the process has crashed or exited unexpectedly
        # But it has not been unmounted yet, so we can still detect it
        echo "crashed"
        return 2
    fi
    echo "stopped"
    return 1
}

start_proxy() {
    if get_status; then
        echo "Proxy core is already running"
        return 0
    fi

    # Start xray core and tun2socks in the background
    echo "start" > "$PIPE_FILE"
    echo "wait" > "$PIPE_FILE"

    echo "Proxy core successfully running!"
}

stop_proxy() {
    # Stop xray core and tun2socks in the background
    echo stop > "$PIPE_FILE"
    echo "wait" > "$PIPE_FILE"

    echo "Proxy core successfully stopped!"
}

reapply() {
    echo "apply_cur_iface" > "$PIPE_FILE"
    echo "wait" > "$PIPE_FILE"
}

start_monitor_latency() {
    echo "start_monitor_latency" > "$PIPE_FILE"
    echo "wait" > "$PIPE_FILE"
}

stop_monitor_latency() {
    echo "stop_monitor_latency" > "$PIPE_FILE"
    echo "wait" > "$PIPE_FILE"
}

case "$1" in
    start) start_proxy ;;
    stop) stop_proxy; rm -rf "$DATADIR/config.json" ;;
    restart) stop_proxy; sleep 1; start_proxy ;;
    status) get_status ;;
    reapply) reapply ;;
    start_monitor_latency) start_monitor_latency;;
    stop_monitor_latency) stop_monitor_latency;;
esac