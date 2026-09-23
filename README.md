# network-qos-lab

**Two enterprise network faults, reproduced and fixed on real infrastructure, with every result measured.**

Voice RTT **152.5 ms → 20.0 ms** · jitter **1.289 ms → 0.002 ms** · WAN load **100.1% → 5.2%** · packet loss **3.33% → 0%**

Nothing here is simulated or mocked up. Two routed topologies are built from Linux network namespaces — real interfaces, real routing, real queueing, real encryption — and every counter, RTT, loss figure and utilisation point in this repository was measured by the kernel during a live run. The raw capture files are in `data/` and every number below can be diffed against them.

---

## Why this exists

Network configuration is easy to claim and hard to prove. So each lab follows the same three steps: **reproduce the documented fault, measure it, remediate it, measure again under an identical offered load.** The before and after captures are both committed.

Everything is built on free, open-source tooling and runs without root, using unprivileged user namespaces.

---

## Network 1 — Protecting voice inside a saturated uplink

A head-office campus LAN where VoIP and bulk data share a 10 Mbps access-layer uplink.

```
VOIP-PHONE-10 ─┐
               ├─ ACC-SW-01 ══ Gi0-1/Gi0-2 (LACP) ══ CORE-SW-01 ── SRV 10.10.8.2
WKSTN-DATA-20 ─┘        10 Mbps uplink                    10 ms each way
```

**The fault.** The access-layer uplink holds all traffic in a single deep tail-drop queue. Under a four-stream bulk transfer the queue fills, and voice waits behind bulk data in the same buffer.

**The fix.** HTB class-based shaping replaces the tail-drop queue, `u32` filters matching DSCP EF steer RTP voice into a priority class, and both switch uplinks are bonded with 802.3ad LACP.

### Before — peak hour, 10 Mbps uplink

| Metric | Value |
|---|---|
| Peak egress utilisation on Gi0-1 | **99.2%** |
| Interface queue | `dropped 128, overlimits 152544` |
| VoIP RTT (min/avg/max) | 128.4 / **152.5** / 165.1 ms |
| RTP-equivalent stream loss | 21 / 29,071 datagrams (0.072%) |

### After — QoS + EtherChannel, identical bulk load offered

| Metric | Value |
|---|---|
| Bundle | 802.3ad LACP, Gi0-1 + Gi0-2, both in Aggregator ID 1, LACP rate fast |
| VoIP RTT (min/avg/max) | 20.022 / **20.029** / 20.039 ms |
| VoIP packet loss | **0%** (ping) and 0 / 25,437 datagrams |
| Voice class 1:10 counters | 25,478 packets sent, **0 dropped** |

Latency fell **87%** while the same four-stream bulk transfer continued to run. The uplink still sits at roughly 99% utilisation — average throughput actually rose slightly. Nothing was throttled. Voice simply stopped sharing a queue with bulk data.

---

## Network 2 — Recovering a WAN link at 100% saturation

A remote branch reaching head office across a site-to-site VPN over a 20 Mbps WAN.

```
BKP-NAS-50 ─┐                    WAN 20 Mbps / 15 ms
            ├─ BR-RTR-01 ═════ wg0 tunnel ═════ HQ-RTR-01 ── CLOUD-SRV 10.30.0.2
WRK-PC-60 ──┘                203.0.113.0/30
```

**The fault.** An unscheduled NAS backup runs during business hours and pushes the tunnel past link capacity. Interactive traffic becomes unusable.

**The fix.** An nftables time-based policy caps backup traffic to a small share of the link inside business hours and releases it outside them. Business traffic is left untouched.

### Before — unrestricted midday cloud sync

| Metric | Value |
|---|---|
| WAN Gi0-0 output rate | 20,014,716 bit/s (**100.1%** of 20 Mbps), peak 100.7% |
| Derived load | **txload 255/255** |
| Tunnel volume | 46.69 MiB sent over `wg0`, handshake current |
| Staff app RTT during the sync | 199 / **713** / 1208 ms, **3.33% loss** |

### After — time-based policy in force

