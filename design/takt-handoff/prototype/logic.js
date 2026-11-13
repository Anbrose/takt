class Component extends DCLogic {
  tree() {
    return { id: 'root', name: '日本旅行', children: [
      { id: 'osaka', name: '大阪', short: '大阪', place: '大阪府 · 关西', lat: 34.6937, lng: 135.5023, pre: [{ action: '预订去程机票', rank: 2 }, { action: '预订大阪住宿', rank: 2 }], children: [
        { id: 'castle', name: '大阪城天守阁', short: '大阪城', place: '中央区 · 大阪城公园', lat: 34.6873, lng: 135.5262, pre: [{ action: '购买天守阁门票', rank: 3 }] },
        { id: 'usj', name: '日本环球影城', short: '环球影城', place: '此花区 · 樱岛', lat: 34.6654, lng: 135.4323, pre: [{ action: '购买指定日期入园门票', rank: 2 }, { action: '抢购快速通关券', rank: 1 }] },
        { id: 'dotonbori', name: '道顿堀', short: '道顿堀', place: '中央区 · 难波', lat: 34.6687, lng: 135.5013, pre: [] },
        { id: 'kaiyukan', name: '海游馆', short: '海游馆', place: '港区 · 天保山', lat: 34.6545, lng: 135.4290, pre: [{ action: '网上预约入场时段', rank: 2 }] },
        { id: 'umeda', name: '梅田蓝天大厦空中庭园', short: '梅田空中庭园', place: '北区 · 梅田', lat: 34.7053, lng: 135.4903, pre: [{ action: '购买展望台门票', rank: 3 }] },
        { id: 'tsutenkaku', name: '通天阁', short: '通天阁', place: '浪速区 · 新世界', lat: 34.6525, lng: 135.5063, pre: [{ action: '购买展望台门票', rank: 3 }] }
      ] },
      { id: 'tokyo', name: '东京', short: '东京', place: '东京都 · 关东', lat: 35.6812, lng: 139.7671, pre: [{ action: '预订东京住宿', rank: 2 }, { action: '购买大阪→东京新干线车票', rank: 3 }], children: [
        { id: 'ghibli', name: '三鹰之森吉卜力美术馆', short: '吉卜力', place: '三鹰市 · 井之头公园', lat: 35.6962, lng: 139.5704, pre: [{ action: '抢购指定日期时段门票', rank: 1 }] },
        { id: 'shibuyasky', name: '涩谷 SKY', short: '涩谷 SKY', place: '涩谷区 · 涩谷站', lat: 35.6585, lng: 139.7022, pre: [{ action: '预约指定时段门票', rank: 2 }] },
        { id: 'teamlab', name: 'teamLab Planets', short: 'teamLab', place: '江东区 · 丰洲', lat: 35.6491, lng: 139.7898, pre: [{ action: '预约指定时段门票', rank: 2 }] },
        { id: 'sensoji', name: '浅草寺', short: '浅草寺', place: '台东区 · 浅草', lat: 35.7148, lng: 139.7967, pre: [] },
        { id: 'tokyotower', name: '东京塔', short: '东京塔', place: '港区 · 芝公园', lat: 35.6586, lng: 139.7454, pre: [{ action: '购买展望台门票', rank: 3 }] }
      ] },
      { id: 'hokkaido', name: '北海道', short: '北海道', place: '札幌 · 北海道', lat: 43.0618, lng: 141.3545, pre: [{ action: '预订东京→札幌机票', rank: 2 }, { action: '预订回程机票', rank: 2 }], children: [
        { id: 'odori', name: '大通公园', short: '大通公园', place: '札幌市 · 中央区', lat: 43.0600, lng: 141.3478, pre: [] },
        { id: 'otaru', name: '小樽运河', short: '小樽', place: '小樽市', lat: 43.1984, lng: 141.0020, pre: [] },
        { id: 'noboribetsu', name: '登别地狱谷', short: '登别', place: '登别市 · 登别温泉', lat: 42.4977, lng: 141.1466, pre: [{ action: '预订温泉旅馆', rank: 2 }] },
        { id: 'toya', name: '洞爷湖', short: '洞爷湖', place: '洞爷湖町', lat: 42.6000, lng: 140.8500, pre: [] },
        { id: 'hakodate', name: '函馆山夜景', short: '函馆山', place: '函馆市', lat: 41.7590, lng: 140.7044, pre: [{ action: '购买缆车票', rank: 3 }] }
      ] }
    ] };
  }

  km(a, b) {
    var rad = Math.PI / 180;
    var dLat = (b.lat - a.lat) * rad;
    var dLng = (b.lng - a.lng) * rad;
    var h = Math.sin(dLat / 2) * Math.sin(dLat / 2) + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLng / 2) * Math.sin(dLng / 2);
    return 6371 * 2 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
  }

  fmt(d) { return d >= 100 ? String(Math.round(d)) : d.toFixed(1); }

  routeKm(list) {
    var total = 0;
    for (var i = 1; i < list.length; i++) total += this.km(list[i - 1], list[i]);
    return total;
  }

  bestOrder(list) {
    if (list.length < 3) return list.slice();
    var self = this;
    var best = null;
    var bestKm = Infinity;
    function walk(done, rest) {
      if (!rest.length) {
        var d = self.routeKm(done);
        if (d < bestKm - 1e-9) { bestKm = d; best = done; }
        return;
      }
      for (var i = 0; i < rest.length; i++) {
        walk(done.concat([rest[i]]), rest.slice(0, i).concat(rest.slice(i + 1)));
      }
    }
    walk([list[0]], list.slice(1));
    return best;
  }

  tagStyle(rank) {
    if (rank === 1) return { tag: '尽早订', tagBg: 'var(--fill)', tagFg: 'var(--onfill)', tagBorder: 'var(--fill)' };
    if (rank === 2) return { tag: '行前订', tagBg: 'var(--soft)', tagFg: 'var(--accent-text)', tagBorder: 'var(--accent)' };
    return { tag: '现场办', tagBg: 'transparent', tagFg: 'var(--muted)', tagBorder: 'var(--line)' };
  }

  componentDidUpdate() {
    var pf = this._preFill;
    if (pf) {
      this._preFill = null;
      try {
        Array.prototype.forEach.call(pf.form.querySelectorAll('[data-f="pre"]'), function (el, i) { el.value = pf.vals[i] || ''; });
      } catch (err) {}
    }
    var f = this._flip;
    if (!f) return;
    this._flip = null;
    try {
      var moving = [];
      Array.prototype.forEach.call(f.el.querySelectorAll('[data-list]'), function (list) {
        var base = list.getBoundingClientRect().top;
        var name = list.getAttribute('data-list');
        Array.prototype.forEach.call(list.querySelectorAll('[data-row]'), function (el) {
          var from = f.tops[name + '|' + el.getAttribute('data-row')];
          if (from === undefined) return;
          var d = from - (el.getBoundingClientRect().top - base);
          if (Math.abs(d) < 1) return;
          el.style.transition = 'none';
          el.style.transform = 'translateY(' + d + 'px)';
          moving.push(el);
        });
      });
      if (f.focus) {
        var h = f.el.querySelector(f.focus);
        if (h) h.focus();
      }
      f.el.getBoundingClientRect();
      requestAnimationFrame(function () {
        moving.forEach(function (el) { el.style.transition = 'transform 240ms ease'; el.style.transform = 'translateY(0px)'; });
        setTimeout(function () { moving.forEach(function (el) { el.style.transition = ''; el.style.transform = ''; }); }, 280);
      });
    } catch (err) {}
  }

  renderVals() {
    var self = this;
    var st = this.state || {};
    var root = this.tree();
    var added = st.added || {};
    root.children = root.children.concat((added.root || []).map(function (t) {
      var c = {}; Object.keys(t).forEach(function (k) { c[k] = t[k]; }); c.children = []; return c;
    }));
    root.children.forEach(function (c) { c.children = c.children.concat(added[c.id] || []); });
    function hasGeo(t) { return typeof t.lat === 'number'; }
    var theme = st.theme || this.props.theme || 'light';
    var dark = theme === 'dark';
    var levelId = st.level || 'root';
    var orders = st.order || {};
    var sels = st.sel || {};
    var done = st.done || {};
    var tab = st.tab || 'tasks';
    var plan = (st.mode || 'plan') === 'plan';
    var mapOn = tab === 'map';
    var objective = st.objective || 'dist';
    var travel = st.travel || 'transit';

    function ordered(node) {
      var ids = orders[node.id] || node.children.map(function (c) { return c.id; });
      var map = {};
      node.children.forEach(function (c) { map[c.id] = c; });
      return ids.map(function (id) { return map[id]; });
    }
    function patch(obj, key, val) {
      var copy = {};
      Object.keys(obj).forEach(function (k) { copy[k] = obj[k]; });
      copy[key] = val;
      return copy;
    }

    var level = levelId === 'root' ? root : root.children.filter(function (c) { return c.id === levelId; })[0];
    var isRoot = levelId === 'root';
    var draft = st.draft && st.draft.level === levelId ? st.draft : null;
    var drag = st.drag || null;
    var editing = !!(drag || draft);
    var ids = draft ? draft.ids : ordered(level).map(function (t) { return t.id; });
    var childMap = {};
    level.children.forEach(function (c) { childMap[c.id] = c; });
    var items = ids.map(function (id) { return childMap[id]; });
    var selIds = sels[levelId] || [];
    var scopeAll = selIds.length === 0;
    var scoped = scopeAll ? items : items.filter(function (t) { return selIds.indexOf(t.id) >= 0; });
    var geo = scoped.filter(hasGeo);

    function setOrder(next) { self.setState({ order: patch(orders, levelId, next) }); }
    function setSel(next) { self.setState({ sel: patch(sels, levelId, next) }); }
    function go(id) { self._drag = null; self.setState({ level: id, tab: 'tasks', draft: null, drag: null, navSeq: (st.navSeq || 0) + 1, navDir: id === 'root' ? 'L' : 'R' }); }

    function navVals(node, indent, count) {
      var active = node.id === levelId;
      return {
        name: node.name, indent: indent, count: count, pressed: active ? 'true' : 'false',
        bg: active ? 'var(--soft)' : 'transparent', border: active ? 'var(--accent)' : 'transparent',
        weight: active ? '700' : '500',
        pick: function () { go(node.id); }
      };
    }
    var levels = [navVals(root, '0px', root.children.length + ' 项')].concat(ordered(root).map(function (c) {
      return navVals(c, '18px', c.children.length + ' 项');
    }));

    function snap(src) {
      var rootEl = (src.closest && src.closest('.app')) || src;
      var o = { el: rootEl, tops: {} };
      Array.prototype.forEach.call(rootEl.querySelectorAll('[data-list]'), function (list) {
        var base = list.getBoundingClientRect().top;
        var name = list.getAttribute('data-list');
        Array.prototype.forEach.call(list.querySelectorAll('[data-row]'), function (r) {
          o.tops[name + '|' + r.getAttribute('data-row')] = r.getBoundingClientRect().top - base;
        });
      });
      return o;
    }
    function heights(el) {
      return Array.prototype.map.call(el.querySelectorAll('[data-row]'), function (r) { return r.getBoundingClientRect().height; });
    }
    function layoutTop(el, hs, k, gap) {
      var top = el.getBoundingClientRect().top;
      for (var j = 0; j < k; j++) top += hs[j] + gap;
      return top;
    }
    function moved(arr, from, to) {
      var a = arr.slice();
      var x = a.splice(from, 1)[0];
      a.splice(to, 0, x);
      return a;
    }
    function dragKit(listName, listIds, gap, toFull) {
      return function (t, i) {
        var d = drag && drag.list === listName ? drag : null;
        var info = self._drag;
        var tf = 'none', tr = 'border-color 280ms ease, background-color 280ms ease, opacity 280ms ease', z = '0', shadow = 'none';
        if (d && info) {
          var amt = info.hs[d.from] + gap;
          if (i === d.from) {
            tf = 'translateY(' + d.y.toFixed(1) + 'px)'; tr = 'none'; z = '2'; shadow = '0 10px 24px rgba(0, 0, 0, 0.22)';
          } else {
            tr = 'transform 180ms ease';
            if (i > d.from && i <= d.to) tf = 'translateY(' + (-amt) + 'px)';
            else if (i < d.from && i >= d.to) tf = 'translateY(' + amt + 'px)';
          }
        }
        return {
          id: t.id, tf: tf, tr: tr, z: z, shadow: shadow,
          dragAria: '拖动调整顺序：' + t.name + '（也可用上下方向键）',
          down: function (e) {
            if (e.button) return;
            var el = e.currentTarget.closest('[data-list]');
            if (!el) return;
            var hs = heights(el);
            self._drag = { el: el, startY: e.clientY, hs: hs, top0: layoutTop(el, hs, i, gap) };
            self._list = el;
            try { e.currentTarget.setPointerCapture(e.pointerId); } catch (err) {}
            e.preventDefault();
            self.setState({ drag: { list: listName, from: i, to: i, y: 0 } });
          },
          move: function (e) {
            var info2 = self._drag;
            if (!info2 || !d || i !== d.from) return;
            var hs = heights(info2.el);
            info2.hs = hs;
            var y = e.clientY - info2.startY - (layoutTop(info2.el, hs, d.from, gap) - info2.top0);
            var cum = [], acc = 0;
            hs.forEach(function (h) { cum.push(acc); acc += h + gap; });
            var c = cum[d.from] + hs[d.from] / 2 + y;
            var to = d.from, n = hs.length;
            while (to < n - 1 && c > cum[to + 1] + hs[to + 1] / 2) to++;
            while (to > 0 && c < cum[to - 1] + hs[to - 1] / 2) to--;
            self.setState({ drag: { list: listName, from: d.from, to: to, y: y } });
          },
          up: function () {
            var info2 = self._drag;
            if (!info2 || !d) return;
            try { self._flip = snap(info2.el); } catch (err) {}
            self._drag = null;
            self.setState({ drag: null, draft: { level: levelId, ids: toFull(moved(listIds, d.from, d.to)) } });
          },
          key: function (e) {
            var delta = e.key === 'ArrowUp' ? -1 : e.key === 'ArrowDown' ? 1 : 0;
            var j = i + delta;
            if (!delta || j < 0 || j >= listIds.length) return;
            e.preventDefault();
            var el = e.currentTarget.closest('[data-list]');
            if (el) {
              self._list = el;
              try { self._flip = snap(el); self._flip.focus = '[data-list="' + listName + '"] [data-row="' + t.id + '"] [data-handle]'; } catch (err) {}
            }
            self.setState({ draft: { level: levelId, ids: toFull(moved(listIds, i, j)) } });
          }
        };
      };
    }
    var rowDrag = dragKit('rows', ids, 10, function (list) { return list; });
    function legFull(list) {
      var next = ids.slice();
      scoped.map(function (t) { return ids.indexOf(t.id); }).forEach(function (slot, j) { next[slot] = list[j]; });
      return next;
    }
    var legDrag = dragKit('legs', scoped.map(function (t) { return t.id; }), 0, legFull);
    function makeRail(listName, nodes, toFull) {
      var on = !!(drag && drag.list === listName);
      var own = nodes.map(function (t) { return t.id; });
      var live = on ? moved(own, drag.from, drag.to) : own;
      var full = toFull(live);
      return {
        w: on ? '52px' : '0px', mr: on ? '8px' : '0px', o: on ? '1' : '0',
        items: nodes.map(function (t, i) {
          var held = on && i === drag.from;
          return {
            num: String(full.indexOf(t.id) + 1),
            abbr: /^[\x00-\x7f]/.test(t.short) ? t.short.slice(0, 4) : t.short.slice(0, 2),
            y: 'translateY(' + ((live.indexOf(t.id) - i) * 26) + 'px)',
            fg: held ? 'var(--accent-text)' : 'var(--text)', weight: held ? '700' : '500'
          };
        })
      };
    }

    var rows = items.map(function (t, i) {
      var on = selIds.indexOf(t.id) >= 0;
      var kids = t.children ? t.children.length : 0;
      var dk = rowDrag(t, i);
      var si = geo.indexOf(t);
      var lost = scoped.indexOf(t) >= 0 && si < 0;
      return {
        leg: lost ? '未定位' : si < 0 ? '' : si === 0 ? '起点' : '+' + self.fmt(self.km(geo[si - 1], t)) + ' km',
        enter: st.lastAdded === t.id ? 'inRA 320ms ease' : 'none',
        legO: mapOn ? '1' : '0', dim: mapOn && si < 0 ? '0.45' : '1',
        detailRows: mapOn ? '0fr' : '1fr', detailO: mapOn ? '0' : '1', kidsOff: mapOn,
        id: dk.id, tf: dk.tf, tr: dk.tr, z: dk.z, shadow: dk.shadow, dragAria: dk.dragAria,
        down: dk.down, move: dk.move, up: dk.up, key: dk.key,
        num: (i + 1) + '.', name: t.name, place: t.place,
        pressed: on ? 'true' : 'false', check: on ? '✓' : '',
        checkAria: (on ? '取消勾选：' : '勾选：') + t.name,
        border: on ? 'var(--accent)' : 'var(--line)',
        boxBg: on ? 'var(--fill)' : 'transparent',
        boxBorder: on ? 'var(--fill)' : 'var(--muted)',
        noPre: t.pre.length === 0,
        pre: t.pre.map(function (p) {
          var ts = self.tagStyle(p.rank);
          return { action: p.action, tagBg: ts.tagBg, tagFg: ts.tagFg, tagBorder: ts.tagBorder };
        }),
        toggle: function () { setSel(on ? selIds.filter(function (id) { return id !== t.id; }) : selIds.concat([t.id])); },
        hasKids: !!t.children, kidsLabel: kids + ' 项',
        open: function () { go(t.id); }
      };
    });

    var located = items.filter(hasGeo);
    var lats = located.map(function (t) { return t.lat; });
    var lngs = located.map(function (t) { return t.lng; });
    var minLat = Math.min.apply(null, lats), maxLat = Math.max.apply(null, lats);
    var minLng = Math.min.apply(null, lngs), maxLng = Math.max.apply(null, lngs);
    var midLat = (minLat + maxLat) / 2, midLng = (minLng + maxLng) / 2;
    var kx = Math.cos(midLat * Math.PI / 180);
    var scale = Math.min(460 / Math.max((maxLng - minLng) * kx, 1e-6), 300 / Math.max(maxLat - minLat, 1e-6));
    function xy(t) {
      return { x: 300 + (t.lng - midLng) * kx * scale, y: 210 - (t.lat - midLat) * scale };
    }

    var pins = located.map(function (t) {
      var i = ids.indexOf(t.id);
      var on = geo.indexOf(t) >= 0;
      var p = xy(t);
      return {
        name: t.short, num: on ? String(i + 1) : '',
        left: (p.x / 600 * 100).toFixed(2) + '%', top: (p.y / 440 * 100).toFixed(2) + '%',
        size: on ? '28px' : '12px', offset: on ? '-14px 0 0 -14px' : '-6px 0 0 -6px',
        bg: on ? 'var(--fill)' : 'var(--surface)',
        border: on ? 'var(--surface)' : 'var(--muted)',
        weight: on ? '700' : '400',
        labelFg: on ? 'var(--text)' : 'var(--muted)'
      };
    });

    var routePts = geo.map(function (t) { var p = xy(t); return p.x.toFixed(1) + ',' + p.y.toFixed(1); }).join(' ');
    var curKm = this.routeKm(geo);
    var best = this.bestOrder(geo);
    var extra = curKm - this.routeKm(best);
    var showDetour = geo.length >= 3 && extra > 0.05;

    var legs = scoped.map(function (t, i) {
      var dk = legDrag(t, i);
      return {
        id: dk.id, tf: dk.tf, tr: dk.tr, z: dk.z, shadow: dk.shadow, dragAria: dk.dragAria,
        down: dk.down, move: dk.move, up: dk.up, key: dk.key,
        num: String(ids.indexOf(t.id) + 1), name: t.name,
        leg: ''
      };
    });

    var prep = [];
    scoped.forEach(function (t) {
      t.pre.forEach(function (p, i) { prep.push({ key: t.id + ':' + i, task: t.name, action: p.action, rank: p.rank }); });
    });
    prep.sort(function (a, b) { return a.rank - b.rank; });
    prep = prep.map(function (p, i) {
      var isDone = !!done[p.key];
      var ts = self.tagStyle(p.rank);
      return {
        action: p.action, task: p.task, tag: ts.tag, tagBg: ts.tagBg, tagFg: ts.tagFg, tagBorder: ts.tagBorder,
        mark: isDone ? '✓' : String(i + 1), pressed: isDone ? 'true' : 'false',
        aria: (isDone ? '标记为未完成：' : '标记为已完成：') + p.action,
        dotBg: isDone ? 'var(--fill)' : 'transparent',
        dotFg: isDone ? 'var(--onfill)' : 'var(--text)',
        dotBorder: isDone ? 'var(--fill)' : 'var(--muted)',
        deco: isDone ? 'line-through' : 'none', opacity: isDone ? '0.6' : '1',
        toggle: function () { self.setState({ done: patch(done, p.key, !isDone) }); }
      };
    });
    var noPrep = scoped.filter(function (t) { return t.pre.length === 0; }).length;
    var left = prep.filter(function (p) { return p.pressed === 'false'; }).length;

    function toTop(e) {
      try {
        var p = e.currentTarget.closest('.app').querySelector('[data-pane="main"]');
        if (p && p.scrollTo) p.scrollTo({ top: 0, behavior: 'smooth' });
      } catch (err) {}
    }
    function tabVals(id, badge) {
      var on = tab === id;
      return {
        fg: on ? 'var(--accent-text)' : 'var(--muted)', weight: on ? '700' : '500',
        pressed: on ? 'true' : 'false', badge: String(badge), hasBadge: badge > 0,
        pick: function (e) { if (id === 'map') toTop(e); self.setState({ tab: id }); }
      };
    }

    function seg(label, on, pick) {
      return {
        label: label, pressed: on ? 'true' : 'false', pick: pick,
        bg: on ? 'var(--fill)' : 'transparent', fg: on ? 'var(--onfill)' : 'var(--muted)'
      };
    }
    var modeSegs = [
      seg('规划', plan, function () { self.setState({ mode: 'plan' }); }),
      seg('进行中', !plan, function () { self.setState({ mode: 'run' }); })
    ];
    var objSegs = [
      seg('距离', objective === 'dist', function () { self.setState({ objective: 'dist' }); }),
      seg('耗时', objective === 'time', function () { self.setState({ objective: 'time' }); })
    ];
    var travelSegs = [['walk', '步行'], ['transit', '公交'], ['drive', '自驾']].map(function (m) {
      return seg(m[1], travel === m[0], function () { self.setState({ travel: m[0] }); });
    });

    function checkVals(t, p, i) {
      var key = t.id + ':' + i;
      var isDone = !!done[key];
      return {
        action: p.action, tag: self.tagStyle(p.rank).tag,
        mark: isDone ? '✓' : '', pressed: isDone ? 'true' : 'false',
        aria: (isDone ? '标记为未完成：' : '标记为已完成：') + p.action,
        dotBg: isDone ? 'var(--fill)' : 'transparent', dotBorder: isDone ? 'var(--fill)' : 'var(--muted)',
        deco: isDone ? 'line-through' : 'none', opacity: isDone ? '0.6' : '1',
        toggle: function () { self.setState({ done: patch(done, key, !isDone) }); }
      };
    }
    var flat = [];
    ordered(root).forEach(function (top) {
      ordered(top).forEach(function (t) { flat.push({ task: t, parent: top }); });
    });
    var runIdx = st.runIdx === undefined ? 1 : st.runIdx;
    var cur = flat[runIdx];
    var nxt = flat[runIdx + 1];
    var run = {
      active: !!cur, finished: !cur,
      progress: cur ? (runIdx + 1) + ' / ' + flat.length : flat.length + ' / ' + flat.length,
      pct: (Math.min(runIdx, flat.length) / flat.length * 100).toFixed(0) + '%',
      finish: function () { self.setState({ runIdx: runIdx + 1, runSeq: (st.runSeq || 0) + 1, runDir: 'R' }); },
      prev: function () { if (runIdx > 0) self.setState({ runIdx: runIdx - 1, runSeq: (st.runSeq || 0) + 1, runDir: 'L' }); },
      prevOff: runIdx === 0, prevOpacity: runIdx === 0 ? '0.4' : '1',
      restart: function () { self.setState({ runIdx: 0, runSeq: (st.runSeq || 0) + 1, runDir: 'L' }); }
    };
    if (cur) {
      run.path = cur.parent.name;
      run.name = cur.task.name;
      run.place = cur.task.place;
      run.pre = cur.task.pre.map(function (p, i) { return checkVals(cur.task, p, i); });
      run.noPre = cur.task.pre.length === 0;
      run.hasNext = !!nxt;
      run.isLast = !nxt;
      run.finishLabel = '完成';
      var later = flat.slice(runIdx + 2, runIdx + 5).map(function (f) { return { name: f.task.name, where: f.parent.name }; });
      run.later = later;
      run.hasLater = later.length > 0;
    }
    if (cur && nxt) {
      var change = nxt.parent.id !== cur.parent.id;
      var nextPre = nxt.task.pre.map(function (p, i) { return checkVals(nxt.task, p, i); });
      if (change) nextPre = nxt.parent.pre.map(function (p, i) { return checkVals(nxt.parent, p, i); }).concat(nextPre);
      run.nextName = nxt.task.name;
      run.nextInfo = nxt.parent.name + ' · ' + nxt.task.place;
      run.nextDist = hasGeo(cur.task) && hasGeo(nxt.task) ? '约 ' + self.fmt(self.km(cur.task, nxt.task)) + ' km' : '';
      run.stageChange = change;
      run.stageLabel = cur.parent.name + ' → ' + nxt.parent.name;
      run.nextPre = nextPre;
      run.nextHasPre = nextPre.length > 0;
      run.nextNoPre = nextPre.length === 0;
    }

    function anim(seq, dir) { return seq ? 'in' + (dir || 'R') + (seq % 2 ? 'A' : 'B') + ' 280ms ease' : 'none'; }
    function pane(on) { return { vis: on ? 'visible' : 'hidden', tr: on ? 'visibility 0s' : 'visibility 0s linear 320ms' }; }
    var tabIdx = tab === 'map' ? 1 : tab === 'prep' ? 2 : 0;
    var canOpt = showDetour && !editing;
    var showBackBtn = plan && !isRoot;
    var aiOn = tab === 'tasks';

    var addOpen = !!st.addOpen;
    var preCount = st.preCount || 0;
    var preRows = [];
    for (var pi = 0; pi < preCount; pi++) {
      (function (k) {
        preRows.push({
          aria: '前置条件 ' + (k + 1), rmAria: '删除前置条件 ' + (k + 1),
          remove: function (e) {
            var form = e.currentTarget.closest('[data-add]');
            var vals = Array.prototype.map.call(form.querySelectorAll('[data-f="pre"]'), function (el) { return el.value; });
            vals.splice(k, 1);
            self._preFill = { form: form, vals: vals };
            self.setState({ preCount: preCount - 1 });
          }
        });
      })(pi);
    }
    var addVals = {
      y: addOpen ? 'translateY(0%)' : 'translateY(110%)',
      desk: addOpen ? 'translate(-50%, 0%)' : 'translate(-50%, 130%)',
      scrimO: addOpen ? '1' : '0', off: !addOpen, level: level.name,
      pres: preRows, preH: (preCount * 56) + 'px',
      addPre: function (e) {
        var form = e.currentTarget.closest('[data-add]');
        self.setState({ preCount: preCount + 1 });
        setTimeout(function () { try { form.querySelectorAll('[data-f="pre"]')[preCount].focus(); } catch (err) {} }, 80);
      },
      vis: addOpen ? 'visible' : 'hidden', visTr: addOpen ? 'visibility 0s' : 'visibility 0s linear 320ms',
      open: function (e) {
        var app = e.currentTarget.closest('.app');
        self.setState({ addOpen: true });
        setTimeout(function () { try { app.querySelector('[data-add] input').focus(); } catch (err) {} }, 340);
      },
      close: function () { self.setState({ addOpen: false }); },
      submit: function (e) {
        e.preventDefault();
        var form = e.currentTarget;
        function val(k) { var el = form.querySelector('[data-f="' + k + '"]'); return el ? el.value.trim() : ''; }
        var name = val('name');
        if (!name) { try { form.querySelector('[data-f="name"]').focus(); } catch (err) {} return; }
        var task = { id: 'n' + Date.now(), name: name, short: name, place: val('place') || '未填地点', lat: null, lng: null, pre: Array.prototype.map.call(form.querySelectorAll('[data-f="pre"]'), function (el) { return el.value.trim(); })
            .filter(function (x) { return x; }).map(function (x) { return { action: x, rank: 2 }; }) };
        var next = { added: patch(added, levelId, (added[levelId] || []).concat([task])), addOpen: false, lastAdded: task.id, preCount: 0 };
        if (orders[levelId]) next.order = patch(orders, levelId, orders[levelId].concat([task.id]));
        if (draft) next.draft = { level: levelId, ids: draft.ids.concat([task.id]) };
        Array.prototype.forEach.call(form.querySelectorAll('input'), function (el) { el.value = ''; });
        var app = form.closest('.app');
        self.setState(next);
        setTimeout(function () {
          try { var p = app.querySelector('[data-pane="main"]'); if (p) p.scrollTo({ top: p.scrollHeight, behavior: 'smooth' }); } catch (err) {}
        }, 60);
      }
    };

    return {
      add: addVals,
      navAnim: anim(st.navSeq, st.navDir), runAnim: anim(st.runSeq, st.runDir),
      mode: { items: modeSegs, w: 'calc((100% - 8px) / 2)', x: plan ? '0%' : '100%' },
      obj: { items: objSegs, w: 'calc((100% - 8px) / 2)', x: objective === 'dist' ? '0%' : '100%' },
      trav: { items: travelSegs, w: 'calc((100% - 8px) / 3)', x: (travel === 'walk' ? 0 : travel === 'transit' ? 100 : 200) + '%' },
      modeX: plan ? 'translateX(0%)' : 'translateX(-50%)',
      planPane: pane(plan), runPane: pane(!plan),
      tabX: tabIdx === 2 ? 'translateX(-50%)' : 'translateX(0%)', tabIndX: (tabIdx * 100) + '%',
      mainPane: pane(plan && tabIdx !== 2),
      mapWrap: {
        rows: mapOn ? '1fr' : '0fr', mb: mapOn ? '0px' : '-12px', o: mapOn ? '1' : '0',
        vis: mapOn ? 'visible' : 'hidden', visTr: mapOn ? 'visibility 0s' : 'visibility 0s linear 380ms'
      },
      mapBtn: { pressed: mapOn ? 'true' : 'false', bg: mapOn ? 'var(--soft)' : 'var(--surface)', border: mapOn ? 'var(--accent)' : 'var(--line)' },
      toggleMap: function (e) { if (!mapOn) toTop(e); self.setState({ tab: mapOn ? 'tasks' : 'map' }); },
      tasksPane: pane(plan && tabIdx === 0), mapPane: pane(plan && tabIdx === 1), prepPane: pane(plan && tabIdx === 2),
      ai: { h: aiOn ? '60px' : '0px', o: aiOn ? '1' : '0', off: !aiOn },
      backBtn: { w: showBackBtn ? '44px' : '0px', o: showBackBtn ? '1' : '0', off: !showBackBtn },
      statusText: editing ? '预览中' : geo.length < 2 ? '至少 2 项' : showDetour ? '多绕 ' + this.fmt(extra) + ' km' : '不绕路',
      opt: { o: canOpt ? '1' : '0', off: !canOpt },
      modeSegs: modeSegs, objSegs: objSegs, travelSegs: travelSegs, run: run,
      planMode: plan, showRun: !plan,
      
      title: plan ? level.name : root.name,
      overline: plan && !isRoot ? root.name : 'Project',
      showBack: plan && !isRoot,
      subCrumb: isRoot ? '' : '/ ' + level.name,
      themeCls: dark ? 't-dark' : 't-light',
      themeLabel: dark ? '切换到浅色' : '切换到深色',
      toggleTheme: function () { self.setState({ theme: dark ? 'light' : 'dark' }); },
      levels: levels, levelName: level.name, isRoot: isRoot, notRoot: !isRoot,
      crumb: isRoot ? 'Flow · ' + items.length + ' 个任务' : root.name + ' / ' + level.name,
      back: function () { go('root'); },
      rows: rows,
      allLabel: scopeAll ? '全选' : '清空',
      toggleAll: function () { setSel(scopeAll ? ids.slice() : []); },
      scopeLabel: scopeAll ? items.length + ' 项' : '已选 ' + scoped.length + ' 项',
      openMap: function () { self.setState({ tab: 'map' }); },
      tabTasks: tabVals('tasks', selIds.length), tabMap: tabVals('map', 0), tabPrep: tabVals('prep', left),
      showTasks: plan && tab === 'tasks', showMap: plan && tab === 'map', showPrep: plan && tab === 'prep',
      pins: pins, routePts: routePts, legs: legs,
      distLabel: geo.length >= 2 ? '约 ' + this.fmt(curKm) + ' km' : '—',
      showDetour: showDetour && !editing,
      showOptimal: geo.length >= 2 && !showDetour && !editing,
      rail: makeRail('rows', items, function (list) { return list; }),
      legRail: makeRail('legs', scoped, legFull),
      sheetY: editing ? 'translateY(0%)' : 'translateY(110%)',
      deskSheet: editing ? 'translate(-50%, 0px)' : 'translate(-50%, 140px)',
      sheetO: editing ? '1' : '0',
      bar: {
        h: editing ? '62px' : '0px', mb: editing ? '0px' : '-12px', o: editing ? '1' : '0', off: !editing,
        cancel: function (e) {
          try { self._flip = snap((e && e.currentTarget) || self._list); } catch (err) {}
          self._drag = null;
          self.setState({ draft: null, drag: null });
        },
        confirm: function () {
          if (!draft) return;
          self.setState({ order: patch(orders, levelId, draft.ids), draft: null, drag: null });
        }
      },
      showMapEmpty: scoped.length < 2,
      detourLabel: '当前排列比最短路线多绕约 ' + this.fmt(extra) + ' km',
      optimize: function (e) {
        try { if (e && e.currentTarget) self._flip = snap(e.currentTarget); } catch (err) {}
        var next = ids.slice();
        var slots = geo.map(function (t) { return ids.indexOf(t.id); });
        slots.forEach(function (slot, j) { next[slot] = best[j].id; });
        setOrder(next);
      },
      prep: prep, prepEmpty: prep.length === 0,
      noPrepLabel: noPrep + ' 项无需准备'
    };
  }
}
