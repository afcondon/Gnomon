-- | Boundary-value tables for the primitive types.
-- |
-- | A different KIND of module from the rest of the corpus. `Test.Numbers`
-- | and friends ask *is this API present and roughly right?*; this one asks
-- | *where exactly does each primitive break?* and enumerates the places
-- | systematically — limits, ties, sign of zero, representability edges,
-- | out-of-range conversions, shift counts at and past the word size.
-- |
-- | It exists because of a bug the rest of the process could not catch.
-- | `Data.Number.round` was implemented as `floor(n + 0.5)` on two of the
-- | three backends — the classic `Math.round` polyfill bug, wrong wherever
-- | `n + 0.5` rounds up in float64. It survived a shim doctrine that says
-- | mirror the real JS foreign, a correct comment on the line itself, a
-- | corpus that tests `round` (with 2.5 and -2.5, both comfortable ties), a
-- | portability index that sees *missing* foreigns and not *wrong* ones, and
-- | on one backend being written twice in two runtimes, identically.
-- |
-- | The divergence ledger has few entries because the corpus has twenty
-- | modules that we wrote. This measures the surface instead of sampling it.
-- | See `docs/kb/research/primitive-type-portability.md`.
-- |
-- | Every value below is chosen, not swept: an exhaustive sweep is Gate D12's
-- | job (same-seed fuzzing). These are the points where an implementation
-- | that is merely plausible parts company with one that is right.
module Test.Boundaries where

import Prelude

import Data.Char as Char
import Data.Enum (toEnum, fromEnum)
import Data.Int as Int
import Data.Int.Bits as Bits
import Data.Maybe (Maybe(..))
import Data.Number as Num
import Data.String.CodeUnits as CU
import Effect (Effect)
import Effect.Console (log)

t :: String -> String -> Effect Unit
t name v = log ("TEST " <> name <> ": " <> v)

-- | The sign of a zero is invisible to `show` on some runtimes and to `==`
-- | on all of them, but `1/x` tells the truth: +Infinity or -Infinity.
signOfZero :: Number -> String
signOfZero x = show (1.0 / x)

main :: Effect Unit
main = do
  log "=== Test.Boundaries ==="
  intLimits
  intDivision
  intBits
  intConversions
  intParsing
  numberZero
  numberLimits
  numberRepresentability
  numberRounding
  numberShow
  numberFunctions
  numberParsing
  charLimits

--------------------------------------------------------------------------
-- Int — the limits themselves
--
-- `top`/`bottom` are `foreign import`s in purescript-prelude, so every
-- backend CHOOSES them. All three copied JavaScript's 2147483647 while
-- running wider arithmetic underneath, which is the whole of the Int
-- incoherence: `Bounded`'s law says bottom <= a <= top, and these tests are
-- where that either holds or does not.
--------------------------------------------------------------------------

intLimits :: Effect Unit
intLimits = do
  t "int-top" (show (top :: Int))
  t "int-bottom" (show (bottom :: Int))
  t "INT64-int-top-plus-1" (show (top + 1 :: Int))
  t "INT64-int-bottom-minus-1" (show (bottom - 1 :: Int))
  t "INT64-int-negate-bottom" (show (negate (bottom :: Int)))
  t "int-negate-top" (show (negate (top :: Int)))
  t "INT64-int-abs-bottom"
    (show (if (bottom :: Int) < 0 then negate bottom else bottom :: Int))
  -- The `Bounded Int` law, stated as an assertion rather than assumed.
  t "INT64-int-negate-bottom-gt-top" (show (negate (bottom :: Int) > top))
  t "INT64-int-top-times-2" (show (top * 2 :: Int))
  t "INT64-int-bottom-times-2" (show (bottom * 2 :: Int))
  t "INT64-int-top-plus-top" (show (top + top :: Int))
  t "INT64-int-top-times-top" (show (top * top :: Int))

