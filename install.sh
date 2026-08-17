#!/bin/sh
#
# BD Controls - one-command clone, build, install & setup
#
# Copyright (C) 2026 Mehedi Hasan <hello@mehedims.com>
# SPDX-License-Identifier: GPL-2.0-only
# https://github.com/asma019/BD-Controls-OpenWRT-Luci
#
# Auto-detects where it is being run:
#
#   ON AN OPENWRT ROUTER (has /etc/openwrt_release + uci)
#     -> uses local .apk/.ipk files if present (BD_PKGDIR or current dir),
#        otherwise installs from the routers configured feeds,
#        installs the two packages, enables + starts the service,
#        runs a sanity check and prints the setup summary.
#
#   ON AN OPENWRT BUILD HOST (an OpenWrt source tree; has rules.mk)
#     -> clones this repo into package/BD-Controls-OpenWRT-Luci,
#        builds BOTH packages (i.e. bd-controls + luci-app-bd-controls),
#        then auto-detects the router (default gateway, any IP like
#        192.168.2.1 or 10.0.0.1) and pushes + installs over scp/ssh.
#        --router <ip|host> overrides detection; --no-push prints the
#        next step instead.
#
# Safety:
#   * set -e: stops at the first failure and prints a clear message
#   * never overwrites an existing build .config or /etc/config files
#   * keeps tc shaping OFF by default - nothing on the router is touched
#     beyond what the bd-controls service itself manages
#   * detects opkg vs apk, verifies every required command first
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/asma019/BD-Controls-OpenWRT-Luci/main/install.sh | sh
#   sh install.sh --help
#   sh install.sh --router 192.168.2.1     # push to any router IP, or auto-detect
#
set -eu

BD_URL="https://github.com/asma019/BD-Controls-OpenWRT-Luci"
BD_DIR="BD-Controls-OpenWRT-Luci"

info(){ printf '%s\n' " * $*"; }
ok(){   printf '%s\n' "   OK: $*"; }
warn(){ printf '%s\n' " !! $*" >&2; }
die(){  printf '\n[FAIL] %s\n' "$*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

TMPD="${TMPDIR:-/tmp}/bd-install.$$"
trap 'rm -rf "$TMPD"' EXIT HUP INT TERM

usage(){
    cat <<EOF
Usage: sh install.sh [options]

Auto-detects the environment and installs BD Controls:

  On an OpenWrt router ......... installs the two packages, enables and
                                starts the service, runs a sanity check.
  On an OpenWrt build host .... clones the repo, builds both packages, then
                                auto-detects your router (your default
                                gateway) and pushes + installs it in one go.

Options:
  --router <ip|host>   router to push to. Any IP/hostname works - your router
                       does NOT need to be 192.168.1.1 (e.g. 192.168.2.1,
                       10.0.0.1, openwrt.lan ...). When omitted it is
                       auto-detected from your default gateway.
  --router=<ip|host>   same as above
  --user <name>        ssh user for the router (default: root)
  --port <n>           ssh/scp port (default: 22)
  --no-push            build host: build only, do not push, just print the
                       next step with the detected router address
  --skip-build         router: only install local artifacts/feeds, skip build
  -h, --help           show this help

Env:
  BD_ROUTER=<ip|host>  router address (same as --router)
  BD_PKGDIR=<dir>      router: directory containing bd-controls_*.apk/ipk
EOF
}

fetch(){                   # $1 url  $2 outfile
    if have curl; then         curl -fsSL --retry 2 -o "$2" "$1"
    elif have wget; then       wget -q -O "$2" "$1"
    elif have uclient-fetch; then uclient-fetch -q -O "$2" "$1"
    else die "no downloader found - need curl, wget or uclient-fetch"; fi
}

is_router(){
    [ -f /etc/openwrt_release ] && [ -x /sbin/uci ] && [ -x /etc/rc.common ]
}

root_check(){
    [ "$(id -u)" = 0 ] || die "installing on the router requires root (run as root or with sudo)"
}

# ------------------------------------------------------------- router side
pick_artifact(){             # $1 = pkg name prefix; prints first match, if any
    local d p
    for d in "${BD_PKGDIR:-.}" .; do
        for p in "$d"/"$1"*; do
            [ -f "$p" ] && { echo "$p"; return 0; }
        done
    done
    return 1
}

router_install(){
    root_check
    local pm=""
    if have apk; then pm=apk; elif have opkg; then pm=opkg; fi
    [ -n "$pm" ] || die "no package manager found (need opkg or apk)"
    info "router detected: $(cat /etc/openwrt_release 2>/dev/null | grep -m1 DISTRIB_DESCRIPTION | cut -d"'" -f2) - package manager: $pm"

    local mem
    mem=$(awk '/MemTotal/{print int($2/1024)" MB"}' /proc/meminfo 2>/dev/null)
    [ -n "$mem" ] && info "router RAM: $mem"

    # 1) local artifacts first, 2) configured feeds as fallback
    local a1 a2
    a1=$(pick_artifact 'bd-controls_') || a1=""
    a2=$(pick_artifact 'luci-app-bd-controls_') || a2=""
    if [ -n "$a1" ] && [ -n "$a2" ]; then
        info "installing local artifacts: $a1 $a2"
        case "$pm" in
            opkg) opkg update >/dev/null 2>&1 || :
                  opkg install --force-reinstall "$a1" "$a2" || die "opkg install failed" ;;
            apk)  apk update >/dev/null 2>&1 || :
                  apk add --allow-untrusted -f -q "$a1" "$a2" || die "apk add failed" ;;
        esac
    else
        info "no local artifacts - installing from the router's feeds"
        case "$pm" in
            opkg) opkg update || die "opkg update failed"
                  opkg install bd-controls luci-app-bd-controls || die "opkg install failed" ;;
            apk)  apk update || die "apk update failed"
                  apk add bd-controls luci-app-bd-controls || die "apk add failed" ;;
        esac
    fi

    [ -x /etc/init.d/bd-controls ] || die "service script missing after install (install failed?)"
    info "enabling + starting the service"
    /etc/init.d/bd-controls enable
    /etc/init.d/bd-controls start

    sanity_check
    setup_note
}

