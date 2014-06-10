{-# LANGUAGE DeriveGeneric #-}
-- | A set of atomic commands shared by client and server.
-- These are the largest building blocks that have no components
-- that can be observed in isolation.
--
-- We try to make atomic commands respect the laws of energy and mass
-- conservation, unless they really can't, e.g., monster spawning.
-- For example item removal from inventory is not an atomic command,
-- but item dropped from the inventory to the ground is. This makes
-- it easier to undo the commands. In principle, the commands are the only
-- way to affect the basic game state (@State@).
--
-- See
-- <https://github.com/kosmikus/LambdaHack/wiki/Client-server-architecture>.
module Game.LambdaHack.Atomic.CmdAtomic
  ( CmdAtomic(..), UpdAtomic(..), SfxAtomic(..), HitAtomic(..)
  , undoUpdAtomic, undoSfxAtomic, undoCmdAtomic
  ) where

import Data.Binary
import Data.Text (Text)
import GHC.Generics (Generic)

import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ClientOptions
import qualified Game.LambdaHack.Common.Color as Color
import qualified Game.LambdaHack.Common.Effect as Effect
import Game.LambdaHack.Common.Faction
import qualified Game.LambdaHack.Common.Feature as F
import Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Common.Perception
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.State
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Common.Vector
import Game.LambdaHack.Content.ItemKind as ItemKind
import Game.LambdaHack.Content.TileKind as TileKind

data CmdAtomic =
    UpdAtomic !UpdAtomic
  | SfxAtomic !SfxAtomic
  deriving (Show, Eq, Generic)

instance Binary CmdAtomic

-- | Abstract syntax of atomic commands.
data UpdAtomic =
  -- Create/destroy actors and items.
    UpdCreateActor !ActorId !Actor ![(ItemId, Item)]
  | UpdDestroyActor !ActorId !Actor ![(ItemId, Item)]
  | UpdCreateItem !ItemId !Item !KisOn !Container
  | UpdDestroyItem !ItemId !Item !KisOn !Container
  | UpdSpotActor !ActorId !Actor ![(ItemId, Item)]
  | UpdLoseActor !ActorId !Actor ![(ItemId, Item)]
  | UpdSpotItem !ItemId !Item !KisOn !Container
  | UpdLoseItem !ItemId !Item !KisOn !Container
  -- Move actors and items.
  | UpdMoveActor !ActorId !Point !Point
  | UpdWaitActor !ActorId !Bool
  | UpdDisplaceActor !ActorId !ActorId
  | UpdMoveItem !ItemId !Int !ActorId !CStore !Bool !CStore !Bool
  -- Change actor attributes.
  | UpdAgeActor !ActorId !(Delta Time)
  | UpdHealActor !ActorId !Int
  | UpdCalmActor !ActorId !Int
  | UpdHasteActor !ActorId !Speed
  | UpdOldFidActor !ActorId !FactionId !FactionId
  | UpdTrajectoryActor !ActorId !(Maybe [Vector]) !(Maybe [Vector])
  | UpdColorActor !ActorId !Color.Color !Color.Color
  -- Change faction attributes.
  | UpdQuitFaction !FactionId !(Maybe Actor) !(Maybe Status) !(Maybe Status)
  | UpdLeadFaction !FactionId !(Maybe ActorId) !(Maybe ActorId)
  | UpdDiplFaction !FactionId !FactionId !Diplomacy !Diplomacy
  | UpdAutoFaction !FactionId !Bool
  | UpdRecordKill !ActorId !Int
  -- Alter map.
  | UpdAlterTile !LevelId !Point !(Kind.Id TileKind) !(Kind.Id TileKind)
  | UpdAlterClear !LevelId !Int
  | UpdSearchTile !ActorId !Point !(Kind.Id TileKind) !(Kind.Id TileKind)
  | UpdSpotTile !LevelId ![(Point, Kind.Id TileKind)]
  | UpdLoseTile !LevelId ![(Point, Kind.Id TileKind)]
  | UpdAlterSmell !LevelId !Point !(Maybe Time) !(Maybe Time)
  | UpdSpotSmell !LevelId ![(Point, Time)]
  | UpdLoseSmell !LevelId ![(Point, Time)]
  -- Assorted.
  | UpdAgeGame !(Delta Time) ![LevelId]
  | UpdDiscover !LevelId !Point !ItemId !(Kind.Id ItemKind) !ItemSeed
  | UpdCover !LevelId !Point !ItemId !(Kind.Id ItemKind) !ItemSeed
  | UpdDiscoverKind !LevelId !Point !ItemId !(Kind.Id ItemKind)
  | UpdCoverKind !LevelId !Point !ItemId !(Kind.Id ItemKind)
  | UpdDiscoverSeed !LevelId !Point !ItemId !ItemSeed
  | UpdCoverSeed !LevelId !Point !ItemId !ItemSeed
  | UpdPerception !LevelId !Perception !Perception
  | UpdRestart !FactionId !Discovery !FactionPers !State !DebugModeCli !Text
  | UpdRestartServer !State
  | UpdResume !FactionId !FactionPers
  | UpdResumeServer !State
  | UpdKillExit !FactionId
  | UpdSaveBkp
  | UpdMsgAll !Msg
  | UpdRecordHistory !FactionId
  deriving (Show, Eq, Generic)

instance Binary UpdAtomic

data SfxAtomic =
    SfxStrike !ActorId !ActorId !ItemId !HitAtomic
  | SfxRecoil !ActorId !ActorId !ItemId !HitAtomic
  | SfxProject !ActorId !ItemId
  | SfxCatch !ActorId !ItemId
  | SfxActivate !ActorId !ItemId !KisOn !Bool
  | SfxCheck !ActorId !ItemId !KisOn !Bool
  | SfxTrigger !ActorId !Point !F.Feature
  | SfxShun !ActorId !Point !F.Feature
  | SfxEffect !FactionId !ActorId !(Effect.Effect Int)
  | SfxMsgFid !FactionId !Msg
  | SfxMsgAll !Msg
  | SfxActorStart !ActorId
  deriving (Show, Eq, Generic)

instance Binary SfxAtomic

data HitAtomic = Hit | HitBlock | MissBlock
  deriving (Show, Eq, Generic)

instance Binary HitAtomic

undoUpdAtomic :: UpdAtomic -> Maybe UpdAtomic
undoUpdAtomic cmd = case cmd of
  UpdCreateActor aid body ais -> Just $ UpdDestroyActor aid body ais
  UpdDestroyActor aid body ais -> Just $ UpdCreateActor aid body ais
  UpdCreateItem iid item kIsOn c -> Just $ UpdDestroyItem iid item kIsOn c
  UpdDestroyItem iid item kIsOn c -> Just $ UpdCreateItem iid item kIsOn c
  UpdSpotActor aid body ais -> Just $ UpdLoseActor aid body ais
  UpdLoseActor aid body ais -> Just $ UpdSpotActor aid body ais
  UpdSpotItem iid item kIsOn c -> Just $ UpdLoseItem iid item kIsOn c
  UpdLoseItem iid item kIsOn c -> Just $ UpdSpotItem iid item kIsOn c
  UpdMoveActor aid fromP toP -> Just $ UpdMoveActor aid toP fromP
  UpdWaitActor aid toWait -> Just $ UpdWaitActor aid (not toWait)
  UpdDisplaceActor source target -> Just $ UpdDisplaceActor target source
  UpdMoveItem iid k aid c1 isOn1 c2 isOn2 ->
    Just $ UpdMoveItem iid k aid c2 isOn2 c1 isOn1
  UpdAgeActor aid delta -> Just $ UpdAgeActor aid (timeDeltaReverse delta)
  UpdHealActor aid n -> Just $ UpdHealActor aid (-n)
  UpdCalmActor aid n -> Just $ UpdCalmActor aid (-n)
  UpdHasteActor aid delta -> Just $ UpdHasteActor aid (speedNegate delta)
  UpdOldFidActor aid fromFid toFid -> Just $ UpdOldFidActor aid toFid fromFid
  UpdTrajectoryActor aid fromT toT -> Just $ UpdTrajectoryActor aid toT fromT
  UpdColorActor aid fromCol toCol -> Just $ UpdColorActor aid toCol fromCol
  UpdQuitFaction fid mb fromSt toSt -> Just $ UpdQuitFaction fid mb toSt fromSt
  UpdLeadFaction fid source target -> Just $ UpdLeadFaction fid target source
  UpdDiplFaction fid1 fid2 fromDipl toDipl ->
    Just $ UpdDiplFaction fid1 fid2 toDipl fromDipl
  UpdAutoFaction fid st -> Just $ UpdAutoFaction fid (not st)
  UpdRecordKill aid k -> Just $ UpdRecordKill aid (-k)
  UpdAlterTile lid p fromTile toTile ->
    Just $ UpdAlterTile lid p toTile fromTile
  UpdAlterClear lid delta -> Just $ UpdAlterClear lid (-delta)
  UpdSearchTile aid p fromTile toTile ->
    Just $ UpdSearchTile aid p toTile fromTile
  UpdSpotTile lid ts -> Just $ UpdLoseTile lid ts
  UpdLoseTile lid ts -> Just $ UpdSpotTile lid ts
  UpdAlterSmell lid p fromSm toSm -> Just $ UpdAlterSmell lid p toSm fromSm
  UpdSpotSmell lid sms -> Just $ UpdLoseSmell lid sms
  UpdLoseSmell lid sms -> Just $ UpdSpotSmell lid sms
  UpdAgeGame delta lids -> Just $ UpdAgeGame (timeDeltaReverse delta) lids
  UpdDiscover lid p iid ik seed -> Just $ UpdCover lid p iid ik seed
  UpdCover lid p iid ik seed -> Just $ UpdDiscover lid p iid ik seed
  UpdDiscoverKind lid p iid ik -> Just $ UpdCoverKind lid p iid ik
  UpdCoverKind lid p iid ik -> Just $ UpdDiscoverKind lid p iid ik
  UpdDiscoverSeed lid p iid seed -> Just $ UpdCoverSeed lid p iid seed
  UpdCoverSeed lid p iid seed -> Just $ UpdDiscoverSeed lid p iid seed
  UpdPerception lid outPer inPer -> Just $ UpdPerception lid inPer outPer
  UpdRestart{} -> Just cmd  -- here history ends; change direction
  UpdRestartServer{} -> Just cmd  -- here history ends; change direction
  UpdResume{} -> Nothing
  UpdResumeServer{} -> Nothing
  UpdKillExit{} -> Nothing
  UpdSaveBkp -> Nothing
  UpdMsgAll{} -> Nothing  -- only generated by @cmdAtomicFilterCli@
  UpdRecordHistory{} -> Just cmd

undoSfxAtomic :: SfxAtomic -> SfxAtomic
undoSfxAtomic cmd = case cmd of
  SfxStrike source target iid b -> SfxRecoil source target iid b
  SfxRecoil source target iid b -> SfxStrike source target iid b
  SfxProject aid iid -> SfxCatch aid iid
  SfxCatch aid iid -> SfxProject aid iid
  SfxActivate aid iid kIsOn isOn -> SfxCheck aid iid kIsOn isOn
  SfxCheck aid iid kIsOn isOn -> SfxActivate aid iid kIsOn isOn
  SfxTrigger aid p feat -> SfxShun aid p feat
  SfxShun aid p feat -> SfxTrigger aid p feat
  SfxEffect{} -> cmd  -- not ideal?
  SfxMsgFid{} -> cmd
  SfxMsgAll{} -> cmd
  SfxActorStart{} -> cmd

undoCmdAtomic :: CmdAtomic -> Maybe CmdAtomic
undoCmdAtomic (UpdAtomic cmd) = fmap UpdAtomic $ undoUpdAtomic cmd
undoCmdAtomic (SfxAtomic sfx) = Just $ SfxAtomic $ undoSfxAtomic sfx
