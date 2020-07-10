{-# LANGUAGE GADTs #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TypeOperators #-}

module Common (V, (:->), (:=>) (..), F (..), U (..), R (..), Stack (..)) where

data V a b

type a :-> b = U a :=> b

infixr 9 :->

newtype R = Behaviour (IO ())

newtype F a = Returns (a -> R)

infixr 9 :=>

data a :=> b = a ::: b

infixr 0 :::

newtype U a = Thunk (a -> R)

data Stack a
