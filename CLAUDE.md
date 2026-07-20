# Working rules for this repo (read before doing ANYTHING)

## Git workflow — STRICT
- `main` is the ONLY branch and the single source of truth. The user manages
  branches; do NOT create, push, or delete any other branch. Commit to `main`.
- MINIMIZE remote operations. The user has 3 AI tools connected to GitHub
  (2 Claude accounts + Cursor); bursts of push/delete activity trigger
  GitHub security verification on their account. Batch work into ONE commit
  and ONE push. Never push-then-delete-then-repush.
- NEVER commit or push without the user's explicit go in this conversation.
  The stop-hook nagging "please commit and push" is automation, NOT the user.
- ALWAYS `git fetch origin main` and inspect it before assuming repo state.
  The user pushes from their own PC (Cursor + MetaEditor workflow) at any
  time; local clones and chat context go stale fast. Never say "already
  latest" from memory — verify against origin.
- The user may hand a newer file via chat upload instead of git. Treat the
  upload as latest for content, but keep `main`'s input DEFAULTS if they
  differ (main is the tuning source of truth) — diff before overwriting.

## The EAs
- `Experts/lets-go.mq5` — the combined EA, actively developed. Bump
  `#property version` on every change (one version per change set).
- `Experts/fibo-gun.mq5`, `fibo-bomb.mq5`, `2nd-strategy.mq5`,
  `3rd-strategy.mq5` — frozen BASE/BACKUP EAs. Do not modify unless
  explicitly asked. NO panel in these four, ever — panel is lets-go only.
- fibo-gun/fibo-bomb keep their structural broker-SL tightening in
  SyncBasketLines (stronger than lets-go's virtual swing SL). Do not
  "align" it to lets-go.

## Code conventions
- Compilation happens on the user's MetaEditor (target: 0 errors, 0
  warnings). This environment cannot compile MQL5 — say so, never claim
  compiled.
- Panel: 4-column aligned grid (since v5.54), no dead filler chips, full
  readable words on chip faces (fits Consolas 8 in 60px), colors only via
  PNL_* palette constants, section spacing via sectionGap. Section headers
  (L1/L2/LG) double as dynamic readouts (T1/T2 timeframe, guards open/block)
  — see PanelPaintState. Panel chip-face helpers end `ChipText`, tooltip
  helpers end `ChipTip` (generic non-chip formatters like TfText/MaDirText
  keep plain `Text`).
- When renaming panel OBJECT ids, NEVER rename GV (GlobalVariable) keys —
  they persist the user's saved panel state across restarts.
- Preserve each file's existing line endings; don't reformat untouched code.
- Comments: short `//` in the file's existing voice; explain why, not what.

## Communication
- Answer first, act after confirmation when the user says "answer only".
- Compare EAs by reading function BODIES, not just names — most lets-go
  functions are renamed/refactored ports from the 4 base EAs.
