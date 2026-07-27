/**
 * Purl icon registry — the single source of truth for every UI glyph.
 *
 * Shape of an entry
 * -----------------
 * An icon is either an array of shapes (the common case: a 24x24 stroked glyph,
 * `stroke-width: 2`, `stroke: currentColor`, `fill: none`) or an object when it
 * needs to opt out of those defaults:
 *
 *   { shapes, viewBox?, fill?, strokeWidth? }
 *
 * A shape is either a plain string (shorthand for `<path d="...">`) or a
 * `[tag, attrs]` tuple for `circle` / `rect` / `line` / `ellipse` / `polyline` /
 * `polygon` / `path`. Keeping shapes as data (never markup strings) is what lets
 * <Icon> render them without `{@html}`.
 *
 * Every icon is a *named export* on purpose: an object map would be opaque to
 * Rollup, whereas named exports stay individually tree-shakeable for any
 * consumer that imports a glyph directly instead of going through <Icon name>.
 *
 * Names are referenced from <Icon> in kebab-case (`chevron-down`); <Icon>
 * camel-cases before looking the export up.
 */

/* ------------------------------------------------------------------ *
 * Chevrons & arrows
 * ------------------------------------------------------------------ */

export const chevronDown = ['m6 9 6 6 6-6'];
export const chevronUp = ['m18 15-6-6-6 6'];
export const chevronRight = ['m9 18 6-6-6-6'];
export const chevronLeft = ['m15 18-6-6 6-6'];

/** "Expand all" — a stacked pair of down chevrons. */
export const chevronsDown = ['m7 6 5 5 5-5', 'm7 13 5 5 5-5'];
/** "Collapse all" — a stacked pair of up chevrons. */
export const chevronsUp = ['m7 11 5-5 5 5', 'm7 18 5-5 5 5'];

export const arrowUp = ['M12 19V5', 'm5 12 7-7 7 7'];
export const arrowDown = ['M12 5v14', 'm19 12-7 7-7-7'];
export const arrowLeft = ['M19 12H5', 'm12 19-7-7 7-7'];
export const arrowRight = ['M5 12h14', 'm12 5 7 7-7 7'];

/* ------------------------------------------------------------------ *
 * Actions
 * ------------------------------------------------------------------ */

export const close = ['M18 6 6 18', 'M6 6l12 12'];
export const check = ['M20 6 9 17l-5-5'];
export const plus = ['M12 5v14', 'M5 12h14'];
export const minus = ['M5 12h14'];

export const search = [
  ['circle', { cx: 11, cy: 11, r: 8 }],
  ['line', { x1: 21, y1: 21, x2: 16.65, y2: 16.65 }],
];

export const copy = [
  ['rect', { x: 9, y: 9, width: 13, height: 13, rx: 2, ry: 2 }],
  'M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1',
];

export const trash = [
  ['polyline', { points: '3 6 5 6 21 6' }],
  'M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2',
];

export const refresh = [
  'M23 4v6h-6',
  'M1 20v-6h6',
  'M3.51 9a9 9 0 0 1 14.85-3.36L23 10',
  'M1 14l4.64 4.36A9 9 0 0 0 20.49 15',
];

export const download = [
  'M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4',
  ['polyline', { points: '7 10 12 15 17 10' }],
  ['line', { x1: 12, y1: 15, x2: 12, y2: 3 }],
];

export const upload = [
  'M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4',
  ['polyline', { points: '17 8 12 3 7 8' }],
  ['line', { x1: 12, y1: 3, x2: 12, y2: 15 }],
];

export const play = [['polygon', { points: '5 3 19 12 5 21 5 3' }]];

export const send = ['m22 2-7 20-4-9-9-4Z', 'M22 2 11 13'];

export const save = [
  'M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z',
  ['polyline', { points: '17 21 17 13 7 13 7 21' }],
  ['polyline', { points: '7 3 7 8 15 8' }],
];

export const pin = [
  'M12 17v5',
  'M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z',
];

/** Drag handle. */
export const grip = {
  fill: true,
  shapes: [
    ['circle', { cx: 9, cy: 5, r: 1.5 }],
    ['circle', { cx: 9, cy: 12, r: 1.5 }],
    ['circle', { cx: 9, cy: 19, r: 1.5 }],
    ['circle', { cx: 15, cy: 5, r: 1.5 }],
    ['circle', { cx: 15, cy: 12, r: 1.5 }],
    ['circle', { cx: 15, cy: 19, r: 1.5 }],
  ],
};

export const filter = [
  ['polygon', { points: '22 3 2 3 10 12.46 10 19 14 21 14 12.46 22 3' }],
];

