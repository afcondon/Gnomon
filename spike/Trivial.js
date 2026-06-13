// JS FFI for Trivial.purs — the reference semantics for the differential gate.
// Mirrors the Go shims in Language.PureScript.Go.Foreigns exactly.
export const goLog = (s) => () => { console.log(s); };
export const goConcat = (a) => (b) => a + b;
export const goIntToString = (n) => String(n);
export const goAdd = (a) => (b) => a + b;
export const goMul = (a) => (b) => a * b;
export const pureEffect = (a) => () => a;
export const bindEffect = (m) => (k) => () => k(m())();