sanity_check(){
    have bd-controls || die "bd-controls binary not found after install"
    local v
    v=$(bd-controls version 2>/dev/null || echo "unknown")
    info "installed version: $v"
    if /etc/init.d/bd-controls running 2>/dev/null; then
        ok "service is running"
    else
        warn "service not running yet - try: /etc/init.d/bd-controls start"
    fi
    if bd-controls status >/dev/null 2>&1; then
        ok "status output looks valid"
    else
        warn "status returned an error (see: bd-controls status)"
    fi
}

setup_note(){
    cat <<EOF

  ---------- setup ----------
  Open LuCI: Network -> BD Controls -> Overview
  (you may need to hard-reload the browser once)

  Monitored interfaces : /etc/config/bd-controls  (monitor.ifaces, default 'br-lan')
  Speed limiting       : OFF by default; to enable set tc.enabled='1' (see README)
  Block / limit        : manage per client in the UI, or via 'bd-controls' CLI
  Uninstall            : opkg/apk remove, or: sh install.sh (idempotent)
  ------------------------------------------------------------------
EOF
}

# ----------------------------------------------------------- build host
find_topdir(){               # find an OpenWrt source tree from cwd upward
    local d=$PWD
    while [ "$d" != "/" ]; do
        [ -f "$d/rules.mk" ] && [ -d "$d/package" ] && { echo "$d"; return 0; }
        d=$(dirname "$d")
    done
    return 1
}

