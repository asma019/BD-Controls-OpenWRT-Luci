'use strict';

/*
 * bd-controls overview view
 * -------------------------
 * Copyright (C) 2026 Mehedi Hasan <hello@mehedims.com>
 * SPDX-License-Identifier: GPL-2.0-only
 * https://github.com/asma019/BD-Controls-OpenWRT-Luci
 *
 * Live router status (CPU/RAM/load/uptime/ifaces), per-user monitoring
 * with block/unblock, per-user speed limits, one weekly schedule per
 * client, disconnect history and usage charts. Pure client-side JS -
 * no Lua, nothing extra on the router beyond bd-controls itself.
 *
 * All actions go through the rpcd "luci" exec method, restricted by the
 * ACL file to /usr/bin/bd-controls only.
 *
 * status output contract (libjson.sh):
 *   { ts, system:{cpu,load,uptime,mem:{tot,avail,free}}, net:[{if,rx,tx,rxps,txps}],
 *     users:[{mac,ip,name,online,since,dur,rx,tx,rxps,txps,block,dn,up,today_rx,today_tx}],
 *     disc:[{at,mac,name,lasted,rx,tx}], sched:[{mac,days,start,end,mode,dn,up}] }
 * usage output contract:
 *   { hours:[{t,rx,tx}], days:[{d,rx,tx}] }   (d = "YYYYMMDD")
 */

'require view';
'require rpc';

const BD = '/usr/bin/bd-controls';

const exec = rpc.declare({
	object: 'luci',
	method: 'exec',
	params: ['command', 'params'],
	expect: { result: ['rc', 'stdout', 'stderr'] }
});

const DAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
const MODES = {
	'0': 'Allow',
	'1': 'Block',
	'2': 'Limit'
};

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

function barCol(rx, tx, max, title) {
	var rh = Math.round((Number(rx) || 0) / max * 100);
	var th = Math.round((Number(tx) || 0) / max * 100);
	return E('div', { 'class': 'bd-gcol', title: title }, [
		E('div', { 'class': 'bd-gtx', style: 'flex-basis:' + th + '%' }),
		E('div', { 'class': 'bd-grx', style: 'flex-basis:' + rh + '%' })
	]);
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
		'.bd-btn-danger { background:#fdecea; border-color:#d88; color:#a33; }' +
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
		'.bd-tbl { min-width:640px; }'
	]);
	bdStyle.id = 'bd-css';
	if (!document.getElementById('bd-css'))
		document.head.appendChild(bdStyle);
}

