{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- | The server definitions for the server-client communication protocol.
module Game.LambdaHack.Server.ProtocolM
  ( -- * The communication channels
    CliSerQueue, ChanServer(..), updateCopsDict
  , ConnServerDict  -- exposed only to be implemented, not used
    -- * The server-client communication monad
  , MonadServerReadRequest
      ( getDict  -- exposed only to be implemented, not used
      , getsDict  -- exposed only to be implemented, not used
      , modifyDict  -- exposed only to be implemented, not used
      , putDict  -- exposed only to be implemented, not used
      , saveChanServer  -- exposed only to be implemented, not used
      , liftIO  -- exposed only to be implemented, not used
      )
    -- * Protocol
  , sendUpdate, sendSfx, sendQueryAI, sendNonLeaderQueryAI, sendQueryUI
    -- * Assorted
  , killAllClients, childrenServer, updateConn
  , saveServer, saveName, tryRestore
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , FrozenClient
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import Control.Concurrent
import Control.Concurrent.Async
import Data.Binary
import qualified Data.EnumMap.Strict as EM
import Data.Key (mapWithKeyM, mapWithKeyM_)
import Game.LambdaHack.Common.Thread
import System.FilePath
import System.IO.Unsafe (unsafePerformIO)

import Game.LambdaHack.Atomic
import Game.LambdaHack.Client.AI
import Game.LambdaHack.Client.HandleResponseM
import Game.LambdaHack.Client.LoopM
import Game.LambdaHack.Client.UI
import Game.LambdaHack.Client.UI.Config
import qualified Game.LambdaHack.Client.UI.Frontend as Frontend
import Game.LambdaHack.Client.UI.KeyBindings
import Game.LambdaHack.Client.UI.SessionUI
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ClientOptions
import Game.LambdaHack.Common.Faction
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Request
import Game.LambdaHack.Common.Response
import qualified Game.LambdaHack.Common.Save as Save
import Game.LambdaHack.Common.State
import Game.LambdaHack.Content.ModeKind
import Game.LambdaHack.Content.RuleKind
import Game.LambdaHack.SampleImplementation.SampleMonadClient
import Game.LambdaHack.Server.DebugM
import Game.LambdaHack.Server.FileM
import Game.LambdaHack.Server.MonadServer hiding (liftIO)
import Game.LambdaHack.Server.State

type CliSerQueue = MVar

writeQueueAI :: MonadServerReadRequest m
             => ResponseAI -> CliSerQueue ResponseAI -> m ()
writeQueueAI cmd responseS = do
  debug <- getsServer $ sniffOut . sdebugSer
  when debug $ debugResponseAI cmd
  liftIO $ putMVar responseS cmd

writeQueueUI :: MonadServerReadRequest m
             => ResponseUI -> CliSerQueue ResponseUI -> m ()
writeQueueUI cmd responseS = do
  debug <- getsServer $ sniffOut . sdebugSer
  when debug $ debugResponseUI cmd
  liftIO $ putMVar responseS cmd

readQueueAI :: MonadServerReadRequest m
            => CliSerQueue RequestAI -> m RequestAI
readQueueAI requestS = liftIO $ takeMVar requestS

readQueueUI :: MonadServerReadRequest m
            => CliSerQueue RequestUI -> m RequestUI
readQueueUI requestS = liftIO $ takeMVar requestS

newQueue :: IO (CliSerQueue a)
newQueue = newEmptyMVar

saveServer :: MonadServerReadRequest m => m ()
saveServer = do
  s <- getState
  ser <- getServer
  dictAll <- getDict
  let f FState{} = True
      f FThread{} = False
      dictFState = EM.filter f dictAll
  toSave <- saveChanServer
  liftIO $ Save.saveToChan toSave (s, ser, dictFState)

saveName :: String
saveName = serverSaveName

tryRestore :: MonadServerReadRequest m
           => Kind.COps -> DebugModeSer
           -> m (Maybe (State, StateServer, ConnServerDict))
tryRestore Kind.COps{corule} sdebugSer = do
  let bench = sbenchmark $ sdebugCli sdebugSer
  if bench then return Nothing
  else do
    let stdRuleset = Kind.stdRuleset corule
        scoresFile = rscoresFile stdRuleset
        pathsDataFile = rpathsDataFile stdRuleset
        prefix = ssavePrefixSer sdebugSer
    let copies = [( "GameDefinition" </> scoresFile
                  , scoresFile )]
        name = prefix <.> saveName
    liftIO $ Save.restoreGame tryCreateDir tryCopyDataFiles strictDecodeEOF name copies pathsDataFile

-- | Connection channel between the server and a single client.
data ChanServer resp req = ChanServer
  { responseS :: !(CliSerQueue resp)
  , requestS  :: !(CliSerQueue req)
  }

-- | Either states or connections to the human-controlled client
-- of a faction and to the AI client for the same faction.
data FrozenClient =
    FState !(Maybe (CliState SessionUI)) !(CliState ())
  | FThread !(Maybe (ChanServer ResponseUI RequestUI))
            !(ChanServer ResponseAI RequestAI)

instance Binary FrozenClient where
  put (FState mcliS cliS) = put mcliS >> put cliS
  put FThread{} =
    assert `failure` ("client thread connection cannot be saved" :: String)
  get = FState <$> get <*> get

-- | Connection information for all factions, indexed by faction identifier.
type ConnServerDict = EM.EnumMap FactionId FrozenClient

-- TODO: refactor so that the monad is split in 2 and looks analogously
-- to the Client monads. Restrict the Dict to implementation modules.
-- Then on top of that implement sendQueryAI, etc.
-- For now we call it MonadServerReadRequest
-- though it also has the functionality of MonadServerWriteResponse.

-- | The server monad with the ability to communicate with clients.
class MonadServer m => MonadServerReadRequest m where
  getDict      :: m ConnServerDict
  getsDict     :: (ConnServerDict -> a) -> m a
  modifyDict   :: (ConnServerDict -> ConnServerDict) -> m ()
  putDict      :: ConnServerDict -> m ()
  saveChanServer :: m (Save.ChanSave (State, StateServer, ConnServerDict))
  liftIO       :: IO a -> m a

updateCopsDict :: MonadServerReadRequest m => KeyKind -> Config -> DebugModeCli -> m ()
updateCopsDict copsClient sconfig sdebugCli = do
  cops <- getsState scops
  schanF <- liftIO $ Frontend.chanFrontendIO sdebugCli
  let sbinding = stdBinding copsClient sconfig  -- evaluate to check for errors
      updFState :: (sess -> sess) -> CliState sess -> CliState sess
      updFState updSess cliS =
        cliS { cliState = updateCOps (const cops) $ cliState cliS
             , cliSession = updSess $ cliSession cliS }
      updSession sess = sess {schanF, sbinding}
      updFrozenClient :: FrozenClient -> FrozenClient
      updFrozenClient (FState mcUI cAI) =
        FState (updFState updSession <$> mcUI) (updFState id cAI)
      updFrozenClient (FThread mconnUI connAI) = FThread mconnUI connAI
  modifyDict $ EM.map updFrozenClient

sendUpdate :: MonadServerReadRequest m => FactionId -> UpdAtomic -> m ()
sendUpdate fid cmd = do
  frozenClient <- getsDict $ (EM.! fid)
  case frozenClient of
    FState mfUI cliState -> do
      let mAI = handleSelfAI cmd
      ((), newCliStateAI) <- liftIO $ runCli mAI cliState
      mnewCliStateUI <- case mfUI of
        Nothing -> return Nothing
        Just cliS -> do
          let mUI = handleSelfUI cmd
          ((), newCliState) <- liftIO $ runCli mUI cliS
          return $ Just newCliState
      modifyDict $ EM.insert fid (FState mnewCliStateUI newCliStateAI)
    FThread mconn conn -> do
      writeQueueAI (RespUpdAtomicAI cmd) $ responseS conn
      maybe (return ())
            (\c -> writeQueueUI (RespUpdAtomicUI cmd) $ responseS c) mconn

sendSfx :: MonadServerReadRequest m  => FactionId -> SfxAtomic -> m ()
sendSfx fid sfx = do
  frozenClient <- getsDict $ (EM.! fid)
  case frozenClient of
    FState (Just cliState) fAI -> do
      let m = displayRespSfxAtomicUI False sfx
      ((), newCliState) <- liftIO $ runCli m cliState
      modifyDict $ EM.insert fid (FState (Just newCliState) fAI)
    FThread (Just conn) _ ->
      writeQueueUI (RespSfxAtomicUI sfx) $ responseS conn
    _ -> return ()

sendQueryAI :: MonadServerReadRequest m => FactionId -> ActorId -> m RequestAI
sendQueryAI fid aid = do
  frozenClient <- getsDict $ (EM.! fid)
  req <- case frozenClient of
    FState fUI cliState -> do
      let m = queryAI
      (req, newCliState) <- liftIO $ runCli m cliState
      modifyDict $ EM.insert fid (FState fUI newCliState)
      return req
    FThread _ conn -> do
      writeQueueAI RespQueryAI $ responseS conn
      readQueueAI $ requestS conn
  debug <- getsServer $ sniffIn . sdebugSer
  when debug $ debugRequestAI aid req
  return req

sendNonLeaderQueryAI :: MonadServerReadRequest m
                     => FactionId -> ActorId -> m ReqAI
sendNonLeaderQueryAI fid aid = do
  frozenClient <- getsDict $ (EM.! fid)
  req <- case frozenClient of
    FState fUI cliState -> do
      let m = nonLeaderQueryAI aid
      (req, newCliState) <- liftIO $ runCli m cliState
      modifyDict $ EM.insert fid (FState fUI newCliState)
      return req
    FThread _ conn -> do
      writeQueueAI (RespNonLeaderQueryAI aid) $ responseS conn
      readQueueAI $ requestS conn
  case req of
    (_, Just{}) -> assert `failure` req
    (cmd, Nothing) -> do
      debug <- getsServer $ sniffIn . sdebugSer
      when debug $ debugRequestAI aid req
      return cmd

sendQueryUI :: (MonadAtomic m, MonadServerReadRequest m)
            => FactionId -> ActorId -> m RequestUI
sendQueryUI fid aid = do
  frozenClient <- getsDict $ (EM.! fid)
  req <- case frozenClient of
    FState (Just cliState) fAI -> do
      let m = queryUI
      (req, newCliState) <- liftIO $ runCli m cliState
      modifyDict $ EM.insert fid (FState (Just newCliState) fAI)
      return req
    FThread (Just conn) _ -> do
      writeQueueUI RespQueryUI $ responseS conn
      readQueueUI $ requestS conn
    _ -> assert `failure` "no channel for faction" `twith` fid
  debug <- getsServer $ sniffIn . sdebugSer
  when debug $ debugRequestUI aid req
  return req

killAllClients :: (MonadAtomic m, MonadServerReadRequest m) => m ()
killAllClients = do
  d <- getDict
  let sendKill fid _ =
        -- We can't check in sfactionD, because client can be from an old game.
        sendUpdate fid $ UpdKillExit fid
  mapWithKeyM_ sendKill d

-- Global variable for all children threads of the server.
childrenServer :: MVar [Async ()]
{-# NOINLINE childrenServer #-}
childrenServer = unsafePerformIO (newMVar [])

-- | Update connections to the new definition of factions.
-- Connect to clients in old or newly spawned threads
-- that read and write directly to the channels.
updateConn :: (MonadAtomic m, MonadServerReadRequest m)
           => Bool
           -> Kind.COps
           -> KeyKind -> Config -> DebugModeCli
           -> (SessionUI -> Kind.COps -> FactionId
               -> ChanServer ResponseUI RequestUI
               -> IO ())
           -> (Kind.COps -> FactionId
               -> ChanServer ResponseAI RequestAI
               -> IO ())
           -> m ()
updateConn useTreadsForNewClients cops copsClient sconfig sdebugCli
           executorUI executorAI = do
  -- Prepare connections based on factions.
  oldD <- getDict
  let mkChanServer :: IO (ChanServer resp req)
      mkChanServer = do
        responseS <- newQueue
        requestS <- newQueue
        return $! ChanServer{..}
      cliSession = emptySessionUI sconfig
      initStateUI fid = do
        let initCli = initialCliState cops cliSession fid
        snd <$> runCli (initUI copsClient sconfig sdebugCli) initCli
      initStateAI fid = do
        let initCli = initialCliState cops () fid
        snd <$> runCli (initAI sdebugCli) initCli
      addConn :: FactionId -> Faction -> IO FrozenClient
      addConn fid fact = case EM.lookup fid oldD of
        Just conns -> return conns  -- share old conns and threads
        Nothing | fhasUI $ gplayer fact ->
          if useTreadsForNewClients then do
            connS <- mkChanServer
            connAI <- mkChanServer
            return $! FThread (Just connS) connAI
          else do
            iUI <- initStateUI fid
            iAI <- initStateAI fid
            return $! FState (Just iUI) iAI
        Nothing ->
          if useTreadsForNewClients then do
            connAI <- mkChanServer
            return $! FThread Nothing connAI
          else do
            iAI <- initStateAI fid
            return $! FState Nothing iAI
  factionD <- getsState sfactionD
  d <- liftIO $ mapWithKeyM addConn factionD
  let newD = d `EM.union` oldD  -- never kill old clients
  putDict newD
  -- Spawn client threads.
  let toSpawn = newD EM.\\ oldD
  let forkUI fid connS =
        forkChild childrenServer $ executorUI cliSession cops fid connS
      forkAI fid connS =
        forkChild childrenServer $ executorAI cops fid connS
      forkClient fid (FThread mconnUI connAI) = do
        -- When a connection is reused, clients are not respawned,
        -- even if UI usage changes, but it works OK thanks to UI faction
        -- clients distinguished by positive FactionId numbers.
        forkAI fid connAI  -- AI clients always needed, e.g., for auto-explore
        maybe (return ()) (forkUI fid) mconnUI
      forkClient _ FState{} = return ()
  liftIO $ mapWithKeyM_ forkClient toSpawn