--------------------------------------------------------------------------
-- Int — division at the edges
--
-- `bottom / (-1)` is the classic trap: the true quotient is 2147483648,
-- which is not an Int. Two's-complement hardware wraps it back to bottom;
-- an arbitrary-precision runtime returns the true value; a trapping runtime
-- raises. Three different answers, all defensible, none the same.
--------------------------------------------------------------------------

intDivision :: Effect Unit
intDivision = do
  t "int-div-bottom-by-neg1" (show ((bottom :: Int) / (-1)))
  t "INT64-int-quot-bottom-by-neg1" (show (Int.quot (bottom :: Int) (-1)))
  t "int-rem-bottom-by-neg1" (show (Int.rem (bottom :: Int) (-1)))
  t "int-mod-bottom-by-neg1" (show ((bottom :: Int) `mod` (-1)))
  t "int-div-top-by-neg1" (show ((top :: Int) / (-1)))
  -- Division by zero: PureScript's Int EuclideanRing defines these as 0.
  t "int-div-zero" (show (1 / 0 :: Int))
  t "int-mod-zero" (show (1 `mod` 0 :: Int))
  t "int-quot-zero" (show (Int.quot 1 0))
  t "INT64-int-rem-zero" (show (Int.rem 1 0))
  t "int-zero-div-zero" (show (0 / 0 :: Int))
  -- `degree` is the other place a sentinel hides: our own EuclideanRing shim
  -- clamps it at 2147483647, which is exactly `top`.
  t "int-degree-bottom" (show (degree (bottom :: Int)))
  t "int-degree-top" (show (degree (top :: Int)))
  t "int-degree-zero" (show (degree (0 :: Int)))
  t "int-gcd-bottom-bottom" (show (gcd (bottom :: Int) bottom))
  t "int-gcd-bottom-zero" (show (gcd (bottom :: Int) 0))
  t "INT64-int-lcm-top-top" (show (lcm (top :: Int) top))
  t "int-lcm-zero" (show (lcm (5 :: Int) 0))

--------------------------------------------------------------------------
-- Int — bit operations
--
-- `Data.Int.Bits` is the one place every backend already agrees to be
-- 32-bit, because its laws demand JavaScript's ToInt32. That makes it the
-- foundation a portable `Int32` newtype could be built on today, without
-- anybody's permission — so it had better be right at the edges.
--
-- Shift counts are taken mod 32 in JavaScript, which is the surprising part:
-- `1 << 32` is 1, not 0.
--------------------------------------------------------------------------

intBits :: Effect Unit
intBits = do
  t "bits-complement-zero" (show (Bits.complement 0))
  t "bits-complement-bottom" (show (Bits.complement (bottom :: Int)))
  t "bits-complement-top" (show (Bits.complement (top :: Int)))
  t "bits-and-bottom-top" (show (Bits.and (bottom :: Int) top))
  t "bits-or-bottom-top" (show (Bits.or (bottom :: Int) top))
  t "bits-xor-bottom-bottom" (show (Bits.xor (bottom :: Int) bottom))
  t "bits-xor-neg1-neg1" (show (Bits.xor (-1 :: Int) (-1)))
  -- Left shift: into and past the sign bit.
  t "bits-shl-1-30" (show (Bits.shl 1 30))
  t "bits-shl-1-31" (show (Bits.shl 1 31))
  t "bits-shl-1-32" (show (Bits.shl 1 32))
  t "bits-shl-1-33" (show (Bits.shl 1 33))
  t "bits-shl-1-0" (show (Bits.shl 1 0))
  t "bits-shl-1-neg1" (show (Bits.shl 1 (-1)))
  t "bits-shl-top-1" (show (Bits.shl (top :: Int) 1))
  -- Arithmetic right shift keeps the sign.
  t "bits-shr-bottom-31" (show (Bits.shr (bottom :: Int) 31))
  t "bits-shr-bottom-32" (show (Bits.shr (bottom :: Int) 32))
  t "bits-shr-neg1-1" (show (Bits.shr (-1 :: Int) 1))
  t "bits-shr-neg8-2" (show (Bits.shr (-8 :: Int) 2))
  -- Logical right shift does not: this is where an Int that is secretly
  -- 64-bit or unbounded gives itself away.
  t "bits-zshr-neg1-0" (show (Bits.zshr (-1 :: Int) 0))
  t "bits-zshr-neg1-1" (show (Bits.zshr (-1 :: Int) 1))
  t "bits-zshr-neg1-31" (show (Bits.zshr (-1 :: Int) 31))
  t "bits-zshr-neg1-32" (show (Bits.zshr (-1 :: Int) 32))
  t "bits-zshr-bottom-0" (show (Bits.zshr (bottom :: Int) 0))
  t "bits-zshr-bottom-31" (show (Bits.zshr (bottom :: Int) 31))

