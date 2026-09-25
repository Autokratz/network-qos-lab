#!/bin/bash
# Network performance lab: NETWORK 1 (Head-Office campus LAN)
# Congestion -> QoS + EtherChannel -> post-optimisation verification.
# Self-elevates into an unprivileged user+net+mount namespace.
if [ -z "$LAB_NS" ]; then exec env LAB_NS=1 unshare -r --net --mount --fork "$0" "$@"; fi
set -u

# shellcheck source=lab/common.sh
source "$(dirname "$0")/common.sh"
trap cleanup_all EXIT

LOG1="$DATA/n1_shot1_congestion.txt"   # screenshot 1 transcript
LOG3="$DATA/n1_shot3_qos_lacp.txt"     # screenshot 3 transcript
LOG5="$DATA/n1_shot5_post.txt"         # screenshot 5 transcript
: > "$LOG1"; : > "$LOG3"; : > "$LOG5"
LOG="$LOG1"


# ---------------------------------------------------------------- topology
echo "[net1] building topology..."
mkns CORE; mkns ACC; mkns VOIP; mkns DATA_H; mkns SRV

link ACC Fa1-1 VOIP   eth0     # IP phone / softphone
link ACC Fa1-2 DATA_H eth0     # workstation + file-sync client
link ACC Gi0-1 CORE   Gi1-1    # uplink member 1
link ACC Gi0-2 CORE   Gi1-2    # uplink member 2
link CORE Gi0-0 SRV   eth0     # core -> voice/app server

# access switch: VLAN10 SVI as a bridge
insh ACC "ip link add br0 type bridge && \
          ip link set Fa1-1 master br0 && ip link set Fa1-2 master br0 && \
          ip addr add 10.10.0.1/24 dev br0 && ip link set br0 up && \
          ip addr add 10.10.9.1/30 dev Gi0-1 && \
          ip link set Gi0-2 down && \
          sysctl -qw net.ipv4.ip_forward=1 && \
          ip route add default via 10.10.9.2"

insh CORE "ip addr add 10.10.9.2/30 dev Gi1-1 && \
           ip addr add 10.10.8.1/30 dev Gi0-0 && \
           ip link set Gi1-2 down && \
           sysctl -qw net.ipv4.ip_forward=1 && \
           ip route add 10.10.0.0/24 via 10.10.9.1"

insh VOIP   "ip addr add 10.10.0.10/24 dev eth0 && ip route add default via 10.10.0.1"
insh DATA_H "ip addr add 10.10.0.20/24 dev eth0 && ip route add default via 10.10.0.1"
insh SRV    "ip addr add 10.10.8.2/30 dev eth0 && ip route add default via 10.10.8.1"

# Provider/core baseline latency: 10 ms each direction = 20 ms base RTT
insh CORE "tc qdisc add dev Gi0-0 root netem delay 10ms"
insh SRV  "tc qdisc add dev eth0  root netem delay 10ms"

# Access uplink = 10 Mbps with a deep tail-drop buffer (the congestion fault)
UPLINK_BPS=10000000
insh ACC  "tc qdisc add dev Gi0-1 root tbf rate 10mbit burst 32kb latency 120ms"
insh CORE "tc qdisc add dev Gi1-1 root tbf rate 10mbit burst 32kb latency 120ms"

start_iperf SRV 5201; start_iperf SRV 5202
sleep 1
insh VOIP "ping -c 2 -W 3 10.10.8.2" >/dev/null 2>&1 || { echo "[net1] FATAL: no path"; exit 1; }
echo "[net1] topology up."

# ---------------------------------------------------------------- sampler
sample() { # sample <ns> <if> <csv> <secs> <link_bps>
  local ns=$1 ifc=$2 f=$3 dur=$4 rate=$5 t prx ptx crx ctx
  echo "second,rx_bps,tx_bps,util_pct" > "$f"
  read -r prx ptx < <(ctr "$ns" "$ifc")
  for ((t=1;t<=dur;t++)); do
    sleep 1
    read -r crx ctx < <(ctr "$ns" "$ifc")
    local rb=$(( (crx-prx)*8 )) tb=$(( (ctx-ptx)*8 ))
    echo "$t,$rb,$tb,$(awk -v a="$tb" -v r="$rate" 'BEGIN{printf "%.1f",(a/r)*100}')" >> "$f"
    prx=$crx; ptx=$ctx
  done
}

