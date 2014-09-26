-- | Descripitons of items.
module Game.LambdaHack.Common.ItemDescription
  ( partItemN, partItem, partItemWs, partItemAW, partItemWownW
  , itemDesc, textAllAE, viewItem
  ) where

import Data.List
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import qualified NLP.Miniutter.English as MU

import Game.LambdaHack.Common.ActorState
import qualified Game.LambdaHack.Common.Color as Color
import qualified Game.LambdaHack.Common.Effect as Effect
import Game.LambdaHack.Common.EffectDescription
import Game.LambdaHack.Common.Flavour
import Game.LambdaHack.Common.Item
import Game.LambdaHack.Common.ItemStrongest
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Content.ItemKind

-- | The part of speech describing the item parameterized by the number
-- of effects/aspects to show..
partItemN :: Bool -> Int -> Container -> LevelId -> Time -> ItemFull
          -> (MU.Part, MU.Part)
partItemN fullInfo n c lid localTime itemFull =
  let genericName = jname $ itemBase itemFull
  in case itemDisco itemFull of
    Nothing ->
      let flav = flavourToName $ jflavour $ itemBase itemFull
      in (MU.Text $ flav <+> genericName, "")
    Just _ ->
      let effTs = filter (not . T.null) $ textAllAE fullInfo c itemFull
      -- The whole stack gets recharged at level change and activation,
      -- not only the item activated.
          it1 = filter (\(lid1, t1) -> lid1 == lid && t1 < localTime)
                       (itemTimer itemFull)
          len = length it1
          timer = if len == 0
                  then ""
                  else if itemK itemFull == 1 && len == 1
                  then "(charging)"
                  else "(" <> tshow len <+> "charging" <> ")"
          ts = take n effTs
               ++ (if length effTs > n then ["(...)"] else [])
               ++ [timer]
      in (MU.Text genericName, MU.Phrase $ map MU.Text ts)

-- | The part of speech describing the item.
partItem :: Container  -> LevelId -> Time -> ItemFull -> (MU.Part, MU.Part)
partItem = partItemN False 4

textAllAE :: Bool -> Container -> ItemFull -> [Text]
textAllAE fullInfo c ItemFull{itemBase, itemDisco} =
  let features | fullInfo = map featureToSuff $ sort $ jfeature itemBase
               | otherwise = []
  in case itemDisco of
    Nothing -> features
    Just ItemDisco{itemKind, itemAE} ->
      let periodicAspect :: Effect.Aspect a -> Bool
          periodicAspect (Effect.Periodic _) = True
          periodicAspect _ = False
          hurtEffect :: Effect.Effect a -> Bool
          hurtEffect (Effect.Hurt _) = True
          hurtEffect _ = False
          cstore = storeFromC c
          active = cstore `elem` [CEqp, COrgan]
                   || cstore == CGround && isJust (strengthEqpSlot itemBase)
          splitAE :: Ord a
                  => [Effect.Aspect a] -> (Effect.Aspect a -> Text)
                  -> [Effect.Effect a] -> (Effect.Effect a -> Text) -> [Text]
          splitAE aspects ppA effects ppE =
            let (periodicAs, restAs) = partition periodicAspect $ sort aspects
                (hurtEs, restEs) = partition hurtEffect $ sort effects
            in map ppA periodicAs ++ map ppE hurtEs
               ++ if active
                  then map ppA restAs ++ map ppE restEs
                  else map ppE restEs ++ map ppA restAs
          aets = case itemAE of
            Just ItemAspectEffect{jaspects, jeffects} ->
              splitAE jaspects aspectToSuffix
                      jeffects effectToSuffix
            Nothing ->
              splitAE (iaspects itemKind) kindAspectToSuffix
                      (ieffects itemKind) kindEffectToSuffix
      in aets ++ features

-- TODO: use kit
partItemWs :: ItemQuant -> Container  -> LevelId -> Time -> ItemFull -> MU.Part
partItemWs _kit@(count, _) c lid localTime itemFull =
  let (name, stats) = partItem c lid localTime itemFull
  in MU.Phrase [MU.CarWs count name, stats]

partItemAW :: Container  -> LevelId -> Time -> ItemFull -> MU.Part
partItemAW c lid localTime itemFull =
  let (name, stats) = partItem c lid localTime itemFull
  in MU.AW $ MU.Phrase [name, stats]

partItemWownW :: MU.Part -> Container  -> LevelId -> Time -> ItemFull -> MU.Part
partItemWownW partA c lid localTime itemFull =
  let (name, stats) = partItem c lid localTime itemFull
  in MU.WownW partA $ MU.Phrase [name, stats]

itemDesc :: Container  -> LevelId -> Time -> ItemFull -> Overlay
itemDesc c lid localTime itemFull =
  let (name, stats) = partItemN True 99 c lid localTime itemFull
      nstats = makePhrase [name, stats MU.:> ":"]
      desc = case itemDisco itemFull of
        Nothing -> "This item is as unremarkable as can be."
        Just ItemDisco{itemKind} -> idesc itemKind
      weight = jweight (itemBase itemFull)
      (scaledWeight, unitWeight) =
        if weight > 1000
        then (tshow $ fromIntegral weight / (1000 :: Double), "kg")
        else (tshow weight, "g")
      ln = abs $ fromEnum $ jlid (itemBase itemFull)
      colorSymbol = uncurry (flip Color.AttrChar) (viewItem $ itemBase itemFull)
      f color = Color.AttrChar Color.defAttr color
      lxsize = fst normalLevelBound + 1  -- TODO
      blurb =
        "D"  -- dummy
        <+> nstats
        <+> desc
        <+> makeSentence ["Weighs", MU.Text scaledWeight <> unitWeight]
        <+> makeSentence ["First found on level", MU.Text $ tshow ln]
      splitBlurb = splitText lxsize blurb
      attrBlurb = map (map f . T.unpack) splitBlurb
  in encodeOverlay $ (colorSymbol : tail (head attrBlurb)) : tail attrBlurb

viewItem :: Item -> (Char, Color.Attr)
viewItem item = ( jsymbol item
                , Color.defAttr {Color.fg = flavourToColor $ jflavour item} )
