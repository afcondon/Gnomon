# purescript-go — go/no-go spike notes

Date: 2026-06-13. Goal: validate the thesis that a Go backend cut from the
Julia/Python skeleton + purerl statement-form machinery + gofmt post-pass can
emit Go that compiles, gofmt-clean, runs, and matches the JS/Julia reference for
the simplest real corpus module (modulo the INT64/ASTRAL ledger).

## STEP 0 — write access
PASS. Created `purescript-go/`, wrote+read+deleted a file. Sandbox does not block
writes here.

## Key early findings
- **Build de-risked.** The `purescript-0.15.14` Haskell library is ALREADY built
  in stack snapshot `54adb6…` (the snapshot Julia uses), and `purejl` is built
  there. Copying Julia's `stack.yaml` + `stack.yaml.lock` verbatim means the heavy
  `purescript` dep resolves from cache — only our new local modules compile.
  Snapshot compiler: GHC 9.2.5.
- **Corefn already on disk.** `purescript-julia/test-suite/output/Test.*/corefn.json`
  exist, as do the JS reference (`output/.../index.js`) and Julia reference
  (`output-jl/Test_*.jl`). I do not need to run `purs` for the corpus modules — I
  can drive the Go compiler straight off the existing corefn.json.
- **Uncurried is NOT the smallest path to green.** `Test.Uncurried` pulls in a big
  transitive foreign closure: Data.Show (showInt/showArray/showOrdering),
  Effect.Console.log, Data.Function.Uncurried mkFn0..5/runFn0..5, Data.Functor.map,
  Data.Ord.compare, Data.Ring, Data.Semigroup.append. Running it needs every one of
  those shims re-authored in Go. That's the "Fn/EffectFn saturation detour" the brief
  warned about. Per the brief, start with a hand-written trivial module to prove the
  pipeline end-to-end first.

## Bash sandbox note
`stack exec`, `du -sh`, and shell `for`-loops trigger permission denials in this
delegated session. `find`, `ls`, `cp`, `mkdir`, `go`, `gofmt`, plain `grep` are fine.
Plan: drive the Go codegen via the built compiler if `stack build`/`stack run` is
permitted; if `stack` is blocked, fall back to demonstrating the codegen on a
checked-in corefn.json with a standalone harness.

## Design decisions taken (ADR-style, recorded as decided)
- Small purpose-built Go AST (GoExpr/GoStmt/GoDecl), NOT a verbatim port of purerl's
  Erlang AST. purerl AST/Pretty are the *shape* reference; a Go-targeted pretty
  printer is small and gofmt does the cleanup.
- Single flat Go package, one file per PS module, mangled top-level names
  (`Data_Maybe_Just`). Plan ADR-0004 option (b).

## BUILD RESULT — GREEN on the Haskell side
`stack build` SUCCEEDED. All 6 library modules + the `psgo` executable compiled
and linked under GHC 9.2.5. The `purescript` library resolved instantly from the
cached snapshot `54adb6…` (NO cold dependency build) — exactly as the build-speed
tip predicted. Copying Julia's stack.yaml+lock verbatim is the correct move and it
works. This proves: (a) the cabal/stack skeleton ports cleanly; (b) my CodeGen's
pattern matches typecheck against the REAL `Language.PureScript.CoreFn` API (every
Expr/Binder constructor lines up), which is a strong correctness signal even before
running.

## SANDBOX MAP (delegation limit — the BLOCKER for full end-to-end)
This delegated session can BUILD but cannot EXECUTE arbitrary binaries:
- ALLOWED: `stack build`, `stack --version`, `find`, `ls`, `cp`, `mkdir`,
  `python3` (for corefn inspection), file read/write.
- BLOCKED (permission denied): `purs`, `go`, `gofmt`, `stack exec`, `stack run`,
  and running the built `psgo` binary directly. Anything that runs a program.
Consequence: I cannot generate fresh corefn (purs blocked), cannot run psgo on the
existing corpus corefn, cannot gofmt or `go run` the output. The end-to-end
GREEN/RED gate (emit→gofmt→go run→diff) MUST be finished from a session that can
execute binaries (the main session can, per the memory note). Everything UP TO
execution is done and green.

