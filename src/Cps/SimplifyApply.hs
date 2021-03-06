{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Cps.SimplifyApply (Simplifier, extract) where

import Common
import Cps
import HasCode
import HasConstants
import HasData
import HasLet
import HasStack
import HasTerminal
import HasTuple
import NatTrans
import Prelude hiding ((<*>))

extract :: Data (Simplifier t) :~> Data t
extract = NatTrans dout

data Simplifier t

data TermS t a where
  ApplyS :: Data t a -> Stack t b -> TermS t (a ~> b)
  NothingS :: TermS t a

cin :: Code t a -> Code (Simplifier t) a
cin = C

cout :: Code (Simplifier t) a -> Code t a
cout (C x) = x

din :: Data t a -> Data (Simplifier t) a
din = D

dout :: Data (Simplifier t) a -> Data t a
dout (D x) = x

kin :: Stack t a -> Stack (Simplifier t) a
kin = S NothingS

sout :: Stack (Simplifier t) a -> Stack t a
sout (S _ x) = x

instance HasCode t => HasCode (Simplifier t) where
  newtype Code (Simplifier t) a = C (Code t a)
  probeCode = cin . probeCode

instance HasData t => HasData (Simplifier t) where
  newtype Data (Simplifier t) a = D (Data t a)
  probeData = din . probeData

instance HasStack t => HasStack (Simplifier t) where
  data Stack (Simplifier t) a = S (TermS t a) (Stack t a)
  probeStack = kin . probeStack

instance HasConstants t => HasConstants (Simplifier t) where
  constant = din . constant

instance HasLet t => HasLet (Simplifier t) where
  whereIs f = cin . whereIs (cout . f . din) . dout

instance HasTerminal t => HasTerminal (Simplifier t) where
  terminal = din terminal

instance HasLabel t => HasLabel (Simplifier t) where
  whereLabel f = cin . whereLabel (cout . f . kin) . sout

instance HasTuple t => HasTuple (Simplifier t) where
  pair f g = din . pair (dout . f . din) (dout . g . din) . dout
  first = din . first . dout
  second = din . second . dout

instance HasThunk t => HasThunk (Simplifier t) where
  thunk t f = din $ thunk t (cout . f . kin)
  force x k = cin $ force (dout x) (sout k)

instance (HasLet t, HasReturn t) => HasReturn (Simplifier t) where
  returns x k = cin $ returns (dout x) (sout k)
  letTo t f = kin $ letTo t (cout . f . din)

instance (HasFn t, HasLet t, HasLabel t) => HasFn (Simplifier t) where
  D x <*> S _ k = S (ApplyS x k) (x <*> k)
  lambda (S (ApplyS x t) _) f = cin $ label t $ \t' ->
    letBe x $ \x' ->
      cout (f (din x') (kin t'))
  lambda (S _ k) f = cin $ lambda k $ \x t -> cout (f (din x) (kin t))

instance HasCall t => HasCall (Simplifier t) where
  call = din . call
