# Slice: Inline SVG Charts

Add deterministic inline SVG chart rendering for dashboard summaries.

## Brief

Implement pure chart helpers for a status donut and a grouping bar chart. Charts must be generated
as inline SVG, work offline under `file://`, and escape all labels.

## Acceptance

- Status donut SVG renders per-status distribution using the default semantic colors.
- Bar chart renders slices grouped by owner; when owner is absent, grouping falls back to feature and
  then stack.
- Chart functions are pure and do not require browser JavaScript or CDN libraries.
- SVG output escapes labels and cannot break HTML/script contexts.
- Swift tests cover donut segments/counts, bar labels, owner fallback grouping, and escaping.

## Stack

swift

## Depends On

- status-projection
