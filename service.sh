#!/system/bin/sh
MODDIR=${0%/*}
BINDIR="$MODDIR/bin"
DATADIR="/data/adb/magic_v2ray"
STUB_DIR=/dev/sysctl_stubs

# Prepare working dir
rm -rf "$STUB_DIR"
mkdir -p "$STUB_DIR"
mount -t tmpfs -o "mode=0755,context=u:object_r:proc_net:s0" proc "$STUB_DIR"

grep_prop() {
  local REGEX="s/^$1=//p"
  shift
  local FILES=$@
  [ -z "$FILES" ] && FILES="$MODDIR/module.prop"
  cat $FILES 2>/dev/null | dos2unix | sed -n "$REGEX" | head -n 1
}

rm -rf "$DATADIR/xray.log"
rm -rf "$DATADIR/tun2socks.log"
XRAY_LOG="$DATADIR/xray.log"
TUN2SOCKS_LOG=/dev/null
IP_HUNT_FILE="$DATADIR/ip_hunt.list"
if [ "$(grep_prop debug)" = "1" ]; then
    set -x
    TUN2SOCKS_LOG="$DATADIR/tun2socks.log"
fi
exec > "$DATADIR/service.log" 2>&1

PIDFILE="$STUB_DIR/run/xray.pid"
TIME_RES_FILE="$STUB_DIR/run/time_res"
ADDR_INFO_FILE="$STUB_DIR/run/addr_info"

# Control pipe for receiving commands from the UI or other components
PIPE_FILE="$STUB_DIR/run/control.pipe"

rm -rf "$STUB_DIR/run"
mkdir -p "$STUB_DIR/run"
mkfifo "$PIPE_FILE"
XRAY_PID=0
TUN2SOCKS_PID=0
MONITOR_PID=0

ip="/system/bin/ip"
iptables="/system/bin/iptables"
ip6tables="/system/bin/ip6tables"
am="/system/bin/am"
settings="/system/bin/settings"

RULE_PRIORITY=1000
FWMARK=255
TUN_NAME="xraytun0"
TUN_ADDR="127.17.1.3"
TUN_PORT="808"

get_status() {
    if [ -f "$PIDFILE" ]; then
        PID=$(cat "$PIDFILE")
        STAT_XRAY_EXE=$(stat -L -c "%D:%i" "/proc/$PID/exe")
        STAT_XRAY_BIN=$(stat -L -c "%D:%i" "$MODDIR/bin/xray")

        if kill -0 "$PID" && [ "$STAT_XRAY_EXE" = "$STAT_XRAY_BIN" ]; then
            return 0
        fi
    fi
    return 1
}

lock_sysctl() {
    local value="$1"
    local target_path="$2"
    local filedir=$(dirname "$target_path")
    local filename=$(basename "$target_path")
    local stub_path="$STUB_DIR/$filedir"
    local stub_file="$stub_path/$filename"
    local current_val="$(cat "$target_path")" 

    mkdir -p "$stub_path"
    echo "$current_val" > "$stub_file"
    echo "$value" > "$target_path"

    chown $(stat -c '%u:%g' "$target_path") "$stub_file"
    chcon $(stat -Z -c '%C' "$target_path") "$stub_file" # Just in case

    mount -o bind "$stub_file" "$target_path"
}

lock_xraytun0() {
    if [ -e "/proc/sys/net/ipv4/conf/$TUN_NAME/rp_filter" ]; then
        echo "0" > "/proc/sys/net/ipv4/conf/$TUN_NAME/rp_filter"
    fi
}

read_table_index() {
    local iface=$1
    local error=1

    cat /data/misc/net/rt_tables | while read -r index name; do
        if [[ "$name" = "$iface" ]]; then
            echo $index
            error=0
        fi
    done

    return $error
}

get_active_interface() {
    # Ask the kernel the route to 8.8.8.8
    local iface=$($ip route get 8.8.8.8 2>/dev/null | grep -oE 'dev [^ ]+' | awk '{print $2}')
    if [ ! -z "$iface" ]; then
        echo "$iface"
        return 0
    fi
    
    return 1
}

remove_mark_rule() {
    $ip rule del fwmark $FWMARK priority $RULE_PRIORITY
    $ip -6 rule del fwmark $FWMARK priority $RULE_PRIORITY
}

apply_mark_rule() {
    local iface="$1"

    [ -z "$iface" ] && return 1

    remove_mark_rule

    local iface_index="$(read_table_index "$iface")"

    [ -z "$iface_index" ] && return 1

    $ip rule add fwmark $FWMARK table "$iface_index" priority $RULE_PRIORITY
    $ip -6 rule add fwmark $FWMARK table "$iface_index" priority $RULE_PRIORITY
    echo "Applied: fwmark $FWMARK -> table $iface_index ($iface)"
    return 0
}

network_reset() {
    echo "Reset the mobile network"
    # Airplane mode kills all radios at once—Wi-Fi, Bluetooth, and cellular
    # which breaks background services and active local networks. 
    # Killing just the phone process targets only the mobile data stack cleanly
    # without disrupting everything else.
    # To be honest, we can use pkill -f com.android.phone here :>
    # But it will kill any process with the name com.android.phone
    for pid_dir in /proc/[0-9]*; do
        [ -d "$pid_dir" ] || continue
        uid=$(stat -c '%u' "$pid_dir" 2>/dev/null)
        if [ "$uid" = "1001" ]; then
            pid="${pid_dir##*/}"
            if [ -f "$pid_dir/cmdline" ] && grep -q "com.android.phone" "$pid_dir/cmdline" 2>/dev/null; then
                echo "Killing com.android.phone (PID: $pid, UID: $uid)"
                kill -9 "$pid"
            fi
        fi
    done
}

