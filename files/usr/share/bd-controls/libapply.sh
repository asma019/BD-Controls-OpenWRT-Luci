#!/bin/sh
# libapply.sh - lease sync, rules fingerprint, tc/HTB shaping, tmpfs-only
# daily rollup, disconnect log, shutdown cleanup. Sourced by /usr/bin/bd-controls.
#
# Copyright (C) 2026 Mehedi Hasan <hello@mehedims.com>
# SPDX-License-Identifier: GPL-2.0-only

KP_HOURS=${KEEP_HOURS:-24}
KP_DAYS=${KEEP_DAYS:-7}
DISC=30
RET=${RETAIN:-1800}
FLEV=${FLASH_EVERY:-300}

# ---- bring state files in line with the current lease list ----
sync_from_leases () {
    : > "$TMP/online.now"
    local t k ip nm n
    for t in $LI; do
        [ -n "$t" ] || continue
        k=$(echo "$t" | cut -d'|' -f1)
        ip=$(echo "$t" | cut -d'|' -f2)
        nm=$(echo "$t" | cut -d'|' -f3)
        echo "$k" >> "$TMP/online.now"
        if [ -f "$TMP/u/$k" ]; then
            state_get "$k"
            if [ "$S_ON" != 1 ]; then
                n=$(now); S_ON=1; S_START=$n; S_SRX=0; S_STX=0
            fi
            [ -z "$S_IP" ] || [ "$S_IP" != "$ip" ] && S_IP="$ip"
            [ -z "$S_NM" ] && S_NM="$nm"
            S_LAST=$(now)
            state_put "$k"
        else
            state_new "$k" "$ip" "$nm"
        fi
    done
}

# ---- disconnect tracking ----
disc_track () {
    local k f n lasted
    n=$(now)
    for f in "$TMP"/u/*; do
        [ -f "$f" ] || continue
        k=${f##*/}
        grep -qxF "$k" "$TMP/online.now" 2>/dev/null && continue
        state_get "$k" || continue
        if [ "$S_ON" = 1 ]; then
            S_ON=0; S_LAST=$n
            lasted=$(( n - S_START ))
            if [ "$lasted" -ge 60 ]; then
                printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                    "$n" "$k" "$S_NM" "$lasted" "$S_RX" "$S_TX" >> "$TMP/disc.new"
            fi
            state_put "$k"
        fi
    done
    if [ -s "$TMP/disc.new" ]; then
        cat "$TMP/disc" 2>/dev/null >> "$TMP/disc.new"
        tail -n "$DISC" "$TMP/disc.new" > "$TMP/disc.tmp" \
            && mv -f "$TMP/disc.tmp" "$TMP/disc"
    fi
    rm -f "$TMP/disc.new"
}

# ---- desired-state -> rules ----
armed_descs () {
    ARM=""
    local f k ip blk polv
    local nowt=$(now)
    for f in "$TMP"/u/*; do
        [ -f "$f" ] || continue
        k=${f##*/}; state_get "$k" || continue
        [ -n "$S_IP" ] || continue
        if [ "$S_ON" = 1 ] || [ $(( nowt - S_LAST )) -lt "$RET" ]; then
            polv=$(pol "$k")
            blk=$(echo "$polv" | cut -d'|' -f1)
            ARM="$ARM$k,$S_IP,$blk
"
        fi
    done
}

apply_rules () {
    armed_descs
    local fp
    fp=$(printf '%s' "$ARM" | md5sum | cut -c1-12)
    if [ -f "$TMP/armed.md5" ] && [ "$(cat "$TMP/armed.md5")" = "$fp" ]; then
        fw_ensure >/dev/null 2>&1
    else
        fw_rebuild $(echo "$ARM" | tr '\n' ' ') >/dev/null 2>&1
        echo "$fp" > "$TMP/armed.md5"
    fi
}

# ---- tc / HTB ----
mostly_tc_iface () { [ -d "/sys/class/net/$1" ]; }

tc_cleanup () {
    [ -n "$TC_IFLAN" ] && tc qdisc del dev "$TC_IFLAN" root 2>/dev/null
    [ -n "$TC_IFWAN" ] && tc qdisc del dev "$TC_IFWAN" root 2>/dev/null
}

tc_setup_side () {        # $1 dev  $2 dst|src
    local dev="$1" m="$2" f k polv blk rate cid
    tc qdisc add dev "$dev" root handle 1: htb default 9999 2>/dev/null || return 1
    tc class add dev "$dev" parent 1: classid 1:1 htb \
        rate "${TC_CEIL}kbit" ceil "${TC_CEIL}kbit" 2>/dev/null
    cid=2
    for f in "$TMP"/u/*; do
        [ -f "$f" ] || continue
        k=${f##*/}; state_get "$k"; [ -n "$S_IP" ] || continue
        polv=$(pol "$k")
        blk=$(echo "$polv" | cut -d'|' -f1)
        if [ "$m" = "dst" ]; then rate=$(echo "$polv" | cut -d'|' -f2)
        else                      rate=$(echo "$polv" | cut -d'|' -f3); fi
        [ "$blk" = 1 ] && continue
        [ "$rate" -gt 0 ] 2>/dev/null || continue
        cid=$((cid+1))
        tc class add dev "$dev" parent 1:1 classid "1:$cid" htb \
            rate "${rate}kbit" ceil "${TC_CEIL}kbit" 2>/dev/null
        if [ "$m" = "dst" ]; then
            tc filter add dev "$dev" parent 1: protocol ip prio 1 u32 \
                match ip dst "$S_IP/32" flowid "1:$cid" 2>/dev/null
        else
            tc filter add dev "$dev" parent 1: protocol ip prio 1 u32 \
                match ip src "$S_IP/32" flowid "1:$cid" 2>/dev/null
        fi
    done
}

