#!/bin/sh
# libjson.sh - status + usage JSON emitters (busybox-safe, no jq)
#
# Copyright (C) 2026 Mehedi Hasan <hello@mehedims.com>
# SPDX-License-Identifier: GPL-2.0-only

status_json () {
    local f k polv blk dn up srx stx first=1
    printf '{"ts":%s,"ver":1,"fw":"%s","poll":%s,"monitor":%s,' \
        "$(now)" "$(fw_status)" "${POLL_SEC:-2}" "${MON_ENABLED:-1}"
    printf '"system":{"cpu":%s,"load":"%s %s %s","uptime":%s,' \
        "${CPU_PCT:-0}" "${L1:-0}" "${L2:-0}" "${L3:-0}" "${UPTIME:-0}"
    printf '"mem":{"tot":%s,"avail":%s,"free":%s}},' \
        "$(( ${MT:-0} / 1024 ))" "$(( ${MA:-0} / 1024 ))" "$(( ${MF:-0} / 1024 ))"
    printf '"net":['
    local i iff rxc txc rps tps
    first=1
    for i in $NET; do
        [ -n "$i" ] || continue
        iff=$(echo "$i" | cut -d'|' -f1)
        rxc=$(echo "$i" | cut -d'|' -f2)
        txc=$(echo "$i" | cut -d'|' -f3)
        rps=$(echo "$i" | cut -d'|' -f4)
        tps=$(echo "$i" | cut -d'|' -f5)
        [ $first = 0 ] && printf ','
        first=0
        printf '{"if":"%s","rx":%s,"tx":%s,"rxps":%s,"txps":%s}' \
            "$iff" "$rxc" "$txc" "$rps" "$tps"
    done
    printf '],"users":['
    first=1
    for f in "$TMP"/u/*; do
        [ -f "$f" ] || continue
        k=${f##*/}
        state_get "$k" || continue
        polv=$(pol "$k")
        blk=$(echo "$polv" | cut -d'|' -f1)
        dn=$(echo "$polv"  | cut -d'|' -f2)
        up=$(echo "$polv"  | cut -d'|' -f3)
        srx=0; sry=0
        if [ -f "$TMP/spd/$k" ]; then
            set -- $(cat "$TMP/spd/$k"); srx=$1; sry=$2
        fi
        [ $first = 0 ] && printf ','
        first=0
        printf '{"mac":"%s","ip":"%s","name":"%s","online":%s,"since":%s,"last":%s,"dur":%s,"rx":%s,"tx":%s,' \
            "$(format_mac "$k")" "$S_IP" "$(esc "${S_NM:-}")" \
            "${S_ON:-0}" "${S_FIRST:-0}" "${S_LAST:-0}" \
            "$([ "${S_ON:-0}" = 1 ] && echo $(( $(now) - ${S_START:-0} )) || echo 0)" \
            "${S_RX:-0}" "${S_TX:-0}"
        printf '"rxps":%s,"txps":%s,"block":%s,"dn":%s,"up":%s,"today_rx":%s,"today_tx":%s}' \
            "$srx" "$sry" "$blk" "$dn" "$up" "${S_DRX:-0}" "${S_DTX:-0}"
    done
    printf '],"disc":['
    local at kk nm lst lrx ltx first2=1
    if [ -f "$TMP/disc" ]; then
    while IFS="$(printf '\t')" read -r at kk nm lst lrx ltx rest; do
        [ -n "$at" ] || continue
        [ $first2 = 0 ] && printf ','
        first2=0
        printf '{"at":%s,"mac":"%s","name":"%s","lasted":%s,"rx":%s,"tx":%s}' \
            "$at" "$(format_mac "$kk")" "$(esc "${nm:-}")" "$lst" "$lrx" "$ltx"
    done < "$TMP/disc"
    fi
    printf '],"sched":['
    first=1
    while IFS='|' read -r sk ds st en mo ldn lup; do
        [ -n "$sk" ] || continue
        [ $first = 0 ] && printf ','
        first=0
        printf '{"mac":"%s","days":"%s","start":"%s","end":"%s","mode":%s,"dn":%s,"up":%s}' \
            "$(format_mac "$sk")" "$(esc "${ds:-}")" "${st:-}" "${en:-}" \
            "${mo:-0}" "${ldn:-0}" "${lup:-0}"
    done <<EOF
