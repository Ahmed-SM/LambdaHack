-- | Atomic monads for handling atomic game state transformations.
module Game.LambdaHack.Atomic.MonadAtomic
  ( MonadAtomic(..)
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import Game.LambdaHack.Atomic.CmdAtomic
import Game.LambdaHack.Common.MonadStateRead

-- | The monad for executing atomic game state transformations.
class MonadStateRead m => MonadAtomic m where
  -- | Execute an arbitrary atomic game state transformation.
  execAtomic    :: CmdAtomic -> m ()
  -- | Execute an atomic command that really changes the state.
  execUpdAtomic :: UpdAtomic -> m ()
  execUpdAtomic = execAtomic . UpdAtomic
  -- | Execute an atomic command that only displays special effects.
  execSfxAtomic :: SfxAtomic -> m ()
  execSfxAtomic = execAtomic . SfxAtomic
