{-# LANGUAGE GADTs #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TypeOperators #-}

module SystemF (simplify, inline, build, Builder, SystemF (..), minus, plus, abstract, Term (..)) where

import Common
import Constant (Constant)
import qualified Constant
import Core hiding (minus, plus)
import qualified Core
import Global
import Kind
import Label
import LabelMap (LabelMap)
import qualified LabelMap
import TextShow (TextShow, fromString, showb)
import Type
import TypeMap (TypeMap)
import qualified TypeMap
import TypeVariable
import qualified Unique

class SystemF t where
  constant :: Constant a -> t (F a)

  global :: Global a -> t a

  lambda :: Action a -> (t a -> t b) -> t (a :-> b)
  apply :: t (a :-> b) -> t a -> t b
  letBe :: t a -> (t a -> t b) -> t b

  pair :: t a -> t b -> t (Pair a b)
  first :: t (Pair a b) -> t a
  second :: t (Pair a b) -> t b

  forall :: Kind a -> (Type a -> t b) -> t (V a b)
  applyType :: t (V a b) -> Type a -> t b

plus :: SystemF t => t (F Integer) -> t (F Integer) -> t (F Integer)
plus x y = apply (apply (global Core.plus) x) y

minus :: SystemF t => t (F Integer) -> t (F Integer) -> t (F Integer)
minus x y = apply (apply (global Core.minus) x) y

newtype Builder a = Builder {builder :: Unique.State (Term a)}

build :: Builder a -> Term a
build (Builder s) = Unique.run s

instance SystemF Builder where
  constant k = (Builder . pure) $ ConstantTerm k
  global g = (Builder . pure) $ GlobalTerm g
  pair x y =
    Builder $
      pure PairTerm <*> builder x <*> builder y
  first tuple =
    Builder $
      pure FirstTerm <*> builder tuple
  second tuple =
    Builder $
      pure SecondTerm <*> builder tuple
  letBe value f = Builder $ do
    value' <- builder value
    let t = typeOf value'
    binder <- pure (Label t) <*> Unique.uniqueId
    body <- builder $ f (Builder $ pure $ LabelTerm binder)
    pure (LetTerm value' binder body)
  lambda t f = Builder $ do
    binder <- pure (Label t) <*> Unique.uniqueId
    body <- builder $ f (Builder $ pure $ LabelTerm binder)
    pure (LambdaTerm binder body)
  forall t f = Builder $ do
    binder <- pure (TypeVariable t) <*> Unique.uniqueId
    body <- builder $ f (VariableType binder)
    pure (ForallTerm binder body)
  apply f x =
    Builder $
      pure ApplyTerm <*> builder f <*> builder x
  applyType f x = Builder $ do
    f' <- builder f
    pure (ApplyTypeTerm f' x)

data Term a where
  LabelTerm :: Label a -> Term a
  ConstantTerm :: Constant a -> Term (F a)
  GlobalTerm :: Global a -> Term a
  LetTerm :: Term a -> Label a -> Term b -> Term b
  LambdaTerm :: Label a -> Term b -> Term (a :-> b)
  ForallTerm :: TypeVariable a -> Term b -> Term (V a b)
  PairTerm :: Term a -> Term b -> Term (Pair a b)
  FirstTerm :: Term (Pair a b) -> Term a
  SecondTerm :: Term (Pair a b) -> Term b
  ApplyTerm :: Term (a :-> b) -> Term a -> Term b
  ApplyTypeTerm :: Term (V a b) -> Type a -> Term b

abstract :: SystemF t => Term a -> t a
abstract = abstract' TypeMap.empty LabelMap.empty

abstract' :: SystemF t => TypeMap Type -> LabelMap t -> Term a -> t a
abstract' tenv env (PairTerm x y) = pair (abstract' tenv env x) (abstract' tenv env y)
abstract' tenv env (FirstTerm tuple) = first (abstract' tenv env tuple)
abstract' tenv env (SecondTerm tuple) = second (abstract' tenv env tuple)
abstract' tenv env (LetTerm term binder body) =
  let term' = abstract' tenv env term
   in letBe term' $ \value -> abstract' tenv (LabelMap.insert binder value env) body
abstract' tenv env (LambdaTerm binder@(Label t _) body) = lambda t $ \value ->
  abstract' tenv (LabelMap.insert binder value env) body
abstract' tenv env (ApplyTerm f x) = apply (abstract' tenv env f) (abstract' tenv env x)
abstract' _ _ (ConstantTerm c) = constant c
abstract' _ _ (GlobalTerm g) = global g
abstract' tenv env (ForallTerm binder@(TypeVariable k _) body) = forall k $ \t ->
  abstract' (TypeMap.insert binder t tenv) env body
abstract' tenv env (ApplyTypeTerm f x) = SystemF.applyType (abstract' tenv env f) x
abstract' _ env (LabelTerm v) = case LabelMap.lookup v env of
  Just x -> x
  Nothing -> error "variable not found in env"

newtype TypeOf a = TypeOf (Action a)

