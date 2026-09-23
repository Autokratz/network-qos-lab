#!/bin/bash
# Network performance lab: NETWORK 2 (Remote branch, site-to-site VPN over WAN)
# WAN/VPN saturation -> time-based backup throttling -> daytime recovery.
if [ -z "$LAB_NS" ]; then exec env LAB_NS=1 unshare -r --net --mount --fork "$0" "$@"; fi
set -u

source "$(dirname "$0")/common.sh"
trap cleanup_all EXIT

LOG2="$DATA/n2_shot2_vpn_saturation.txt"
LOG4="$DATA/n2_shot4_time_policy.txt"
LOG6="$DATA/n2_shot6_recovery.txt"
: > "$LOG2"; : > "$LOG4"; : > "$LOG6"
LOG="$LOG2"
KD=$(mktemp -d)

say() { echo "$*" >> "$LOG"; }
cmd() { local ns=$1 host=$2; shift 2; echo "${host}# $*" >> "$LOG"; insh "$ns" "$*" >> "$LOG" 2>&1; echo >> "$LOG"; }

WAN_KBPS=20000
WAN_BPS=20000000

# ---------------------------------------------------------------- topology
echo "[net2] building topology..."
mkns BR; mkns HQ; mkns BKP; mkns WRK; mkns CLD

link BR Gi0-1 BKP eth0      # branch NAS / cloud-backup agent
link BR Gi0-2 WRK eth0      # branch staff workstation
link BR Gi0-0 HQ  Gi0-0     # WAN uplink (20 Mbps business broadband)
link HQ Gi0-1 CLD eth0      # HQ / cloud data-centre server

insh BR "ip link add br0 type bridge && ip link set Gi0-1 master br0 && \
         ip link set Gi0-2 master br0 && ip addr add 10.20.0.1/24 dev br0 && \
         ip link set br0 up && ip addr add 203.0.113.1/30 dev Gi0-0 && \
         sysctl -qw net.ipv4.ip_forward=1"
insh HQ "ip addr add 203.0.113.2/30 dev Gi0-0 && ip addr add 10.30.0.1/30 dev Gi0-1 && \
         sysctl -qw net.ipv4.ip_forward=1"
insh BKP "ip addr add 10.20.0.50/24 dev eth0 && ip route add default via 10.20.0.1"
insh WRK "ip addr add 10.20.0.60/24 dev eth0 && ip route add default via 10.20.0.1"
insh CLD "ip addr add 10.30.0.2/30 dev eth0 && ip route add default via 10.30.0.1"

# WAN pipe: 20 Mbps each way with 15 ms provider latency
for spec in "BR Gi0-0" "HQ Gi0-0"; do
  set -- $spec
  insh "$1" "tc qdisc add dev $2 root handle 1: htb default 10"
  insh "$1" "tc class add dev $2 parent 1: classid 1:10 htb rate 20mbit ceil 20mbit"
  insh "$1" "tc qdisc add dev $2 parent 1:10 handle 10: netem delay 15ms limit 2000"
done

# ---------------------------------------------------------------- IPsec-equivalent site-to-site VPN (WireGuard)
echo "[net2] bringing up site-to-site VPN tunnel..."
umask 077
# keys are fed on stdin: the AppArmor policy that covers unprivileged user
# namespaces on this host denies wg(8) read access to ordinary key files.
BRKEY=$(wg genkey); BRPUB=$(printf '%s' "$BRKEY" | wg pubkey)
HQKEY=$(wg genkey); HQPUB=$(printf '%s' "$HQKEY" | wg pubkey)

insh BR "ip link add wg0 type wireguard"
insh BR "printf '%s' '$BRKEY' | wg set wg0 private-key /dev/stdin listen-port 51820 \
            peer $HQPUB allowed-ips 10.30.0.0/30,172.16.10.2/32 \
            endpoint 203.0.113.2:51820 persistent-keepalive 25"
insh BR "ip addr add 172.16.10.1/30 dev wg0 && ip link set wg0 up && \
         ip route add 10.30.0.0/30 dev wg0"

insh HQ "ip link add wg0 type wireguard"
insh HQ "printf '%s' '$HQKEY' | wg set wg0 private-key /dev/stdin listen-port 51820 \
            peer $BRPUB allowed-ips 10.20.0.0/24,172.16.10.1/32 \
            endpoint 203.0.113.1:51820 persistent-keepalive 25"
insh HQ "ip addr add 172.16.10.2/30 dev wg0 && ip link set wg0 up && \
         ip route add 10.20.0.0/24 dev wg0"

insh CLD "iperf3 -s -D -p 5201"; insh CLD "iperf3 -s -D -p 5202"
sleep 2
VPN_UP=0
for _try in $(seq 1 12); do
  if insh BKP "ping -c 2 -W 2 10.30.0.2" >/dev/null 2>&1; then VPN_UP=1; break; fi
  sleep 2
