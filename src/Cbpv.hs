{-# LANGUAGE GADTs, TypeOperators #-}
module Cbpv (Code (..), Value (..), simplify, intrinsify, inline) where
import Common
import TextShow
import Data.Typeable
import qualified Data.Text as T
import Compiler
import Core
import GlobalMap (GlobalMap)
import qualified GlobalMap as GlobalMap
import VarMap (VarMap)
import qualified VarMap as VarMap

data Code a where
  GlobalCode :: Global a -> Code a
  LambdaCode :: Variable a -> Code b -> Code (a -> b)
  ApplyCode :: Code (a -> b) -> Value a -> Code b
  ForceCode :: Value (U a) -> Code a
  ReturnCode :: Value a -> Code (F a)
  LetToCode :: Code (F a) -> Variable a -> Code b -> Code b
  LetBeCode :: Value a -> Variable a -> Code b -> Code b

data Value a where
  VariableValue :: Variable a -> Value a
  ConstantValue :: Constant a -> Value a
  ThunkValue ::  Code a -> Value (U a)

data AnyCode where
  AnyCode :: Code a -> AnyCode

instance Eq AnyCode where
  AnyCode (GlobalCode g) == AnyCode (GlobalCode g') = AnyGlobal g == AnyGlobal g'
  AnyCode (LambdaCode binder body) == AnyCode (LambdaCode binder' body') = AnyVariable binder == AnyVariable binder' && AnyCode body == AnyCode body'
  AnyCode (LetBeCode value binder body) == AnyCode (LetBeCode value' binder' body') = AnyValue value == AnyValue value' && AnyVariable binder' == AnyVariable binder' && AnyCode body == AnyCode body'
  AnyCode (LetToCode act binder body) == AnyCode (LetToCode act' binder' body') = AnyCode act == AnyCode act' && AnyVariable binder' == AnyVariable binder' && AnyCode body == AnyCode body'
  AnyCode (ApplyCode f x) == AnyCode (ApplyCode f' x') = AnyCode f == AnyCode f' && AnyValue x == AnyValue x'
  AnyCode (ForceCode x) == AnyCode (ForceCode x') = AnyValue x == AnyValue x'
  AnyCode (ReturnCode x) == AnyCode (ReturnCode x') = AnyValue x == AnyValue x'
  _ == _ = False

instance Eq (Code a) where
  x == y = AnyCode x == AnyCode y

data AnyValue where
  AnyValue :: Value a -> AnyValue

instance Eq AnyValue where
  AnyValue (ConstantValue k) == AnyValue (ConstantValue k') = AnyConstant k == AnyConstant k'
  AnyValue (VariableValue v) == AnyValue (VariableValue v') = AnyVariable v == AnyVariable v'
  AnyValue (ThunkValue code) == AnyValue (ThunkValue code') = AnyCode code == AnyCode code'
  _ == _ = False

instance Eq (Value a) where
  x == y = AnyValue x == AnyValue y

instance TextShow (Code a) where
  showb (GlobalCode g) = showb g
  showb (LambdaCode binder body) = fromString "λ " <> showb binder <> fromString " →\n" <> showb body
  showb (ApplyCode f x) = showb x <> fromString "\n" <> showb f
  showb (ForceCode thunk) = fromString "! " <> showb thunk
  showb (ReturnCode value) = fromString "return " <> showb value
  showb (LetToCode action binder body) = showb action <> fromString " to " <> showb binder <> fromString ".\n" <> showb body
  showb (LetBeCode value binder body) = showb value <> fromString " be " <> showb binder <> fromString ".\n" <> showb body

instance TextShow (Value a) where
  showb (VariableValue v) = showb v
  showb (ConstantValue k) = showb k
  showb (ThunkValue code) = fromString "thunk {" <> fromText (T.replace (T.pack "\n") (T.pack "\n\t") (toText (fromString "\n" <> showb code))) <> fromString "\n}"

{-
Simplify Call By Push Value Inverses

So far we handle:

- force (thunk X) to X
- thunk (force X) to X
-}
simplify :: Code a -> Code a
simplify (ForceCode (ThunkValue x)) = simplify x
simplify (ForceCode x) = ForceCode (simplifyValue x)
simplify (ApplyCode (LambdaCode binder body) value) = simplify (LetBeCode value binder body)
simplify (LambdaCode binder body) = let
  body' = simplify body
  in LambdaCode binder body'
simplify (ApplyCode f x) = ApplyCode (simplify f) (simplifyValue x)
simplify (ReturnCode value) = ReturnCode (simplifyValue value)
simplify (LetBeCode value binder body) = LetBeCode (simplifyValue value) binder (simplify body)
simplify (LetToCode action binder body) = LetToCode (simplify action) binder (simplify body)
simplify x = x

simplifyValue :: Value a -> Value a
simplifyValue (ThunkValue (ForceCode x)) = simplifyValue x
simplifyValue (ThunkValue x) = ThunkValue (simplify x)
simplifyValue x = x


count :: Variable a -> Code b -> Int
count v = code where
  code :: Code x -> Int
  code (LetBeCode x binder body) = value x + if AnyVariable binder == AnyVariable v then 0 else code body
  code (LetToCode action binder body) = code action + if AnyVariable binder == AnyVariable v then 0 else code body
  code (LambdaCode binder body) = if AnyVariable binder == AnyVariable v then 0 else code body
  code (ApplyCode f x) = code f + value x
  code (ForceCode thunk) = value thunk
  code (ReturnCode x) = value x
  code _ = 0

  value :: Value x -> Int
  value (VariableValue binder) = if AnyVariable v == AnyVariable binder then 1 else 0
  value (ThunkValue c) = code c
  value _ = 0

inline :: Code a -> Code a
inline = inline' VarMap.empty

inline' :: VarMap Value -> Code a -> Code a
inline' map = code where
  code :: Code x -> Code x
  code (LetBeCode term binder body) = if count binder body <= 1
    then inline' (VarMap.insert binder (value term) map) body
    else LetBeCode (value term) binder (inline' (VarMap.delete binder map) body)
  code (LetToCode term binder body) = LetToCode (code term) binder (inline' (VarMap.delete binder map) body)
  code (ApplyCode f x) = ApplyCode (code f) (value x)
  code (LambdaCode binder body) = LambdaCode binder (inline' (VarMap.delete binder map) body)
  code term = term

  value :: Value x -> Value x
  value v@(VariableValue variable) = case VarMap.lookup variable map of
    Nothing -> v
    Just replacement -> replacement
  value (ThunkValue c) = ThunkValue (code c)
  value x = x



-- Fixme... use a different file for this?

intrinsify :: Code a -> Compiler (Code a)
intrinsify global@(GlobalCode g) = case GlobalMap.lookup g intrinsics of
  Nothing -> pure global
  Just (Intrinsic intrinsic) -> intrinsic
intrinsify (LambdaCode binder x) = pure (LambdaCode binder) <*> intrinsify x
intrinsify (ApplyCode f x) = pure ApplyCode <*> intrinsify f <*> intrinsifyValue x
intrinsify (ForceCode x) = pure ForceCode <*> intrinsifyValue x
intrinsify (ReturnCode x) = pure ReturnCode <*> intrinsifyValue x
intrinsify (LetBeCode value binder body) = pure LetBeCode <*> intrinsifyValue value <*> pure binder <*> intrinsify body
intrinsify (LetToCode action binder body) = pure LetToCode <*> intrinsify action <*> pure binder <*> intrinsify body

intrinsifyValue :: Value a -> Compiler (Value a)
intrinsifyValue (ThunkValue code) = pure ThunkValue <*> intrinsify code
intrinsifyValue x = pure x

newtype Intrinsic a = Intrinsic (Compiler (Code a))

intrinsics :: GlobalMap Intrinsic
intrinsics = GlobalMap.fromList [
     GlobalMap.Entry plus (Intrinsic plusIntrinsic)
  ]

plusIntrinsic :: Compiler (Code (F Integer :-> F Integer :-> F Integer))
plusIntrinsic = do
  let Type int' = int
  let Type thunk' = thunk
  x' <- getVariable (Type (ApplyName thunk' int'))
  y' <- getVariable (Type (ApplyName thunk' int'))
  x'' <- getVariable intRaw
  y'' <- getVariable intRaw
  pure $
    LambdaCode x' $
    LambdaCode y' $
    LetToCode (ForceCode (VariableValue x')) x'' $
    LetToCode (ForceCode (VariableValue y')) y'' $
    ApplyCode (ApplyCode (GlobalCode strictPlus) (VariableValue x'')) (VariableValue y'')
