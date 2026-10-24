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
      var msText = '';
      if (ms.desiredEnabled === false) msText = '意图:禁用';
      else if (ms.consecutiveHealthFailures) msText = '健康失败×' + ms.consecutiveHealthFailures;
      else if (ms.lastHealthDetail) msText = String(ms.lastHealthDetail);
      else msText = '—';

      tr.innerHTML =
        '<td><a href="#" data-open="' + escapeHtml(name) + '">' + escapeHtml(name) + '</a></td>' +
        '<td>' + escapeHtml(e.landing || '') + '</td>' +
        '<td>' + escapeHtml(e.mode || '') + '</td>' +
        '<td>' + (enabled === true ? '是' : enabled === false ? '否' : '—') + '</td>' +
        '<td>' + escapeHtml(msText) + '</td>' +
        '<td class="actions"></td>';
      var actions = tr.querySelector('.actions');
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

  function loadEntries() {
    return api('/entries').then(function (j) {
      state.entries = j.entries || [];
      renderEntries();
    }).catch(function (e) { setErr(e.message || String(e)); });
  }

  function loadDetail() {
    var name = $('detailSelect').value;
    if (!name) return;
    state.selected = name;
    $('detailJson').textContent = '加载中…';
    Promise.all([
      api('/entries/' + encodeURIComponent(name)),
      api('/entries/' + encodeURIComponent(name) + '/keepalive')
    ]).then(function (pair) {
      var st = pair[0];
      var ka = pair[1];
      $('detailJson').textContent = JSON.stringify(st, null, 2);
      fillKeepalive(ka.keepalive || {});
      $('kaSaveMsg').textContent = '';
    }).catch(function (e) {
      $('detailJson').textContent = '错误: ' + (e.message || e);
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
    t.addEventListener('click', function () { showTab(t.getAttribute('data-tab')); });
  });
  $('btnRefresh').addEventListener('click', refreshAll);
  $('btnLoadDetail').addEventListener('click', loadDetail);
  $('keepaliveForm').addEventListener('submit', saveKeepalive);
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