is_mobile_data_iface() {
    local ifname="$1"
    case "$ifname" in
        rmnet*|ccmni*|pdp*|wwan*)
            return 0 # Mobile network interface
            ;;
        *)
            return 1
            ;;
    esac
}

check_ip_hunter() {
    local INET="$1"
    is_mobile_data_iface "$INET" || return 0
    [ ! -f "$IP_HUNT_FILE" ] && return 0
    local RAW_PREFIX_LIST="$(cat "$IP_HUNT_FILE" | tr -d '\r')"
    local IFS=";"
    local TARGET
    local CURRENT_IP="$($ip addr show $INET | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)"
    # Check for every prefix
    for TARGET in $RAW_PREFIX_LIST; do
        case "$TARGET" in
            *.) ;;
            *) TARGET="$TARGET." ;;
        esac
        case "$CURRENT_IP." in
            "$TARGET"*)
                echo "Obtained IP: $CURRENT_IP"
                return 0
                ;;
        esac
    done
    echo "IP $CURRENT_IP does not match the expected list, continue..."
    network_reset &
    return 1
}

monitor_net_interfaces() {
    local cur=$(get_active_interface)
    local new=""
    if [ ! -z "$cur" ]; then
        echo "Initial active interface: $cur"
        # apply iptables rules for the first time
        apply_mark_rule "$cur"
    else
        echo "No active interface detected at startup."
    fi
    $ip monitor route | while read -r line; do
        new=$(get_active_interface)
        [ "$new" == "$cur" ] && continue
        if [ -z "$new" ]; then
            echo "Network interface disconnected"
            cur=""
            rm -rf "$ADDR_INFO_FILE" 
            continue
        fi
        echo "Network interface switched directly to: $new"
        apply_mark_rule "$new" && cur="$new"
        rm -rf "$ADDR_INFO_FILE"
        $ip addr show "$new" > "$ADDR_INFO_FILE"
        check_ip_hunter "$new"
    done
}

monitor_network_latency() {
    local URL="https://gstatic.com/generate_204"
    local TIME_RES
    touch "$TIME_RES_FILE"
    while [ -f "$TIME_RES_FILE" ]; do
        TIME_RES=$(${MODDIR}/bin/curl --socks5-hostname "${TUN_ADDR}:${TUN_PORT}" -s -w "%{time_starttransfer}" --max-time 3 -o /dev/null "$URL" 2>/dev/null)
        echo -n "$TIME_RES" > "$TIME_RES_FILE"
        sleep 1
    done
    rm -rf "$TIME_RES_FILE"
}