export const sparkles = [
  'm12 3-1.9 5.8a2 2 0 0 1-1.3 1.3L3 12l5.8 1.9a2 2 0 0 1 1.3 1.3L12 21l1.9-5.8a2 2 0 0 1 1.3-1.3L21 12l-5.8-1.9a2 2 0 0 1-1.3-1.3L12 3Z',
];

/* ------------------------------------------------------------------ *
 * Status
 * ------------------------------------------------------------------ */

export const info = [
  ['circle', { cx: 12, cy: 12, r: 10 }],
  ['line', { x1: 12, y1: 16, x2: 12, y2: 12 }],
  ['line', { x1: 12, y1: 8, x2: 12.01, y2: 8 }],
];

export const alertCircle = [
  ['circle', { cx: 12, cy: 12, r: 10 }],
  ['line', { x1: 12, y1: 8, x2: 12, y2: 12 }],
  ['line', { x1: 12, y1: 16, x2: 12.01, y2: 16 }],
];

export const alertTriangle = [
  'M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z',
  ['line', { x1: 12, y1: 9, x2: 12, y2: 13 }],
  ['line', { x1: 12, y1: 17, x2: 12.01, y2: 17 }],
];

export const xCircle = [
  ['circle', { cx: 12, cy: 12, r: 10 }],
  ['line', { x1: 15, y1: 9, x2: 9, y2: 15 }],
  ['line', { x1: 9, y1: 9, x2: 15, y2: 15 }],
];

export const checkCircle = [
  'M22 11.08V12a10 10 0 1 1-5.93-9.14',
  ['polyline', { points: '22 4 12 14.01 9 11.01' }],
];

export const clock = [
  ['circle', { cx: 12, cy: 12, r: 10 }],
  'M12 6v6l4 2',
];

/** Filled status dot. */
export const dot = { fill: true, shapes: [['circle', { cx: 12, cy: 12, r: 7 }]] };
/** Hollow status dot. */
export const dotOutline = [['circle', { cx: 12, cy: 12, r: 7 }]];

/** Indeterminate loading ring — the arc is what rotates. */
export const spinner = {
  strokeWidth: 3,
  shapes: [
    ['circle', { cx: 12, cy: 12, r: 10, opacity: 0.2 }],
    'M12 2a10 10 0 0 1 10 10',
  ],
};

/* ------------------------------------------------------------------ *
 * Security & identity
 * ------------------------------------------------------------------ */

export const lock = [
  ['rect', { x: 3, y: 11, width: 18, height: 11, rx: 2, ry: 2 }],
  'M7 11V7a5 5 0 0 1 10 0v4',
];

export const key = [
  'M21 2l-2 2m-7.61 7.61a5.5 5.5 0 1 1-7.778 7.778 5.5 5.5 0 0 1 7.777-7.777zm0 0L15.5 7.5m0 0l3 3L22 7l-3-3m-3.5 3.5L19 4',
];

export const shield = ['M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z'];

export const users = [
  'M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2',
  ['circle', { cx: 9, cy: 7, r: 4 }],
  'M23 21v-2a4 4 0 0 0-3-3.87',
  'M16 3.13a4 4 0 0 1 0 7.75',
];

export const user = [
  'M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2',
  ['circle', { cx: 12, cy: 7, r: 4 }],
];

/* ------------------------------------------------------------------ *
 * Infrastructure
 * ------------------------------------------------------------------ */

export const server = [
  ['rect', { x: 2, y: 2, width: 20, height: 8, rx: 2 }],
  ['rect', { x: 2, y: 14, width: 20, height: 8, rx: 2 }],
  ['line', { x1: 6, y1: 6, x2: 6.01, y2: 6 }],
  ['line', { x1: 6, y1: 18, x2: 6.01, y2: 18 }],
];

export const database = [
  ['ellipse', { cx: 12, cy: 5, rx: 9, ry: 3 }],
  'M21 12c0 1.66-4 3-9 3s-9-1.34-9-3',
  'M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5',
];

/** Two-tier datastore — used for the Redis section. */
export const databaseTwoTier = [
  ['ellipse', { cx: 12, cy: 5, rx: 9, ry: 3 }],
  'M3 5v4c0 1.66 4 3 9 3s9-1.34 9-3V5',
  'M3 9v4c0 1.66 4 3 9 3s9-1.34 9-3V9',
];

