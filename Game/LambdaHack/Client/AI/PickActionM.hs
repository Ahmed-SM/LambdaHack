-- | AI procedure for picking the best action for an actor.
module Game.LambdaHack.Client.AI.PickActionM
  ( pickAction
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , actionStrategy, waitBlockNow, yellNow
  , pickup, equipItems, yieldUnneeded, unEquipItems
  , groupByEqpSlot, bestByEqpSlot, harmful, meleeBlocker, meleeAny
  , trigger, projectItem, ApplyItemGroup, applyItem, flee
  , displaceFoe, displaceBlocker, displaceTgt
  , chase, moveTowards, moveOrRunAid
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import           Data.Either
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import           Data.Function
import           Data.Ord (comparing)
import           Data.Ratio

import           Game.LambdaHack.Client.AI.ConditionM
import           Game.LambdaHack.Client.AI.Strategy
import           Game.LambdaHack.Client.Bfs
import           Game.LambdaHack.Client.BfsM
import           Game.LambdaHack.Client.CommonM
import           Game.LambdaHack.Client.MonadClient
import           Game.LambdaHack.Client.Request
import           Game.LambdaHack.Client.State
import           Game.LambdaHack.Common.Ability
import qualified Game.LambdaHack.Common.Ability as Ability
import           Game.LambdaHack.Common.Actor
import           Game.LambdaHack.Common.ActorState
import           Game.LambdaHack.Common.Container
import           Game.LambdaHack.Common.Faction
import           Game.LambdaHack.Common.Frequency
import           Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.ItemAspect as IA
import           Game.LambdaHack.Common.Kind
import           Game.LambdaHack.Common.Level
import           Game.LambdaHack.Common.Misc
import           Game.LambdaHack.Common.MonadStateRead
import           Game.LambdaHack.Common.Point
import qualified Game.LambdaHack.Common.PointArray as PointArray
import           Game.LambdaHack.Common.Random
import           Game.LambdaHack.Common.ReqFailure
import           Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import           Game.LambdaHack.Common.Time
import           Game.LambdaHack.Common.Vector
import qualified Game.LambdaHack.Content.ItemKind as IK
import           Game.LambdaHack.Content.ModeKind

-- | Pick the most desirable AI ation for the actor.
pickAction :: MonadClient m
           => Maybe ActorId -> ActorId -> Bool -> m RequestTimed
{-# INLINE pickAction #-}
pickAction moldLeader aid retry = do
  side <- getsClient sside
  body <- getsState $ getActorBody aid
  let !_A = assert (bfid body == side
                    `blame` "AI tries to move enemy actor"
                    `swith` (aid, bfid body, side)) ()
  let !_A = assert (not (bproj body)
                    `blame` "AI gets to manually move its projectiles"
                    `swith` (aid, bfid body, side)) ()
  -- Reset fleeing flag. May then be set in @flee@.
  modifyClient $ \cli -> cli {sfleeD = EM.delete aid (sfleeD cli)}
  stratAction <- actionStrategy moldLeader aid retry
  let bestAction = bestVariant stratAction
      !_A = assert (not (nullFreq bestAction)  -- equiv to nullStrategy
                    `blame` "no AI action for actor"
                    `swith` (stratAction, aid, body)) ()
  -- Run the AI: chose an action from those given by the AI strategy.
  rndToAction $ frequency bestAction

-- AI strategy based on actor's sight, smell, etc.
-- Never empty.
actionStrategy :: forall m. MonadClient m
               => Maybe ActorId -> ActorId -> Bool -> m (Strategy RequestTimed)
{-# INLINE actionStrategy #-}
actionStrategy moldLeader aid retry = do
  mleader <- getsClient sleader
  body <- getsState $ getActorBody aid
  condInMelee <- condInMeleeM $ blid body
  condAimEnemyPresent <- condAimEnemyPresentM aid
  condAimEnemyNoMelee <- condAimEnemyNoMeleeM aid
  condAimEnemyRemembered <- condAimEnemyRememberedM aid
  condAimCrucial <- condAimCrucialM aid
  condAnyFoeAdj <- condAnyFoeAdjM aid
  threatDistL <- getsState $ meleeThreatDistList aid
  (fleeL, badVic) <- fleeList aid
  condSupport1 <- condSupport 1 aid
  condSupport3 <- condSupport 3 aid
  condSolo <- condSoloM aid  -- solo fighters aggresive
  canDeAmbientL <- getsState $ canDeAmbientList body
  actorSk <- currentSkillsClient aid
  condCanProject <- condCanProjectM (getSk SkProject actorSk) aid
  condAdjTriggerable <- condAdjTriggerableM aid
  condBlocksFriends <- condBlocksFriendsM aid
  condNoEqpWeapon <- condNoEqpWeaponM aid
  condEnoughGear <- condEnoughGearM aid
  condFloorWeapon <- condFloorWeaponM aid
  condDesirableFloorItem <- condDesirableFloorItemM aid
  condTgtNonmoving <- condTgtNonmovingM aid
  explored <- getsClient sexplored
  actorMaxSkills <- getsState sactorMaxSkills
  friends <- getsState $ friendRegularList (bfid body) (blid body)
  let anyFriendOnLevelAwake = any (\b ->
        bwatch b /= WSleep && bpos b /= bpos body) friends
      actorMaxSk = actorMaxSkills EM.! aid
      mayFallAsleep = not condAimEnemyRemembered
                      && mayContinueSleep
                      && canSleep actorSk
      mayContinueSleep = not condAimEnemyPresent
                         && not (hpFull body actorSk)
                         && not uneasy
                         && not condAnyFoeAdj
                         && anyFriendOnLevelAwake  -- friend guards the sleeper
      dozes = case bwatch body of
                WWait n -> n > 0
                _ -> False
              && mayFallAsleep
              && (Just aid /= mleader || maybe True (== aid) moldLeader)
                   -- perhaps waited last turn only due to not being a leader,
                   -- so dozing interrupted when becomes a leader
      lidExplored = ES.member (blid body) explored
      panicFleeL = fleeL ++ badVic
      condHpTooLow = hpTooLow body actorMaxSk
      heavilyDistressed =  -- actor hit by a proj or similarly distressed
        deltaSerious (bcalmDelta body)
      condNotCalmEnough = not (calmEnough body actorMaxSk)
      uneasy = heavilyDistressed || condNotCalmEnough
      speed1_5 = speedScale (3%2) (gearSpeed actorMaxSk)
      -- Max skills used, because we need to know if can melee as leader.
      condCanMelee = actorCanMelee actorMaxSkills aid body
      condMeleeBad = not ((condSolo || condSupport1) && condCanMelee)
      condThreat n = not $ null $ takeWhile ((<= n) . fst) threatDistL
      threatAdj = takeWhile ((== 1) . fst) threatDistL
      condManyThreatAdj = length threatAdj >= 2
      condFastThreatAdj =
        any (\(_, (aid2, _)) ->
              let ar2 = actorMaxSkills EM.! aid2
              in gearSpeed ar2 > speed1_5)
        threatAdj
      actorShines = Ability.getSk SkShine actorMaxSk > 0
      aCanDeLightL | actorShines = []
                   | otherwise = canDeAmbientL
      aCanDeLight = not $ null aCanDeLightL
      canFleeFromLight = not $ null $ aCanDeLightL `intersect` map snd fleeL
      abInMaxSkill sk = getSk sk actorMaxSk > 0
      runSkills = [SkMove, SkDisplace, SkAlter]
      stratToFreq :: Int
                  -> m (Strategy RequestTimed)
                  -> m (Frequency RequestTimed)
      stratToFreq scale mstrat = do
        st <- mstrat
        return $! if scale == 0
                  then mzero
                  else scaleFreq scale $ bestVariant st
      -- Order matters within the list, because it's summed with .| after
      -- filtering. Also, the results of prefix, distant and suffix
      -- are summed with .| at the end.
      prefix, suffix:: [([Skill], m (Strategy RequestTimed), Bool)]
      prefix =
        [ ( [SkApply]
          , applyItem aid ApplyFirstAid
          , not condAnyFoeAdj && condHpTooLow)
        , ( [SkAlter]
          , trigger aid ViaStairs
              -- explore next or flee via stairs, even if to wrong level;
              -- in the latter case, may return via different stairs later on
          , condAdjTriggerable && not condAimEnemyPresent
            && ((condNotCalmEnough || condHpTooLow)  -- flee
                && condMeleeBad && condThreat 1
                || (lidExplored || condEnoughGear)  -- explore
                   && not condDesirableFloorItem) )
        , ( [SkDisplace]
          , displaceFoe aid  -- only swap with an enemy to expose him
                             -- and only if a friend is blocked by us
          , condAnyFoeAdj && condBlocksFriends)  -- later checks foe eligible
        , ( [SkMoveItem]
          , pickup aid True
          , condNoEqpWeapon  -- we assume organ weapons usually inferior
            && condFloorWeapon && not condHpTooLow
            && abInMaxSkill SkMelee )
        , ( [SkAlter]
          , trigger aid ViaEscape
          , condAdjTriggerable && not condAimEnemyPresent
            && not condDesirableFloorItem )  -- collect the last loot
        , ( runSkills
          , flee aid fleeL
          , -- Flee either from melee, if our melee is bad and enemy close
            -- or from missiles, if hit and enemies are only far away,
            -- can fling at us and we can't well fling at them.
            not condFastThreatAdj
            && if | condThreat 1 ->
                    -- Here we don't check @condInMelee@ because regardless
                    -- of whether our team melees (including the fleeing ones),
                    -- endangered actors should flee from very close foes.
                    not condCanMelee
                    || condManyThreatAdj && not condSupport1 && not condSolo
                  | not condInMelee
                    && (condThreat 2 || condThreat 5 && canFleeFromLight) ->
                    -- Don't keep fleeing if just hit, because too close
                    -- to enemy to get out of his range, most likely,
                    -- and so melee him instead, unless can't melee at all.
                    not condCanMelee
                    || not condSupport3 && not condSolo
                       && not heavilyDistressed
                  | condThreat 5
                    || not condInMelee && condAimEnemyNoMelee && condCanMelee ->
                    -- Too far to flee from melee, too close from ranged,
                    -- not in ambient, so no point fleeing into dark; advance.
                    -- Or the target enemy doesn't melee and melee enemies
                    -- far away, so chase him.
                    False
                  | otherwise ->
                    -- If I'm hit, they are still in range to fling at me,
                    -- even if I can't see them. And probably far away.
                    -- Too far to close in for melee; can't shoot; flee from
                    -- ranged attack and prepare ambush for later on.
                    not condInMelee
                    && heavilyDistressed
                    && (not condCanProject || canFleeFromLight) )
        , ( [SkMelee]
          , meleeBlocker aid  -- only melee blocker
          , condAnyFoeAdj  -- if foes, don't displace, otherwise friends:
            || not (abInMaxSkill SkDisplace)  -- displace friends, if possible
               && condAimEnemyPresent )  -- excited
                    -- So animals block each other until hero comes and then
                    -- the stronger makes a show for him and kills the weaker.
        , ( [SkAlter]
          , trigger aid ViaNothing
          , not condInMelee  -- don't incur overhead
            && condAdjTriggerable && not condAimEnemyPresent )
        , ( [SkDisplace]  -- prevents some looping movement
          , displaceBlocker aid retry  -- fires up only when path blocked
          , retry || not condDesirableFloorItem )
        , ( [SkMelee]
          , meleeAny aid
          , condAnyFoeAdj )  -- won't flee nor displace, so let it melee
        , ( runSkills
          , flee aid panicFleeL  -- ultimate panic mode, displaces foes
          , condAnyFoeAdj )
        ]
      -- Order doesn't matter, scaling does.
      -- These are flattened (taking only the best variant) and then summed,
      -- so if any of these can fire, it will fire. If none, @suffix@ is tried.
      -- Only the best variant of @chase@ is taken, but it's almost always
      -- good, and if not, the @chase@ in @suffix@ may fix that.
      -- The scaling values for @stratToFreq@ need to be so low-resolution
      -- or we get 32bit @Freqency@ overflows, which would bite us in JS.
      distant :: [([Skill], m (Frequency RequestTimed), Bool)]
      distant =
        [ ( [SkMoveItem]
          , stratToFreq (if condInMelee then 2 else 20000)
            $ yieldUnneeded aid  -- 20000 to unequip ASAP, unless is thrown
          , True )
        , ( [SkMoveItem]
          , stratToFreq 1
            $ equipItems aid  -- doesn't take long, very useful if safe
          , not (condInMelee
                 || condDesirableFloorItem
                 || uneasy) )
        , ( [SkProject]
          , stratToFreq (if condTgtNonmoving then 20 else 3)
              -- not too common, to leave missiles for pre-melee dance
            $ projectItem aid  -- equivalent of @condCanProject@ called inside
          , condAimEnemyPresent && not condInMelee )
        , ( [SkApply]
          , stratToFreq 1
            $ applyItem aid ApplyAll  -- use any potion or scroll
          , condAimEnemyPresent || condThreat 9 )  -- can affect enemies
        , ( runSkills
          , stratToFreq (if | condInMelee ->
                              400  -- friends pummeled by target, go to help
                            | not condAimEnemyPresent ->
                              2  -- if enemy only remembered investigate anyway
                            | otherwise ->
                              20)
            $ chase aid (not condInMelee
                         && (condThreat 12 || heavilyDistressed)
                         && aCanDeLight) retry
          , condCanMelee
            && (if condInMelee then condAimEnemyPresent
                else (condAimEnemyPresent || condAimEnemyRemembered)
                     && (not (condThreat 2)
                         || heavilyDistressed  -- if under fire, do something!
                         || not condMeleeBad)
                       -- this results in animals in corridor never attacking
                       -- (unless distressed by, e.g., being hit by missiles),
                       -- because they can't swarm opponent, which is logical,
                       -- and in rooms they do attack, so not too boring;
                       -- two aliens attack always, because more aggressive
                     && not condDesirableFloorItem) )
        ]
      suffix =
        [ ( [SkMoveItem]
          , pickup aid False  -- e.g., to give to other party members
          , not condInMelee && not dozes )
        , ( [SkMoveItem]
          , unEquipItems aid  -- late, because these items not bad
          , not condInMelee && not dozes )
        , ( [SkWait]
          , waitBlockNow  -- try to fall asleep, rarely
          , bwatch body `notElem` [WSleep, WWake]
            && mayFallAsleep
            && prefersSleep actorMaxSk
            && not condAimCrucial)
        , ( runSkills
          , chase aid (not condInMelee
                       && heavilyDistressed
                       && aCanDeLight) retry
          , not dozes
            && if condInMelee
               then condCanMelee && condAimEnemyPresent
               else not (condThreat 2) || not condMeleeBad )
        ]
      fallback =  -- Wait until friends sidestep; ensures strategy never empty.
                  -- Also, this is what non-leader heroes do, unless they melee.
        [ ( [SkWait]
          , case bwatch body of
              WSleep -> if mayContinueSleep
                             -- no check of @canSleep@, because sight
                             -- lowered by sleeping
                        then waitBlockNow
                        else yellNow  -- celebrate wake up with a bang
              _ -> waitBlockNow  -- block, etc.
          , True )
        , ( runSkills  -- if can't block, at least change something
          , chase aid (not condInMelee
                       && heavilyDistressed
                       && aCanDeLight) True
          , not condInMelee || condCanMelee && condAimEnemyPresent )
        , ( [SkDisplace]  -- if can't brace, at least change something
          , displaceBlocker aid True
          , True )
        , ( []
          , yellNow  -- desperate fallback
          , True )
       ]
  -- Check current, not maximal skills, since this can be a leader as well
  -- as non-leader action.
  let abInSkill sk = getSk sk actorSk > 0
      checkAction :: ([Skill], m a, Bool) -> Bool
      checkAction (abts, _, cond) = (null abts || any abInSkill abts) && cond
      sumS abAction = do
        let as = filter checkAction abAction
        strats <- mapM (\(_, m, _) -> m) as
        return $! msum strats
      sumF abFreq = do
        let as = filter checkAction abFreq
        strats <- mapM (\(_, m, _) -> m) as
        return $! msum strats
      combineWeighted as = liftFrequency <$> sumF as
  sumPrefix <- sumS prefix
  comDistant <- combineWeighted distant
  sumSuffix <- sumS suffix
  sumFallback <- sumS fallback
  return $! if bwatch body == WSleep
               && mayContinueSleep
                 -- no check of @canSleep@, because sight lowered by sleeping
            then returN "sleep" ReqWait
            else sumPrefix .| comDistant .| sumSuffix .| sumFallback

waitBlockNow :: MonadClient m => m (Strategy RequestTimed)
waitBlockNow = return $! returN "wait" ReqWait

yellNow :: MonadClient m => m (Strategy RequestTimed)
yellNow = return $! returN "yell" ReqYell

pickup :: MonadClient m => ActorId -> Bool -> m (Strategy RequestTimed)
pickup aid onlyWeapon = do
  benItemL <- benGroundItems aid
  b <- getsState $ getActorBody aid
  -- This calmE is outdated when one of the items increases max Calm
  -- (e.g., in pickup, which handles many items at once), but this is OK,
  -- the server accepts item movement based on calm at the start, not end
  -- or in the middle.
  -- The calmE is inaccurate also if an item not IDed, but that's intended
  -- and the server will ignore and warn (and content may avoid that,
  -- e.g., making all rings identified)
  actorMaxSk <- getsState $ getActorMaxSkills aid
  let calmE = calmEnough b actorMaxSk
      isWeapon (_, _, _, itemFull, _) = IA.isMelee $ aspectRecordFull itemFull
      filterWeapon | onlyWeapon = filter isWeapon
                   | otherwise = id
      prepareOne (oldN, l4)
                 (Benefit{benInEqp}, _, iid, itemFull, (itemK, _)) =
        let prep newN toCStore = (newN, (iid, itemK, CGround, toCStore) : l4)
            n = oldN + itemK
            arItem = aspectRecordFull itemFull
        in if | calmE && IA.goesIntoSha arItem && not onlyWeapon ->
                prep oldN CSha
              | benInEqp && eqpOverfull b n ->
                if onlyWeapon then (oldN, l4)
                else prep oldN (if calmE then CSha else CInv)
              | benInEqp ->
                prep n CEqp
              | not onlyWeapon ->
                prep oldN CInv
              | otherwise -> (oldN, l4)
      (_, prepared) = foldl' prepareOne (0, []) $ filterWeapon benItemL
  return $! if null prepared then reject
            else returN "pickup" $ ReqMoveItems prepared

-- This only concerns items that can be equipped, that is with a slot
-- and with @inEqp@ (which implies @goesIntoEqp@).
-- Such items are moved between any stores, as needed. In this case,
-- from inv or sha to eqp.
equipItems :: MonadClient m => ActorId -> m (Strategy RequestTimed)
equipItems aid = do
  body <- getsState $ getActorBody aid
  actorMaxSk <- getsState $ getActorMaxSkills aid
  let calmE = calmEnough body actorMaxSk
  eqpAssocs <- getsState $ kitAssocs aid [CEqp]
  invAssocs <- getsState $ kitAssocs aid [CInv]
  shaAssocs <- getsState $ kitAssocs aid [CSha]
  condShineWouldBetray <- condShineWouldBetrayM aid
  condAimEnemyPresent <- condAimEnemyPresentM aid
  discoBenefit <- getsClient sdiscoBenefit
  let improve :: CStore
              -> (Int, [(ItemId, Int, CStore, CStore)])
              -> ( [(Int, (ItemId, ItemFullKit))]
                 , [(Int, (ItemId, ItemFullKit))] )
              -> (Int, [(ItemId, Int, CStore, CStore)])
      improve fromCStore (oldN, l4) (bestInv, bestEqp) =
        let n = 1 + oldN
        in case (bestInv, bestEqp) of
          ((_, (iidInv, _)) : _, []) | not (eqpOverfull body n) ->
            (n, (iidInv, 1, fromCStore, CEqp) : l4)
          ((vInv, (iidInv, _)) : _, (vEqp, _) : _)
            | vInv > vEqp && not (eqpOverfull body n) ->
                (n, (iidInv, 1, fromCStore, CEqp) : l4)
          _ -> (oldN, l4)
      heavilyDistressed =  -- Actor hit by a projectile or similarly distressed.
        deltaSerious (bcalmDelta body)
      -- We filter out unneeded items. In particular, we ignore them in eqp
      -- when comparing to items we may want to equip, so that the unneeded
      -- but powerful items don't fool us.
      -- In any case, the unneeded items should be removed from equip
      -- in @yieldUnneeded@ earlier or soon after this check.
      -- In other stores we need to filter, for otherwise we'd have
      -- a loop of equip/yield.
      filterNeeded (_, (itemFull, _)) =
        not $ hinders condShineWouldBetray condAimEnemyPresent
                      heavilyDistressed (not calmE) actorMaxSk itemFull
      bestThree = bestByEqpSlot discoBenefit
                                (filter filterNeeded eqpAssocs)
                                (filter filterNeeded invAssocs)
                                (filter filterNeeded shaAssocs)
      bEqpInv = foldl' (improve CInv) (0, [])
                $ map (\(eqp, inv, _) -> (inv, eqp)) bestThree
      bEqpBoth | calmE =
                   foldl' (improve CSha) bEqpInv
                   $ map (\(eqp, _, sha) -> (sha, eqp)) bestThree
               | otherwise = bEqpInv
      (_, prepared) = bEqpBoth
  return $! if null prepared
            then reject
            else returN "equipItems" $ ReqMoveItems prepared

yieldUnneeded :: MonadClient m => ActorId -> m (Strategy RequestTimed)
yieldUnneeded aid = do
  body <- getsState $ getActorBody aid
  actorMaxSk <- getsState $ getActorMaxSkills aid
  let calmE = calmEnough body actorMaxSk
  eqpAssocs <- getsState $ kitAssocs aid [CEqp]
  condShineWouldBetray <- condShineWouldBetrayM aid
  condAimEnemyPresent <- condAimEnemyPresentM aid
  discoBenefit <- getsClient sdiscoBenefit
  -- Here and in @unEquipItems@ AI may hide from the human player,
  -- in shared stash, the Ring of Speed And Bleeding,
  -- which is a bit harsh, but fair. However any subsequent such
  -- rings will not be picked up at all, so the human player
  -- doesn't lose much fun. Additionally, if AI learns alchemy later on,
  -- they can repair the ring, wield it, drop at death and it's
  -- in play again.
  let heavilyDistressed =  -- Actor hit by a projectile or similarly distressed.
        deltaSerious (bcalmDelta body)
      csha = if calmE then CSha else CInv
      yieldSingleUnneeded (iidEqp, (itemEqp, (itemK, _))) =
        if | harmful discoBenefit iidEqp ->
             [(iidEqp, itemK, CEqp, CInv)]  -- harmful not shared
           | hinders condShineWouldBetray condAimEnemyPresent
                     heavilyDistressed (not calmE) actorMaxSk itemEqp ->
             [(iidEqp, itemK, CEqp, csha)]
           | otherwise -> []
      yieldAllUnneeded = concatMap yieldSingleUnneeded eqpAssocs
  return $! if null yieldAllUnneeded
            then reject
            else returN "yieldUnneeded" $ ReqMoveItems yieldAllUnneeded

-- This only concerns items that can be equipped, that is with a slot
-- and with @inEqp@ (which implies @goesIntoEqp@).
-- Such items are moved between any stores, as needed. In this case,
-- from inv or eqp to sha.
unEquipItems :: MonadClient m => ActorId -> m (Strategy RequestTimed)
unEquipItems aid = do
  body <- getsState $ getActorBody aid
  actorMaxSk <- getsState $ getActorMaxSkills aid
  let calmE = calmEnough body actorMaxSk
  eqpAssocs <- getsState $ kitAssocs aid [CEqp]
  invAssocs <- getsState $ kitAssocs aid [CInv]
  shaAssocs <- getsState $ kitAssocs aid [CSha]
  condShineWouldBetray <- condShineWouldBetrayM aid
  condAimEnemyPresent <- condAimEnemyPresentM aid
  discoBenefit <- getsClient sdiscoBenefit
  let improve :: CStore -> ( [(Int, (ItemId, ItemFullKit))]
                           , [(Int, (ItemId, ItemFullKit))] )
              -> [(ItemId, Int, CStore, CStore)]
      improve fromCStore (bestSha, bestEOrI) =
        case bestEOrI of
          ((vEOrI, (iidEOrI, bei)) : _) | getK bei > 1
                                          && betterThanSha vEOrI bestSha ->
            -- To share the best items with others, if they care.
            [(iidEOrI, getK bei - 1, fromCStore, CSha)]
          (_ : (vEOrI, (iidEOrI, bei)) : _) | betterThanSha vEOrI bestSha ->
            -- To share the second best items with others, if they care.
            [(iidEOrI, getK bei, fromCStore, CSha)]
          ((vEOrI, (_, _)) : _) | fromCStore == CEqp
                                  && eqpOverfull body 1
                                  && worseThanSha vEOrI bestSha ->
            -- To make place in eqp for an item better than any ours.
            -- Even a minor boost is removed only if sha has a better one.
            [(fst $ snd $ last bestEOrI, 1, fromCStore, CSha)]
          _ -> []
      getK (_, (itemK, _)) = itemK
      betterThanSha _ [] = True
      betterThanSha vEOrI ((vSha, _) : _) = vEOrI > vSha
      worseThanSha _ [] = False
      worseThanSha vEOrI ((vSha, _) : _) = vEOrI < vSha
      heavilyDistressed =  -- Actor hit by a projectile or similarly distressed.
        deltaSerious (bcalmDelta body)
      -- Here we don't need to filter out items that hinder (except in sha)
      -- because they are moved to sha and will be equipped by another actor
      -- at another time, where hindering will be completely different.
      -- If they hinder and we unequip them, all the better.
      -- We filter sha to consider only eligible items in @worseThanSha@.
      filterNeeded (_, (itemFull, _)) =
        not $ hinders condShineWouldBetray condAimEnemyPresent
                      heavilyDistressed (not calmE) actorMaxSk itemFull
      bestThree = bestByEqpSlot discoBenefit eqpAssocs invAssocs
                                (filter filterNeeded shaAssocs)
      bInvSha = concatMap
                  (improve CInv . (\(_, inv, sha) -> (sha, inv))) bestThree
      bEqpSha = concatMap
                  (improve CEqp . (\(eqp, _, sha) -> (sha, eqp))) bestThree
      prepared = if calmE then bInvSha ++ bEqpSha else []
  return $! if null prepared
            then reject
            else returN "unEquipItems" $ ReqMoveItems prepared

groupByEqpSlot :: [(ItemId, ItemFullKit)]
               -> EM.EnumMap EqpSlot [(ItemId, ItemFullKit)]
groupByEqpSlot is =
  let f (iid, itemFullKit) =
        let arItem = aspectRecordFull $ fst itemFullKit
        in case IA.aEqpSlot arItem of
          Nothing -> Nothing
          Just es -> Just (es, [(iid, itemFullKit)])
      withES = mapMaybe f is
  in EM.fromListWith (++) withES

bestByEqpSlot :: DiscoveryBenefit
              -> [(ItemId, ItemFullKit)]
              -> [(ItemId, ItemFullKit)]
              -> [(ItemId, ItemFullKit)]
              -> [( [(Int, (ItemId, ItemFullKit))]
                  , [(Int, (ItemId, ItemFullKit))]
                  , [(Int, (ItemId, ItemFullKit))] )]
bestByEqpSlot discoBenefit eqpAssocs invAssocs shaAssocs =
  let eqpMap = EM.map (\g -> (g, [], [])) $ groupByEqpSlot eqpAssocs
      invMap = EM.map (\g -> ([], g, [])) $ groupByEqpSlot invAssocs
      shaMap = EM.map (\g -> ([], [], g)) $ groupByEqpSlot shaAssocs
      appendThree (g1, g2, g3) (h1, h2, h3) = (g1 ++ h1, g2 ++ h2, g3 ++ h3)
      eqpInvShaMap = EM.unionsWith appendThree [eqpMap, invMap, shaMap]
      bestSingle = strongestSlot discoBenefit
      bestThree eqpSlot (g1, g2, g3) = (bestSingle eqpSlot g1,
                                        bestSingle eqpSlot g2,
                                        bestSingle eqpSlot g3)
  in EM.elems $ EM.mapWithKey bestThree eqpInvShaMap

harmful :: DiscoveryBenefit -> ItemId -> Bool
harmful discoBenefit iid =
  -- Items that are known, perhaps recently discovered, and it's now revealed
  -- they should not be kept in equipment, should be unequipped
  -- (either they are harmful or they waste eqp space).
  not $ benInEqp $ discoBenefit EM.! iid

-- Everybody melees in a pinch, even though some prefer ranged attacks.
meleeBlocker :: MonadClient m => ActorId -> m (Strategy RequestTimed)
meleeBlocker aid = do
  b <- getsState $ getActorBody aid
  actorMaxSk <- getsState $ getActorMaxSkills aid
  fact <- getsState $ (EM.! bfid b) . sfactionD
  actorSk <- currentSkillsClient aid
  mtgtMPath <- getsClient $ EM.lookup aid . stargetD
  case mtgtMPath of
    Just TgtAndPath{ tapTgt=TEnemy{}
                   , tapPath=AndPath{pathList=q : _, pathGoal} }
      | q == pathGoal -> return reject  -- not a real blocker, but goal enemy
    Just TgtAndPath{tapPath=AndPath{pathList=q : _, pathGoal}} -> do
      -- We prefer the goal position, so that we can kill the foe and enter it,
      -- but we accept any @q@ as well.
      lvl <- getLevel (blid b)
      let maim | adjacent (bpos b) pathGoal = Just pathGoal
               | adjacent (bpos b) q = Just q
               | otherwise = Nothing  -- MeleeDistant
          lBlocker = case maim of
            Nothing -> []
            Just aim -> maybeToList (posToBigLvl aim lvl)
                        ++ posToProjsLvl aim lvl
      case lBlocker of
        aid2 : _ -> do
          body2 <- getsState $ getActorBody aid2
          actorMaxSk2 <- getsState $ getActorMaxSkills aid2
          -- No problem if there are many projectiles at the spot. We just
          -- attack the first one.
          if | actorDying body2
               || bproj body2  -- displacing saves a move, so don't melee
                  && getSk SkDisplace actorSk > 0 ->
               return reject
             | isFoe (bfid b) fact (bfid body2)
                 -- at war with us, so hit, not displace
               || isFriend (bfid b) fact (bfid body2) -- don't start a war
                  && getSk SkDisplace actorSk <= 0
                       -- can't displace
                  && getSk SkMove actorSk > 0  -- blocked move
                  && 3 * bhp body2 < bhp b  -- only get rid of weak friends
                  && gearSpeed actorMaxSk2 <= gearSpeed actorMaxSk -> do
               mel <- maybeToList <$> pickWeaponClient aid aid2
               return $! liftFrequency $ uniformFreq "melee in the way" mel
             | otherwise -> return reject
        [] -> return reject
    _ -> return reject  -- probably no path to the enemy, if any

-- Everybody melees in a pinch, skills and weapons allowing,
-- even though some prefer ranged attacks.
meleeAny :: MonadClient m => ActorId -> m (Strategy RequestTimed)
meleeAny aid = do
  b <- getsState $ getActorBody aid
  fact <- getsState $ (EM.! bfid b) . sfactionD
  adjBigAssocs <- getsState $ adjacentBigAssocs b
  let foe (_, b2) = isFoe (bfid b) fact (bfid b2) && bhp b2 > 0
      adjFoes = map fst $ filter foe adjBigAssocs
  btarget <- getsClient $ getTarget aid
  mtargets <- case btarget of
    Just (TEnemy aid2 _) -> do
      b2 <- getsState $ getActorBody aid2
      return $! if adjacent (bpos b2) (bpos b) && foe (aid2, b2)
                then Just [aid2]
                else Nothing
    _ -> return Nothing
  let adjTargets = fromMaybe adjFoes mtargets
  mels <- mapM (pickWeaponClient aid) adjTargets
  let freq = uniformFreq "melee adjacent" $ catMaybes mels
  return $! liftFrequency freq

-- The level the actor is on is either explored or the actor already
-- has a weapon equipped, so no need to explore further, he tries to find
-- enemies on other levels.
-- We don't verify any embedded item is targeted by the actor, but at least
-- the actor doesn't target a visible enemy at this point.
-- TODO: In @actionStrategy@ we require minimal @SkAlter@ even for the case
-- of triggerable tile underfoot. A quirk; a specialization of AI actors.
trigger :: MonadClient m
        => ActorId -> FleeViaStairsOrEscape
        -> m (Strategy RequestTimed)
trigger aid fleeVia = do
  b <- getsState $ getActorBody aid
  lvl <- getLevel (blid b)
  let f pos = case EM.lookup pos $ lembed lvl of
        Nothing -> Nothing
        Just bag -> Just (pos, bag)
      pbags = mapMaybe f $ bpos b : vicinityUnsafe (bpos b)
  efeat <- embedBenefit fleeVia aid pbags
  return $! liftFrequency $ toFreq "trigger"
    [ (ceiling benefit, ReqAlter pos)
    | (benefit, (pos, _)) <- efeat ]

projectItem :: MonadClient m => ActorId -> m (Strategy RequestTimed)
projectItem aid = do
  btarget <- getsClient $ getTarget aid
  b <- getsState $ getActorBody aid
  mfpos <- case btarget of
    Nothing -> return Nothing
    Just target -> getsState $ aidTgtToPos aid (blid b) target
  seps <- getsClient seps
  case (btarget, mfpos) of
    (_, Just fpos) | adjacent (bpos b) fpos -> return reject
    (Just TEnemy{}, Just fpos) -> do
      mnewEps <- makeLine False b fpos seps
      case mnewEps of
        Just newEps -> do
          actorSk <- currentSkillsClient aid
          let skill = getSk SkProject actorSk
          -- ProjectAimOnself, ProjectBlockActor, ProjectBlockTerrain
          -- and no actors or obstacles along the path.
          benList <- condProjectListM skill aid
          localTime <- getsState $ getLocalTime (blid b)
          let coeff CGround = 2  -- pickup turn saved
              coeff COrgan = error $ "" `showFailure` benList
              coeff CEqp = 100000  -- must hinder currently (or be very potent)
              coeff CInv = 1
              coeff CSha = 1
              fRanged (Benefit{benFling}, cstore, iid, itemFull, kit) =
                -- We assume if the item has a timeout, most effects are under
                -- Recharging, so no point projecting if not recharged.
                -- This changes in time, so recharging is not included
                -- in @condProjectListM@, but checked here, just before fling.
                let recharged = hasCharge localTime itemFull kit
                    arItem = aspectRecordFull itemFull
                    trange = IA.totalRange arItem $ itemKind itemFull
                    bestRange =
                      chessDist (bpos b) fpos + 2  -- margin for fleeing
                    rangeMult =  -- penalize wasted or unsafely low range
                      10 + max 0 (10 - abs (trange - bestRange))
                    benR = coeff cstore * benFling
                in if trange >= chessDist (bpos b) fpos && recharged
                   then Just ( - ceiling (benR * fromIntegral rangeMult / 10)
                             , ReqProject fpos newEps iid cstore )
                   else Nothing
              benRanged = mapMaybe fRanged benList
          return $! liftFrequency $ toFreq "projectItem" benRanged
        _ -> return reject
    _ -> return reject

data ApplyItemGroup = ApplyAll | ApplyFirstAid
  deriving Eq

applyItem :: MonadClient m
          => ActorId -> ApplyItemGroup -> m (Strategy RequestTimed)
applyItem aid applyGroup = do
  actorSk <- currentSkillsClient aid
  b <- getsState $ getActorBody aid
  condShineWouldBetray <- condShineWouldBetrayM aid
  condAimEnemyPresent <- condAimEnemyPresentM aid
  localTime <- getsState $ getLocalTime (blid b)
  actorMaxSk <- getsState $ getActorMaxSkills aid
  let calmE = calmEnough b actorMaxSk
      condNotCalmEnough = not calmE
      heavilyDistressed =  -- Actor hit by a projectile or similarly distressed.
        deltaSerious (bcalmDelta b)
      skill = getSk SkApply actorSk
      -- This detects if the value of keeping the item in eqp is in fact < 0.
      hind = hinders condShineWouldBetray condAimEnemyPresent
                     heavilyDistressed condNotCalmEnough actorMaxSk
      permittedActor itemFull kit =
        either (const False) id
        $ permittedApply localTime skill calmE itemFull kit
      -- Both effects tweak items, which is only situationally beneficial
      -- and not really the best idea while in combat.
      getTweak IK.PolyItem = True
      getTweak IK.RerollItem = True
      getTweak IK.DupItem = True
      getTweak IK.Identify = True
      getTweak (IK.OneOf l) = any getTweak l
      getTweak (IK.Recharging eff) = getTweak eff
      getTweak (IK.Composite l) = any getTweak l
      getTweak _ = False
      q (Benefit{benInEqp}, _, _, itemFull@ItemFull{itemKind}, kit) =
        let arItem = aspectRecordFull itemFull
            durable = IA.checkFlag Durable arItem
        in (not benInEqp  -- can't wear, so OK to break
            || durable  -- can wear, but can't break, even better
            || not (IA.isMelee arItem)  -- anything else expendable
               && hind itemFull)  -- hinders now, so possibly often, so away!
           && permittedActor itemFull kit
           && not (any getTweak $ IK.ieffects itemKind)
           && not (IA.isHumanTrinket itemKind)  -- hack for elixir of youth
      -- Organs are not taken into account, because usually they are either
      -- melee items, so harmful, or periodic, so charging between activations.
      -- The case of a weak weapon curing poison is too rare to incur overhead.
      stores = [CEqp, CInv, CGround] ++ [CSha | calmE]
  discoBenefit <- getsClient sdiscoBenefit
  benList <- getsState $ benAvailableItems discoBenefit aid stores
  getKind <- getsState $ flip getIidKind
  let (myBadGrps, myGoodGrps) = partitionEithers $ mapMaybe (\iid ->
        let itemKind = getKind iid
        in if isJust $ lookup "condition" $ IK.ifreq itemKind
           then Just $ if benInEqp (discoBenefit EM.! iid)
                       then Left $ toGroupName $ IK.iname itemKind
                         -- conveniently, @iname@ matches @ifreq@
                       else Right $ toGroupName $ IK.iname itemKind
           else Nothing) (EM.keys $ borgan b)
      coeff CGround = 2  -- pickup turn saved
      coeff COrgan = error $ "" `showFailure` benList
      coeff CEqp = 1
      coeff CInv = 1
      coeff CSha = 1
      fTool benAv@( Benefit{benApply}, cstore, iid
                  , itemFull@ItemFull{itemKind}, _ ) =
        let -- Don't include @Ascend@ nor @Teleport@, because maybe no foe near.
            -- Don't include @OneOf@ because other effects may kill you.
            getHP (IK.RefillHP p) | p > 0 = True
            getHP (IK.Recharging eff) = getHP eff
            getHP (IK.Composite l) = any getHP l
            getHP _ = False
            heals = any getHP $ IK.ieffects itemKind
            dropsGrps = IK.getDropOrgans itemKind
            dropsBadOrgans =
              not (null myBadGrps)
              && ("condition" `elem` dropsGrps
                  || not (null (dropsGrps `intersect` myBadGrps)))
            dropsGoodOrgans =
              not (null myGoodGrps)
              && ("condition" `elem` dropsGrps
                  || not (null (dropsGrps `intersect` myGoodGrps)))
            wastesDrop = not dropsBadOrgans && not (null dropsGrps)
            durable = IA.checkFlag Durable $ aspectRecordFull itemFull
            situationalBenApply | dropsBadOrgans = benApply + 20
                                | wastesDrop = benApply - 10
                                | otherwise = benApply
            benR = ceiling situationalBenApply
                   * if cstore == CEqp && not durable
                     then 1000  -- must hinder currently (or be very potent)
                     else coeff cstore
            canApply = situationalBenApply > 0 && case applyGroup of
              ApplyFirstAid -> q benAv && heals
              ApplyAll -> q benAv
                          && not dropsGoodOrgans
                          && (dropsBadOrgans
                              || not (hpEnough b actorMaxSk && heals))
        in if canApply
           then Just (benR, ReqApply iid cstore)
           else Nothing
      benTool = mapMaybe fTool benList
  return $! liftFrequency $ toFreq "applyItem" benTool

-- If low on health or alone, flee in panic, close to the path to target
-- and as far from the attackers, as possible. Usually fleeing from
-- foes will lead towards friends, but we don't insist on that.
flee :: MonadClient m
     => ActorId -> [(Int, Point)] -> m (Strategy RequestTimed)
flee aid fleeL = do
  b <- getsState $ getActorBody aid
  -- Regardless if fleeing accomplished, mark the need.
  modifyClient $ \cli -> cli {sfleeD = EM.insert aid (bpos b) (sfleeD cli)}
  let vVic = map (second (`vectorToFrom` bpos b)) fleeL
      str = liftFrequency $ toFreq "flee" vVic
  mapStrategyM (moveOrRunAid aid) str

-- The result of all these conditions is that AI displaces rarely,
-- but it can't be helped as long as the enemy is smart enough to form fronts.
displaceFoe :: MonadClient m => ActorId -> m (Strategy RequestTimed)
displaceFoe aid = do
  COps{coTileSpeedup} <- getsState scops
  b <- getsState $ getActorBody aid
  lvl <- getLevel $ blid b
  fact <- getsState $ (EM.! bfid b) . sfactionD
  friends <- getsState $ friendRegularList (bfid b) (blid b)
  adjBigAssocs <- getsState $ adjacentBigAssocs b
  let foe (_, b2) = isFoe (bfid b) fact (bfid b2)
      adjFoes = filter foe adjBigAssocs
      walkable p =  -- DisplaceAccess
        Tile.isWalkable coTileSpeedup (lvl `at` p)
      notLooping body p =  -- avoid displace loops
        boldpos body /= Just p || waitedLastTurn body
      nFriends body = length $ filter (adjacent (bpos body) . bpos) friends
      nFrNew = nFriends b + 1
      qualifyActor (aid2, body2) = do
        let tpos = bpos body2
        case maybeToList (posToBigLvl tpos lvl) ++ posToProjsLvl tpos lvl of
          [_] -> do
            actorMaxSk <- getsState $ getActorMaxSkills aid2
            dEnemy <- getsState $ dispEnemy aid aid2 actorMaxSk
              -- DisplaceDying, DisplaceBraced, DisplaceImmobile,
              -- DisplaceSupported
            let nFrOld = nFriends body2
            return $! if walkable (bpos body2)  -- DisplaceAccess
                         && dEnemy && nFrOld < nFrNew
                         && notLooping b (bpos body2)
                      then Just (nFrOld * nFrOld, ReqDisplace aid2)
                      else Nothing
          _ -> return Nothing  -- DisplaceProjectiles
  foes <- mapM qualifyActor adjFoes
  return $! liftFrequency $ toFreq "displaceFoe" $ catMaybes foes

displaceBlocker :: MonadClient m => ActorId -> Bool -> m (Strategy RequestTimed)
displaceBlocker aid retry = do
  b <- getsState $ getActorBody aid
  actorMaxSkills <- getsState sactorMaxSkills
  let condCanMelee = actorCanMelee actorMaxSkills aid b
  mtgtMPath <- getsClient $ EM.lookup aid . stargetD
  case mtgtMPath of
    Just TgtAndPath{ tapTgt=TEnemy _ permit
                   , tapPath=AndPath{pathList=q : _, pathGoal} }
      | q == pathGoal  -- not a real blocker but goal; only displace if can't
                       -- melee (e.g., followed leader) and desperate
        && not (retry && not permit && condCanMelee) ->
        return reject
    Just TgtAndPath{tapPath=AndPath{pathList=q : _}}
      | adjacent (bpos b) q ->  -- not veered off target too much
        displaceTgt aid q retry
    _ -> return reject  -- goal reached

displaceTgt :: MonadClient m
            => ActorId -> Point -> Bool -> m (Strategy RequestTimed)
displaceTgt source tpos retry = do
  COps{coTileSpeedup} <- getsState scops
  b <- getsState $ getActorBody source
  let !_A = assert (adjacent (bpos b) tpos) ()
  lvl <- getLevel $ blid b
  let walkable p =  -- DisplaceAccess
        Tile.isWalkable coTileSpeedup (lvl `at` p)
      notLooping body p =  -- avoid displace loops
        boldpos body /= Just p || waitedLastTurn body
  if walkable tpos && notLooping b tpos then do
    mleader <- getsClient sleader
    case maybeToList (posToBigLvl tpos lvl) ++ posToProjsLvl tpos lvl of
      [] -> return reject
      [aid2] | Just aid2 /= mleader -> do
        b2 <- getsState $ getActorBody aid2
        mtgtMPath <- getsClient $ EM.lookup aid2 . stargetD
        enemyTgt <- condAimEnemyPresentM source
        enemyPos <- condAimEnemyRememberedM source
        enemyTgt2 <- condAimEnemyPresentM aid2
        enemyPos2 <- condAimEnemyRememberedM aid2
        case mtgtMPath of
          Just TgtAndPath{tapPath=AndPath{pathList=q : _}}
            | q == bpos b  -- friend wants to swap
              || bwatch b2 `elem` [WSleep, WWake]  -- friend sleeps, not cares
              || retry  -- desperate
                 && not (boldpos b == Just tpos  -- and no displace loop
                         && not (waitedLastTurn b))
              || (enemyTgt || enemyPos) && not (enemyTgt2 || enemyPos2) ->
                 -- he doesn't have Enemy target and I have, so push him aside,
                 -- because, for heroes, he will never be a leader, so he can't
                 -- step aside himself
              return $! returN "displace friend" $ ReqDisplace aid2
          Just _ | bwatch b2 `notElem` [WSleep, WWake] -> return reject
          _ -> do  -- an enemy or ally or dozing or disoriented friend --- swap
            tfact <- getsState $ (EM.! bfid b2) . sfactionD
            actorMaxSk <- getsState $ getActorMaxSkills aid2
            dEnemy <- getsState $ dispEnemy source aid2 actorMaxSk
              -- DisplaceDying, DisplaceBraced, DisplaceImmobile,
              -- DisplaceSupported
            if not (isFoe (bfid b2) tfact (bfid b)) || dEnemy then
              return $! returN "displace other" $ ReqDisplace aid2
            else return reject
      _ -> return reject  -- DisplaceProjectiles or trying to displace leader
  else return reject

chase :: MonadClient m => ActorId -> Bool -> Bool -> m (Strategy RequestTimed)
chase aid avoidAmbient retry = do
  COps{coTileSpeedup} <- getsState scops
  body <- getsState $ getActorBody aid
  fact <- getsState $ (EM.! bfid body) . sfactionD
  mtgtMPath <- getsClient $ EM.lookup aid . stargetD
  lvl <- getLevel $ blid body
  let isAmbient pos = Tile.isLit coTileSpeedup (lvl `at` pos)
                      && Tile.isWalkable coTileSpeedup (lvl `at` pos)
                        -- if solid, will be altered and perhaps darkened
  str <- case mtgtMPath of
    Just TgtAndPath{tapPath=AndPath{pathList=q : _, ..}}
      | pathGoal == bpos body -> return reject  -- shortcut and just to be sure
      | not $ avoidAmbient && isAmbient q ->
      -- With no leader, the goal is vague, so permit arbitrary detours.
      moveTowards aid q pathGoal (fleaderMode (gplayer fact) == LeaderNull
                                  || retry)
    _ -> return reject  -- goal reached or banned ambient lit tile
  if avoidAmbient && nullStrategy str
  then chase aid False retry
  else mapStrategyM (moveOrRunAid aid) str

moveTowards :: MonadClient m
            => ActorId -> Point -> Point -> Bool -> m (Strategy Vector)
moveTowards aid target goal relaxed = do
  b <- getsState $ getActorBody aid
  actorSk <- currentSkillsClient aid
  let source = bpos b
      alterSkill = getSk SkAlter actorSk
      !_A = assert (source == bpos b
                    `blame` (source, bpos b, aid, b, goal)) ()
      !_B = assert (adjacent source target
                    `blame` (source, target, aid, b, goal)) ()
  fact <- getsState $ (EM.! bfid b) . sfactionD
  salter <- getsClient salter
  noFriends <- getsState $ \s p ->
    all (isFoe (bfid b) fact . bfid . snd)
        (maybeToList (posToBigAssoc p (blid b) s)
         ++ posToProjAssocs p (blid b) s)  -- don't kill own projectiles
  let lalter = salter EM.! blid b
      -- Only actors with SkAlter can search for hidden doors, etc.
      enterableHere p = alterSkill >= fromEnum (lalter PointArray.! p)
  if noFriends target && enterableHere target then
    return $! returN "moveTowards target" $ target `vectorToFrom` source
  else do
    -- This lets animals mill around, even when blocked,
    -- because they have nothing to lose (unless other animals melee).
    -- Blocked heroes instead don't become leaders and don't move
    -- until friends sidestep to let them reach their goal.
    let goesBack p = Just p == boldpos b
        nonincreasing p = chessDist source goal >= chessDist p goal
        isSensible | relaxed = \p -> noFriends p
                                     && enterableHere p
                   | otherwise = \p -> nonincreasing p
                                       && not (goesBack p)
                                       && noFriends p
                                       && enterableHere p
        sensible = [ ((goesBack p, chessDist p goal), v)
                   | v <- moves, let p = source `shift` v, isSensible p ]
        sorted = sortBy (comparing fst) sensible
        groups = map (map snd) $ groupBy ((==) `on` fst) sorted
        freqs = map (liftFrequency . uniformFreq "moveTowards") groups
    return $! foldr (.|) reject freqs

-- Actor moves or searches or alters or attacks.
-- This function is very general, even though it's often used in contexts
-- when only one or two of the many cases can possibly occur.
moveOrRunAid :: MonadClient m => ActorId -> Vector -> m (Maybe RequestTimed)
moveOrRunAid source dir = do
  COps{coTileSpeedup} <- getsState scops
  sb <- getsState $ getActorBody source
  actorSk <- currentSkillsClient source
  let lid = blid sb
  lvl <- getLevel lid
  let walkable =  -- DisplaceAccess
        Tile.isWalkable coTileSpeedup (lvl `at` tpos)
      notLooping body p =  -- avoid displace loops
        boldpos body /= Just p || waitedLastTurn body
      spos = bpos sb           -- source position
      tpos = spos `shift` dir  -- target position
      t = lvl `at` tpos
  -- We start by checking actors at the target position,
  -- which gives a partial information (actors can be invisible),
  -- as opposed to accessibility (and items) which are always accurate
  -- (tiles can't be invisible).
  case maybeToList (posToBigLvl tpos lvl) ++ posToProjsLvl tpos lvl of
    [target] | walkable
               && getSk SkDisplace actorSk > 0
               && notLooping sb tpos -> do
      -- @target@ can be a foe, as well as a friend.
      tb <- getsState $ getActorBody target
      tfact <- getsState $ (EM.! bfid tb) . sfactionD
      actorMaxSk <- getsState $ getActorMaxSkills target
      dEnemy <- getsState $ dispEnemy source target actorMaxSk
        -- DisplaceDying, DisplaceBraced, DisplaceImmobile, DisplaceSupported
      if isFoe (bfid tb) tfact (bfid sb) && not dEnemy
      then return Nothing
      else return $ Just $ ReqDisplace target
    [] | walkable && getSk SkMove actorSk > 0 ->
      -- Movement requires full access. The potential invisible actor is hit.
      return $ Just $ ReqMove dir
    [] | not walkable
         && getSk SkAlter actorSk
              >= Tile.alterMinWalk coTileSpeedup t  -- AlterUnwalked
         -- Only possible if items allowed inside unwalkable tiles:
         && EM.notMember tpos (lfloor lvl) ->  -- AlterBlockItem
      -- Not walkable, but alter skill suffices, so search or alter the tile.
      -- We assume that unalterable unwalkable tiles are protected
      -- by high skill req. We don't alter walkable tiles (e.g., close doors).
      return $ Just $ ReqAlter tpos
    _ -> return Nothing  -- can't displace, move nor alter
