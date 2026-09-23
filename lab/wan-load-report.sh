#!/bin/bash
# wan-load-report - lab utility.
# Samples live kernel interface counters (netlink) for <secs> and prints an
# IOS-style load summary. All figures are MEASURED, not simulated.
# usage: wan-load-report <iface> <link_kbps> [secs]
IF=${1:?iface}; BW_KBPS=${2:?link kbps}; SECS=${3:-5}

read_ctr() { ip -s link show dev "$IF" | awk '/^ *RX:/{getline; rx=$1} /^ *TX:/{getline; tx=$1} END{print rx+0, tx+0}'; }

read -r RX0 TX0 < <(read_ctr)
sleep "$SECS"
read -r RX1 TX1 < <(read_ctr)

STATE=$(ip -br link show dev "$IF" | awk '{print $2}')
DROPS=$(ip -s link show dev "$IF" | awk '/^ *TX:/{getline; print $4+0}')
ERRS=$(ip -s link show dev "$IF" | awk '/^ *TX:/{getline; print $3+0}')

awk -v rx0="$RX0" -v tx0="$TX0" -v rx1="$RX1" -v tx1="$TX1" -v s="$SECS" \
    -v bw="$BW_KBPS" -v ifc="$IF" -v st="$STATE" -v dr="$DROPS" -v er="$ERRS" 'BEGIN{
  rbps=(rx1-rx0)*8/s; tbps=(tx1-tx0)*8/s; cap=bw*1000;
  rl=rbps/cap*255; tl=tbps/cap*255;
  if (rl>255) rl=255; if (tl>255) tl=255;
  printf "%s is up, line protocol is %s\n", ifc, (st=="UP"?"up":tolower(st));
  printf "  MTU 1500 bytes, BW %d Kbit/sec, sampling window %d sec\n", bw, s;
  printf "  reliability 255/255, txload %d/255, rxload %d/255\n", tl+0.5, rl+0.5;
  printf "  %d second input  rate %d bits/sec  (%.1f%% of link)\n", s, rbps, rbps/cap*100;
  printf "  %d second output rate %d bits/sec  (%.1f%% of link)\n", s, tbps, tbps/cap*100;
  printf "  output errors %d, output drops %d\n", er, dr;
}'