--------------------------------------------------------------------------
-- Int <-> Number
--
-- `Int.fromNumber` is partial and the interesting question is what it
-- rejects. `floor`/`ceil`/`round`/`trunc` are total and the interesting
-- question is what they do with values no Int can hold, and with NaN.
--------------------------------------------------------------------------

intConversions :: Effect Unit
intConversions = do
  t "int-fromNumber-2147483647" (show (Int.fromNumber 2147483647.0))
  t "int-fromNumber-2147483648" (show (Int.fromNumber 2147483648.0))
  t "int-fromNumber-neg2147483648" (show (Int.fromNumber (-2147483648.0)))
  t "int-fromNumber-neg2147483649" (show (Int.fromNumber (-2147483649.0)))
  t "int-fromNumber-fractional" (show (Int.fromNumber 1.5))
  t "int-fromNumber-negfractional" (show (Int.fromNumber (-1.5)))
  t "int-fromNumber-negzero" (show (Int.fromNumber (-0.0)))
  t "int-fromNumber-nan" (show (Int.fromNumber (0.0 / 0.0)))
  t "int-fromNumber-inf" (show (Int.fromNumber (1.0 / 0.0)))
  t "int-fromNumber-neginf" (show (Int.fromNumber (-1.0 / 0.0)))
  t "int-toNumber-top" (show (Int.toNumber (top :: Int)))
  t "int-toNumber-bottom" (show (Int.toNumber (bottom :: Int)))
  -- Total conversions, saturating or wrapping — the divergence lives here.
  t "int-floor-huge" (show (Int.floor 1.0e30))
  t "int-floor-neghuge" (show (Int.floor (-1.0e30)))
  t "int-floor-nan" (show (Int.floor (0.0 / 0.0)))
  t "int-floor-inf" (show (Int.floor (1.0 / 0.0)))
  t "int-ceil-huge" (show (Int.ceil 1.0e30))
  t "int-ceil-nan" (show (Int.ceil (0.0 / 0.0)))
  t "int-round-half" (show (Int.round 0.5))
  t "int-round-neghalf" (show (Int.round (-0.5)))
  t "int-round-1half" (show (Int.round 1.5))
  t "int-round-neg1half" (show (Int.round (-1.5)))
  t "int-round-just-under-half" (show (Int.round 0.49999999999999994))
  t "int-round-huge" (show (Int.round 1.0e30))
  t "int-round-nan" (show (Int.round (0.0 / 0.0)))
  t "int-trunc-neg" (show (Int.trunc (-1.9)))
  t "int-trunc-pos" (show (Int.trunc 1.9))
  t "int-trunc-negzero" (show (Int.trunc (-0.4)))

--------------------------------------------------------------------------
-- Int — parsing and radix printing
--
-- `fromString` has to reject everything JavaScript's `parseInt` would
-- happily accept a prefix of, and the radix functions have to agree about
-- how a negative number is written in base 36.
--------------------------------------------------------------------------

