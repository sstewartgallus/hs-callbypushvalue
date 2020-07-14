{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeOperators #-}

module Main where

import qualified Callcc
import qualified Cbpv
import Common
import qualified Constant
import Core
import qualified Cps
import Data.Data
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Interpreter
import Lib
import qualified Porcelain
import qualified SystemF as F
import TextShow
import Type

-- mkProgram :: (SystemF.SystemF t => Data a => t SystemF.Term a)
-- mkProgram = undefined

iterTerm = 20

iterCbpv = 20

iterCallcc = 20

iterCps = 20

mkProgram :: F.SystemF t => t (F Integer :-> F Integer :-> F Integer)
mkProgram =
  F.lambda (F IntType) $ \x ->
    F.lambda (F IntType) $ \y ->
      ( F.lambda (F IntType) $ \z ->
          F.global Core.plus F.<*> z F.<*> y
      )
        F.<*> x

phases ::
  F.Term a ->
  ( F.Term a,
    Cbpv.Code a,
    Cbpv.Code a,
    Cbpv.Code a,
    Callcc.Code a,
    Callcc.Code a,
    Cps.Data (U a),
    Cps.Data (U a)
  )
phases term =
  let optTerm = optimizeTerm term
      cbpv = Cbpv.build (toCallByPushValue optTerm)
      intrinsified = Cbpv.build (Cbpv.intrinsify cbpv)
      optIntrinsified = optimizeCbpv intrinsified
      catchThrow = toCallcc optIntrinsified
      optCatchThrow = optimizeCallcc catchThrow
      cps = Cps.build (toContinuationPassingStyle optCatchThrow)
      optCps = optimizeCps cps
   in (optTerm, cbpv, intrinsified, optIntrinsified, catchThrow, optCatchThrow, cps, optCps)

optimizeTerm :: F.Term a -> F.Term a
optimizeTerm = loop iterTerm
  where
    loop :: Int -> F.Term a -> F.Term a
    loop 0 term = term
    loop n term =
      let simplified = F.build (F.simplify term)
          inlined = F.build (F.inline simplified)
       in loop (n - 1) inlined

optimizeCbpv :: Cbpv.Code a -> Cbpv.Code a
optimizeCbpv = loop iterCbpv
  where
    loop :: Int -> Cbpv.Code a -> Cbpv.Code a
    loop 0 term = term
    loop n term =
      let simplified = Cbpv.simplify term
          inlined = Cbpv.build (Cbpv.inline simplified)
       in loop (n - 1) inlined

optimizeCallcc :: Callcc.Code a -> Callcc.Code a
optimizeCallcc = loop iterCallcc
  where
    loop :: Int -> Callcc.Code a -> Callcc.Code a
    loop 0 term = term
    loop n term =
      let simplified = Callcc.simplify term
          inlined = Callcc.build (Callcc.inline simplified)
       in loop (n - 1) inlined

optimizeCps :: Cps.Data a -> Cps.Data a
optimizeCps = loop iterCps
  where
    loop :: Int -> Cps.Data a -> Cps.Data a
    loop 0 term = term
    loop n term =
      let simplified = Cps.simplify term
          inlined = Cps.build (Cps.inline simplified)
       in loop (n - 1) inlined

main :: IO ()
main = do
  let program = F.build $ mkProgram

  putStrLn "Lambda Calculus:"
  printT program

  let (optTerm, cbpv, intrinsified, optIntrinsified, catchThrow, optCatchThrow, cps, optCps) = phases program

  putStrLn "\nOptimized Term:"
  printT optTerm

  putStrLn "\nCall By Push Value:"
  printT cbpv

  putStrLn "\nIntrinsified:"
  printT intrinsified

  putStrLn "\nOptimized Intrinsified:"
  printT optIntrinsified

  putStrLn "\nCatch/Throw:"
  printT catchThrow

  putStrLn "\nOptimized Catch/Throw:"
  printT optCatchThrow

  putStrLn "\nCps:"
  printT cps

  putStrLn "\nOptimized Cps:"
  printT optCps

  putStrLn "\nPorcelain Output:"
  T.putStrLn (Porcelain.porcelain optCps)

  putStrLn "\nEvaluates to:"
  let cpsData = Interpreter.evaluate optCps

  let Interpreter.Thunk k = cpsData
  let Interpreter.Behaviour eff = k (t 4 `Interpreter.Apply` t 8 `Interpreter.Apply` (Interpreter.Returns $ \(Interpreter.I x) -> Interpreter.Behaviour $ printT x))
  eff

  return ()

t :: Integer -> Interpreter.Value (U (F Integer))
t x = Interpreter.Thunk $ \(Interpreter.Returns k) -> k (Interpreter.I x)
