{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module HasTuple (HasTuple (..)) where

import Common
import HasCode
import HasData

class (HasData t, HasCode t) => HasTuple t where
  pair :: DataRep t a -> DataRep t b -> DataRep t (a :*: b)
  unpair :: DataRep t (a :*: b) -> (DataRep t a -> DataRep t b -> CodeRep t c) -> CodeRep t c