apply_routing_rules() {
    local retry=0
    local max_retry=10
    while [ $retry -lt $max_retry ]; do
        if $ip link show "$TUN_NAME" >/dev/null 2>&1; then
            break
        fi
        sleep 0.5
        retry=$((retry + 1))
    done

    # Lock down xraytun0 interface
    lock_xraytun0

    # =========================================================================
    # IPv4 CONFIGURATION
    # =========================================================================
    
    # Step 1: Assign IP address and set TUN device UP
    $ip addr add 198.18.0.1/15 dev $TUN_NAME
    $ip link set dev $TUN_NAME up
    $ip route replace default dev $TUN_NAME table 100

    # Step 2: Routing Rule for marked packets
    $ip rule add fwmark 1 table 100 priority 1010

    # Step 3: Create Mangle chain for local output traffic
    $iptables -t mangle -N XRAY_MARK
    $iptables -t mangle -A XRAY_MARK -m mark --mark $FWMARK -j RETURN
    $iptables -t mangle -A XRAY_MARK -d 127.0.0.0/8 -j RETURN
    $iptables -t mangle -A XRAY_MARK -d 10.0.0.0/8 -j RETURN
    $iptables -t mangle -A XRAY_MARK -d 172.16.0.0/12 -j RETURN
    $iptables -t mangle -A XRAY_MARK -d 192.168.0.0/16 -j RETURN
    $iptables -t mangle -A XRAY_MARK -d 169.254.0.0/16 -j RETURN       # Link-local
    $iptables -t mangle -A XRAY_MARK -d 224.0.0.0/4 -j RETURN         # Multicast
    $iptables -t mangle -A XRAY_MARK -d 240.0.0.0/4 -j RETURN         # Class E (Reserved)
    $iptables -t mangle -A XRAY_MARK -m owner --uid-owner 1000 -j MARK --set-xmark 1
    $iptables -t mangle -A XRAY_MARK -m owner --uid-owner 1052 -j MARK --set-xmark 1
    $iptables -t mangle -A XRAY_MARK -m owner --uid-owner 9999-2147483647 -j MARK --set-xmark 1
    $iptables -t mangle -A OUTPUT -j XRAY_MARK

    # Step 4: IPv4 Hotspot / Tethering Support
    # Filter FORWARD rules
    $iptables -I FORWARD -i $TUN_NAME -j ACCEPT
    $iptables -I FORWARD -o $TUN_NAME -j ACCEPT

    # Force DNS redirection for tethered clients to Cloudflare DNS
    $iptables -t nat -I PREROUTING ! -i $TUN_NAME -d 10.0.0.0/8 -p udp --dport 53 -j DNAT --to 1.1.1.1
    $iptables -t nat -I PREROUTING ! -i $TUN_NAME -d 172.16.0.0/12 -p udp --dport 53 -j DNAT --to 1.1.1.1
    $iptables -t nat -I PREROUTING ! -i $TUN_NAME -d 192.168.0.0/16 -p udp --dport 53 -j DNAT --to 1.1.1.1

    # PREROUTING Mangle rules for incoming hotspot traffic
    $iptables -t mangle -N HOTSPOT_PREROUTING
    $iptables -t mangle -A HOTSPOT_PREROUTING -d 10.0.0.0/8 -j RETURN
    $iptables -t mangle -A HOTSPOT_PREROUTING -d 172.16.0.0/12 -j RETURN
    $iptables -t mangle -A HOTSPOT_PREROUTING -d 192.168.0.0/16 -j RETURN
    $iptables -t mangle -A HOTSPOT_PREROUTING -d 127.0.0.0/8 -j RETURN
    $iptables -t mangle -A HOTSPOT_PREROUTING ! -i $TUN_NAME -p tcp -j MARK --set-xmark 1
    $iptables -t mangle -A HOTSPOT_PREROUTING ! -i $TUN_NAME -p udp -j MARK --set-xmark 1
    $iptables -t mangle -I PREROUTING 1 -j HOTSPOT_PREROUTING

    # IP Routing rules for tethering private subnets
    $ip rule add iif lo goto 6000 pref 5000
    $ip rule add iif $TUN_NAME lookup main suppress_prefixlength 0 pref 5010
    $ip rule add iif $TUN_NAME goto 6000 pref 5020
    # Bypass LAN
    $ip rule add to 10.0.0.0/8 lookup main pref 5025
    $ip rule add to 172.16.0.0/12 lookup main pref 5026
    $ip rule add to 192.168.0.0/16 lookup main pref 5027
    # Redirect Hotspot to table 100
    $ip rule add from 10.0.0.0/8 lookup 100 pref 5030
    $ip rule add from 172.16.0.0/12 lookup 100 pref 5040
    $ip rule add from 192.168.0.0/16 lookup 100 pref 5050
    $ip rule add nop pref 6000

    # Clamp TCP MSS to prevent fragmentation issues over VPN/TUN
    $iptables -t mangle -I FORWARD -o $TUN_NAME -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1350

    # Hide proxy port from non-system apps
    $iptables -I OUTPUT -p tcp --dport $TUN_PORT -d $TUN_ADDR -m owner --uid-owner 9999-2147483647 -j REJECT --reject-with tcp-reset


    # =========================================================================
    # IPv6 CONFIGURATION
    # =========================================================================

    # Step 1: Assign IPv6 address and default route
    $ip -6 addr add fdfe:dcba:9876::1/64 dev $TUN_NAME
    $ip -6 route replace default dev $TUN_NAME table 100

    # Step 2: Routing Rule for marked IPv6 packets
    $ip -6 rule add fwmark 1 table 100 priority 1010

    # Step 3: Create Mangle chain for local IPv6 output traffic
    $ip6tables -t mangle -N XRAY_MARK
    $ip6tables -t mangle -A XRAY_MARK -m mark --mark $FWMARK -j RETURN
    $ip6tables -t mangle -A XRAY_MARK -d ::1/128 -j RETURN
    $ip6tables -t mangle -A XRAY_MARK -d fe80::/10 -j RETURN
    $ip6tables -t mangle -A XRAY_MARK -d fc00::/7 -j RETURN
    $ip6tables -t mangle -A XRAY_MARK -d ff00::/8 -j RETURN
    $ip6tables -t mangle -A XRAY_MARK -m owner --uid-owner 1000 -j MARK --set-xmark 1
    $ip6tables -t mangle -A XRAY_MARK -m owner --uid-owner 1052 -j MARK --set-xmark 1
    $ip6tables -t mangle -A XRAY_MARK -m owner --uid-owner 9999-2147483647 -j MARK --set-xmark 1
    $ip6tables -t mangle -A OUTPUT -j XRAY_MARK

    # Step 4: IPv6 Hotspot / Tethering Support
    # Filter FORWARD rules
    $ip6tables -I FORWARD -i $TUN_NAME -j ACCEPT
    $ip6tables -I FORWARD -o $TUN_NAME -j ACCEPT

    # PREROUTING Mangle rules for incoming IPv6 hotspot traffic
    $ip6tables -t mangle -N HOTSPOT_PREROUTING
    $ip6tables -t mangle -A HOTSPOT_PREROUTING -p udp --dport 53 -j MARK --set-xmark 1
    $ip6tables -t mangle -A HOTSPOT_PREROUTING -p tcp --dport 53 -j MARK --set-xmark 1
    $ip6tables -t mangle -A HOTSPOT_PREROUTING ! -i $TUN_NAME -d ::1/128 -j RETURN
    $ip6tables -t mangle -A HOTSPOT_PREROUTING ! -i $TUN_NAME -d fe80::/10 -j RETURN
    $ip6tables -t mangle -A HOTSPOT_PREROUTING ! -i $TUN_NAME -d fc00::/7 -j RETURN
    $ip6tables -t mangle -A HOTSPOT_PREROUTING ! -i $TUN_NAME -j MARK --set-xmark 1
    $ip6tables -t mangle -I PREROUTING 1 -j HOTSPOT_PREROUTING

    # Clamp IPv6 TCP MSS
    $ip6tables -t mangle -I FORWARD -o $TUN_NAME -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1330
}

