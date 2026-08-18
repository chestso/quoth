# Known Bugs

## Arrow-up stuck on reasoning fold `before-string` marker

When a reasoning region is collapsed, the `before-string` display text
(`... reasoning (N lines, M chars)\n`) blocks upward cursor navigation.
Arrow-up from the line below the marker gets stuck — the cursor cannot
move past the marker line. Arrow-left works as a workaround (move left
to enter the preview region, then arrow-up).

**Root cause:** The `intangible t` property on the `before-string` text
and the body overlay should make Emacs skip both, but the `before-string`
display-only text still acts as a navigation barrier in some cases.
The interaction between `before-string`, `intangible`, and `invisible`
named specs needs further investigation.

**Workaround:** Use arrow-left to enter the preview region, then arrow-up.

**Affected:** `crush--reasoning-fold-marker` / `crush--reasoning-install-fold`
