---
name: feedback_diet_trailing_spaces
description: Edit tool trims trailing spaces; split edits to avoid touching lines with meaningful trailing whitespace in diet templates
metadata:
  type: feedback
---

Never remove trailing spaces from `.dt` (diet-ng) template files. Trailing spaces are meaningful — diet-ng uses them to inject whitespace between adjacent inline nodes (e.g., a `span` followed by a `|` text node).

**Why:** The Edit tool trims trailing whitespace from strings passed to it. When an edit's `old_string` or `new_string` spans a line with a meaningful trailing space, that space gets silently dropped, breaking the rendered HTML spacing.

**How to apply:** When editing `.dt` files, keep edits narrow — split into multiple small edits so that lines with trailing spaces are never included in the `old_string`/`new_string`. If a trailing-space line must appear in an edit, use the Write tool for the whole file instead (which preserves content exactly).