intParsing :: Effect Unit
intParsing = do
  t "int-fromString-top" (show (Int.fromString "2147483647"))
  t "int-fromString-over-top" (show (Int.fromString "2147483648"))
  t "int-fromString-bottom" (show (Int.fromString "-2147483648"))
  t "int-fromString-under-bottom" (show (Int.fromString "-2147483649"))
  t "int-fromString-empty" (show (Int.fromString ""))
  t "int-fromString-plus" (show (Int.fromString "+1"))
  t "int-fromString-space-lead" (show (Int.fromString " 1"))
  t "int-fromString-space-trail" (show (Int.fromString "1 "))
  t "int-fromString-trailing-junk" (show (Int.fromString "1x"))
  t "int-fromString-hex" (show (Int.fromString "0x10"))
  t "int-fromString-exp" (show (Int.fromString "1e3"))
  t "int-fromString-float" (show (Int.fromString "1.5"))
  t "int-fromString-neg-zero" (show (Int.fromString "-0"))
  t "int-fromStringAs-bin" (show (Int.fromStringAs Int.binary "1010"))
  t "int-fromStringAs-bin-bad" (show (Int.fromStringAs Int.binary "102"))
  t "int-fromStringAs-hex" (show (Int.fromStringAs Int.hexadecimal "ff"))
  t "int-fromStringAs-hex-upper" (show (Int.fromStringAs Int.hexadecimal "FF"))
  t "int-fromStringAs-base36" (show (Int.fromStringAs Int.base36 "zz"))
  t "int-toStringAs-bin-bottom" (Int.toStringAs Int.binary bottom)
  t "int-toStringAs-bin-neg" (Int.toStringAs Int.binary (-5))
  t "int-toStringAs-hex-bottom" (Int.toStringAs Int.hexadecimal bottom)
  t "int-toStringAs-hex-top" (Int.toStringAs Int.hexadecimal top)
  t "int-toStringAs-base36-top" (Int.toStringAs Int.base36 top)
  t "int-toStringAs-dec-bottom" (Int.toStringAs Int.decimal bottom)

--------------------------------------------------------------------------
-- Number — the sign of zero
--
-- IEEE 754 has two zeros and they compare equal, so `==` cannot tell them
-- apart and a backend can lose the distinction without any test noticing.
-- `1/x` notices. `Math.round(-0.2)` is -0 in JavaScript, which is how the
-- round bug could have been caught earlier than it was.
--------------------------------------------------------------------------

numberZero :: Effect Unit
numberZero = do
  t "num-zero-eq-negzero" (show (0.0 == -0.0))
  t "num-sign-of-poszero" (signOfZero 0.0)
  t "num-sign-of-negzero" (signOfZero (-0.0))
  t "num-sign-of-negzero-literal" (signOfZero (0.0 * (-1.0)))
  t "num-sign-of-round-negsmall" (signOfZero (Num.round (-0.2)))
  t "num-sign-of-ceil-negsmall" (signOfZero (Num.ceil (-0.5)))
  t "num-sign-of-trunc-negsmall" (signOfZero (Num.trunc (-0.5)))
  t "num-sign-of-negzero-plus-negzero" (signOfZero ((-0.0) + (-0.0)))
  t "num-sign-of-negzero-plus-zero" (signOfZero ((-0.0) + 0.0))
  t "num-sign-of-sqrt-negzero" (signOfZero (Num.sqrt (-0.0)))
  t "num-show-negzero" (show (-0.0))
  t "NEGZERO-num-min-zeros" (signOfZero (Num.min 0.0 (-0.0)))
  t "num-max-zeros" (signOfZero (Num.max 0.0 (-0.0)))

--------------------------------------------------------------------------
-- Number — the limits of the format
--------------------------------------------------------------------------