done
if [ "$VPN_UP" -eq 0 ]; then
  echo "[net2] FATAL: no VPN path - diagnostics:"
  echo "-- keys --"; echo "BRPUB=$BRPUB"; echo "HQPUB=$HQPUB"
  echo "-- BR wg --";      insh BR "wg show"
  echo "-- HQ wg --";      insh HQ "wg show"
  echo "-- BR routes --";  insh BR "ip route"
  echo "-- BR addr --";    insh BR "ip -br addr"
  echo "-- HQ routes --";  insh HQ "ip route"
  echo "-- BR fwd --";     insh BR "sysctl net.ipv4.ip_forward"
  echo "-- BKP->br0 --";   insh BKP "ping -c1 -W2 10.20.0.1"    2>&1 | tail -2
  echo "-- BR->tun --";    insh BR  "ping -c1 -W2 172.16.10.2"  2>&1 | tail -2
  echo "-- BR->cld --";    insh BR  "ping -c1 -W2 10.30.0.2"    2>&1 | tail -2
  echo "-- HQ->cld --";    insh HQ  "ping -c1 -W2 10.30.0.2"    2>&1 | tail -2
  exit 1
fi
echo "[net2] tunnel established."

sample() { # sample <ns> <if> <csv> <secs> <link_bps>
  local ns=$1 ifc=$2 f=$3 dur=$4 rate=$5 t prx ptx crx ctx
  echo "second,rx_bps,tx_bps,util_pct" > "$f"
  read -r prx ptx < <(ctr "$ns" "$ifc")
  for ((t=1;t<=dur;t++)); do
    sleep 1
    read -r crx ctx < <(ctr "$ns" "$ifc")
    local rb=$(( (crx-prx)*8 )) tb=$(( (ctx-ptx)*8 ))
    echo "$t,$rb,$tb,$(awk -v a=$tb -v r=$rate 'BEGIN{printf "%.1f",(a/r)*100}')" >> "$f"
    prx=$crx; ptx=$ctx
  done
}

# ================================================================ SHOT 2 : midday sync saturating the VPN uplink
echo "[net2] PHASE A - unrestricted cloud backup over the VPN (55 s)..."
sample BR Gi0-0 "$DATA/n2_util_saturated.csv" 55 $WAN_BPS &
SPID=$!
sleep 5
insh BKP "iperf3 -c 10.30.0.2 -p 5201 -t 45 -P 4" > "$DATA/n2_backup_before.txt" 2>&1 &
sleep 2
insh WRK "ping -c 30 -i 0.5 -W 2 10.30.0.2" > "$DATA/n2_ping_before.txt" 2>&1 &
sleep 12
insh BR "bash $BASE/lab/wan-load-report.sh Gi0-0 $WAN_KBPS 5" > "$DATA/n2_report_before.txt" 2>&1
WAN_STATS=$(insh BR "ip -s link show dev Gi0-0")
WG_STATS=$(insh BR "wg show")
WG_LINK=$(insh BR "ip -s link show dev wg0")
wait $SPID

PEAK2=$(awk -F, 'NR>1 && $4>m {m=$4} END{printf "%.1f", m}' "$DATA/n2_util_saturated.csv")
echo "[net2] peak WAN utilisation: ${PEAK2}%"

LOG="$LOG2"
say "===== NETWORK 2 : BRANCH WAN / SITE-TO-SITE VPN - MIDDAY CLOUD SYNC ====="
say "Device: BR-RTR-01   WAN Gi0-0 (20 Mbps)   Tunnel wg0 -> HQ 203.0.113.2"
say ""
echo "BR-RTR-01# wan-load-report Gi0-0 20000 5      (live counters -> IOS-style load)" >> "$LOG"
cat "$DATA/n2_report_before.txt" >> "$LOG"; echo >> "$LOG"
echo "BR-RTR-01# ip -s link show dev Gi0-0          (WAN interface statistics)" >> "$LOG"
echo "$WAN_STATS" >> "$LOG"; echo >> "$LOG"
echo "BR-RTR-01# wg show                            (site-to-site tunnel status/volume)" >> "$LOG"
echo "$WG_STATS" >> "$LOG"; echo >> "$LOG"
echo "BR-RTR-01# ip -s link show dev wg0            (tunnel interface statistics)" >> "$LOG"
echo "$WG_LINK" >> "$LOG"; echo >> "$LOG"
echo "WRK-PC-60# ping -c 30 10.30.0.2               (staff app response during the sync)" >> "$LOG"
tail -4 "$DATA/n2_ping_before.txt" >> "$LOG"; echo >> "$LOG"
say "PEAK WAN EGRESS = ${PEAK2}% of 20 Mbps  --> UPLINK SATURATED BY BACKUP TRAFFIC"

# ================================================================ SHOT 4 : time-based policy
echo "[net2] PHASE B - applying time-based backup restriction..."
# 5% of the 20 Mbps uplink = 1 Mbps = 125 kbytes/second
insh BR "nft -f $BASE/lab/branch-wan-policy.nft"