## CODEGEN COVERAGE — complete for the target set
Census of expr/binder node types across Test.{Uncurried,Effects,ADTs,Dictionaries}:
expr: App, Var, Literal, Abs, Constructor, Case, Let, ObjectUpdate, Accessor.
binder: ConstructorBinder, VarBinder, NullBinder.
`genExpr`/`genPattern` handle ALL of these (plus Literal/Named binders not yet seen).
So statement-form lowering covers 100% of the smallest corpus modules' node shapes.

## HAND-TRACE of the target artifact (`output-go/main.go`)
Since I can't run the binary, I hand-traced the codegen rules against the
`Trivial` module (self-contained FFI, exercises Literal/Var/App/Abs/Let/Case/
Constructor) and wrote the Go it WOULD emit to `output-go/main.go`. Manual Go
review of that file:
- Curried application `(f).(func(any) any)(x)` chains correctly: left-assoc,
  each call yields `any`, re-asserted for the next. VALID Go.
- ADT: `V{Tag:"Circle", Fields:[]any{v}}`; pattern `_v0.(V).Tag == "Circle"` and
  field `_v0.(V).Fields[0]`. VALID.
- Case → IIFE `func() any { _v0 := s; if … {return …}; …; panic(…) }()`. The
  terminating `panic` satisfies Go's "function must return on all paths". VALID.
- Let → IIFE with `prefix := …; return …`. VALID.
- Discard binder `$__unused` mangles to `S__unused`; as a FUNCTION PARAMETER an
  unused name is LEGAL in Go (only unused LOCALS/imports error). So `\_ ->`
  lambdas need NO Unused pass. Confirmed `$__unused` is the real corefn name.
- Effect thunks: `func() any`; `bindEffect` runs `m.(func() any)()` then
  `k.(func(any) any)(a).(func() any)()`. VALID.
Expected stdout (computed by hand): `=== Trivial ===` / `TEST circle: 48` /
`TEST rect: 15` / `TEST add: 42` / `TEST done: ok`.

## Where the Unused pass actually bites (correctly deferred)
NOT on discard parameters (legal in Go). It bites on unused `:=` LOCALS from
let-bindings and case field-binders that the body doesn't reference — those are
"declared and not used" compile errors. Graft purerl's Unused as soon as a corpus
module binds-and-ignores a field. Trivial doesn't, so the spike artifact is clean.

## ADRs recorded (decided, not backfilled)
- ADR-0001 Runtime representation: `any` everywhere; curried unary closures;
  `V{Tag,Fields}` ADTs; `map[string]any` records/dicts; `func() any` Effects;
  nil=Unit. Inherits Julia's INT64/ASTRAL ledger. → src/.../CodeGen.hs, Foreigns.hs.
- ADR-0002 Statement-form via Go AST+Pretty+gofmt: GoExpr/GoStmt/GoDecl
  (AST.hs), naive correct-syntax pretty-printer (Pretty.hs) + gofmt post-pass in
  Make.hs. Statement scope in expr position = zero-arg IIFE `func() any {…}()`.
  This is the pivot from the family expression-emitter. DONE.
- ADR-0003 TCO trampoline: DEFERRED (Phase 2). Not on the critical path for the
  smallest modules. Attaches in generateBind/genLetBind; port Julia's verbatim.
- ADR-0004 Module layout: single flat package, one var per top-level binding,
  `Module_ident` mangling, NO loader. DONE (option b).
- ADR-0005 FFI doctrine "constructors across, handles back": core shims in
  Foreigns.hs DO encode the V/map repr (allowed for core). DONE for Trivial's set.
- ADR-0006 Conformance-first: corpus + runner adopted in shape; the differential
  gate is the next step once a session can execute binaries.

## How much purerl graft was actually needed
LESS than the plan budgeted. The plan said graft AST.hs (~412) + Pretty.hs (~350)
and trim. In practice: purerl's AST is Erlang-shaped (atoms, tuples, map-patterns,
specs, types, 4 traversal combinators) — I used it only as a SHAPE REFERENCE and
wrote a purpose-built ~70-line Go AST (12 GoExpr + 7 GoStmt + 3 GoDecl ctors) and a
~70-line pretty-printer. gofmt absorbs all layout, so Pretty stayed tiny. The
traversal combinators (everywhereOnErl*) weren't needed yet — they'll matter when
the Unused/MagicDo optimizer passes land. Net: the "reach back to grandparent
purerl" move is real but lighter than feared — it's a design template, not a port.

