(function () {
  'use strict';

  var API = '/api/v1';
  var state = { entries: [], watches: null, paused: false, selected: null };

  function $(id) { return document.getElementById(id); }

  function setErr(msg) {
    $('footerErr').textContent = msg || '';
  }

  function api(path, opts) {
    opts = opts || {};
    return fetch(API + path, {
      method: opts.method || 'GET',
      headers: Object.assign({ 'Accept': 'application/json' }, opts.body ? { 'Content-Type': 'application/json' } : {}, opts.headers || {}),
      body: opts.body ? JSON.stringify(opts.body) : undefined
    }).then(function (r) {
      return r.json().then(function (j) {
        if (!r.ok) {
          var err = (j && j.error) || ('HTTP ' + r.status);
          if (j && Array.isArray(j.conflicts) && j.conflicts.length) {
            err = formatConflictsMessage(j.conflicts) || err;
          }
          throw new Error(err);
        }
        return j;
      }).catch(function (e) {
        if (e instanceof SyntaxError) throw new Error('HTTP ' + r.status);
        throw e;
      });
    });
  }

  function postAction(name, action) {
    return api('/entries/' + encodeURIComponent(name) + '/' + action, { method: 'POST' });
  }

  function refreshHealth() {
    return api('/health').then(function (h) {
      state.paused = !!h.paused;
      var badge = $('healthBadge');
      if (h.ok && h.paused) {
        badge.className = 'badge warn';
        badge.textContent = '已暂停探针/热重载';
      } else if (h.ok) {
        badge.className = 'badge ok';
        badge.textContent = 'Manager 运行中';
      } else {
        badge.className = 'badge err';
        badge.textContent = '异常';
      }
      setErr('');
    }).catch(function (e) {
      $('healthBadge').className = 'badge err';
      $('healthBadge').textContent = '无法连接 API';
      setErr(e.message || String(e));
    });
  }

  function renderEntries() {
    var tbody = $('entriesTable').querySelector('tbody');
    tbody.innerHTML = '';
    var empty = $('entriesEmpty');
    var list = state.entries || [];
    empty.classList.toggle('hidden', list.length > 0);
    var sel = $('detailSelect');
    var prev = sel.value;
    sel.innerHTML = '';
    list.forEach(function (e) {
      var name = e.name || '';
      var opt = document.createElement('option');
      opt.value = name;
      opt.textContent = name;
      sel.appendChild(opt);

      var tr = document.createElement('tr');
      var enabled = e.enabled;
      var ms = e.managerState || {};
      var msText = formatManagerStatus(ms, name);

      tr.innerHTML =
        '<td><a href="#" data-open="' + escapeHtml(name) + '">' + escapeHtml(name) + '</a></td>' +
        '<td>' + escapeHtml(e.landing || '') + '</td>' +
        '<td>' + escapeHtml(e.mode || '') + '</td>' +
        '<td>' + (enabled === true ? '是' : enabled === false ? '否' : '—') + '</td>' +
        '<td class="ports-cell">' + formatExposedPortsHtml(e.exposedPorts) + '</td>' +
        '<td>' + msText + '</td>' +
        '<td class="actions"></td>';
      var actions = tr.querySelector('.actions');
      var btnDetail = document.createElement('button');
      btnDetail.type = 'button';
      btnDetail.className = 'btn tiny secondary';
      btnDetail.textContent = '详情';
      btnDetail.addEventListener('click', function () {
        state.selected = name;
        sel.value = name;
        showTab('detail');
        loadDetail();
      });
      actions.appendChild(btnDetail);
      ['start', 'stop', 'restart', 'enable', 'disable'].forEach(function (act) {
        var b = document.createElement('button');
        b.type = 'button';
        b.className = 'btn tiny' + (act === 'disable' || act === 'stop' ? ' danger' : '');
        b.textContent = ({ start: '启动', stop: '停止', restart: '重启', enable: '启用', disable: '禁用' })[act];
        b.addEventListener('click', function () {
          b.disabled = true;
          postAction(name, act).then(function () {
            return loadEntries();
          }).catch(function (err) {
            setErr(err.message || String(err));
          }).then(function () { b.disabled = false; });
        });
        actions.appendChild(b);
      });
      tbody.appendChild(tr);
    });
    if (prev) sel.value = prev;
    else if (state.selected) sel.value = state.selected;

    tbody.querySelectorAll('[data-open]').forEach(function (a) {
      a.addEventListener('click', function (ev) {
        ev.preventDefault();
        state.selected = a.getAttribute('data-open');
        sel.value = state.selected;
        showTab('detail');
        loadDetail();
      });
    });
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c];
    });
  }

  function normalizePortsList(raw) {
    if (Array.isArray(raw)) {
      return raw.map(function (x) { return parseInt(x, 10); }).filter(function (n) {
        return !isNaN(n) && n >= 1 && n <= 65535;
      });
    }
    if (raw == null || raw === '') return [];
    var n = parseInt(raw, 10);
    return (!isNaN(n) && n >= 1 && n <= 65535) ? [n] : [];
  }

  function formatExposedPortsHtml(raw) {
    var ports = normalizePortsList(raw);
    if (!ports.length) return '—';
    return ports.map(function (p) {
      return '<a class="port-link" href="http://127.0.0.1:' + p + '/" target="_blank" rel="noopener noreferrer">' + p + '</a>';
    }).join(' ');
  }

  function formatConflictsMessage(conflicts) {
    if (!Array.isArray(conflicts) || !conflicts.length) return '';
    var parts = conflicts.map(function (c) {
      var port = c && c.port != null ? c.port : '?';
      if (c && c.kind === 'declared') {
        return '端口 ' + port + ' 已被 ' + (c.entry || '?') + ' 声明（' + (c.source || '?') + '）';
      }
      if (c && c.kind === 'listen') {
        var who = 'PID ' + (c.pid != null ? c.pid : '?');
        if (c.processName) who += ', ' + c.processName;
        return '端口 ' + port + ' 已被本机进程占用（' + who + '），且无法确认为本条目';
      }
      return '端口 ' + port + ' 冲突';
    });
    return '端口冲突：' + parts.join('；');
  }

  function formatManagerStatus(ms, name) {
    if (name === 'win-autostart-manager') {
      return '<span class="status-ok">控制面自身</span>';
    }
    if (!ms) return '—';
    if (ms.desiredEnabled === false) return '<span class="status-soft">意图:禁用</span>';
    var fails = Number(ms.consecutiveHealthFailures || 0);
    if (fails > 0) {
      return '<span class="status-bad">健康失败×' + fails + '</span>';
    }
    var detail = ms.lastHealthDetail ? String(ms.lastHealthDetail) : '';
    if (detail.indexOf('soft:') >= 0) {
      return '<span class="status-soft">正常（process 辅证未通过）</span>';
    }
    if (detail) return '<span class="status-ok">正常</span>';
    return '—';
  }

  function shortTime(v) {
    if (!v) return '—';
    try {
      var d = new Date(v);
      if (isNaN(d.getTime())) return String(v);
      return d.toLocaleString();
    } catch (e) {
      return String(v);
    }
  }

  function loadEntries() {
    return api('/entries').then(function (j) {
      state.entries = j.entries || [];
      renderEntries();
    }).catch(function (e) { setErr(e.message || String(e)); });
  }

  function fillSummary(st, ka) {
    // GET /entries/{name} → { ok, cli: { data }, managerState }
    var data = (st && st.cli && st.cli.data) ? st.cli.data : (st.entry || st || {});
    var ms = (st && st.managerState) || data.managerState || {};
    var name = data.name || $('detailSelect').value || '—';
    $('sumName').textContent = name;
    $('sumLanding').textContent = (data.landing || '—') + ' / ' + (data.mode || '—');
    var en = data.enabled;
    $('sumEnabled').textContent = en === true ? '是' : en === false ? '否' : '—';
    var fails = Number(ms.consecutiveHealthFailures || 0);
    var healthEl = $('sumHealth');
    if (name === 'win-autostart-manager') {
      healthEl.className = 'status-ok';
      healthEl.textContent = '控制面自身（默认不探针）';
    } else if (fails > 0) {
      healthEl.className = 'status-bad';
      healthEl.textContent = '连续失败 ×' + fails;
    } else if (ms.lastHealthDetail) {
      healthEl.className = String(ms.lastHealthDetail).indexOf('soft:') >= 0 ? 'status-soft' : 'status-ok';
      healthEl.textContent = '正常';
    } else {
      healthEl.className = '';
      healthEl.textContent = '尚无探测记录';
    }
    $('sumLastCheck').textContent = shortTime(ms.lastHealthCheckAt);
    $('sumLastOk').textContent = shortTime(ms.lastHealthOkAt);
    var restart = shortTime(ms.lastRestartAt);
    if (ms.lastRestartReason) restart += '（' + ms.lastRestartReason + '）';
    $('sumLastRestart').textContent = restart;
    $('sumDetail').textContent = ms.lastHealthDetail || '—';
  }

  function loadDetail() {
    var name = $('detailSelect').value;
    if (!name) return;
    state.selected = name;
    $('detailJson').textContent = '加载中…';
    Promise.all([
      api('/entries/' + encodeURIComponent(name)),
      api('/entries/' + encodeURIComponent(name) + '/keepalive'),
      api('/entries/' + encodeURIComponent(name) + '/ports')
    ]).then(function (pair) {
      var st = pair[0];
      var ka = pair[1];
      var ports = pair[2];
      fillSummary(st, ka);
      $('detailJson').textContent = JSON.stringify(st, null, 2);
      fillKeepalive(ka.keepalive || {});
      fillExposedPorts(ports.exposedPorts);
      $('kaSaveMsg').textContent = '';
      $('portsSaveMsg').textContent = '';
    }).catch(function (e) {
      $('detailJson').textContent = '错误: ' + (e.message || e);
    });
  }

  function fillExposedPorts(raw) {
    var ports = normalizePortsList(raw);
    $('exposedPortsInput').value = ports.length ? ports.join(',') : '';
  }

  function saveExposedPorts(ev) {
    ev.preventDefault();
    var name = $('detailSelect').value;
    if (!name) return;
    var ports = String($('exposedPortsInput').value || '').split(/[,;\s]+/).filter(Boolean).map(function (x) {
      return parseInt(x, 10);
    }).filter(function (n) { return !isNaN(n) && n >= 1 && n <= 65535; });
    // 去重保持输入顺序后由服务端升序规范化
    var seen = {};
    ports = ports.filter(function (n) {
      if (seen[n]) return false;
      seen[n] = true;
      return true;
    });
    api('/entries/' + encodeURIComponent(name) + '/ports', {
      method: 'PUT',
      body: { exposedPorts: ports }
    }).then(function () {
      $('portsSaveMsg').className = 'msg';
      $('portsSaveMsg').textContent = '已保存';
      return Promise.all([loadDetail(), loadEntries()]);
    }).catch(function (e) {
      $('portsSaveMsg').className = 'msg err';
      $('portsSaveMsg').textContent = e.message || String(e);
    });
  }

  function fillKeepalive(ka) {
    var proc = ka.process || {};
    var health = ka.health || {};
    $('kaProcEnabled').checked = !!proc.enabled;
    $('kaImageName').value = proc.imageName || '';
    $('kaCmdContains').value = proc.commandLineContains || '';
    $('kaHealthEnabled').checked = !!health.enabled;
    $('kaInterval').value = health.intervalSec != null ? health.intervalSec : 30;
    $('kaThreshold').value = health.failureThreshold != null ? health.failureThreshold : 3;
    var ports = health.tcpPorts;
    if (Array.isArray(ports)) $('kaTcpPorts').value = ports.join(',');
    else if (ports != null && ports !== '') $('kaTcpPorts').value = String(ports);
    else $('kaTcpPorts').value = '';
    var http = health.http || {};
    $('kaHttpUrl').value = http.url || '';
    var es = http.expectStatus;
    if (Array.isArray(es)) $('kaHttpStatus').value = es.join(',');
    else if (es != null) $('kaHttpStatus').value = String(es);
    else $('kaHttpStatus').value = '200';
  }

  function saveKeepalive(ev) {
    ev.preventDefault();
    var name = $('detailSelect').value;
    if (!name) return;
    var ports = String($('kaTcpPorts').value || '').split(/[,;\s]+/).filter(Boolean).map(function (x) { return parseInt(x, 10); }).filter(function (n) { return !isNaN(n); });
    var statuses = String($('kaHttpStatus').value || '200').split(/[,;\s]+/).filter(Boolean).map(function (x) { return parseInt(x, 10); }).filter(function (n) { return !isNaN(n); });
    var httpUrl = $('kaHttpUrl').value.trim();
    var body = {
      process: {
        enabled: $('kaProcEnabled').checked,
        imageName: $('kaImageName').value.trim() || null,
        commandLineContains: $('kaCmdContains').value.trim() || null
      },
      health: {
        enabled: $('kaHealthEnabled').checked,
        intervalSec: parseInt($('kaInterval').value, 10) || 30,
        failureThreshold: parseInt($('kaThreshold').value, 10) || 3,
        tcpPorts: ports,
        http: httpUrl ? { url: httpUrl, expectStatus: statuses.length ? statuses : [200] } : null
      }
    };
    api('/entries/' + encodeURIComponent(name) + '/keepalive', { method: 'PUT', body: body }).then(function () {
      $('kaSaveMsg').className = 'msg';
      $('kaSaveMsg').textContent = '已保存';
      return loadDetail();
    }).catch(function (e) {
      $('kaSaveMsg').className = 'msg err';
      $('kaSaveMsg').textContent = e.message || String(e);
    });
  }

  function renderWatches() {
    var doc = state.watches || { items: [], debounceMs: 800 };
    $('debounceMs').textContent = String(doc.debounceMs != null ? doc.debounceMs : '—');
    var tbody = $('watchesTable').querySelector('tbody');
    tbody.innerHTML = '';
    var items = doc.items || [];
    $('watchesEmpty').classList.toggle('hidden', items.length > 0);
    items.forEach(function (it) {
      var tr = document.createElement('tr');
      var paths = Array.isArray(it.paths) ? it.paths.join('\n') : (it.paths || '');
      var targets = Array.isArray(it.targets) ? it.targets.join(', ') : (it.targets || '');
      tr.innerHTML =
        '<td>' + escapeHtml(it.id || '') + '</td>' +
        '<td><pre style="max-height:120px;margin:0">' + escapeHtml(paths) + '</pre></td>' +
        '<td>' + escapeHtml(targets) + '</td>' +
        '<td>' + (it.enabled === false ? '否' : '是') + '</td>' +
        '<td class="actions"></td>';
      var btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'btn tiny danger';
      btn.textContent = '删除';
      btn.addEventListener('click', function () {
        if (!confirm('删除 watch ' + (it.id || '') + ' ?')) return;
        api('/watches/' + encodeURIComponent(it.id), { method: 'DELETE' }).then(loadWatches).catch(function (e) { setErr(e.message); });
      });
      tr.querySelector('.actions').appendChild(btn);
      tbody.appendChild(tr);
    });
  }

  function loadWatches() {
    return api('/watches').then(function (j) {
      state.watches = j;
      renderWatches();
    }).catch(function (e) { setErr(e.message || String(e)); });
  }

  function addWatch(ev) {
    ev.preventDefault();
    var paths = String($('wPaths').value || '').split(/\r?\n/).map(function (s) { return s.trim(); }).filter(Boolean);
    var targets = String($('wTargets').value || '').split(/[,;\s]+/).filter(Boolean);
    var body = {
      paths: paths,
      targets: targets,
      enabled: $('wEnabled').checked
    };
    var id = $('wId').value.trim();
    if (id) body.id = id;
    var glob = $('wGlob').value.trim();
    if (glob) body.glob = glob;
    api('/watches', { method: 'POST', body: body }).then(function () {
      $('wSaveMsg').className = 'msg';
      $('wSaveMsg').textContent = '已添加';
      $('wPaths').value = '';
      $('wTargets').value = '';
      $('wId').value = '';
      return loadWatches();
    }).catch(function (e) {
      $('wSaveMsg').className = 'msg err';
      $('wSaveMsg').textContent = e.message || String(e);
    });
  }

  function showTab(name) {
    document.querySelectorAll('.tab').forEach(function (t) {
      t.classList.toggle('active', t.getAttribute('data-tab') === name);
    });
    document.querySelectorAll('.panel').forEach(function (p) {
      p.classList.toggle('active', p.id === 'tab-' + name);
    });
  }

  function refreshAll() {
    return Promise.all([refreshHealth(), loadEntries(), loadWatches()]);
  }

  document.querySelectorAll('.tab').forEach(function (t) {
    t.addEventListener('click', function () {
      var name = t.getAttribute('data-tab');
      showTab(name);
      if (name === 'detail') loadDetail();
    });
  });
  $('btnRefresh').addEventListener('click', refreshAll);
  $('btnLoadDetail').addEventListener('click', loadDetail);
  $('detailSelect').addEventListener('change', loadDetail);
  $('keepaliveForm').addEventListener('submit', saveKeepalive);
  $('portsForm').addEventListener('submit', saveExposedPorts);
  $('watchForm').addEventListener('submit', addWatch);
  $('btnPause').addEventListener('click', function () {
    api('/pause', { method: 'POST' }).then(refreshHealth).catch(function (e) { setErr(e.message); });
  });
  $('btnResume').addEventListener('click', function () {
    api('/pause/resume', { method: 'POST' }).then(refreshHealth).catch(function (e) { setErr(e.message); });
  });

  refreshAll();
  setInterval(refreshHealth, 8000);
})();
