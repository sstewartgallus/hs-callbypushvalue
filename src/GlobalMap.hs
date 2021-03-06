{-# LANGUAGE GADTs #-}
{-# LANGUAGE StrictData #-}

module GlobalMap where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Typeable
import Global
import Name (Name)
import SystemF.Type

data Dyn t = forall a. Dyn (SType a) (t a)

newtype GlobalMap t = GlobalMap (Map Name (Dyn t))

-- fixme... verify types ?
lookup :: Global a -> GlobalMap t -> Maybe (t a)
lookup (Global t name) (GlobalMap m) = case Map.lookup name m of
  Nothing -> Nothing
  Just (Dyn t' x) -> case equalType t t' of
    Just Refl -> Just x
    Nothing -> error "Global not equal in type to lookup"

insert :: Global a -> t a -> GlobalMap t -> GlobalMap t
insert (Global t name) value (GlobalMap m) = GlobalMap (Map.insert name (Dyn t value) m)

data Entry t = forall a. Entry (Global a) (t a)

fromList :: [Entry t] -> GlobalMap t
fromList entries = GlobalMap (Map.fromList (map entryToDyn entries))

entryToDyn :: Entry t -> (Name, Dyn t)
entryToDyn (Entry (Global t name) value) = (name, Dyn t value)
