{-# OPTIONS_GHC -XNoImplicitPrelude #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Exception
-- Copyright   :  (c) The University of Glasgow 2001
-- License     :  BSD-style (see the file libraries/base/LICENSE)
--
-- Maintainer  :  libraries@haskell.org
-- Stability   :  experimental
-- Portability :  non-portable (extended exceptions)
--
-- This module provides support for raising and catching both built-in
-- and user-defined exceptions.
--
-- In addition to exceptions thrown by 'IO' operations, exceptions may
-- be thrown by pure code (imprecise exceptions) or by external events
-- (asynchronous exceptions), but may only be caught in the 'IO' monad.
-- For more details, see:
--
--  * /A semantics for imprecise exceptions/, by Simon Peyton Jones,
--    Alastair Reid, Tony Hoare, Simon Marlow, Fergus Henderson,
--    in /PLDI'99/.
--
--  * /Asynchronous exceptions in Haskell/, by Simon Marlow, Simon Peyton
--    Jones, Andy Moran and John Reppy, in /PLDI'01/.
--
--  * /An Extensible Dynamically-Typed Hierarchy of Exceptions/,
--    by Simon Marlow, in /Haskell '06/.
--
-----------------------------------------------------------------------------

module Control.Exception (

        -- * The Exception type
#ifdef __HUGS__
        SomeException,
#else
        SomeException(..),
#endif
        Exception(..),          -- class
        IOException,            -- instance Eq, Ord, Show, Typeable, Exception
        ArithException(..),     -- instance Eq, Ord, Show, Typeable, Exception
        ArrayException(..),     -- instance Eq, Ord, Show, Typeable, Exception
        AssertionFailed(..),
        AsyncException(..),     -- instance Eq, Ord, Show, Typeable, Exception

#if __GLASGOW_HASKELL__ || __HUGS__
        NonTermination(..),
        NestedAtomically(..),
#endif
#ifdef __NHC__
        System.ExitCode(), -- instance Exception
#endif

        BlockedOnDeadMVar(..),
        BlockedIndefinitely(..),
        Deadlock(..),
        NoMethodError(..),
        PatternMatchFail(..),
        RecConError(..),
        RecSelError(..),
        RecUpdError(..),
        ErrorCall(..),

        -- * Throwing exceptions
        throw,
        throwIO,
        ioError,
#ifdef __GLASGOW_HASKELL__
        throwTo,
#endif

        -- * Catching Exceptions

        -- $catching

        -- ** Catching all exceptions

        -- $catchall

        -- ** The @catch@ functions
        catch,
        catches, Handler(..),
        catchJust,

        -- ** The @handle@ functions
        handle,
        handleJust,

        -- ** The @try@ functions
        try,
        tryJust,

        -- ** The @evaluate@ function
        evaluate,

        -- ** The @mapException@ function
        mapException,

        -- * Asynchronous Exceptions

        -- $async

        -- ** Asynchronous exception control

        -- |The following two functions allow a thread to control delivery of
        -- asynchronous exceptions during a critical region.

        block,
        unblock,
        blocked,

        -- *** Applying @block@ to an exception handler

        -- $block_handler

        -- *** Interruptible operations

        -- $interruptible

        -- * Assertions

        assert,

        -- * Utilities

        bracket,
        bracket_,
        bracketOnError,

        finally,
        onException,

  ) where

import Control.Exception.Base

#ifdef __GLASGOW_HASKELL__
import GHC.Base
-- import GHC.IO hiding ( onException, finally )
import Data.Maybe
#else
import Prelude hiding (catch)
#endif

#ifdef __NHC__
import System (ExitCode())
#endif

-- | You need this when using 'catches'.
data Handler a = forall e . Exception e => Handler (e -> IO a)

{- |
Sometimes you want to catch two different sorts of exception. You could
do something like

> f = expr `catch` \ (ex :: ArithException) -> handleArith ex
>          `catch` \ (ex :: IOException)    -> handleIO    ex

However, there are a couple of problems with this approach. The first is
that having two exception handlers is inefficient. However, the more
serious issue is that the second exception handler will catch exceptions
in the first, e.g. in the example above, if @handleArith@ throws an
@IOException@ then the second exception handler will catch it.

Instead, we provide a function 'catches', which would be used thus:

> f = expr `catches` [Handler (\ (ex :: ArithException) -> handleArith ex),
>                     Handler (\ (ex :: IOException)    -> handleIO    ex)]
-}
catches :: IO a -> [Handler a] -> IO a
catches io handlers = io `catch` catchesHandler handlers

catchesHandler :: [Handler a] -> SomeException -> IO a
catchesHandler handlers e = foldr tryHandler (throw e) handlers
    where tryHandler (Handler handler) res
              = case fromException e of
                Just e' -> handler e'
                Nothing -> res

-- -----------------------------------------------------------------------------
-- Catching exceptions

{- $catching

There are several functions for catching and examining
exceptions; all of them may only be used from within the
'IO' monad.

Here's a rule of thumb for deciding which catch-style function to
use:

 * If you want to do some cleanup in the event that an exception
   is raised, use 'finally', 'bracket' or 'onException'.

 * To recover after an exception and do something else, the best
   choice is to use one of the 'try' family.

 * ... unless you are recovering from an asynchronous exception, in which
   case use 'catch' or 'catchJust'.

The difference between using 'try' and 'catch' for recovery is that in
'catch' the handler is inside an implicit 'block' (see \"Asynchronous
Exceptions\") which is important when catching asynchronous
exceptions, but when catching other kinds of exception it is
unnecessary.  Furthermore it is possible to accidentally stay inside
the implicit 'block' by tail-calling rather than returning from the
handler, which is why we recommend using 'try' rather than 'catch' for
ordinary exception recovery.

A typical use of 'tryJust' for recovery looks like this:

>  do r <- tryJust (guard . isDoesNotExistError) $ getEnv "HOME"
>     case r of
>       Left  e    -> ...
>       Right home -> ...

-}

-- -----------------------------------------------------------------------------
-- Asynchronous exceptions

{- $async

 #AsynchronousExceptions# Asynchronous exceptions are so-called because they arise due to
external influences, and can be raised at any point during execution.
'StackOverflow' and 'HeapOverflow' are two examples of
system-generated asynchronous exceptions.

The primary source of asynchronous exceptions, however, is
'throwTo':

>  throwTo :: ThreadId -> Exception -> IO ()

'throwTo' (also 'throwDynTo' and 'Control.Concurrent.killThread') allows one
running thread to raise an arbitrary exception in another thread.  The
exception is therefore asynchronous with respect to the target thread,
which could be doing anything at the time it receives the exception.
Great care should be taken with asynchronous exceptions; it is all too
easy to introduce race conditions by the over zealous use of
'throwTo'.
-}

{- $block_handler
There\'s an implied 'block' around every exception handler in a call
to one of the 'catch' family of functions.  This is because that is
what you want most of the time - it eliminates a common race condition
in starting an exception handler, because there may be no exception
handler on the stack to handle another exception if one arrives
immediately.  If asynchronous exceptions are blocked on entering the
handler, though, we have time to install a new exception handler
before being interrupted.  If this weren\'t the default, one would have
to write something like

>      block (
>           catch (unblock (...))
>                      (\e -> handler)
>      )

If you need to unblock asynchronous exceptions again in the exception
handler, just use 'unblock' as normal.

Note that 'try' and friends /do not/ have a similar default, because
there is no exception handler in this case.  Don't use 'try' for
recovering from an asynchronous exception.
-}

{- $interruptible

Some operations are /interruptible/, which means that they can receive
asynchronous exceptions even in the scope of a 'block'.  Any function
which may itself block is defined as interruptible; this includes
'Control.Concurrent.MVar.takeMVar'
(but not 'Control.Concurrent.MVar.tryTakeMVar'),
and most operations which perform
some I\/O with the outside world.  The reason for having
interruptible operations is so that we can write things like

>      block (
>         a <- takeMVar m
>         catch (unblock (...))
>               (\e -> ...)
>      )

if the 'Control.Concurrent.MVar.takeMVar' was not interruptible,
then this particular
combination could lead to deadlock, because the thread itself would be
blocked in a state where it can\'t receive any asynchronous exceptions.
With 'Control.Concurrent.MVar.takeMVar' interruptible, however, we can be
safe in the knowledge that the thread can receive exceptions right up
until the point when the 'Control.Concurrent.MVar.takeMVar' succeeds.
Similar arguments apply for other interruptible operations like
'System.IO.openFile'.
-}

{- $catchall

It is possible to catch all exceptions, by using the type 'SomeException':

> catch f (\e -> ... (e :: SomeException) ...)

HOWEVER, this is normally not what you want to do!

For example, suppose you want to read a file, but if it doesn't exist
then continue as if it contained \"\".  You might be tempted to just
catch all exceptions and return \"\" in the handler. However, this has
all sorts of undesirable consequences.  For example, if the user
presses control-C at just the right moment then the 'UserInterrupt'
exception will be caught, and the program will continue running under
the belief that the file contains \"\".  Similarly, if another thread
tries to kill the thread reading the file then the 'ThreadKilled'
exception will be ignored.

Instead, you should only catch exactly the exceptions that you really
want. In this case, this would likely be more specific than even
\"any IO exception\"; a permissions error would likely also want to be
handled differently. Instead, you would probably want something like:

> e <- tryJust (guard . isDoesNotExistError) (readFile f)
> let str = either (const "") id e

There are occassions when you really do need to catch any sort of
exception. However, in most cases this is just so you can do some
cleaning up; you aren't actually interested in the exception itself.
For example, if you open a file then you want to close it again,
whether processing the file executes normally or throws an exception.
However, in these cases you can use functions like 'bracket', 'finally'
and 'onException', which never actually pass you the exception, but
just call the cleanup functions at the appropriate points.

But sometimes you really do need to catch any exception, and actually
see what the exception is. One example is at the very top-level of a
program, you may wish to catch any exception, print it to a logfile or
the screen, and then exit gracefully. For these cases, you can use
'catch' (or one of the other exception-catching functions) with the
'SomeException' type.
-}

