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
#        and either prints the next step or, with --router <ip>, pushes
#        and installs them on the router over scp/ssh.
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
#   sh install.sh --router 192.168.1.1     # build host: also push + install
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
  On an OpenWrt build host .... clones the repo, builds both packages,
                                prints the next step (or pushes to a
                                router with --router).

Options:
  --router <ip|host>   build host: also "scp + install" onto the router
  --router=<ip|host>   same as above
  --skip-build         router: only install local artifacts/feeds, skip build
  -h, --help           show this help

Env:
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

    local arts
    arts=$(find "$TOPDIR/bin" \( -name 'bd-controls_*' -o -name 'luci-app-bd-controls_*' \) 2>/dev/null) || true
    if [ -z "$arts" ]; then
        warn "no built artifacts found under $TOPDIR/bin"
        return 1
    fi
    for a in $arts; do ok "artifact: $a"; done

    if [ -n "${ROUTER:-}" ]; then
        push_and_install "$TOPDIR/bin" "$arts"
    else
        cat <<EOF

  ---------- next step ----------
  Copy to the router and install:

    scp $TOPDIR/bin/*/packages/*/bd-controls_* root@ROUTER:/tmp/
    scp $TOPDIR/bin/*/packages/*/luci-app-bd-controls_* root@ROUTER:/tmp/
    ssh root@ROUTER 'opkg update && opkg install --force-reinstall /tmp/bd-controls_* /tmp/luci-app-bd-controls_*'

  (apk-based images: apk add --allow-untrusted -f /tmp/bd-controls_* /tmp/luci-app-bd-controls_*)
  Or rerun on the router:  curl -fsSL .../install.sh | sh
  ------------------------------------------------------------------
EOF
    fi
}

push_and_install(){          # $1 = bin dir  $2 = artifacts (multi-line)
    have scp || die "scp is required for --router"
    have ssh || die "ssh is required for --router"
    info "pushing to root@$ROUTER"
    scp -q $2 root@"$ROUTER":/tmp/ || die "scp failed"
    info "detecting package manager on the router and installing"
    if ssh root@"$ROUTER" 'command -v apk >/dev/null 2>&1' 2>/dev/null; then
        ssh root@"$ROUTER" 'apk update && apk add --allow-untrusted -f /tmp/bd-controls_* /tmp/luci-app-bd-controls_*' || die "remote apk install failed"
    else
        ssh root@"$ROUTER" 'opkg update && opkg install --force-reinstall /tmp/bd-controls_* /tmp/luci-app-bd-controls_*' || die "remote opkg install failed"
    fi
    ssh root@"$ROUTER" '/etc/init.d/bd-controls enable && /etc/init.d/bd-controls start' || die "could not start the service on the router"
    ok "installed and started on $ROUTER"
}

# ----------------------------------------------------------------------
ROUTER=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --router)      ROUTER=$2; shift 2 ;;
        --router=*)    ROUTER=${1#--router=}; shift ;;
        --skip-build)  : ;;                        # accepted for forward-compat
        -h|--help)     usage; exit 0 ;;
        *)             die "unknown option: $1 (see --help)" ;;
    esac
done

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