---

# Session 2 (2026-06-13 cont.) — gate verified for real; Phase 1 infra; first codegen grind

## The go/no-go gate is now ACTUALLY GREEN (not hand-traced)
`spike/finish-gate.sh` ran end-to-end in a session that can execute binaries:
`purs compile Trivial.purs → corefn,js`; JS reference run; `psgo` (built binary)
corefn → `output-go/main.go`; `gofmt` clean; `go run` → **byte-identical** to JS.
The spike's hand-computed ref.txt/go.txt were overwritten by the real run. The
PLAN's premise ("design risk retired by the spike") is now verified, not traced.

## Phase 1 infrastructure stood up
- **Corpus copied** → `test-suite/` (10 `Test.*` modules, spago.yaml renamed
  `psgo-tests`, lock copied). `spago build` green (2 inherited unused-import warns).
- **psgo: per-test entrypoint + reachability pruning** (`--entry Module.Name`).
  Make.hs ports Jurist's `loadOrder` (DFS post-order transitive closure) so each
  Test module emits only ITS closure and can be walked to green independently.
- **Go differential runner** `test-suite/run_tests.py`: purs corefn,js → per
  module `psgo --entry` → `go run main.go prelude.go` → diff TEST lines vs JS.
  KNOWN_DIVERGENCES seeded from Julia (INT64/ASTRAL).
- **Honest red baseline** captured: `test-suite/BASELINE.md` +
  `test-suite/FOREIGN_WORKLIST.txt` (229 distinct foreign shims; per-module cost
  ranking — ADTs/PatternMatch leanest at 56, all 56 being the core prelude layer).

## ADR-0004 refinement: separate prelude.go (not inlined Haskell strings)
The foreign catalogue is now authored as REAL Go in `runtime/prelude.go`
(gofmt-checked, `go run`-testable) and **embedded into psgo at compile time**
via `file-embed`/TemplateHaskell (`Foreigns.hs`). psgo emits TWO `package main`
files — generated `main.go` + static `prelude.go` — run with
`go run main.go prelude.go` (no go.mod needed; verified). This mirrors Julia's
separate `purejl_runtime.jl` and makes the 229-shim grind maintainable.
`builtinForeigns`/`runtimePreamble` exports were replaced by `preludeFile`.

## Core foreign shim layer authored (~56, mirroring output/<Module>/foreign.js)
Eq/Ord/Show/Semiring/Ring/EuclideanRing/Semigroup/HeytingAlgebra/Bounded,
array Functor/Apply/Bind/Extend, Unit, Effect+Console, Record.Unsafe,
unsafeCoerce, plus helpers (`_mkOrd`, `_floorDivPos`, `_showInt/Number/Char/
String`, `_refEq`). INT64 ledger honored (intAdd etc. do NOT int32-wrap).
`_showNumber` is approximate (Go strconv 'g' vs JS toString) — flagged for the
Numbers module to stress.

## Codegen fixes landed this session
1. **Guard conditions** `if <any-expr>` → `.(bool)` assertion (`asBool` in
   CodeGen). Pattern tag-checks are already real Go bools; only guard exprs
   (Var/App, e.g. `Data_Boolean_otherwise`) needed the assert.
2. **Unused scrutinee binders**: `genCase` now only binds `_vN` roots the
   alternatives actually reference (Go: unused `:=` local = compile error).
   Minimal inline form of the Unused pass (`rootUsed`).
3. **Direct lambda application** `(\_ -> e) x`: callee is a closure LITERAL
   (concrete `func(any)any`, not an interface) → call directly, skip the
   `.(func(any)any)` assertion (Pretty special-cases `GoCurriedApp (GoClosure..)`).