| Metric | Value |
|---|---|
| WAN Gi0-0 output rate | 1,049,385 bit/s (**5.2%** of 20 Mbps) |
| Derived load | **txload 13/255** |
| Policer counters | 70 packets / 170,536 bytes dropped by `BACKUP-CAP-…-5PCT` |
| Business traffic | 1,527 packets permitted, untouched |
| Staff app RTT | 30.1 / **30.3** / 30.8 ms, **0% loss** |
| 24-hour profile | 08:00–19:00 ≈ **13.1%**; 22:00–05:00 ≈ 100% |

---

## Linux mechanism → vendor equivalent

The lab is built on Linux, but every mechanism is chosen because it maps one-to-one onto vendor configuration. This table is the point of the repository.

| Lab mechanism | Cisco / vendor equivalent |
|---|---|
| `tc tbf` deep tail-drop queue on the uplink | congested access-layer uplink with an oversized interface buffer |
| `tc htb` classes + `u32` DSCP filters | `class-map` / `policy-map` with `priority` and `bandwidth` |
| DSCP EF (0xb8) match | `match dscp ef` for RTP voice |
| kernel bonding `mode 802.3ad` | EtherChannel / `channel-group X mode active` (LACP) |
| `/proc/net/bonding/bond0` | `show etherchannel summary` / `show lacp neighbor` |
| WireGuard `wg0` | IPsec site-to-site tunnel interface |
| `nftables` `meta hour` rule | time-based ACL (`time-range` + ACL) |
| `nft limit rate over … drop` | policer (`police cir …` / rate-limit) |
| `ip -s link`, `tc -s class` | `show interfaces`, `show policy-map interface` |
| `wan-load-report.sh` | derives `txload x/255`-style load from the same live counters |

---

## Honest notes on the evidence

Engineering credibility comes from stating the limits of your own measurements, so:

* **The screenshots are renderings of real captured console output**, not photographs of a screen. This desktop runs Wayland, which blocks silent screen capture, so `lab/render.py` typesets the exact text each command produced into a terminal panel. The raw, unedited output is in `data/*.txt` — every line in a screenshot can be diffed against it.
* Long ping runs are displayed as the first six replies plus the last two, with an explicit `… N further replies omitted …` marker. Full output is in `data/`.
* Utilisation slightly above 100% is expected and not an error: kernel byte counters include Ethernet framing, while the shaped rate is the nominal IP rate.
* The 24-hour chart is an **accelerated run — one simulated hour equals two seconds of real traffic**, labelled as such on the axis. The bar heights are measured, not drawn.
* `branch-wan-policy.nft` contains two policers. The production one carries the `meta hour "09:00"-"17:00"` match. A second, identical policer without the time match exists purely so the control could be evidenced outside office hours (the lab ran at about 22:30); it is commented as such and would be removed before a production cut-over.

---

## Reproducing

```bash
./lab/net1.sh          # ~2.5 min – Network 1, all three phases
./lab/net2.sh          # ~4 min   – Network 2, all four phases
python3 lab/make_screenshots.py
```

```
lab/common.sh              namespace / veth / counter helpers
lab/net1.sh                Network 1 lab (congestion → QoS + LACP → verify)
lab/net2.sh                Network 2 lab (VPN saturation → policy → recovery)
lab/branch-wan-policy.nft  time-based ACL + policer ruleset
lab/wan-load-report.sh     IOS-style load summary from live counters
lab/render.py              terminal + chart rendering
lab/make_screenshots.py    builds out/Screenshot_1..6.png
data/                      raw captured output and CSV counter samples
out/                       generated evidence images
```

## Evidence images

| File | Shows |
|---|---|
| `out/Screenshot_1.png` | Network 1 — traffic congestion & high link utilisation |
| `out/Screenshot_2.png` | Network 2 — VPN tunnel & WAN saturation |
| `out/Screenshot_3.png` | Network 1 — QoS & EtherChannel configuration |
| `out/Screenshot_4.png` | Network 2 — time-based bandwidth throttling / policy |
| `out/Screenshot_5.png` | Network 1 — post-optimisation latency & packet loss |
| `out/Screenshot_6.png` | Network 2 — post-optimisation daytime bandwidth recovery |

---

**Stack** — Linux network namespaces · `tc` (HTB, TBF, u32) · DSCP classification · 802.3ad bonding · WireGuard · nftables · iperf3 · Python · Bash

Built by [Hector Cabra](https://autokratz.github.io) while completing an Advanced Diploma of Networking Engineering.
