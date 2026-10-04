// Rebuilds a capture as native FigJam objects: a clean screenshot, real stickies, real connector arrows.
// Coordinates are 1 screen point = 1 FigJam unit, so the layout matches what you saw in the overlay.
figma.showUI(__html__, { width: 320, height: 480 });

// Line / text colours, line weights and text sizes (keep in sync with StrokeColor, LineWeight and TextSize in Store.swift).
// These are FigJam's exact connector palette values; FigJam only treats exact matches as palette colours.
const STROKE_COLORS = {
  red: '#ff7556', orange: '#ff9e42', green: '#66d575', blue: '#3dadff', violet: '#874fff', black: '#1e1e1e', white: '#ffffff',
};
const LINE_WEIGHTS = { thin: 2, medium: 3, thick: 6 };
const TEXT_SIZES = { small: 16, medium: 24, large: 36 };

// Sticky colours offered in the overlay (keep in sync with StickyColor in Store.swift).
// FigJam's exact sticky palette. Yellow is FigJam's own default and is left untouched.
const STICKY_COLORS = {
  orange: '#ffd3a8', red: '#ffb8a8', pink: '#ffa8db', violet: '#d3bdff', blue: '#a8daff', green: '#b3efbd', gray: '#e6e6e6',
};

// Anything FigJam did not accept is collected here and reported after the flow is placed.
let warnings = [];
function sameColor(a, b) { return Math.abs(a.r - b.r) < 0.01 && Math.abs(a.g - b.g) < 0.01 && Math.abs(a.b - b.b) < 0.01; }
function firstColor(node, prop) {
  try { const p = node[prop] && node[prop][0]; return p && p.type === 'SOLID' ? p.color : null; } catch (e) { return null; }
}
const SECTION_PAD = 80;

figma.clientStorage.getAsync('token').then((token) => figma.ui.postMessage({ type: 'token', token }));
figma.clientStorage.getAsync('settings').then((settings) => figma.ui.postMessage({ type: 'settings', settings }));

// Measure FigJam's native sticky size once and give it to the Mac app, so the overlay draws stickies at true size.
(async () => {
  let size = await figma.clientStorage.getAsync('stickySize');
  if (!size || !size.color) {
    const probe = figma.createSticky();
    const paint = probe.fills && probe.fills[0];
    size = { w: probe.width, h: probe.height, color: paint && paint.type === 'SOLID' ? rgbToHex(paint.color) : null };
    probe.remove();
    await figma.clientStorage.setAsync('stickySize', size);
  }
  figma.ui.postMessage({ type: 'sticky-size', w: size.w, h: size.h, color: size.color });
})();

function rgbToHex(c) {
  const h = (v) => Math.round(v * 255).toString(16).padStart(2, '0');
  return '#' + h(c.r) + h(c.g) + h(c.b);
}

function hexToRgb(hex) {
  const n = parseInt(hex.replace('#', ''), 16);
  return { r: ((n >> 16) & 255) / 255, g: ((n >> 8) & 255) / 255, b: (n & 255) / 255 };
}

// Flows stack down one column: every flow starts at the same left edge and sits `flowGap` (set in the panel, default 120)
// below the previous one. The anchor is fixed on the first placement so later flows line up even if the view has moved.
const DEFAULT_FLOW_GAP = 120;
let anchorX = null;       // left edge shared by all flows placed in this session
let lastBottom = null;    // bottom edge of the previously placed flow
let queue = Promise.resolve();

figma.ui.onmessage = (msg) => {
  if (msg.type === 'save-token') return figma.clientStorage.setAsync('token', msg.token);
  if (msg.type === 'save-settings') return figma.clientStorage.setAsync('settings', msg.settings);
  if (msg.type !== 'flow') return;
  // Placements run one at a time: two flows posted together must not start before the first has finished.
  queue = queue.then(() => placeFlow(msg)).catch((e) => figma.notify(`Could not place "${msg.name}": ${e.message}`, { error: true }));
};

