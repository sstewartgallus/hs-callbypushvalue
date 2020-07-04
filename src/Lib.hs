{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeOperators #-}

module Lib
  ( fn,
    thunk,
    int,
    plus,
    Variable (..),
    Constant (..),
    Global (Global),
    Type (..),
    Stack (),
    F (),
    U (),
    (:->) (),
    inlineTerm,
    simplifyTerm,
    toCallByPushValue,
    toCallcc,
    toContinuationPassingStyle,
    intrinsify,
    simplifyCbpv,
    inlineCbpv,
    simplifyCallcc,
  )
where

import qualified Callcc
import qualified Cbpv
import Common
import Control.Monad.ST
import Control.Monad.State
import Core
import Cps
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Text as T
import Data.Typeable
import SystemF (Term (..))
import qualified SystemF
import TextShow
import Unique
import qualified VarMap
import VarMap (VarMap)

inlineTerm = SystemF.inline

simplifyTerm = SystemF.simplify

simplifyCbpv = Cbpv.simplify

inlineCbpv = Cbpv.inline

simplifyCallcc = Callcc.simplify

intrinsify = Cbpv.intrinsify

toCallByPushValue :: SystemF.Term a -> Cbpv.Code a
toCallByPushValue (VariableTerm x) = Cbpv.ForceCode (Cbpv.VariableData x)
toCallByPushValue (ConstantTerm x) = Cbpv.ReturnCode (Cbpv.ConstantData x)
toCallByPushValue (GlobalTerm x) = Cbpv.GlobalCode x
toCallByPushValue (LetTerm term binder body) =
  let term' = toCallByPushValue term
      body' = toCallByPushValue body
   in Cbpv.LetBeCode (Cbpv.ThunkData term') binder body'
toCallByPushValue (LambdaTerm binder body) =
  let body' = toCallByPushValue body
   in Cbpv.LambdaCode binder body'
toCallByPushValue (ApplyTerm f x) =
  let f' = toCallByPushValue f
      x' = toCallByPushValue x
   in Cbpv.ApplyCode f' (Cbpv.ThunkData x')

toCallcc :: Cbpv.Code a -> Unique.Stream -> Callcc.Code a
toCallcc x = Callcc.build $ toExplicitCatchThrow VarMap.empty x

data X a = X (Callcc.DataBuilder a)

toExplicitCatchThrow :: VarMap X -> Cbpv.Code a -> Callcc.CodeBuilder a
toExplicitCatchThrow _ (Cbpv.GlobalCode x) = Callcc.global x
toExplicitCatchThrow env (Cbpv.LambdaCode binder@(Variable t _) body) =
  Callcc.lambda t $ \x -> toExplicitCatchThrow (VarMap.insert binder (X x) env) body
toExplicitCatchThrow env ap@(Cbpv.ApplyCode f x) =
  let f' = toExplicitCatchThrow env f
      x' = toExplicitCatchThrowData env x
   in Callcc.letTo x' $ \val ->
        Callcc.apply f' val
toExplicitCatchThrow env (Cbpv.LetToCode action binder body) =
  let action' = toExplicitCatchThrow env action
   in Callcc.letTo action' $ \x ->
        toExplicitCatchThrow (VarMap.insert binder (X x) env) body
toExplicitCatchThrow env (Cbpv.LetBeCode value binder body) =
  let value' = toExplicitCatchThrowData env value
   in Callcc.letTo value' $ \x ->
        toExplicitCatchThrow (VarMap.insert binder (X x) env) body
toExplicitCatchThrow env (Cbpv.ReturnCode x) =
  toExplicitCatchThrowData env x
toExplicitCatchThrow env f@(Cbpv.ForceCode thunk) =
  let t = Cbpv.typeOf f
      thunk' = toExplicitCatchThrowData env thunk
   in Callcc.catch t $ \v ->
        Callcc.letTo thunk' $ \val ->
          Callcc.throw val (Callcc.returns v)

toExplicitCatchThrowData :: VarMap X -> Cbpv.Data a -> Callcc.CodeBuilder (F a)
toExplicitCatchThrowData _ (Cbpv.ConstantData x) = Callcc.returns (Callcc.constant x)
toExplicitCatchThrowData env (Cbpv.VariableData v) =
  let Just (X x) = VarMap.lookup v env
   in Callcc.returns x
toExplicitCatchThrowData env (Cbpv.ThunkData code) =
  let code' = toExplicitCatchThrow env code
      t = Cbpv.typeOf code
   in Callcc.catch (ApplyType returnsType (ApplyType stack (ApplyType returnsType (ApplyType stack t)))) $ \returner ->
        Callcc.letTo
          ( Callcc.catch (ApplyType returnsType (ApplyType stack t)) $ \label ->
              Callcc.throw returner (Callcc.returns label)
          )
          $ \binder ->
            (Callcc.throw binder code')

toContinuationPassingStyle :: Callcc.Code a -> Cps.CodeBuilder a
toContinuationPassingStyle = toCps' VarMap.empty

toCps' :: VarMap Y -> Callcc.Code a -> Cps.CodeBuilder a
toCps' _ (Callcc.GlobalCode x) = Cps.global x
toCps' env (Callcc.ReturnCode value) = Cps.returns (toCpsData env value)
toCps' env (Callcc.LambdaCode binder@(Variable t _) body) =
  Cps.lambda t $ \value ->
    let env' = VarMap.insert binder (Y value) env
     in toCps' env' body
toCps' env (Callcc.ApplyCode f x) =
  let f' = toCps' env f
   in Cps.apply f' (toCpsData env x)
toCps' env act =
  let x = Callcc.typeOf act
   in Cps.kont x $ \k ->
        toCps env act $ \a ->
          Cps.jump a k

toCps :: VarMap Y -> Callcc.Code a -> (Cps.CodeBuilder a -> Cps.CodeBuilder Nil) -> Cps.CodeBuilder Nil
toCps env (Callcc.ApplyCode f x) k =
  toCps env f $ \f' ->
    k $ Cps.apply f' (toCpsData env x)
toCps env (Callcc.LetBeCode value binder body) k =
  k $ Cps.letBe (toCpsData env value) $ \value ->
    let env' = VarMap.insert binder (Y value) env
     in toCps' env' body
toCps env (Callcc.ThrowCode val body) _ = do
  toCps env body $ \body' ->
    Cps.jump body' (toCpsData env val)
toCps env (Callcc.LetToCode action binder@(Variable t _) body) k =
  toCps env action $ \act ->
    Cps.letTo act $ \value ->
      let env' = VarMap.insert binder (Y value) env
       in toCps env' body k
toCps env (Callcc.CatchCode binder@(Variable (StackType t) _) body) k =
  k $ Cps.kont t $ \value ->
    let env' = VarMap.insert binder (Y value) env
     in toCps env' body id
toCps env act k =
  let val = toCps' env act
   in k $ val

newtype Y a = Y (DataBuilder a)

toCpsData :: VarMap Y -> Callcc.Data a -> Cps.DataBuilder a
toCpsData _ (Callcc.ConstantData x) = Cps.constant x
toCpsData env (Callcc.VariableData v) =
  let Just (Y x) = VarMap.lookup v env
   in x
