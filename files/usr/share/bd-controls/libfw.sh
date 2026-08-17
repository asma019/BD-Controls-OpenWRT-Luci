#!/bin/sh
# libfw.sh - firewall backend abstraction (nftables primary, iptables fallback)
# Sourced by /usr/bin/bd-controls. POSIX sh + busybox only.
#
# Copyright (C) 2026 Mehedi Hasan <hello@mehedims.com>
# SPDX-License-Identifier: GPL-2.0-only
#
# API:
#   fw_init()            detect & set BD_FW (nft | iptables | none)
#   fw_status()          echo backend name
#   fw_rebuild <desc..>  atomically rebuild rules; desc="mac,ip,block(0|1)"
#   fw_read_map <out>    write "id<TAB>dir<TAB>bytes" (dir: s=upload, d=download)
#   fw_ensure <desc..>   re-arm cheaply if fw4 flushed our rules
#
# Direction per client:
#   's' = ip saddr = traffic FROM client (upload), 'd' = ip daddr (download)
# Drop rules sit AFTER counting rules, so blocked traffic is still counted.
#
# nft map rows are keyed by the stripped mac key; iptables rows by ip address
# (the caller resolves ip->key, see libsys.sh merge_counters).

BD_FW=auto
BD_NFT=/usr/sbin/nft
BD_IPT=/usr/sbin/iptables-nft
BD_IPT_ALT=/usr/sbin/iptables

fw_init () {
    [ "$BD_FW" = "auto" ] || return 0
    if [ -x "$BD_NFT" ]; then BD_FW=nft; return 0; fi
    if [ -x "$BD_IPT" ] || [ -x "$BD_IPT_ALT" ]; then BD_FW=iptables; return 0; fi
    BD_FW=none; return 1
}
fw_status () { echo "$BD_FW"; }
fw_which_ipt () { [ -x "$BD_IPT" ] && echo "$BD_IPT" || echo "$BD_IPT_ALT"; }

# ---------------------------------------------------------------- nftables
# table inet bd { chain ftr { type filter hook forward priority -100 } }
# counting rules: comment "<mac>_s|_d"; drop rules "_bs|_bd" (skipped when read)
fw_nft_rebuild () {
    "$BD_NFT" delete table inet bd 2>/dev/null || :
    "$BD_NFT" -f - 2>/dev/null <<-EOF || return 1
		table inet bd {
			chain ftr {
				type filter hook forward priority -100; policy accept;
			}
		}
	EOF
    local mac ip blk
    while [ "$#" -gt 0 ]; do
        mac="${1%%,*}"; rest="${1#*,}"; ip="${rest%%,*}"; blk="${rest##*,}"
        "$BD_NFT" add rule inet bd ftr ip saddr "$ip" counter comment "${mac}_s" 2>/dev/null
        "$BD_NFT" add rule inet bd ftr ip daddr "$ip" counter comment "${mac}_d" 2>/dev/null
        if [ "$blk" = "1" ]; then
            "$BD_NFT" add rule inet bd ftr ip saddr "$ip" drop comment "${mac}_bs" 2>/dev/null
            "$BD_NFT" add rule inet bd ftr ip daddr "$ip" drop comment "${mac}_bd" 2>/dev/null
        fi
        shift
    done
}

# portable awk (no gawk match-array). Emit counting rules only.
fw_nft_read () {
    local out="$1"
    "$BD_NFT" list table inet bd 2>/dev/null |
    awk '
        /comment "/ {
            q = index($0, "\"")
            t = substr($0, q+1)
            e = index(t, "\"")
            c = substr(t, 1, e-1)            # e.g. aabbccddeeff_s
            ln = length(c)
            if (ln < 3) next
            dir = substr(c, ln)
            pre = substr(c, ln-1, 1)
            if ((dir == "s" || dir == "d") && pre == "_") {
                for (i=1;i<=NF;i++) if ($i == "bytes") { b=$(i+1); gsub(/[,;]/,"",b) }
                printf "%s\t%s\t%s\n", substr(c,1,ln-2), dir, b
            }
        }' > "$out"
}

# ---------------------------------------------------------------- iptables
# user chain BDCTRL jumped from FORWARD index 1; counting first, then DROP.
#
fw_ipt_arm () {
    local b
    b=$(fw_which_ipt)
    "$b" -N BDCTRL 2>/dev/null || :
    "$b" -C FORWARD -j BDCTRL 2>/dev/null || "$b" -I FORWARD 1 -j BDCTRL 2>/dev/null
}

fw_ipt_rebuild () {
    local b mac ip blk rest
    b=$(fw_which_ipt)
    "$b" -N BDCTRL 2>/dev/null || :
    "$b" -F BDCTRL 2>/dev/null
    while [ "$#" -gt 0 ]; do
        mac="${1%%,*}"; rest="${1#*,}"; ip="${rest%%,*}"; blk="${rest##*,}"
        "$b" -A BDCTRL -s "$ip" 2>/dev/null
        "$b" -A BDCTRL -d "$ip" 2>/dev/null
        if [ "$blk" = "1" ]; then
            "$b" -A BDCTRL -s "$ip" -j DROP 2>/dev/null
            "$b" -A BDCTRL -d "$ip" -j DROP 2>/dev/null
        fi
        shift
    done
}

fw_ipt_read () {
    local out="$1"
    "$(fw_which_ipt)" -L BDCTRL -n -v -x 2>/dev/null |
    sed -n '3,$p' |
    awk '$3 == "" {                 # only counting rules (no target)
        if ($8  ~ /^[0-9.]+$/) printf "%s\ts\t%s\n", $8 , $2
        if ($9  ~ /^[0-9.]+$/) printf "%s\td\t%s\n", $9 , $2
    }' > "$out"
}

# ---------------------------------------------------------------- dispatcher
fw_rebuild () {
    fw_init || return 1
    case "$BD_FW" in
        nft)      fw_nft_rebuild "$@" ;;
        iptables) fw_ipt_rebuild "$@" ;;
        none)     return 1 ;;
    esac
}

fw_read_map () {        # $1 = outfile
    case "$BD_FW" in
        nft)      fw_nft_read "$1" ;;
        iptables) fw_ipt_read "$1" ;;
        *)        : > "$1"; return 1 ;;
    esac
}

fw_ensure () {          # cheap re-arm after fw4 flush ($@ = descs)
    fw_init || return 1
    case "$BD_FW" in
        nft)
            [ -n "$("$BD_NFT" list chain inet bd ftr 2>/dev/null)" ] || fw_rebuild "$@"
            ;;
        iptables)
            [ -n "$("$(fw_which_ipt)" -S BDCTRL 2>/dev/null)" ] || fw_rebuild "$@"
            ;;
    esac
    return 0
}

# fw_unload - remove only our own rules. Idempotent; never touches the
# user's other tables/chains. Called on stop/uninstall via shutdown_cleanup.
fw_unload () {
    fw_init || return 0
    case "$BD_FW" in
        nft)
            "$BD_NFT" delete table inet bd 2>/dev/null || :
            ;;
        iptables)
            local b; b=$(fw_which_ipt)
            "$b" -D FORWARD -j BDCTRL 2>/dev/null || :
            "$b" -F BDCTRL 2>/dev/null || :
            "$b" -X BDCTRL 2>/dev/null || :
            ;;
    esac
    return 0
}