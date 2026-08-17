# Contributing to BD Controls

Thanks for helping! This project is intentionally small, boring, and
correct — please keep it that way.

## Constraints (non-negotiable)

- **POSIX `sh` + busybox `awk` only.** No jq, no sed-to-excess, no other
  runtimes. The whole point is to run on a 128 MB router.
- **Tmpfs for state, UCI for policy.** Usage counters/history live in
  `/tmp/bd` and may be wiped at any time; block/limit/schedule/name live
  in `/etc/config/bd-controls`. Never write per-user usage data to flash.
- **Robust over clever.** No `set -e`; failures are logged and the loop
  continues. Every `nft`/`tc`/`iptables` call must be idempotent and must
  never touch anything the daemon didn't create.
- **Modern LuCI JS.** The view uses `view.extend` + `E()` + `rpc.declare`
  on the `luci` exec method — nothing else.

## Before you submit

```sh
# shell syntax
for f in files/usr/bin/bd-controls files/usr/share/bd-controls/* files/etc/init.d/bd-controls; do
  sh -n "$f" || echo "FAIL $f"
done

# JS syntax
node --check files/www/luci-static/resources/view/bd-controls/overview.js

# JSON
for j in files/usr/share/luci/menu.d/*.json files/usr/share/rpcd/acl.d/*.json; do
  node -e "JSON.parse(require('fs').readFileSync('$j','utf8'))"
done
```

## Code of conduct

Be civil. This is a hobby-scale project run by one person; kindness and
clear bug reports beat cleverness.