return view.extend({
	render: function () {
		var self = this;

		injectStyles();

		var banner = E('div', { 'class': 'bd-error' });

		var root = E('div', { 'class': 'bd-page' }, [
			banner,
			this.panelSys(),
			this.panelClients(),
			this.panelSched(),
			this.panelHist(),
			this.panelUsage()
		]);

		this.root = root;
		this.banner = banner;
		this._t1 = null;
		this._t2 = null;

		/* initial fetch, then poll.
		 * The pollers stop themselves once this view is no longer in the
		 * document (LuCI swaps views in place), which keeps the rpcd exec
		 * traffic to zero when the page is left. */
		this.refreshStatus();
		this.refreshUsage();
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
		return exec(BD, argv).then(function (r) {
			if (Number(r[0]) !== 0)
				throw new Error('bd-controls: ' + (r[2] || 'command failed'));
			return r[1];
		}).catch(function (e) {
			self.showError(e.message);
			throw e;
		});
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

	/* ---------------- panels ---------------- */
	panelSys: function () {
		return E('div', { 'class': 'bd-panel' }, [
			E('h3', {}, [_('System')]),
			E('div', { 'class': 'bd-sub' }, [_('Live router resource usage')]),
			E('div', { 'class': 'bd-flex', id: 'bd-sysout' })
		]);
	},

	panelClients: function () {
		return E('div', { 'class': 'bd-panel' }, [
			E('h3', {}, [_('Clients')]),
			E('div', { 'class': 'bd-sub' }, [_('Live sessions, per-user traffic, limits and blocking')]),
			E('div', { 'class': 'bd-wrap' }, [
				E('table', { 'class': 'table bd-tbl', id: 'bd-clients' })
			])
		]);
	},

	panelSched: function () {
		return E('div', { 'class': 'bd-panel' }, [
			E('h3', {}, [_('Schedules')]),
			E('div', { 'class': 'bd-sub' }, [
				_('Per-client weekly time windows: allow, block or throttle')
			]),
			E('div', { 'class': 'bd-wrap' }, [
				E('table', { 'class': 'table bd-tbl', id: 'bd-sched' })
			])
		]);
	},

	panelHist: function () {
		return E('div', { 'class': 'bd-panel' }, [
			E('h3', {}, [_('Recent disconnect sessions')]),
			E('div', { 'class': 'bd-sub' }, [_('Clients that disconnected and how long they stayed')]),
			E('div', { 'class': 'bd-wrap' }, [
				E('table', { 'class': 'table bd-tbl', id: 'bd-hist' })
			])
		]);
	},

	panelUsage: function () {
		return E('div', { 'class': 'bd-panel' }, [
			E('h3', {}, [_('Usage history')]),
			E('div', { 'class': 'bd-sub' }, [_('Router-wide traffic (download / upload per interval)')]),
			E('div', { 'class': 'bd-flex' }, [
				E('div', { 'class': 'bd-card', style: 'flex:1 1 48%' }, [
					E('span', {}, [_('Last 24 hours')]),
					E('div', { 'class': 'bd-graph', id: 'bd-graph-h' })
				]),
				E('div', { 'class': 'bd-card', style: 'flex:1 1 48%' }, [
					E('span', {}, [_('Last 7 days')]),
					E('div', { 'class': 'bd-graph', id: 'bd-graph-d' })
				])
			]),
			E('div', { 'class': 'bd-glegend', style: 'margin-top:10px' }, [
				E('span', {}, [E('i', { 'class': 'bd-square', style: 'background:#42a5f5' }), _('Download')]),
				E('span', {}, [E('i', { 'class': 'bd-square', style: 'background:#ffa726' }), _('Upload')])
			])
		]);
	},

	/* ---------------- polling ---------------- */
	refreshStatus: function () {
		var self = this;
		return exec(BD, ['status']).then(function (r) {
			if (Number(r[0]) !== 0)
				throw new Error('bd-controls: ' + (r[2] || 'status failed'));
			var st = JSON.parse(r[1]);
			self.renderSystem(st.system || {}, st.net || []);
			self.renderUsers(st.users || []);
			self.renderSched(st.sched || [], st.users || []);
			self.renderHist(st.disc || []);
		}).catch(function (e) {
			self.showError(e.message);
		});
	},

	refreshUsage: function () {
		var self = this;
		return exec(BD, ['usage']).then(function (r) {
			if (Number(r[0]) !== 0)
				throw new Error('bd-controls: ' + (r[2] || 'usage failed'));
			var u = JSON.parse(r[1]);
			self.renderUsageGraph(self.$('#bd-graph-h'), u.hours || [], true);
			self.renderUsageGraph(self.$('#bd-graph-d'), u.days || [], false);
		}).catch(function () { /* non-critical poll */ });
	},

	/* ---------------- renderers ---------------- */
	renderSystem: function (sys, net) {
		var box = this.$('#bd-sysout');
		if (!box)
			return;

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
			]),
			this.ifaceTable(net)
		]);
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

		return E('div', { 'class': 'bd-wrap', style: 'margin-top:10px' }, [
			E('table', { 'class': 'table bd-tbl' }, rows)
		]);
	},

	renderUsers: function (users) {
		var self = this;
		var tab = this.$('#bd-clients');
		if (!tab)
			return;

		var rows = [
			E('tr', { 'class': 'tr' }, [
				E('th', { 'class': 'th' }, ['Client']),
				E('th', { 'class': 'th' }, ['Status']),
				E('th', { 'class': 'th' }, ['Connection']),
				E('th', { 'class': 'th' }, ['Download']),
				E('th', { 'class': 'th' }, ['Upload']),
				E('th', { 'class': 'th' }, ['Today (RX/TX)']),
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

			var conn = online
				? (_('connected ') + fmtDur(u.dur) + ' ago')
				: (_('last seen ') + fmtLocal(u.last || u.since));

			rows.push(E('tr', { 'class': 'tr' + (blocked ? ' bd-row-blocked' : '') }, [
				E('td', { 'class': 'td' }, [
					E('b', {}, [esc(u.name || u.mac)]), E('br'),
					E('span', { 'class': 'bd-sub' }, [esc(u.mac)])
				]),
				E('td', { 'class': 'td' }, [badge]),
				E('td', { 'class': 'td' }, [conn]),
				E('td', { 'class': 'td' }, [fmtBytes(u.rx), E('br'),
					E('span', { 'class': 'bd-sub' }, [fmtRate(u.rxps)])]),
				E('td', { 'class': 'td' }, [fmtBytes(u.tx), E('br'),
					E('span', { 'class': 'bd-sub' }, [fmtRate(u.txps)])]),
				E('td', { 'class': 'td' }, [fmtBytes(u.today_rx) + ' / ' + fmtBytes(u.today_tx)]),
				E('td', { 'class': 'td' }, [
					dn, ' / ', up, E('br'), apply
				]),
				E('td', { 'class': 'td' }, [block, reset])
			]));
		});

		if (!users.length)
			rows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', colspan: '8' }, [
					E('div', { 'class': 'bd-center' },
						[_('No clients known yet – wait for the first lease…')])
				])
			]));

		setChildren(tab, rows);
	},

	renderSched: function (sched, users) {
		var self = this;
		var tab = this.$('#bd-sched');
		if (!tab)
			return;

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

			var daysInp = E('input', { 'class': 'cbi-input', style: 'width:180px',
				value: s.days || '' });
			var startInp = E('input', { 'class': 'bd-limit cbi-input', value: s.start || '22:00' });
			var endInp = E('input', { 'class': 'bd-limit cbi-input', value: s.end || '07:00' });

			var modeSel = E('select', { 'class': 'cbi-input' });
			for (var m in MODES) {
				var o = E('option', { value: m }, [MODES[m]]);
				o.selected = (String(s.mode) === m);
				modeSel.appendChild(o);
			}

			var dnInp = E('input', { 'class': 'cbi-input bd-limit', type: 'number',
				min: '0', value: String(s.dn || 0) });
			var upInp = E('input', { 'class': 'cbi-input bd-limit', type: 'number',
				min: '0', value: String(s.up || 0) });

			var save = bdBtn(_('Update'), '', function () {
				var days = daysInp.value.trim().split(/\s+/).filter(function (d) {
					return DAYS.indexOf(d) >= 0;
				});
				if (!days.length) {
					window.alert(_('Pick at least one day (mon tue wed thu fri sat sun)'));
					return;
				}
				var mode = modeSel.value;
				if (mode === '2' && !(Number(dnInp.value) > 0 || Number(upInp.value) > 0)) {
					window.alert(_('A limit schedule needs a non-zero limit'));
					return;
				}
				self.execCmd(['sched', s.mac, 'set',
					days.join(' '), startInp.value, endInp.value,
					mode,
					String(Math.max(0, Number(dnInp.value) || 0)),
					String(Math.max(0, Number(upInp.value) || 0))])
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
					daysInp, E('br'),
					E('span', { style: 'white-space:nowrap' }, [startInp, ' – ', endInp])
				]),
				E('td', { 'class': 'td' }, [modeSel]),
				E('td', { 'class': 'td' }, [
					E('span', { style: 'white-space:nowrap' }, [dnInp, ' / ', upInp])
				]),
				E('td', { 'class': 'td' }, [save, clear])
			]));
		});

		if (!sched.length)
			rows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', colspan: '5' }, [
					E('div', { 'class': 'bd-center' }, [_('No schedules yet.')])
				])
			]));

		setChildren(tab, rows);
	},

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

	renderUsageGraph: function (el, data, isHours) {
		if (!el)
			return;
		if (!data || !data.length) {
			setChildren(el, [E('div', { 'class': 'bd-center' }, [_('No data yet')])]);
			return;
		}

		var max = 1;
		data.forEach(function (p) { max = Math.max(max, (p.rx || 0) + (p.tx || 0), p.rx || 0, p.tx || 0); });

		var cols = data.map(function (p) {
			var label = isHours ? fmtLocal(p.t) : fmtDay(p.d);
			return barCol(p.rx, p.tx, max,
				label + '\nRX ' + fmtBytes(p.rx) + '\nTX ' + fmtBytes(p.tx));
		});
		setChildren(el, cols);
	}
});