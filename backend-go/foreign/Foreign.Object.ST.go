// Go foreigns for Foreign.Object.ST (foreign-object 4.1.0). See
// foreign/README.md for how a file in this directory reaches a build.
//
// The mutable-object builder `Foreign.Object.fromFoldable` runs under `runST`,
// which is how every codec-argonaut record encoder assembles its object — so a
// program that never mentions ST still needs these the moment it encodes JSON.
// That is how the gap was found: Bosun's `bosun serve` grew a codec-encoded
// `/where` answer, and the Go build stopped linking.
//
// A Go `map[string]any` is already a reference, so `poke` mutates in place and
// hands the SAME map back exactly as the JS does — no copy, and the ST region's
// no-aliasing guarantee comes from the types, not from us.
//
// `new` is emitted as `new_`: backend-go suffixes a name that collides with a
// Go keyword.
package main

// new :: ST r (STObject r a) — a thunk, per the Effect/ST ABI.
var Foreign_Object_ST_new_ any = func() any { return map[string]any{} }

// poke :: String -> a -> STObject r a -> ST r (STObject r a)  (curried)
var Foreign_Object_ST_poke any = func(k any) any {
	return func(v any) any {
		return func(m any) any {
			return func() any {
				m.(map[string]any)[k.(string)] = v
				return m
			}
		}
	}
}

// peekImpl :: (a -> b) -> b -> String -> STObject r a -> ST r b  (curried)
var Foreign_Object_ST_peekImpl any = func(just any) any {
	return func(nothing any) any {
		return func(k any) any {
			return func(m any) any {
				return func() any {
					if v, ok := m.(map[string]any)[k.(string)]; ok {
						return just.(func(any) any)(v)
					}
					return nothing
				}
			}
		}
	}
}
