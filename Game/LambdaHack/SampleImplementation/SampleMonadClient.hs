{-# LANGUAGE DeriveGeneric, GeneralizedNewtypeDeriving #-}
-- | The main game action monad type implementation. Just as any other
-- component of the library, this implementation can be substituted.
-- This module should not be imported anywhere except in 'Action'
-- to expose the executor to any code using the library.
module Game.LambdaHack.SampleImplementation.SampleMonadClient
  ( CliState(..)
#ifdef CLIENTS_AS_THREADS
  , executorCliAsThread
#else
  , runCli, initialCliState
#endif
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , CliImplementation
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import qualified Control.Monad.IO.Class as IO
import Control.Monad.Trans.State.Strict hiding (State)
import Data.Binary
import GHC.Generics (Generic)

import Game.LambdaHack.Atomic.HandleAtomicWrite
import Game.LambdaHack.Atomic.MonadAtomic
import Game.LambdaHack.Atomic.MonadStateWrite
import Game.LambdaHack.Client.MonadClient
import Game.LambdaHack.Client.State
import Game.LambdaHack.Client.UI.MonadClientUI
import Game.LambdaHack.Client.UI.SessionUI
import Game.LambdaHack.Common.Faction
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.State

#ifdef CLIENTS_AS_THREADS
import Control.Concurrent
import System.FilePath

import Game.LambdaHack.Client.FileM
import Game.LambdaHack.Client.ProtocolM
import Game.LambdaHack.Common.ClientOptions
import qualified Game.LambdaHack.Common.Save as Save
import Game.LambdaHack.Server.ProtocolM hiding (saveName)
#endif

data CliState = CliState
  { cliState   :: !State              -- ^ current global state
  , cliClient  :: !StateClient        -- ^ current client state
  , cliSession :: !(Maybe SessionUI)  -- ^ UI state, empty for AI clients
#ifdef CLIENTS_AS_THREADS
  , cliDict    :: !ChanServer   -- ^ this client connection information
  , cliToSave  :: !(Save.ChanSave (State, StateClient, Maybe SessionUI))
                                -- ^ connection to the save thread
#endif
  }
  deriving Generic

#ifndef CLIENTS_AS_THREADS
instance Binary CliState
#endif

-- | Client state transformation monad.
newtype CliImplementation a = CliImplementation
  { runCliImplementation :: StateT CliState IO a }
  deriving (Monad, Functor, Applicative)

instance MonadStateRead CliImplementation where
  {-# INLINE getsState #-}
  getsState f = CliImplementation $ gets $ f . cliState

instance MonadStateWrite CliImplementation where
  {-# INLINE modifyState #-}
  modifyState f = CliImplementation $ state $ \cliS ->
    let !newCliState = f $ cliState cliS
    in ((), cliS {cliState = newCliState})

instance MonadClient CliImplementation where
  {-# INLINE getsClient #-}
  getsClient   f = CliImplementation $ gets $ f . cliClient
  {-# INLINE modifyClient #-}
  modifyClient f = CliImplementation $ state $ \cliS ->
    let !newCliState = f $ cliClient cliS
    in ((), cliS {cliClient = newCliState})
  {-# INLINABLE liftIO #-}
  liftIO = CliImplementation . IO.liftIO

instance MonadClientSetup CliImplementation where
#ifdef CLIENTS_AS_THREADS
  saveClient = CliImplementation $ do
    toSave <- gets cliToSave
    s <- gets cliState
    cli <- gets cliClient
    sess <- gets cliSession
    IO.liftIO $ Save.saveToChan toSave (s, cli, sess)
#else
  saveClient = return ()
#endif
  restartClient  = CliImplementation $ state $ \cliS ->
    case cliSession cliS of
      Just sess ->
        let !newSess = (emptySessionUI (sconfig sess))
                         { schanF = schanF sess
                         , sbinding = sbinding sess
                         , shistory = shistory sess
                         , _sreport = _sreport sess
                         , sstart = sstart sess
                         , sgstart = sgstart sess
                         , sallTime = sallTime sess
                         , snframes = snframes sess
                         , sallNframes = sallNframes sess
                         }
        in ((), cliS {cliSession = Just newSess})
      Nothing -> ((), cliS)

instance MonadClientUI CliImplementation where
  {-# INLINE getsSession #-}
  getsSession   f = CliImplementation $ gets $ f . fromJust . cliSession
  {-# INLINE modifySession #-}
  modifySession f = CliImplementation $ state $ \cliS ->
    let !newCliSession = f $ fromJust $ cliSession cliS
    in ((), cliS {cliSession = Just newCliSession})
  {-# INLINABLE liftIO #-}
  liftIO = CliImplementation . IO.liftIO

#ifdef CLIENTS_AS_THREADS
instance MonadClientReadResponse CliImplementation where
  {-# INLINE receiveResponse #-}
  receiveResponse = CliImplementation $ do
    ChanServer{responseS} <- gets cliDict
    IO.liftIO $ takeMVar responseS

instance MonadClientWriteRequest CliImplementation where
  {-# INLINE sendRequest #-}
  sendRequest scmd = CliImplementation $ do
    ChanServer{requestS} <- gets cliDict
    IO.liftIO $ putMVar requestS scmd
#endif

-- | The game-state semantics of atomic commands
-- as computed on the client.
instance MonadAtomic CliImplementation where
  {-# INLINE execUpdAtomic #-}
  execUpdAtomic cmd = handleUpdAtomic cmd
  {-# INLINE execSfxAtomic #-}
  execSfxAtomic _sfx = return ()

#ifdef CLIENTS_AS_THREADS
-- | Init the client, then run an action, with a given session,
-- state and history, in the @IO@ monad.
executorCliAsThread :: Bool
                    -> CliImplementation ()
                    -> Maybe SessionUI
                    -> Kind.COps
                    -> FactionId
                    -> ChanServer
                    -> IO ()
{-# INLINE executorCliAsThread #-}
executorCliAsThread isAI m cliSession cops fid cliDict =
  let saveFile (_, cli, _) =
        ssavePrefixCli (sdebugCli cli)
        <.> saveName (sside cli) isAI
      totalState cliToSave = CliState
        { cliState = emptyState cops
        , cliClient = emptyStateClient fid
        , cliDict
        , cliToSave
        , cliSession
        }
      exe = evalStateT (runCliImplementation m) . totalState
  in Save.wrapInSaves tryCreateDir encodeEOF saveFile exe
#else
initialCliState :: Kind.COps
                -> Maybe SessionUI
                -> FactionId
                -> CliState
initialCliState cops cliSession fid =
  CliState
    { cliState = emptyState cops
    , cliClient = emptyStateClient fid
    , cliSession
    }

runCli :: CliImplementation a -> CliState -> IO (a, CliState)
{-# INLINE runCli #-}
runCli m = runStateT (runCliImplementation m)
#endif
