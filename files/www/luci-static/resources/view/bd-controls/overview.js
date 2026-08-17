'use strict';

/*
 * bd-controls overview view
 * -------------------------
 * Copyright (C) 2026 Mehedi Hasan <hello@mehedims.com>
 * SPDX-License-Identifier: GPL-2.0-only
 * https://github.com/asma019/BD-Controls-OpenWRT-Luci
 *
 * Tabbed LuCI view: Status (system + router traffic), Clients (per-user
 * table + per-user 7-day chart + disconnect history), Schedules (weekly
 * windows + add), Settings (daemon + tc options). Pure client-side JS -
 * no Lua, nothing extra on the router beyond bd-controls itself.
 *
 * All actions run through the rpcd "file" object (fs.exec), restricted by
 * the ACL file to /usr/bin/bd-controls only.
 *
 * status output contract (libjson.sh):
 *   { ts, ver, fw, poll, monitor, system:{cpu,load,uptime,mem},
 *     net:[{if,rx,tx,rxps,txps}],
 *     users:[{mac,ip,name,online,since,last,dur,rx,tx,rxps,txps,block,dn,up,today_rx,today_tx}],
 *     disc:[{at,mac,name,lasted,rx,tx}], sched:[{mac,days,start,end,mode,dn,up}],
 *     cfg:{monitor:{enabled,poll,ifaces,keep_hours,keep_days,retain,disc},
 *          tc:{enabled,iface_lan,iface_wan,ceil}} }
 * usage output contract:
 *   { hours:[{t,rx,tx}], days:[{d,rx,tx}],   (d = "YYYYMMDD")
 *     udays:[{mac,name,days:[{d,rx,tx}]}] }   per-client daily totals
 */

'require view';
'require fs';

const BD = '/usr/bin/bd-controls';

/* The legacy "luci" rpcd object's exec method no longer exists in
 * luci-base >= 25.x - commands now run through the "file" object via the
 * fs module. fs.exec() resolves to { code, stdout, stderr }. */
function runBD(argv) {
	return fs.exec(BD, argv).then(function (res) {
		if (Number(res.code) !== 0)
			throw new Error('bd-controls: ' + (res.stderr || ('exit ' + res.code)));
		return res.stdout;
	});
}

const DAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
const MODES = {
	'0': 'Allow',
	'1': 'Block',
	'2': 'Limit'
};
const PRESETS = [
	[256, '256k'],
	[512, '512k'],
	[1024, '1M'],
	[2048, '2M'],
	[0, '∞']
];

let bdStyle = null;

