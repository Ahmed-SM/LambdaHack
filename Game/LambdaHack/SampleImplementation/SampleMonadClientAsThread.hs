{-# LANGUAGE FlexibleInstances, GeneralizedNewtypeDeriving,
             MultiParamTypeClasses #-}
-- | The main game action monad type implementation. Just as any other
-- component of the library, this implementation can be substituted.
-- This module should not be imported anywhere except in 'Action'
-- to expose the executor to any code using the library.
module Game.LambdaHack.SampleImplementation.SampleMonadClientAsThread
  ( executorCliAsThread
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , CliImplementationAsThread
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import Control.Concurrent
import qualified Control.Monad.IO.Class as IO
import Control.Monad.Trans.State.Strict hiding (State)
import Data.Binary
import System.FilePath

import Game.LambdaHack.Atomic.HandleAtomicWrite
import Game.LambdaHack.Atomic.MonadAtomic
import Game.LambdaHack.Atomic.MonadStateWrite
import Game.LambdaHack.Client.FileM
import Game.LambdaHack.Client.MonadClient
import Game.LambdaHack.Client.ProtocolM
import Game.LambdaHack.Client.State
import Game.LambdaHack.Client.UI.MonadClientUI
import Game.LambdaHack.Client.UI.SessionUI
import Game.LambdaHack.Common.ClientOptions
import Game.LambdaHack.Common.Faction
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.MonadStateRead
import qualified Game.LambdaHack.Common.Save as Save
import Game.LambdaHack.Common.State
import Game.LambdaHack.Server.ProtocolM hiding (saveName)

data CliState sess resp req = CliState
  { cliState   :: !State        -- ^ current global state
  , cliClient  :: !StateClient  -- ^ current client state
  , cliDict    :: !(ChanServer resp req)
                                -- ^ this client connection information
  , cliToSave  :: !(Save.ChanSave (State, StateClient, sess))
                                -- ^ connection to the save thread
  , cliSession :: !sess         -- ^ UI state, empty for AI clients
  }

-- | Client state transformation monad.
newtype CliImplementation sess resp req a = CliImplementation
  { runCliImplementation :: StateT (CliState sess resp req) IO a }
  deriving (Monad, Functor, Applicative)

instance MonadStateRead (CliImplementation sess resp req) where
  getState    = CliImplementation $ gets cliState
  getsState f = CliImplementation $ gets $ f . cliState

instance MonadStateWrite (CliImplementation sess resp req) where
  modifyState f = CliImplementation $ state $ \cliS ->
    let !newCliState = f $ cliState cliS
    in ((), cliS {cliState = newCliState})
  putState s = CliImplementation $ state $ \cliS ->
    s `seq` ((), cliS {cliState = s})

instance MonadClient (CliImplementation sess resp req) where
  getClient      = CliImplementation $ gets cliClient
  getsClient   f = CliImplementation $ gets $ f . cliClient
  modifyClient f = CliImplementation $ state $ \cliS ->
    let !newCliState = f $ cliClient cliS
    in ((), cliS {cliClient = newCliState})
  putClient s = CliImplementation $ state $ \cliS ->
    s `seq` ((), cliS {cliClient = s})
  liftIO = CliImplementation . IO.liftIO

instance MonadClientSetup (CliImplementation () resp req) where
  saveClient = CliImplementation $ do
    toSave <- gets cliToSave
    s <- gets cliState
    cli <- gets cliClient
    IO.liftIO $ Save.saveToChan toSave (s, cli, ())
  restartClient = return ()

instance MonadClientSetup (CliImplementation SessionUI resp req) where
  saveClient = CliImplementation $ do
    toSave <- gets cliToSave
    s <- gets cliState
    cli <- gets cliClient
    sess <- gets cliSession
    IO.liftIO $ Save.saveToChan toSave (s, cli, sess)
  restartClient  = CliImplementation $ state $ \cliS ->
    let sess = cliSession cliS
        !newSess = (emptySessionUI (sconfig sess))
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
    in ((), cliS {cliSession = newSess})

instance MonadClientUI (CliImplementation SessionUI resp req) where
  getSession      = CliImplementation $ gets cliSession
  getsSession   f = CliImplementation $ gets $ f . cliSession
  modifySession f = CliImplementation $ state $ \cliS ->
    let !newCliSession = f $ cliSession cliS
    in ((), cliS {cliSession = newCliSession})
  putSession s = CliImplementation $ state $ \cliS ->
    s `seq` ((), cliS {cliSession = s})
  liftIO = CliImplementation . IO.liftIO

instance MonadClientReadResponse resp (CliImplementation sess resp req) where
  receiveResponse = CliImplementation $ do
    ChanServer{responseS} <- gets cliDict
    IO.liftIO $ takeMVar responseS

instance MonadClientWriteRequest req (CliImplementation sess resp req) where
  sendRequest scmd = CliImplementation $ do
    ChanServer{requestS} <- gets cliDict
    IO.liftIO $ putMVar requestS scmd

-- | The game-state semantics of atomic commands
-- as computed on the client.
instance MonadAtomic (CliImplementation sess resp req) where
  execAtomic = handleCmdAtomic

-- | Init the client, then run an action, with a given session,
-- state and history, in the @IO@ monad.
executorCliAsThread :: Binary sess
                    => CliImplementation sess resp req ()
                    -> sess
                    -> Kind.COps
                    -> FactionId
                    -> ChanServer resp req
                    -> IO ()
executorCliAsThread m cliSession cops fid cliDict =
  let saveFile (_, cli, _) =
        ssavePrefixCli (sdebugCli cli)
        <.> saveName (sside cli) (sisAI cli)
      totalState cliToSave = CliState
        { cliState = emptyState cops
        , cliClient = emptyStateClient fid
        , cliDict
        , cliToSave
        , cliSession
        }
      exe = evalStateT (runCliImplementation m) . totalState
  in Save.wrapInSaves tryCreateDir encodeEOF saveFile exe