async function placeFlow(msg) {
  warnings = [];
  const vp = figma.viewport.bounds;
  if (anchorX === null) anchorX = vp.x + 40;
  const flowGap = Number.isFinite(msg.flowGap) ? msg.flowGap : DEFAULT_FLOW_GAP;
  const nextTop = lastBottom === null ? vp.y + 40 : lastBottom + flowGap;
  const inset = msg.wrap ? SECTION_PAD : 0;       // a section sits SECTION_PAD outside its content
  const oy = nextTop + inset;
  let x = anchorX + inset;
  const groups = [];

  for (const step of msg.steps) {
    groups.push(await placeStep(step, x, oy));
    x += step.width + msg.gap;
    figma.ui.postMessage({ type: 'placed', id: step.id });
  }

  const outer = msg.wrap ? wrapInSection(groups, msg.name) : null;
  const selection = outer ? [outer] : groups;

  // Snap the flow's outermost edge to the shared left line and to nextTop. Stickies or arrows hanging outside the
  // screenshot would otherwise push this flow's edge out of line with the others.
  const dx = anchorX - Math.min(...selection.map((n) => n.x));
  const dy = nextTop - Math.min(...selection.map((n) => n.y));
  for (const n of selection) { n.x += dx; n.y += dy; }

  // The next flow starts `flowGap` below the bottom edge of what was just placed (the section, or the lowest step).
  lastBottom = Math.max(...selection.map((n) => n.y + n.height));

  figma.currentPage.selection = selection;
  figma.viewport.scrollAndZoomIntoView(selection);
  figma.notify(`Placed ${groups.length} step${groups.length === 1 ? '' : 's'} from Flow Capture`);
  if (warnings.length) {
    const unique = [...new Set(warnings)];
    figma.notify(`Some styles were not applied: ${unique.slice(0, 3).join('; ')}`, { timeout: 12000 });
    figma.ui.postMessage({ type: 'warnings', list: unique });
  }
}

// Section sized to the steps' bounding box. Children are re-positioned relative to the section.
function wrapInSection(nodes, name) {
  const minX = Math.min(...nodes.map((n) => n.x)), minY = Math.min(...nodes.map((n) => n.y));
  const maxX = Math.max(...nodes.map((n) => n.x + n.width)), maxY = Math.max(...nodes.map((n) => n.y + n.height));
  const section = figma.createSection();
  section.name = name;
  section.x = minX - SECTION_PAD; section.y = minY - SECTION_PAD;
  section.resizeWithoutConstraints(maxX - minX + SECTION_PAD * 2, maxY - minY + SECTION_PAD * 2);
  for (const n of nodes) {
    const ax = n.x, ay = n.y;
    section.appendChild(n);
    n.x = ax - section.x; n.y = ay - section.y;
  }
  return section;
}