numberLimits :: Effect Unit
numberLimits = do
  t "num-max-value" (show 1.7976931348623157e308)
  t "num-max-value-times-2" (show (1.7976931348623157e308 * 2.0))
  t "num-min-normal" (show 2.2250738585072014e-308)
  t "num-min-subnormal" (show 5.0e-324)
  t "num-min-subnormal-halved" (show (5.0e-324 / 2.0))
  t "num-subnormal-arith" (show (5.0e-324 * 3.0))
  t "num-epsilon" (show 2.220446049250313e-16)
  t "num-one-plus-epsilon" (show (1.0 + 2.220446049250313e-16))
  t "num-one-plus-half-epsilon" (show (1.0 + 1.1102230246251565e-16))
  t "num-inf" (show (1.0 / 0.0))
  t "num-neginf" (show (-1.0 / 0.0))
  t "num-nan" (show (0.0 / 0.0))
  t "num-inf-minus-inf" (show ((1.0 / 0.0) - (1.0 / 0.0)))
  t "num-zero-times-inf" (show (0.0 * (1.0 / 0.0)))
  t "num-nan-eq-nan" (show ((0.0 / 0.0) == (0.0 / 0.0)))
  t "num-nan-lt" (show ((0.0 / 0.0) < 1.0))
  t "num-nan-compare" (show (compare (0.0 / 0.0) 1.0))
  t "num-min-nan" (show (Num.min (0.0 / 0.0) 1.0))
  t "num-max-nan" (show (Num.max (0.0 / 0.0) 1.0))

--------------------------------------------------------------------------
-- Number — integer representability
--
-- 2^53 is where consecutive integers stop being representable, and it is
-- where the `floor(n + 0.5)` round bug produces a value one too large.
--------------------------------------------------------------------------

numberRepresentability :: Effect Unit
numberRepresentability = do
  t "num-2pow52" (show 4503599627370496.0)
  t "num-2pow52-plus-1" (show 4503599627370497.0)
  t "num-2pow53" (show 9007199254740992.0)
  t "num-2pow53-plus-1" (show 9007199254740993.0)
  t "num-2pow53-plus-2" (show 9007199254740994.0)
  t "num-2pow53-eq-plus-1" (show (9007199254740992.0 == 9007199254740993.0))
  t "num-2pow53-plus-1-minus" (show (9007199254740993.0 - 9007199254740992.0))
  t "num-2pow63" (show 9223372036854775808.0)
  t "num-1e21" (show 1.0e21)
  t "num-1e20" (show 1.0e20)

--------------------------------------------------------------------------
-- Number — the rounding family, at ties and near-ties
--
-- This is the section the whole module was written for. `round` ties toward
-- +Infinity in JavaScript, which is NOT round-half-even and NOT
-- round-half-away-from-zero: -2.5 rounds to -2, not -3. And
-- `0.49999999999999994` is the largest double below 0.5, so any
-- implementation that adds 0.5 first rounds it up to 1 and is wrong.
--------------------------------------------------------------------------

numberRounding :: Effect Unit
numberRounding = do
  t "num-round-half" (show (Num.round 0.5))
  t "num-round-neghalf" (show (Num.round (-0.5)))
  t "num-round-1half" (show (Num.round 1.5))
  t "num-round-neg1half" (show (Num.round (-1.5)))
  t "num-round-2half" (show (Num.round 2.5))
  t "num-round-neg2half" (show (Num.round (-2.5)))
  t "num-round-just-under-half" (show (Num.round 0.49999999999999994))
  t "num-round-neg-just-under-half" (show (Num.round (-0.49999999999999994)))
  t "num-round-just-over-half" (show (Num.round 0.5000000000000001))
  t "num-round-2pow52-plus-1" (show (Num.round 4503599627370497.0))
  t "num-round-2pow53" (show (Num.round 9007199254740992.0))
  t "num-round-large-half" (show (Num.round 123456789.5))
  t "num-round-tiny" (show (Num.round 1.0e-300))
  t "num-round-nan" (show (Num.round (0.0 / 0.0)))
  t "num-round-inf" (show (Num.round (1.0 / 0.0)))
  t "num-floor-neghalf" (show (Num.floor (-0.5)))
  t "num-floor-neg-integral" (show (Num.floor (-2.0)))
  t "num-floor-nan" (show (Num.floor (0.0 / 0.0)))
  t "num-floor-inf" (show (Num.floor (1.0 / 0.0)))
  t "num-ceil-half" (show (Num.ceil 0.5))
  t "num-ceil-neghalf" (show (Num.ceil (-0.5)))
  t "num-ceil-nan" (show (Num.ceil (0.0 / 0.0)))
  t "num-trunc-half" (show (Num.trunc 0.5))
  t "num-trunc-neghalf" (show (Num.trunc (-0.5)))
  t "num-trunc-nan" (show (Num.trunc (0.0 / 0.0)))
  t "num-trunc-inf" (show (Num.trunc (1.0 / 0.0)))