$SCHED
EOF
    printf '],"cfg":{"monitor":{"enabled":%s,"poll":%s,"ifaces":"%s",' \
        "${MON_ENABLED:-1}" "${POLL_SEC:-2}" "$(esc "${IFACES:-}")"
    printf '"keep_hours":%s,"keep_days":%s,"retain":%s,"disc":%s},' \
        "${KP_HOURS:-24}" "${KP_DAYS:-7}" "${RET:-1800}" "${DISC:-30}"
    printf '"tc":{"enabled":%s,"iface_lan":"%s","iface_wan":"%s","ceil":%s}}' \
        "${TC_ENABLED:-0}" "$(esc "${TC_IFLAN:-}")" "$(esc "${TC_IFWAN:-}")" "${TC_CEIL:-100000}"
    printf '}'
    printf '\n'
}

usage_json () {    # hourly buckets (24h) + current hour + daily totals (7d)
    local first=1 h rx tx d drx dtx nh
    printf '{"hours":['
    if [ -f "$TMP/hourly" ]; then
    while IFS="$(printf '\t')" read -r h rx tx; do
        [ -n "$h" ] || continue
        [ $first = 0 ] && printf ','
        first=0
        printf '{"t":%s,"rx":%s,"tx":%s}' "$h" "$rx" "$tx"
    done < "$TMP/hourly"
    fi
    # in-progress hour (already accumulated in hour.cur)
    if [ -s "$TMP/hour.cur" ]; then
        read -r h rx tx < "$TMP/hour.cur" 2>/dev/null || h=""
        if [ -n "$h" ]; then
            [ $first = 0 ] && printf ','
            printf '{"t":%s,"rx":%s,"tx":%s}' "$h" "$rx" "$tx"
        fi
    fi
    printf '],"days":['
    first=1
    for d in $(ls "$TMP/days/" 2>/dev/null | sort); do
        [ -f "$TMP/days/$d" ] || continue
        set -- $(awk '{ a+=$2; b+=$3 } END { print a, b }' "$TMP/days/$d")
        drx=${1:-0}; dtx=${2:-0}
        [ $first = 0 ] && printf ','
        first=0
        printf '{"d":%s,"rx":%s,"tx":%s}' "$d" "$drx" "$dtx"
    done
    printf '],"udays":['
    # per-client daily totals from the same tmpfs buckets ($TMP/days/<date>).
    # line format "key<TAB>today_rx<TAB>today_tx" - group by key across the
    # keep window. Grouping needs the lines sorted by key first.
    local cur="" first3=1 kk drx dtx dd
    : > "$TMP/udays.tmp"
    for dd in $(ls "$TMP/days/" 2>/dev/null | sort); do
        [ -f "$TMP/days/$dd" ] || continue
        while IFS="$(printf '\t')" read -r kk drx dtx rest; do
            [ -n "$kk" ] || continue
            printf '%s\t%s\t%s\t%s\n' "$kk" "$dd" "$drx" "$dtx" >> "$TMP/udays.tmp"
        done < "$TMP/days/$dd"
    done
    if [ -s "$TMP/udays.tmp" ]; then
        sort "$TMP/udays.tmp" > "$TMP/udays.srt"
        while IFS="$(printf '\t')" read -r kk dd drx dtx; do
            if [ "$kk" != "$cur" ]; then
                [ -n "$cur" ] && printf ']}'
                [ $first3 = 0 ] && printf ','
                first3=0
                state_get "$kk" 2>/dev/null
                printf '{"mac":"%s","name":"%s","days":[' \
                    "$(format_mac "$kk")" "$(esc "${S_NM:-}")"
                cur="$kk"
            else
                printf ','
            fi
            printf '{"d":"%s","rx":%s,"tx":%s}' "$dd" "$drx" "$dtx"
        done < "$TMP/udays.srt"
        [ -n "$cur" ] && printf ']}'
        rm -f "$TMP/udays.srt"
    fi
    rm -f "$TMP/udays.tmp"
    printf ']}'
    printf '\n'
}