async function placeStep(step, ox, oy) {
  const nodes = [];

  const image = figma.createImage(step.bytes);
  const shot = figma.createRectangle();
  shot.name = 'Screenshot';
  shot.resize(step.width, step.height);
  shot.x = ox; shot.y = oy;
  shot.fills = [{ type: 'IMAGE', imageHash: image.hash, scaleMode: 'FILL' }];
  nodes.push(shot);

  for (const a of step.annotations) {
    if (a.kind === 'sticky') {
      const s = figma.createSticky();
      await figma.loadFontAsync(s.text.fontName);
      s.text.characters = a.text || ' ';
      if (STICKY_COLORS[a.color]) {
        const want = hexToRgb(STICKY_COLORS[a.color]);
        try { s.fills = [{ type: 'SOLID', color: want }]; } catch (e) { warnings.push(`sticky colour (${a.color}) was rejected: ${e.message}`); }
        const got = firstColor(s, 'fills');
        if (!got || !sameColor(got, want)) warnings.push(`sticky colour "${a.color}" did not apply (FigJam kept ${got ? rgbToHex(got) : 'a different fill'})`);
      }
      applyList(s, a);
      s.x = ox + a.x; s.y = oy + a.y;
      nodes.push(s);
    } else if (a.kind === 'rect' || a.kind === 'oval') {
      const shape = figma.createShapeWithText();
      shape.shapeType = a.kind === 'oval' ? 'ELLIPSE' : 'SQUARE';
      shape.resize(Math.max(1, Math.abs(a.x2 - a.x)), Math.max(1, Math.abs(a.y2 - a.y)));
      shape.x = ox + Math.min(a.x, a.x2); shape.y = oy + Math.min(a.y, a.y2);
      shape.fills = [];                                   // outline only, like a highlight box
      styleLine(shape, a);
      nodes.push(shape);
    } else if (a.kind === 'text') {
      const t = figma.createText();
      await figma.loadFontAsync(t.fontName);
      t.characters = a.text || ' ';
      t.fontSize = TEXT_SIZES[a.size] || 24;
      const textWant = hexToRgb(STROKE_COLORS[a.stroke] || STROKE_COLORS.black);
      t.fills = [{ type: 'SOLID', color: textWant }];
      const textGot = firstColor(t, 'fills');
      if (!textGot || !sameColor(textGot, textWant)) warnings.push(`text colour "${a.stroke}" did not apply`);
      t.textAutoResize = 'HEIGHT';
      t.resize(Math.max(40, a.x2 - a.x), t.height);
      t.x = ox + a.x; t.y = oy + a.y;
      nodes.push(t);
    } else {
      const c = figma.createConnector();
      c.connectorStart = { position: { x: ox + a.x, y: oy + a.y } };
      c.connectorEnd = { position: { x: ox + a.x2, y: oy + a.y2 } };
      c.connectorLineType = 'STRAIGHT';
      c.connectorEndStrokeCap = 'ARROW_LINES';
      styleLine(c, a);
      nodes.push(c);
    }
  }

  try { const g = figma.group(nodes, figma.currentPage); g.name = 'Flow step'; return g; }
  catch (e) { return nodes[0]; }
}

// Bulleted / numbered notes: use FigJam's own list formatting; if that isn't available, fall back to typed prefixes.
function applyList(sticky, a) {
  if (!a.list || a.list === 'none' || !a.text) return;
  let applied = false;
  try {
    sticky.text.setRangeListOptions(0, sticky.text.characters.length, { type: a.list === 'number' ? 'ORDERED' : 'UNORDERED' });
    applied = true;
  } catch (e) { /* not supported on sticky text */ }
  if (applied) {
    try {
      const o = sticky.text.getRangeListOptions(0, 1);
      if (o && o.type === 'NONE') applied = false;
    } catch (e) { /* cannot verify; assume it worked */ }
  }
  if (!applied) {
    sticky.text.characters = a.text.split('\n').map((l, i) => (a.list === 'number' ? `${i + 1}. ` : '• ') + l).join('\n');
  }
}

// Colour, thickness and dashes shared by arrows (connectors) and shapes. Each setting is read back; failures are reported.
function styleLine(node, a) {
  const want = hexToRgb(STROKE_COLORS[a.stroke] || STROKE_COLORS.red);
  const weight = LINE_WEIGHTS[a.weight] || 3;
  const label = node.type === 'CONNECTOR' ? 'arrow' : 'shape';
  try { node.strokes = [{ type: 'SOLID', color: want }]; } catch (e) { warnings.push(`${label} colour was rejected: ${e.message}`); }
  const got = firstColor(node, 'strokes');
  if (!got || !sameColor(got, want)) warnings.push(`${label} colour "${a.stroke}" did not apply`);
  try { node.strokeWeight = weight; } catch (e) { warnings.push(`${label} thickness was rejected: ${e.message}`); }
  if (node.strokeWeight !== weight) warnings.push(`${label} thickness "${a.weight}" did not apply (got ${node.strokeWeight})`);
  if (a.dashed) {
    try { node.dashPattern = [weight * 3, weight * 2]; } catch (e) { warnings.push(`${label} dashes were rejected: ${e.message}`); }
    if (!node.dashPattern || node.dashPattern.length === 0) warnings.push(`${label} dashes did not apply`);
  }
}
