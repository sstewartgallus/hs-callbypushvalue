{-# LANGUAGE StrictData #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Porcelain (porcelain) where

import Common
import Const
import Constant
import Core
import qualified Cps
import Data.Text
import GlobalMap (GlobalMap)
import qualified GlobalMap
import TextShow
import qualified Unique

porcelain :: Cps.Data a -> Text
porcelain x = case Cps.abstract x of
  XD val -> toText (Unique.run val)

ws = fromString " "

lp = fromString "("

rp = fromString ")"

atom = fromString

node x = lp <> x <> rp

fresh = do
  v <- Unique.uniqueId
  pure $ fromString "v" <> showb v

pType :: SSet a -> Builder
pType = showb

pAction :: SAlg a -> Builder
pAction = showb

data X

instance Const X where
  newtype SetRep X a = XD (Unique.State Builder)
  constant (U64Constant x) = XD $ pure $ node $ atom "u64" <> ws <> showb x

instance Cps.Cps X where
  newtype CodeRep X = XC (Unique.State Builder)
  newtype StackRep X a = XS (Unique.State Builder)

  throw (XS k) (XD value) = XC $ do
    k' <- k
    value' <- value
    pure $ node $ atom "throw" <> ws <> k' <> ws <> value'
  force (XD thunk) (XS k) = XC $ do
    thunk' <- thunk
    k' <- k
    pure $ node $ atom "force" <> ws <> thunk' <> ws <> k'

  thunk t f = XD $ do
    v <- fresh
    let XC body = f (XS $ pure v)
    body' <- body
    pure $ node $ atom "thunk" <> ws <> v <> ws <> pAction t <> ws <> body'
  letTo t f = XS $ do
    v <- fresh
    let XC body = f (XD $ pure v)
    body' <- body
    pure $ node $ atom "to" <> ws <> v <> ws <> pType t <> ws <> body'

  lambda (XS k) f = XC $ do
    k' <- k
    x <- fresh
    t <- fresh
    let XC body = f (XD $ pure x) (XS $ pure t)
    body' <- body
    pure $ node $ atom "lambda" <> ws <> k' <> ws <> x <> ws <> t <> ws <> body'
  apply (XD h) (XS t) = XS $ do
    h' <- h
    t' <- t
    pure $ node $ atom "apply" <> ws <> h' <> ws <> t'

  nil = XS $ pure $ atom "nil"

  global g (XS k) = XC $ do
    k' <- k
    pure $ node $ atom "global" <> ws <> showb g <> ws <> k'
