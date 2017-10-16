-- So .: works with Strings.
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module MyPokemon (
  MyPokemon (MyPokemon, stats),
  load,
  name,
  species,
  cp,
  hp,
  stardust,
  quickName,
  chargeName,
  appraisal,
  stats,
  attack,
  defense,
  stamina,
  level,
) where

import           GHC.Generics
import qualified Data.Aeson.Types as Aeson
import qualified Data.Yaml as Yaml
import           Data.Yaml
import           Data.Yaml (FromJSON(..), (.:), (.:?))

import qualified Epic
import qualified Stats
import           Stats (Stats)

data MyPokemon = MyPokemon {
  name        :: String,
  species     :: String,
  quickName   :: String,
  chargeName  :: String,
  cp          :: Integer,
  hp          :: Integer,
  stardust    :: Integer,
  appraisal   :: String,
  stats       :: Maybe [Stats]
} deriving (Show, Generic)

instance Yaml.FromJSON MyPokemon where
  parseJSON (Yaml.Object y) =
    MyPokemon <$>
    y .: "name" <*>
    y .: "species" <*>
    y .: "quick" <*>
    y .: "charge" <*>
    y .: "cp" <*>
    y .: "hp" <*>
    y .: "dust" <*>
    y .: "appraisal" <*>
    y .:? "stats"
  parseJSON _ = fail "Expected Yaml.Object for MyPokemon.parseJSON"

instance Yaml.ToJSON MyPokemon where
  toEncoding = Aeson.genericToEncoding Aeson.defaultOptions

load :: Epic.MonadCatch m => FilePath -> IO (m [MyPokemon])
load filename = do
  either <- Yaml.decodeFileEither filename
  case either of
    Right myPokemon -> return $ pure myPokemon
    Left yamlParseException -> Epic.fail $ show yamlParseException

level :: Epic.MonadCatch m => MyPokemon -> m Float
level = getStat Stats.level

attack :: Epic.MonadCatch m => MyPokemon -> m Integer
attack = getStat Stats.attack

defense :: Epic.MonadCatch m => MyPokemon -> m Integer
defense = getStat Stats.defense

stamina :: Epic.MonadCatch m => MyPokemon -> m Integer
stamina = getStat Stats.stamina

getStat :: (Num a, Epic.MonadCatch m) => (Stats -> a) -> MyPokemon -> m a
getStat getter this = do
  case MyPokemon.stats this of
    Just (stats:_) -> return $ getter stats
    Nothing -> Epic.fail $ "No stats for " ++ (MyPokemon.name this)
