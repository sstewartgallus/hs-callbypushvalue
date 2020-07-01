module Main where

import Lib
import Control.Monad.State
import TextShow
import qualified Data.Text as T
import Term (Term)
import qualified Term
import Unique

fixpoint :: (TextShow a, Eq a) => (a -> a) -> a -> a
fixpoint op = w 0 where
  w 5000 term = error ("term did not terminate:\n" <> toString (showb term))
  w tick term = let
    newTerm = op term
    in if newTerm == term then term else w (tick + 1) newTerm

mkProgram :: Unique.Stream -> Term (F Integer)
mkProgram = Term.build $ Term.ApplyBuild (Term.LambdaBuild (Type undefined) $ \x ->
          Term.ApplyBuild (Term.ApplyBuild (Term.GlobalBuild plus)  x) x) (Term.ConstantBuild (IntegerConstant 5))

optimizeCbpv = inlineCbpv . simplifyCbpv

phases :: Unique.Stream -> Term a -> (Term a, Code a, Code a, Code a, Code a, Action a, Action a, Stuff (Stack (F (Stack a))))
phases supply term = let
    optimizeTerm :: Unique.Stream -> Term a -> Term a
    optimizeTerm s t = let
      (left, right) = Unique.split s
      simplified = Term.build (Term.simplify t) left
      inlined = Term.build (Term.inline simplified) right
      -- fixme.. get fixpoint working
      in inlined
  in flip evalState (CompilerState 0 0) $ do

  let optTerm = optimizeTerm supply term

  cbpv <- toCallByPushValue optTerm

  let optCbpv = fixpoint optimizeCbpv cbpv
  intrinsified <- intrinsify optCbpv
  let optIntrinsified = fixpoint optimizeCbpv intrinsified

  catchThrow <- toExplicitCatchThrow intrinsified
  let optCatchThrow = fixpoint simplifyCallcc catchThrow

  cps <- toCps' catchThrow

  return (optTerm, cbpv, optCbpv, intrinsified, optIntrinsified, catchThrow, optCatchThrow, cps)

main :: IO ()
main = do
  stream <- Unique.streamIO
  let (left, right) = Unique.split stream
  let program = mkProgram left

  putStrLn "Lambda Calculus:"
  printT program

  let (optTerm, cbpv, optCbpv, intrinsified, optIntrinsified, catchThrow, optCatchThrow, cps) = phases stream program

  putStrLn "\nOptimized Term:"
  printT optTerm

  putStrLn "\nCall By Push Value:"
  printT cbpv

  putStrLn "\nOptimized CBPV:"
  printT optCbpv

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
