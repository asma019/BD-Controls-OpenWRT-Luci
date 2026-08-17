#!/bin/sh
# libbase.sh - helpers, UCI config, schedule policy, leases, per-user state
# Sourced by /usr/bin/bd-controls. POSIX sh + busybox only.
#
# Copyright (C) 2026 Mehedi Hasan <hello@mehedims.com>
# SPDX-License-Identifier: GPL-2.0-only

# ---------------------------------------------------------------- utils
now ()         { date +%s; }
log ()         { echo "bd-controls: $*" >&2; }
esc ()         { printf '%s' "$1" | sed 's#\\#\\\\#g; s#"#\\"#g; s#\t#\\t#g; s#\r##g'; }
keymac ()      { echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/://g'; }
namefmt ()     { echo "$1" | tr -c 'A-Za-z0-9_.-' '_'; }
cfg_name () {          # $1 client key -> UCI user-section name ('' if unset)
    local s
    for s in $HAVE; do
        case "$s" in "$1"\|*) echo "$s" | cut -d'|' -f5; return 0;; esac
    done
}
format_mac ()  { echo "$1" | sed 's/\(..\)/\1:/g; s/:$//' | tr 'a-f' 'A-F'; }
poll_sec ()    { echo "${POLL_SEC:-2}"; }

# ---------------------------------------------------------------- uci
# globals set: HAVE, SCHED, MON_ENABLED, POLL_SEC, DATA_DIR, IFACES, TC_*
# HAVE lines : "key|blk|dn|up|name" (names sanitized)
# SCHED lines: "key|days|start|end|mode|dn|up" (days space separated)
load_uci () {
    config_load bd-controls 2>/dev/null || return 1
    config_get_bool MON_ENABLED monitor enabled 1
    config_get POLL_SEC  monitor poll 2
    config_get DATA_FROM monitor data_dir "$DATA_DIR"
    [ -n "$DATA_FROM" ] && DATA_DIR="$DATA_FROM"
    config_get IFACES    monitor ifaces ""
    config_get KP_HOURS  monitor keep_hours 24
    config_get KP_DAYS   monitor keep_days 7
    config_get RET       monitor retain 1800
    config_get DISC      monitor disc 30
    config_get_bool TC_ENABLED tc enabled 0
    config_get TC_IFLAN  tc iface_lan ""
    config_get TC_IFWAN  tc iface_wan ""
    config_get TC_CEIL   tc ceil 100000
    [ -n "$TC_IFLAN" ] || TC_IFLAN="br-lan"
    HAVE=""; SCHED=""
    config_foreach base_user_cfg user
    config_foreach base_sch_cfg schedule
}

base_user_cfg () {           # $1 = uci section name
    local mac blk dn up nm
    config_get mac "$1" mac ""
    [ -n "$mac" ] || return 0
    config_get_bool blk "$1" block 0
    config_get dn "$1" dn 0
    config_get up "$1" up 0
    config_get nm "$1" name ""
    HAVE="$HAVE$(keymac "$mac")|$blk|$dn|$up|$(namefmt "$nm")
"
}

base_sch_cfg () {            # $1 = uci schedule section; client -> user section -> mac
    local cl mac k ds st en mo v
    config_get cl "$1" client ""
    [ -n "$cl" ] || return 0
    config_get mac "$cl" mac ""              # client refs the user section
    [ -n "$mac" ] || return 0
    k=$(keymac "$mac")
    config_get ds "$1" days ""
    config_get st "$1" start ""
    config_get en "$1" end ""
    config_get mo "$1" mode 0    # 0=allow 1=block 2=limit (int, not bool)
    config_get v "$1" limit_dn 0
    SCHED="$SCHED$k|$ds|$st|$en|$mo|$v|"
    config_get v "$1" limit_up 0
    SCHED="$SCHED$v
"
}