4. **Top-level init via `func init()` in topological (eager-dependency) order**
   (`prettyProgram` in Pretty). Go's package var-init cycle detector rejects ANY
   self/mutual reference in a var initializer even when buried in a closure
   (self-recursive `gcd`; the monad/bind/apply superclass dict chain). Emitting
   `var X any` + assignment inside `init()` dodges that. Ordering uses STRUCTURAL
   eager-dependency analysis (`eagerNames`: refs outside closure bodies only) so
   lazy `\_ -> dict` cycle edges don't constrain order.

## THE BLOCKER for first green: lazy initialization of cyclic CAF clusters
After all the above, ADTs/PatternMatch COMPILE and RUN but panic at init:
`interface conversion: nil is not map[string]interface{}`. Root cause:
`Effect_applyEffect = ApplyS_Dict({apply: Control_Monad_ap(Effect_monadEffect), ...})`
evaluates `ap(monadEffect)` EAGERLY, and `ap`'s body eagerly reads
`monadEffect.Applicative0()`/`.Bind1()` → `applicativeEffect`/`bindEffect`. Those
are in the same dictionary cycle and may be nil when applyEffect is built. This is
a TRANSITIVE-through-a-function-call eager dependency that my shallow `eagerNames`
cannot see, so topo can't order around it.

**purs's own answer is the lazy-thunk runtime.** `output/Effect/index.js` shows
`functorEffect`/`applyEffect` wrapped in `$runtime_lazy(...)` and forced AFTER the
plain dicts (monad/bind/applicative, whose cycle edges are all lazy `function(){}`).
This is exactly ADR-0004's "lazy-thunk helper for value-level CAF cycles" — it
turns out to be a PREREQUISITE for the standard typeclass-dictionary clusters, not
an edge case. **This is the next task and the gateway to the first real green.**

### Implementation options for lazy init (next session)
- **(A) Force-on-use, all generated bindings.** Runtime `_lazy(thunk) func()any`
  (memoize). Emit `var X any = _lazy(func() any { return <e> })`; rewrite every
  reference to a GENERATED binding (known name set, disjoint from prelude shims)
  to `X()`. mainCall becomes `Module_main().(func() any)()`. CAVEAT: the GoRaw
  escape hatches (genPattern `.(V).Tag`/field access, asBool `.(bool)`,
  ObjectUpdate copy-loop, Rec let-binds) embed ALREADY-RENDERED references as bare
  names — the force-rewrite must either AST-ify those (replace GoRaw with real
  nodes) or token-patch the GoRaw text. AST-ification is the clean route and also
  pays down debt. The eager-force graph for the dict clusters is acyclic, so
  memoized forcing converges without a forcing-in-progress guard (add one anyway
  to turn true value cycles into a clear panic rather than a hang).
- **(B) Mirror purs precisely.** Only wrap cyclic-CAF bindings in `$runtime_lazy`,
  leave acyclic ones as plain `var = expr`. Requires detecting the cyclic set
  (SCCs on the FULL eager-force graph incl. interprocedural reads) — more analysis,
  closer to JS output, fewer thunks. (A) is simpler and Phase 1 is the slow
  reference backend anyway; lean (A).

## State of the tree at end of session 2
psgo BUILDS (stack build green). Trivial gate GREEN (regression-checked after all
Make/Pretty changes). Runner works; all 10 corpus modules reach `go run` and fail
at the lazy-init panic above (foreigns + the four codegen fixes resolved
everything up to it). prelude.go gofmt-clean + standalone-compilable.

---

# Session 2 cont. — lazy init DONE; first greens

**Lazy init landed (Option A, force-on-use).** prelude.go gained `_lazy` (memoized
thunk, with a forcing-flag guard that turns a true eager value-cycle into a clear
panic) and `_force`. `prettyProgram` now emits every generated binding as
`var X any` + `X = _lazy(func() any { return <init> })` in `init()` (order
irrelevant — nothing runs until first force), and `forceRefs` rewrites every
reference to a GENERATED binding into `_force(name)`. Generated vs prelude shims
are distinguished by the generated-name set. The `GoRaw`/`GoRawStmt` escape
hatches are handled by `patchTokens` (whole-identifier-token text patch) rather
than AST-ification — cheaper, and collision-safe because generated names are long
mangled `Module_ident`. mainCall became `_force(<M>_main).(func() any)()`. The
topoSort/eagerNames machinery from the previous attempt was removed (unnecessary
under full laziness). Trivial gate stays green.

