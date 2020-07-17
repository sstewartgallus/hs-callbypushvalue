{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}

module MonoInliner (extract, extractData, MonoInliner (..)) where

import qualified Callcc
import Cbpv
import Common
import qualified Cps
import qualified Data.Text as T
import Explicit
import Global
import HasCode
import HasConstants
import HasData
import HasGlobals
import HasLet
import HasLetLabel
import HasReturn
import HasStack
import qualified HasThunk
import HasTuple
import Name
import qualified SystemF
import TextShow
import qualified Unique
import Prelude hiding ((<*>))

data MonoInliner t

extract :: CodeRep (MonoInliner t) a -> CodeRep t a
extract (M _ x) = x

extractData :: DataRep (MonoInliner t) a -> DataRep t a
extractData (MS _ x) = x

instance HasCode t => HasCode (MonoInliner t) where
  data CodeRep (MonoInliner t) a = M Int (CodeRep t a)

instance HasData t => HasData (MonoInliner t) where
  data DataRep (MonoInliner t) a = MS Int (DataRep t a)

instance HasStack t => HasStack (MonoInliner t) where
  data StackRep (MonoInliner t) a = SB Int (StackRep t a)

instance HasGlobals t => HasGlobals (MonoInliner t) where
  global g = M 0 (global g)

instance HasConstants t => HasConstants (MonoInliner t) where
  constant k = MS 0 (constant k)
  unit = MS 0 unit

instance HasTuple t => HasTuple (MonoInliner t) where
  pair (MS xcost x) (MS ycost y) = MS (xcost + ycost) (pair x y)

instance HasLet t => HasLet (MonoInliner t) where
  letBe (MS xcost x) f = result
    where
      result
        | inlineCost <= 1 = inlined
        | otherwise = notinlined
      inlined@(M inlineCost _) = f (MS 1 x)
      notinlined = M (xcost + fcost) $ letBe x $ \x' -> case f (MS 0 x') of
        M _ y -> y
      M fcost _ = f (MS 0 x)

instance HasLetLabel t => HasLetLabel (MonoInliner t) where
  letLabel (SB xcost x) f = result
    where
      result
        | inlineCost <= 1 = inlined
        | otherwise = notinlined
      inlined@(M inlineCost _) = f (SB 1 x)
      notinlined = M (xcost + fcost) $ letLabel x $ \x' -> case f (SB 0 x') of
        M _ y -> y
      M fcost _ = f (SB 0 x)

instance Explicit t => Explicit (MonoInliner t) where
  letTo (M xcost x) f =
    let -- fixme... figure out a better probe...
        M fcost _ = f (MS 0 undefined)
     in M (xcost + fcost) $ letTo x $ \x' -> case f (MS 0 x') of
          M _ y -> y

  apply (M fcost f) (MS xcost x) = M (fcost + xcost) (apply f x)

instance Cbpv t => Cbpv (MonoInliner t) where
  lambda t f =
    let M fcost _ = f (MS 0 undefined)
     in M fcost $ lambda t $ \x' -> case f (MS 0 x') of
          M _ y -> y
  force (MS cost thunk) = M cost (force thunk)
  thunk (M cost code) = MS cost (thunk code)

instance HasThunk.HasThunk t => HasThunk.HasThunk (MonoInliner t) where
  lambda (SB kcost k) f =
    let M fcost _ = f (MS 0 undefined) (SB 0 undefined)
     in M (kcost + fcost) $ HasThunk.lambda k $ \x n -> case f (MS 0 x) (SB 0 n) of
          M _ y -> y
  thunk t f =
    let M fcost _ = f (SB 0 undefined)
     in MS fcost $ HasThunk.thunk t $ \x' -> case f (SB 0 x') of
          M _ y -> y
  force (MS tcost thunk) (SB scost stack) = M (tcost + scost) (HasThunk.force thunk stack)

  call g (SB kcost k) = M kcost (HasThunk.call g k)

instance Callcc.Callcc t => Callcc.Callcc (MonoInliner t) where
  catch t f =
    let M fcost _ = f (SB 0 undefined)
     in M fcost $ Callcc.catch t $ \x' -> case f (SB 0 x') of
          M _ y -> y
  throw (SB scost stack) (M xcost x) = M (scost + xcost) (Callcc.throw stack x)

instance Cps.Cps t => Cps.Cps (MonoInliner t) where
  letTo t f =
    let M fcost _ = f (MS 0 undefined)
     in SB fcost $ Cps.letTo t $ \x' -> case f (MS 0 x') of
          M _ y -> y

  throw (SB tcost stk) (MS scost c) = M (tcost + scost) (Cps.throw stk c)

  apply (MS xcost x) (SB kcost k) = SB (xcost + kcost) $ Cps.apply x k

instance HasReturn t => HasReturn (MonoInliner t) where
  returns (MS cost k) = M cost (returns k)

instance SystemF.SystemF t => SystemF.SystemF (MonoInliner t) where
  pair (M xcost x) (M ycost y) = M (xcost + ycost) (SystemF.pair x y)

  letBe (M xcost x) f = result
    where
      result
        | inlineCost <= 1 = inlined
        | otherwise = notinlined
      inlined@(M inlineCost _) = f (M 1 x)
      notinlined = M (xcost + fcost) $ SystemF.letBe x $ \x' -> case f (M 0 x') of
        M _ y -> y
      M fcost _ = f (M 0 x)

  lambda t f =
    let M fcost _ = f (M 0 (global (probe t)))
     in M fcost $ SystemF.lambda t $ \x' -> case f (M 0 x') of
          M _ y -> y
  M fcost f <*> M xcost x = M (fcost + xcost) (f SystemF.<*> x)

probe :: SAlgebra a -> Global a
probe t = Global t $ Name (T.pack "core") (T.pack "probe")
