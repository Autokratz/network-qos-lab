#!/bin/bash
# Network performance lab: shared lab helpers
# Runs entirely inside an unprivileged user+network namespace (no root needed).

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$BASE/out"
DATA="$BASE/data"
mkdir -p "$OUT" "$DATA"

declare -A NSPID

# Create a named network namespace backed by a sleeping holder process.
mkns() {
  local n=$1
  unshare --net -- sleep 100000 &
  NSPID[$n]=$!
  # wait for the namespace to exist
  local i=0
  while [ ! -e "/proc/${NSPID[$n]}/ns/net" ] && [ $i -lt 50 ]; do sleep 0.05; i=$((i+1)); done
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

cleanup_all() {
  for p in "${NSPID[@]}"; do kill "$p" 2>/dev/null; done
}
