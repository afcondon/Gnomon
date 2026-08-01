// `performance` is a global in Node 16+ and in browsers; `process.hrtime` is
// Node-only and would make the reference backend refuse to run anywhere else.
export const nowNs = () => performance.now() * 1e6;

// console.log already flushes on Node; the shim exists for the runtimes
// that block-buffer a redirected stdout.
export const flushOut = () => {};

export const ffiInc = (x) => x + 1;

export const ffiSumArray = (xs) => {
  let s = 0;
  for (let i = 0; i < xs.length; i++) s += xs[i];
  return s;
};