# Matching shaper on the tunnel (pre-encryption, so inner addresses are visible)
insh BR "tc qdisc add dev wg0 root handle 1: htb default 30 r2q 10"
insh BR "tc class add dev wg0 parent 1:  classid 1:1  htb rate 20mbit ceil 20mbit"
insh BR "tc class add dev wg0 parent 1:1 classid 1:20 htb rate 1mbit  ceil 1mbit  prio 2"
insh BR "tc class add dev wg0 parent 1:1 classid 1:30 htb rate 19mbit ceil 20mbit prio 1"
insh BR "tc filter add dev wg0 parent 1: protocol ip prio 1 u32 match ip src 10.20.0.50/32 flowid 1:20"

LOG="$LOG4"
say "===== NETWORK 2 : TIME-BASED BANDWIDTH THROTTLING (CLOUD BACKUP) ====="
say "Uplink 20 Mbps.  Office-hours cap for backup host 10.20.0.50 = 1 Mbps (5%)"
say ""
cmd BR "BR-RTR-01" "nft list ruleset"
cmd BR "BR-RTR-01" "tc class show dev wg0"
cmd BR "BR-RTR-01" "tc filter show dev wg0"

# ================================================================ SHOT 6 : daytime recovery
echo "[net2] PHASE C - daytime behaviour with the policy in force (50 s)..."
sample BR Gi0-0 "$DATA/n2_util_recovered.csv" 50 $WAN_BPS &
SPID=$!
sleep 4
# backup agent still tries to run - policy holds it to 5%
insh BKP "iperf3 -c 10.30.0.2 -p 5201 -t 40 -P 4" > "$DATA/n2_backup_after.txt" 2>&1 &
sleep 2
# normal business application traffic
insh WRK "iperf3 -c 10.30.0.2 -p 5202 -u -b 1200k -t 35" > "$DATA/n2_biz_after.txt" 2>&1 &
insh WRK "ping -c 30 -i 0.5 -W 2 10.30.0.2" > "$DATA/n2_ping_after.txt" 2>&1
sleep 3
insh BR "bash $BASE/lab/wan-load-report.sh Gi0-0 $WAN_KBPS 5" > "$DATA/n2_report_after.txt" 2>&1
NFT_CTRS=$(insh BR "nft list chain inet BRANCH_WAN_POLICY FORWARD")
TC_AFTER=$(insh BR "tc -s class show dev wg0")
wait $SPID

LOG="$LOG6"
say "===== NETWORK 2 : DAYTIME BANDWIDTH RECOVERY (POLICY IN FORCE) ====="
say "Backup relocated to the 22:00-05:00 window; office-hours attempts are policed to 5%"
say ""
echo "BR-RTR-01# wan-load-report Gi0-0 20000 5      (WAN load during business hours)" >> "$LOG"
cat "$DATA/n2_report_after.txt" >> "$LOG"; echo >> "$LOG"
echo "BR-RTR-01# nft list chain inet BRANCH_WAN_POLICY FORWARD   (policer hit counters)" >> "$LOG"
echo "$NFT_CTRS" >> "$LOG"; echo >> "$LOG"
echo "BR-RTR-01# tc -s class show dev wg0           (backup class held at 1 Mbps)" >> "$LOG"
echo "$TC_AFTER" >> "$LOG"; echo >> "$LOG"
echo "WRK-PC-60# ping -c 30 10.30.0.2               (staff app response, business hours)" >> "$LOG"
tail -4 "$DATA/n2_ping_after.txt" >> "$LOG"; echo >> "$LOG"

# ---------------------------------------------------------------- accelerated 24-hour profile
echo "[net2] PHASE D - accelerated 24-hour traffic profile (1 simulated hour = 2 s)..."
echo "hour,tx_bps,util_pct" > "$DATA/n2_24h_profile.csv"
# Model the scheduler: outside 09:00-17:00 the office-hours policer does not
# apply, so the relocated backup job is free to use the full uplink. The
# lab-verification rule (which has no time match) is withdrawn for this run.
insh BR "nft flush chain inet BRANCH_WAN_POLICY FORWARD"
insh BR "tc class change dev wg0 parent 1:1 classid 1:20 htb rate 19mbit ceil 20mbit prio 2"
for h in $(seq 0 23); do
  case $h in
    22|23|0|1|2|3|4) RATE=19000k; SRC=BKP; PORT=5201 ;;   # scheduled backup window
    5)               RATE=9000k;  SRC=BKP; PORT=5201 ;;   # tail of the backup job
    6|7|20|21)       RATE=1500k;  SRC=WRK; PORT=5202 ;;   # fringe hours
    *)               RATE=2400k;  SRC=WRK; PORT=5202 ;;   # 08:00-19:00 business traffic
  esac
  read -r _ t0 < <(ctr BR Gi0-0)
  insh $SRC "iperf3 -c 10.30.0.2 -p $PORT -u -b $RATE -t 2 --forceflush" >/dev/null 2>&1
  read -r _ t1 < <(ctr BR Gi0-0)
  BPS=$(( (t1-t0)*8/2 ))
  echo "$h,$BPS,$(awk -v a=$BPS -v r=$WAN_BPS 'BEGIN{printf "%.1f",(a/r)*100}')" >> "$DATA/n2_24h_profile.csv"
done

rm -rf "$KD"
echo "[net2] done."
