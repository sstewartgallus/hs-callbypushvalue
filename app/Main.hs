{-# LANGUAGE TypeOperators #-}

module Main where

import AsCbpv (AsCbpv)
import qualified AsCbpv
import AsCompose ((:.:))
import qualified AsCompose
import AsCps (AsCps)
import qualified AsCps
import AsDup (AsDup)
import qualified AsDup
import AsIntrinsified (AsIntrinsified)
import qualified AsIntrinsified
import qualified AsPorcelain
import AsText
import Cbpv (Cbpv, HasThunk (..))
import qualified Cbpv.Simplify
import Common (FromType)
import qualified Constant
import Control.Category
import qualified Core
import Cps (Cps)
import qualified Cps.AsOptimized
import qualified Data.Text.IO as T
import Data.Word
import HasCode
import HasData
import HasTerm
import qualified Interpreter
import NatTrans
import PairF
import SystemF (SystemF)
import qualified SystemF as F
import qualified SystemF.AsOptimized
import SystemF.Type
import TextShow
import Prelude hiding (id, (.))

iterTerm :: Int
iterTerm = 20

iterCbpv :: Int
iterCbpv = 20

iterCps :: Int
iterCps = 20

program :: SystemF t => Term t (U64 ~> U64 ~> U64)
program = F.lam $ \_ ->
  F.lam $ \y ->
    ( F.lam $ \z ->
        F.call Core.plus F.<*> z F.<*> y
    )
      F.<*> (F.call Core.plus F.<*> F.constant (Constant.U64Constant 8) F.<*> y)

main :: IO ()
main = do
  copy <- dupLog program
  optTerm <- optimizeTerm copy
  cbpv <- cbpvTerm optTerm
  intrinsified <- intrinsify cbpv
  optCbpv <- optimizeCbpv intrinsified
  cps <- cpsTerm (Cbpv.thunk optCbpv)
  optCps <- optimizeCps cps

  let PairF porcelain interpreter = AsDup.extractData # optCps

  putStrLn "\nPorcelain Output:"
  T.putStrLn (AsPorcelain.extract porcelain)

  putStrLn "\nEvaluates to:"
  let cpsData = Interpreter.evaluate interpreter

  let Interpreter.Thunk k = cpsData
  let Interpreter.Behaviour eff = k (t 4 `Interpreter.Apply` t 8 `Interpreter.Apply` (Interpreter.Returns $ \(Interpreter.I x) -> Interpreter.Behaviour $ printT x))
  eff

  return ()

dupLog :: SystemF t => Term (AsDup AsText t) a -> IO (Term t a)
dupLog term = do
  let PairF text copy = AsDup.extractTerm # term

  putStrLn "Lambda Calculus:"
  T.putStrLn (AsText.extractTerm text)

  return copy

cbpvTerm :: Cbpv t => Term ((AsCbpv :.: AsDup AsText) t) a -> IO (Code t (FromType a))
cbpvTerm term = do
  let PairF text copy = AsDup.extract # (AsCbpv.extract (AsCompose.extractTerm # term))

  putStrLn "\nCall By Push Value:"
  T.putStrLn (AsText.extract text)

  return copy

intrinsify :: Cbpv t => Code ((AsIntrinsified :.: AsDup AsText) t) a -> IO (Code t a)
intrinsify term = do
  let PairF text copy = (AsDup.extract . AsIntrinsified.extract . AsCompose.extract) # term

  putStrLn "\nIntrinsified:"
  T.putStrLn (AsText.extract text)

  return copy

cpsTerm :: Cps t => Data ((AsCps :.: AsDup AsText) t) a -> IO (Data t a)
cpsTerm term = do
  let PairF text copy = (AsDup.extractData . AsCps.extract . AsCompose.extractData) # term

  putStrLn "\nContinuation Passing Style:"
  T.putStrLn (AsText.extractData text)

  return copy

-- fixme... loop
optimizeTerm :: SystemF t => Term (SystemF.AsOptimized.Simplifier (AsDup AsText t)) a -> IO (Term t a)
optimizeTerm input = do
  let PairF text copy = (AsDup.extractTerm . SystemF.AsOptimized.extract) # input
  putStrLn "\nOptimized Term:"
  T.putStrLn (AsText.extractTerm text)

  return copy

-- fixme... loop
optimizeCbpv :: Cbpv t => Code (Cbpv.Simplify.Simplifier (AsDup AsText t)) a -> IO (Code t a)
optimizeCbpv input = do
  let PairF text copy = (AsDup.extract . Cbpv.Simplify.extract) # input
  putStrLn "\nOptimized Call By Push Value:"
  T.putStrLn (AsText.extract text)

  return copy

optimizeCps :: Cps t => Data (Cps.AsOptimized.Simplifier (AsDup AsText t)) a -> IO (Data t a)
optimizeCps input = do
  let PairF text copy = (AsDup.extractData . Cps.AsOptimized.extract) # input
  putStrLn "\nOptimized Continuation Passing Style:"
  T.putStrLn (AsText.extractData text)

  return copy

-- t :: Word64 -> Interpreter.Value (U (F U64))
t x = Interpreter.Thunk $ \(Interpreter.Returns k) -> k (Interpreter.I x)
