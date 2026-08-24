// Go foreigns for Data.Argonaut.Core (argonaut-core 7.0.0). See
// foreign/README.md for how a file in this directory reaches a build.
//
// Written in the Bosun repo first (2026-06) and moved here 2026-08-24 with the
// rest of the registry-package layer: a demonstrator that has to carry the
// backend's FFI is a demonstrator carrying the backend's work.
//
// Representation: argonaut's opaque `Json` is, at runtime, exactly the decoded
// value — `map[string]any` (object) / `[]any` (array) / `float64` (number) /
// `string` / `bool` / `nil` (null) — which is precisely what `encoding/json`
// produces into an `interface{}`. So the `from*` coercions are identities and
// `_caseJson` is a type switch.
//
// backend-go ABI: foreign `Data.Argonaut.Core.name` → `var Data_Argonaut_Core_name`;
// a leading-underscore name (`_caseJson`) → `Data_Argonaut_Core__caseJson`
// (module sep `_` + the name's own `_`). An uncurried `FnN` foreign is a
// variadic `func(args ...any) any` (args collected by runFnN).
package main

import "encoding/json"

// from* :: x -> Json — a typed view of the same runtime value (JS: `id`).
var Data_Argonaut_Core_fromBoolean any = func(x any) any { return x }
var Data_Argonaut_Core_fromNumber any = func(x any) any { return x }
var Data_Argonaut_Core_fromString any = func(x any) any { return x }
var Data_Argonaut_Core_fromArray any = func(x any) any { return x }
var Data_Argonaut_Core_fromObject any = func(x any) any { return x }

// jsonNull :: Json
var Data_Argonaut_Core_jsonNull any = nil

// _caseJson :: Fn7 (Unit->a) (Boolean->a) (Number->a) (String->a)
//
//	(Array Json->a) (Object Json->a) Json a
//
// Every branch is a unary `func(any) any` (the null branch's argument is unit /
// ignored, mirroring the JS `isNull()` const-style call). Numbers are float64
// (encoding/json's interface{} number), but an int is tolerated and widened.
var Data_Argonaut_Core__caseJson any = func(args ...any) any {
	isNull := args[0].(func(any) any)
	isBool := args[1].(func(any) any)
	isNum := args[2].(func(any) any)
	isStr := args[3].(func(any) any)
	isArr := args[4].(func(any) any)
	isObj := args[5].(func(any) any)
	switch v := args[6].(type) {
	case nil:
		return isNull(nil)
	case bool:
		return isBool(v)
	case float64:
		return isNum(v)
	case int:
		return isNum(float64(v))
	case string:
		return isStr(v)
	case []any:
		return isArr(v)
	case map[string]any:
		return isObj(v)
	default:
		return isObj(args[6])
	}
}

// stringify :: Json -> String
//
// Reached only through `Data.Codec.Argonaut.printJsonDecodeError` — the text a
// decode failure carries. `encoding/json` sorts object keys where JS
// `JSON.stringify` preserves insertion order, so a diagnostic naming a
// multi-key object can differ between the columns. That is accepted here and
// nowhere else: this string is read by a human who is already looking at a
// broken payload, and the alternative (an order-preserving Json
// representation) is the same deferred work `foreign_object_foreign.go`'s
// key-order caveat describes.
var Data_Argonaut_Core_stringify any = func(x any) any {
	b, err := json.Marshal(x)
	if err != nil {
		return ""
	}
	return string(b)
}
