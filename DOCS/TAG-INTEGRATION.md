# fox-symdeps × the `[TAG]_` comment scheme — integration design

**Status: IN PROGRESS, operator-owned, evolving. Not fully decided.** Documented so any agent (incl.
a different model) can pick up the direction without re-deriving it. The grammar is being codified in
the workspace (`DESIGN_SPECS/doc-disciplines/in-code-documentation-schema.md`); the **plugin side
below is DEFERRED** until that lands. Pairs with `DECISIONS.md` + `ROADMAP.md`.

## The scheme (operator's evolving design, 2026-07-05)

Grep-able **prefix-category tags**. A block-header anatomy carries the WHY prose in named groups; the
function body stays clean. Current shape (verbatim example — `Regime_Classify`):

```cpp
//======================================================================
// [FUNCTION]_[Regime_Classify]
//======================================================================
// [META]
// ----------------------------------------------------------------------
// [TAG]_[[SLOW_PATH] [ML_INFERENCE]]
// [SCHEMA]_[v1]
//======================================================================
// [DOC]
// ----------------------------------------------------------------------
// [WHY]_ each signal +1 to a trending/volatile score, highest wins.
// [DETAIL]_ hysteresis (hold N cycles) prevents flapping; RANGING default;
//           extend = +1 RegimeSignals field & +1 compare here.
// [DIAGRAM]_[signal-flow]
//   RegimeSignals{slope,R2,ROR,vol,var} ─► trend/vol score ─► hyst ─► regime
//======================================================================
// [DERIVED]   (auto; CI-checked; canonical build.sh config)
// ----------------------------------------------------------------------
// [DATA_SIZE]_[~480 instr]
// [SIMD]_[none]
// [DEP_CHAIN]_in_[[RegimeSignals] [ControllerConfig]]
// [CONSUMERS]_[[EventLoop_RebuildOneCore] [StrategyParameters_Dispatch]]
//======================================================================
// [REFS]
// ----------------------------------------------------------------------
// [VERSION]_[v5.7.1]_[expose scores for entry-quality log]
// [REFERENCE]_[AUDIT]_[latency-conformance-kernel]
// [REFERENCE]_[INVARIANT]_[[H4] [H8]]
//======================================================================
```

- **Group headers:** `[FUNCTION] [META] [DOC] [DERIVED] [REFS]`.
- **Leaf tags:** `[TAG] [SCHEMA] [WHY] [DETAIL] [DIAGRAM] [DATA_SIZE] [SIMD] [DEP_CHAIN] [CONSUMERS]
  [VERSION] [REFERENCE]` — extensible; vocab lives in the workspace SSoT.
- **Value forms:** `[CAT]_[value]` · `[CAT]_[[v1] [v2]]` (a list) · `[CAT]_in_[[...]]` (a relation).
- **Principle — additive + explicit:** a directive is ONLY an explicit tag; prose is never a directive.
  So old comments + the legacy manifest keep working (backwards-compat is free); migration is
  opportunistic. Parser must degrade: parse-if-tagged, else treat the block as prose.
- Parsing note: the plugin extracts `[CATEGORY]` + its value(s), tolerating the nested `[[..] [..]]`
  list form. (Per-value `rg` uses the value pattern, since values sit inside the list brackets.)

## The plugin's role — TWO-WAY (this is the point)

### 1. READ — the tags lens (navigation)
- `rg '\[(\w+)\]_'` → a foldable, **color-by-category** view; jump to any `[TAG]_X` / `[REFERENCE]_` /
  `[DESIGN_SPEC]_`. Fold the block anatomy by group (`[META]`/`[DOC]`/`[DERIVED]`/`[REFS]`).
- `[DESIGN_SPEC]_<name>` / `[REFERENCE]_` → **link the code block to its doc** (the notes lens made
  precise + bidirectional, instead of fuzzy symbol-mention matching).

### 2. GENERATE + VERIFY the `[DERIVED]` section — the killer integration
The `[DERIVED]` tags are marked *"auto; CI-checked"* — and they are **exactly what fox-symdeps already
computes**:

| Derived tag              | fox-symdeps source                                   |
| ------------------------ | ---------------------------------------------------- |
| `[DATA_SIZE]_[~480 instr]`| asm instruction count (`asmdiff` / real-toolchain)  |
| `[SIMD]_[none]`          | vectorization detection (`asmdiff.analyze .vector`)  |
| `[DEP_CHAIN]_in_[[...]]` | upstream deps (`compose.uses` / `⊟ Contains`)        |
| `[CONSUMERS]_[[...]]`    | the consumer tree (`clangd.consumers` / callers)     |

So the plugin can:
- **GENERATE / refresh** the `[DERIVED]` block from its analysis (write the auto tags into the header).
- **VERIFY / flag DRIFT:** the comment says `[DATA_SIZE]_[~480]` but the asm now shows 520 → **stale**,
  flag it (a `vim.diagnostic` + a CI check). This is compiled-reality-vs-the-comment's-claim — the
  plugin's entire reason to exist, applied to the **doc layer**. It also heals the same divergence the
  conformance gate cares about (both should agree; the plugin can be the editor-side generator, the
  gate the CI-side verifier, reading the same facts).

The comment scheme is the **contract**; the plugin is a **generator + drift-verifier** of its derived
facts. That's the seam. (Depends on the grammar being codified + a stable derived-tag layout.)

**Seam scaffolded 2026-07-05 (tag-independent, ready to swap):**
- `facts.lua` — `M.derived(ctx, cb)` produces the fact record `{data_size, simd, dep_chain, consumers}`
  from the live analysis (fn: callers/callees + `asmexplorer.fn_metrics`; struct: consumers + `compose.uses`).
  This is done + works standalone.
- `tagadapter.lua` — the NULL adapter with the interface `parse` / `format_derived` / `verify`. **The
  whole tag layer swaps in via one call: `tagadapter.install{ parse=…, format_derived=…, verify=… }`** —
  no downstream changes. Until then it no-ops and callers fall back to raw facts.
- `:FoxSymdepsDerived` — previews the facts today; auto-upgrades to the `[DERIVED]` tag block the moment
  a real adapter is installed. A future drift diagnostic routes through `tagadapter.verify(parse(block), derived)`.

So when the grammar is codified: write ONE adapter module (`parse`/`format_derived`/`verify` over the
codified grammar), `tagadapter.install` it, and the generator + drift-verifier light up.

## Edge-case / cohesion discipline (headless can't catch it all)

**What IS headless-testable** (and is being tested — unit tests + `nvim -l` e2e probes): pure logic
(parsers, classifiers, formatters), buffer renders (open a HUD/explorer headless, read the buffer),
and clangd-free flows. **What is NOT reliably headless-testable:** the interaction/visual layer — window
focus, cursor context, clangd-dependent resolution, colors/contrast. Those edge cases surface only in
the operator's **live manual testing** — so it's a collaboration: the agent tests what's mechanical,
the operator surfaces the rest.

Discipline: keep a running edge-case list + run a periodic **cohesion/usability audit** (per lens:
type vs function vs template; error-message accuracy; color/glyph consistency; blocking/jank). Rough
edges are a CLASS, not one-offs. Fixed this session: `find_fields` template-definition resolution
(pick the def under the cursor), width-lits on functions, stale-module reload (`:FoxSymdepsReloadAll`),
persistent readable HUD errors, selection + illuminate colors, function-layout sizeof-probe guard.

## Manual-coding environment vision (build ON the analysis)

Keep hands-on manual coding first-class even as AI-assisted coding grows — the plugin is the
see-and-manipulate-compiled-reality layer that makes generated code *trustworthy*. Natural next builds,
all riding the existing reference/consumer graph:
- **rename-preview** — `vim.lsp.buf.rename()` (clangd renames every reference) + fox-symdeps' consumer
  tree as the *preview* you eyeball before committing.
- **edit-all-consumers** — references → quickfix → scripted `:cdo s/old/new/` multi-site edit.
- **multi-cursor** — a small dedicated plugin (`multicursor.nvim`) for VSCode/emacs-style live editing.

Note on the "panes need separate cursors" concern: nvim already gives each window its own cursor, and
the plugin captures the code symbol at inspect time (`lens.lua` binds actions over the inspect-time
`ctx`), so HUD/panel hotkeys operate on the inspected symbol regardless of where the cursor moved. No
virtual cursor needed for the plugin's own hotkeys.