/** Three-tier directory — used for the LDAP/AD section. */
export const databaseThreeTier = [
  ['ellipse', { cx: 12, cy: 5, rx: 9, ry: 3 }],
  'M3 5v4c0 1.66 4 3 9 3s9-1.34 9-3V5',
  'M3 9v4c0 1.66 4 3 9 3s9-1.34 9-3V9',
  'M3 13v4c0 1.66 4 3 9 3s9-1.34 9-3v-4',
];

export const monitor = [
  ['rect', { x: 2, y: 3, width: 20, height: 14, rx: 2 }],
  ['line', { x1: 8, y1: 21, x2: 16, y2: 21 }],
  ['line', { x1: 12, y1: 17, x2: 12, y2: 21 }],
];

/** Collector agent — a monitor showing a throughput line. */
export const agent = [
  ['rect', { x: 2, y: 3, width: 20, height: 14, rx: 2 }],
  'M8 21h8',
  'M12 17v4',
  'M7 10l3-3 2 2 3-4',
];

export const activity = ['M22 12h-4l-3 9L9 3l-3 9H2'];

export const pipeline = [
  'M4 6h16',
  'M4 12h16',
  'M4 18h10',
  ['circle', { cx: 20, cy: 18, r: 2 }],
];

export const integrations = [
  'M16 16v3a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h3',
  'M8 16h8a2 2 0 0 0 2-2V3a2 2 0 0 0-2-2H8a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2z',
];

export const bell = [
  'M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9',
  'M13.73 21a2 2 0 0 1-3.46 0',
];

/** Shipping box — stands in for "package" (a reserved word). */
export const box = [
  'M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 2 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 22 16z',
  ['polyline', { points: '3.27 6.96 12 12.01 20.73 6.96' }],
  ['line', { x1: 12, y1: 22.08, x2: 12, y2: 12 }],
];

export const link = [
  'M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71',
  'M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71',
];

export const globe = [
  ['circle', { cx: 12, cy: 12, r: 10 }],
  'M12 2a14.5 14.5 0 0 0 4 10 14.5 14.5 0 0 0-4 10 14.5 14.5 0 0 0-4-10 14.5 14.5 0 0 0 4-10',
  'M2 12h20',
];

export const ai = [
  'M12 2a10 10 0 0 1 10 10 10 10 0 0 1-10 10A10 10 0 0 1 2 12 10 10 0 0 1 12 2z',
  'M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3',
  ['line', { x1: 12, y1: 17, x2: 12.01, y2: 17 }],
];

/* ------------------------------------------------------------------ *
 * Documents & data display
 * ------------------------------------------------------------------ */

export const fileText = [
  'M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z',
  ['polyline', { points: '14 2 14 8 20 8' }],
  ['line', { x1: 16, y1: 13, x2: 8, y2: 13 }],
  ['line', { x1: 16, y1: 17, x2: 8, y2: 17 }],
  ['polyline', { points: '10 9 9 9 8 9' }],
];

/** JSON / raw payload. */
export const braces = [
  'M8 3H7a2 2 0 0 0-2 2v5a2 2 0 0 1-2 2 2 2 0 0 1 2 2v5a2 2 0 0 0 2 2h1',
  'M16 21h1a2 2 0 0 0 2-2v-5a2 2 0 0 1 2-2 2 2 0 0 1-2-2V5a2 2 0 0 0-2-2h-1',
];

export const table = [
  ['rect', { x: 3, y: 3, width: 18, height: 18, rx: 2, ry: 2 }],
  ['line', { x1: 3, y1: 9, x2: 21, y2: 9 }],
  ['line', { x1: 9, y1: 21, x2: 9, y2: 9 }],
];

export const code = [
  ['polyline', { points: '16 18 22 12 16 6' }],
  ['polyline', { points: '8 6 2 12 8 18' }],
];

export const terminal = [
  ['polyline', { points: '4 17 10 11 4 5' }],
  ['line', { x1: 12, y1: 19, x2: 20, y2: 19 }],
];

export const barChart = ['M18 20V10', 'M12 20V4', 'M6 20v-6'];

/** Side-by-side panes — the histogram "compare" toggle. */
export const columns = [
  ['rect', { x: 3, y: 3, width: 18, height: 18, rx: 2, ry: 2 }],
  'M12 3v18',
];

export const menu = ['M4 6h16', 'M4 12h16', 'M4 18h16'];

export const list = [
  'M8 6h13',
  'M8 12h13',
  'M8 18h13',
  'M3 6h.01',
  'M3 12h.01',
  'M3 18h.01',
];

export const grid = [
  ['rect', { x: 3, y: 3, width: 7, height: 7, rx: 1 }],
  ['rect', { x: 14, y: 3, width: 7, height: 7, rx: 1 }],
  ['rect', { x: 3, y: 14, width: 7, height: 7, rx: 1 }],
  ['rect', { x: 14, y: 14, width: 7, height: 7, rx: 1 }],
];

