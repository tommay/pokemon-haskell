-- So .: works with literal Strings.
{-# LANGUAGE OverloadedStrings #-}

module Stats (
  Stats (Stats),
  level,
  attack,
  defense,
  stamina,
) where

import qualified Data.Scientific as Scientific
import           Data.Semigroup ((<>))
import qualified Data.Yaml as Yaml
import           Data.Yaml (FromJSON(..), (.:))
import qualified Data.Yaml.Builder as Builder
import           Data.Yaml.Builder ((.=))

import qualified Debug.Trace as Trace

data Stats = Stats {
  level       :: Float,
  attack      :: Int,
  defense     :: Int,
  stamina     :: Int
} deriving (Show)

instance Yaml.FromJSON Stats where
  parseJSON (Yaml.Object y) =
    Stats <$>
    y .: "level" <*>
    y .: "attack" <*>
    y .: "defense" <*>
    y .: "stamina"
  parseJSON _ = fail "Expected Yaml.Object for Stats.parseJSON"

instance Builder.ToYaml Stats where
  toYaml this =
    Builder.mapping [
      "level" .= level this,
      "attack" .= attack this,
      "defense" .= defense this,
      "stamina" .= stamina this
    ]

instance Builder.ToYaml Float where
  toYaml = Builder.scientific . Scientific.fromFloatDigits
