module Main where

import qualified Calc
import qualified Epic
import qualified IVs
import           IVs (IVs)
import qualified GameMaster
import           GameMaster (GameMaster)
import qualified MyPokemon
import           MyPokemon (MyPokemon)
import qualified TweakLevel

import qualified Options.Applicative as O
import           Options.Applicative ((<**>))
import           Data.Semigroup ((<>))

import           Control.Monad (join)
import qualified Data.ByteString as B
import qualified Data.Yaml.Builder as Builder
import qualified System.Exit as Exit

data Options = Options {
  maybeTweakLevel :: Maybe (Float -> Float),
  maybeFilename  :: Maybe String
}

getOptions :: IO Options
getOptions =
  let opts = Options <$> optMaybeTweakLevel <*> optFilename
      optMaybeTweakLevel = TweakLevel.optMaybeTweakLevel
      optFilename = O.optional $ O.argument O.str (O.metavar "FILENAME")
      options = O.info (opts <**> O.helper)
        (  O.fullDesc
        <> O.progDesc "Calculate pokemon values from IVs.")
      prefs = O.prefs O.showHelpOnEmpty
  in O.customExecParser prefs options

main = Epic.catch (
  do
    options <- getOptions

    gameMaster <- join $ GameMaster.load

    myPokemon <- join $ MyPokemon.load $ maybeFilename options

    myNewPokemon <-
      mapM (updateFromIVs gameMaster (maybeTweakLevel options)) myPokemon
    B.putStr $ Builder.toByteString myNewPokemon
  )
  $ Exit.die

updateFromIVs :: (Epic.MonadCatch m) =>
  GameMaster -> Maybe (Float -> Float) -> MyPokemon -> m MyPokemon
updateFromIVs gameMaster maybeTweakLevel myPokemon = do
  pokemonBase <-
    GameMaster.getPokemonBase gameMaster $ MyPokemon.species myPokemon
  let ivs = MyPokemon.ivs myPokemon
      ivs' = case maybeTweakLevel of
        Nothing -> ivs
        Just tweakLevel -> IVs.tweakLevel tweakLevel ivs
      cp = Calc.cp gameMaster pokemonBase ivs'
      hp = Calc.hp gameMaster pokemonBase ivs'
      stardust =
        GameMaster.getStardustForLevel gameMaster $ IVs.level ivs'
  return $ myPokemon {
    MyPokemon.ivs = ivs',
    MyPokemon.cp = cp,
    MyPokemon.hp = hp,
    MyPokemon.stardust = stardust
    }