--------------------------------------------------------------------------
-- Number — `show`
--
-- JavaScript's Number.prototype.toString has idiosyncratic rules about when
-- to use exponent notation and how many digits to print. Every backend
-- emulates them; these are the places the emulation is load-bearing.
--------------------------------------------------------------------------

numberShow :: Effect Unit
numberShow = do
  t "show-point-one" (show 0.1)
  t "show-point-one-plus-point-two" (show (0.1 + 0.2))
  t "show-third" (show (1.0 / 3.0))
  t "show-two-thirds" (show (2.0 / 3.0))
  t "show-1e-7" (show 1.0e-7)
  t "show-1e-6" (show 1.0e-6)
  t "show-1e21" (show 1.0e21)
  t "show-1e20" (show 1.0e20)
  t "show-neg-1e-7" (show (-1.0e-7))
  t "show-integral" (show 3.0)
  t "show-neg-integral" (show (-3.0))
  t "show-large-integral" (show 123456789012345680.0)
  t "show-min-subnormal" (show 5.0e-324)
  t "show-max-value" (show 1.7976931348623157e308)
  t "show-round-trip-third" (show (Num.fromString (show (1.0 / 3.0))))

--------------------------------------------------------------------------
-- Number — libm at the edges
--
-- The long tail. These are the calls where two conforming libm
-- implementations are allowed to differ in the last bit, and where a
-- reimplementation is most likely to differ by much more.
--------------------------------------------------------------------------

numberFunctions :: Effect Unit
numberFunctions = do
  t "num-pow-zero-zero" (show (Num.pow 0.0 0.0))
  t "num-pow-neg1-inf" (show (Num.pow (-1.0) (1.0 / 0.0)))
  t "num-pow-1-nan" (show (Num.pow 1.0 (0.0 / 0.0)))
  t "num-pow-nan-zero" (show (Num.pow (0.0 / 0.0) 0.0))
  t "num-pow-neg8-third" (show (Num.pow (-8.0) (1.0 / 3.0)))
  t "num-pow-zero-neg1" (show (Num.pow 0.0 (-1.0)))
  t "num-pow-negzero-neg1" (show (Num.pow (-0.0) (-1.0)))
  t "num-sqrt-neg" (show (Num.sqrt (-1.0)))
  t "num-log-zero" (show (Num.log 0.0))
  t "num-log-negzero" (show (Num.log (-0.0)))
  t "num-log-neg" (show (Num.log (-1.0)))
  t "num-log-inf" (show (Num.log (1.0 / 0.0)))
  t "num-exp-large" (show (Num.exp 1000.0))
  t "num-exp-neg-large" (show (Num.exp (-1000.0)))
  t "num-asin-one" (show (Num.asin 1.0))
  t "num-asin-oob" (show (Num.asin 1.0000000000000002))
  t "num-acos-oob" (show (Num.acos (-1.0000000000000002)))
  t "num-atan2-zero-zero" (show (Num.atan2 0.0 0.0))
  t "num-atan2-negzero-zero" (show (Num.atan2 (-0.0) 0.0))
  t "num-atan2-zero-negzero" (show (Num.atan2 0.0 (-0.0)))
  t "num-atan2-inf-inf" (show (Num.atan2 (1.0 / 0.0) (1.0 / 0.0)))
  t "num-remainder-by-zero" (show (Num.remainder 1.0 0.0))
  t "num-remainder-inf" (show (Num.remainder (1.0 / 0.0) 1.0))
  t "num-remainder-neg" (show (Num.remainder (-7.5) 2.0))
  t "num-abs-negzero" (signOfZero (Num.abs (-0.0)))
  t "num-sign-negzero" (show (Num.sign (-0.0)))
  t "num-sign-nan" (show (Num.sign (0.0 / 0.0)))

