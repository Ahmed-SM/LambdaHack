-- | Here the knot of engine code pieces, frontend and the game-specific
-- content definitions is tied, resulting in an executable game.
module Implementation.TieKnot
  ( tieKnotForAsync, tieKnot
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import           Control.Concurrent
import           Control.Concurrent.Async
import qualified Control.Exception as Ex
import qualified System.Random as R

import           Game.LambdaHack.Client
import qualified Game.LambdaHack.Client.UI.Content.Input as IC
import qualified Game.LambdaHack.Client.UI.Content.Screen as SC
import           Game.LambdaHack.Client.UI.ContentClientUI
import qualified Game.LambdaHack.Common.ItemAspect as IA
import           Game.LambdaHack.Common.Kind
import           Game.LambdaHack.Common.Misc
import           Game.LambdaHack.Common.Point
import qualified Game.LambdaHack.Common.Tile as Tile
import qualified Game.LambdaHack.Content.CaveKind as CK
import qualified Game.LambdaHack.Content.ItemKind as IK
import qualified Game.LambdaHack.Content.ModeKind as MK
import qualified Game.LambdaHack.Content.PlaceKind as PK
import qualified Game.LambdaHack.Content.RuleKind as RK
import qualified Game.LambdaHack.Content.TileKind as TK
import           Game.LambdaHack.Server

import qualified Client.UI.Content.Input as Content.Input
import qualified Client.UI.Content.Screen as Content.Screen
import qualified Content.CaveKind
import qualified Content.ItemKind
import qualified Content.ModeKind
import qualified Content.PlaceKind
import qualified Content.RuleKind
import qualified Content.TileKind
import           Implementation.MonadServerImplementation (executorSer)

-- | Tie the LambdaHack engine client, server and frontend code
-- with the game-specific content definitions, and run the game.
--
-- The custom monad types to be used are determined by the 'executorSer'
-- call, which in turn calls 'executorCli'. If other functions are used
-- in their place- the types are different and so the whole pattern
-- of computation differs. Which of the frontends is run inside the UI client
-- depends on the flags supplied when compiling the engine library.
-- Similarly for the choice of native vs JS builds.
tieKnotForAsync :: ServerOptions -> IO ()
tieKnotForAsync options@ServerOptions{ sallClear
                                     , sboostRandomItem
                                     , sdungeonRng } = do
  -- Verify the hack ASAP in case points are used soon.
  let !_A = assert (speedupHackXSize
                    == RK.rXmax (Content.RuleKind.standardRules)) ()
  -- This setup ensures the boosting option doesn't affect generating initial
  -- RNG for dungeon, etc., and also, that setting dungeon RNG on commandline
  -- equal to what was generated last time, ensures the same item boost.
  initialGen <- maybe R.getStdGen return sdungeonRng
  let soptionsNxt = options {sdungeonRng = Just initialGen}
      boostedItems = IK.boostItemKindList initialGen Content.ItemKind.items
      coitem = IK.makeData $
        if sboostRandomItem
        then boostedItems ++ Content.ItemKind.otherItemContent
        else Content.ItemKind.content
      coItemSpeedup = IA.speedupItem coitem
      cotile = TK.makeData coitem Content.TileKind.content
      coTileSpeedup = Tile.speedupTile sallClear cotile
      coplace = PK.makeData cotile Content.PlaceKind.content
      cocave = CK.makeData coitem coplace cotile Content.CaveKind.content
      -- Common content operations, created from content definitions.
      -- Evaluated fully to discover errors ASAP and to free memory.
      -- Fail here, not inside server code, so that savefiles are not removed,
      -- because they are not the source of the failure.
      !cops = COps
        { cocave
        , coitem
        , comode  = MK.makeData cocave coitem Content.ModeKind.content
        , coplace
        , corule  = RK.makeData Content.RuleKind.standardRules
        , cotile
        , coItemSpeedup
        , coTileSpeedup
        }
      benchmark = sbenchmark $ sclientOptions soptionsNxt
  -- Parse UI client configuration file.
  -- It is reparsed at each start of the game executable.
  -- Fail here, not inside client code, so that savefiles are not removed,
  -- because they are not the source of the failure.
  sUIOptions <- mkUIOptions cops benchmark
  -- Client content operations containing default keypresses
  -- and command descriptions.
  let !ccui = CCUI
        { coinput = IC.makeData sUIOptions Content.Input.standardKeysAndMouse
        , coscreen = SC.makeData Content.Screen.standardLayoutAndFeatures
        }
  -- Wire together game content, the main loops of game clients
  -- and the game server loop.
  executorSer cops ccui soptionsNxt sUIOptions

-- | Runs tieKnotForAsync in an async and applies the main thread workaround.
tieKnot :: ServerOptions -> IO ()
tieKnot serverOptions = do
#ifndef USE_JSFILE
  let fillWorkaround =
        -- Set up void workaround if nothing specific required.
        void $ tryPutMVar workaroundOnMainThreadMVar $ return ()
#endif
  -- Avoid the bound thread that would slow down the communication.
  a <- async $ tieKnotForAsync serverOptions
#ifndef USE_JSFILE
               `Ex.finally` fillWorkaround
  link a
  -- Run a (possibly void) workaround. It's needed for OSes/frontends
  -- that need to perform some actions on the main thread
  -- (not just any bound thread), e.g., newer OS X drawing with SDL2.
  workaround <- takeMVar workaroundOnMainThreadMVar
  workaround
#endif
  wait a
