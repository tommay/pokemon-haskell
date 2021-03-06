{-# LANGUAGE OverloadedStrings #-}

module Main where

import qualified Options.Applicative as O
import           Options.Applicative ((<|>), (<**>))
import           Data.Semigroup ((<>))

import qualified BattlerUtil
import           BattlerUtil (Battler)
import qualified Breakpoint
import qualified Epic
import qualified Friend
import           Friend (Friend)
import qualified IVs
import qualified GameMaster
import           GameMaster (GameMaster)
import qualified MakePokemon
import qualified MyPokemon
import qualified Pokemon
import           Pokemon (Pokemon)
import qualified PokeUtil
import qualified Util
import qualified Weather
import           Weather (Weather (..))

import           Control.Applicative (optional, some)
import           Control.Monad (join, forM, forM_)
import qualified System.Exit as Exit
import qualified Text.Printf as Printf

data Options = Options {
  maybeWeather :: Maybe Weather,
  maybeFriend  :: Maybe Friend,
  maybeFilename :: Maybe String,
  attacker :: Battler,
  defender :: Battler
}

getOptions :: IO Options
getOptions =
  let opts = Options <$> optWeather <*> optFriend
        <*> optFilename <*> optAttacker <*> optDefender
      optWeather = O.optional Weather.optWeather
      optFriend = O.optional Friend.optFriend
      optFilename = O.optional $ O.strOption
        (  O.long "file"
        <> O.short 'f'
        <> O.metavar "FILE"
        <> O.help "File to read my_pokemon from to get the attacker")
      optAttacker = O.argument
        BattlerUtil.optParseBattler
        (O.metavar "ATTACKER[:LEVEL]")
      optDefender = O.argument
        BattlerUtil.optParseBattler
        (O.metavar "DEFENDER[:LEVEL]")
      options = O.info (opts <**> O.helper)
        (  O.fullDesc
        <> O.progDesc "Battle some pokemon.")
      prefs = O.prefs O.showHelpOnEmpty
  in O.customExecParser prefs options

main =
  Epic.catch (
    do
      options <- getOptions

      gameMaster <- join $ GameMaster.load

      let weatherBonus =
            GameMaster.getWeatherBonus gameMaster $ maybeWeather options 

      attackerVariants <- case maybeFilename options of
        Just filename -> do
          myPokemon <- join $ MyPokemon.load $ Just filename
          let name = BattlerUtil.species $ attacker options
          case filter (Util.matchesAbbrevInsensitive name . MyPokemon.name)
              myPokemon of
            [myPokemon] -> MakePokemon.makePokemon gameMaster myPokemon
            [] -> Epic.fail $ "Can't find pokemon named " ++ name
            _ -> Epic.fail $ "Multiple pokemon named " ++ name
        Nothing ->
          BattlerUtil.makeBattlerVariants gameMaster $ attacker options

      defenderVariants <-
        BattlerUtil.makeBattlerVariants gameMaster $ defender options

      -- We can just use the first defender variant because we don't care
      -- about its moveset, just its level and ivs.
      let defender = head defenderVariants

      forM_ attackerVariants $ \ attacker -> do
        indent <- case attackerVariants of
          [_] -> return ""
          _ -> do
            putStrLn $ showPokemon attacker
            return "  "
        let friendBonus = Friend.damageBonus $ maybeFriend options
            breakpoints = Breakpoint.getBreakpoints
              gameMaster weatherBonus friendBonus attacker defender
        forM_ breakpoints $ \ (level, damage, dps) ->
          putStrLn $ Printf.printf "%s%-4s %d  %.1f"
            (indent :: String) (PokeUtil.levelToString level) damage dps
    )
    $ Exit.die

showPokemon :: Pokemon -> String
showPokemon pokemon =
  let ivs = Pokemon.ivs pokemon
  in Printf.printf "%s:%s/%d/%d/%d"
       (Pokemon.pname pokemon)
       (PokeUtil.levelToString $ IVs.level ivs)
       (IVs.attack ivs)
       (IVs.defense ivs)
       (IVs.stamina ivs)