# effective policy for a client key -> "blk|dn|up" (manual block wins)
pol () {
    local key="$1" blk=0 dn=0 up=0 row="" s
    for s in $HAVE; do
        case "$s" in "$key"\|*) row="$s"; break;; esac
    done
    if [ -n "$row" ]; then
        blk=$(echo "$row" | cut -d'|' -f2)
        dn=$(echo "$row"  | cut -d'|' -f3)
        up=$(echo "$row"  | cut -d'|' -f4)
    fi
    local dow nowmin tmpf cl days start end mode ldn lup stm enm inwin
    dow=$(date +%a | tr '[:upper:]' '[:lower:]')
    nowmin=$(( $(date +%H) * 60 + $(date +%M) ))
    tmpf="$TMP/sched.$$"
    printf '%s' "$SCHED" > "$tmpf"
    while IFS='|' read -r cl days start end mode ldn lup; do
        [ -n "$cl" ] || continue
        [ "$cl" = "$key" ] || continue
        case " $days " in *" $dow "*) ;; *) continue;; esac
        stm=$(echo "$start" | awk -F: '{print $1*60+$2}')
        enm=$(echo "$end"   | awk -F: '{print $1*60+$2}')
        inwin=0
        if [ "$stm" -le "$enm" ]; then
            [ "$nowmin" -ge "$stm" ] && [ "$nowmin" -lt "$enm" ] && inwin=1
        else
            { [ "$nowmin" -ge "$stm" ] || [ "$nowmin" -lt "$enm" ]; } && inwin=1
        fi
        [ "$inwin" = 1 ] || continue
        case "$mode" in
            1) blk=1 ;;
            2) dn=$ldn; up=$lup ;;
        esac
    done < "$tmpf"
    rm -f "$tmpf"
    echo "$blk|$dn|$up"
}

# ---------------------------------------------------------------- leases
# LI rows "key|ip|name" (newline separated)
read_leases () {
    LI=""
    [ -r /tmp/dhcp.leases ] || return 0
    local lnow=$(now) exp mac ip name k
    while read -r exp mac ip name tail; do
        [ -n "$mac" ] || continue
        case "$exp" in
            '*') ;;
            *) [ "$exp" -ge "$lnow" ] 2>/dev/null || continue ;;
        esac
        LI="$LI$(keymac "$mac")|$ip|$(namefmt "$name")
"
    done < /tmp/dhcp.leases
}

# ---------------------------------------------------------------- ip map
# iptables backend counters arrive keyed by ip; nft by mac-key.
build_ipmap () {
    : > "$TMP/ipmap"
    local f k ip
    for f in "$TMP"/u/*; do
        [ -f "$f" ] || continue
        k=${f##*/}
        ip=$(cut -f1 "$f" 2>/dev/null)
        [ -n "$ip" ] && echo "$ip $k" >> "$TMP/ipmap"
    done
    for t in $LI; do
        [ -n "$t" ] || continue
        ip=$(echo "$t" | cut -d'|' -f2)
        k=$(echo "$t"  | cut -d'|' -f1)
        [ -n "$ip" ] && echo "$ip $k" >> "$TMP/ipmap"
    done
}
key_for_ip () { awk -v ip="$1" '$1==ip{print $2; exit}' "$TMP/ipmap"; }

# ---------------------------------------------------------- per-user state
# file "$TMP/u/<key>", tab separated, 16 fields:
#  ip name online first last cumrx cumtx sessrx sesstx sstart rawrx rawtx
#  prx ptx todayrx todaytx
state_get () {             # $1 = key
    local f="$TMP/u/$1"
    S_IP=""; S_NM=""; S_ON=0; S_FIRST=0; S_LAST=0
    S_RX=0; S_TX=0; S_SRX=0; S_STX=0; S_START=0
    S_RR=0; S_RT=0; S_PRX=0; S_PTX=0; S_DRX=0; S_DTX=0
    [ -f "$f" ] || return 1
    IFS="$(printf '\t')" read -r S_IP S_NM S_ON S_FIRST S_LAST \
        S_RX S_TX S_SRX S_STX S_START S_RR S_RT S_PRX S_PTX S_DRX S_DTX < "$f"
}
state_put () {
    printf '%s\n' \
        "$S_IP	$S_NM	$S_ON	$S_FIRST	$S_LAST	$S_RX	$S_TX	$S_SRX	$S_STX	$S_START	$S_RR	$S_RT	$S_PRX	$S_PTX	$S_DRX	$S_DTX" \
        > "$TMP/u/$1"
}
state_new () {             # $1 key $2 ip $3 name
    local n=$(now)
    S_IP="$2"; S_NM="$3"; S_ON=1; S_FIRST=$n; S_LAST=$n
    S_RX=0; S_TX=0; S_SRX=0; S_STX=0; S_START=$n
    S_RR=0; S_RT=0; S_PRX=0; S_PTX=0; S_DRX=0; S_DTX=0
    state_put "$1"
}