apply_tc () {
    if [ "${TC_ENABLED:-0}" != 1 ]; then
        if [ -f "$TMP/tc.md5" ]; then tc_cleanup; rm -f "$TMP/tc.md5"; fi
        return 0
    fi
    local fp="e1:$TC_IFLAN:$TC_IFWAN:$TC_CEIL" f k polv blk dn up
    for f in "$TMP"/u/*; do
        [ -f "$f" ] || continue
        k=${f##*/}; state_get "$k"; [ -n "$S_IP" ] || continue
        polv=$(pol "$k")
        blk=$(echo "$polv" | cut -d'|' -f1)
        dn=$(echo "$polv"  | cut -d'|' -f2)
        up=$(echo "$polv"  | cut -d'|' -f3)
        [ "$blk" = 0 ] && fp="$fp:$k=$S_IP:$dn:$up"
    done
    local fpchk
    fpchk=$(printf '%s' "$fp" | md5sum | cut -c1-12)
    [ -f "$TMP/tc.md5" ] && [ "$(cat "$TMP/tc.md5")" = "$fpchk" ] && return 0
    mostly_tc_iface "$TC_IFLAN" || return 0        # iface not up yet
    tc_cleanup
    tc_setup_side "$TC_IFLAN" dst
    if [ -n "$TC_IFWAN" ] && mostly_tc_iface "$TC_IFWAN"; then
        tc_setup_side "$TC_IFWAN" src
    fi
    echo "$fpchk" > "$TMP/tc.md5"
}

# ---- hourly rollup (24h chart) ----
hourly_rollup () {
    local h=$(( $(now) / 3600 )) curh crx ctx
    if [ -f "$TMP/hour.cur" ]; then
        read -r curh crx ctx < "$TMP/hour.cur"
        if [ "$curh" != "$h" ]; then
            printf '%s\t%s\t%s\n' "$curh" "$crx" "$ctx" >> "$TMP/hourly"
            tail -n "$KP_HOURS" "$TMP/hourly" > "$TMP/hourly.tmp" \
                && mv -f "$TMP/hourly.tmp" "$TMP/hourly"
            printf '%s\t%s\t%s\n' "$h" "$H_RX" "$H_TX" > "$TMP/hour.cur"
        else
            printf '%s\t%s\t%s\n' "$h" "$((crx+H_RX))" "$((ctx+H_TX))" > "$TMP/hour.cur"
        fi
    else
        printf '%s\t%s\t%s\n' "$h" "$H_RX" "$H_TX" > "$TMP/hour.cur"
    fi
}

# ---- daily rollup (tmpfs only: usage never survives a reboot) ----
# "today" per-user counters (S_DRX/S_DTX) accumulate in memory all day;
# at a day boundary they are folded into a tmpfs daily bucket for the
# 7-day chart and the today counters reset. Nothing per-user is written
# to flash: the only durable values are the UCI config (block / limits /
# schedule / name), committed by the CLI commands. This keeps flash
# writes at ~zero and usage deliberately volatile.
rollup_daily () {
    mkdir -p "$TMP/days" 2>/dev/null || return 0
    local day f k prev
    day=$(date +%Y%m%d)
    prev=$(cat "$TMP/curday" 2>/dev/null || echo "$day")
    if [ "$prev" != "$day" ]; then
        # close yesterday's bucket, then open today
        : > "$TMP/day.tmp"
        for f in "$TMP"/u/*; do
            [ -f "$f" ] || continue
            k=${f##*/}; state_get "$k" || continue
            if [ "$S_DRX" -ne 0 ] || [ "$S_DTX" -ne 0 ]; then
                printf '%s\t%s\t%s\n' "$k" "$S_DRX" "$S_DTX" >> "$TMP/day.tmp"
            fi
            S_DRX=0; S_DTX=0; state_put "$k"
        done
        [ -s "$TMP/day.tmp" ] && mv -f "$TMP/day.tmp" "$TMP/days/$prev"
        ls "$TMP/days/" 2>/dev/null | sort -r \
            | tail -n +"$((KP_DAYS+1))" | while read -r od; do
                rm -f "$TMP/days/$od"
            done
    fi
    echo "$day" > "$TMP/curday"
}

rollup_tick () {             # throttled caller (cheap: no-op between ticks)
    local lt n
    lt=$(cat "$TMP/lastroll" 2>/dev/null || echo 0)
    n=$(now)
    [ $(( n - lt )) -lt "$FLEV" ] && return 0
    rollup_daily
    echo "$n" > "$TMP/lastroll"
}

# ---- teardown: idempotent, never fatal. Used by the daemon TERM trap
# and the `shutdown` command (init stop / uninstall).
shutdown_cleanup () {
    rollup_daily 2>/dev/null
    # only delete the qdisc we actually created (TC_ENABLED=1); never
    # touch a user's own QoS/SQM root.
    if [ -f "$TMP/tc.md5" ]; then
        rm -f "$TMP/tc.md5"
        tc_cleanup 2>/dev/null
    fi
    fw_unload 2>/dev/null
    rm -f "$TMP/daemon.pid" 2>/dev/null
    rm -rf "$TMP" 2>/dev/null
    return 0
}