clear_routing_rules() {
    # =========================================================================
    # CLEAR IPv4 RULES
    # =========================================================================
    
    # Delete local mangle output rules
    $iptables -t mangle -D OUTPUT -j XRAY_MARK
    $iptables -t mangle -F XRAY_MARK
    $iptables -t mangle -X XRAY_MARK
    $ip rule del fwmark 1 table 100 priority 1010
    $iptables -D OUTPUT -p tcp --dport $TUN_PORT -d $TUN_ADDR -m owner --uid-owner 9999-2147483647 -j REJECT --reject-with tcp-reset

    # Delete hotspot rules & ip rules
    $ip rule del pref 5000
    $ip rule del pref 5010
    $ip rule del pref 5020
    $ip rule del pref 5025
    $ip rule del pref 5026
    $ip rule del pref 5027
    $ip rule del pref 5030
    $ip rule del pref 5040
    $ip rule del pref 5050
    $ip rule del pref 6000

    $iptables -D FORWARD -i $TUN_NAME -j ACCEPT
    $iptables -D FORWARD -o $TUN_NAME -j ACCEPT

    $iptables -D PREROUTING -t nat ! -i $TUN_NAME -d 10.0.0.0/8 -p udp --dport 53 -j DNAT --to 1.1.1.1
    $iptables -D PREROUTING -t nat ! -i $TUN_NAME -d 172.16.0.0/12 -p udp --dport 53 -j DNAT --to 1.1.1.1
    $iptables -D PREROUTING -t nat ! -i $TUN_NAME -d 192.168.0.0/16 -p udp --dport 53 -j DNAT --to 1.1.1.1

    $iptables -t mangle -D PREROUTING -j HOTSPOT_PREROUTING
    $iptables -t mangle -F HOTSPOT_PREROUTING
    $iptables -t mangle -X HOTSPOT_PREROUTING

    $iptables -t mangle -D FORWARD -o $TUN_NAME -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1350


    # =========================================================================
    # CLEAR IPv6 RULES
    # =========================================================================
    
    # Delete local mangle output rules
    $ip6tables -t mangle -D OUTPUT -j XRAY_MARK
    $ip6tables -t mangle -F XRAY_MARK
    $ip6tables -t mangle -X XRAY_MARK
    $ip -6 rule del fwmark 1 table 100 priority 1010

    # Delete hotspot rules
    $ip6tables -D FORWARD -i $TUN_NAME -j ACCEPT
    $ip6tables -D FORWARD -o $TUN_NAME -j ACCEPT

    $ip6tables -t mangle -D PREROUTING -j HOTSPOT_PREROUTING
    $ip6tables -t mangle -F HOTSPOT_PREROUTING
    $ip6tables -t mangle -X HOTSPOT_PREROUTING

    $ip6tables -t mangle -D FORWARD -o $TUN_NAME -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1330

    # Down the TUN device
    $ip link set dev $TUN_NAME down
}

