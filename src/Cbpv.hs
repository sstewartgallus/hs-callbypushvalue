{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeOperators #-}

module Cbpv (build, typeOf, CodeBuilder (..), DataBuilder (..), Code (..), Data (..), simplify, intrinsify, inline) where

import Common
import Core
import qualified Data.Text as T
import GlobalMap (GlobalMap)
import qualified GlobalMap as GlobalMap
import TextShow
import Unique
import VarMap (VarMap)
import qualified VarMap as VarMap

typeOf :: Code a -> Type a
typeOf (GlobalCode (Global t _ _)) = t
typeOf (ForceCode thunk) =
  let ThunkType x = typeOfData thunk
   in x
typeOf (ReturnCode value) = ApplyType returnsType (typeOfData value)
typeOf (LetToCode _ _ body) = typeOf body
typeOf (LetBeCode _ _ body) = typeOf body
typeOf (LambdaCode (Variable t _) body) = t -=> typeOf body
typeOf (ApplyCode f _) =
  let _ :=> result = typeOf f
   in result

typeOfData :: Data a -> Type a
typeOfData (VariableData (Variable t _)) = t
typeOfData (ConstantData (IntegerConstant _)) = intRaw
typeOfData (ThunkData code) = ApplyType thunk (typeOf code)

newtype CodeBuilder a = CodeBuilder {build :: Unique.Stream -> Code a}

newtype DataBuilder a = DataBuilder {buildData :: Unique.Stream -> Data a}

global :: Global a -> CodeBuilder a
global g = (CodeBuilder . const) $ GlobalCode g

force :: DataBuilder (U a) -> CodeBuilder a
force thunk = CodeBuilder $ \stream ->
  ForceCode (buildData thunk stream)

returns :: DataBuilder a -> CodeBuilder (F a)
returns value = CodeBuilder $ \stream ->
  ReturnCode (buildData value stream)

letTo :: CodeBuilder (F a) -> (DataBuilder a -> CodeBuilder b) -> CodeBuilder b
letTo x f = CodeBuilder $ \(Unique.Pick h (Unique.Split l r)) ->
  let x' = build x l
      ReturnsType t = typeOf x'
      v = Variable t h
      body = build (f ((DataBuilder . const) $ VariableData v)) r
   in LetToCode x' v body

letBe :: DataBuilder a -> (DataBuilder a -> CodeBuilder b) -> CodeBuilder b
letBe x f = CodeBuilder $ \(Unique.Pick h (Unique.Split l r)) ->
  let x' = buildData x l
      t = typeOfData x'
      v = Variable t h
      body = build (f ((DataBuilder . const) $ VariableData v)) r
   in LetBeCode x' v body

lambda :: Type a -> (DataBuilder a -> CodeBuilder b) -> CodeBuilder (a -> b)
lambda t f = CodeBuilder $ \(Unique.Pick h stream) ->
  let v = Variable t h
      body = build (f ((DataBuilder . const) $ VariableData v)) stream
   in LambdaCode v body

apply :: CodeBuilder (a -> b) -> DataBuilder a -> CodeBuilder b
apply f x = CodeBuilder $ \(Unique.Split l r) ->
  let f' = build f l
      x' = buildData x r
   in ApplyCode f' x'

constant :: Constant a -> DataBuilder a
constant k = (DataBuilder . const) $ ConstantData k

delay :: CodeBuilder a -> DataBuilder (U a)
delay code = DataBuilder $ \stream ->
  ThunkData (build code stream)

data Code a where
  GlobalCode :: Global a -> Code a
  LambdaCode :: Variable a -> Code b -> Code (a -> b)
  ApplyCode :: Code (a -> b) -> Data a -> Code b
  ForceCode :: Data (U a) -> Code a
  ReturnCode :: Data a -> Code (F a)
  LetToCode :: Code (F a) -> Variable a -> Code b -> Code b
  LetBeCode :: Data a -> Variable a -> Code b -> Code b

data Data a where
  VariableData :: Variable a -> Data a
  ConstantData :: Constant a -> Data a
  ThunkData :: Code a -> Data (U a)

data AnyCode where
  AnyCode :: Code a -> AnyCode

eqCode :: Code a -> Code b -> Bool
(GlobalCode g) `eqCode` (GlobalCode g') = AnyGlobal g == AnyGlobal g'
(LambdaCode binder body) `eqCode` (LambdaCode binder' body') = AnyVariable binder == AnyVariable binder' && body `eqCode` body'
(LetBeCode value binder body) `eqCode` (LetBeCode value' binder' body') = value `eqData` value' && AnyVariable binder' == AnyVariable binder' && body `eqCode` body'
(LetToCode act binder body) `eqCode` (LetToCode act' binder' body') = act `eqCode` act' && AnyVariable binder' == AnyVariable binder' && body `eqCode` body'
(ApplyCode f x) `eqCode` (ApplyCode f' x') = f `eqCode` f' && x `eqData` x'
(ForceCode x) `eqCode` (ForceCode x') = x `eqData` x'
(ReturnCode x) `eqCode` (ReturnCode x') = x `eqData` x'
_ `eqCode` _ = False

eqData :: Data a -> Data b -> Bool
(ConstantData k) `eqData` (ConstantData k') = AnyConstant k == AnyConstant k'
(VariableData v) `eqData` (VariableData v') = AnyVariable v == AnyVariable v'
(ThunkData code) `eqData` (ThunkData code') = code `eqCode` code'
_ `eqData` _ = False

instance Eq AnyCode where
  AnyCode x == AnyCode y = x `eqCode` y

instance Eq (Code a) where
  x == y = x `eqCode` y

data AnyData where
  AnyData :: Data a -> AnyData

instance Eq AnyData where
  AnyData x == AnyData y = x `eqData` y

instance Eq (Data a) where
  x == y = AnyData x == AnyData y

instance TextShow (Code a) where
  showb (GlobalCode g) = showb g
  showb (LambdaCode binder body) = fromString "λ " <> showb binder <> fromString " →\n" <> showb body
  showb (ApplyCode f x) = showb x <> fromString "\n" <> showb f
  showb (ForceCode thunk) = fromString "! " <> showb thunk
  showb (ReturnCode value) = fromString "return " <> showb value
  showb (LetToCode action binder body) = showb action <> fromString " to " <> showb binder <> fromString ".\n" <> showb body
  showb (LetBeCode value binder body) = showb value <> fromString " be " <> showb binder <> fromString ".\n" <> showb body

instance TextShow (Data a) where
  showb (VariableData v) = showb v
  showb (ConstantData k) = showb k
  showb (ThunkData code) = fromString "thunk {" <> fromText (T.replace (T.pack "\n") (T.pack "\n\t") (toText (fromString "\n" <> showb code))) <> fromString "\n}"

{-
Simplify Call By Push Data Inverses

So far we handle:

- force (thunk X) to X
- thunk (force X) to X
-}
simplify :: Code a -> Code a
simplify (ForceCode (ThunkData x)) = simplify x
simplify (ForceCode x) = ForceCode (simplifyData x)
simplify (ApplyCode (LambdaCode binder body) value) = simplify (LetBeCode value binder body)
simplify (LambdaCode binder body) =
  let body' = simplify body
   in LambdaCode binder body'
simplify (ApplyCode f x) = ApplyCode (simplify f) (simplifyData x)
simplify (ReturnCode value) = ReturnCode (simplifyData value)
simplify (LetBeCode value binder body) = LetBeCode (simplifyData value) binder (simplify body)
simplify (LetToCode action binder body) = LetToCode (simplify action) binder (simplify body)
simplify x = x

simplifyData :: Data a -> Data a
simplifyData (ThunkData (ForceCode x)) = simplifyData x
simplifyData (ThunkData x) = ThunkData (simplify x)
simplifyData x = x

count :: Variable a -> Code b -> Int
count v = code
  where
    code :: Code x -> Int
    code (LetBeCode x binder body) = value x + if AnyVariable binder == AnyVariable v then 0 else code body
    code (LetToCode action binder body) = code action + if AnyVariable binder == AnyVariable v then 0 else code body
    code (LambdaCode binder body) = if AnyVariable binder == AnyVariable v then 0 else code body
    code (ApplyCode f x) = code f + value x
    code (ForceCode thunk) = value thunk
    code (ReturnCode x) = value x
    code _ = 0
    value :: Data x -> Int
    value (VariableData binder) = if AnyVariable v == AnyVariable binder then 1 else 0
    value (ThunkData c) = code c
    value _ = 0

inline :: Code a -> Code a
inline = inline' VarMap.empty

inline' :: VarMap Data -> Code a -> Code a
inline' map = code
  where
    code :: Code x -> Code x
    code (LetBeCode term binder body) =
      if count binder body <= 1
        then inline' (VarMap.insert binder (value term) map) body
        else LetBeCode (value term) binder (inline' (VarMap.delete binder map) body)
    code (LetToCode term binder body) = LetToCode (code term) binder (inline' (VarMap.delete binder map) body)
    code (ApplyCode f x) = ApplyCode (code f) (value x)
    code (LambdaCode binder body) = LambdaCode binder (inline' (VarMap.delete binder map) body)
    code term = term
    value :: Data x -> Data x
    value v@(VariableData variable) = case VarMap.lookup variable map of
      Nothing -> v
      Just replacement -> replacement
    value (ThunkData c) = ThunkData (code c)
    value x = x

-- Fixme... use a different file for this?
intrinsify :: Code a -> CodeBuilder a
intrinsify code = intrins VarMap.empty code

newtype X a = X (DataBuilder a)

intrins :: VarMap X -> Code a -> CodeBuilder a
intrins env (GlobalCode g) = case GlobalMap.lookup g intrinsics of
  Nothing -> global g
  Just (Intrinsic intrinsic) -> intrinsic
intrins env (ApplyCode f x) = apply (intrins env f) (intrinsData env x)
intrins env (ForceCode x) = force (intrinsData env x)
intrins env (ReturnCode x) = returns (intrinsData env x)
intrins env (LambdaCode binder@(Variable t _) body) = lambda t $ \value ->
  let env' = VarMap.insert binder (X value) env
   in intrins env' body
intrins env (LetBeCode value binder body) = letBe (intrinsData env value) $ \value ->
  let env' = VarMap.insert binder (X value) env
   in intrins env' body
intrins env (LetToCode action binder body) = letTo (intrins env action) $ \value ->
  let env' = VarMap.insert binder (X value) env
   in intrins env' body

intrinsData :: VarMap X -> Data a -> DataBuilder a
intrinsData env (ThunkData code) = delay (intrins env code)
intrinsData env (VariableData binder) =
  let Just (X x) = VarMap.lookup binder env
   in x
intrinsData env (ConstantData x) = constant x

newtype Intrinsic a = Intrinsic (CodeBuilder a)

intrinsics :: GlobalMap Intrinsic
intrinsics =
  GlobalMap.fromList
    [ GlobalMap.Entry plus (Intrinsic plusIntrinsic)
    ]

plusIntrinsic :: CodeBuilder (F Integer :-> F Integer :-> F Integer)
plusIntrinsic =
  lambda (ApplyType thunk int) $ \x' ->
    lambda (ApplyType thunk int) $ \y' ->
      letTo (force x') $ \x'' ->
        letTo (force y') $ \y'' ->
          apply (apply (global strictPlus) x'') y''
