{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE TupleSections #-}

module Data.IP.Builder
    ( -- * 'P.BoundedPrim' 'B.Builder's for general, IPv4 and IPv6 addresses.
      ipBuilder
    , ipv4Builder
    , ipv6Builder
    ) where

import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Builder.Prim as P
import           Data.ByteString.Builder.Prim ((>$<), (>*<))
import           GHC.Exts
import           GHC.Word (Word8(..), Word16(..), Word32(..))

import           Data.IP.Addr

------------ IP builders

{-# INLINE ipBuilder #-}
-- | 'P.BoundedPrim' bytestring 'B.Builder' for general 'IP' addresses.
ipBuilder :: IP -> B.Builder
ipBuilder (IPv4 addr) = ipv4Builder addr
ipBuilder (IPv6 addr) = ipv6Builder addr

{-# INLINE ipv4Builder #-}
-- | 'P.BoundedPrim' bytestring 'B.Builder' for 'IPv4' addresses.
ipv4Builder :: IPv4 -> B.Builder
ipv4Builder addr = P.primBounded ipv4Bounded $! fromIPv4w addr

{-# INLINE ipv6Builder #-}
-- | 'P.BoundedPrim' bytestring 'B.Builder' for 'IPv6' addresses.
ipv6Builder :: IPv6 -> B.Builder
ipv6Builder addr = P.primBounded ipv6Bounded $! fromIPv6w addr

------------ Builder utilities

-- Convert fixed to bounded for fusion
toB :: P.FixedPrim a -> P.BoundedPrim a
toB = P.liftFixedToBounded
{-# INLINE toB #-}

{-# INLINE ipv4Bounded #-}
ipv4Bounded :: P.BoundedPrim Word32
ipv4Bounded =
    quads >$< ((P.word8Dec >*< dotsep) >*< (P.word8Dec >*< dotsep))
          >*< ((P.word8Dec >*< dotsep) >*< P.word8Dec)
  where
    quads a = ((qdot 0o30# a, qdot 0o20# a), (qdot 0o10# a, qfin a))
    {-# INLINE quads #-}
    qdot s (W32# a) = (W8# ((a `uncheckedShiftRL#` s) `and#` 0xff##), ())
    {-# INLINE qdot #-}
    qfin (W32# a) = W8# (a `and#` 0xff##)
    {-# INLINE qfin #-}
    dotsep = const 0x2e >$< toB P.word8

-- | For each of the 32-bit chunks of an IPv6 address, encode how it should be
-- displayed in the presentation form of the address, based its location
-- relative to the "best gap", i.e.  the left-most longest run of zeros. The
-- "hi" and, or "lo" parts are accompanied by occasional units mapped to colons.
--
data FF = CHL {-# UNPACK #-} ! Word32  -- ^ :<h>:<l>
        | HL  {-# UNPACK #-} ! Word32  -- ^  <h>:<l>
        | NOP                          -- ^  nop
        | COL                          -- ^ :
        | CLO {-# UNPACK #-} ! Word32  -- ^     :<l>
        | CC                           -- ^ :   :
        | CHC {-# UNPACK #-} ! Word32  -- ^ :<h>:
        | HC  {-# UNPACK #-} ! Word32  -- ^  <h>:

-- Build an IPv6 address in conformance with
-- [RFC5952](http://tools.ietf.org/html/rfc5952 RFC 5952).
--
{-# INLINE ipv6Bounded #-}
ipv6Bounded :: P.BoundedPrim (Word32, Word32, Word32, Word32)
ipv6Bounded =
    P.condB generalCase
      ( genFields >$< output128 )
      ( P.condB v4mapped
          ( pairPair >$< (colsep >*< colsep)
                     >*< (ffff >*< (fstUnit >$< colsep >*< ipv4Bounded)) )
          ( pairPair >$< (P.emptyB >*< colsep) >*< (colsep >*< ipv4Bounded) ) )
  where
    -- The boundedPrim switches and predicates need to be inlined for best
    -- performance, gaining a factor of ~2 in throughput in tests.
    --
    {-# INLINE output128 #-}
    {-# INLINE output64 #-}
    {-# INLINE generalCase #-}
    {-# INLINE v4mapped #-}
    {-# INLINE output32 #-}

    generalCase :: (Word32, Word32, Word32, Word32) -> Bool
    generalCase (w0, w1, w2, w3) =
        w0 /= 0 || w1 /= 0 || (w2 /= 0xffff && (w2 /= 0 || w3 <= 0xffff))
    --
    v4mapped :: (Word32, Word32, Word32, Word32) -> Bool
    v4mapped (w0, w1, w2, _) =
        w0 == 0 && w1 == 0 && w2 == 0xffff

    -- BoundedPrim for the full 128-bit IPv6 address given as
    -- a pair of pairs of FF values, which encode the
    -- output format of each of the 32-bit chunks.
    --
    output128 :: P.BoundedPrim ((FF, FF), (FF, FF))
    output128 = output64 >*< output64
    output64 = (output32 >*< output32)
    --
    -- And finally the per-word case-work.
    --
    output32 :: P.BoundedPrim FF
    output32 =
        P.condB ffCond03
          ( P.condB ffCond01
               ( P.condB ffCond0
                   build_CHL        -- :<h>:<l>
                   build_HL )       -- <h>:<l>
               ( P.condB ffCond2
                   build_NOP        -- nop
                   build_COL ) )    -- :
          ( P.condB ffCond45
               ( P.condB ffCond4
                   build_CLO        -- :<l>
                   build_CC  )      -- :   :
               ( P.condB ffCond6
                   build_CHC        -- :<h>:
                   build_HC ) )     -- <h>:

    -- Branch selection predicates
    ffCond03 = \case { CHL _ -> True; HL  _ -> True;
                       NOP   -> True; COL   -> True; _ -> False }
    ffCond01 = \case { CHL _ -> True; HL  _ -> True; _ -> False }
    ffCond45 = \case { CC    -> True; CLO _ -> True; _ -> False }
    ffCond0  = \case { CHL _ -> True;                _ -> False }
    ffCond2  = \case { NOP   -> True;                _ -> False }
    ffCond4  = \case { CLO _ -> True;                _ -> False }
    ffCond6  = \case { CHC _ -> True;                _ -> False }

    -- encoders for the seven field format (FF) cases.
    --
    build_CHL = (\ (CHL w) -> ( fstUnit (hi16 w), fstUnit (lo16 w) ) )
                >$< (colsep >*< P.word16Hex)
                >*< (colsep >*< P.word16Hex)
    --
    build_HL  = (\ (HL  w) -> ( hi16 w, fstUnit (lo16 w) ) )
                >$< P.word16Hex >*< colsep >*< P.word16Hex
    --
    build_NOP  = P.emptyB
    --
    build_COL  = const () >$< colsep
    --
    build_CC   = const ((), ()) >$< colsep >*< colsep
    --
    build_CLO = (\ (CLO w) -> fstUnit (lo16 w) )
                >$< colsep >*< P.word16Hex
    --
    build_CHC = (\ (CHC w) -> fstUnit (sndUnit (hi16 w)) )
                >$< colsep >*< P.word16Hex >*< colsep
    --
    build_HC  = (\ (HC  w) -> sndUnit (hi16 w))
                >$< P.word16Hex >*< colsep

    -- static encoders
    --
    colsep :: P.BoundedPrim a
    colsep = toB $ const 0x3a >$< P.word8
    --
    ffff :: P.BoundedPrim a
    ffff = toB $ const 0xffff >$< P.word16HexFixed

    -- | Helpers
    hi16, lo16 :: Word32 -> Word16
    hi16 !(W32# w) = W16# (w `uncheckedShiftRL#` 16#)
    lo16 !(W32# w) = W16# (w `and#` 0xffff##)
    --
    fstUnit :: a -> ((), a)
    fstUnit = ((), )
    --
    sndUnit :: a -> (a, ())
    sndUnit = (, ())
    --
    pairPair (a, b, c, d) = ((a, b), (c, d))

    -- Construct fields decorated with output format details
    genFields (w0, w1, w2, w3) =
        let !(!gapStart, !gapEnd) = bestgap w0 w1 w2 w3
            !f0 = makeF0 gapStart gapEnd w0
            !f1 = makeF12 gapStart gapEnd 2# 3# w1
            !f2 = makeF12 gapStart gapEnd 4# 5# w2
            !f3 = makeF3 gapStart gapEnd w3
         in ((f0, f1), (f2, f3))

    makeF0 (I# gapStart) (I# gapEnd) !w =
        case (gapEnd ==# 0#) `orI#` (gapStart ># 1#) of
        1#                               -> HL  w
        _  -> case gapStart ==# 0# of
              1#                         -> COL
              _                          -> HC  w
    {-# INLINE makeF0 #-}

    makeF12 (I# gapStart) (I# gapEnd) il ir !w =
        case (gapEnd <=# il) `orI#` (gapStart ># ir) of
        1#                               -> CHL w
        _ -> case gapStart >=# il of
             1# -> case gapStart ==# il of
                   1#                    -> COL
                   _                     -> CHC w
             _  -> case gapEnd ==# ir of
                   0#                    -> NOP
                   _                     -> CLO w
    {-# INLINE makeF12 #-}

    makeF3 (I# gapStart) (I# gapEnd) !w =
        case gapEnd <=# 6# of
        1#                               -> CHL w
        _ -> case gapStart ==# 6# of
             0# -> case gapEnd ==# 8# of
                   1#                    -> COL
                   _                     -> CLO w
             _                           -> CC
    {-# INLINE makeF3 #-}

-- | Unrolled and inlined calculation of the first longest
-- run (gap) of 16-bit aligned zeros in the input address.
--
bestgap :: Word32 -> Word32 -> Word32 -> Word32 -> (Int, Int)
bestgap !(W32# a0) !(W32# a1) !(W32# a2) !(W32# a3) =
    finalGap
        (updateGap (0xffff##     `and#` a3)
        (updateGap (0xffff0000## `and#` a3)
        (updateGap (0xffff##     `and#` a2)
        (updateGap (0xffff0000## `and#` a2)
        (updateGap (0xffff##     `and#` a1)
        (updateGap (0xffff0000## `and#` a1)
        (updateGap (0xffff##     `and#` a0)
        (initGap   (0xffff0000## `and#` a0)))))))))
  where

    -- The state after the first input word is always i' = 7,
    -- but if the input word is zero, then also g=z=1 and e'=7.
    initGap :: Word# -> Int#
    initGap w = case w of { 0## -> 0x1717#; _ -> 0x0707# }

    -- Update the nibbles of g|e'|z|i' based on the next input
    -- word.  We always decrement i', reset z on non-zero input,
    -- otherwise increment z and check for a new best gap, if so
    -- we replace g|e' with z|i'.
    updateGap :: Word# -> Int# -> Int#
    updateGap w g = case w `neWord#` 0## of
        1# -> (g +# 0xffff#) `andI#` 0xff0f#  -- g, e, 0, --i
        _  -> let old = g +# 0xf#             -- ++z, --i
                  zi  = old `andI#` 0xff#
                  new = (zi `uncheckedIShiftL#` 8#) `orI#` zi
               in case new ># old of
                  1# -> new            -- z, i, z, i
                  _  -> old            -- g, e, z, i

    -- Extract gap start and end from the nibbles of g|e'|z|i'
    -- where g is the gap width and e' is 8 minus its end.
    finalGap :: Int# -> (Int, Int)
    finalGap i =
        let g = i `uncheckedIShiftRL#` 12#
         in case g <# 2# of
            1# -> (0, 0)
            _  -> let e = 8# -# ((i `uncheckedIShiftRL#` 8#) `andI#` 0xf#)
                      s = e -# g
                   in (I# s, I# e)
{-# INLINE bestgap #-}