--------------------------------------------------------------------------
-- Number — parsing
--------------------------------------------------------------------------

numberParsing :: Effect Unit
numberParsing = do
  t "num-fromString-inf" (show (Num.fromString "Infinity"))
  t "num-fromString-neginf" (show (Num.fromString "-Infinity"))
  t "num-fromString-nan" (show (Num.fromString "NaN"))
  t "num-fromString-hex" (show (Num.fromString "0x10"))
  t "num-fromString-empty" (show (Num.fromString ""))
  t "num-fromString-space" (show (Num.fromString " 1.5 "))
  t "num-fromString-trailing" (show (Num.fromString "1.5x"))
  t "num-fromString-underscore" (show (Num.fromString "1_000"))
  t "num-fromString-leading-dot" (show (Num.fromString ".5"))
  t "num-fromString-trailing-dot" (show (Num.fromString "5."))
  t "num-fromString-plus" (show (Num.fromString "+1.5"))
  t "num-fromString-negzero" (show (Num.fromString "-0"))
  t "num-fromString-subnormal" (show (Num.fromString "5e-324"))
  t "num-fromString-overflow" (show (Num.fromString "1e400"))

--------------------------------------------------------------------------
-- Char — the code-unit boundary
--
-- PureScript's `Char` is a UTF-16 code unit, not a code point. The
-- boundaries are 0, the surrogate range (which is representable but not a
-- character), and 0xFFFF. Everything above needs two of them, which is the
-- string-representation divergence already in the ledger; these tests pin
-- the primitive itself rather than the string API over it.
--------------------------------------------------------------------------

charLimits :: Effect Unit
charLimits = do
  t "char-toCharCode-nul" (show (Char.toCharCode '\x0'))
  t "char-toCharCode-max" (show (Char.toCharCode '\xFFFF'))
  t "char-fromCharCode-0" (show (map Char.toCharCode (Char.fromCharCode 0)))
  t "char-fromCharCode-max" (show (map Char.toCharCode (Char.fromCharCode 65535)))
  t "char-fromCharCode-over" (show (map Char.toCharCode (Char.fromCharCode 65536)))
  t "char-fromCharCode-neg" (show (map Char.toCharCode (Char.fromCharCode (-1))))
  -- Lone surrogates: representable as Char, not valid on their own as text.
  t "ASTRAL-char-fromCharCode-high-surrogate" (show (map Char.toCharCode (Char.fromCharCode 55296)))
  t "ASTRAL-char-fromCharCode-low-surrogate" (show (map Char.toCharCode (Char.fromCharCode 57343)))
  t "char-enum-top" (show (fromEnum (top :: Char)))
  t "char-enum-bottom" (show (fromEnum (bottom :: Char)))
  t "char-toEnum-over" (show (map Char.toCharCode (toEnum 65536 :: Maybe Char)))
  -- An astral character is two code units, and `length` says so.
  t "char-astral-length" (show (CU.length "\x1F600"))
  t "char-astral-take-1" (show (map Char.toCharCode (CU.charAt 0 "\x1F600")))
  t "char-astral-take-2" (show (map Char.toCharCode (CU.charAt 1 "\x1F600")))
  t "char-bmp-length" (show (CU.length "é"))
