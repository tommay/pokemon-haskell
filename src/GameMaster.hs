-- So .: works with Strings.
{-# LANGUAGE OverloadedStrings #-}

module GameMaster where

import qualified Data.Text as Text
import           Data.Text (Text)
import qualified Data.Yaml as Yaml
import           Data.Yaml (ParseException)
import Data.Yaml (FromJSON(..), (.:))  -- ???
import qualified Data.HashMap.Strict as HashMap
import           Data.HashMap.Strict (HashMap)
import qualified Data.Vector as Vector
import           Data.Vector (Vector)

data GameMaster = GameMaster {
  pokemonBases  :: HashMap String PokemonBase,
  moves         :: HashMap String Move,
  cpMultipliers :: Vector Float,
  stardustCost  :: Vector Int
} deriving (Show)

data PokemonBase = PokemonBase {
  types        :: [String],
  attack       :: Int,
  defense      :: Int,
  stamina      :: Int,
  evolutions   :: [String],
  quickMoves   :: [String],
  chargeMoves  :: [String],
  parent       :: Maybe String
} deriving (Show)

data Type = Type {
  effectiveness :: HashMap Text Float,
  name          :: Text,
  stab          :: Float
} deriving (Show)


data Move = Move deriving (Show)

type Result = Maybe [Yaml.Object]

load :: FilePath -> IO (Either ParseException Result)
load filename =
  fmap makeGameMaster <$> Yaml.decodeFileEither filename

makeGameMaster :: Yaml.Object -> Result
makeGameMaster yamlObject =
  case getItemTemplates yamlObject of
    Just itemTemplates ->
      let types = makeObjects "typeEffective" "attackType" makeType itemTemplates
      in Just []
    _ -> Nothing

makeObjects ::
  Text -> Text -> (Yaml.Object -> a) -> [Yaml.Object] -> HashMap Text a
makeObjects filterKey nameKey makeObject itemTemplates =
  foldr (\ yamlObject hash ->
          case HashMap.lookup nameKey yamlObject of
            Just (Yaml.String name) ->
              let obj = makeObject yamlObject
              in HashMap.insert name obj hash
            _ -> hash)
    HashMap.empty
    $ filter (hasKey filterKey) itemTemplates

makeType :: Yaml.Object -> Type
makeType yamlObject =
  Type HashMap.empty "" 0

-- "hasKey" can be done the Yaml.Parser way but it's really convoluted
-- compared to this simple key lookup.
--
hasKey :: Text -> Yaml.Object -> Bool
hasKey = HashMap.member

-- Here it's nice to use Yaml.Parser because it will error if we don't
-- get a [Yaml.Object].
--
getItemTemplates :: Yaml.Object -> Maybe [Yaml.Object]
getItemTemplates yamlObject =
  Yaml.parseMaybe (.: "itemTemplates") yamlObject

{-
  GameMaster HashMap.empty HashMap.empty Vector.empty Vector.empty
-}