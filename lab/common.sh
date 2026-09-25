#!/bin/bash
# Network performance lab: shared lab helpers
# Runs entirely inside an unprivileged user+network namespace (no root needed).

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$BASE/out"
DATA="$BASE/data"
mkdir -p "$OUT" "$DATA"

declare -A NSPID
declare -a IPERF_PIDFILES

# Create a named network namespace backed by a sleeping holder process.
mkns() {
  local n=$1
  unshare --net -- sleep 100000 &
  NSPID[$n]=$!
  # Wait for the namespace, then say so if it never appeared. Returning
  # success with a dead PID made every later step fail somewhere else.
  local i=0
  while [ ! -e "/proc/${NSPID[$n]}/ns/net" ] && [ $i -lt 50 ]; do sleep 0.05; i=$((i+1)); done
  if [ ! -e "/proc/${NSPID[$n]}/ns/net" ]; then
    echo "mkns: namespace '$n' never appeared." >&2
    echo "  On Ubuntu 24.04+ unprivileged user namespaces are restricted:" >&2
    echo "  sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0" >&2
    return 1
  fi
}

# Run a command inside a named namespace
inns() { local n=$1; shift; nsenter -t "${NSPID[$n]}" -n -- "$@"; }

# Run a shell string inside a named namespace
insh() { local n=$1; shift; nsenter -t "${NSPID[$n]}" -n -- bash -c "$*"; }

# Create a veth pair and place each end in a namespace with a chosen name.
# link nsA ifA nsB ifB
link() {
  local nsA=$1 ifA=$2 nsB=$3 ifB=$4
  ip link add "tmpA$$" type veth peer name "tmpB$$"
  ip link set "tmpA$$" netns "${NSPID[$nsA]}" name "$ifA"
  ip link set "tmpB$$" netns "${NSPID[$nsB]}" name "$ifB"
  inns "$nsA" ip link set "$ifA" up
  inns "$nsB" ip link set "$ifB" up
}

# Read RX/TX byte counters for an interface inside a namespace (netlink, ns-correct)
ctr() { # ctr <ns> <if>  -> "rxbytes txbytes"
  insh "$1" "ip -s link show dev $2" | awk '/^ *RX:/{getline; rx=$1} /^ *TX:/{getline; tx=$1} END{print rx+0, tx+0}'
}

# Servers started with `iperf3 -s -D` daemonise inside their namespace and are
# not children of this shell, so killing the holder alone orphaned them.
start_iperf() { # start_iperf <ns> <port>
  insh "$1" "iperf3 -s -D -p $2 --pidfile /tmp/iperf-$1-$2.pid"
  IPERF_PIDFILES+=("/tmp/iperf-$1-$2.pid")
}

cleanup_all() {
  for f in "${IPERF_PIDFILES[@]:-}"; do
    [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null
    rm -f "$f"
  done
  for p in "${NSPID[@]}"; do kill "$p" 2>/dev/null; done
}

# Transcript helpers. Both append to $LOG, which each lab script sets after
# sourcing this file; the value is read at call time, so a script may point
# $LOG at a different file between phases.
say() { echo "$*" >> "$LOG"; }

# Echo a device prompt line, run the command in its namespace, and record
# both in the transcript. Redirects are grouped so the file is opened once.
cmd() { # cmd <ns> <prompt> <command string>
  local ns=$1 host=$2; shift 2
  {
    echo "${host}# $*"
    insh "$ns" "$*" 2>&1
    echo
  } >> "$LOG"
}
