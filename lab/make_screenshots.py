#!/usr/bin/env python3
"""Build the six Network performance lab portfolio screenshots from captured lab data."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import render as R

D, O = R.DATA, R.OUT


def p(*a):
    return os.path.join(D, *a)


def o(*a):
    return os.path.join(O, *a)


print("[render] charts...")

peak1 = R.chart_util(
    p("n1_util_congested.csv"),
    "Network 1 - ACC-SW-01 uplink Gi0-1 egress utilisation, peak hour (10 Mbps link)",
    "link utilisation (%)", o(".c1.png"), colour="#ff5f56", thresh=90)

peak2 = R.chart_util(
    p("n2_util_saturated.csv"),
    "Network 2 - BR-RTR-01 WAN Gi0-0 egress utilisation during midday cloud sync (20 Mbps link)",
    "WAN utilisation (%)", o(".c2.png"), colour="#ff9f43", thresh=90)

b, a = R.chart_latency(p("n1_ping_before.txt"), p("n1_ping_after.txt"), o(".c5.png"))

prof = R.chart_24h(p("n2_24h_profile.csv"), o(".c6a.png"))

R.chart_util(
    p("n2_util_recovered.csv"),
    "Network 2 - BR-RTR-01 WAN Gi0-0 utilisation during business hours, policy in force",
    "WAN utilisation (%)", o(".c6b.png"), colour="#7ee08a", thresh=15,
    cap_label="backup policed to 5% of uplink")

print("[render] composites...")

R.build(1,
        "SCREENSHOT 1  -  NETWORK 1: TRAFFIC CONGESTION & HIGH LINK UTILISATION",
        f"ACC-SW-01 Gi0-1 uplink saturated at {peak1:.1f}% of 10 Mbps; tail-drop buffer overflowing; "
        f"voice RTT {(sum(b)/len(b) if b else 0):.0f} ms average",
        p("n1_shot1_congestion.txt"), "ACC-SW-01 - console (peak hour)",
        [o(".c1.png")])

R.build(2,
        "SCREENSHOT 2  -  NETWORK 2: VPN TUNNEL & WAN SATURATION",
        f"BR-RTR-01 WAN Gi0-0 at {peak2:.1f}% of 20 Mbps - site-to-site tunnel wg0 carrying the "
        f"midday cloud-backup upload",
        p("n2_shot2_vpn_saturation.txt"), "BR-RTR-01 - console (midday sync)",
        [o(".c2.png")])

R.build(3,
        "SCREENSHOT 3  -  NETWORK 1: QoS & ETHERCHANNEL CONFIGURATION",
        "802.3ad LACP bundle (Gi0-1 + Gi0-2) plus HTB policy map prioritising DSCP EF voice over generic traffic",
        p("n1_shot3_qos_lacp.txt"), "ACC-SW-01 - console (control measures)",
        [])

R.build(4,
        "SCREENSHOT 4  -  NETWORK 2: TIME-BASED BANDWIDTH THROTTLING / POLICY",
        f"Time-based ACL ({R.POLICER_WINDOW[0]:02d}:00-{R.POLICER_WINDOW[1]:02d}:00) capping cloud backup "
        "at 5% of the 20 Mbps uplink, with matching class-based shaper",
        p("n2_shot4_time_policy.txt"), "BR-RTR-01 - console (traffic policy)",
        [])

R.build(5,
        "SCREENSHOT 5  -  NETWORK 1: POST-OPTIMISATION LATENCY & PACKET LOSS",
        f"VoIP RTT reduced from {(sum(b)/len(b) if b else 0):.0f} ms to "
        f"{(sum(a)/len(a) if a else 0):.0f} ms under the same bulk load, 0% packet loss",
        p("n1_shot5_post.txt"), "VOIP-PHONE-10 / ACC-SW-01 - console (verification)",
        [o(".c5.png")])

day = [v for h, v in prof.items() if R.WORKING_DAY[0] <= h <= R.WORKING_DAY[1]]
R.build(6,
        "SCREENSHOT 6  -  NETWORK 2: POST-OPTIMISATION DAYTIME BANDWIDTH RECOVERY",
        f"Working-day WAN load back to {(sum(day)/len(day) if day else 0):.1f}% average; "
        f"heavy backup traffic confined to the 22:00-05:00 window",
        p("n2_shot6_recovery.txt"), "BR-RTR-01 - console (business hours)",
        [o(".c6b.png"), o(".c6a.png")])

for f in os.listdir(O):
    if f.startswith(".c") and f.endswith(".png"):
        os.remove(o(f))

print("[render] done ->", O)
