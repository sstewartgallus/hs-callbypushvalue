{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module CostInliner (extract, extractData, CostInliner) where

import qualified AsDup
import AsDup (AsDup)
import qualified AsInlineCost
import AsInlineCost (AsInlineCost)
import Cbpv
import Control.Category
import qualified Cps
import HasCall
import HasCode
import HasConstants
import HasData
import HasLet
import HasStack
import HasTuple
import NatTrans
import PairF
import qualified Path
import qualified SystemF as F
import Prelude hiding ((.), (<*>))

extract :: Code (CostInliner t) :~> Code t
extract = NatTrans $ \(C x) -> case AsDup.extract # x of
  PairF _ r -> r

extractData :: Data (CostInliner t) :~> Data t
extractData = NatTrans $ \(D x) -> case AsDup.extractData # x of
  PairF _ r -> r

inlineThreshold :: Int
inlineThreshold = 5

instance HasLet t => HasLet (CostInliner t) where
  letBe (D x) f = result
    where
      result
        | AsInlineCost.extractData inlineCost <= inlineThreshold = f (D x)
        | otherwise = notinlined
      PairF inlineCost _ = AsDup.extractData # x
      notinlined = C $ letBe x $ \x' -> case f (D x') of
        C y -> y

instance Cps.HasLabel t => Cps.HasLabel (CostInliner t) where
  label (S x) f = result
    where
      result
        | AsInlineCost.extractStack inlineCost <= inlineThreshold = f (S x)
        | otherwise = notinlined
      PairF inlineCost _ = AsDup.extractStack # x
      notinlined = C $ Cps.label x $ \x' -> case f (S x') of
        C y -> y

instance F.HasLet t => F.HasLet (CostInliner t) where
  letBe (C x) f = result
    where
      result
        | AsInlineCost.extract inlineCost <= inlineThreshold = f (C x)
        | otherwise = notinlined
      PairF inlineCost _ = AsDup.extract # x
      notinlined = C $ F.letBe x $ \x' -> case f (C x') of
        C y -> y

-- | Tagless final newtype to inline letBe clauses based on a simple
-- cost model
--
-- FIXME: for now all the node costs and inline thresholds are
-- arbitrary and will need tuning
--
-- FIXME: use an alternative to the probe function
data CostInliner t

instance HasData t => HasData (CostInliner t) where
  newtype Data (CostInliner t) a = D (Data (AsDup AsInlineCost t) a)

instance HasCode t => HasCode (CostInliner t) where
  newtype Code (CostInliner t) a = C {unC :: Code (AsDup AsInlineCost t) a}

instance HasStack t => HasStack (CostInliner t) where
  newtype Stack (CostInliner t) a = S (Stack (AsDup AsInlineCost t) a)

instance HasCall t => HasCall (CostInliner t) where
  call g = C (call g)

instance HasReturn t => HasReturn (CostInliner t) where
  letTo (C x) f = C $ letTo x $ \x' -> case f (D x') of
    C y -> y
  returns (D k) = C (returns k)

instance F.HasTuple t => F.HasTuple (CostInliner t) where
  pair (C x) (C y) = C (F.pair x y)
  unpair (C tuple) f = C $ F.unpair tuple $ \x y -> case f (C x) (C y) of
    C r -> r

instance F.HasFn t => F.HasFn (CostInliner t) where
  lambda t f = C $ F.lambda t (Path.make unC . f . Path.make C)
  C f <*> C x = C (f F.<*> x)

instance HasConstants t => HasConstants (CostInliner t) where
  constant k = D (constant k)

instance F.HasConstants t => F.HasConstants (CostInliner t) where
  constant k = C (F.constant k)

instance HasTuple t => HasTuple (CostInliner t) where
  pair (D x) (D y) = D (pair x y)
  unpair (D tuple) f = C $ unpair tuple $ \x y -> case f (D x) (D y) of
    C r -> r

instance HasFn t => HasFn (CostInliner t) where
  C f <*> D x = C (f <*> x)
  lambda t f = C $ lambda t $ \x' -> case f (D x') of
    C y -> y

instance HasThunk t => HasThunk (CostInliner t) where
  force (D th) = C (force th)
  thunk (C code) = D (thunk code)

instance Cps.HasThunk t => Cps.HasThunk (CostInliner t) where
  thunk t f = D $ Cps.thunk t $ \x' -> case f (S x') of
    C y -> y
  force (D th) (S stack) = C (Cps.force th stack)

instance Cps.HasFn t => Cps.HasFn (CostInliner t) where
  lambda (S k) f = C $ Cps.lambda k $ \x n -> case f (D x) (S n) of
    C y -> y
  D x <*> S k = S (x Cps.<*> k)

instance Cps.HasCall t => Cps.HasCall (CostInliner t) where
  call g = D (Cps.call g)

instance Cps.HasReturn t => Cps.HasReturn (CostInliner t) where
  letTo t f = S $ Cps.letTo t $ \x' -> case f (D x') of
    C y -> y
  returns (D c) (S stk) = C (Cps.returns c stk)
