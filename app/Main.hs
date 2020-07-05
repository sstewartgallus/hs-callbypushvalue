module Main where

import qualified Callcc
import qualified Cbpv
import Control.Monad.State
import qualified Cps
import qualified Data.Text as T
import Lib
import SystemF
import qualified SystemF
import TextShow
import Unique

iterTerm = 20

iterCbpv = 20

iterCallcc = 20

iterCps = 20

mkProgram :: SystemF.Term (F Integer)
mkProgram =
  SystemF.build $
    SystemF.apply
      ( SystemF.lambda int $ \x ->
          SystemF.apply (SystemF.apply (SystemF.global plus) x) x
      )
      (SystemF.constant (IntegerConstant 5))

phases ::
  Unique.Stream ->
  SystemF.Term a ->
  ( SystemF.Term a,
    Cbpv.Code a,
    Cbpv.Code a,
    Cbpv.Code a,
    Callcc.Code a,
    Callcc.Code a,
    Cps.Code a,
    Cps.Code a
  )
phases (Unique.Split a (Unique.Split b (Unique.Split c (Unique.Split d (Unique.Split e (Unique.Split f (Unique.Split k g))))))) term =
  let optTerm = optimizeTerm term
      cbpv = Cbpv.build (toCallByPushValue optTerm) k
      intrinsified = Cbpv.build (intrinsify cbpv) b
      optIntrinsified = optimizeCbpv c intrinsified
      catchThrow = toCallcc optIntrinsified d
      optCatchThrow = optimizeCallcc e catchThrow
      cps = Cps.build (toContinuationPassingStyle optCatchThrow) f
      optCps = optimizeCps g cps
   in (optTerm, cbpv, intrinsified, optIntrinsified, catchThrow, optCatchThrow, cps, optCps)

optimizeTerm :: SystemF.Term a -> SystemF.Term a
optimizeTerm = loop iterTerm
  where
    loop :: Int -> SystemF.Term a -> SystemF.Term a
    loop 0 term = term
    loop n term =
      let simplified = SystemF.build (SystemF.simplify term)
          inlined = SystemF.build (SystemF.inline simplified)
       in loop (n - 1) inlined

optimizeCbpv :: Unique.Stream -> Cbpv.Code a -> Cbpv.Code a
optimizeCbpv = loop iterCbpv
  where
    loop :: Int -> Unique.Stream -> Cbpv.Code a -> Cbpv.Code a
    loop 0 _ term = term
    loop n (Unique.Split left (Unique.Split right strm)) term =
      let simplified = Cbpv.simplify term
          inlined = Cbpv.build (Cbpv.inline simplified) right
       in loop (n - 1) strm inlined

optimizeCallcc :: Unique.Stream -> Callcc.Code a -> Callcc.Code a
optimizeCallcc = loop iterCallcc
  where
    loop :: Int -> Unique.Stream -> Callcc.Code a -> Callcc.Code a
    loop 0 _ term = term
    loop n (Unique.Split left (Unique.Split right strm)) term =
      let simplified = Callcc.simplify term
          inlined = Callcc.build (Callcc.inline simplified) right
       in loop (n - 1) strm inlined

optimizeCps :: Unique.Stream -> Cps.Code a -> Cps.Code a
optimizeCps = loop iterCps
  where
    loop :: Int -> Unique.Stream -> Cps.Code a -> Cps.Code a
    loop 0 _ term = term
    loop n (Unique.Split left (Unique.Split right strm)) term =
      let simplified = Cps.simplify term
          inlined = Cps.build (Cps.inline simplified) right
       in loop (n - 1) strm inlined

main :: IO ()
main = do
  stream <- Unique.streamIO
  let (left, right) = Unique.split stream
  let program = mkProgram

  putStrLn "Lambda Calculus:"
  printT program

  let (optTerm, cbpv, intrinsified, optIntrinsified, catchThrow, optCatchThrow, cps, optCps) = phases stream program

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

  Cps.evaluate optCps $ \result -> do
    printT result

  return ()
