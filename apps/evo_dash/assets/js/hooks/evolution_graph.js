// EvolutionGraph hook — 任务演化图（横版，左→右生长）
//
// 移植自 evogit-tree-lr.html 的图形引擎（布局/渲染/动效/视图/图例），
// 剥离其模拟器（tick/decompose/fake 数据/播放控制/时间轴回放）。
// 数据由 LiveView 驱动：
//   - 初始：hook 容器的 data-agents JSON（dead render 注入）
//   - 增量：push_event("agents:sync", %{nodes: [...]})
//   - 选中：push_event("agents:select" / "agents:deselect")
// 交互：
//   - 点击节点 → pushEvent("select_agent", {id})（由 AgentsLive 现有事件处理）
//   - 点击空白 → pushEvent("close_details", {})
//   - ?demo=1 → 服务端下发内置演示数据（两棵独立树，走真实切换路径），
//     这里仅抑制节点点选（演示节点没有详情面板）

const SVGNS = 'http://www.w3.org/2000/svg';

const DEPTH_GAP = 172;   // 相邻深度的层间距（横版：x 方向）
const SIB_GAP = 58;      // 同层兄弟最小间距（横版：y 方向）
const R = 11;

const STATUS_CN = {
  pending: '待执行', blocked: '阻塞（等槽位）', running: '执行中',
  waiting: '等待子任务', ready: '即将恢复', completed: '已完成', failed: '失败重试',
};

const NODE_LEGEND = [
  ['pending',   '待执行'],
  ['blocked',   '阻塞'],
  ['running',   '执行中'],
  ['waiting',   '等待子任务'],
  ['ready',     '子任务齐'],
  ['completed', '已完成'],
  ['failed',    '失败'],
];
const EDGE_LEGEND = [
  ['st-running', '子执行中'],
  ['st-waiting', '子等待中'],
  ['st-ready',   '子即将恢复'],
  ['st-pending', '子排队 / 阻塞'],
  ['converge',   '结果收敛'],
];