export const hash = ['M4 9h16', 'M4 15h16', 'M10 3 8 21', 'M16 3l-2 18'];

export const calendar = [
  ['rect', { x: 3, y: 4, width: 18, height: 18, rx: 2, ry: 2 }],
  ['line', { x1: 16, y1: 2, x2: 16, y2: 6 }],
  ['line', { x1: 8, y1: 2, x2: 8, y2: 6 }],
  ['line', { x1: 3, y1: 10, x2: 21, y2: 10 }],
];

/* ------------------------------------------------------------------ *
 * Brand marks (filled, drawn on their own grid)
 * ------------------------------------------------------------------ */

/** Purl wordmark glyph. */
export const logo = {
  viewBox: '0 0 32 32',
  shapes: [
    ['circle', { cx: 16, cy: 16, r: 14 }],
    'M10 12 L22 12 M10 16 L22 16 M10 20 L18 20',
  ],
};

export const telegram = {
  fill: true,
  shapes: [
    'M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm4.64 6.8c-.15 1.58-.8 5.42-1.13 7.19-.14.75-.42 1-.68 1.03-.58.05-1.02-.38-1.58-.75-.88-.58-1.38-.94-2.23-1.5-.99-.65-.35-1.01.22-1.59.15-.15 2.71-2.48 2.76-2.69a.2.2 0 00-.05-.18c-.06-.05-.14-.03-.21-.02-.09.02-1.49.95-4.22 2.79-.4.27-.76.41-1.08.4-.36-.01-1.04-.2-1.55-.37-.63-.2-1.12-.31-1.08-.66.02-.18.27-.36.74-.55 2.92-1.27 4.86-2.11 5.83-2.51 2.78-1.16 3.35-1.36 3.73-1.36.08 0 .27.02.39.12.1.08.13.19.14.27-.01.06.01.24 0 .38z',
  ],
};

export const slack = {
  fill: true,
  shapes: [
    'M5.042 15.165a2.528 2.528 0 0 1-2.52 2.523A2.528 2.528 0 0 1 0 15.165a2.527 2.527 0 0 1 2.522-2.52h2.52v2.52zM6.313 15.165a2.527 2.527 0 0 1 2.521-2.52 2.527 2.527 0 0 1 2.521 2.52v6.313A2.528 2.528 0 0 1 8.834 24a2.528 2.528 0 0 1-2.521-2.522v-6.313zM8.834 5.042a2.528 2.528 0 0 1-2.521-2.52A2.528 2.528 0 0 1 8.834 0a2.528 2.528 0 0 1 2.521 2.522v2.52H8.834zM8.834 6.313a2.528 2.528 0 0 1 2.521 2.521 2.528 2.528 0 0 1-2.521 2.521H2.522A2.528 2.528 0 0 1 0 8.834a2.528 2.528 0 0 1 2.522-2.521h6.312zM18.956 8.834a2.528 2.528 0 0 1 2.522-2.521A2.528 2.528 0 0 1 24 8.834a2.528 2.528 0 0 1-2.522 2.521h-2.522V8.834zM17.688 8.834a2.528 2.528 0 0 1-2.523 2.521 2.527 2.527 0 0 1-2.52-2.521V2.522A2.527 2.527 0 0 1 15.165 0a2.528 2.528 0 0 1 2.523 2.522v6.312zM15.165 18.956a2.528 2.528 0 0 1 2.523 2.522A2.528 2.528 0 0 1 15.165 24a2.527 2.527 0 0 1-2.52-2.522v-2.522h2.52zM15.165 17.688a2.527 2.527 0 0 1-2.52-2.523 2.526 2.526 0 0 1 2.52-2.52h6.313A2.527 2.527 0 0 1 24 15.165a2.528 2.528 0 0 1-2.522 2.523h-6.313z',
  ],
};

export const grafana = {
  fill: true,
  shapes: [
    'M22 12c0 5.52-4.48 10-10 10S2 17.52 2 12 6.48 2 12 2s10 4.48 10 10zm-10 8c4.41 0 8-3.59 8-8s-3.59-8-8-8-8 3.59-8 8 3.59 8 8 8zm-2-12h1.5v5H10zm3 0h1.5v5H13zm-4.5 6.5h7v1.5h-7z',
  ],
};

export const kibana = {
  fill: true,
  shapes: [
    'M3 3h18v18H3V3zm2 2v14h14V5H5z',
    'M7 7h4v10H7z',
    'M13 7l4 5-4 5V7z',
  ],
};
