-- | Helper functions for both inventory management and human commands.
module Game.LambdaHack.Client.UI.HandleHelperM
  ( FailError, showFailError, MError, mergeMError, FailOrCmd, failWith
  , failSer, failMsg, weaveJust, sortSlots
  , memberCycle, memberBack, partyAfterLeader, pickLeader, pickLeaderWithPointer
  , itemOverlay, skillsOverlay, placesFromState, placeParts, placesOverlay
  , pickNumber, lookAtItems, lookAtPosition
  , displayItemLore, viewLoreItems, cycleLore, spoilsBlurb
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , lookAtTile, lookAtActors
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import qualified Data.Char as Char
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import qualified Data.Text as T
import qualified NLP.Miniutter.English as MU

import           Game.LambdaHack.Client.ClientOptions
import           Game.LambdaHack.Client.CommonM
import           Game.LambdaHack.Client.MonadClient
import           Game.LambdaHack.Client.State
import           Game.LambdaHack.Client.UI.ActorUI
import           Game.LambdaHack.Client.UI.Content.Screen
import           Game.LambdaHack.Client.UI.ContentClientUI
import           Game.LambdaHack.Client.UI.EffectDescription
import qualified Game.LambdaHack.Client.UI.HumanCmd as HumanCmd
import           Game.LambdaHack.Client.UI.ItemDescription
import           Game.LambdaHack.Client.UI.ItemSlot
import qualified Game.LambdaHack.Client.UI.Key as K
import           Game.LambdaHack.Client.UI.MonadClientUI
import           Game.LambdaHack.Client.UI.MsgM
import           Game.LambdaHack.Client.UI.Overlay
import           Game.LambdaHack.Client.UI.SessionUI
import           Game.LambdaHack.Client.UI.Slideshow
import           Game.LambdaHack.Client.UI.SlideshowM
import qualified Game.LambdaHack.Common.Ability as Ability
import           Game.LambdaHack.Common.Actor
import           Game.LambdaHack.Common.ActorState
import qualified Game.LambdaHack.Common.Color as Color
import           Game.LambdaHack.Common.Container
import           Game.LambdaHack.Common.Faction
import           Game.LambdaHack.Common.Item
import           Game.LambdaHack.Common.Kind
import           Game.LambdaHack.Common.Level
import           Game.LambdaHack.Common.Misc
import           Game.LambdaHack.Common.MonadStateRead
import           Game.LambdaHack.Common.Perception
import           Game.LambdaHack.Common.Point
import           Game.LambdaHack.Common.ReqFailure
import           Game.LambdaHack.Common.State
import           Game.LambdaHack.Common.Time
import qualified Game.LambdaHack.Content.ItemKind as IK
import qualified Game.LambdaHack.Content.PlaceKind as PK
import qualified Game.LambdaHack.Content.TileKind as TK

-- | Message describing the cause of failure of human command.
newtype FailError = FailError {failError :: Text}
  deriving Show

showFailError :: FailError -> Text
showFailError (FailError err) = "*" <> err <> "*"

type MError = Maybe FailError

mergeMError :: MError -> MError -> MError
mergeMError Nothing Nothing = Nothing
mergeMError merr1@Just{} Nothing = merr1
mergeMError Nothing merr2@Just{} = merr2
mergeMError (Just err1) (Just err2) =
  Just $ FailError $ failError err1 <+> "and" <+> failError err2

type FailOrCmd a = Either FailError a

failWith :: MonadClientUI m => Text -> m (FailOrCmd a)
failWith err = assert (not $ T.null err) $ return $ Left $ FailError err

failSer :: MonadClientUI m => ReqFailure -> m (FailOrCmd a)
failSer = failWith . showReqFailure

failMsg :: MonadClientUI m => Text -> m MError
failMsg err = assert (not $ T.null err) $ return $ Just $ FailError err

weaveJust :: FailOrCmd a -> Either MError a
weaveJust (Left ferr) = Left $ Just ferr
weaveJust (Right a) = Right a

sortSlots :: MonadClientUI m => m ()
sortSlots = do
  itemToF <- getsState $ flip itemToFull
  ItemSlots itemSlots <- getsSession sslots
  let newSlots = ItemSlots $ EM.map (sortSlotMap itemToF) itemSlots
  modifySession $ \sess -> sess {sslots = newSlots}

-- | Switches current member to the next on the level, if any, wrapping.
memberCycle :: MonadClientUI m => Bool -> m MError
memberCycle verbose = do
  side <- getsClient sside
  fact <- getsState $ (EM.! side) . sfactionD
  lidV <- viewedLevelUI
  leader <- getLeaderUI
  body <- getsState $ getActorBody leader
  hs <- partyAfterLeader leader
  let (autoDun, _) = autoDungeonLevel fact
  case filter (\(_, b, _) -> blid b == lidV) hs of
    _ | autoDun && lidV /= blid body ->
      failMsg $ showReqFailure NoChangeDunLeader
    [] -> failMsg "cannot pick any other member on this level"
    (np, b, _) : _ -> do
      success <- pickLeader verbose np
      let !_A = assert (success `blame` "same leader"
                                `swith` (leader, np, b)) ()
      return Nothing

-- | Switches current member to the previous in the whole dungeon, wrapping.
memberBack :: MonadClientUI m => Bool -> m MError
memberBack verbose = do
  side <- getsClient sside
  fact <- getsState $ (EM.! side) . sfactionD
  leader <- getLeaderUI
  hs <- partyAfterLeader leader
  let (autoDun, _) = autoDungeonLevel fact
  case reverse hs of
    _ | autoDun -> failMsg $ showReqFailure NoChangeDunLeader
    [] -> failMsg "no other member in the party"
    (np, b, _) : _ -> do
      success <- pickLeader verbose np
      let !_A = assert (success `blame` "same leader"
                                `swith` (leader, np, b)) ()
      return Nothing

partyAfterLeader :: MonadClientUI m => ActorId -> m [(ActorId, Actor, ActorUI)]
partyAfterLeader leader = do
  side <- getsState $ bfid . getActorBody leader
  sactorUI <- getsSession sactorUI
  allOurs <- getsState $ fidActorNotProjGlobalAssocs side -- not only on level
  let allOursUI = map (\(aid, b) -> (aid, b, sactorUI EM.! aid)) allOurs
      hs = sortOn keySelected allOursUI
      i = fromMaybe (-1) $ findIndex (\(aid, _, _) -> aid == leader) hs
      (lt, gt) = (take i hs, drop (i + 1) hs)
  return $! gt ++ lt

-- | Select a faction leader. False, if nothing to do.
pickLeader :: MonadClientUI m => Bool -> ActorId -> m Bool
pickLeader verbose aid = do
  leader <- getLeaderUI
  saimMode <- getsSession saimMode
  if leader == aid
    then return False -- already picked
    else do
      body <- getsState $ getActorBody aid
      bodyUI <- getsSession $ getActorUI aid
      let !_A = assert (not (bproj body)
                        `blame` "projectile chosen as the leader"
                        `swith` (aid, body)) ()
      -- Even if it's already the leader, give his proper name, not 'you'.
      let subject = partActor bodyUI
      when verbose $ msgAdd $ makeSentence [subject, "picked as a leader"]
      -- Update client state.
      updateClientLeader aid
      -- Move the xhair, if active, to the new level.
      case saimMode of
        Nothing -> return ()
        Just _ ->
          modifySession $ \sess -> sess {saimMode = Just $ AimMode $ blid body}
      -- Inform about items, etc.
      itemsBlurb <- lookAtItems True (bpos body) aid
      when verbose $ msgAdd itemsBlurb
      return True

pickLeaderWithPointer :: MonadClientUI m => m MError
pickLeaderWithPointer = do
  CCUI{coscreen=ScreenContent{rheight}} <- getsSession sccui
  lidV <- viewedLevelUI
  side <- getsClient sside
  fact <- getsState $ (EM.! side) . sfactionD
  arena <- getArenaUI
  sactorUI <- getsSession sactorUI
  ours <- getsState $ filter (not . bproj . snd)
                      . actorAssocs (== side) lidV
  let oursUI = map (\(aid, b) -> (aid, b, sactorUI EM.! aid)) ours
      viewed = sortOn keySelected oursUI
      (autoDun, _) = autoDungeonLevel fact
      pick (aid, b) =
        if | blid b /= arena && autoDun ->
               failMsg $ showReqFailure NoChangeDunLeader
           | otherwise -> do
               void $ pickLeader True aid
               return Nothing
  Point{..} <- getsSession spointer
  -- Pick even if no space in status line for the actor's symbol.
  if | py == rheight - 1 && px == 0 -> memberBack True
     | py == rheight - 1 ->
         case drop (px - 1) viewed of
           [] -> return Nothing
             -- relaxed, due to subtleties of display of selected actors
           (aid, b, _) : _ -> pick (aid, b)
     | otherwise ->
         case find (\(_, b, _) -> bpos b == Point px (py - mapStartY)) oursUI of
           Nothing -> failMsg "not pointing at an actor"
           Just (aid, b, _) -> pick (aid, b)

itemOverlay :: MonadClientUI m => SingleItemSlots -> LevelId -> ItemBag -> m OKX
itemOverlay lSlots lid bag = do
  localTime <- getsState $ getLocalTime lid
  itemToF <- getsState $ flip itemToFull
  side <- getsClient sside
  factionD <- getsState sfactionD
  combEqp <- getsState $ combinedEqp side
  combOrgan <- getsState $ combinedOrgan side
  combInv <- getsState $ combinedInv side
  discoBenefit <- getsClient sdiscoBenefit
  shaBag <- getsState $ \s -> gsha $ sfactionD s EM.! side
  let !_A = assert (all (`elem` EM.elems lSlots) (EM.keys bag)
                    `blame` (lid, bag, lSlots)) ()
      markEqp iid t =
        if | iid `EM.member` combEqp
             || iid `EM.member` combOrgan -> T.snoc (T.init t) ']'
           | iid `EM.member` combInv
             || iid `EM.member` shaBag -> T.snoc (T.init t) '}'
           | otherwise -> t
      pr (l, iid) =
        case EM.lookup iid bag of
          Nothing -> Nothing
          Just kit@(k, _) ->
            let itemFull = itemToF iid
                colorSymbol =
                  if isJust $ lookup "condition" $ IK.ifreq $ itemKind itemFull
                  then let color = if benInEqp (discoBenefit EM.! iid)
                                   then Color.BrGreen
                                   else Color.BrRed
                       in Color.attrChar2ToW32 color
                                               (IK.isymbol $ itemKind itemFull)
                  else viewItem itemFull
                phrase = makePhrase
                  [snd $ partItemWsRanged side factionD k
                                          localTime itemFull kit]
                al = textToAL (markEqp iid $ slotLabel l)
                     <+:> [colorSymbol]
                     <+:> textToAL phrase
                kx = (Right l, (undefined, 0, length al))
            in Just ([al], kx)
      (ts, kxs) = unzip $ mapMaybe pr $ EM.assocs lSlots
      renumber y (km, (_, x1, x2)) = (km, (y, x1, x2))
  return (concat ts, zipWith renumber [0..] kxs)

skillsOverlay :: MonadClientRead m => ActorId -> m OKX
skillsOverlay aid = do
  b <- getsState $ getActorBody aid
  actorMaxSk <- getsState $ getActorMaxSkills aid
  let prSlot :: (Y, SlotChar) -> Ability.Skill -> (Text, KYX)
      prSlot (y, c) skill =
        let skName = skillName skill
            fullText t =
              makePhrase [ MU.Text $ slotLabel c
                         , MU.Text $ T.justifyLeft 22 ' ' skName
                         , MU.Text t ]
            valueText = skillToDecorator skill b
                        $ Ability.getSk skill actorMaxSk
            ft = fullText valueText
        in (ft, (Right c, (y, 0, T.length ft)))
      (ts, kxs) = unzip $ zipWith prSlot (zip [0..] allSlots) skillSlots
  return (map textToAL ts, kxs)

placesFromState :: ContentData PK.PlaceKind -> ClientOptions -> State
                -> EM.EnumMap (ContentId PK.PlaceKind)
                              (ES.EnumSet LevelId, Int, Int, Int)
placesFromState coplace ClientOptions{sexposePlaces} =
  let addEntries (es1, ne1, na1, nd1) (es2, ne2, na2, nd2) =
        (ES.union es1 es2, ne1 + ne2, na1 + na2, nd1 + nd2)
      insertZeros !em !pk _ = EM.insert pk (ES.empty, 0, 0, 0) em
      initialPlaces | not sexposePlaces = EM.empty
                    | otherwise = ofoldlWithKey' coplace insertZeros EM.empty
      placesFromLevel :: (LevelId, Level)
                      -> EM.EnumMap (ContentId PK.PlaceKind)
                                    (ES.EnumSet LevelId, Int, Int, Int)
      placesFromLevel (lid, Level{lentry}) =
        let f (PK.PEntry pk) em =
              EM.insertWith addEntries pk (ES.singleton lid, 1, 0, 0) em
            f (PK.PAround pk) em =
              EM.insertWith addEntries pk (ES.singleton lid, 0, 1, 0) em
            f (PK.PEnd pk) em =
              EM.insertWith addEntries pk (ES.singleton lid, 0, 0, 1) em
        in EM.foldr' f initialPlaces lentry
  in EM.unionsWith addEntries . map placesFromLevel . EM.assocs . sdungeon

placeParts :: (ES.EnumSet LevelId, Int, Int, Int) -> [MU.Part]
placeParts (_, ne, na, nd) =
  ["(" <> MU.CarWs ne "entrance" <> ")" | ne > 0]
  ++ ["(" <> MU.CarWs na "surrounding" <> ")" | na > 0]
  ++ ["(" <> MU.CarWs nd "end" <> ")" | nd > 0]

placesOverlay :: MonadClientRead m => m OKX
placesOverlay = do
  COps{coplace} <- getsState scops
  soptions <- getsClient soptions
  places <- getsState $ placesFromState coplace soptions
  let prSlot :: (Y, SlotChar)
             -> (ContentId PK.PlaceKind, (ES.EnumSet LevelId, Int, Int, Int))
             -> (Text, KYX)
      prSlot (y, c) (pk, (es, ne, na, nd)) =
        let placeName = PK.pname $ okind coplace pk
            parts = placeParts (es, ne, na, nd)
            markPlace t = if ne + na + nd == 0
                          then T.snoc (T.init t) '>'
                          else t
            ft = makePhrase $ MU.Text (markPlace $ slotLabel c)
                 : MU.Text placeName
                 : parts
        in (ft, (Right c, (y, 0, T.length ft)))
      (ts, kxs) = unzip $ zipWith prSlot (zip [0..] allSlots) $ EM.assocs places
  return (map textToAL ts, kxs)

pickNumber :: MonadClientUI m => Bool -> Int -> m (Either MError Int)
pickNumber askNumber kAll = assert (kAll >= 1) $ do
  let shownKeys = [ K.returnKM, K.spaceKM, K.mkChar '+', K.mkChar '-'
                  , K.backspaceKM, K.escKM ]
      frontKeyKeys = shownKeys ++ map K.mkChar ['0'..'9']
      gatherNumber kCur = assert (1 <= kCur && kCur <= kAll) $ do
        let kprompt = "Choose number:" <+> tshow kCur
        promptAdd0 kprompt
        sli <- reportToSlideshow shownKeys
        ekkm <- displayChoiceScreen "" ColorFull False
                                    sli frontKeyKeys
        case ekkm of
          Left kkm ->
            case K.key kkm of
              K.Char '+' ->
                gatherNumber $ if kCur + 1 > kAll then 1 else kCur + 1
              K.Char '-' ->
                gatherNumber $ if kCur - 1 < 1 then kAll else kCur - 1
              K.Char l | kCur * 10 + Char.digitToInt l > kAll ->
                gatherNumber $ if Char.digitToInt l == 0
                               then kAll
                               else min kAll (Char.digitToInt l)
              K.Char l -> gatherNumber $ kCur * 10 + Char.digitToInt l
              K.BackSpace -> gatherNumber $ max 1 (kCur `div` 10)
              K.Return -> return $ Right kCur
              K.Esc -> weaveJust <$> failWith "never mind"
              K.Space -> return $ Left Nothing
              _ -> error $ "unexpected key" `showFailure` kkm
          Right sc -> error $ "unexpected slot char" `showFailure` sc
  if | kAll == 1 || not askNumber -> return $ Right kAll
     | otherwise -> do
         res <- gatherNumber kAll
         case res of
           Right k | k <= 0 -> error $ "" `showFailure` (res, kAll)
           _ -> return res

-- | Produces a textual description of the tile at a position.
lookAtTile :: MonadClientUI m
           => Bool       -- ^ can be seen right now?
           -> Point      -- ^ position to describe
           -> ActorId    -- ^ the actor that looks
           -> LevelId    -- ^ level the position is at
           -> m Text
lookAtTile canSee p aid lidV = do
  COps{cotile, coplace} <- getsState scops
  side <- getsClient sside
  factionD <- getsState sfactionD
  b <- getsState $ getActorBody aid
  lvl <- getLevel lidV
  embeds <- getsState $ getEmbedBag lidV p
  itemToF <- getsState $ flip itemToFull
  seps <- getsClient seps
  mnewEps <- makeLine False b p seps
  localTime <- getsState $ getLocalTime lidV
  let aims = isJust mnewEps
      tile = okind cotile $ lvl `at` p
      vis | TK.tname tile == "unknown space" = "that is"
          | not canSee = "you remember"
          | not aims = "you are aware of"
          | otherwise = "you see"
      tilePart = MU.AW $ MU.Text $ TK.tname tile
      entrySentence pk blurb =
        makeSentence [blurb, MU.Text $ PK.pname $ okind coplace pk]
      elooks = case EM.lookup p $ lentry lvl of
        Nothing -> ""
        Just (PK.PEntry pk) -> entrySentence pk "it is an entrance to"
        Just (PK.PAround pk) -> entrySentence pk "it surrounds"
        Just (PK.PEnd pk) -> entrySentence pk "it ends"
      itemLook (iid, kit@(k, _)) =
        let itemFull = itemToF iid
            (temporary, nWs) = partItemWs side factionD k localTime itemFull kit
            verb = if k == 1 || temporary then "is" else "are"
            ik = itemKind itemFull
            desc = IK.idesc ik
        in makeSentence ["There", verb, nWs] <+> desc
      ilooks = T.intercalate " " $ map itemLook $ EM.assocs embeds
  return $! makeSentence [vis, tilePart] <+> elooks <+> ilooks

-- | Produces a textual description of actors at a position.
lookAtActors :: MonadClientUI m
             => Point      -- ^ position to describe
             -> LevelId    -- ^ level the position is at
             -> m Text
lookAtActors p lidV = do
  side <- getsClient sside
  inhabitants <- getsState $ \s -> maybeToList (posToBigAssoc p lidV s)
                                   ++ posToProjAssocs p lidV s
  sactorUI <- getsSession sactorUI
  let inhabitantsUI =
        map (\(aid2, b2) -> (aid2, b2, sactorUI EM.! aid2)) inhabitants
  itemToF <- getsState $ flip itemToFull
  factionD <- getsState sfactionD
  let actorsBlurb = case inhabitants of
        [] -> ""
        (_, body) : rest ->
          let itemFull = itemToF (btrunk body)
              bfact = factionD EM.! bfid body
              -- Even if it's the leader, give his proper name, not 'you'.
              subjects = map (\(_, _, bUI) -> partActor bUI)
                             inhabitantsUI
              -- No "a" prefix even if singular and inanimate, to distinguish
              -- from items lying on the floor (and to simplify code).
              (subject, person) = squashedWWandW subjects
              resideVerb = case bwatch body of
                WWatch -> "be here"
                WWait 0 -> "idle here"
                WWait _ -> "brace for impact"
                WSleep -> "sleep here"
                WWake -> "be waking up"
              guardVerbs = guardItemVerbs body bfact
              verbs = resideVerb : guardVerbs
              factDesc = case jfid $ itemBase itemFull of
                Just tfid | tfid /= bfid body ->
                  let dominatedBy = if bfid body == side
                                    then "us"
                                    else gname bfact
                      tfact = factionD EM.! tfid
                  in "Originally of" <+> gname tfact
                     <> ", now fighting for" <+> dominatedBy <> "."
                _ | bfid body == side -> ""  -- just one of us
                _ | bproj body -> "Launched by" <+> gname bfact <> "."
                _ -> "One of" <+> gname bfact <> "."
              idesc = IK.idesc $ itemKind itemFull
              -- If many different actors, only list names.
              sameTrunks = all (\(_, b) -> btrunk b == btrunk body) rest
              desc = if sameTrunks then factDesc <+> idesc else ""
              -- Both description and faction blurb may be empty.
              pdesc = if desc == "" then "" else "(" <> desc <> ")"
          in if null rest || bwatch body == WWatch && null guardVerbs
             then makeSentence
                    [MU.SubjectVVxV "and" person MU.Yes subject verbs]
                  <+> pdesc
             else makeSentence [subject, "can be seen"]
                  <+> if bwatch body == WWatch && null guardVerbs
                      then ""
                      else makeSentence [MU.SubjectVVxV "and" MU.Sg3rd MU.Yes
                                                        (head subjects) verbs]
  return $! actorsBlurb

guardItemVerbs :: Actor -> Faction -> [MU.Part]
guardItemVerbs body _fact =
  -- In reality, currently the client knows all the items
  -- in eqp and inv of the foe, but we may remove the knowledge
  -- in the future and, anyway, it would require a dedicated
  -- UI mode beyond a couple of items per actor.
  --
  -- OTOH, shares stash is currently secret for other factions, so that
  -- case would never be triggered except for our own actors.
  -- We may want to relax that secrecy, but there are technical hurdles.
  let itemsSize = EM.size (beqp body) + EM.size (binv body)
      belongingsVerbs | itemsSize == 1 = ["fondle a trinket"]
                      | itemsSize > 1 = ["guard a hoard"]
                      | otherwise = []
  in if bproj body
     then []
     else belongingsVerbs
--        ++ ["defend a shared stash" | not $ EM.null $ gsha fact]

-- | Produces a textual description of items at a position.
lookAtItems :: MonadClientUI m
            => Bool       -- ^ can be seen right now?
            -> Point      -- ^ position to describe
            -> ActorId    -- ^ the actor that looks
            -> m Text
lookAtItems canSee p aid = do
  itemToF <- getsState $ flip itemToFull
  b <- getsState $ getActorBody aid
  -- Not using @viewedLevelUI@, because @aid@ may be temporarily not a leader.
  saimMode <- getsSession saimMode
  let lidV = maybe (blid b) aimLevelId saimMode
  localTime <- getsState $ getLocalTime lidV
  subject <- partAidLeader aid
  is <- getsState $ getFloorBag lidV p
  side <- getsClient sside
  factionD <- getsState sfactionD
  let verb = MU.Text $ if | p == bpos b && lidV == blid b -> "stand on"
                          | canSee -> "notice"
                          | otherwise -> "remember"
      nWs (iid, kit@(k, _)) =
        partItemWs side factionD k localTime (itemToF iid) kit
  -- Here @squashedWWandW@ is not needed, because identical items at the same
  -- position are already merged in the floor item bag and multiple identical
  -- messages concerning different positions are merged with <x7>
  -- to distinguish from a stack of items at a single position.
  return $! if EM.null is then ""
            else makeSentence [ MU.SubjectVerbSg subject verb
                              , MU.WWandW $ map (snd . nWs) $ EM.assocs is]

-- | Produces a textual description of everything at the requested
-- level's position.
lookAtPosition :: MonadClientUI m => LevelId -> Point -> m Text
lookAtPosition lidV p = do
  leader <- getLeaderUI
  per <- getPerFid lidV
  let canSee = ES.member p (totalVisible per)
  -- Show general info about current position.
  tileBlurb <- lookAtTile canSee p leader lidV
  actorsBlurb <- lookAtActors p lidV
  itemsBlurb <- lookAtItems canSee p leader
  Level{lsmell, ltime} <- getLevel lidV
  let smellBlurb = case EM.lookup p lsmell of
        Just sml | sml > ltime ->
          let Delta t = smellTimeout `timeDeltaSubtract`
                          (sml `timeDeltaToFrom` ltime)
              seconds = t `timeFitUp` timeSecond
          in "A smelly body passed here around" <+> tshow seconds <> "s ago."
        _ -> ""
  return $! tileBlurb <+> actorsBlurb <+> itemsBlurb <+> smellBlurb

displayItemLore :: MonadClientUI m
                => ItemBag -> Int -> (ItemId -> ItemFull -> Int -> Text) -> Int
                -> SingleItemSlots
                -> m Bool
displayItemLore itemBag meleeSkill promptFun slotIndex lSlots = do
  CCUI{coscreen=ScreenContent{rwidth, rheight}} <- getsSession sccui
  side <- getsClient sside
  arena <- getArenaUI
  let lSlotsElems = EM.elems lSlots
      lSlotsBound = length lSlotsElems - 1
      iid2 = lSlotsElems !! slotIndex
      kit2@(k, _) = itemBag EM.! iid2
  itemFull2 <- getsState $ itemToFull iid2
  localTime <- getsState $ getLocalTime arena
  factionD <- getsState sfactionD
  -- The hacky level 0 marks items never seen, but sent by server at gameover.
  jlid <- getsSession $ fromMaybe (toEnum 0) <$> EM.lookup iid2 . sitemUI
  let attrLine = itemDesc True side factionD meleeSkill
                          CGround localTime jlid itemFull2 kit2
      ov = splitAttrLine rwidth attrLine
      keys = [K.spaceKM, K.escKM]
             ++ [K.upKM | slotIndex /= 0]
             ++ [K.downKM | slotIndex /= lSlotsBound]
  promptAdd0 $ promptFun iid2 itemFull2 k
  slides <- overlayToSlideshow (rheight - 2) keys (ov, [])
  km <- getConfirms ColorFull keys slides
  case K.key km of
    K.Space -> return True
    K.Up ->
      displayItemLore itemBag meleeSkill promptFun (slotIndex - 1) lSlots
    K.Down ->
      displayItemLore itemBag meleeSkill promptFun (slotIndex + 1) lSlots
    K.Esc -> return False
    _ -> error $ "" `showFailure` km

viewLoreItems :: MonadClientUI m
              => Bool -> String -> SingleItemSlots -> ItemBag -> Text
              -> (Int -> SingleItemSlots -> m Bool)
              -> m K.KM
viewLoreItems enableSorting menuName lSlotsRaw trunkBag prompt examItem = do
  CCUI{coscreen=ScreenContent{rheight}} <- getsSession sccui
  arena <- getArenaUI
  revCmd <- revCmdMap
  itemToF <- getsState $ flip itemToFull
  let caretKey = revCmd (K.KM K.NoModifier $ K.Char '^')
                        HumanCmd.SortSlots
      keysPre = [K.spaceKM, K.mkChar '/', K.mkChar '?', K.escKM]
                ++ [caretKey | enableSorting]
      -- Here, unlike for inventory items, slots are not sorted persistently
      -- and only for the single slot category.
      lSlots = if enableSorting
               then lSlotsRaw
               else sortSlotMap itemToF lSlotsRaw
  promptAdd0 $
    prompt <+> if EM.null lSlots then "(Nothing here this time.)" else ""
  io <- itemOverlay lSlots arena trunkBag
  itemSlides <- overlayToSlideshow (rheight - 2) keysPre io
  let keyOfEKM (Left km) = km
      keyOfEKM (Right SlotChar{slotChar}) = [K.mkChar slotChar]
      allOKX = concatMap snd $ slideshow itemSlides
      keysMain = keysPre ++ concatMap (keyOfEKM . fst) allOKX
  ekm <- displayChoiceScreen menuName ColorFull False itemSlides keysMain
  case ekm of
    Left km | km == K.spaceKM -> return km
    Left km | km == K.mkChar '/' -> return km
    Left km | km == K.mkChar '?' -> return km
    Left km | km == caretKey ->
      viewLoreItems False menuName (sortSlotMap itemToF lSlotsRaw)
                    trunkBag prompt examItem
    Left km | km == K.escKM -> return km
    Left _ -> error $ "" `showFailure` ekm
    Right slot -> do
      let ix0 = fromJust $ findIndex (== slot) $ EM.keys lSlots
      go2 <- examItem ix0 lSlots
      if go2
      then viewLoreItems enableSorting menuName lSlots trunkBag prompt examItem
      else return K.escKM

cycleLore :: MonadClientUI m => [m K.KM] -> [m K.KM] -> m ()
cycleLore _ [] = return ()
cycleLore seen (m : rest) = do  -- @seen@ is needed for SPACE to end cycling
  km <- m
  if | km == K.spaceKM -> cycleLore (m : seen) rest
     | km == K.mkChar '/' -> if null rest
                             then cycleLore [] (reverse $ m : seen)
                             else cycleLore (m : seen) rest
     | km == K.mkChar '?' -> case seen of
                               prev : ps -> cycleLore ps (prev : m : rest)
                               [] -> case reverse (m : rest) of
                                 prev : ps -> cycleLore ps [prev]
                                 [] -> error "cycleLore: screens disappeared"
     | km == K.escKM -> return ()
     | otherwise -> error "cycleLore: unexpected key"

spoilsBlurb :: Text -> Int -> Int -> Text
spoilsBlurb currencyName total dungeonTotal =
  if | dungeonTotal == 0 ->  "All your spoils are of the practical kind."
     | total == 0 -> "You haven't found any genuine treasure."
     | otherwise -> makeSentence
         [ "your spoils are worth"
         , MU.CarWs total $ MU.Text currencyName
         , "out of the rumoured total"
         , MU.Cardinal dungeonTotal ]