instance SystemF TypeOf where
  constant k = TypeOf $ F (Constant.typeOf k)
  global (Global t _) = TypeOf t
  pair (TypeOf x) (TypeOf y) =
    TypeOf $
      F (U x :*: U y :*: UnitType)
  first (TypeOf (F (U x :*: U _ :*: UnitType))) = TypeOf x
  second (TypeOf (F (U _ :*: U y :*: UnitType))) = TypeOf y
  letBe x f = f x
  lambda t f =
    let TypeOf result = f (TypeOf t)
     in TypeOf (U t :=> result)
  apply (TypeOf (_ :=> b)) _ = TypeOf b

typeOf :: Term a -> Action a
typeOf term =
  let TypeOf t = abstract term
   in t

instance TextShow (Term a) where
  showb (LabelTerm v) = showb v
  showb (ConstantTerm k) = showb k
  showb (GlobalTerm g) = showb g
  showb (PairTerm x y) = fromString "(" <> showb x <> fromString ", " <> showb y <> fromString ")"
  showb (FirstTerm tuple) = showb tuple <> fromString ".1"
  showb (SecondTerm tuple) = showb tuple <> fromString ".2"
  showb (LetTerm term binder body) = showb term <> fromString " be " <> showb binder <> fromString ".\n" <> showb body
  showb (LambdaTerm binder@(Label t _) body) = fromString "λ " <> showb binder <> fromString ": " <> showb t <> fromString " →\n" <> showb body
  showb (ApplyTerm f x) = fromString "(" <> showb f <> fromString " " <> showb x <> fromString ")"
  showb (ForallTerm binder@(TypeVariable t _) body) = fromString "∀ " <> showb binder <> fromString ": " <> showb t <> fromString " →\n" <> showb body
  showb (ApplyTypeTerm f x) = fromString "(" <> showb f <> fromString " " <> showb x <> fromString ")"

simplify :: SystemF t => Term a -> t a
simplify = simp TypeMap.empty LabelMap.empty

simp :: SystemF t => TypeMap Type -> LabelMap t -> Term a -> t a
simp tenv env (PairTerm x y) = pair (simp tenv env x) (simp tenv env y)
simp tenv env (FirstTerm tuple) = first (simp tenv env tuple)
simp tenv env (SecondTerm tuple) = second (simp tenv env tuple)
simp tenv env (ApplyTerm (LambdaTerm binder body) term) =
  let term' = simp tenv env term
   in letBe term' $ \value -> simp tenv (LabelMap.insert binder value env) body
simp tenv env (LetTerm term binder body) =
  let term' = simp tenv env term
   in letBe term' $ \value -> simp tenv (LabelMap.insert binder value env) body
simp tenv env (LambdaTerm binder@(Label t _) body) = lambda t $ \value ->
  simp tenv (LabelMap.insert binder value env) body
simp tenv env (ApplyTerm f x) = apply (simp tenv env f) (simp tenv env x)
simp _ _ (ConstantTerm c) = constant c
simp _ _ (GlobalTerm g) = global g
simp tenv env (ForallTerm binder@(TypeVariable k _) body) = forall k $ \t ->
  simp (TypeMap.insert binder t tenv) env body
simp tenv env (ApplyTypeTerm f x) = SystemF.applyType (simp tenv env f) x
simp _ env (LabelTerm v) = case LabelMap.lookup v env of
  Just x -> x
  Nothing -> error "variable not found in env"

count :: Label a -> Term b -> Int
count v = w
  where
    w :: Term x -> Int
    w (LabelTerm binder) = if AnyLabel v == AnyLabel binder then 1 else 0
    w (LetTerm term binder body) = w term + w body
    w (LambdaTerm binder body) = w body
    w (ApplyTerm f x) = w f + w x
    w (PairTerm x y) = w x + w y
    w (FirstTerm tuple) = w tuple
    w (SecondTerm tuple) = w tuple
    w _ = 0

inline :: SystemF t => Term a -> t a
inline = inl TypeMap.empty LabelMap.empty

data X t a where
  X :: t a -> X t (U a)

inl :: SystemF t => TypeMap Type -> LabelMap t -> Term a -> t a
inl tenv env (PairTerm x y) = pair (inl tenv env x) (inl tenv env y)
inl tenv env (FirstTerm tuple) = first (inl tenv env tuple)
inl tenv env (SecondTerm tuple) = second (inl tenv env tuple)
inl tenv env (LetTerm term binder body) =
  let term' = inl tenv env term
   in if count binder body <= 1 || isSimple term
        then inl tenv (LabelMap.insert binder term' env) body
        else letBe term' $ \value ->
          inl tenv (LabelMap.insert binder value env) body
inl _ env (LabelTerm v) = case LabelMap.lookup v env of
  Just x -> x
  Nothing -> error "variable not found in env"
inl tenv env (ApplyTerm f x) = inl tenv env f `apply` inl tenv env x
inl tenv env (LambdaTerm binder@(Label t _) body) = lambda t $ \value ->
  inl tenv (LabelMap.insert binder value env) body
inl _ _ (ConstantTerm c) = constant c
inl _ _ (GlobalTerm g) = global g
inl tenv env (ApplyTypeTerm f x) = inl tenv env f `SystemF.applyType` x
inl tenv env (ForallTerm binder@(TypeVariable t _) body) = forall t $ \value ->
  inl (TypeMap.insert binder value tenv) env body

isSimple :: Term a -> Bool
isSimple (ConstantTerm _) = True
isSimple _ = False