# ================================================================ PHASE A
echo "[net1] PHASE A - peak-hour congestion (70 s)..."
sample ACC Gi0-1 "$DATA/n1_util_congested.csv" 70 $UPLINK_BPS &
SPID=$!
sleep 8
# bulk file-sync / imaging traffic from the workstation VLAN
insh DATA_H "iperf3 -c 10.10.8.2 -p 5201 -t 52 -P 4" > "$DATA/n1_bulk_before.txt" 2>&1 &
sleep 3
# RTP-like voice stream, unclassified (no QoS yet)
insh VOIP "iperf3 -c 10.10.8.2 -p 5202 -u -b 1M -t 40 -l 172" > "$DATA/n1_voice_before.txt" 2>&1 &
# latency / loss measurement during the peak
insh VOIP "ping -c 40 -i 0.5 -W 2 10.10.8.2" > "$DATA/n1_ping_before.txt" 2>&1
wait $SPID
CONG_QDISC=$(insh ACC "tc -s qdisc show dev Gi0-1")
CONG_LINK=$(insh ACC "ip -s link show dev Gi0-1")
# (load generators finish inside the sampling window; the namespace holder
#  processes are background jobs too, so a bare `wait` must not be used)

PEAK=$(awk -F, 'NR>1 && $4>m {m=$4} END{printf "%.1f", m}' "$DATA/n1_util_congested.csv")
echo "[net1] peak uplink utilisation: ${PEAK}%"

LOG="$LOG1"
say "===== NETWORK 1 : ACCESS-SWITCH UPLINK - PEAK HOUR (09:00-11:00) ====="
say "Device: ACC-SW-01  Uplink Gi0-1 -> CORE-SW-01 Gi1-1   Link rate: 10 Mbps"
say ""
say "ACC-SW-01# tc -s qdisc show dev Gi0-1        (interface queue / drop counters)"
say "$CONG_QDISC"; say ""
say "ACC-SW-01# ip -s link show dev Gi0-1         (interface error / drop statistics)"
say "$CONG_LINK"; say ""
say "VOIP-PHONE-10# ping -c 40 -i 0.5 10.10.8.2   (voice path to server, unclassified)"
cat "$DATA/n1_ping_before.txt" >> "$LOG"; say ""
say "VOIP-PHONE-10# iperf3 -c 10.10.8.2 -u -b 1M  (RTP-equivalent stream, loss report)"
tail -6 "$DATA/n1_voice_before.txt" >> "$LOG"; say ""
say "PEAK EGRESS UTILISATION ON Gi0-1 = ${PEAK}% of 10 Mbps  --> LINK SATURATED"

# ================================================================ PHASE B
echo "[net1] PHASE B - EtherChannel + QoS..."
for spec in "ACC Gi0-1 Gi0-2 10.10.9.1" "CORE Gi1-1 Gi1-2 10.10.9.2"; do
  # shellcheck disable=SC2086  # deliberate: $spec is a space-separated field list
  set -- $spec; ns=$1; m1=$2; m2=$3; addr=$4
  insh "$ns" "tc qdisc del dev $m1 root" 2>/dev/null
  insh "$ns" "ip addr flush dev $m1; ip link set $m1 down; ip link set $m2 down"
  insh "$ns" "ip link add bond0 type bond mode 802.3ad miimon 100 lacp_rate fast xmit_hash_policy layer3+4"
  insh "$ns" "ip link set $m1 master bond0 && ip link set $m2 master bond0"
  insh "$ns" "ip link set $m1 up; ip link set $m2 up; ip link set bond0 up"
  insh "$ns" "ip addr add ${addr}/30 dev bond0"
