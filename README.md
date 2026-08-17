<div align="center">

# BD Controls

**Extremely lightweight per-user bandwidth monitoring & control for low-end OpenWrt / ImmortalWrt routers**

A single busybox-`sh` daemon + a modern LuCI (JS) page. No Lua, no database,
no jq, no daemon languages. Built for 128–256 MB RAM / 65–128 MB flash routers.

[![License](https://img.shields.io/badge/license-GPL--2.0--only-blue.svg)](LICENSE)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-23.05%2B-orange)](https://openwrt.org)
[![ImmortalWrt](https://img.shields.io/badge/ImmortalWrt-supported-green)](https://immortalwrt.org)
[![Version](https://img.shields.io/badge/version-1.1.0-brightgreen)](#)
[![Made with shell](https://img.shields.io/badge/made%20with-busybox%20sh-4f4f4f)](#)

</div>

---

## What it does

- **Real-time router usage** – CPU, load, uptime, RAM, per-interface traffic
  totals and live rates (read straight from `/proc`).
- **Connected clients** – who is online, for how long, current IP, and live
  download/upload rate.
- **Disconnected clients** – last-seen sessions with session length and
  traffic used (kept in tmpfs, capped at 30 entries).
- **Per-user traffic totals** – lifetime, session, and "today" counters.
- **Block / unblock** any client — one click, persists across reboots.
- **Per-user speed limits** – symmetric download/upload caps via `tc`/HTB
  (`u32` classifiers), in kbit.
- **Time schedules** – one weekly window per client with three modes:
  `allow`, `block`, or `limit` (with its own cap).
- **Usage graphs** – last 24 h (hourly) and last 7 days (daily) bar charts,
  pure DOM, no chart library.

---

## Why it's a good fit for a 128 MB router

| Resource | Budget | BD Controls |
|---|---|---|
| **RAM** | < 15 MB | One tiny `sh` loop; state = a few 1-line tmpfs files. Peak is short-lived `awk`/`nft`/`tc` children. Resident footprint is well under 1 MB. |
| **Flash** | < 5 MB | **~zero writes.** Usage counters and history are volatile (tmpfs) and die with the router. The only durable values are the UCI config (block / limits / schedule / name), committed only when you change them. |
| **CPU** | — | One process, one poll every 2 s (configurable). Firewall rules are rebuilt only when the desired state actually changes (md5 fingerprint). |
| **Binaries** | — | busybox `sh` + `awk` only. `nft` (or `iptables`) and `tc` are detected; the package degrades gracefully if missing. |

> **Deliberate design choice:** *usage* is a live dashboard and is therefore
> volatile — reboot and it resets. *Policy* (who is blocked, their speed caps,
> schedules) is durable and lives in `/etc/config/bd-controls`.

---

## Screenshots

_Coming soon — the LuCI page lives under `Network ▸ BD Controls ▸ Overview`._
The panel shows system stats, a client table (block / limits / reset /
schedule per row), the disconnected-sessions log, and the two bar charts.

---

## Requirements

- **Firmware:** OpenWrt 23.05+ or ImmortalWrt (nftables `fw4` or iptables
  `fw3`; auto-detected).
- **LuCI:** modern (client-side JS) LuCI — shipped by default on these releases.
- **Router:** 128–256 MB RAM recommended.
- **Build host:** a standard OpenWrt SDK/imagebuilder tree (see below).

---

## Installation

### 0. One-command install (auto-detects)

The repo ships a self-contained installer that clones, builds, installs and
sets everything up in one go — it figures out what kind of machine it's
running on:

```sh
curl -fsSL https://raw.githubusercontent.com/asma019/BD-Controls-OpenWRT-Luci/main/install.sh | sh
```

| where you run it | what it does |
|---|---|
| **on the router** | detects `opkg` vs `apk`, installs the two packages — from local `.apk/.ipk` files in the current dir / `$BD_PKGDIR`, else the latest GitHub **release** for your CPU (`bd-controls-<arch>.tar.gz`), else feeds only with `--from-feed` — then enables + starts the service, runs a sanity check and prints setup notes |
| **on an OpenWrt build host** | finds the source tree (`rules.mk`), clones the repo into `package/BD-Controls-OpenWRT-Luci`, runs `make defconfig` only if missing, builds both packages, then **auto-detects your router** (your LAN's default gateway) and pushes + installs onto it in one go — no IP to type |

**How the router gets the packages.** BD Controls is *not* published in any
OpenWrt/ImmortalWrt feed, so the installer never silently assumes it is. On
the router it looks, in order:

1. **local files** — any `bd-controls_*` + `luci-app-bd-controls_*`
   `.apk`/`.ipk` in the current directory or `$BD_PKGDIR` (that's what you get
   after `scp`-ing built packages over),
2. **the latest GitHub release** — downloaded automatically as
   `bd-controls-<arch>.tar.gz` (arch detected via `apk print-arch` /
   `/etc/apk/arch` or `opkg print-architecture`),
3. **feeds** — only when you pass `--from-feed` (in case you run a custom
   feed that does carry the packages).

If none of those yield the packages, it stops with a clear message telling
you exactly how to get them (build + `scp`, or run the installer on a build
host), instead of failing with a confusing "no such package".

**Router IP is never assumed.** Your router does *not* need to be
`192.168.1.1`. On the build host the installer figures out the router's
address by itself, trying in order:

1. the **default route gateway** (`ip route` / `route -n` /
   `/proc/net/route`) — on a normal LAN that *is* the router, whatever its IP
   (`192.168.2.1`, `10.0.0.1`, …),
2. common hostnames (`openwrt.lan`, `immortalwrt.lan`),
3. anything you pass explicitly — `--router` accepts any IP *or hostname*
   and always wins.

If nothing can be detected it prints the copy/install commands with a
`<router-ip>` placeholder instead of guessing. To control the push yourself:

```sh
sh install.sh --router 192.168.2.1         # any IP works
sh install.sh --router openwrt.lan         # or a hostname
sh install.sh --user admin --port 2222 --router 192.168.2.1
sh install.sh --no-push                    # build only, print the next step
sh install.sh --from-feed                  # router: install from your feeds
sh install.sh --release v1.1.0             # router: fetch a specific release tag
```

Safety & error handling built in:

- **stops at the first error** with a clear message (`set -e`); every required
  command is verified before it is used (curl/wget/uclient-fetch, git,
  opkg/apk, scp/ssh),
- **never overwrites** your existing build `.config` or `/etc/config` files,
- keeps `tc` shaping **off** by default — nothing beyond the service's own
  rules is ever touched on the router,
- **auto-push is conservative** — the detected gateway is only pushed to when
  it's a private LAN address (`10.*`, `172.16-31.*`, `192.168.*`); anything
  unusual just prints the next step,
- **idempotent** — re-running updates rather than duplicating.

Prefer to review before running? Download and inspect first:

```sh
curl -fsSL -o install.sh https://raw.githubusercontent.com/asma019/BD-Controls-OpenWRT-Luci/main/install.sh
sh install.sh --help                       # all options
```

The rest of this section documents the same flow manually.

### 1. Get the source

```sh
# clone into your OpenWrt build tree — the folder keeps the repo name
cd $TOPDIR/package
git clone https://github.com/asma019/BD-Controls-OpenWRT-Luci.git
```

The clone creates a folder named `BD-Controls-OpenWRT-Luci`, exactly like
the repo — nothing to rename. The folder *is* the package: the whole tree
under `files/` inside it is what gets installed.

or download & extract a release tarball (extracts with a `-main` suffix —
rename it to match the repo name):

```sh
cd $TOPDIR/package
curl -L -o bd-controls.tar.gz \
  https://github.com/asma019/BD-Controls-OpenWRT-Luci/archive/refs/heads/main.tar.gz
tar -xzf bd-controls.tar.gz
mv BD-Controls-OpenWRT-Luci-main BD-Controls-OpenWRT-Luci
```

The package is self-contained — it has no upstream download step.

### 2. Build the packages

> OpenWrt targets packages by their **directory path**, not by the name in
> the Makefile — so the target below uses the folder name. Both packages are
> defined in this one Makefile, so a single target builds them both:

```sh
cd $TOPDIR
make defconfig                      # or: make menuconfig → LuCI → Applications
make package/BD-Controls-OpenWRT-Luci/clean    # optional, for a fresh rebuild
make package/BD-Controls-OpenWRT-Luci/compile

# locate the artifacts (named after each package, not the folder)
find bin -name 'bd*'
```

(`{clean,compile}` is a bash shortcut for the same two `make` targets; the
plain form above works in any shell, including `dash`/busybox.)

This produces two packages:

| package | installs |
|---|---|
| `bd-controls` | the daemon, backend libs, init script, UCI defaults |
| `luci-app-bd-controls` | the LuCI menu entry, ACL, JS page |

### 3. Install on the router

Upgrade without reflashing — copy to `/tmp` and install over the running
system:

```sh
scp bin/*/packages/*/bd-controls_*.apk root@router:/tmp/
scp bin/*/packages/*/luci-app-bd-controls_*.apk root@router:/tmp/

# on the router:
opkg update
opkg install -force-reinstall /tmp/bd-controls_*.apk /tmp/luci-app-bd-controls_*.apk
```

On opkg images use the `.ipk` artifacts and `opkg install --force-reinstall`.
After install, LuCI will show **Network ▸ BD Controls ▸ Overview** — you may
need to clear the browser cache and reload.

---

## Setup (first run)

The service is **enabled by default** and auto-starts at boot (`START=90`,
after firewall and DHCP). To start it right now:

```sh
service bd-controls enable     # already on for a fresh install; harmless
service bd-controls start
```

Check it's alive:

```sh
bd-controls version      # prints the version
bd-controls status       # JSON snapshot of system + clients
```

Then run through these three checks:

### 1. Interfaces that are monitored

Make sure `monitor.ifaces` lists the bridge/interface your clients actually
use (default is `br-lan`). Edit `/etc/config/bd-controls` or use `uci`:

```sh
uci set bd-controls.monitor.ifaces='br-lan'   # or eth0.1, wlan0, ...
uci commit bd-controls
bd-controls apply
```

### 2. (Optional) Poll interval

`monitor.poll` sets the seconds between samples (default `2`). Lower = more
responsive charts, higher = even less CPU. `3`–`5` is a good low-load choice
on a 128 MB box.

### 3. (Optional) Turn on speed limiting

Rate shaping is **off by default** so it never interferes with an existing
QoS/SQM setup. To enable per-client `tc`/HTB caps:

```sh
uci set bd-controls.tc.enabled='1'
uci set bd-controls.tc.iface_lan='br-lan'     # download side
uci set bd-controls.tc.iface_wan='wan'        # upload side
uci set bd-controls.tc.ceil='100000'          # ceiling kbit for every class
uci commit bd-controls
bd-controls apply
```

You can now open **Network ▸ BD Controls ▸ Overview** and block / limit
clients. A client appears in the table as soon as it holds a DHCP lease —
no restart needed.

---

## Usage

### Web UI

`Network ▸ BD Controls ▸ Overview` polls `status` every 3 s and `usage` every
60 s, both through the same `bd-controls` binary (the ACL grants exec of that
one file and nothing else).

Per client you can:

- block / unblock (persisted to UCI),
- set download / upload caps in kbit (applied immediately), or use the
  one-click quick presets (256k / 512k / 1M / 2M / unlimited),
- rename the client (a friendly name that overrides the DHCP hostname),
- reset the counters,
- maintain the weekly schedule (day-toggle chips, `type="time"` inputs, mode
  selector, and caps for limit mode),
- inspect the client's own 7-day traffic in the per-client chart.

The page is tabbed (Status / Clients / Schedules / Settings). Status shows the
live router state plus interactive 24 h and 7-day charts (hover a bar for
exact numbers, click to pin it); Clients adds per-user totals with a 7-day
mini chart per row; Settings edits the daemon options from the UI. The poll
interval is adjustable (1–60 s) in the header.

### CLI — full reference

Everything the web UI does is available from the shell. MACs are accepted in
any form (`aa:bb:cc:dd:ee:ff`, `AABBCCDDEEFF`, …) and normalized internally.

| command | action |
|---|---|
| `bd-controls daemon` | run the monitoring loop (started by the init script) |
| `bd-controls status` | cached JSON snapshot (`/tmp/bd/status.json`) |
| `bd-controls status -f` | force a fresh compute (used by `apply`) |
| `bd-controls apply` / `reload` | re-apply firewall + tc rules from UCI now |
| `bd-controls block <mac> on\|off` | block/unblock a client — **persistent** |
| `bd-controls limit <mac> <dn> <up>` | per-user speed cap in kbit, `0` = off — **persistent** |
| `bd-controls sched <mac> set <days> <start> <end> <mode> [dn] [up]` | create/replace the client's weekly schedule — **persistent** |
| `bd-controls sched <mac> clear` | remove the client's schedule |
| `bd-controls name <mac> <name>` | set a friendly client name — **persistent** |
| `bd-controls reset <mac>` | zero the client's tmpfs usage counters |
| `bd-controls reset all` | zero every client's counters and clear history |
| `bd-controls settings` | print the current daemon settings as JSON |
| `bd-controls settings <k=v> …` | update whitelisted daemon options — **persistent** |
| `bd-controls usage` | hourly (24 h) + daily (7 d) history JSON |
| `bd-controls shutdown` | remove our fw/tc rules + tmpfs state (init stop) |
| `bd-controls version` | print the version |

`status` is cheap: while the daemon is running it returns the cached
`/tmp/bd/status.json` written every poll; `-f` (or a stopped daemon) forces a
fresh pass.

**Schedule arguments**

- `<days>` — space-separated subset of `mon tue wed thu fri sat sun`.
- `<start>` / `<end>` — `HH:MM` in 24 h. Windows may **cross midnight**
  (e.g. `22:00`–`07:00`).
- `<mode>` — `0` = allow, `1` = block, `2` = limit.
- `[dn]` `[up]` — caps in kbit applied only in `limit` mode (default `0`).

Examples:

```sh
bd-controls block 00:11:22:33:44:55 on
bd-controls limit 00:11:22:33:44:55 2048 1024        # 2 Mbit down / 1 Mbit up
bd-controls sched 00:11:22:33:44:55 set "mon tue wed thu fri" 22:00 07:00 1
bd-controls sched 00:11:22:33:44:55 clear
bd-controls name 00:11:22:33:44:55 "Dad's phone"
bd-controls reset all
bd-controls settings monitor.poll=5 tc.ceil=200000
```

**`settings` whitelist** — only these keys are accepted, each range-checked
before any UCI write (bad values change nothing):

| key | range / format |
|---|---|
| `monitor.enabled` / `tc.enabled` | `0` \| `1` |
| `monitor.poll` | 1–300 seconds |
| `monitor.ifaces` | space-separated interface names |
| `monitor.keep_hours` | 1–1024 |
| `monitor.keep_days` | 1–31 |
| `monitor.retain` | 60–604800 seconds |
| `monitor.disc` | 5–200 sessions |
| `tc.iface_lan` / `tc.iface_wan` | interface name |
| `tc.ceil` | 0–1000000 kbit |

A poll change applies on the next daemon pass (no restart, so volatile usage
is preserved); disabling the monitor removes our firewall rules; disabling tc
tears down the shaping qdisc.

---

## Configuration (`/etc/config/bd-controls`)

```uci
config monitor
	option enabled   '1'
	option poll       '2'          # seconds
	# usage data is volatile (tmpfs) by design; only block/limit/schedule
	# persist, in this config file. data_dir is reserved for future use.
	option data_dir   '/etc/bd-data'
	option ifaces     'br-lan'

config tc
	option enabled   '0'          # 1 enables tc/HTB shaping
	option iface_lan 'br-lan'
	option iface_wan 'wan'
	option ceil      '100000'     # ceiling kbit for every class

config user 'example'
	option mac '00:11:22:33:44:55'
	option name 'Example Phone'
	option block '0'
	option dn  '0'                # kbit
	option up  '0'                # kbit

config schedule 'example_sched'
	option client 'example'       # references a user section
	option days   'mon tue wed thu fri'
	option start  '22:00'
	option end    '07:00'
	option mode   '1'             # 0=allow 1=block 2=limit
	option limit_dn '0'
	option limit_up '0'
```

User and schedule sections are normally created from the web UI — the CLI
`block|limit|sched` commands write them and re-apply.

### Every option

**`monitor`** — the daemon itself.

| option | default | meaning |
|---|---|---|
| `enabled` | `1` | set to `0` to stop collecting/acting (rules already applied stay, nothing new is applied) |
| `poll` | `2` | seconds between sample passes |
| `ifaces` | `br-lan` | space-separated interfaces reported in `net` |
| `data_dir` | `/etc/bd-data` | **reserved** — usage is volatile (tmpfs) by design; nothing is written here |

**`tc`** — per-client rate shaping. Off unless `enabled='1'`.

| option | default | meaning |
|---|---|---|
| `enabled` | `0` | `1` arms `tc`/HTB shaping |
| `iface_lan` | `br-lan` | LAN-facing interface (download caps, `u32 dst` matches) |
| `iface_wan` | `wan` | WAN-facing interface (upload caps, `u32 src` matches) |
| `ceil` | `100000` | ceiling kbit for every HTB class |

**`user`** — one per managed client. Identity is the MAC.

| option | default | meaning |
|---|---|---|
| `mac` | — | client MAC; the unique key (required) |
| `name` | *(empty)* | display name shown in the UI |
| `block` | `0` | `1` blocks the client (persistent) |
| `dn` | `0` | download cap in kbit; `0` = unlimited |
| `up` | `0` | upload cap in kbit; `0` = unlimited |

**`schedule`** — one weekly window per client (references a `user` section).

| option | default | meaning |
|---|---|---|
| `client` | — | name of the `user` section this schedule applies to (required) |
| `days` | *(empty)* | space-separated `mon tue wed thu fri sat sun` |
| `start` | *(empty)* | window start, `HH:MM` |
| `end` | *(empty)* | window end, `HH:MM` (may cross midnight) |
| `mode` | `0` | `0`=allow, `1`=block, `2`=limit |
| `limit_dn` | `0` | download cap in kbit, used in `limit` mode |
| `limit_up` | `0` | upload cap in kbit, used in `limit` mode |

The effective policy each poll is: manual `block`/`dn`/`up` **plus** any
schedule window that is currently active. A schedule in `block` or `limit`
mode overrides the manual caps while the window is open.

---

## How it works

```
 leases (/tmp/dhcp.leases)          UCI policy (block/limit/schedule)
        │                                     │
        ▼                                     ▼
  per-user state (tmpfs)  ──►  desired state ──►  fingerprint (md5)
                                                    │   (only rebuild on change)
                                                    ▼
                                    nftables (inet bd)  /  iptables (BDCTRL)
                                    tc / HTB per-client class (if enabled)
```

- **Identity** is the MAC address. A client appears once it holds a DHCP
  lease; state files are keyed by the normalized MAC, so reconnects keep the
  same counters.
- **Firewall backend** auto-detected: nftables when present (`inet bd`
  table, `bd_fwd` chain), transparent iptables fallback (`BDCTRL` user
  chain jumped from `FORWARD` position 1). Drop rules sit *after* counting
  rules, so blocked traffic is still counted.
- **Rate limiting** is handled by `tc` only, never duplicated in the
  firewall: an HTB root (ceiling `ceil` kbit) with one class + `u32` match
  per limited client on the LAN/WAN side.
- **Poll loop** degrades instead of spinning: if a pass runs longer than the
  poll period it drops to 1 Hz; a failed pass is logged and the loop
  continues.

---

## Safety

- **No lock-out risk.** The daemon is a userspace loop that never aborts on
  error and touches only its own nft table / iptables chain and (only when
  `tc enabled` and it installed the qdisc) its own HTB classes. Your other
  `FORWARD` rules, other tables, and any separate QoS/SQM qdisc are never
  modified.
- **Crash-safe.** procd respawns at most 5×/hour then backs off, so a
  crashing daemon can't busy-loop the CPU.
- **Volatile by design.** Usage counters/history live in tmpfs; the only
  durable state is the UCI config, so a crash or reboot can never corrupt
  your router configuration.

---

## Uninstall

Stopping the service already removes everything the daemon created — its
firewall rules, the qdisc it installed, and `/tmp/bd`. To remove the
packages completely:

```sh
# 1. stop the service (runs the teardown)
service bd-controls stop

# 2. remove the packages
opkg remove luci-app-bd-controls bd-controls     # OpenWrt 23.05 / opkg
apk del luci-app-bd-controls bd-controls          # OpenWrt 24.10+ / ImmortalWrt
```

What remains (and how to clean it if you want a full wipe):

| file / state | after uninstall |
|---|---|
| Firewall rules | gone — verify: `nft list table inet bd` or `iptables -S BDCTRL` shows nothing |
| `tc` qdisc | gone (only ever installed when `tc.enabled='1'`) |
| `/tmp/bd` | gone (tmpfs, removed on stop; wiped on reboot regardless) |
| `/etc/config/bd-controls` | the shipped template is removed with the package. If you **edited** it, the package manager keeps it as a *conffile* — delete manually if you want it gone: `rm /etc/config/bd-controls` |
| `/etc/bd-data` | never created — usage is tmpfs-only |

Reinstalling is just the install step again; nothing is left behind to
conflict.

---

## Repository layout

```
Makefile                                   # builds both packages
LICENSE                                    # GPL-2.0-only
files/
  etc/config/bd-controls                   # UCI defaults (config template)
  etc/init.d/bd-controls                   # procd service (START=90)
  usr/bin/bd-controls                      # thin sh dispatch (daemon + CLI)
  usr/share/bd-controls/
    cli            # command handlers (status/block/limit/sched/reset/usage)
    libbase.sh     # uci parsing, leases, schedule policy, per-user state
    libsys.sh      # /proc CPU/mem/net sampling, counter merge, speeds
    libfw.sh       # nftables / iptables backends, counters, cleanup
    libapply.sh    # rule fingerprinting, tc/HTB shaping, tmpfs rollup, disc
    libjson.sh     # status / usage JSON emitters
  usr/share/luci/menu.d/luci-app-bd-controls.json
  usr/share/rpcd/acl.d/luci-app-bd-controls.json
  www/luci-static/resources/view/bd-controls/overview.js   # the LuCI page
```

The frontend talks to the daemon **only** through `/usr/bin/bd-controls` via
the rpcd `luci.exec` channel. The ACL grants exec of exactly that one binary,
nothing else.

---

## Development

```sh
# syntax-check everything after editing
for f in files/usr/bin/bd-controls files/usr/share/bd-controls/* files/etc/init.d/bd-controls; do
  sh -n "$f" || echo "FAIL $f"
done
node --check files/www/luci-static/resources/view/bd-controls/overview.js
```

Style: POSIX `sh` + busybox `awk` only, no external tools, no `set -e`
(robustness is explicit). Keep state writes in tmpfs and flash writes out.

---

## Credits

**Author & maintainer:** [Mehedi Hasan](https://github.com/asma019) —
[website](https://mehedims.com) · [email](mailto:hello@mehedims.com)

Built with OpenWrt's standard package machinery and the modern LuCI
JavaScript view API (modeled on `luci-app-example` / `luci-mod-status`).

---

## License

[GPL-2.0-only](LICENSE) © 2026 Mehedi Hasan. See the `LICENSE` file for the
full text. You are free to use, modify, and redistribute it under the terms
of the GNU General Public License version 2.