**Greens (3 modules, 72 tests):** Test.ADTs 32/32, Test.PatternMatch 31/31,
Test.Uncurried 9/9 — all byte-identical to JS. Uncurried needed the
Data.Function.Uncurried `mkFnN`/`runFnN` family: FnN represented as a Go variadic
`func(...any) any`, with `_mkFn`/`_runFn` helpers (authored mkFn0,2..10 + runFn0,2..10).

**Remaining red (module-specific foreign grind), unique missing shims:**
Dictionaries 26, Numbers 37, STTests 38, Recursion 73, Arrays 85, Effects 97,
Strings 117. Recursion will also exercise the TCO trampoline (ADR-0003) and its
INT64 ledger entries. The walk is now pure foreign-authoring + occasional codegen
fix; the hard structural problems (statement form, init cycles, lazy init) are
retired.

---

# Session 3 — Dictionaries, Numbers, STTests green (6 modules, 235 tests)

Continued the module-specific foreign grind. **6 modules now byte-identical to
JS, 235 tests:** ADTs 32, PatternMatch 31, Uncurried 9, Dictionaries 42,
Numbers 106, STTests 15. Three modules added this session, plus two structural
codegen fixes and one runtime rewrite — none of which were "missing shim", all
were latent correctness bugs the new modules surfaced.

**Dictionaries (42/42).** Authored Data.Enum (char↔codepoint via rune),
Data.Foldable foldr/foldlArray, Data.FunctorWithIndex mapWithIndexArray,
Data.Int.Bits, Data.Int (fromNumberImpl/toNumber/fromStringAsImpl),
Data.Number (ceil/floor/round/trunc/isFinite/fromStringImpl), Data.Traversable
traverseArrayImpl (curried 5-arg divide&conquer), Data.Unfoldable(1)
unfoldr(1)ArrayImpl, Effect.Ref (cell = `map[string]any{"value":…}`), Effect
control-flow (untilE/whileE/forE/foreachE), Partial/_crashWith + _unsafePartial.
- **Codegen fix — `GoVarDef`.** Non-recursive `let` emitted `x := <closure>`,
  giving `x` a *concrete* func type, so a later `x.(func(any) any)(arg)` is
  illegal (Go only asserts on interface types). New AST node `GoVarDef` emits
  `var x any = …`, forcing interface type. The recursive-`let` path already did
  this via `var x any` + reassign; this unifies them. Systemic — every later
  module benefits.

**Numbers (106/106).** Authored Data.Int rem/quot/pow/toStringAs and the full
Data.Number Math.* family + constants. Two correctness points:
- **`_showNumber` rewritten to ECMAScript Number::toString.** Go's `strconv`
  `'g'` format uses different exponent thresholds and zero-pads exponents
  (`1e-06` vs JS `1e-6`). New `_jsNumToString` takes the shortest round-trip
  digits + decimal exponent from `'e'` format and reformats per the spec: fixed
  notation for −6 < n ≤ 21, exponential otherwise, sign-only (unpadded) exponent.
  Nails every corpus case: `1e10`→`10000000000.0`, `1e20`→`…0.0`, `1e21`→`1e+21`,
  `1e-6`→`0.000001`, `1e-7`→`1e-7`, `5e-324`, max double, `0.1+0.2`, etc.
- **JS int32 bitwise via `_toInt32`/`_toUint32`.** `shl`/`shr`/`zshr`/`complement`
  and the `&`/`|`/`^` results route through ToInt32 (ToUint32 for `>>>`), shift
  counts masked to 5 bits — so `1 << 31 == -2147483648` and `(-1) >>> 0 ==
  4294967295` match JS. This is *faithful*, not a ledger divergence (the wrap is
  the whole point). `Int.pow` likewise `| 0`s through ToInt32 (2^31 wraps).