function esc(s) {
	return String(s == null ? '' : s)
		.replace(/&/g, '&amp;').replace(/</g, '&lt;')
		.replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function fmtBytes(n) {
	n = Number(n) || 0;
	if (n < 0) n = 0;
	if (n < 1024) return n.toFixed(0) + ' B';
	if (n < 1048576) return (n / 1024).toFixed(1) + ' KiB';
	if (n < 1073741824) return (n / 1048576).toFixed(1) + ' MiB';
	return (n / 1073741824).toFixed(2) + ' GiB';
}

function fmtRate(bps) {
	return fmtBytes(bps) + '/s';
}

function fmtDur(sec) {
	sec = Number(sec) || 0;
	var s = sec % 60, m = Math.floor(sec / 60) % 60,
	    h = Math.floor(sec / 3600) % 24, d = Math.floor(sec / 86400);
	if (d > 0) return d + 'd ' + h + 'h';
	if (h > 0) return h + 'h ' + m + 'm';
	if (m > 0) return m + 'm';
	return s + 's';
}

function fmtLocal(ts) {
	if (!ts) return '—';
	var dt = new Date(Number(ts) * 1000);
	return dt.toLocaleDateString(undefined, { month: 'short', day: 'numeric' }) +
		' ' + dt.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
}

function fmtDay(d) {
	/* d is an 8-digit number/string "YYYYMMDD" */
	d = String(d);
	if (d.length !== 8) return d;
	var dt = new Date(Number(d.substr(0, 4)), Number(d.substr(4, 2)) - 1,
		Number(d.substr(6, 2)));
	return dt.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

function clearChildren(el) {
	while (el.firstChild)
		el.removeChild(el.firstChild);
}

function setChildren(el, nodes) {
	clearChildren(el);
	(nodes || []).forEach(function (n) {
		if (n != null)
			el.appendChild(n);
	});
}

function bdBtn(label, cls, onClick) {
	var b = E('button', { 'class': 'bd-btn ' + (cls || '') }, [label]);
	if (onClick)
		b.addEventListener('click', onClick);
	return b;
}

function injectStyles() {
	if (bdStyle)
		return;
	bdStyle = E('style', {}, [
		'.bd-page { padding: 6px 0; }' +
		'.bd-panel { background:#fff; border:1px solid #ccc; border-radius:3px; ' +
			'margin-bottom:18px; padding:12px 14px; }' +
		'.bd-panel h3 { margin:0 0 6px 0; font-size:15px; }' +
		'.bd-sub { color:#666; font-size:12px; margin:0 0 10px 0; }' +
		'.bd-flex { display:flex; flex-wrap:wrap; gap:10px; }' +
		'.bd-card { flex:0 1 170px; background:#f8f8f8; border:1px solid #e3e3e3; ' +
			'border-radius:3px; padding:8px 10px; }' +
		'.bd-card b { display:block; font-size:19px; }' +
		'.bd-card span { color:#555; font-size:12px; }' +
		'.bd-bar { height:9px; background:#e8e8e8; border-radius:5px; overflow:hidden; margin-top:6px; }' +
		'.bd-error { display:none; background:#fdd; color:#900; border:1px solid #d88; ' +
			'padding:8px 10px; border-radius:3px; margin-bottom:10px; }' +
		'.bd-btn { padding:2px 9px; border-radius:3px; border:1px solid #999; ' +
			'cursor:pointer; background:#f5f5f5; margin:0 2px 2px 0; }' +
		'.bd-btn:active { background:#e0e0e0; }' +
		'.bd-btn-primary { background:#2e7d32; border-color:#1b5e20; color:#fff; }' +
		'.bd-btn-danger { background:#fdecea; border-color:#d88; color:#a33; }' +
		'.bd-btn-primary:active { background:#1b5e20; }' +
		'.bd-badge { display:inline-block; padding:1px 7px; border-radius:8px; ' +
			'color:#fff; font-size:11px; margin-right:4px; }' +
		'.bd-badge.bd-online { background:#4caf50; }' +
		'.bd-badge.bd-off { background:#9e9e9e; }' +
		'.bd-badge.bd-bad { background:#e53935; }' +
		'.bd-row-blocked td { background:#ffe9e9; }' +
		'.bd-limit { width:58px; }' +
		'.bd-graph { display:flex; align-items:flex-end; height:86px; gap:2px; }' +
		'.bd-gcol { display:flex; flex-direction:column; justify-content:flex-end; ' +
			'flex:1; min-width:2px; height:100%; }' +
		'.bd-grx { background:#42a5f5; border-radius:1px 1px 0 0; }' +
		'.bd-gtx { background:#ffa726; border-radius:1px 1px 0 0; }' +
		'.bd-glegend span { display:inline-block; margin-right:16px; font-size:12px; }' +
		'.bd-square { display:inline-block; width:10px; height:10px; margin-right:4px; }' +
		'.bd-center { text-align:center; color:#888; padding:14px; }' +
		'.bd-wrap { overflow-x:auto; }' +
		'.bd-tbl { min-width:640px; }' +
		/* header + tabs */
		'.bd-head { display:flex; align-items:center; gap:12px; margin-bottom:12px; flex-wrap:wrap; }' +
		'.bd-head b { font-size:18px; }' +
		'.bd-poller { display:inline-flex; align-items:center; gap:6px; font-size:12px; color:#555; }' +
		'.bd-upd { font-size:11px; color:#888; margin-left:auto; }' +
		'.bd-tabs { display:flex; gap:4px; border-bottom:2px solid #e0e0e0; margin-bottom:14px; }' +
		'.bd-tab { padding:6px 16px; border:none; background:transparent; cursor:pointer; ' +
			'font-size:14px; color:#555; border-bottom:2px solid transparent; margin-bottom:-2px; }' +
		'.bd-tab:hover { color:#111; }' +
		'.bd-tab.bd-active { color:#1565c0; border-bottom-color:#1565c0; font-weight:600; }' +
		/* interactive charts */
		'.bd-gwrap { position:relative; }' +
		'.bd-tip { position:absolute; display:none; background:#333; color:#fff; font-size:11px; ' +
			'padding:4px 8px; border-radius:3px; pointer-events:none; z-index:5; white-space:nowrap; }' +
		'.bd-gpin { font-size:12px; color:#444; margin-top:6px; min-height:16px; }' +
		'.bd-spark { display:flex; align-items:flex-end; height:18px; gap:1px; width:78px; }' +
		/* schedules + settings */
		'.bd-chips { display:inline-flex; gap:2px; flex-wrap:wrap; }' +
		'.bd-chip { padding:2px 7px; border-radius:9px; border:1px solid #bbb; ' +
			'background:#fff; font-size:11px; cursor:pointer; text-transform:capitalize; }' +
		'.bd-chip.bd-chip-on { background:#1565c0; border-color:#1565c0; color:#fff; }' +
		'.bd-time { width:70px; }' +
		'.bd-num { width:86px; }' +
		'.bd-grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(150px,1fr)); gap:10px; }' +
		'.bd-fld { display:flex; flex-direction:column; font-size:12px; }' +
		'.bd-fld span { color:#555; margin-bottom:3px; }' +
		'.bd-actions { margin-top:14px; }' +
		'.bd-add { display:flex; flex-wrap:wrap; gap:8px; align-items:center; }' +
		'.bd-rename { border:none; background:none; cursor:pointer; color:#1565c0; ' +
			'font-size:13px; padding:0 4px; }'
	]);
	bdStyle.id = 'bd-css';
	if (!document.getElementById('bd-css'))
		document.head.appendChild(bdStyle);
}

return view.extend({
	render: function () {
		var self = this;

		this.tab = 'status';
		this.selUser = null;
		this.st = null;
		this.udays = [];
		this.pollSec = 3;

		injectStyles();

		var banner = E('div', { 'class': 'bd-error' });

		var pollSel = E('select', { 'class': 'cbi-input', id: 'bd-poll' });
		[1, 2, 3, 5, 10, 30, 60].forEach(function (s) {
			var o = E('option', { value: String(s) }, [s + ' s']);
			o.selected = (s === 3);
			pollSel.appendChild(o);
		});
		pollSel.addEventListener('change', function () {
			self.pollSec = Number(pollSel.value) || 3;
			if (self._t1) {
				clearInterval(self._t1);
				self._t1 = null;
			}
			self._t1 = setInterval(function () { self.poller('refreshStatus', 1); }, self.pollSec * 1000);
			self.refreshStatus();
		});

		var head = E('div', { 'class': 'bd-head' }, [
			E('b', {}, [_('BD Controls')]),
			E('span', { 'class': 'bd-poller' }, [_('Refresh'), pollSel]),
			bdBtn(_('Refresh now'), 'bd-ref', function () { self.refreshAll(); }),
			E('span', { 'class': 'bd-upd', id: 'bd-upd' })
		]);

		var tabs = E('div', { 'class': 'bd-tabs' }, [
			this.tabBtn('status', _('Status')),
			this.tabBtn('clients', _('Clients')),
			this.tabBtn('sched', _('Schedules')),
			this.tabBtn('settings', _('Settings'))
		]);

		var root = E('div', { 'class': 'bd-page' }, [
			banner,
			head,
			tabs,
			this.panelStatus(),
			this.panelClients(),
			this.panelSched(),
			this.panelSettings()
		]);

		this.root = root;
		this.banner = banner;
		this._t1 = null;
		this._t2 = null;

		this.switchTab('status');
		this.refreshAll();

		this._t1 = setInterval(function () { self.poller('refreshStatus', 1); }, 3000);
		this._t2 = setInterval(function () { self.poller('refreshUsage', 2); }, 60000);

		return root;
	},

	/* single entry point for both timers: quits the poll if detached */
	poller: function (name, which) {
		var root = this.root;
		if (!root || !document.body.contains(root)) {
			if (this['_t' + which]) {
				clearInterval(this['_t' + which]);
				this['_t' + which] = null;
			}
			return;
		}
		this[name]();
	},

	/* ---------------- helpers ---------------- */
	$: function (sel) {
		return this.root ? this.root.querySelector(sel) : null;
	},

	showError: function (msg) {
		if (!this.banner)
			return;
		this.banner.textContent = msg || '';
		this.banner.style.display = msg ? '' : 'none';
	},

	execCmd: function (argv) {
		var self = this;
		return runBD(argv).then(function (stdout) {
			return stdout;
		}).catch(function (e) {
			self.showError(e.message);
			throw e;
		});
	},

	refreshAll: function () {
		this.refreshStatus();
		this.refreshUsage();
	},

	card: function (label, value, pct, color) {
		var c = E('div', { 'class': 'bd-card' }, [
			E('span', {}, [label]),
			E('b', {}, [value])
		]);
		if (pct != null) {
			var w = Math.max(0, Math.min(100, Number(pct) || 0));
			c.appendChild(E('div', { 'class': 'bd-bar' }, [
				E('div', {
					style: 'width:' + w.toFixed(1) + '%; height:100%; ' +
						'background:' + (color || '#42a5f5')
				})
			]));
		}
		return c;
	},

	/* don't re-render a container the user is actively typing in */
	isEditing: function (container) {
		var a = document.activeElement;
		return !!(a && a.tagName && /^(INPUT|SELECT|TEXTAREA)$/.test(a.tagName) &&
			container && container.contains(a));
	},

	/* ---------------- tabs ---------------- */
	tabBtn: function (name, label) {
		var self = this;
		var b = E('button', { 'class': 'bd-tab' }, [label]);
		b.addEventListener('click', function () { self.switchTab(name); });
		this.tabBtns = this.tabBtns || {};
		this.tabBtns[name] = b;
		return b;
	},

	switchTab: function (name) {
		this.tab = name;
		var self = this;
		for (var k in this.tabBtns)
			this.tabBtns[k].classList.toggle('bd-active', k === name);
		['status', 'clients', 'sched', 'settings'].forEach(function (p) {
			var pan = self.$('#bd-pan-' + p);
			if (pan)
				pan.style.display = (p === name) ? '' : 'none';
		});
	},

	/* ---------------- panels ---------------- */
	panelStatus: function () {
		return E('div', { 'class': 'bd-pan', id: 'bd-pan-status' }, [
			E('div', { 'class': 'bd-panel' }, [
				E('h3', {}, [_('System')]),
				E('div', { 'class': 'bd-sub' }, [_('Live router resource usage')]),
				E('div', { 'class': 'bd-flex', id: 'bd-sysout' })
			]),
			E('div', { 'class': 'bd-panel' }, [
				E('h3', {}, [_('Router traffic')]),
				E('div', { 'class': 'bd-sub' }, [_('Per-interface totals and current rates')]),
				E('div', { id: 'bd-netout' })
			]),
			E('div', { 'class': 'bd-panel' }, [
				E('h3', {}, [_('Usage history')]),
				E('div', { 'class': 'bd-sub' }, [
					_('Router-wide traffic - hover a bar for details, click to pin it')
				]),
				E('div', { 'class': 'bd-flex' }, [
					E('div', { 'class': 'bd-card', style: 'flex:1 1 48%' }, [
						E('span', {}, [_('Last 24 hours')]),
						E('div', { 'class': 'bd-gwrap' }, [
							E('div', { 'class': 'bd-graph', id: 'bd-graph-h' })
						]),
						E('div', { 'class': 'bd-gpin', id: 'bd-gpin-h' })
					]),
					E('div', { 'class': 'bd-card', style: 'flex:1 1 48%' }, [
						E('span', {}, [_('Last 7 days')]),
						E('div', { 'class': 'bd-gwrap' }, [
							E('div', { 'class': 'bd-graph', id: 'bd-graph-d' })
						]),
						E('div', { 'class': 'bd-gpin', id: 'bd-gpin-d' })
					])
				]),
				E('div', { 'class': 'bd-glegend', style: 'margin-top:10px' }, [
					E('span', {}, [E('i', { 'class': 'bd-square', style: 'background:#42a5f5' }), _('Download')]),
					E('span', {}, [E('i', { 'class': 'bd-square', style: 'background:#ffa726' }), _('Upload')])
				])
			])
		]);
	},

	panelClients: function () {
		return E('div', { 'class': 'bd-pan', id: 'bd-pan-clients' }, [
			E('div', { 'class': 'bd-panel' }, [
				E('h3', {}, [_('Clients')]),
				E('div', { 'class': 'bd-sub' }, [
					_('Live sessions, per-user traffic, limits and blocking')
				]),
				E('div', { 'class': 'bd-wrap' }, [
					E('table', { 'class': 'table bd-tbl', id: 'bd-clients' })
				])
			]),
			E('div', { 'class': 'bd-panel' }, [
				E('h3', {}, [_('Per-client traffic')]),
				E('div', { 'class': 'bd-sub' }, [_('Last 7 days for one client - hover a bar, click to pin')]),
				E('div', { 'class': 'bd-add', style: 'margin-bottom:8px' }, [
					E('select', { 'class': 'cbi-input', id: 'bd-usel', style: 'min-width:240px' })
				]),
				E('div', { 'class': 'bd-gwrap' }, [
					E('div', { 'class': 'bd-graph', id: 'bd-ugraph' })
				]),
				E('div', { 'class': 'bd-gpin', id: 'bd-ugpin' })
			]),
			E('div', { 'class': 'bd-panel' }, [
				E('h3', {}, [_('Recent disconnect sessions')]),
				E('div', { 'class': 'bd-sub' }, [_('Clients that disconnected and how long they stayed')]),
				E('div', { 'class': 'bd-wrap' }, [
					E('table', { 'class': 'table bd-tbl', id: 'bd-hist' })
				])
			])
		]);
	},

	panelSched: function () {
		return E('div', { 'class': 'bd-pan', id: 'bd-pan-sched' }, [
			E('div', { 'class': 'bd-panel' }, [
				E('h3', {}, [_('Schedules')]),
				E('div', { 'class': 'bd-sub' }, [
					_('Per-client weekly time windows: allow, block or throttle')
				]),
				E('div', { 'class': 'bd-wrap' }, [
					E('table', { 'class': 'table bd-tbl', id: 'bd-sched' })
				])
			]),
			E('div', { 'class': 'bd-panel' }, [
				E('h3', {}, [_('Add schedule')]),
				E('div', { 'class': 'bd-sub' }, [_('Create a new weekly window for a client')]),
				E('div', { id: 'bd-schedadd' })
			])
		]);
	},

	panelSettings: function () {
		return E('div', { 'class': 'bd-pan', id: 'bd-pan-settings' }, [
			E('div', { 'class': 'bd-panel' }, [
				E('h3', {}, [_('Settings')]),
				E('div', { 'class': 'bd-sub' }, [_('Daemon and traffic-control options')]),
				E('div', { id: 'bd-settings' })
			])
		]);
	},

	/* ---------------- polling ---------------- */
	refreshStatus: function () {
		var self = this;
		return runBD(['status']).then(function (stdout) {
			var st = JSON.parse(stdout);
			self.st = st;
			self.renderSystem(st.system || {}, st.net || []);
			self.renderUsers(st.users || []);
			self.renderSched(st.sched || [], st.users || []);
			self.renderSchedAdd(st.sched || [], st.users || []);
			self.renderHist(st.disc || []);
			self.renderSettings();
			var u = self.$('#bd-upd');
			if (u)
				u.textContent = 'updated ' + new Date().toLocaleTimeString();
		}).catch(function (e) {
			self.showError(e.message);
		});
	},

	refreshUsage: function () {
		var self = this;
		return runBD(['usage']).then(function (stdout) {
			var u = JSON.parse(stdout);
			self.udays = u.udays || [];
			self.renderCharts(self.$('#bd-graph-h'), self.$('#bd-gpin-h'), u.hours || [], false);
			self.renderCharts(self.$('#bd-graph-d'), self.$('#bd-gpin-d'), u.days || [], true);
			self.renderUChart();
		}).catch(function () { /* non-critical poll */ });
	},

	/* ---------------- renderers: system ---------------- */
	renderSystem: function (sys, net) {
		var box = this.$('#bd-sysout');
		if (box) {
			var memUsed = Math.max(0, (sys.mem.tot || 0) - (sys.mem.avail || 0));
			var memPct = sys.mem.tot ? (memUsed / sys.mem.tot) * 100 : 0;
			var cpuPct = Number(sys.cpu) || 0;

			setChildren(box, [
				E('div', { 'class': 'bd-flex' }, [
					this.card('CPU', cpuPct.toFixed(1) + ' %', cpuPct, '#42a5f5'),
					this.card('RAM used', fmtBytes(memUsed * 1048576) + ' / ' +
						fmtBytes(sys.mem.tot * 1048576), memPct, '#26a69a'),
					this.card('Load avg', String(sys.load || '0 0 0')),
					this.card('Uptime', fmtDur(sys.uptime))
				])
			]);
		}
		var netbox = this.$('#bd-netout');
		if (netbox)
			setChildren(netbox, [this.ifaceTable(net)]);
	},

	ifaceTable: function (net) {
		var peak = 1;
		(net || []).forEach(function (i) {
			peak = Math.max(peak, Number(i.rxps) || 0, Number(i.txps) || 0);
		});

		var rows = [
			E('tr', { 'class': 'tr' }, [
				E('th', { 'class': 'th' }, ['Interface']),
				E('th', { 'class': 'th' }, ['Total RX / TX']),
				E('th', { 'class': 'th' }, ['Current rate']),
				E('th', { 'class': 'th' }, ['RX', E('br'), 'TX'])
			])
		];
		(net || []).forEach(function (i) {
			rows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, [i['if']]),
				E('td', { 'class': 'td' }, [fmtBytes(i.rx) + ' / ' + fmtBytes(i.tx)]),
				E('td', { 'class': 'td' }, [fmtRate(i.rxps) + ' / ' + fmtRate(i.txps)]),
				E('td', { 'class': 'td' }, [
					E('div', { 'class': 'bd-bar' }, [
						E('div', {
							style: 'width:' + Math.min(100, (i.rxps / peak) * 100).toFixed(0) +
								'%; height:100%; background:#42a5f5'
						})
					]),
					E('div', { 'class': 'bd-bar' }, [
						E('div', {
							style: 'width:' + Math.min(100, (i.txps / peak) * 100).toFixed(0) +
								'%; height:100%; background:#ffa726'
						})
					])
				])
			]));
		});

		return E('div', { 'class': 'bd-wrap' }, [
			E('table', { 'class': 'table bd-tbl' }, rows)
		]);
	},

	/* ---------------- renderers: clients ---------------- */
	spark: function (mac) {
		var entry = null;
		(this.udays || []).forEach(function (e) {
			if (e.mac === mac) entry = e;
		});
		if (!entry || !entry.days || !entry.days.length)
			return E('span', { 'class': 'bd-sub' }, ['—']);
		var max = 1;
		entry.days.forEach(function (dd) { max = Math.max(max, dd.rx || 0, dd.tx || 0); });
		var sp = E('div', { 'class': 'bd-spark', title: entry.days.map(function (dd) {
			return fmtDay(dd.d) + '  RX ' + fmtBytes(dd.rx) + ' / TX ' + fmtBytes(dd.tx);
		}).join('\n') });
		entry.days.forEach(function (dd) {
			var rh = Math.round((dd.rx || 0) / max * 100);
			var th = Math.round((dd.tx || 0) / max * 100);
			sp.appendChild(E('div', { 'class': 'bd-gcol' }, [
				E('div', { 'class': 'bd-gtx', style: 'flex-basis:' + th + '%' }),
				E('div', { 'class': 'bd-grx', style: 'flex-basis:' + rh + '%' })
			]));
		});
		return sp;
	},

	renderUsers: function (users) {
		var tab = this.$('#bd-clients');
		if (!tab)
			return;
		if (this.isEditing(tab))
			return;
		var self = this;

		var rows = [
			E('tr', { 'class': 'tr' }, [
				E('th', { 'class': 'th' }, ['Client']),
				E('th', { 'class': 'th' }, ['Status']),
				E('th', { 'class': 'th' }, ['Connection']),
				E('th', { 'class': 'th' }, ['Download']),
				E('th', { 'class': 'th' }, ['Upload']),
				E('th', { 'class': 'th' }, ['Today (RX/TX)']),
				E('th', { 'class': 'th' }, ['7 days']),
				E('th', { 'class': 'th' }, ['Limits (kbit)']),
				E('th', { 'class': 'th' }, ['Control'])
			])
		];

		users.forEach(function (u) {
			var online = Number(u.online) === 1;
			var blocked = Number(u.block) === 1;

			var badge = E('span', {
				'class': 'bd-badge ' + (online ? 'bd-online' : 'bd-off'),
				title: u.ip || ''
			}, [online ? _('online') : _('offline')]);
			if (blocked)
				badge.appendChild(E('span', { 'class': 'bd-badge bd-bad' }, ['Blocked']));

			var dn = E('input', { 'class': 'cbi-input bd-limit', type: 'number',
				min: '0', step: '1', value: String(u.dn || 0) });
			var up = E('input', { 'class': 'cbi-input bd-limit', type: 'number',
				min: '0', step: '1', value: String(u.up || 0) });

			var apply = bdBtn(_('Apply'), '', function () {
				self.execCmd(['limit', u.mac,
					String(Math.max(0, Number(dn.value) || 0)),
					String(Math.max(0, Number(up.value) || 0))])
					.then(function () { self.refreshStatus(); })
					.catch(function () {});
			});
			var block = bdBtn(blocked ? _('Unblock') : _('Block'),
				blocked ? 'bd-btn-danger' : '', function () {
					self.execCmd(['block', u.mac, blocked ? 'off' : 'on'])
						.then(function () { self.refreshStatus(); })
						.catch(function () {});
				});
			var reset = bdBtn(_('Reset'), 'bd-btn-danger', function () {
				if (window.confirm(_('Really reset the counters of this client?')))
					self.execCmd(['reset', u.mac])
						.then(function () { self.refreshStatus(); })
						.catch(function () {});
			});
			var chart = bdBtn(_('Chart'), '', function () {
				self.switchTab('clients');
				self.focusUser(u.mac);
			});

			var presetRow = E('div', {}, [E('span', { 'class': 'bd-sub' }, ['quick: '])]);
			PRESETS.forEach(function (p) {
				presetRow.appendChild(bdBtn(p[1], '', function () {
					self.execCmd(['limit', u.mac, String(p[0]), String(p[0])])
						.then(function () { self.refreshStatus(); })
						.catch(function () {});
				}));
			});

			var rename = bdBtn('✎', 'bd-rename', function () {
				var nm = window.prompt(_('Client name (leave empty to clear)'), u.name || '');
				if (nm === null)
					return;
				self.execCmd(['name', u.mac, nm])
					.then(function () { self.refreshStatus(); })
					.catch(function () {});
			});

			var conn = online
				? (_('connected ') + fmtDur(u.dur) + ' ago')
				: (_('last seen ') + fmtLocal(u.last || u.since));

			rows.push(E('tr', { 'class': 'tr' + (blocked ? ' bd-row-blocked' : '') }, [
				E('td', { 'class': 'td' }, [
					rename, E('b', {}, [esc(u.name || u.mac)]), E('br'),
					E('span', { 'class': 'bd-sub' }, [esc(u.mac)])
				]),
				E('td', { 'class': 'td' }, [badge]),
				E('td', { 'class': 'td' }, [conn]),
				E('td', { 'class': 'td' }, [fmtBytes(u.rx), E('br'),
					E('span', { 'class': 'bd-sub' }, [fmtRate(u.rxps)])]),
				E('td', { 'class': 'td' }, [fmtBytes(u.tx), E('br'),
					E('span', { 'class': 'bd-sub' }, [fmtRate(u.txps)])]),
				E('td', { 'class': 'td' }, [fmtBytes(u.today_rx) + ' / ' + fmtBytes(u.today_tx)]),
				E('td', { 'class': 'td' }, [self.spark(u.mac)]),
				E('td', { 'class': 'td' }, [
					dn, ' / ', up, E('br'), apply, E('br'), presetRow
				]),
				E('td', { 'class': 'td' }, [block, reset, E('br'), chart])
			]));
		});

		if (!users.length)
			rows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', colspan: '9' }, [
					E('div', { 'class': 'bd-center' },
						[_('No clients known yet – wait for the first lease…')])
				])
			]));

		setChildren(tab, rows);
	},

	focusUser: function (mac) {
		this.selUser = mac;
		var sel = this.$('#bd-usel');
		if (sel)
			sel.value = mac;
		this.renderUChart();
	},

	renderUChart: function () {
		var sel = this.$('#bd-usel');
		var g = this.$('#bd-ugraph');
		var pin = this.$('#bd-ugpin');
		if (!sel || !g || !pin)
			return;
		var self = this;

		var users = (this.st && this.st.users) || [];
		var cur = this.selUser;
		var found = false;
		users.forEach(function (u) { if (u.mac === cur) found = true; });
		if (!found) {
			cur = null;
			for (var i = 0; i < users.length; i++) {
				if (Number(users[i].online) === 1) { cur = users[i].mac; break; }
			}
			if (!cur && users.length)
				cur = users[0].mac;
			this.selUser = cur;
		}

		var opts = [E('option', { value: '' }, [users.length ? '— select client —' : 'No clients yet'])];
		users.forEach(function (u) {
			var o = E('option', { value: u.mac }, [esc(u.name || u.mac) + '  ·  ' + u.mac]);
			if (u.mac === cur) o.selected = true;
			opts.push(o);
		});
		setChildren(sel, opts);
		sel.onchange = function () {
			self.selUser = sel.value || null;
			self.renderUChart();
		};

		var entry = null;
		(this.udays || []).forEach(function (e) { if (e.mac === cur) entry = e; });
		if (!cur || !entry || !entry.days || !entry.days.length) {
			setChildren(g, [E('div', { 'class': 'bd-center' }, [_('No usage data yet for this client')])]);
			setChildren(pin, []);
			return;
		}
		var sum = 0;
		entry.days.forEach(function (dd) { sum += (dd.rx || 0) + (dd.tx || 0); });
		setChildren(pin, [
			E('span', {}, [esc(entry.name || entry.mac) + ' — total ' + fmtBytes(sum) +
				' over ' + entry.days.length + ' day(s)'])
		]);
		this.interactiveGraph(g, pin, entry.days, { day: true });
	},

	/* ---------------- renderers: schedules ---------------- */
	dayChips: function (selectedDays) {
		var set = {};
		String(selectedDays || '').split(/\s+/).forEach(function (d) {
			if (d) set[d] = true;
		});
		var out = E('div', { 'class': 'bd-chips' });
		DAYS.forEach(function (d) {
			var c = E('button', { 'class': 'bd-chip' + (set[d] ? ' bd-chip-on' : ''), type: 'button' }, [d]);
			c.addEventListener('click', function () {
				if (set[d]) { delete set[d]; c.classList.remove('bd-chip-on'); }
				else { set[d] = true; c.classList.add('bd-chip-on'); }
			});
			out.appendChild(c);
		});
		return out;
	},

	chipsValue: function (chipsEl) {
		var s = [];
		if (chipsEl)
			for (var i = 0; i < chipsEl.children.length; i++)
				if (chipsEl.children[i].classList.contains('bd-chip-on'))
					s.push(chipsEl.children[i].textContent);
		return s.join(' ');
	},

	modeLimitInps: function (mode, dn, up) {
		var modeSel = E('select', { 'class': 'cbi-input' });
		for (var m in MODES) {
			var o = E('option', { value: m }, [MODES[m]]);
			o.selected = (String(mode) === m);
			modeSel.appendChild(o);
		}
		var dnInp = E('input', { 'class': 'cbi-input bd-limit', type: 'number',
			min: '0', value: String(dn || 0) });
		var upInp = E('input', { 'class': 'cbi-input bd-limit', type: 'number',
			min: '0', value: String(up || 0) });
		return { sel: modeSel, dn: dnInp, up: upInp };
	},

	renderSched: function (sched, users) {
		var tab = this.$('#bd-sched');
		if (!tab)
			return;
		/* only rebuild when the schedule set actually changed, otherwise
		 * in-progress edits (chips, times, caps) would be wiped by the
		 * 3 s status poll */
		var sig = JSON.stringify(sched);
		if (sig === this._schedSig)
			return;
		this._schedSig = sig;
		var self = this;

		var userByMac = {};
		(users || []).forEach(function (u) { userByMac[u.mac] = u; });

		var rows = [
			E('tr', { 'class': 'tr' }, [
				E('th', { 'class': 'th' }, ['Client']),
				E('th', { 'class': 'th' }, ['Days + window']),
				E('th', { 'class': 'th' }, ['Mode']),
				E('th', { 'class': 'th' }, ['Limit DN/UP (kbit)']),
				E('th', { 'class': 'th' }, ['Actions'])
			])
		];

		sched.forEach(function (s) {
			var u = userByMac[s.mac];
			var cname = (u && (u.name || u.mac)) || s.mac;

			var chips = self.dayChips(s.days);
			var startInp = E('input', { 'class': 'cbi-input bd-time', type: 'time',
				value: s.start || '22:00' });
			var endInp = E('input', { 'class': 'cbi-input bd-time', type: 'time',
				value: s.end || '07:00' });
			var lim = self.modeLimitInps(s.mode, s.dn, s.up);

			var save = bdBtn(_('Update'), '', function () {
				var days = self.chipsValue(chips);
				if (!days) {
					window.alert(_('Pick at least one day (tap the day buttons)'));
					return;
				}
				var mode = lim.sel.value;
				if (mode === '2' && !(Number(lim.dn.value) > 0 || Number(lim.up.value) > 0)) {
					window.alert(_('A limit schedule needs a non-zero limit'));
					return;
				}
				self.execCmd(['sched', s.mac, 'set', days, startInp.value, endInp.value,
					mode,
					String(Math.max(0, Number(lim.dn.value) || 0)),
					String(Math.max(0, Number(lim.up.value) || 0))])
					.then(function () { self.refreshStatus(); })
					.catch(function () {});
			});
			var clear = bdBtn(_('Remove'), 'bd-btn-danger', function () {
				if (window.confirm(_('Remove this schedule?')))
					self.execCmd(['sched', s.mac, 'clear'])
						.then(function () { self.refreshStatus(); })
						.catch(function () {});
			});

			rows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, [
					E('b', {}, [esc(cname)]), E('br'),
					E('span', { 'class': 'bd-sub' }, [esc(s.mac)])
				]),
				E('td', { 'class': 'td' }, [
					chips, E('br'),
					E('span', { style: 'white-space:nowrap' }, [startInp, ' – ', endInp])
				]),
				E('td', { 'class': 'td' }, [lim.sel]),
				E('td', { 'class': 'td' }, [
					E('span', { style: 'white-space:nowrap' }, [lim.dn, ' / ', lim.up])
				]),
				E('td', { 'class': 'td' }, [save, clear])
			]));
		});

		if (!sched.length)
			rows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', colspan: '5' }, [
					E('div', { 'class': 'bd-center' }, [_('No schedules yet. Use the form below to add one.')])
				])
			]));

		setChildren(tab, rows);
	},

	renderSchedAdd: function (sched, users) {
		var box = this.$('#bd-schedadd');
		if (!box)
			return;
		/* rebuild only when the candidate set changes (a client gained or
		 * lost a schedule, or a new client appeared) - same edit-clobber
		 * protection as the schedule table */
		var have = {};
		sched.forEach(function (s) { have[s.mac] = 1; });
		var avail = users.filter(function (u) { return !have[u.mac]; });
		var sig = sched.map(function (s) { return s.mac; }).sort().join(',') + '|' +
			avail.map(function (u) { return u.mac; }).sort().join(',');
		if (sig === this._schedAddSig)
			return;
		this._schedAddSig = sig;
		var self = this;

		var sel = E('select', { 'class': 'cbi-input', style: 'min-width:200px' });
		sel.appendChild(E('option', { value: '' }, [
			avail.length ? '— pick a client —' : 'All clients already have a schedule'
		]));
		avail.forEach(function (u) {
			var o = E('option', { value: u.mac }, [esc(u.name || u.mac) + '  ·  ' + u.mac]);
			sel.appendChild(o);
		});

		var chips = self.dayChips('');
		var startInp = E('input', { 'class': 'cbi-input bd-time', type: 'time', value: '22:00' });
		var endInp = E('input', { 'class': 'cbi-input bd-time', type: 'time', value: '07:00' });
		var lim = self.modeLimitInps(0, 0, 0);

		var create = bdBtn(_('Create schedule'), 'bd-btn-primary', function () {
			if (!sel.value) {
				window.alert(_('Pick a client first'));
				return;
			}
			var days = self.chipsValue(chips);
			if (!days) {
				window.alert(_('Pick at least one day (tap the day buttons)'));
				return;
			}
			var mode = lim.sel.value;
			if (mode === '2' && !(Number(lim.dn.value) > 0 || Number(lim.up.value) > 0)) {
				window.alert(_('A limit schedule needs a non-zero limit'));
				return;
			}
			self.execCmd(['sched', sel.value, 'set', days, startInp.value, endInp.value,
				mode,
				String(Math.max(0, Number(lim.dn.value) || 0)),
				String(Math.max(0, Number(lim.up.value) || 0))])
				.then(function () { self.refreshStatus(); })
				.catch(function () {});
		});

		setChildren(box, [E('div', { 'class': 'bd-add' }, [
			sel, chips,
			E('span', { style: 'white-space:nowrap' }, [startInp, ' – ', endInp]),
			lim.sel, E('span', { style: 'white-space:nowrap' }, [lim.dn, ' / ', lim.up]),
			create
		])]);
	},

	/* ---------------- renderers: settings ---------------- */
	renderSettings: function () {
		var pan = this.$('#bd-settings');
		if (!pan)
			return;
		if (this.isEditing(pan))
			return;
		var self = this;

		var cfg = (this.st && this.st.cfg) || null;
		if (!cfg) {
			setChildren(pan, [E('div', { 'class': 'bd-center' }, ['Loading…'])]);
			return;
		}
		/* settings only change when the user saves - don't rebuild the
		 * form on every status poll (would drop in-progress edits) */
		var sig = JSON.stringify(cfg);
		if (sig === this._cfgSig)
			return;
		this._cfgSig = sig;

		function numInp(k, v) {
			return E('input', { 'class': 'cbi-input bd-num', type: 'number',
				min: '0', 'data-k': k, value: String(v) });
		}
		function txtInp(k, v) {
			return E('input', { 'class': 'cbi-input', 'data-k': k, value: String(v) });
		}
		function ynSel(k, v) {
			var s = E('select', { 'class': 'cbi-input', 'data-k': k });
			[['1', 'On'], ['0', 'Off']].forEach(function (o) {
				var x = E('option', { value: o[0] }, [o[1]]);
				x.selected = (String(v) === o[0]);
				s.appendChild(x);
			});
			return s;
		}
		function fld(label, input) {
			return E('label', { 'class': 'bd-fld' }, [E('span', {}, [label]), input]);
		}

		var m = cfg.monitor || {}, tc = cfg.tc || {};

		var mon = E('div', { 'class': 'bd-panel' }, [
			E('h3', {}, [_('Monitor')]),
			E('div', { 'class': 'bd-sub' }, [_('Daemon data collection')]),
			E('div', { 'class': 'bd-grid' }, [
				fld('Enabled', ynSel('monitor.enabled', m.enabled)),
				fld('Poll interval (s)', numInp('monitor.poll', m.poll)),
				fld('Interfaces', txtInp('monitor.ifaces', m.ifaces)),
				fld('History keep (hours)', numInp('monitor.keep_hours', m.keep_hours)),
				fld('History keep (days)', numInp('monitor.keep_days', m.keep_days)),
				fld('Retain (s)', numInp('monitor.retain', m.retain)),
				fld('Disconnect sessions kept', numInp('monitor.disc', m.disc))
			])
		]);

		var tcp = E('div', { 'class': 'bd-panel' }, [
			E('h3', {}, [_('Traffic control (tc / HTB)')]),
			E('div', { 'class': 'bd-sub' }, [_('Per-user speed limits via traffic shaping')]),
			E('div', { 'class': 'bd-grid' }, [
				fld('Enabled', ynSel('tc.enabled', tc.enabled)),
				fld('LAN interface', txtInp('tc.iface_lan', tc.iface_lan)),
				fld('WAN interface', txtInp('tc.iface_wan', tc.iface_wan)),
				fld('Ceiling (kbit)', numInp('tc.ceil', tc.ceil))
			])
		]);

		var save = bdBtn(_('Save settings'), 'bd-btn-primary', function () {
			var args = ['settings'];
			var inps = pan.querySelectorAll('[data-k]');
			for (var i = 0; i < inps.length; i++) {
				var k = inps[i].getAttribute('data-k');
				var v = inps[i].value.trim();
				if (k === 'monitor.ifaces' && !v) v = 'br-lan';
				if (v === '') v = '0';
				args.push(k + '=' + v);
			}
			self.execCmd(args).then(function () {
				self.refreshAll();
			}).catch(function () {});
		});

		var reset = bdBtn(_('Reset all usage'), 'bd-btn-danger', function () {
			if (window.confirm(_('Reset usage counters and history for ALL clients?')))
				self.execCmd(['reset', 'all']).then(function () {
					self.refreshAll();
				}).catch(function () {});
		});

		var note = E('div', { 'class': 'bd-sub', style: 'margin-top:10px' }, [
			_('Poll interval changes apply automatically. Disabling the monitor removes BD Controls firewall rules. Disabling traffic control removes the shaping qdisc. Usage data is volatile - it resets on reboot by design.')
		]);

		setChildren(pan, [mon, tcp, note, E('div', { 'class': 'bd-actions' }, [save, reset])]);
	},

	/* ---------------- renderers: history ---------------- */
	renderHist: function (disc) {
		var tab = this.$('#bd-hist');
		if (!tab)
			return;

		var rows = [
			E('tr', { 'class': 'tr' }, [
				E('th', { 'class': 'th' }, ['Client']),
				E('th', { 'class': 'th' }, ['Disconnected']),
				E('th', { 'class': 'th' }, ['Lasted']),
				E('th', { 'class': 'th' }, ['Downloaded']),
				E('th', { 'class': 'th' }, ['Uploaded'])
			])
		];

		(disc || []).forEach(function (d) {
			rows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, [
					esc(d.name || d.mac), E('br'),
					E('span', { 'class': 'bd-sub' }, [esc(d.mac)])
				]),
				E('td', { 'class': 'td' }, [fmtLocal(d.at)]),
				E('td', { 'class': 'td' }, [fmtDur(d.lasted)]),
				E('td', { 'class': 'td' }, [fmtBytes(d.rx)]),
				E('td', { 'class': 'td' }, [fmtBytes(d.tx)])
			]));
		});

		if (!(disc || []).length)
			rows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', colspan: '5' }, [
					E('div', { 'class': 'bd-center' }, [_('No disconnect sessions yet.')])
				])
			]));

		setChildren(tab, rows);
	},

	/* ---------------- interactive bar charts ---------------- */
	renderCharts: function (el, pin, data, isDay) {
		if (el)
			this.interactiveGraph(el, pin, data, { day: isDay });
	},

	interactiveGraph: function (el, pin, data, opts) {
		var self = this;
		setChildren(el, []);
		if (!data || !data.length) {
			el.appendChild(E('div', { 'class': 'bd-center' }, [_('No data yet')]));
			return;
		}

		var max = 1;
		data.forEach(function (p) {
			max = Math.max(max, p.rx || 0, p.tx || 0, (p.rx || 0) + (p.tx || 0));
		});

		var tip = E('div', { 'class': 'bd-tip' });
		el.appendChild(tip);
		var wrap = el.parentNode || el;

		data.forEach(function (p) {
			var rh = Math.round((p.rx || 0) / max * 100);
			var th = Math.round((p.tx || 0) / max * 100);
			var label = (opts && opts.day) ? fmtDay(p.d) : fmtLocal(p.t);

			var col = E('div', { 'class': 'bd-gcol', title: label }, [
				E('div', { 'class': 'bd-gtx', style: 'flex-basis:' + th + '%' }),
				E('div', { 'class': 'bd-grx', style: 'flex-basis:' + rh + '%' })
			]);
			col.addEventListener('mouseenter', function (ev) {
				tip.textContent = label + ' — RX ' + fmtBytes(p.rx) + ' / TX ' + fmtBytes(p.tx);
				self.moveTip(tip, wrap, ev);
			});
			col.addEventListener('mousemove', function (ev) {
				self.moveTip(tip, wrap, ev);
			});
			col.addEventListener('mouseleave', function () {
				tip.style.display = 'none';
			});
			col.addEventListener('click', function () {
				if (pin)
					pin.textContent = label + ' — RX ' + fmtBytes(p.rx) + ' / TX ' + fmtBytes(p.tx) +
						'  •  total ' + fmtBytes((p.rx || 0) + (p.tx || 0));
			});
			el.appendChild(col);
		});
	},

	moveTip: function (tip, wrap, ev) {
		if (!tip)
			return;
		var r = wrap.getBoundingClientRect();
		var x = ev.clientX - r.left;
		var y = ev.clientY - r.top;
		x = Math.max(2, Math.min(x, r.width - 6));
		y = Math.max(2, y - 14);
		tip.style.left = x + 'px';
		tip.style.top = y + 'px';
		tip.style.display = '';
	}
});
