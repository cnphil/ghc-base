{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE CPP
           , ForeignFunctionInterface
           , CApiFFI
           , GeneralizedNewtypeDeriving
           , NoImplicitPrelude
           , RecordWildCards
           , BangPatterns
  #-}

module GHC.Event.KQueue
    (
      new
    , available
    ) where

import qualified GHC.Event.Internal as E

#include "EventConfig.h"
#if !defined(HAVE_KQUEUE)
import GHC.Base

new :: IO E.Backend
new = error "KQueue back end not implemented for this platform"

available :: Bool
available = False
{-# INLINE available #-}
#else

import Control.Monad (when, void)
import Data.Bits (Bits(..))
import Data.Maybe (Maybe(..))
import Data.Monoid (Monoid(..))
import Data.Word (Word16, Word32)
import Foreign.C.Error (throwErrnoIfMinus1)
import Foreign.C.Types
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (Storable(..))
import GHC.Base
import GHC.Enum (toEnum)
import GHC.Err (undefined)
import GHC.Num (Num(..))
import GHC.Real (ceiling, floor, fromIntegral)
import GHC.Show (Show(show))
import GHC.Event.Internal (Timeout(..))
import System.Posix.Internals (c_close)
import System.Posix.Types (Fd(..))
import qualified GHC.Event.Array as A

#if defined(HAVE_KEVENT64)
import Data.Int (Int64)
import Data.Word (Word64)
#elif defined(netbsd_HOST_OS)
import Data.Int (Int64)
#endif

#include <sys/types.h>
#include <sys/event.h>
#include <sys/time.h>

-- Handle brokenness on some BSD variants, notably OS X up to at least
-- 10.6.  If NOTE_EOF isn't available, we have no way to receive a
-- notification from the kernel when we reach EOF on a plain file.
#ifndef NOTE_EOF
# define NOTE_EOF 0
#endif

available :: Bool
available = True
{-# INLINE available #-}

------------------------------------------------------------------------
-- Exported interface

data EventQueue = EventQueue {
      eqFd       :: {-# UNPACK #-} !QueueFd
    , eqEvents   :: {-# UNPACK #-} !(A.Array Event)
    }

new :: IO E.Backend
new = do
  qfd <- kqueue
  events <- A.new 64
  let !be = E.backend poll modifyFd modifyFdOnce delete (EventQueue qfd events)
  return be

delete :: EventQueue -> IO ()
delete q = do
  _ <- c_close . fromQueueFd . eqFd $ q
  return ()

modifyFd :: EventQueue -> Fd -> E.Event -> E.Event -> IO ()
modifyFd q fd oevt nevt
  | nevt == mempty = do
      let !ev = event fd (toFilter oevt) flagDelete noteEOF
      kqueueControl (eqFd q) ev
  | otherwise      = do
      let !ev = event fd (toFilter nevt) flagAdd noteEOF
      kqueueControl (eqFd q) ev

toFilter :: E.Event -> Filter
toFilter evt
  | evt `E.eventIs` E.evtRead = filterRead
  | otherwise                 = filterWrite

modifyFdOnce :: EventQueue -> Fd -> E.Event -> IO ()
modifyFdOnce = error "modifyFdOnce not supported in KQueue backend"

poll :: EventQueue
     -> Maybe Timeout
     -> (Fd -> E.Event -> IO ())
     -> IO Int
poll EventQueue{..} mtout f = do
    n <- A.unsafeLoad eqEvents $ \evp cap ->
      case mtout of
        Just tout -> withTimeSpec (fromTimeout tout) $
                     kevent True eqFd nullPtr 0 evp cap
        Nothing   -> withTimeSpec (TimeSpec 0 0) $
                     kevent False eqFd nullPtr 0 evp cap
    when (n > 0) $ do
        cap <- A.capacity eqEvents
        when (n == cap) $ A.ensureCapacity eqEvents (2 * cap)
        A.forM_ eqEvents $ \e -> f (fromIntegral (ident e)) (toEvent (filter e))
    return n
------------------------------------------------------------------------
-- FFI binding

newtype QueueFd = QueueFd {
      fromQueueFd :: CInt
    } deriving (Eq, Show)

#if defined(HAVE_KEVENT64)
data Event = KEvent64 {
      ident  :: {-# UNPACK #-} !Word64
    , filter :: {-# UNPACK #-} !Filter
    , flags  :: {-# UNPACK #-} !Flag
    , fflags :: {-# UNPACK #-} !FFlag
    , data_  :: {-# UNPACK #-} !Int64
    , udata  :: {-# UNPACK #-} !Word64
    , ext0   :: {-# UNPACK #-} !Word64
    , ext1   :: {-# UNPACK #-} !Word64
    } deriving Show

event :: Fd -> Filter -> Flag -> FFlag -> Event
event fd filt flag fflag = KEvent64 (fromIntegral fd) filt flag fflag 0 0 0 0

instance Storable Event where
    sizeOf _ = #size struct kevent64_s
    alignment _ = alignment (undefined :: CInt)

    peek ptr = do
        ident'  <- #{peek struct kevent64_s, ident} ptr
        filter' <- #{peek struct kevent64_s, filter} ptr
        flags'  <- #{peek struct kevent64_s, flags} ptr
        fflags' <- #{peek struct kevent64_s, fflags} ptr
        data'   <- #{peek struct kevent64_s, data} ptr
        udata'  <- #{peek struct kevent64_s, udata} ptr
        ext0'   <- #{peek struct kevent64_s, ext[0]} ptr
        ext1'   <- #{peek struct kevent64_s, ext[1]} ptr
        let !ev = KEvent64 ident' (Filter filter') (Flag flags') fflags' data'
                           udata' ext0' ext1'
        return ev

    poke ptr ev = do
        #{poke struct kevent64_s, ident} ptr (ident ev)
        #{poke struct kevent64_s, filter} ptr (filter ev)
        #{poke struct kevent64_s, flags} ptr (flags ev)
        #{poke struct kevent64_s, fflags} ptr (fflags ev)
        #{poke struct kevent64_s, data} ptr (data_ ev)
        #{poke struct kevent64_s, udata} ptr (udata ev)
        #{poke struct kevent64_s, ext[0]} ptr (ext0 ev)
        #{poke struct kevent64_s, ext[1]} ptr (ext1 ev)
#else
data Event = KEvent {
      ident  :: {-# UNPACK #-} !CUIntPtr
    , filter :: {-# UNPACK #-} !Filter
    , flags  :: {-# UNPACK #-} !Flag
    , fflags :: {-# UNPACK #-} !FFlag
#ifdef netbsd_HOST_OS
    , data_  :: {-# UNPACK #-} !Int64
#else
    , data_  :: {-# UNPACK #-} !CIntPtr
#endif
    , udata  :: {-# UNPACK #-} !(Ptr ())
    } deriving Show

event :: Fd -> Filter -> Flag -> FFlag -> Event
event fd filt flag fflag = KEvent (fromIntegral fd) filt flag fflag 0 nullPtr

instance Storable Event where
    sizeOf _ = #size struct kevent
    alignment _ = alignment (undefined :: CInt)

    peek ptr = do
        ident'  <- #{peek struct kevent, ident} ptr
        filter' <- #{peek struct kevent, filter} ptr
        flags'  <- #{peek struct kevent, flags} ptr
        fflags' <- #{peek struct kevent, fflags} ptr
        data'   <- #{peek struct kevent, data} ptr
        udata'  <- #{peek struct kevent, udata} ptr
        let !ev = KEvent ident' (Filter filter') (Flag flags') fflags' data'
                         udata'
        return ev

    poke ptr ev = do
        #{poke struct kevent, ident} ptr (ident ev)
        #{poke struct kevent, filter} ptr (filter ev)
        #{poke struct kevent, flags} ptr (flags ev)
        #{poke struct kevent, fflags} ptr (fflags ev)
        #{poke struct kevent, data} ptr (data_ ev)
        #{poke struct kevent, udata} ptr (udata ev)
#endif

newtype FFlag = FFlag Word32
    deriving (Eq, Show, Storable)

#{enum FFlag, FFlag
 , noteEOF = NOTE_EOF
 }

#if SIZEOF_KEV_FLAGS == 4 /* kevent.flag: uint32_t or uint16_t. */
newtype Flag = Flag Word32
#else
newtype Flag = Flag Word16
#endif
    deriving (Eq, Show, Storable)

#{enum Flag, Flag
 , flagAdd     = EV_ADD
 , flagDelete  = EV_DELETE
 }

#if SIZEOF_KEV_FILTER == 4 /*kevent.filter: uint32_t or uint16_t. */
newtype Filter = Filter Word32
#else
newtype Filter = Filter Word16
#endif
    deriving (Bits, Eq, Num, Show, Storable)

#{enum Filter, Filter
 , filterRead   = EVFILT_READ
 , filterWrite  = EVFILT_WRITE
 }

data TimeSpec = TimeSpec {
      tv_sec  :: {-# UNPACK #-} !CTime
    , tv_nsec :: {-# UNPACK #-} !CLong
    }

instance Storable TimeSpec where
    sizeOf _ = #size struct timespec
    alignment _ = alignment (undefined :: CInt)

    peek ptr = do
        tv_sec'  <- #{peek struct timespec, tv_sec} ptr
        tv_nsec' <- #{peek struct timespec, tv_nsec} ptr
        let !ts = TimeSpec tv_sec' tv_nsec'
        return ts

    poke ptr ts = do
        #{poke struct timespec, tv_sec} ptr (tv_sec ts)
        #{poke struct timespec, tv_nsec} ptr (tv_nsec ts)

kqueue :: IO QueueFd
kqueue = QueueFd `fmap` throwErrnoIfMinus1 "kqueue" c_kqueue

kqueueControl :: KQueueFd -> Event -> IO ()
kqueueControl kfd ev = void $
    withTimeSpec (TimeSpec 0 0) $ \tp ->
        withEvent ev $ \evp -> kevent False kfd evp 1 nullPtr 0 tp

-- TODO: We cannot retry on EINTR as the timeout would be wrong.
-- Perhaps we should just return without calling any callbacks.
kevent :: Bool -> QueueFd -> Ptr Event -> Int -> Ptr Event -> Int -> Ptr TimeSpec
       -> IO Int
kevent safe k chs chlen evs evlen ts
    = fmap fromIntegral $ E.throwErrnoIfMinus1NoRetry "kevent" $
#if defined(HAVE_KEVENT64)
      if safe
      then c_kevent64 k chs (fromIntegral chlen) evs (fromIntegral evlen) 0 ts
      else c_kevent64_unsafe k chs (fromIntegral chlen) evs (fromIntegral evlen) 0 ts
#else
      if safe 
      then c_kevent k chs (fromIntegral chlen) evs (fromIntegral evlen) ts
      else c_kevent_unsafe k chs (fromIntegral chlen) evs (fromIntegral evlen) ts
#endif

withTimeSpec :: TimeSpec -> (Ptr TimeSpec -> IO a) -> IO a
withTimeSpec ts f =
    if tv_sec ts < 0 then
        f nullPtr
      else
        alloca $ \ptr -> poke ptr ts >> f ptr

fromTimeout :: Timeout -> TimeSpec
fromTimeout Forever     = TimeSpec (-1) (-1)
fromTimeout (Timeout s) = TimeSpec (toEnum sec) (toEnum nanosec)
  where
    sec :: Int
    sec     = floor s

    nanosec :: Int
    nanosec = ceiling $ (s - fromIntegral sec) * 1000000000

toEvent :: Filter -> E.Event
toEvent (Filter f)
    | f == (#const EVFILT_READ) = E.evtRead
    | f == (#const EVFILT_WRITE) = E.evtWrite
    | otherwise = error $ "toEvent: unknown filter " ++ show f

foreign import ccall unsafe "kqueue"
    c_kqueue :: IO CInt

#if defined(HAVE_KEVENT64)
foreign import ccall safe "kevent64"
    c_kevent64 :: QueueFd -> Ptr Event -> CInt -> Ptr Event -> CInt -> CUInt
               -> Ptr TimeSpec -> IO CInt

foreign import ccall unsafe "kevent64"
    c_kevent64_unsafe :: KQueueFd -> Ptr Event -> CInt -> Ptr Event -> CInt -> CUInt
                      -> Ptr TimeSpec -> IO CInt               
#elif defined(HAVE_KEVENT)
foreign import capi safe "sys/event.h kevent"
    c_kevent :: QueueFd -> Ptr Event -> CInt -> Ptr Event -> CInt
             -> Ptr TimeSpec -> IO CInt

foreign import ccall unsafe "kevent"
    c_kevent_unsafe :: KQueueFd -> Ptr Event -> CInt -> Ptr Event -> CInt
                    -> Ptr TimeSpec -> IO CInt
#else
#error no kevent system call available!?
#endif

#endif /* defined(HAVE_KQUEUE) */
