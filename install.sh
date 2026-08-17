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

# Where prebuilt packages are published (GitHub Releases). The asset name is
# bd-controls-<arch>.tar.gz and must contain bd-controls_*.apk|ipk plus
# luci-app-bd-controls_*.apk|ipk for that architecture.
REL_REF="latest"                       # or --release <tag> (a release tag)

info(){ printf '%s\n' " * $*"; }
ok(){   printf '%s\n' "   OK: $*"; }
warn(){ printf '%s\n' " !! $*" >&2; }
die(){  printf '\n[FAIL] %s\n' "$*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

TMPD="${TMPDIR:-/tmp}/bd-install.$$"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT HUP INT TERM

usage(){
    cat <<EOF
Usage: sh install.sh [options]

Auto-detects the environment and installs BD Controls:

  On an OpenWrt router ......... installs the two packages (from local
                                .apk/.ipk files, else the latest GitHub
                                release, else feeds with --from-feed),
                                enables + starts the service, sanity-checks.
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
  --from-feed          router: install from the router's feeds instead of
                       trying the GitHub release (feeds normally have no
                       bd-controls packages)
  --release <tag>      router: fetch a specific release tag instead of latest
  --skip-build         accepted for forward-compat
  -h, --help           show this help

Env:
  BD_ROUTER=<ip|host>  router address (same as --router)
  BD_PKGDIR=<dir>      router: directory containing bd-controls_*.apk/ipk
EOF
}

fetch(){                   # $1 url  $2 outfile; fails (non-zero) on HTTP errors
    if have curl; then         curl -fsSL --retry 2 -o "$2" "$1"
    elif have wget; then       wget -q -O "$2" "$1"
    elif have uclient-fetch; then uclient-fetch -q -f -O "$2" "$1"
    else die "no downloader found - need curl, wget or uclient-fetch"; fi
}

is_router(){
    [ -f /etc/openwrt_release ] && [ -x /sbin/uci ] && [ -x /etc/rc.common ]
}

root_check(){
    [ "$(id -u)" = 0 ] || die "installing on the router requires root (run as root or with sudo)"
}

# ------------------------------------------------------------- router side
pick_artifact(){             # $1 = pkg name prefix; match .ipk (name_*) and .apk (name-*)
    local d p
    for d in "${BD_PKGDIR:-.}" .; do
        for p in "$d"/"$1"_* "$d"/"$1"-*; do
            [ -f "$p" ] && { echo "$p"; return 0; }
        done
    done
    return 1
}

detect_arch(){                 # echo the package arch (aarch64_cortex-a53, mipsel_24kc, ...)
    local a=""
    if have apk; then
        a=$(apk print-arch 2>/dev/null || true)
        [ -n "$a" ] && { echo "$a"; return 0; }
        if [ -r /etc/apk/arch ]; then a=$(cat /etc/apk/arch || true); [ -n "$a" ] && { echo "$a"; return 0; }; fi
    fi
    if have opkg; then
        a=$(opkg print-architecture 2>/dev/null | awk '$1=="arch"{a=$2} END{if(a)print a}' || true)
        [ -n "$a" ] && { echo "$a"; return 0; }
        if [ -r /etc/opkg/architectures ]; then a=$(head -1 /etc/opkg/architectures || true); [ -n "$a" ] && { echo "$a"; return 0; }; fi
    fi
    return 1
}

install_local(){               # $1 = pm  $2 = bd-controls pkg  $3 = luci pkg
    info "installing: $2 $3"
    case "$1" in
        opkg) opkg update >/dev/null 2>&1 || :
              opkg install --force-reinstall "$2" "$3" || die "opkg install failed" ;;
        apk)  apk update >/dev/null 2>&1 || :
              apk add --allow-untrusted -f -q "$2" "$3" || die "apk add failed" ;;
    esac
}

install_feeds(){               # $1 = pm  (only used with --from-feed)
    info "no local packages - installing from the router's feeds (--from-feed)"
    case "$1" in
        opkg) opkg update || die "opkg update failed"
              opkg install bd-controls luci-app-bd-controls || die "opkg install failed - bd-controls is not in these feeds; see README" ;;
        apk)  apk update || die "apk update failed"
              apk add bd-controls luci-app-bd-controls || die "apk add failed - bd-controls is not in these feeds; see README" ;;
    esac
}

