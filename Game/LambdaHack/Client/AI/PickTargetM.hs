{-# LANGUAGE TupleSections #-}
-- | Let AI pick the best target for an actor.
module Game.LambdaHack.Client.AI.PickTargetM
  ( refreshTarget
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , computeTarget
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES

import           Game.LambdaHack.Client.AI.ConditionM
import           Game.LambdaHack.Client.Bfs
import           Game.LambdaHack.Client.BfsM
import           Game.LambdaHack.Client.CommonM
import           Game.LambdaHack.Client.MonadClient
import           Game.LambdaHack.Client.State
import qualified Game.LambdaHack.Common.Ability as Ability
import           Game.LambdaHack.Common.Actor
import           Game.LambdaHack.Common.ActorState
import           Game.LambdaHack.Common.Faction
import           Game.LambdaHack.Common.Frequency
import           Game.LambdaHack.Common.Item
import           Game.LambdaHack.Common.Kind
import           Game.LambdaHack.Common.Level
import           Game.LambdaHack.Common.MonadStateRead
import           Game.LambdaHack.Common.Point
import qualified Game.LambdaHack.Common.PointArray as PointArray
import           Game.LambdaHack.Common.Random
import           Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import           Game.LambdaHack.Common.Time
import           Game.LambdaHack.Common.Vector
import           Game.LambdaHack.Content.ModeKind
import           Game.LambdaHack.Content.RuleKind
import           Game.LambdaHack.Content.TileKind (isUknownSpace)

-- | Verify and possibly change the target of an actor. This function both
-- updates the target in the client state and returns the new target explicitly.
refreshTarget :: MonadClient m => (ActorId, Actor) -> m (Maybe TgtAndPath)
-- This inline speeds up execution by 5% and decreases allocation by 10%,
-- despite probably bloating executable:
{-# INLINE refreshTarget #-}
refreshTarget (aid, body) = do
  side <- getsClient sside
  let !_A = assert (bfid body == side
                    `blame` "AI tries to move an enemy actor"
                    `swith` (aid, body, side)) ()
  let !_A = assert (not (bproj body)
                    `blame` "AI gets to manually move its projectiles"
                    `swith` (aid, body, side)) ()
  mtarget <- computeTarget aid
  case mtarget of
    Nothing -> do
      -- Melee in progress and the actor can't contribute
      -- and would slow down others if he acted.
      modifyClient $ \cli -> cli {stargetD = EM.delete aid (stargetD cli)}
      return Nothing
    Just tgtMPath -> do
      -- _debugoldTgt <- getsClient $ EM.lookup aid . stargetD
      -- Choose a target from those proposed by AI for the actor.
      modifyClient $ \cli ->
        cli {stargetD = EM.insert aid tgtMPath (stargetD cli)}
      return mtarget
      -- let _debug = T.unpack
      --       $ "\nHandleAI symbol:"    <+> tshow (bsymbol body)
      --       <> ", aid:"               <+> tshow aid
      --       <> ", pos:"               <+> tshow (bpos body)
      --       <> "\nHandleAI oldTgt:"   <+> tshow _debugoldTgt
      --       <> "\nHandleAI strTgt:"   <+> tshow stratTarget
      --       <> "\nHandleAI target:"   <+> tshow tgtMPath
      -- trace _debug $ return $ Just tgtMPath

computeTarget :: forall m. MonadClient m => ActorId -> m (Maybe TgtAndPath)
{-# INLINE computeTarget #-}
computeTarget aid = do
  cops@COps{corule=RuleContent{rXmax, rYmax, rnearby}, coTileSpeedup}
    <- getsState scops
  b <- getsState $ getActorBody aid
  mleader <- getsClient sleader
  salter <- getsClient salter
  -- We assume the actor eventually becomes a leader (or has the same
  -- set of skills as the leader, anyway) and set his target accordingly.
  actorMaxSkills <- getsState sactorMaxSkills
  condInMelee <- condInMeleeM $ blid b
  let lalter = salter EM.! blid b
      actorMaxSk = actorMaxSkills EM.! aid
      alterSkill = Ability.getSk Ability.SkAlter actorMaxSk
  lvl <- getLevel $ blid b
  let stepAccesible :: AndPath -> Bool
      stepAccesible AndPath{pathList=q : _} =
        -- Effectively, only @alterMinWalk@ is checked, because real altering
        -- is not done via target path, but action after end of path.
        alterSkill >= fromEnum (lalter PointArray.! q)
      stepAccesible _ = False
  mtgtMPath <- getsClient $ EM.lookup aid . stargetD
  oldTgtUpdatedPath <- case mtgtMPath of
    Just TgtAndPath{tapTgt,tapPath=NoPath} ->
      -- This case is especially for TEnemyPos that would be lost otherwise.
      -- This is also triggered by @UpdLeadFaction@.
      Just <$> createPath aid tapTgt
    Just tap@TgtAndPath{..} -> do
      mvalidPos <- getsState $ aidTgtToPos aid (blid b) tapTgt
      if | isNothing mvalidPos -> return Nothing  -- wrong level
         | bpos b == pathGoal tapPath ->
             return mtgtMPath  -- goal reached; stay there picking up items
         | otherwise -> return $! case tapPath of
             AndPath{..} | pathSource == bpos b ->  -- no move
               -- If next step not accessible, something serious happened,
               -- so reconsider the target, not only path.
               if stepAccesible tapPath then mtgtMPath else Nothing
             AndPath{..} -> case break (== bpos b) pathList of
               (crossed, _ : rest) ->  -- step or many steps along path
                 if null rest
                 then Nothing  -- path to the goal was partial, so tiles
                               -- discovered or altered, so reconsider target
                 else let newPath =
                            AndPath{ pathSource = bpos b
                                   , pathList = rest
                                   , pathGoal
                                   , pathLen = pathLen - length crossed - 1 }
                      in if stepAccesible newPath
                         then Just tap{tapPath=newPath}
                         else Nothing
               (_, []) -> Nothing  -- veered off the path, e.g., due to push
                                   -- by enemy or congestion, so serious,
                                   -- so reconsider target, not only path
             NoPath -> error $ "" `showFailure` tap
    Nothing -> return Nothing  -- no target assigned yet
  fact <- getsState $ (EM.! bfid b) . sfactionD
  allFoes <- getsState $ foeRegularAssocs (bfid b) (blid b)
  let canMove = Ability.getSk Ability.SkMove actorMaxSk > 0
                || Ability.getSk Ability.SkDisplace actorMaxSk > 0
                -- Needed for now, because AI targets and shoots enemies
                -- based on the path to them, not LOS to them:
                || Ability.getSk Ability.SkProject actorMaxSk > 0
      canAlterLabyrinth = Ability.getSk Ability.SkAlter actorMaxSk >= 4
  actorMinSk <- getsState $ actorCurrentSkills Nothing aid
  condCanProject <-
    condCanProjectM (Ability.getSk Ability.SkProject actorMaxSk) aid
  let condCanMelee = actorCanMelee actorMaxSkills aid b
      condHpTooLow = hpTooLow b actorMaxSk
  friends <- getsState $ friendRegularList (bfid b) (blid b)
  let canEscape = fcanEscape (gplayer fact)
      canSmell = Ability.getSk Ability.SkSmell actorMaxSk > 0
      meleeNearby | canEscape = rnearby `div` 2
                  | otherwise = rnearby
      rangedNearby = 2 * meleeNearby
      -- Don't melee-target inherently nonmoving actors (not due to sleep
      -- and not if they are particularly aggresive),
      -- unless they attack ours, because nonmoving can't be lured
      -- nor ambushed nor can chase us.
      -- This is especially important for fences, tower defense actors, etc.
      -- If content gives nonmoving actor loot, this becomes problematic,
      -- so such actors should be made aggressive.
      -- Human players may also choose not to wake up sleeping actors,
      -- but deciding if they are likely to wake up on their own later on
      -- and if they have decent loot per risk ratio is too difficult for AI.
      targetableMelee aidE body = do
        actorMaxSkE <- getsState $ getActorMaxSkills aidE
        let attacksFriends = any (adjacent (bpos body) . bpos) friends
            -- 3 is
            -- 1 from condSupport1
            -- + 2 from foe being 2 away from friend before he closed in
            -- + 1 for as a margin for ambush, given than actors exploring
            -- can't physically keep adjacent all the time
            n | Ability.getSk Ability.SkAggression actorMaxSk >= 2
              = rangedNearby
                  -- boss never waits
              | condInMelee = if attacksFriends then 4 else 2
                  -- attack even if foe not in melee, to create another
                  -- skirmish and perhaps overwhelm them in this one;
                  -- also, this looks more natural; also sometimes the foe
                  -- would attack our friend in a couple of turns anyway,
                  -- but we may be too far from him at that time
              | otherwise = meleeNearby
            nonmoving = Ability.getSk Ability.SkMove actorMaxSkE <= 0
                        && bwatch body `notElem` [WSleep, WWake]
                             -- exploit sleep weakness
                        && Ability.getSk Ability.SkAggression actorMaxSkE < 2
                             -- react to provocation
        return {-keep lazy-} $
          case chessDist (bpos body) (bpos b) of
            1 -> True  -- if adjacent, target even if can't melee, to flee
            cd -> condCanMelee && cd <= n && (not nonmoving || attacksFriends)
      -- Even when missiles run out, the non-moving foe will still be
      -- targeted, which is fine, since he is weakened by ranged, so should be
      -- meleed ASAP, even if without friends.
      targetableRanged body =
        (not condInMelee || Ability.getSk Ability.SkAggression actorMaxSk >= 2)
          -- boss fires at will
        && chessDist (bpos body) (bpos b) < rangedNearby
        && condCanProject
      targetableEnemy (aidE, body) = do
        tMelee <- targetableMelee aidE body
        return $! targetableRanged body || tMelee
  nearbyFoes <- filterM targetableEnemy allFoes
  discoBenefit <- getsClient sdiscoBenefit
  fleeD <- getsClient sfleeD
  getKind <- getsState $ flip getIidKind
  getArItem <- getsState $ flip aspectRecordFromIid
  let desirableIid (iid, (k, _)) =
        let Benefit{benPickup} = discoBenefit EM.! iid
        in desirableItem cops canEscape benPickup
                         (getArItem iid) (getKind iid) k
      desirableBagFloor bag = any desirableIid $ EM.assocs bag
      desirableFloor (_, (_, bag)) = desirableBagFloor bag
      focused = gearSpeed actorMaxSk < speedWalk || condHpTooLow
      couldMoveLastTurn =
        let actorSk = if mleader == Just aid then actorMaxSk else actorMinSk
        in Ability.getSk Ability.SkMove actorSk > 0
      isStuck = waitedLastTurn b && couldMoveLastTurn
      slackTactic =
        ftactic (gplayer fact)
          `elem` [ Ability.TMeleeAndRanged, Ability.TMeleeAdjacent
                 , Ability.TBlock, Ability.TRoam, Ability.TPatrol ]
      setPath :: Target -> m (Maybe TgtAndPath)
      setPath tgt = do
        let take7 tap@TgtAndPath{tapTgt=TEnemy{}} =
              tap  -- @TEnemy@ needed for projecting, even by roaming actors
            take7 tap@TgtAndPath{tapPath=AndPath{..}} =
              -- Best path only followed 7 moves; then straight on. Cheaper.
              let path7 = take 7 pathList
                  vOld = towards (bpos b) pathGoal
                  pNew = shiftBounded rXmax rYmax (bpos b) vOld
                  walkable = Tile.isWalkable coTileSpeedup $ lvl `at` pNew
                  tapTgt = TVector vOld
              in if bpos b == pathGoal  -- goal reached, so better know the tgt
                    || not walkable  -- can't walk, so don't chase a vector
                 then tap
                 else TgtAndPath{tapTgt, tapPath=AndPath{pathList=path7, ..}}
            take7 tap = tap
        tgtpath <- createPath aid tgt
        return $ Just $ if slackTactic then take7 tgtpath else tgtpath
      pickNewTarget = pickNewTargetIgnore Nothing
      pickNewTargetIgnore :: Maybe ActorId -> m (Maybe TgtAndPath)
      pickNewTargetIgnore maidToIgnore = do
        let f aidToIgnore = filter ((/= aidToIgnore) . fst) nearbyFoes
            notIgnoredFoes = maybe nearbyFoes f maidToIgnore
        cfoes <- closestFoes notIgnoredFoes aid
        case cfoes of
          (_, (aid2, _)) : _ -> setPath $ TEnemy aid2 False
          [] | condInMelee -> return Nothing  -- don't slow down fighters
            -- this looks a bit strange, because teammates stop in their tracks
            -- all around the map (unless very close to the combatant),
            -- but the intuition is, not being able to help immediately,
            -- and not being too friendly to each other, they just wait and see
            -- and also shout to the teammate to flee and lure foes into ambush
          [] -> do
            citemsRaw <- closestItems aid
            let citems = toFreq "closestItems"
                         $ filter desirableFloor citemsRaw
            if nullFreq citems then do
              ctriggersRaw <- closestTriggers ViaAnything aid
              let ctriggers = toFreq "ctriggers" ctriggersRaw
              if nullFreq ctriggers then do
                -- Tracking enemies is more important than exploring, but smell
                -- is unreliable and may lead to allies, not foes, so avoid it.
                smpos <- if canSmell
                         then closestSmell aid
                         else return []
                case smpos of
                  [] -> do
                    let vToTgt v0 = do
                          let vFreq = toFreq "vFreq"
                                      $ (20, v0) : map (1,) moves
                          v <- rndToAction $ frequency vFreq
                          -- Items and smells, etc. considered every 7 moves.
                          let pathSource = bpos b
                              tra = trajectoryToPathBounded
                                      rXmax rYmax pathSource (replicate 7 v)
                              pathList = nub tra
                              pathGoal = last pathList
                              pathLen = length pathList
                          return $ Just $
                            TgtAndPath
                              { tapTgt = TVector v
                              , tapPath = if pathLen == 0
                                          then NoPath
                                          else AndPath{..} }
                        oldpos = fromMaybe originPoint (boldpos b)
                        vOld = bpos b `vectorToFrom` oldpos
                        pNew = shiftBounded rXmax rYmax (bpos b) vOld
                    if slackTactic && not isStuck
                       && isUnit vOld && bpos b /= pNew
                       && Tile.isWalkable coTileSpeedup (lvl `at` pNew)
                    then vToTgt vOld
                    else do
                      upos <- closestUnknown aid
                      case upos of
                        Nothing -> do
                          -- If can't move (i.e., no Bfs data), no info gained.
                          -- Or if can't alter and possibly stuck among rubble.
                          when (canMove && canAlterLabyrinth) $
                            modifyClient $ \cli -> cli {sexplored =
                              ES.insert (blid b) (sexplored cli)}
                          ctriggersRaw2 <- closestTriggers ViaExit aid
                          let ctriggers2 = toFreq "ctriggers2" ctriggersRaw2
                          if nullFreq ctriggers2 then do
                            afoes <- closestFoes allFoes aid
                            case afoes of
                              (_, (aid2, _)) : _ ->
                                -- All stones turned, time to win or die.
                                setPath $ TEnemy aid2 False
                              [] -> do
                                furthest <- furthestKnown aid
                                setPath $ TPoint TKnown (blid b) furthest
                          else do
                            (p, (p0, bag)) <- rndToAction $ frequency ctriggers2
                            setPath $ TPoint (TEmbed bag p0) (blid b) p
                        Just p -> setPath $ TPoint TUnknown (blid b) p
                  (_, (p, _)) : _ -> setPath $ TPoint TSmell (blid b) p
              else do
                (p, (p0, bag)) <- rndToAction $ frequency ctriggers
                setPath $ TPoint (TEmbed bag p0) (blid b) p
            else do
              (p, bag) <- rndToAction $ frequency citems
              setPath $ TPoint (TItem bag) (blid b) p
      tellOthersNothingHere pos = do
        let f TgtAndPath{tapTgt} = case tapTgt of
              TPoint _ lid p -> p /= pos || lid /= blid b
              _ -> True
        modifyClient $ \cli -> cli {stargetD = EM.filter f (stargetD cli)}
        pickNewTarget
      followingWrong permit =
        permit && (condInMelee  -- in melee, stop following
                   || mleader == Just aid)  -- a leader, never follow
      updateTgt :: TgtAndPath -> m (Maybe TgtAndPath)
      updateTgt TgtAndPath{tapPath=NoPath} = pickNewTarget
      updateTgt _ | EM.member aid fleeD = pickNewTarget
        -- forget enemy positions to prevent attacking them again soon
      updateTgt tap@TgtAndPath{tapPath=AndPath{..},tapTgt} = case tapTgt of
        TEnemy a permit -> do
          body <- getsState $ getActorBody a
          if | (condInMelee  -- fight close foes or nobody at all
                || not focused && not (null nearbyFoes))  -- prefers closer foes
               && a `notElem` map fst nearbyFoes  -- old one not close enough
               || blid body /= blid b  -- wrong level
               || actorDying body -> -- foe already dying
               pickNewTarget
             | followingWrong permit -> pickNewTarget
             | otherwise -> do
               -- If there are no unwalkable tiles on the path to enemy,
               -- he gets target @TEnemy@ and then, even if such tiles emerge,
               -- the target updated by his moves remains @TEnemy@.
               -- Conversely, he is stuck with @TBlock@ if initial target had
               -- unwalkable tiles, for as long as they remain. Harmless quirk.
               mpath <- getCachePath aid $ bpos body
               case mpath of
                 NoPath -> pickNewTargetIgnore (Just a)
                   -- enemy became unreachable
                 AndPath{pathList=[]} -> pickNewTargetIgnore (Just a)
                   -- he is his own enemy
                 AndPath{pathList= q : _} ->
                   -- If in melee and path blocked by actors (even proj.)
                   -- change target for this turn due to urgency.
                   -- Because of @condInMelee@ new target will be enemy,
                   -- if any other is left, or empty target.
                   -- If not in melee, keep target and consider your options
                   -- (wait until blocking actors move or displace or melee).
                   -- We don't want to wander away in search of loot, only to
                   -- turn around next turn when the enemy is again considered.
                   if not condInMelee || not (occupiedBigLvl q lvl)
                                         && not (occupiedProjLvl q lvl)
                   then return $ Just tap{tapPath=mpath}
                   else pickNewTargetIgnore (Just a)
          -- In this case, need to retarget, to focus on foes that melee ours
          -- and not, e.g., on remembered foes or items.
        _ | condInMelee -> pickNewTarget
        TPoint _ lid _ | lid /= blid b -> pickNewTarget  -- wrong level
        TPoint tgoal lid pos -> case tgoal of
          TEnemyPos _ permit  -- chase last position even if foe hides
            | bpos b == pos -> tellOthersNothingHere pos
            | followingWrong permit -> pickNewTarget
            | otherwise -> do
              -- Here pick the closer enemy, remembered or seen, to avoid
              -- loops when approaching new enemy obscures him behind obstacle
              -- but reveals the previously remembered one, etc.
              let remainingDist = chessDist (bpos b) pos
              if any (\(_, b3) -> chessDist (bpos b) (bpos b3) < remainingDist)
                     nearbyFoes
              then pickNewTarget
              else return $ Just tap
          _ | not $ null nearbyFoes ->
            pickNewTarget  -- prefer close foes to anything else
          -- Below we check the target could not be picked again in
          -- pickNewTarget (e.g., an item got picked up by our teammate)
          -- and only in this case it is invalidated.
          -- This ensures targets are eventually reached (unless a foe
          -- shows up) and not changed all the time mid-route
          -- to equally interesting, but perhaps a bit closer targets,
          -- most probably already targeted by other actors.
          TEmbed bag p -> assert (adjacent pos p) $ do
            -- First, stairs and embedded items from @closestTriggers@.
            -- We don't check skills, because they normally don't change
            -- or we can put some equipment back and recover them.
            -- We don't determine if the stairs or embed are interesting
            -- (this changes with time), but allow the actor
            -- to reach them and then retarget. The two things we check
            -- is whether the embedded bag is still there, or used up
            -- and whether we happen to be already adjacent to @p@,
            -- even though not necessarily at @pos@.
            bag2 <- getsState $ getEmbedBag lid p  -- not @pos@
            if | bag /= bag2 -> pickNewTarget  -- others will notice soon enough
               | adjacent (bpos b) p ->  -- regardless if at @pos@ or not
                   setPath $ TPoint TAny lid (bpos b)
                     -- stay there one turn (high chance to become leader)
                     -- to enable triggering; if trigger fails
                     -- (e.g, changed skills), will retarget next turn (@TAny@)
               | otherwise -> return $ Just tap
          TItem bag -> do
            bag2 <- getsState $ getFloorBag lid pos
            if | bag /= bag2 -> pickNewTarget  -- others will notice soon enough
               | bpos b == pos ->
                   setPath $ TPoint TAny lid (bpos b)
                     -- stay there one turn (high chance to become leader)
                     -- to enable pickup; if pickup fails, will retarget
               | otherwise -> return $ Just tap
          TSmell ->
            if not canSmell
               || let sml = EM.findWithDefault timeZero pos (lsmell lvl)
                  in sml <= ltime lvl
            then pickNewTarget  -- others will notice soon enough
            else return $ Just tap
          TBlock -> do  -- e.g., door or first unknown tile of an area
            let t = lvl `at` pos
            if isStuck  -- not a very important target, because blocked
               || alterSkill < fromEnum (lalter PointArray.! pos)
                    -- tile was searched or altered or skill lowered
               || Tile.isWalkable coTileSpeedup t
                    -- tile is no longer unwalkable, so was explored
                    -- so time to recalculate target
            then pickNewTarget  -- others will notice soon enough
            else return $ Just tap
          TUnknown ->
            let t = lvl `at` pos
            in if lexpl lvl <= lseen lvl
                  || not (isUknownSpace t)
               then pickNewTarget  -- others will notice soon enough
               else return $ Just tap
          TKnown ->
            if bpos b == pos
               || isStuck
               || alterSkill < fromEnum (lalter PointArray.! pos)
                    -- tile was searched or altered or skill lowered
            then pickNewTarget  -- others unconcerned
            else return $ Just tap
          TAny -> pickNewTarget  -- reset elsewhere or carried over from UI
        TVector{} -> if pathLen > 1
                     then return $ Just tap
                     else pickNewTarget
  if canMove
  then case oldTgtUpdatedPath of
    Nothing -> pickNewTarget
    Just tap -> updateTgt tap
  else return $ Just $ TgtAndPath (TPoint TAny (blid b) (bpos b)) NoPath
