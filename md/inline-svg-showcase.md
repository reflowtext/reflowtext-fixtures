# Inline SVG Showcase

Ten inline `<svg>` graphics written straight into Markdown: shapes, line icons,
sprites, gradients and text.

## 1. Basic shapes

<svg width="240" height="60" viewBox="0 0 240 60" xmlns="http://www.w3.org/2000/svg">
  <rect x="5" y="5" width="50" height="50" rx="8" fill="#4f46e5" />
  <circle cx="90" cy="30" r="25" fill="#10b981" />
  <ellipse cx="150" cy="30" rx="30" ry="18" fill="#f59e0b" />
  <line x1="190" y1="5" x2="235" y2="55" stroke="#ef4444" stroke-width="3" />
  <polygon points="210,5 235,30 210,55 185,30" fill="#8b5cf6" />
</svg>

## 2. Stroked path (line-icon style)

This is the shape sprite-free icon libraries emit. Relies on `fill="none"`,
`stroke`, `stroke-width`, `stroke-linecap`, `stroke-linejoin`.

<svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
  <path d="M3 12h18" />
  <path d="M12 3v18" />
  <circle cx="12" cy="12" r="9" />
</svg>

## 3. Sprite via `<symbol>` + `<use>`

Both icons below reference the same `<symbol>` definition.

<svg width="0" height="0" style="position:absolute" aria-hidden="true">
  <symbol id="icon-check" viewBox="0 0 24 24">
    <path d="M4 12l5 5L20 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
  </symbol>
  <symbol id="icon-star" viewBox="0 0 24 24">
    <path d="M12 2l3 7h7l-5.5 4 2 7-6.5-4.5L5.5 22l2-7L2 9h7z" fill="currentColor" />
  </symbol>
</svg>

<svg width="32" height="32"><use href="#icon-check" /></svg>
<svg width="32" height="32"><use href="#icon-star" /></svg>

## 4. Legacy `xlink:href` form

Older sprites use `xlink:href` instead of `href`.

<svg width="32" height="32"><use xlink:href="#icon-check" /></svg>

## 5. Linear gradient + fill-rule

<svg width="200" height="80" viewBox="0 0 200 80" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="grad1" x1="0%" y1="0%" x2="100%" y2="0%">
      <stop offset="0%" stop-color="#4f46e5" />
      <stop offset="100%" stop-color="#ec4899" />
    </linearGradient>
  </defs>
  <rect x="0" y="0" width="200" height="80" rx="12" fill="url(#grad1)" />
  <path d="M40 40 a20 20 0 1 0 40 0 a20 20 0 1 0 -40 0 z" fill="#ffffff" fill-rule="evenodd" />
</svg>

## 6. Text inside SVG + dashed stroke

<svg width="260" height="60" viewBox="0 0 260 60" xmlns="http://www.w3.org/2000/svg">
  <rect x="2" y="2" width="256" height="56" rx="8" fill="none" stroke="#64748b" stroke-width="2" stroke-dasharray="6 4" />
  <text x="130" y="36" text-anchor="middle" font-family="sans-serif" font-size="18" fill="#0f172a">SVG &lt;text&gt;</text>
</svg>

## 7. Grouped + transformed

<svg width="120" height="120" viewBox="0 0 120 120" xmlns="http://www.w3.org/2000/svg">
  <g transform="translate(60,60)">
    <rect x="-30" y="-30" width="60" height="60" fill="#0ea5e9" transform="rotate(15)" />
    <rect x="-20" y="-20" width="40" height="40" fill="#fbbf24" transform="rotate(35)" />
  </g>
</svg>

## 8. SVG as a Markdown image (data URI)

![Green badge](data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%20width='90'%20height='28'%3E%3Crect%20width='90'%20height='28'%20rx='4'%20fill='%2310b981'/%3E%3Ctext%20x='45'%20y='19'%20text-anchor='middle'%20fill='white'%20font-family='sans-serif'%20font-size='13'%3Epassing%3C/text%3E%3C/svg%3E)