done
insh ACC  "ip route replace default via 10.10.9.2"
insh CORE "ip route replace 10.10.0.0/24 via 10.10.9.1"

# QoS: 20 Mbps aggregate (2 x 10 Mbps bundled), EF voice class gets strict priority
apply_qos() { # apply_qos <ns> <dev>
  local ns=$1 d=$2
  insh "$ns" "tc qdisc add dev $d root handle 1: htb default 20 r2q 10"
  insh "$ns" "tc class add dev $d parent 1:  classid 1:1  htb rate 20mbit ceil 20mbit"
  insh "$ns" "tc class add dev $d parent 1:1 classid 1:10 htb rate 5mbit  ceil 20mbit prio 0 burst 8k"
  insh "$ns" "tc class add dev $d parent 1:1 classid 1:20 htb rate 15mbit ceil 20mbit prio 1"
  insh "$ns" "tc qdisc add dev $d parent 1:10 handle 10: pfifo limit 16"
  insh "$ns" "tc qdisc add dev $d parent 1:20 handle 20: pfifo limit 200"
  # classify DSCP EF (46 / ToS 0xb8) -> priority voice class 1:10
  insh "$ns" "tc filter add dev $d parent 1: protocol ip prio 1 u32 match ip tos 0xb8 0xfc flowid 1:10"
  # classify DSCP AF31 (26 / ToS 0x68) signalling -> voice class as well
  insh "$ns" "tc filter add dev $d parent 1: protocol ip prio 2 u32 match ip tos 0x68 0xfc flowid 1:10"
}
apply_qos ACC bond0
apply_qos CORE bond0
sleep 6
insh VOIP "ping -c 2 -W 3 10.10.8.2" >/dev/null 2>&1 || echo "[net1] WARN: path down after bonding"

LOG="$LOG3"
say "===== NETWORK 1 : CONTROL MEASURES APPLIED (QoS + LINK AGGREGATION) ====="
say ""
cmd ACC "ACC-SW-01" "cat /proc/net/bonding/bond0"
cmd ACC "ACC-SW-01" "ip -d link show bond0 | head -6"
cmd ACC "ACC-SW-01" "tc class show dev bond0"
cmd ACC "ACC-SW-01" "tc filter show dev bond0"

# ================================================================ PHASE C
echo "[net1] PHASE C - post-optimisation verification (55 s)..."
sample ACC bond0 "$DATA/n1_util_optimised.csv" 55 20000000 &
SPID=$!
sleep 5
insh DATA_H "iperf3 -c 10.10.8.2 -p 5201 -t 45 -P 4" > "$DATA/n1_bulk_after.txt" 2>&1 &
sleep 3
insh VOIP "iperf3 -c 10.10.8.2 -p 5202 -u -b 1M -t 35 -l 172 -S 184" > "$DATA/n1_voice_after.txt" 2>&1 &
insh VOIP "ping -Q 0xb8 -c 40 -i 0.5 -W 2 10.10.8.2" > "$DATA/n1_ping_after.txt" 2>&1
wait $SPID
POST_CLASS=$(insh ACC "tc -s class show dev bond0")
# (load generators finish inside the sampling window; the namespace holder
#  processes are background jobs too, so a bare `wait` must not be used)

LOG="$LOG5"
say "===== NETWORK 1 : POST-OPTIMISATION VERIFICATION (same bulk load offered) ====="
say "Voice marked DSCP EF (0xb8) and policed into priority class 1:10 across bond0"
say ""
say "VOIP-PHONE-10# ping -Q 0xb8 -c 40 -i 0.5 10.10.8.2   (EF-marked voice path)"
cat "$DATA/n1_ping_after.txt" >> "$LOG"; say ""
say "VOIP-PHONE-10# iperf3 -c 10.10.8.2 -u -b 1M -S 184  (RTP-equivalent, EF marked)"
tail -6 "$DATA/n1_voice_after.txt" >> "$LOG"; say ""
say "ACC-SW-01# tc -s class show dev bond0                 (per-class service counters)"
say "$POST_CLASS"

echo "[net1] done."