fetch_release(){               # $1 = pm; download the release tarball and install; 0=ok 1=unavailable
    local pm=$1 arch rel rel_base
    arch=$(detect_arch) || { warn "cannot detect the CPU architecture - release download skipped"; return 1; }
    rel="bd-controls-$arch.tar.gz"
    # GitHub URLs: latest -> releases/latest/download/..., any tag -> releases/download/<tag>/...
    if [ "$REL_REF" = latest ]; then
        rel_base="$BD_URL/releases/latest/download"
    else
        rel_base="$BD_URL/releases/download/$REL_REF"
    fi
    info "no local packages - trying the GitHub release $REL_REF ($rel)"
    if ! fetch "$rel_base/$rel" "$TMPD/$rel"; then
        warn "release asset not found: $rel"
        return 1
    fi
    if ! tar -xzf "$TMPD/$rel" -C "$TMPD" 2>/dev/null; then
        warn "downloaded archive looks corrupt: $rel"
        return 1
    fi
    local a1 a2
    a1=$(find "$TMPD" -maxdepth 1 \( -name 'bd-controls_*' -o -name 'bd-controls-*' \) | head -1) || a1=""
    a2=$(find "$TMPD" -maxdepth 1 \( -name 'luci-app-bd-controls_*' -o -name 'luci-app-bd-controls-*' \) | head -1) || a2=""
    if [ -z "$a1" ] || [ -z "$a2" ]; then
        warn "release archive does not contain both packages"
        return 1
    fi
    install_local "$pm" "$a1" "$a2"
}

pkg_unavailable(){             # nothing installable was found - tell the user exactly what to do
    die "no BD Controls packages were found.

  BD Controls is NOT published in any OpenWrt/ImmortalWrt feed, so the
  installer cannot fetch it from here. Do one of these:

  1. EASIEST - build on a build host (or grab a published release) and copy
     the two packages to this router, then re-run the installer in that dir:

       scp bd-controls_*.apk luci-app-bd-controls_*.apk root@<this router>:/tmp/
       cd /tmp && sh install.sh
     (or:  BD_PKGDIR=/tmp sh install.sh)

  2. From the release tarball published on the GitHub releases page:
       sh install.sh --release <tag>      # tries bd-controls-<arch>.tar.gz
     A 'latest' release is auto-tried when this message appears.

  3. Build them yourself on an OpenWrt build host:
       cd \$TOPDIR/package
       git clone $BD_URL.git
       cd \$TOPDIR
       make package/$BD_DIR/compile
     then scp bin/*/packages/*/bd-controls_*.apk (and luci-..._*.apk) here.
     Or run 'sh install.sh' on the build host to build and push automatically."
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

    # 1) local artifacts, 2) release (or feeds when --from-feed), 3) clear error
    local a1 a2
    a1=$(pick_artifact 'bd-controls_') || a1=""
    a2=$(pick_artifact 'luci-app-bd-controls_') || a2=""
    if [ -n "$a1" ] && [ -n "$a2" ]; then
        install_local "$pm" "$a1" "$a2"
    elif [ "$FROMFEED" = 1 ]; then
        install_feeds "$pm"
    elif fetch_release "$pm"; then
        :
    else
        pkg_unavailable
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
FROMFEED=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --router)      ROUTER=$2; shift 2 ;;
        --router=*)    ROUTER=${1#--router=}; shift ;;
        --user)        RHUSER=$2; shift 2 ;;
        --user=*)      RHUSER=${1#--user=}; shift ;;
        --port)        PORT=$2; shift 2 ;;
        --port=*)      PORT=${1#--port=}; shift ;;
        --no-push)     NOPUSH=1; shift ;;
        --from-feed)   FROMFEED=1; shift ;;
        --release)     REL_REF=$2; shift 2 ;;
        --release=*)   REL_REF=${1#--release=}; shift ;;
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