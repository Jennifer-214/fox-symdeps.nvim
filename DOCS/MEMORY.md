# fox-symdeps.nvim — memory & durable notes

The plugin's own memory, **relocated into the toolchain 2026-07-05** (was in the Linux_Theme Claude
auto-memory scope — wrong scope now that the plugin lives in the trader workspace). Kept here so it's
usable in the workspace/engine context, versioned with the plugin, and yours to harvest/scrape/repurpose.

Current **state, decisions, and queue** live in the sibling docs — this file is the pointer + the
durable technical gotchas that recur:

→ **`REFERENCE.md`** (start here) · `DECISIONS.md` · `ROADMAP.md` · `TAG-INTEGRATION.md` · `EDGE-CASES.md`

## Durable technical gotchas (the recurring bites)

### 1. Compile-flag features: test against the ENGINE's flags, not a toy sandbox
Three features shell out to a compiler with the project's `compile_commands` flags: **sizeprobe**
(template size), **breakcheck** (static_assert failures), **asmdiff** (asm flag-diff). They passed
against a trivial sandbox (`clang++ -std=c++17`) but the real engine builds with **`-flto`** (+ `-march`,
defines, …). The bite (2026-07-01): `clang -S -flto` emits **LLVM IR, not x86 asm**, so asmdiff's label
parser found 0 blocks → every function showed "unavailable"; the sandbox hid it. Fix: `asmdiff.strip_opt`
drops `-flto`/`-emit-llvm`/`-fwhole-program-vtables`/`-fsplit-lto-unit` so `-S` emits native asm.
**Lesson: for any compile-flag-dependent feature, verify against the engine's actual flags.** (2026-07-05
the asm tooling went further — compiles 1:1 with the real toolchain; see DECISIONS.)

### 2. clangd hover omits Size for templates → why `sizeprobe` exists
clangd hover on a **plain struct** → `Size: N bytes, alignment M` (parse_layout works). On a **template
specialization** (`FPN_Binary<64>`, `T<8>`) → signature only, **NO Size line** → `parse_layout` returns
nil → the generic Layout readout is silently BLANK for any templated type (incl. the engine's central
`FPN_Binary<64>`). Fix: `sizeprobe` recovers `sizeof`/`alignof` via a compile probe (the undefined-template
diagnostic trick); a concrete instantiation's size comes from there, not the generic clangd path. Related:
the `find_fields` template fix (2026-07-05, EDGE-CASES) — resolve fields on the *specialization under the
cursor*, not the un-instantiated primary.

## History (pre-move, condensed — full detail in git + ROADMAP)

C++ compiled-reality cockpit; private repo (`Jennyfirrr/fox-symdeps.nvim`); personal tool, never published;
single plugin extensible via `lenses/*.lua` + `lens.define` + `:FoxSymdepsReload`. 2026-07-03 (~15 commits):
the co-programming loop — the panel reflects external edits → auto cross-file cascade + break-check +
sizeof/breakage alerts; lenses s=false-sharing / b=break-check / m=mutations / n=notes; Uses + callees nav;
hot-path instruction-budget guardrail; the trader byte-layout cascade folded in as a self-gating lens.
**2026-07-05:** the large buildout + the move to the workspace (see ROADMAP + DECISIONS).
