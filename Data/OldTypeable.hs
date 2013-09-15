{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE CPP
           , NoImplicitPrelude
           , OverlappingInstances
           , ScopedTypeVariables
           , ForeignFunctionInterface
           , FlexibleInstances
  #-}
{-# OPTIONS_GHC -funbox-strict-fields -fno-warn-warnings-deprecations #-}

-- The -XOverlappingInstances flag allows the user to over-ride
-- the instances for Typeable given here.  In particular, we provide an instance
--      instance ... => Typeable (s a) 
-- But a user might want to say
--      instance ... => Typeable (MyType a b)

-----------------------------------------------------------------------------
-- |
-- Module      :  Data.Typeable
-- Copyright   :  (c) The University of Glasgow, CWI 2001--2004
-- License     :  BSD-style (see the file libraries/base/LICENSE)
-- 
-- Maintainer  :  libraries@haskell.org
-- Stability   :  experimental
-- Portability :  portable
--
-- This module defines the old, kind-monomorphic 'Typeable' class. It is now
-- deprecated; users are recommended to use the kind-polymorphic
-- "Data.Typeable" module instead.
--
-----------------------------------------------------------------------------

module Data.OldTypeable {-# DEPRECATED "Use Data.Typeable instead" #-} -- deprecated in 7.8
  (

        -- * The Typeable class
        Typeable( typeOf ),     -- :: a -> TypeRep

        -- * Type-safe cast
        cast,                   -- :: (Typeable a, Typeable b) => a -> Maybe b
        gcast,                  -- a generalisation of cast

        -- * Type representations
        TypeRep,        -- abstract, instance of: Eq, Show, Typeable
        showsTypeRep,

        TyCon,          -- abstract, instance of: Eq, Show, Typeable
        tyConString,    -- :: TyCon   -> String
        tyConPackage,   -- :: TyCon   -> String
        tyConModule,    -- :: TyCon   -> String
        tyConName,      -- :: TyCon   -> String

        -- * Construction of type representations
        mkTyCon,        -- :: String  -> TyCon
        mkTyCon3,       -- :: String  -> String -> String -> TyCon
        mkTyConApp,     -- :: TyCon   -> [TypeRep] -> TypeRep
        mkAppTy,        -- :: TypeRep -> TypeRep   -> TypeRep
        mkFunTy,        -- :: TypeRep -> TypeRep   -> TypeRep

        -- * Observation of type representations
        splitTyConApp,  -- :: TypeRep -> (TyCon, [TypeRep])
        funResultTy,    -- :: TypeRep -> TypeRep   -> Maybe TypeRep
        typeRepTyCon,   -- :: TypeRep -> TyCon
        typeRepArgs,    -- :: TypeRep -> [TypeRep]
        typeRepKey,     -- :: TypeRep -> IO TypeRepKey
        TypeRepKey,     -- abstract, instance of Eq, Ord

        -- * The other Typeable classes
        -- | /Note:/ The general instances are provided for GHC only.
        Typeable1( typeOf1 ),   -- :: t a -> TypeRep
        Typeable2( typeOf2 ),   -- :: t a b -> TypeRep
        Typeable3( typeOf3 ),   -- :: t a b c -> TypeRep
        Typeable4( typeOf4 ),   -- :: t a b c d -> TypeRep
        Typeable5( typeOf5 ),   -- :: t a b c d e -> TypeRep
        Typeable6( typeOf6 ),   -- :: t a b c d e f -> TypeRep
        Typeable7( typeOf7 ),   -- :: t a b c d e f g -> TypeRep
        gcast1,                 -- :: ... => c (t a) -> Maybe (c (t' a))
        gcast2,                 -- :: ... => c (t a b) -> Maybe (c (t' a b))

        -- * Default instances
        -- | /Note:/ These are not needed by GHC, for which these instances
        -- are generated by general instance declarations.
        typeOfDefault,  -- :: (Typeable1 t, Typeable a) => t a -> TypeRep
        typeOf1Default, -- :: (Typeable2 t, Typeable a) => t a b -> TypeRep
        typeOf2Default, -- :: (Typeable3 t, Typeable a) => t a b c -> TypeRep
        typeOf3Default, -- :: (Typeable4 t, Typeable a) => t a b c d -> TypeRep
        typeOf4Default, -- :: (Typeable5 t, Typeable a) => t a b c d e -> TypeRep
        typeOf5Default, -- :: (Typeable6 t, Typeable a) => t a b c d e f -> TypeRep
        typeOf6Default  -- :: (Typeable7 t, Typeable a) => t a b c d e f g -> TypeRep

  ) where

import Data.OldTypeable.Internal hiding (mkTyCon)

import Unsafe.Coerce
import Data.Maybe

import GHC.Base

import GHC.Fingerprint.Type
import GHC.Fingerprint

#include "OldTypeable.h"

{-# DEPRECATED typeRepKey "TypeRep itself is now an instance of Ord" #-} -- deprecated in 7.2
-- | (DEPRECATED) Returns a unique key associated with a 'TypeRep'.
-- This function is deprecated because 'TypeRep' itself is now an
-- instance of 'Ord', so mappings can be made directly with 'TypeRep'
-- as the key.
--
typeRepKey :: TypeRep -> IO TypeRepKey
typeRepKey (TypeRep f _ _) = return (TypeRepKey f)

        -- 
        -- let fTy = mkTyCon "Foo" in show (mkTyConApp (mkTyCon ",,")
        --                                 [fTy,fTy,fTy])
        -- 
        -- returns "(Foo,Foo,Foo)"
        --
        -- The TypeRep Show instance promises to print tuple types
        -- correctly. Tuple type constructors are specified by a 
        -- sequence of commas, e.g., (mkTyCon ",,,,") returns
        -- the 5-tuple tycon.

newtype TypeRepKey = TypeRepKey Fingerprint
  deriving (Eq,Ord)

----------------- Construction ---------------------

{-# DEPRECATED mkTyCon "either derive Typeable, or use mkTyCon3 instead" #-} -- deprecated in 7.2
-- | Backwards-compatible API
mkTyCon :: String       -- ^ unique string
        -> TyCon        -- ^ A unique 'TyCon' object
mkTyCon name = TyCon (fingerprintString name) "" "" name

-------------------------------------------------------------
--
--              Type-safe cast
--
-------------------------------------------------------------

-- | The type-safe cast operation
cast :: (Typeable a, Typeable b) => a -> Maybe b
cast x = r
       where
         r = if typeOf x == typeOf (fromJust r)
               then Just $ unsafeCoerce x
               else Nothing

-- | A flexible variation parameterised in a type constructor
gcast :: (Typeable a, Typeable b) => c a -> Maybe (c b)
gcast x = r
 where
  r = if typeOf (getArg x) == typeOf (getArg (fromJust r))
        then Just $ unsafeCoerce x
        else Nothing
  getArg :: c x -> x 
  getArg = undefined

-- | Cast for * -> *
gcast1 :: (Typeable1 t, Typeable1 t') => c (t a) -> Maybe (c (t' a)) 
gcast1 x = r
 where
  r = if typeOf1 (getArg x) == typeOf1 (getArg (fromJust r))
       then Just $ unsafeCoerce x
       else Nothing
  getArg :: c x -> x 
  getArg = undefined

-- | Cast for * -> * -> *
gcast2 :: (Typeable2 t, Typeable2 t') => c (t a b) -> Maybe (c (t' a b)) 
gcast2 x = r
 where
  r = if typeOf2 (getArg x) == typeOf2 (getArg (fromJust r))
       then Just $ unsafeCoerce x
       else Nothing
  getArg :: c x -> x 
  getArg = undefined