hex_ip(){                    # little-endian hex from /proc/net/route -> dotted quad
    local h=$1
    printf '%d.%d.%d.%d' \
        $((16#$(echo "$h" | cut -c7-8))) \
        $((16#$(echo "$h" | cut -c5-6))) \
        $((16#$(echo "$h" | cut -c3-4))) \
        $((16#$(echo "$h" | cut -c1-2)))
}

detect_router_ip(){          # best-effort: echo the router's address or fail
    local gw=""
    # try each method in turn; fall through when a tool exists but yields nothing
    if have ip; then
        gw=$(ip route 2>/dev/null | awk '$1=="default"{print $3; exit}')
        [ -n "$gw" ] && [ "$gw" != "0.0.0.0" ] && { echo "$gw"; return 0; }
    fi
    if have route; then
        gw=$(route -n 2>/dev/null | awk '$1=="0.0.0.0"{print $2; exit}')
        [ -n "$gw" ] && [ "$gw" != "0.0.0.0" ] && { echo "$gw"; return 0; }
    fi
    if [ -r /proc/net/route ]; then
        gw=$(awk '$2=="00000000"{print $3; exit}' /proc/net/route 2>/dev/null)
        if [ -n "$gw" ] && [ "$gw" != "00000000" ]; then
            gw=$(hex_ip "$gw")
            echo "$gw"; return 0
        fi
    fi
    # last resort: common OpenWrt hostnames (mDNS / /etc/hosts)
    for h in openwrt.lan immortalwrt.lan openwrt; do
        if have getent; then
            getent hosts "$h" >/dev/null 2>&1 && { echo "$h"; return 0; }
        elif have ping; then
            ping -c1 -W1 "$h" >/dev/null 2>&1 && { echo "$h"; return 0; }
        fi
    done
    return 1
}

is_private(){                # $1 = dotted quad; true only for RFC1918 LAN space
    local a b
    a=${1%%.*}
    b=$(echo "$1" | cut -d. -f2)
    case "$a" in
        10)   return 0 ;;
        172)  [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 0 ;;
        192)  [ "$b" = 168 ] && return 0 ;;
    esac
    return 1
}

resolve_router(){            # echo 'user@host' from --router, BD_ROUTER, or detection
    local user="${RHUSER:-root}" host="${ROUTER:-}"
    if [ -z "$host" ]; then
        host=$(detect_router_ip) || die "could not detect your router's IP - pass --router <ip|host> (any IP works, e.g. 192.168.2.1)"
        info "auto-detected router as $host (override with --router <ip|host>)" >&2
    fi
    case "$host" in
        *://*) host=${host#*://} ;;          # strip any ssh:// prefix
    esac
    case "$host" in
        *@*) user=${host%%@*}; host=${host#*@} ;;   # honor user@ given explicitly
    esac
    [ -n "$host" ] || die "no usable router address - pass --router <ip|host>"
    echo "$user@$host"
}

host_build(){
    have git || die "git is required on the build host (apt install git / opkg install git)"
    local TOPDIR
    TOPDIR=$(find_topdir) || die "not inside an OpenWrt source tree (no rules.mk found) - cd into your OpenWrt tree first"
    info "OpenWrt tree: $TOPDIR"

    local PKGDIR="$TOPDIR/package/$BD_DIR"
    if [ -d "$PKGDIR/.git" ]; then
        info "repo already present - refreshing"
        git -C "$PKGDIR" pull --ff-only >/dev/null 2>&1 || warn "pull failed; continuing with the existing tree"
    else
        info "cloning into package/$BD_DIR"
        git -C "$TOPDIR/package" clone "$BD_URL.git" || die "git clone failed"
    fi

    if [ ! -f "$TOPDIR/.config" ]; then
        info "no .config yet - running 'make defconfig'"
        make -C "$TOPDIR" defconfig >/dev/null || die "'make defconfig' failed"
    fi

    info "building the two packages (bd-controls + luci-app-bd-controls)"
    make -C "$TOPDIR" "package/$BD_DIR/clean" >/dev/null 2>&1 || :
    make -C "$TOPDIR" V=s "package/$BD_DIR/compile" || die "build failed - see output above"

    local arts PUSH=0 DET=""
    arts=$(find "$TOPDIR/bin" \( -name 'bd-controls_*' -o -name 'luci-app-bd-controls_*' \) 2>/dev/null) || true
    if [ -z "$arts" ]; then
        warn "no built artifacts found under $TOPDIR/bin"
        return 1
    fi
    for a in $arts; do ok "artifact: $a"; done

    # decide whether to push, and to whom
    if [ "$NOPUSH" = 1 ]; then
        PUSH=0
        DET=$(detect_router_ip 2>/dev/null) || DET=""
    elif [ -n "${ROUTER:-}" ]; then
        PUSH=1                                   # explicit --router: always push
    elif DET=$(detect_router_ip 2>/dev/null); then
        case "$DET" in
            *.*.*.*) is_private "$DET" && { PUSH=1; info "auto-detected router as $DET (this LAN's gateway)"; } ;;
            *)       PUSH=1; info "auto-detected router as $DET" ;;
        esac
    fi

    if [ "$PUSH" = 1 ]; then
        push_and_install "$TOPDIR/bin" "$arts"
    else
        DET="${DET:-<router-ip>}"
        cat <<EOF

  ---------- next step ----------
  Copy to the router and install ($DET):

    scp $TOPDIR/bin/*/packages/*/bd-controls_* root@$DET:/tmp/
    scp $TOPDIR/bin/*/packages/*/luci-app-bd-controls_* root@$DET:/tmp/
    ssh root@$DET 'opkg update && opkg install --force-reinstall /tmp/bd-controls_* /tmp/luci-app-bd-controls_*'

  (apk-based images: apk add --allow-untrusted -f /tmp/bd-controls_* /tmp/luci-app-bd-controls_*)
  Tip: 'sh install.sh --router $DET' does the copy + install for you in one go.
  ------------------------------------------------------------------
EOF
    fi
}

push_and_install(){          # $1 = bin dir  $2 = artifacts (multi-line)
    have scp || die "scp is required to push to the router (apt install openssh-client)"
    have ssh || die "ssh is required to push to the router (apt install openssh-client)"
    local RHOST
    RHOST=$(resolve_router) || return 1
    info "pushing to $RHOST (port ${PORT:-22})"
    $SCP $2 "$RHOST:/tmp/" || die "scp to $RHOST failed - is the address right? override with --router <ip|host>"
    info "detecting package manager on the router and installing"
    if $SSH "$RHOST" 'command -v apk >/dev/null 2>&1'; then
        $SSH "$RHOST" 'apk update && apk add --allow-untrusted -f /tmp/bd-controls_* /tmp/luci-app-bd-controls_*' || die "remote apk install failed"
    else
        $SSH "$RHOST" 'opkg update && opkg install --force-reinstall /tmp/bd-controls_* /tmp/luci-app-bd-controls_*' || die "remote opkg install failed"
    fi
    $SSH "$RHOST" '/etc/init.d/bd-controls enable && /etc/init.d/bd-controls start' || die "could not start the service on the router"
    ok "installed and started on $RHOST"
}

# ----------------------------------------------------------------------
ROUTER=""
RHUSER=""
PORT=""
NOPUSH=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --router)      ROUTER=$2; shift 2 ;;
        --router=*)    ROUTER=${1#--router=}; shift ;;
        --user)        RHUSER=$2; shift 2 ;;
        --user=*)      RHUSER=${1#--user=}; shift ;;
        --port)        PORT=$2; shift 2 ;;
        --port=*)      PORT=${1#--port=}; shift ;;
        --no-push)     NOPUSH=1; shift ;;
        --skip-build)  : ;;                        # accepted for forward-compat
        -h|--help)     usage; exit 0 ;;
        *)             die "unknown option: $1 (see --help)" ;;
    esac
done
: "${ROUTER:=${BD_ROUTER:-}}"                     # honor BD_ROUTER env as --router

# Non-interactive-friendly ssh/scp: short connect timeout, accept new host keys
SSH="ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"
SCP="scp -q -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"
if [ -n "$PORT" ]; then
    SSH="$SSH -p $PORT"
    SCP="$SCP -P $PORT"
fi

if is_router; then
    router_install
elif TOPDIR=$(find_topdir) && [ -n "$TOPDIR" ]; then
    host_build
else
    die "cannot detect the environment.
  On a router this script needs /etc/openwrt_release + uci.
  On a build host it must run inside an OpenWrt source tree.
  See --help."
fi