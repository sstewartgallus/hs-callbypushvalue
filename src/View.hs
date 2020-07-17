{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}

module View (extract, View (..)) where

import qualified Callcc
import qualified Cbpv
import Common
import qualified Data.Text as T
import Explicit
import HasCode
import HasConstants
import HasData
import HasGlobals
import qualified Pure
import qualified SystemF
import TextShow
import Tuple
import qualified Unique

data View

extract :: AlgRep View a -> T.Text
extract (V x) = toText (Unique.withStream x)

instance HasData View where
  newtype SetRep View a = VS (forall s. Unique.Stream s -> Builder)

instance HasCode View where
  newtype AlgRep View a = V (forall s. Unique.Stream s -> Builder)

instance HasGlobals View where
  global g = V $ \_ -> showb g

instance HasConstants View where
  constant k = VS $ \_ -> showb k
  unit = VS $ \_ -> fromString "."

instance Tuple View

instance Pure.Pure View where
  pure (VS k) = V $ \s ->
    fromString "(pure " <> k s <> fromString ")"

instance SystemF.SystemF View where
  pair (V x) (V y) = V $ \(Unique.Stream _ xs ys) ->
    let x' = x xs
        y' = y ys
     in fromString "(" <> x' <> fromString ", " <> y' <> fromString ")"

  letBe (V x) f = V $ \(Unique.Stream newId xs ys) ->
    let binder = fromString "v" <> showb newId
        V y = f (V $ \_ -> binder)
     in x xs <> fromString " be " <> binder <> fromString ".\n" <> y ys

  lambda t f = V $ \(Unique.Stream newId _ ys) ->
    let binder = fromString "v" <> showb newId
        V y = f (V $ \_ -> binder)
     in fromString "λ " <> binder <> fromString ".\n" <> y ys

  V f <*> V x = V $ \(Unique.Stream _ fs xs) ->
    fromString "(" <> f fs <> fromString " " <> x xs <> fromString ")"

instance Explicit View where
  letTo (V x) f = V $ \(Unique.Stream newId xs ys) ->
    let binder = fromString "v" <> showb newId
        V y = f (VS $ \_ -> binder)
     in x xs <> fromString " to " <> binder <> fromString ".\n" <> y ys
  letBe (VS x) f = V $ \(Unique.Stream newId xs ys) ->
    let binder = fromString "v" <> showb newId
        V y = f (VS $ \_ -> binder)
     in x xs <> fromString " be " <> binder <> fromString ".\n" <> y ys

  lambda t f = V $ \(Unique.Stream newId _ s) ->
    let binder = fromString "v" <> showb newId
        V body = f (VS $ \_ -> binder)
     in fromString "λ " <> binder <> fromString ": " <> showb t <> fromString " →\n" <> body s
  apply (V f) (VS x) = V $ \(Unique.Stream _ fs xs) -> x xs <> fromString "\n" <> f fs

instance Cbpv.Cbpv View where
  thunk (V code) = VS $ \s -> fromString "thunk {" <> fromText (T.replace (T.pack "\n") (T.pack "\n\t") (toText (fromString "\n" <> code s))) <> fromString "\n}"
  force (VS thunk) = V $ \s -> fromString "! " <> thunk s

instance Callcc.Callcc View where
  data StackRep View a = VStk (forall s. Unique.Stream s -> TextShow.Builder)

  catch t f = V $ \(Unique.Stream newId _ s) ->
    let binder = fromString "l" <> showb newId
        V body = f (VStk $ \_ -> binder)
     in fromString "catch " <> binder <> fromString ": " <> showb t <> fromString " →\n" <> body s
  thunk t f = VS $ \(Unique.Stream newId _ s) ->
    let binder = fromString "l" <> showb newId
        V body = f (VStk $ \_ -> binder)
     in fromString "thunk " <> binder <> fromString ": " <> showb t <> fromString " →\n" <> body s

  throw (VStk f) (V x) = V $ \(Unique.Stream _ fs xs) -> x xs <> fromString "\nthrow " <> f fs
  force (VS f) (VStk x) = V $ \(Unique.Stream _ fs xs) -> x xs <> fromString "\n! " <> f fs