mount_proc_with_name() {
    local PID="$1"
    local NAME="$2"
    if [ -d "/proc/$PID" ] && [ ! -e "$STUB_DIR/proc/$NAME" ]; then
        mkdir -p "$STUB_DIR/proc/$NAME"
        mount --bind "/proc/$PID" "$STUB_DIR/proc/$NAME"
        echo "Mounted /proc/$PID to $STUB_DIR/proc/$NAME"
    fi
}

umount_proc_with_name() {
    local NAME="$1"
    umount -l "$STUB_DIR/proc/$NAME" 2>/dev/null || true
    rm -rf "$STUB_DIR/proc/$NAME"
    echo "Unmounted $STUB_DIR/proc/$NAME"
}

is_proc_running() {
    local NAME="$1"
    if [ -e "$STUB_DIR/proc/$NAME/exe" ]; then
        return 0
    else
        # When the process is dead, stat $STUB_DIR/proc/$NAME will fail
        # as well as anything inside it, so we can safely assume that the process is not running.
        return 1
    fi
}

do_job() {
    local content="$1"
    if [ "$content" = "wait" ]; then
        : # Do nothing
        return 0
    fi
    if [ "$content" = "apply_cur_iface" ]; then
        local cur_iface=$(get_active_interface)
        if [ ! -z "$cur_iface" ]; then
            echo "Applying routing rules for current active interface: $cur_iface"
            apply_mark_rule "$cur_iface"
        else
            echo "No active interface detected to apply routing rules."
        fi
        return 0
    fi
    if [ "$content" = "start" ]; then
        if is_proc_running "xray"; then
            echo "Xray is already running with PID $XRAY_PID"
        else
            # Start Xray core
            "$BINDIR/xray" run -c "$DATADIR/config.json" </dev/null &>"$XRAY_LOG" &
            XRAY_PID=$!
            echo "$XRAY_PID" > "$PIDFILE"
            echo "Xray is running with PID $XRAY_PID"

            mount_proc_with_name "$XRAY_PID" "xray"
            apply_routing_rules
        fi
        return 0
    fi
    if [ "$content" = "stop" ]; then
        clear_routing_rules 2>/dev/null

        if is_proc_running "xray"; then
            kill -9 "$XRAY_PID"
            XRAY_PID=0
        fi
        umount_proc_with_name "xray"
        rm -f "$PIDFILE"
        return 0
    fi
    if [ "$content" = "start_monitor" ]; then
        [ $MONITOR_PID -gt 0 ] && is_proc_running "monitor_net_interfaces" && kill -9 "$MONITOR_PID"
        MONITOR_PID=0
        monitor_net_interfaces &
        MONITOR_PID=$!
        mount_proc_with_name "$MONITOR_PID" "monitor_net_interfaces"
        echo "monitor_net_interfaces is running with PID $MONITOR_PID"
        return 0
    fi
    if [ "$content" = "stop_monitor" ]; then
        if [ $MONITOR_PID -gt 0 ] && is_proc_running "monitor_net_interfaces"; then
            kill -9 "$MONITOR_PID"
            echo "killed monitor_net_interfaces is with PID $MONITOR_PID"
        fi
        umount_proc_with_name "monitor_net_interfaces"
        MONITOR_PID=0
        return 0
    fi
    if [ "$content" = "start_monitor_latency" ]; then
        [ $MONITOR_PID -gt 0 ] && is_proc_running "monitor_network_latency" && kill -9 "$MONITOR_PID"
        MONITOR_PID=0
        monitor_network_latency &
        MONITOR_PID=$!
        mount_proc_with_name "$MONITOR_PID" "monitor_network_latency"
        echo "monitor_network_latency is running with PID $MONITOR_PID"
        return 0
    fi
    if [ "$content" = "stop_monitor_latency" ]; then
        if [ $MONITOR_PID -gt 0 ] && is_proc_running "monitor_network_latency"; then
            kill -9 "$MONITOR_PID"
            echo "killed monitor_network_latency is with PID $MONITOR_PID"
        fi
        umount_proc_with_name "monitor_network_latency"
        MONITOR_PID=0
        rm -rf "$TIME_RES_FILE"
        return 0
    fi
    if [ "$content" = "reset_mobile_network" ]; then
        local cur_iface=$(get_active_interface)
        if [ ! -z "$cur_iface" ]; then
            check_ip_hunter "$cur_iface"
        fi
        return 0
    fi
    return 1
}

