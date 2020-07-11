{-# LANGUAGE GADTs #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TypeOperators #-}

module Common (V, (:->), (:*:) (..), (:=>) (..), Void (..), F (..), U (..), R (..)) where

data V a b

type a :-> b = U a :=> b

infixr 9 :->

data Void = Void

newtype R = Behaviour (IO ())

newtype F a = Returns (a -> R)

data a :=> b = a ::: b

infixr 0 :::

infixr 9 :=>

data a :*: b = Pair a b

infixr 0 :*:

newtype U a = Thunk (a -> R)
