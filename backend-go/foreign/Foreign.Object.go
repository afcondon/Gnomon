// Go foreigns for Foreign.Object (foreign-object 4.1.0). See foreign/README.md
// for how a file in this directory reaches a build.
//
// Written in the Bosun repo first (2026-06) and moved here 2026-08-24: a
// registry package's FFI is the BACKEND's to provide, not each demonstrator's
// to re-derive. Bosun found the gap by being the first Gnomon program to
// compile PureScript that touches an Object; the next one should find the
// answer already here.
//
// Representation: a `Foreign.Object a` is a `map[string]any`, the same shape as
// a JSON object and a PureScript record at runtime. ST actions are `func() any`
// thunks (the Effect ABI). An uncurried `FnN` foreign is `func(args ...any) any`.
//
// CAVEAT — KEY ORDER: JS `for (k in obj)` and `Object.keys` iterate in insertion
// order; Go `for k := range m` is RANDOMISED. So `keys` / `toArrayWithKey` /
// `toUnfoldable` here may differ in order from the node build. This does not
// affect array-sourced input (e.g. a registry's `servers` array) or pure
// lookups, but an object-keyed compose with multiple services could order its
// services differently across columns. Fixing it needs an order-preserving
// Object representation (a custom JSON tokeniser); deferred until a multi-service
// object-keyed fixture actually requires byte-identical ordering.
package main

// empty :: Object a
var Foreign_Object_empty any = map[string]any{}

// size :: Object a -> Int
var Foreign_Object_size any = func(m any) any { return len(m.(map[string]any)) }

// _lookup :: Fn4 z (a -> z) String (Object a) z
var Foreign_Object__lookup any = func(args ...any) any {
	no := args[0]
	yes := args[1].(func(any) any)
	k := args[2].(string)
	m := args[3].(map[string]any)
	if v, ok := m[k]; ok {
		return yes(v)
	}
	return no
}

// _lookupST :: Fn4 z (a -> z) String (STObject r a) (ST r z)  -- returns a thunk
var Foreign_Object__lookupST any = func(args ...any) any {
	no := args[0]
	yes := args[1].(func(any) any)
	k := args[2].(string)
	m := args[3].(map[string]any)
	return func() any {
		if v, ok := m[k]; ok {
			return yes(v)
		}
		return no
	}
}

// keys :: Object a -> Array String
var Foreign_Object_keys any = func(m any) any {
	mm := m.(map[string]any)
	out := make([]any, 0, len(mm))
	for k := range mm {
		out = append(out, k)
	}
	return out
}

// toArrayWithKey :: (String -> a -> b) -> Object a -> Array b
var Foreign_Object_toArrayWithKey any = func(f any) any {
	ff := f.(func(any) any)
	return func(m any) any {
		mm := m.(map[string]any)
		out := make([]any, 0, len(mm))
		for k, v := range mm {
			out = append(out, ff(k).(func(any) any)(v))
		}
		return out
	}
}

// _fmapObject :: Fn2 (Object a) (a -> b) (Object b)
var Foreign_Object__fmapObject any = func(args ...any) any {
	mm := args[0].(map[string]any)
	f := args[1].(func(any) any)
	r := make(map[string]any, len(mm))
	for k, v := range mm {
		r[k] = f(v)
	}
	return r
}

// _mapWithKey :: Fn2 (Object a) (String -> a -> b) (Object b)
var Foreign_Object__mapWithKey any = func(args ...any) any {
	mm := args[0].(map[string]any)
	f := args[1].(func(any) any)
	r := make(map[string]any, len(mm))
	for k, v := range mm {
		r[k] = f(k).(func(any) any)(v)
	}
	return r
}

// all :: (String -> a -> Boolean) -> Object a -> Boolean
var Foreign_Object_all any = func(f any) any {
	ff := f.(func(any) any)
	return func(m any) any {
		for k, v := range m.(map[string]any) {
			if !ff(k).(func(any) any)(v).(bool) {
				return false
			}
		}
		return true
	}
}

// _copyST :: a -> ST r b   (shallow copy, in a thunk)
var Foreign_Object__copyST any = func(m any) any {
	return func() any {
		mm := m.(map[string]any)
		r := make(map[string]any, len(mm))
		for k, v := range mm {
			r[k] = v
		}
		return r
	}
}

// runST :: (forall r. ST r (STObject r a)) -> Object a   (run the thunk)
var Foreign_Object_runST any = func(f any) any { return f.(func() any)() }

// _foldM :: (m -> (z -> m) -> m) -> (z -> String -> a -> m) -> m -> Object a -> m
var Foreign_Object__foldM any = func(bind any) any {
	bindF := bind.(func(any) any)
	return func(f any) any {
		fF := f.(func(any) any)
		return func(mz any) any {
			return func(m any) any {
				acc := mz
				for k, v := range m.(map[string]any) {
					kk, vv := k, v
					g := func(z any) any { return fF(z).(func(any) any)(kk).(func(any) any)(vv) }
					acc = bindF(acc).(func(any) any)(g)
				}
				return acc
			}
		}
	}
}

// _foldSCObject :: Fn4 (Object a) z (z -> String -> a -> Maybe z) (forall b. b -> Maybe b -> b) z
var Foreign_Object__foldSCObject any = func(args ...any) any {
	mm := args[0].(map[string]any)
	z := args[1]
	f := args[2].(func(any) any)
	fromMaybe := args[3].(func(any) any)
	acc := z
	for k, v := range mm {
		maybeR := f(acc).(func(any) any)(k).(func(any) any)(v)
		r := fromMaybe(nil).(func(any) any)(maybeR)
		if r == nil {
			return acc
		}
		acc = r
	}
	return acc
}
