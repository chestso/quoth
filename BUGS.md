# Known Bugs

## Arrow-up stuck on reasoning fold `before-string` marker

When a reasoning region is collapsed, the `before-string` display text
(`... reasoning (N lines, M chars)\n`) blocks upward cursor navigation.
Arrow-up from the line below the marker gets stuck — the cursor cannot
move past the marker line. Arrow-left works as a workaround (move left
to enter the preview region, then arrow-up).

**Root cause:** The `before-string` display text was on the invisible
body overlay. The body overlay's start position is invisible (hidden by
`crush-reasoning-fold` in `buffer-invisibility-spec`) and intangible.
When `line-move-visual` tries to move up from below the fold, it targets
the visual line created by the `before-string` text, but cannot land
point there because the underlying position is invisible. This causes
`line-move-visual` to signal `beginning-of-buffer` instead of skipping
the marker.

**Fix:** Replace the `before-string` on the invisible body overlay with
an `after-string` on a separate zero-width **marker overlay** at the
last visible position before the body (the trailing newline of the
preview). This marker overlay is at a visible position, so its
`after-string` text is tangible and `line-move-visual` can navigate
through it. The marker text starts with a leading `\n` to push it onto
its own visual line.

Additionally:

1. **`crush--reasoning-stop`** — ensure the reasoning overlay always
   ends with a newline before freezing its boundary, so `:extend t`
   on `crush-reasoning-face` paints the last line's background to the
   end of the screen line.

2. **`crush--reasoning-install-fold`** — move `preview-end` past the
   newline so the body overlay starts at the beginning of the next line
   and the preview overlay includes its trailing newline.

3. **`crush--reasoning-fold-marker`** — add `'face 'crush-reasoning-face'
to the marker text and remove `intangible t` (the marker must be
   tangible for navigation).

**Affected:** `crush--reasoning-fold-marker` /
`crush--reasoning-install-fold` / `crush--reasoning-stop` /
`crush--reasoning-expand` / `crush--reasoning-collapse` /
`crush-reasoning-toggle` / `crush--reasoning-tab`

**Status:** Fixed.