{
while true; do
    if read -r line < "$PIPE_FILE"; then
        if [ -n "$line" ]; then
            if ! do_job "$line"; then
                echo "Unknown command: $line"
            fi
        fi
    fi
done
} &

# ===

{
while [ ! -f /data/misc/net/rt_tables ]; do
    sleep 1
done
lock_sysctl "1" "/proc/sys/net/ipv4/ip_forward"
lock_sysctl "1" "/proc/sys/net/ipv6/conf/all/forwarding"
lock_sysctl "1" "/proc/sys/net/ipv6/conf/default/forwarding"

lock_sysctl "0" "/proc/sys/net/ipv4/conf/all/rp_filter"
lock_sysctl "0" "/proc/sys/net/ipv4/conf/default/rp_filter"

echo "start_monitor" > "$PIPE_FILE"

until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 1
done
sleep 5

if [ ! -e /dev/net/tun ]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200
    chmod 666 /dev/net/tun
fi

# Start hev-socks5-tunnel
cat <<EOF  >"$STUB_DIR/run/tunnel.yml"
tunnel:
  name: $TUN_NAME
  mtu: 8500
  ipv4: 198.18.0.1
  ipv6: fdfe:dcba:9876::1

socks5:
  address: $TUN_ADDR
  port: $TUN_PORT
  udp: 'udp'
  mark: $FWMARK

misc:
  log-file: stderr
  log-level: warn
EOF

"$BINDIR/hev-socks5-tunnel" "$STUB_DIR/run/tunnel.yml" </dev/null &>"$TUN2SOCKS_LOG" &
TUN2SOCKS_PID=$!
echo "hev-socks5-tunnel is running with PID $TUN2SOCKS_PID"

if [ -e "$DATADIR/config.json" ]; then
    echo "Restart previous xray on boot"
    echo "start" > "$PIPE_FILE"
    echo "wait" > "$PIPE_FILE"
fi

} &