const EvolutionGraph = {
  mounted() {
    // ?demo=1 时服务端会下发演示数据（走真实代码路径），这里仅用于抑制
    // 节点点选事件（演示数据没有对应的详情面板）
    this.demo = new URLSearchParams(window.location.search).get('demo') === '1' ||
      this.el.dataset.interactive === 'false';
    this.nodes = new Map();   // id -> node
    this.prevStatuses = new Map();
    this.selectedId = null;
    this.hoverEl = null;
    this.view = { k: 1, x: 0, y: 0, manual: false };
    this.buildDom();
    this.bindView();
    this.bindPointer();

    this.handleEvent('agents:sync', ({ nodes, ash }) => {
      this.sync(nodes || []);
      this.el.classList.toggle('evo-ash', !!ash);
    });
    this.handleEvent('agents:select', ({ id }) => {
      this.markSelected(String(id));
      this.centerOnNode(String(id));
    });
    this.handleEvent('agents:deselect', () => this.markSelected(null));

    try {
      const initial = JSON.parse(this.el.dataset.agents || '[]');
      this.sync(initial);
    } catch (e) { this.sync([]); }
  },

  // ---------- DOM 骨架 ----------
  buildDom() {
    this.el.classList.add('evo-graph-root');
    this.el.innerHTML = `
      <svg class="evo-canvas">
        <g class="evo-viewport">
          <g class="evo-edges"></g>
          <g class="evo-nodes"></g>
          <g class="evo-fx"></g>
        </g>
      </svg>
      <div class="evo-hud evo-tl">
        <div class="evo-brand-t">EVOGIT</div>
        <div class="evo-brand-sub">TASK EVOLUTION GRAPH</div>
        <div class="evo-counter"></div>
      </div>
      <div class="evo-hud evo-br"><div class="evo-event"></div></div>
      <div class="evo-legend-h evo-legend-bottom"></div>
      <div class="evo-tip"></div>
      <div class="evo-empty" style="display:none">
        <div class="evo-empty-t">暂无 Agent</div>
        <div class="evo-empty-s">从任务页创建一个任务，这里会实时生长出演化树</div>
      </div>`;
    this.svg = this.el.querySelector('.evo-canvas');
    this.viewport = this.el.querySelector('.evo-viewport');
    this.edgesG = this.el.querySelector('.evo-edges');
    this.nodesG = this.el.querySelector('.evo-nodes');
    this.fxG = this.el.querySelector('.evo-fx');
    this.counterEl = this.el.querySelector('.evo-counter');
    this.eventEl = this.el.querySelector('.evo-event');
    this.tipEl = this.el.querySelector('.evo-tip');
    this.emptyEl = this.el.querySelector('.evo-empty');
    this.viewport.style.transition = 'transform .9s cubic-bezier(.22,1,.36,1)';
    // Server-rendered translations (data-legend JSON) override the defaults.
    try {
      if (this.el.dataset.legend) this._legendI18n = JSON.parse(this.el.dataset.legend);
    } catch (e) { this._legendI18n = null; }
    this.buildLegend();
  },

  buildLegend() {
    // 横向图例（底部居中条）。分区标题只和该区第一项绑定（标题永不落单），
    // 其余项在窄容器里自由折行，保证任何宽度下都不超出框架。
    const i18n = this._legendI18n || {};
    const nodeLegend = i18n.nodes || NODE_LEGEND;
    const edgeLegend = i18n.edges || EDGE_LEGEND;
    const titles = i18n.titles || { nodes: '节点', edges: '连线' };
    const nodeRow = ([s, t]) => `
      <div class="evo-row"><svg width="20" height="20"><g class="node ${s}" transform="translate(10,10)">
        <circle class="halo" r="10"/><circle class="pulse" r="7"/><circle class="ring" r="7"/><circle class="dot" r="2.2"/>
      </g></svg><span>${t}</span></div>`;
    const edgeRow = ([s, t]) => `
      <div class="evo-row"><svg width="26" height="12">
        <path class="edge ${s}" d="M 2 6 C 9 2, 17 10, 24 6" fill="none"/>
      </svg><span>${t}</span></div>`;

    const nodeItems = nodeLegend.map(nodeRow);
    const edgeItems = edgeLegend.map(edgeRow);

    const group = (title, items) =>
      `<div class="evo-legend-group">` +
      `<div class="evo-sec-head"><span class="evo-sec-t">${title}</span>${items[0]}</div>` +
      items.slice(1).join('') +
      `</div>`;

    this.el.querySelector('.evo-legend-bottom').innerHTML =
      group(titles.nodes, nodeItems) + group(titles.edges, edgeItems);
  },

  // ---------- 数据同步（diff by id）----------
  sync(list) {
    const seen = new Set();
    let structureChanged = false;
    const transitions = [];

    for (const raw of list) {
      const id = String(raw.id);
      seen.add(id);
      const parentId = raw.parent_id != null ? String(raw.parent_id) : null;
      let n = this.nodes.get(id);
      if (!n) {
        n = {
          id, parentId, label: raw.label || id, status: raw.status || 'pending',
          depth: raw.depth || 0, agent: raw.agent || '', children: [],
          r: (raw.depth || 0) === 0 ? R * 1.2 : R, tx: 0, ty: 0, el: null, edgeEl: null,
        };
        this.nodes.set(id, n);
        // 多根（多任务）场景：根节点全部锁定，错开初始纵坐标避免重叠
        if (!n.parentId) n.ty = (this.roots().length - 1) * SIB_GAP * 2;
        if (n.parentId && this.nodes.has(n.parentId)) {
          this.nodes.get(n.parentId).children.push(n);
        }
        structureChanged = true;
        transitions.push(`「${n.label}」已注册，等待调度`);
      } else {
        if (n.status !== raw.status) {
          transitions.push(`「${n.label}」${STATUS_CN[n.status] || n.status} → ${STATUS_CN[raw.status] || raw.status}`);
          // ready = 子任务全部完成 → 结果回流
          if (raw.status === 'ready') n._converge = true;
        }
        if (n.parentId !== parentId) structureChanged = true;
        n.parentId = parentId;
        n.label = raw.label || n.label;
        n.status = raw.status || n.status;
        n.agent = raw.agent || n.agent;
        n.depth = raw.depth || n.depth;
      }
    }

    // 移除消失的节点
    for (const [id, n] of [...this.nodes]) {
      if (!seen.has(id)) {
        this.removeNode(n);
        structureChanged = true;
      }
    }

    // 事件 toast（只展示最后一个变化）
    if (transitions.length) this.toast(transitions[transitions.length - 1]);

    if (structureChanged) {
      this.layout();
      this.autoFit();
    }
    this.render();
    this.renderCounter();
  },

  removeNode(n) {
    // 从父节点 children 摘除，子节点变根
    if (n.parentId && this.nodes.has(n.parentId)) {
      const p = this.nodes.get(n.parentId);
      p.children = p.children.filter(c => c !== n);
    }
    for (const c of [...this.nodes.values()]) {
      if (c.parentId === n.id) c.parentId = null;
    }
    if (n.el) {
      n.el.style.opacity = '0';
      const el = n.el;
      setTimeout(() => { if (el.isConnected) el.remove(); }, 600);
    }
    if (n.edgeEl) n.edgeEl.remove();
    if (this.selectedId === n.id) this.selectedId = null;
    this.nodes.delete(n.id);
  },

  // ---------- 布局（对称松弛：母节点锁定，两侧自由节点对等让位）----------
  roots() {
    return [...this.nodes.values()].filter(n => !n.parentId || !this.nodes.has(n.parentId));
  },

  layout() {
    // Classic tidy tree layout: leaves take consecutive y slots, parents are
    // centered over their children. By construction nodes never overlap and
    // parent→child edges never cross — robust for parents with many children.
    let nextY = 0;
    const place = (n, d) => {
      n.tx = d * DEPTH_GAP;
      n.depth = d;
      if (!n.children.length) {
        n.ty = nextY;
        nextY += SIB_GAP;
      } else {
        n.children.forEach(c => place(c, d + 1));
        const first = n.children[0], last = n.children[n.children.length - 1];
        n.ty = (first.ty + last.ty) / 2;
      }
    };

    const roots = this.roots();
    roots.forEach(r => {
      place(r, r.depth || 0);
      nextY += SIB_GAP; // extra gap between independent trees
    });
  },

  // ---------- 渲染 ----------
  edgeD(p, c) {
    const x1 = p.tx + p.r, x2 = c.tx - c.r, mx = (x1 + x2) / 2;
    return `M ${x1} ${p.ty} C ${mx} ${p.ty}, ${mx} ${c.ty}, ${x2} ${c.ty}`;
  },

  nodeInner(n) {
    return `
      <circle class="halo" r="${(n.r + 5).toFixed(1)}"/>
      <circle class="pulse" r="${n.r}"/>
      <circle class="hoverring" r="${n.r + 6}"/>
      <circle class="selring" r="${n.r + 6}"/>
      <circle class="ring" r="${n.r}"/>
      <circle class="dot" r="${(n.r * 0.3).toFixed(1)}"/>
      <text class="ag" y="3"></text>
      <text class="lbl"></text>`;
  },

  placeLabel(lbl, ag, n) {
    const hasKids = n.children.length > 0;
    if (hasKids) {
      lbl.setAttribute('x', 0); lbl.setAttribute('y', -(n.r + 9)); lbl.style.textAnchor = 'middle';
    } else {
      lbl.setAttribute('x', n.r + 8); lbl.setAttribute('y', 3); lbl.style.textAnchor = 'start';
    }
    ag.setAttribute('x', 0); ag.setAttribute('y', n.r + 14); ag.style.textAnchor = 'middle';
  },

  render() {
    for (const n of this.nodes.values()) {
      if (!n.el) this.createNodeEl(n);
      n.el.setAttribute('class', 'node ' + n.status + (n.depth === 0 ? ' root' : '')
        + (n.el.classList.contains('hover') ? ' hover' : '')
        + (this.selectedId === n.id ? ' selected' : ''));
      n.el.style.transform = `translate(${n.tx}px, ${n.ty}px)`;
      if (n.parentId && this.nodes.has(n.parentId)) {
        const p = this.nodes.get(n.parentId);
        if (!n.edgeEl) this.growEdge(n, p);
        else {
          const d = this.edgeD(p, n);
          n.edgeEl.setAttribute('d', d);
          n.edgeEl.style.d = `path("${d}")`;
          n.edgeEl.setAttribute('class', 'edge st-' + n.status + (n._converge ? ' converge' : ''));
        }
        if (n._converge) { this.convergeSpark(n, p); n._converge = false; }
      }
      const ag = n.el.querySelector('.ag');
      ag.textContent = n.agent || '';
      const lbl = n.el.querySelector('.lbl');
      lbl.textContent = n.label;
      this.placeLabel(lbl, ag, n);
    }
  },

  createNodeEl(n) {
    const g = document.createElementNS(SVGNS, 'g');
    const from = (n.parentId && this.nodes.get(n.parentId)) || n;
    g.setAttribute('class', 'node ' + n.status + (n.depth === 0 ? ' root' : ''));
    g.style.opacity = '0';
    g.style.transform = `translate(${from.tx}px, ${from.ty}px)`;
    g.innerHTML = this.nodeInner(n);
    g.__data__ = n;
    this.nodesG.appendChild(g);
    n.el = g;

    const ring = g.querySelector('.ring');
    ring.setAttribute('pathLength', '100');
    ring.style.strokeDasharray = '100';
    ring.style.strokeDashoffset = '100';
    ring.style.transition = 'stroke-dashoffset .8s ease-out .15s';
    requestAnimationFrame(() => requestAnimationFrame(() => {
      g.style.opacity = '1';
      g.style.transform = `translate(${n.tx}px, ${n.ty}px)`;
      ring.style.strokeDashoffset = '0';
    }));
    setTimeout(() => {
      if (!ring.isConnected) return;
      ring.style.strokeDasharray = ''; ring.style.strokeDashoffset = ''; ring.style.transition = '';
    }, 1200);
  },

  // 子节点生长：连线逐段点亮，能量球从父流向子
  growEdge(n, p) {
    const path = document.createElementNS(SVGNS, 'path');
    path.setAttribute('class', 'edge st-' + n.status);
    const d = this.edgeD(p, n);
    path.setAttribute('d', d); path.style.d = `path("${d}")`;
    this.edgesG.appendChild(path);
    n.edgeEl = path;

    const len = path.getTotalLength();
    path.style.strokeDasharray = len;
    path.style.strokeDashoffset = len;
    path.getBoundingClientRect();
    path.style.transition = 'stroke-dashoffset .9s linear, stroke .8s, d .9s cubic-bezier(.22,1,.36,1)';
    path.style.strokeDashoffset = 0;

    const spark = document.createElementNS(SVGNS, 'circle');
    spark.setAttribute('class', 'spark');
    spark.setAttribute('r', '3');
    const motion = document.createElementNS(SVGNS, 'animateMotion');
    motion.setAttribute('dur', '0.9s');
    motion.setAttribute('path', d);
    motion.setAttribute('fill', 'freeze');
    spark.appendChild(motion);
    this.fxG.appendChild(spark);
    motion.addEventListener('endEvent', () => spark.remove());
    setTimeout(() => { if (spark.isConnected) spark.remove(); }, 1100);
    setTimeout(() => {
      if (!path.isConnected) return;
      path.style.strokeDasharray = ''; path.style.strokeDashoffset = ''; path.style.transition = '';
    }, 1000);
  },

  // 收敛：绿色能量球从子节点沿连线回流到父节点
  convergeSpark(c, p) {
    const x1 = c.tx - c.r, x2 = p.tx + p.r, mx = (x1 + x2) / 2;
    const d = `M ${x1} ${c.ty} C ${mx} ${c.ty}, ${mx} ${p.ty}, ${x2} ${p.ty}`;
    const spark = document.createElementNS(SVGNS, 'circle');
    spark.setAttribute('class', 'spark green');
    spark.setAttribute('r', '2.5');
    const motion = document.createElementNS(SVGNS, 'animateMotion');
    motion.setAttribute('dur', '0.8s');
    motion.setAttribute('path', d);
    motion.setAttribute('fill', 'freeze');
    spark.appendChild(motion);
    this.fxG.appendChild(spark);
    motion.addEventListener('endEvent', () => spark.remove());
    setTimeout(() => { if (spark.isConnected) spark.remove(); }, 950);
  },

  renderCounter() {
    let done = 0, run = 0, wait = 0, q = 0;
    for (const n of this.nodes.values()) {
      if (n.status === 'completed') done++;
      if (n.status === 'running') run++;
      if (n.status === 'waiting' || n.status === 'ready') wait++;
      if (n.status === 'pending' || n.status === 'blocked') q++;
    }
    this.counterEl.innerHTML = `${done} / ${this.nodes.size} 完成 · ${run} 运行 · ${wait} 分解中 · <b>${q} 排队</b>`;
    this.emptyEl.style.display = this.nodes.size === 0 ? '' : 'none';
  },

  toast(text) {
    this.eventEl.textContent = text;
    this.eventEl.classList.add('show');
    clearTimeout(this._eventTimer);
    this._eventTimer = setTimeout(() => this.eventEl.classList.remove('show'), 3200);
  },

  // ---------- 选中 ----------
  markSelected(id) {
    this.selectedId = id;
    for (const n of this.nodes.values()) {
      if (n.el) {
        n.el.classList.toggle('selected', n.id === id);
      }
    }
  },

  // Centers the viewport on a node (file-tree → graph linking).
  centerOnNode(id) {
    const n = this.nodes.get(id);
    if (!n) return;
    const box = this.svg.getBoundingClientRect();
    this.view.manual = true;
    this.view.x = box.width / 2 - n.tx * this.view.k;
    this.view.y = box.height / 2 - n.ty * this.view.k;
    this.applyView();
  },

  // ---------- 悬浮 + 点击 ----------
  bindPointer() {
    let downPos = null, downNode = null;

    this.svg.addEventListener('pointermove', e => {
      if (this._drag) { this.clearHover(); return; }
      const g = e.target.closest('g.node');
      if (g && g.__data__) {
        if (this.hoverEl !== g) {
          this.clearHover();
          this.hoverEl = g;
          g.classList.add('hover');
        }
        const n = g.__data__;
        this.tipEl.innerHTML = `<b>${n.label}</b><br>${STATUS_CN[n.status] || n.status}${n.agent ? ' · ' + n.agent : ''}`;
        this.tipEl.style.left = (e.clientX + 14) + 'px';
        this.tipEl.style.top = (e.clientY + 16) + 'px';
        this.tipEl.style.opacity = '1';
      } else {
        this.clearHover();
      }
    });
    this.svg.addEventListener('pointerleave', () => this.clearHover());

    this.svg.addEventListener('pointerdown', e => {
      downPos = [e.clientX, e.clientY];
      downNode = e.target.closest('g.node');
    });
    this.svg.addEventListener('click', e => {
      if (downPos && Math.hypot(e.clientX - downPos[0], e.clientY - downPos[1]) > 5) return;
      if (downNode && downNode.__data__) {
        const n = downNode.__data__;
        if (!this.demo) this.pushEvent('select_agent', { id: n.id });
        this.markSelected(n.id);
      } else {
        if (!this.demo) this.pushEvent('close_details', {});
        this.markSelected(null);
      }
      downNode = null;
    });
  },

  clearHover() {
    if (this.hoverEl) this.hoverEl.classList.remove('hover');
    this.hoverEl = null;
    this.tipEl.style.opacity = '0';
  },

  // ---------- 视图（缩放/平移/复位）----------
  bindView() {
    const applyView = () => {
      this.viewport.style.transform = `translate(${this.view.x}px, ${this.view.y}px) scale(${this.view.k})`;
    };
    this.applyView = applyView;

    this.svg.addEventListener('wheel', e => {
      e.preventDefault();
      this.view.manual = true;
      const rect = this.svg.getBoundingClientRect();
      const mx = e.clientX - rect.left, my = e.clientY - rect.top;
      const k2 = Math.min(Math.max(this.view.k * (e.deltaY < 0 ? 1.12 : 0.89), 0.12), 4);
      this.view.x = mx - (mx - this.view.x) * (k2 / this.view.k);
      this.view.y = my - (my - this.view.y) * (k2 / this.view.k);
      this.view.k = k2;
      applyView();
    }, { passive: false });

    this.svg.addEventListener('pointerdown', e => {
      this._drag = { x: e.clientX, y: e.clientY, vx: this.view.x, vy: this.view.y };
      this.svg.classList.add('dragging');
      try { this.svg.setPointerCapture(e.pointerId); } catch {}
    });
    this.svg.addEventListener('pointermove', e => {
      if (!this._drag) return;
      this.view.manual = true;
      this.view.x = this._drag.vx + e.clientX - this._drag.x;
      this.view.y = this._drag.vy + e.clientY - this._drag.y;
      applyView();
    });
    this.svg.addEventListener('pointerup', () => { this._drag = null; this.svg.classList.remove('dragging'); });
    this.svg.addEventListener('dblclick', () => { this.view.manual = false; this.autoFit(); });
    new ResizeObserver(() => this.autoFit()).observe(this.svg);
  },

  fitBounds(list) {
    if (this.view.manual) return;
    const box = this.svg.getBoundingClientRect();
    let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
    for (const n of list) {
      minX = Math.min(minX, n.tx); maxX = Math.max(maxX, n.tx);
      minY = Math.min(minY, n.ty); maxY = Math.max(maxY, n.ty);
    }
    if (!isFinite(minX) || box.width === 0) return;
    const w = Math.max(maxX - minX + 160, 1), h = Math.max(maxY - minY + 150, 1);
    this.view.k = Math.min(box.width / w, box.height / h, 1.5);
    this.view.x = (box.width - w * this.view.k) / 2 - (minX - 80) * this.view.k;
    this.view.y = (box.height - h * this.view.k) / 2 - (minY - 60) * this.view.k;
    this.applyView();
  },

  autoFit() {
    this.fitBounds([...this.nodes.values()]);
  },
};

export default EvolutionGraph;
