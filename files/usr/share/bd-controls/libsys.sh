#!/bin/sh
# libsys.sh - system sampling (cpu/ram/load/net), counter merge, per-user speeds
# Sourced by /usr/bin/bd-controls.
#
# Copyright (C) 2026 Mehedi Hasan <hello@mehedims.com>
# SPDX-License-Identifier: GPL-2.0-only

# ------------------------------------------------------------ /proc samples
read_sys () {     # fills CPU_PCT, MT, MA, MF, L1..L3, UPTIME
    local tl id
    set -- $(awk 'NR==1{print $2+$3+$4+$5+$6+$7+$8, $5+$6}' /proc/stat)
    tl=$1; id=$2
    if [ -f "$TMP/cpu.prev" ]; then
        read -r pid ptd < "$TMP/cpu.prev"
        local dt=$(( tl - ptd )) di=$(( id - pid ))
        CPU_PCT=0
        [ "$dt" -gt 0 ] && CPU_PCT=$(awk -v di="$di" -v dt="$dt" \
            'BEGIN { printf "%.1f", 100*(1-(di/dt)) }')
    fi
    printf '%s %s\n' "$id" "$tl" > "$TMP/cpu.prev"

    MT=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    MA=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    MF=$(awk '/^MemFree:/{print $2}' /proc/meminfo)
    read -r L1 L2 L3 < /proc/loadavg
    read -r UPTIME _R < /proc/uptime
    CPU_PCT=${CPU_PCT:-0}
}

# ------------------------------------------------------------ net counters
# NET rows: "if rx tx rxps txps"
read_net () {
    NET=""
    local t=$(now) dt=$(( t - LASTTS )) i rx tx rp tp
    [ -n "${IFACES:-}" ] || IFACES="br-lan"
    for i in $IFACES; do
        rx=$(cat "/sys/class/net/$i/statistics/rx_bytes" 2>/dev/null) || continue
        tx=$(cat "/sys/class/net/$i/statistics/tx_bytes" 2>/dev/null) || continue
        rp=0; tp=0
        if [ -f "$TMP/prev.$i" ]; then
            read -r pri pti < "$TMP/prev.$i"
            if [ "$dt" -gt 0 ]; then
                rp=$(( (rx - pri) / dt ))
                tp=$(( (tx - pti) / dt ))
            fi
        fi
        printf '%s %s\n' "$rx" "$tx" > "$TMP/prev.$i"
        NET="$NET $i|$rx|$tx|$rp|$tp"
    done
}

# ------------------------------------------------------------ counter merge
# fw_read_map emits per-direction total bytes; we diff vs. last sample and
# fold deltas into cumulative/session/today. Hourly rollup input too.
merge_counters () {
    H_RX=0; H_TX=0
    local fw k dir b key last delta
    fw_read_map "$TMP/map" 2>/dev/null || { : > "$TMP/map"; }
    # map rows: nft  "key\tdir\tbytes"    iptables  "ip\tdir\tbytes"
    while IFS="$(printf '\t')" read -r k dir b; do
        [ -n "$k" ] || continue
        case "$k" in
            *.*) key=$(key_for_ip "$k");;              # ipv4 -> mac key
            *)   key=$k;;                              # already a mac key
        esac
        [ -n "$key" ] && [ -f "$TMP/u/$key" ] || continue
        state_get "$key" || continue
        case "$dir" in
            d) last=$S_RR ;;
            s) last=$S_RT ;;
            *) continue ;;
        esac
        delta=0
        [ "$b" -ge "$last" ] 2>/dev/null && delta=$(( b - last ))
        if [ "$dir" = "d" ]; then
            S_RX=$((S_RX+delta)); S_SRX=$((S_SRX+delta)); S_DRX=$((S_DRX+delta)); S_RR=$b
            H_RX=$((H_RX+delta))
        else
            S_TX=$((S_TX+delta)); S_STX=$((S_STX+delta)); S_DTX=$((S_DTX+delta)); S_RT=$b
            H_TX=$((H_TX+delta))
        fi
        state_put "$key"
    done < "$TMP/map"
}

# ------------------------------------------------------------ speeds
# rxps/txps = cumulative delta between polls; store prx/ptx snapshot
per_user_speed () {
    local dt=$(( $(now) - LASTTS )) f key rp tp
    [ "$dt" -ge 1 ] || dt=1
    for f in "$TMP"/u/*; do
        [ -f "$f" ] || continue
        key=${f##*/}
        state_get "$key" || continue
        rp=$(awk -v a="$S_RX" -v b="$S_PRX" -v d="$dt" 'BEGIN { printf "%.1f", (a-b)/d }')
        tp=$(awk -v a="$S_TX" -v b="$S_PTX" -v d="$dt" 'BEGIN { printf "%.1f", (a-b)/d }')
        S_PRX=$S_RX; S_PTX=$S_TX
        state_put "$key"
        printf '%s %s\n' "$rp" "$tp" > "$TMP/spd/$key"
    done
}