**STTests (15/15).** Authored Control.Monad.ST.Internal (STRef = same cell repr
as Effect.Ref; ST actions are `func() any` thunks; **note ST `write` returns the
written value**, unlike Effect.Ref.write→unit), Control.Monad.ST.Uncurried
runSTFn1–4 (`_runSTFn` = `_runFn` but final application wrapped in an ST thunk),
and Data.Array.ST (mutable array = **`*[]any`** for reference semantics;
primitives are uncurried/variadic, called via runSTFnN; freeze/thaw/clone copy,
unsafe variants alias; in-place merge `sortByImpl`).
- **Codegen fix — bijective reserved-word mangler.** `Control.Monad.ST.Internal`
  has BOTH a `map` binding (`Data.Functor.map functorST`) and a foreign `map_`.
  `map` is Go-reserved → escaped to `map_`, colliding with the real `map_`; the
  generated `map_ = Data.Functor.map(functorST)` then reduced to `map_ =
  functorST["map"] = map_`, a true strict CAF cycle (caught by `_lazy`'s forcing
  guard at runtime — first such catch). Fix: escape iff the *trailing-underscore-
  stripped core* is reserved, so `map`→`map_`, `map_`→`map__`: a bijection,
  distinct PS names stay distinct. The foreign `map_` shim is now
  `Control_Monad_ST_Internal_map__`.

**Remaining red:** Recursion (TCO trampoline ADR-0003 + INT64 ledger entries),
Arrays, Effects (Effect.Uncurried EffectFnN, Effect.Ref already done),
Strings (the big one — codepoint/UTF-16 ASTRAL ledger). The structural toolkit
(statement form, lazy init, interface-typed lets, bijective mangling, ECMAScript
number formatting, int32 bitwise, mutable-ref semantics) is now broad enough that
the remaining modules should be mostly shim-authoring + the one known TCO feature.

---

# Session 3 FINALE — ALL 10 modules green; Phase 1 conformance COMPLETE

`python3 run_tests.py` over the full corpus:

    422/426 identical, 4 known divergences, 0 failures, 0 module errors

Every corpus module is byte-identical to the JS reference. The only 4 diffs are
the pre-seeded ledger entries: INT64 (`sumTo 1e6`, `fact 20` — Go 64-bit ints
don't int32-wrap) and ASTRAL (`CU.length "😀"`, `CU.take 1 "😀x"` — Go counts
codepoints, JS counts UTF-16 units). Both are intentional properties of a
64-bit/UTF-8 target, not bugs.

**Effects (14/14)** added Effect.Uncurried mk/runEffectFnN (`_mkEffectFn` applies
all args then runs the effect; `runEffectFn` == `_runSTFn`) + Effect.Unsafe
unsafePerformEffect. **Strings (72/74 + 2 ASTRAL)** — all Data.String.{Common,
CodeUnits,CodePoints,Unsafe} ops implemented on Go **runes** (codepoints): matches
JS for ASCII/BMP, diverges predictably on astral (the ledger). CodeUnits index
results converted byte→rune so they stay codepoint-consistent. **Arrays (85/85)**
— Data.Array + Data.Array.NonEmpty.Internal (incl. the traverse1 Cont trampoline
and shared `_mergeFromTo` merge sort). **Recursion (16/18 + 2 INT64)** needed
ZERO new shims and, crucially, **no TCO trampoline** — Go's growable goroutine
stack absorbed `sumTo 1e6` (1M frames). ADR-0003 is therefore a Phase-2
performance concern, not a Phase-1 correctness requirement.

**Codegen correctness fixes this session (all general, surfaced by the corpus):**
`GoVarDef` (interface-typed `let`), `_jsNumToString` (ECMAScript number format),
`_toInt32`/`_toUint32` (JS int32 bitwise), bijective reserved-word mangler
(`map` vs `map_`), and per-alternative block scoping in `genCase` (equational
clauses binding the same names). The runtime grew from ~56 core shims to the full
Phase-1 catalogue; prelude.go stays gofmt-clean and standalone-compilable.

**Phase 1 (correct, un-optimized `any`-runtime CoreFn→Go emitter) is DONE.**
Next horizons: Phase 2 (Eibes's monomorphise+inline optimizing layer, with this
backend as the correctness oracle), or broadening the corpus beyond the 10
modules (typeclasses-heavy code, Aff, more of core).
