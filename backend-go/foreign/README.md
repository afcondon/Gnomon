# `foreign/` — Go FFI for PureScript packages outside the core runtime

## The rule

**A PureScript package's Go FFI is the backend's to provide, not each program's
to re-derive.** If your program fails to link with `undefined:
Some_Module_someName`, the fix belongs here, not in a shim beside your app.

## Why this directory exists, and what it is not

`runtime.go` is the **core** foreign layer: prelude, `Data.Array`,
`Data.String.*`, `Control.Monad.ST`, `Effect.*`, `Data.Function.Uncurried`,
`Record.Builder` — the surface essentially every PureScript program touches. It
is copied into every build wholesale, and that is right for a floor that every
program stands on.

It is not right for `foreign-object`, or `argonaut-core`, or the next registry
package with an FFI. Those are dependencies some programs have and others do
not, and putting them in `runtime.go` makes every Gnomon binary carry the FFI
of packages it never mentions.

So: **one file per PureScript MODULE, named for the module.**

```
foreign/Foreign.Object.go        →  Foreign_Object_foreign.go in the output
foreign/Foreign.Object.ST.go     →  Foreign_Object_ST_foreign.go
foreign/Data.Argonaut.Core.go    →  Data_Argonaut_Core_foreign.go
foreign/Data.Argonaut.Parser.go  →  Data_Argonaut_Parser_foreign.go
```

## How a file here reaches a build

`Main.purs` copies `foreign/<Module.Name>.go` into the output directory for
every module in the **built set** — everything the optimizer read corefn for,
which is the program's whole dependency closure. Demand-driven, and derived from
the compilation itself: there is no list of packages to keep in step with
anything.

Two deliberate choices in that:

- **The built set, not the reachable set.** A module can be pruned to nothing
  and still have its foreigns referenced from elsewhere — `Foreign.Object.ST`
  emits no Go file at all, yet `Foreign_Object.go` calls
  `Foreign_Object_ST_poke`. Keying on what survived pruning would miss exactly
  the cases that matter.
- **Over-inclusion is safe, omission is not.** A program that depends on
  `argonaut-core` but never calls it still gets the file: a handful of unused
  package-level `var`s, which Go permits and the linker drops. The other
  direction is a build that does not link.

## Adding a package

1. Write `foreign/<Module.Name>.go`, `package main`, mirroring
   `.spago/p/<pkg>/src/**/<Module>.js` function for function.
2. Follow the ABI in `runtime.go`'s header: everything is `any`; curried unary
   closures; `FnN`/`EffectFnN` are variadic `func(...any) any`; `Effect a` is a
   `func() any` thunk; records and `Foreign.Object` are `map[string]any`; ADTs
   are `V{Tag,Fields}`; `Nullable a` is the value or `nil`.
3. Say in the header where the JS original lives and **where the two runtimes
   cannot agree** — Go maps do not preserve key order and Go ints do not wrap
   to int32, so a faithful port sometimes has a divergence to declare rather
   than hide. `Foreign.Object.go`'s key-order caveat is the model.
4. `gofmt` it.
5. `./run_conformance.sh`.

## History

This layer was created 2026-08-24, seeded from four files that had accumulated
in Bosun's `conformance/go/`. Bosun is a *demonstrator* — its job is to stress
the backend — and it had ended up carrying the backend's FFI for two registry
packages because there was nowhere else to put it. The instruction that closed
it: "definitely the idea is to enhance the upstream backend, not to shim it in
Bosun or any other demonstrator."
