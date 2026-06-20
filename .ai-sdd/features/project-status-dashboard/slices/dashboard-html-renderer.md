# Slice: Dashboard HTML Renderer

Render the full PM-facing dashboard page from dashboard projection data and inline chart SVG.

## Brief

Extend `GraphRenderer` or a closely related engine renderer with a self-contained dashboard HTML
page. The page should be readable without Mermaid literacy and should include summary cards,
progress, legend, status-styled graph sections, charts, and feature/slice tables.

## Acceptance

- Renderer emits complete HTML with embedded CSS and no required external assets.
- Summary header shows feature count, slice count, done/total progress, and a progress bar.
- Legend shows the confirmed status colors/styles.
- Status-annotated graph view styles nodes by status.
- Feature sections list slices with status, owner/fallback group, stack, dependency count, and
  next-action hint.
- Inline donut and bar charts are included.
- All dynamic text is HTML-escaped.
- Swift tests cover HTML escaping, status classes/legend, progress bar values, feature sections,
  and chart inclusion.

## Stack

swift

## Depends On

- status-projection
- inline-svg-charts
