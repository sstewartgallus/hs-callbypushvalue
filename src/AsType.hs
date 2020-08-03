{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module AsType (extract, extractData, AsType) where

import Cbpv
import Common
import qualified Constant
import qualified Cps
import Global
import HasCall
import HasCode
import HasConstants
import HasData
import HasLet
import HasStack
import HasTuple
import NatTrans

extract :: Code AsType :~> SAlgebra
extract = NatTrans $ \(C x) -> x

extractData :: Data AsType :~> SSet
extractData = NatTrans $ \(D x) -> x

data AsType

instance HasCode AsType where
  newtype Code AsType a = C {unC :: SAlgebra a}

instance HasData AsType where
  newtype Data AsType a = D {unD :: SSet a}

instance HasConstants AsType where
  constant = D . Constant.typeOf

instance HasLet AsType where
  whereIs = id

instance HasReturn AsType where
  returns = C . SF . unD
  from f (C (SF t)) = f (D t)

instance HasTuple AsType where
  pair (D tx) (D ty) = D (SPair tx ty)
  ofPair f (D (SPair tx ty)) = f (D tx) (D ty)

instance HasThunk AsType where
  force (D (SU t)) = C t
  thunk (C t) = D (SU t)

instance HasFn AsType where
  C (_ `SFn` b) <*> D x = C b
  lambda t f =
    let C bt = f (D t)
     in C (t `SFn` bt)

instance HasCall AsType where
  call g@(Global t _) = C t
