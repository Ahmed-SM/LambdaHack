{-# LANGUAGE DeriveGeneric, GeneralizedNewtypeDeriving, TypeFamilies #-}
-- | Breadth first search algorithm.
module Game.LambdaHack.Client.Bfs
  ( BfsDistance, MoveLegal(..), minKnownBfs, apartBfs, maxBfsDistance, fillBfs
  , AndPath(..), actorsAvoidedDist, findPathBfs
  , accessBfs
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , abortedKnownBfs, abortedUnknownBfs
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import           Control.Monad.ST.Strict
import           Data.Binary
import           Data.Bits (Bits, complement, (.&.), (.|.))
import qualified Data.EnumMap.Strict as EM
import qualified Data.IntMap.Strict as IM
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Unboxed.Mutable as VM
import           GHC.Generics (Generic)

import           Game.LambdaHack.Common.Level
import           Game.LambdaHack.Common.Point
import qualified Game.LambdaHack.Common.PointArray as PointArray
import           Game.LambdaHack.Common.Vector

-- | Weighted distance between points along shortest paths.
newtype BfsDistance = BfsDistance {bfsDistance :: Word8}
  deriving (Show, Eq, Ord, Enum, Bits)

instance PointArray.UnboxRepClass BfsDistance where
  type UnboxRep BfsDistance = Word8
  toUnboxRepUnsafe = bfsDistance
  fromUnboxRep = BfsDistance

-- | State of legality of moves between adjacent points.
data MoveLegal = MoveBlocked | MoveToOpen | MoveToClosed | MoveToUnknown
  deriving Eq

-- | The minimal distance value assigned to paths that don't enter
-- any unknown tiles.
minKnownBfs :: BfsDistance
minKnownBfs = BfsDistance $ toEnum $ (1 + fromEnum (maxBound :: Word8)) `div` 2

-- | The distance value that denotes no legal path between points,
-- either due to blocked tiles or pathfinding aborted at earlier tiles,
-- e.g., due to unknown tiles.
apartBfs :: BfsDistance
apartBfs = pred minKnownBfs

-- | Maximum value of the type.
maxBfsDistance :: BfsDistance
maxBfsDistance = BfsDistance (maxBound :: Word8)

-- | The distance value that denotes that path search was aborted
-- at this tile due to too large actual distance
-- and that the tile was known and not blocked.
-- It is also a true distance value for this tile
-- (shifted by minKnownBfs, as all distances of known tiles).
abortedKnownBfs :: BfsDistance
abortedKnownBfs = pred maxBfsDistance

-- | The distance value that denotes that path search was aborted
-- at this tile due to too large actual distance
-- and that the tile was unknown.
-- It is also a true distance value for this tile.
abortedUnknownBfs :: BfsDistance
abortedUnknownBfs = pred apartBfs

-- | Fill out the given BFS array.
-- Unsafe @PointArray@ operations are OK here, because the intermediate
-- values of the vector don't leak anywhere outside nor are kept unevaluated
-- and so they can't be overwritten by the unsafe side-effect.
--
-- When computing move cost, we assume doors openable at no cost,
-- because other actors use them, too, so the cost is shared and the extra
-- visiblity is valuable, too. We treat unknown tiles specially.
-- Whether suspect tiles are considered openable depends on @smarkSuspect@.
fillBfs :: PointArray.Array Word8
        -> Word8
        -> Point                          -- ^ starting position
        -> PointArray.Array BfsDistance   -- ^ initial array, with @apartBfs@
        -> ()
{-# INLINE fillBfs #-}
fillBfs lalter alterSkill source arr@PointArray.Array{..} =
  let unsafeWriteI :: PointI -> BfsDistance -> ()
      {-# INLINE unsafeWriteI #-}
      unsafeWriteI p c = runST $ do
        vThawed <- U.unsafeThaw avector
        VM.unsafeWrite vThawed p (bfsDistance c)
        void $ U.unsafeFreeze vThawed
      bfs :: BfsDistance -> [PointI] -> ()  -- modifies the vector
      bfs !distance !predK =
        let processKnown :: PointI -> [PointI] -> [PointI]
            processKnown !pos !succK2 =
              -- Terrible hack trigger warning!
              -- Unsafe ops inside @fKnown@ seem to be OK, for no particularly
              -- clear reason. The array value given to each p depends on
              -- array value only at p (it's not overwritten if already there).
              -- So the only problem with the unsafe ops writing at p is
              -- if one with higher depth (dist) is evaluated earlier
              -- than another with lower depth. The particular pattern of
              -- laziness and order of list elements below somehow
              -- esures the lowest possible depth is always written first.
              -- The code also doesn't keep a wholly evaluated list of all p
              -- at a given depth, but generates them on demand, unlike a fully
              -- strict version inside the ST monad. So it uses little memory
              -- and is fast.
              let fKnown :: [PointI] -> VectorI -> [PointI]
                  fKnown !l !move =
                    let !p = pos + move
                        visitedMove =
                          BfsDistance (arr `PointArray.accessI` p) /= apartBfs
                    in if visitedMove
                       then l
                       else let alter :: Word8
                                !alter = lalter `PointArray.accessI` p
                            in if | alterSkill < alter -> l
                                  | alter == 1 ->
                                      let distCompl =
                                            distance .&. complement minKnownBfs
                                      in unsafeWriteI p distCompl
                                         `seq` l
                                  | otherwise -> unsafeWriteI p distance
                                                 `seq` p : l
              in foldl' fKnown succK2 movesI
            succK4 = foldr processKnown [] predK
        in if null succK4 || distance == abortedKnownBfs
           then () -- no more dungeon positions to check, or we delved too deep
           else bfs (succ distance) succK4
  in bfs (succ minKnownBfs) [fromEnum source]

data AndPath =
    AndPath { pathSource :: Point    -- never included in @pathList@
            , pathList   :: [Point]
            , pathGoal   :: Point    -- needn't be @last pathList@
            , pathLen    :: Int      -- needn't be @length pathList@
            }
  | NoPath
  deriving (Show, Generic)

instance Binary AndPath

actorsAvoidedDist :: BfsDistance
actorsAvoidedDist = BfsDistance 5

-- | Find a path, without the source position, with the smallest length.
-- The @eps@ coefficient determines which direction (of the closest
-- directions available) that path should prefer, where 0 means north-west
-- and 1 means north. The path tries hard to avoid actors and tries to avoid
-- tiles that need altering and ambient light. Actors are avoided only close
-- to the start of the path, because  elsewhere they are likely to move
-- before they are reached. Even projectiles are avoided,
-- which sometimes has the effect of choosing a safer route
-- (regardless if the projectiles are friendly fire or not).
--
-- An unwelcome side effect of avoiding actors is that friends will sometimes
-- avoid displacing and instead perform two separate moves, wasting 1 turn
-- in total. But in corridors they will still displace and elsewhere
-- this scenario was quite rare already.
findPathBfs :: BigActorMap -> PointArray.Array Word8 -> (PointI -> Bool)
            -> Point -> Point -> Int
            -> PointArray.Array BfsDistance
            -> AndPath
{-# INLINE findPathBfs #-}
findPathBfs lbig lalter fovLit pathSource pathGoal sepsRaw
            arr@PointArray.Array{..} =
  let !pathGoalI = fromEnum pathGoal
      !pathSourceI = fromEnum pathSource
      eps = sepsRaw `mod` 4
      (mc1, mc2) = splitAt eps movesCardinalI
      (md1, md2) = splitAt eps movesDiagonalI
      -- Prefer cardinal directions when closer to the target, so that
      -- the enemy can't easily disengage.
      prefMoves = mc2 ++ reverse mc1 ++ md2 ++ reverse md1  -- fuzz
      track :: PointI -> BfsDistance -> [Point] -> [Point]
      track !pos !oldDist !suffix | oldDist == minKnownBfs =
        assert (pos == pathSourceI) suffix
      track pos oldDist suffix | oldDist == succ minKnownBfs =
        let !posP = toEnum pos
        in posP : suffix  -- avoid calculating minP and dist for the last call
      track pos oldDist suffix =
        let !dist = pred oldDist
            minChild :: PointI -> Bool -> Word8 -> [VectorI] -> PointI
            minChild !minP _ _ [] = minP
            minChild minP maxDark minAlter (mv : mvs) =
              let !p = pos + mv
                  backtrackingMove =
                    BfsDistance (arr `PointArray.accessI` p) /= dist
              in if backtrackingMove
                 then minChild minP maxDark minAlter mvs
                 else let free = dist < actorsAvoidedDist
                                 || p `IM.notMember` EM.enumMapToIntMap lbig
                          alter | free = lalter `PointArray.accessI` p
                                | otherwise = maxBound-1  -- occupied; disaster
                          dark = not $ fovLit p
                      -- Prefer paths without actors and through
                      -- more easily opened tiles and, secondly,
                      -- in the ambient dark (even if light carried,
                      -- because it can be taken off at any moment).
                      in if | alter == 0 && dark -> p  -- speedup
                            | alter < minAlter -> minChild p dark alter mvs
                            | dark > maxDark && alter == minAlter ->
                              minChild p dark alter mvs
                            | otherwise -> minChild minP maxDark minAlter mvs
            -- @maxBound@ means not alterable, so some child will be lower
            !newPos = minChild pos{-dummy-} False maxBound prefMoves
#ifdef WITH_EXPENSIVE_ASSERTIONS
            !_A = assert (newPos /= pos) ()
#endif
            !posP = toEnum pos
        in track newPos dist (posP : suffix)
      !goalDist = BfsDistance $ arr `PointArray.accessI` pathGoalI
      pathLen = fromEnum $ goalDist .&. complement minKnownBfs
      pathList = track pathGoalI (goalDist .|. minKnownBfs) []
      andPath = AndPath{..}
  in assert (BfsDistance (arr `PointArray.accessI` pathSourceI)
             == minKnownBfs) $
     if goalDist /= apartBfs && pathLen < 2 * chessDist pathSource pathGoal
     then andPath
     else let f :: (Point, Int, Int, Int) -> Point -> BfsDistance
                -> (Point, Int, Int, Int)
              f acc@(pAcc, dAcc, chessAcc, sumAcc) p d =
                if d <= abortedUnknownBfs  -- works in visible secrets mode only
                   || d /= apartBfs && adjacent p pathGoal  -- works for stairs
                then let dist = fromEnum $ d .&. complement minKnownBfs
                         chessNew = chessDist p pathGoal
                         sumNew = dist + 2 * chessNew
                         resNew = (p, dist, chessNew, sumNew)
                     in case compare sumNew sumAcc of
                       LT -> resNew
                       EQ -> case compare chessNew chessAcc of
                         LT -> resNew
                         EQ -> case compare dist dAcc of
                           LT -> resNew
                           EQ | euclidDistSq p pathGoal
                                < euclidDistSq pAcc pathGoal -> resNew
                           _ -> acc
                         _ -> acc
                       _ -> acc
                else acc
              initAcc = (originPoint, maxBound, maxBound, maxBound)
              (pRes, dRes, _, sumRes) = PointArray.ifoldlA' f initAcc arr
          in if sumRes == maxBound
                || goalDist /= apartBfs && pathLen < sumRes
             then if goalDist /= apartBfs then andPath else NoPath
             else let pathList2 = track (fromEnum pRes)
                                        (toEnum dRes .|. minKnownBfs) []
                  in AndPath{pathList = pathList2, pathLen = sumRes, ..}

-- | Access a BFS array and interpret the looked up distance value.
accessBfs :: PointArray.Array BfsDistance -> Point -> Maybe Int
accessBfs bfs p =
  let dist = bfs PointArray.! p
  in if dist == apartBfs
     then Nothing
     else Just $ fromEnum $ dist .&. complement minKnownBfs
