module PokemonBase (
  PokemonBase,
  new,
  pokemonId,
  species,
  types,
  attack,
  defense,
  stamina,
  evolutions,
  quickMoves,
  chargeMoves,
  pvpFastMoves,
  pvpChargedMoves,
  hasEvolutions,
  baseCaptureRate,
  thirdMoveCost,
  purificationCost,
  addMove,
  addPvpFastMove,
  addPvpChargedMove,
) where

import           Type (Type)
import qualified Move
import           Move (Move)
import qualified PvpFastMove
import           PvpFastMove (PvpFastMove)
import qualified PvpChargedMove
import           PvpChargedMove (PvpChargedMove)

import           Data.Text (Text)

data PokemonBase = PokemonBase {
  pokemonId    :: String,
  species      :: String,
  types        :: [Type],
  attack       :: Int,
  defense      :: Int,
  stamina      :: Int,
  evolutions   :: [(String, Int)],
  quickMoves   :: [Move],
  chargeMoves  :: [Move],
  pvpFastMoves :: [PvpFastMove],
  pvpChargedMoves :: [PvpChargedMove],
  parent       :: Maybe String,
  baseCaptureRate :: Float,
  thirdMoveCost :: (Int, Int),  -- (stardust, candy)
  purificationCost :: (Int, Int)  -- (stardust, candy)
}

instance Show PokemonBase where
  show = species

new = PokemonBase

hasEvolutions :: PokemonBase -> Bool
hasEvolutions this = (not . null) $ PokemonBase.evolutions this

-- add*Move are for adding legacy moves.

addMove :: Move -> PokemonBase -> PokemonBase
addMove move this =
  if Move.isQuick move
    then this { quickMoves = move : quickMoves this }
    else this { chargeMoves = move : chargeMoves this }

addPvpFastMove :: PokemonBase -> PvpFastMove -> PokemonBase
addPvpFastMove this move =
  this { pvpFastMoves = move : pvpFastMoves this }

addPvpChargedMove :: PokemonBase -> PvpChargedMove -> PokemonBase
addPvpChargedMove this move =
  this { pvpChargedMoves = move : pvpChargedMoves this }
