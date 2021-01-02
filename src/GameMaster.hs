-- So .: works with literal Strings.
{-# LANGUAGE OverloadedStrings #-}

-- This uses the Data.Store serialization library to cache a binary
-- version of GameMaster because reading GAME_MASTER.yaml has gotten
-- pretty slow as the file gets larger and larger.  To do this,
-- GameMaster and the types it uses need to be instances of the
-- library's serializable typeclass.  The easiest way to do that is to
-- use GHC.Generics and make the types instances of Generic and then
-- they can be made instances of the appropriate type with some kind
-- of Generic magic
--
-- Note that the cache file is about three times bigger than the yaml
-- file because all the Types and Moves get written for every
-- PokemonBase, and all the string are ucs-32 or something instead of
-- utf-8.
--
-- Reading it back in seems to take half the time of reading the yaml
-- file which isn't as good as I'd hoped.

{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}

module GameMaster (
  GameMaster,
  load,
  getPokemonBase,
  getQuick,
  getCharge,
  getCpMultiplier,
  getLevelsForStardust,
  getStardustForLevel,
  allPokemonBases,
  allSpecies,
  getType,
  getAllTypes,
  getWeatherBonus,
  defaultWeatherBonus,
  dustAndLevel,
  candyAndLevel,
  allLevels,
  powerUpLevels,
  nextLevel,
  allLevelAndCost,
  shadowStardustMultiplier,
  shadowCandyMultiplier,
  purifiedStardustMultiplier,
  purifiedCandyMultiplier,
  luckyPowerUpStardustDiscountPercent,
) where

import qualified Cost
import           Cost (Cost)
import qualified Epic
import qualified Move
import           Move (Move)
import qualified PokemonBase
import           PokemonBase (PokemonBase)
import qualified PvpChargedMove
import           PvpChargedMove (PvpChargedMove)
import qualified PvpFastMove
import           PvpFastMove (PvpFastMove)
import           StringMap (StringMap)
import qualified Type
import           Type (Type)
import qualified Util
import qualified Weather
import           Weather (Weather (..))
import           WeatherBonus (WeatherBonus)

import qualified Data.List
import qualified Data.ByteString as B
import qualified Data.Yaml as Yaml
import           Data.Yaml ((.:), (.:?), (.!=))
import qualified Data.Store as Store
import           GHC.Generics (Generic)

import           Control.Monad (join, foldM, liftM)
import qualified Data.HashMap.Strict as HashMap
import           Data.HashMap.Strict (HashMap)
import qualified Data.List as List
import qualified Data.List.Extra
import qualified Data.Maybe as Maybe
import           Data.Maybe (mapMaybe)
import           Data.Semigroup ((<>))
import           Data.Text.Conversions (convertText)
import           Data.Time.Clock (UTCTime)
import qualified Data.Vector as Vector
import           Data.Vector (Vector, (!))
import qualified System.Directory
import           System.IO.Error (tryIOError)
import qualified Text.Regex as Regex

import qualified Debug as D

data GameMaster = GameMaster {
  types         :: StringMap Type,
  moves         :: StringMap Move,
  forms         :: StringMap [String],
  pokemonBases  :: StringMap PokemonBase,
  cpMultipliers :: Vector Float,
  stardustCost  :: [Int],
  candyCost     :: [Int],
  shadowStardustMultiplier   :: Float,
  shadowCandyMultiplier      :: Float,
  purifiedStardustMultiplier :: Float,
  purifiedCandyMultiplier    :: Float,
  xlCandyCost   :: [Int],
  luckyPowerUpStardustDiscountPercent :: Float,
  weatherBonusMap :: HashMap Weather (HashMap Type Float)
} deriving (Show, Generic)

instance Store.Store GameMaster
instance Store.Store Type
instance Store.Store Move
instance Store.Store PokemonBase
instance Store.Store Weather

type ItemTemplate = Yaml.Object

new = GameMaster

load :: Epic.MonadCatch m => IO (m GameMaster)
load = do
  let filename = "GAME_MASTER.yaml"
  let cacheFileName = "/tmp/" ++ filename ++ ".cache"
  maybeGameMaster <- do
    cacheIsNewer <- cacheFileName `isNewerThan` filename
    if cacheIsNewer
      then maybeLoadFromCache cacheFileName
      else return $ Nothing
  case maybeGameMaster of
    Just gameMaster -> return $ pure gameMaster
    Nothing -> do
      mGameMaster <- loadFromYaml filename
      case mGameMaster of
         Left exception -> Epic.fail $ show exception
         Right gameMaster -> do
           writeCache cacheFileName gameMaster
           return $ pure gameMaster

loadFromYaml :: Epic.MonadCatch m => FilePath -> IO (m GameMaster)
loadFromYaml filename = do
  either <- Yaml.decodeFileEither filename
  case either of
    Left yamlParseException -> Epic.fail $ show yamlParseException
    Right yamlObjects -> return $ makeGameMaster yamlObjects

writeCache :: FilePath -> GameMaster -> IO ()
writeCache filename gameMaster =
  B.writeFile filename $ Store.encode gameMaster  

maybeLoadFromCache :: FilePath -> IO (Maybe GameMaster)
maybeLoadFromCache filename = do
  either <- tryIOError $ B.readFile filename
  return $ case either of
    Left ioError -> Nothing
    Right byteString -> case Store.decode byteString of
      Left peekException -> Nothing
      Right gameMaster -> Just gameMaster

isNewerThan :: FilePath -> FilePath -> IO Bool
name1 `isNewerThan` name2 = do
  maybeTime1 <- getMaybeModificationTime name1
  maybeTime2 <- getMaybeModificationTime name2
  let Just time1 >> Just time2 = time1 > time2
      _ >> _ = False
  return $ maybeTime1 >> maybeTime2

-- Returns a file's modification time if the file exists and we can get
-- its modification time, or Nothing.
--
getMaybeModificationTime :: FilePath -> IO (Maybe UTCTime)
getMaybeModificationTime filename = do
  either <- tryIOError $ System.Directory.getModificationTime filename
  return $ case either of
    Left ioError -> Nothing
    Right time -> Just time

allPokemonBases :: GameMaster -> [PokemonBase]
allPokemonBases this =
  -- Doing nubOn battleStats filters out pokemon that, for battle, are
  -- identical to pokemon earlier in the list, such as shadow and
  -- purified pokemon which are effectively the same as non-shadow and
  -- non-purified pokemon, and also weird things like the _FALL_2019
  -- pokemon wearing halloween costumes.  It should robustly filter
  -- out any further weird things down the line.  Sorting by the
  -- species name first will put the plain-named pokemon first so
  -- they will be kept by nub.
  -- XXX Currently (11/2019) dugtrio_purified has 2 more defense than normal
  -- so dugtrio_purified makes it through.
  let removeLegacy = filter (not . Move.isLegacy)
      battleStats base =
        (PokemonBase.pokemonId base,
         PokemonBase.types base,
         PokemonBase.attack base,
         PokemonBase.defense base,
         PokemonBase.stamina base,
         removeLegacy $ PokemonBase.quickMoves base,
         removeLegacy $ PokemonBase.chargeMoves base)
  in Data.List.Extra.nubOn battleStats $ List.sortOn PokemonBase.species $
       HashMap.elems $ pokemonBases this

allSpecies :: GameMaster -> [String]
allSpecies = map PokemonBase.species . GameMaster.allPokemonBases

getPokemonBase :: Epic.MonadCatch m => GameMaster -> String -> m PokemonBase
getPokemonBase this speciesName =
  let getPokemonBase' = GameMaster.lookup "species" (pokemonBases this)
  in case getPokemonBase' speciesName of
       Right pokemonBase -> return pokemonBase
       Left _ -> case getPokemonBase' (speciesName ++ "_NORMAL") of
         Right pokemonBase -> return pokemonBase
         Left _ -> do
           forms <- GameMaster.lookup "species" (forms this) speciesName
           Epic.fail $
             speciesName ++ " has no normal form.  Specify one of " ++
             Util.toLower (commaSeparated forms) ++ "."

getMove :: Epic.MonadCatch m => GameMaster -> String -> m Move
getMove this moveName  =
  GameMaster.lookup "move" (moves this) moveName

getQuick :: Epic.MonadCatch m => GameMaster -> String -> m Move
getQuick this moveName = do
  move <- getMove this (moveName ++ "_fast")
  case Move.isQuick move of
    True -> return move
    False -> Epic.fail $ moveName ++ " is not a quick move"

getCharge :: Epic.MonadCatch m => GameMaster -> String -> m Move
getCharge this moveName = do
  move <- getMove this moveName
  case Move.isCharge move of
    True -> return move
    False -> Epic.fail $ moveName ++ " is not a charge move"

getCpMultiplier :: GameMaster -> Float -> Float
getCpMultiplier this level =
  let cpMultipliers' = GameMaster.cpMultipliers this
      intLevel = floor level
  in case fromIntegral intLevel == level of
    True -> cpMultipliers' ! (intLevel - 1)
    False ->
      let cp0 = cpMultipliers' ! (intLevel - 1)
          cp1 = cpMultipliers' ! intLevel
      in sqrt $ (cp0*cp0 + cp1*cp1) / 2

costAndLevel :: [Int] -> [(Int, Float)]
costAndLevel costs =
  init $ concat $ map (\ (cost, level) -> [(cost, level), (cost, level + 0.5)])
    $ zip costs [1..]

levelAndCost :: [a] -> [(Float, a)]
levelAndCost costs =
  init $ concat $ map (\ (level, cost) -> [(level, cost), (level + 0.5, cost)])
    $ zip [1..] costs

allLevelAndCost :: GameMaster -> [(Float, Cost)]
allLevelAndCost this =
  let zeroXlCandy = map (const 0) $ takeWhile (/= 0) $ candyCost this
      allXlCandyCost = zeroXlCandy ++ xlCandyCost this
      allCosts = zip3 (stardustCost this) (candyCost this) allXlCandyCost
      toCost (dust, candy, xlCandy) = Cost.new dust candy xlCandy
  in levelAndCost $ map toCost allCosts

powerupCost :: GameMaster -> Float -> Maybe Cost
powerupCost this level =
  Data.List.lookup level (allLevelAndCost this)

dustAndLevel :: GameMaster -> [(Int, Float)]
dustAndLevel this =
  costAndLevel $ stardustCost this

candyAndLevel :: GameMaster -> [(Int, Float)]
candyAndLevel this =
  costAndLevel $ candyCost this

-- allLevels returns all levels up through 45 which is the max level
-- that team leaders and Team Rocket have.  Normal players can power
-- up to 40 then get one more level with best buddy oost.
--
allLevels :: GameMaster -> [Float]
allLevels =
  init . concat . map (\ (level, _) -> [level, level + 0.5])
    . zip [1..] . Vector.toList . cpMultipliers

-- powerUpLevels returns the levels that pokemon can be powered up to.
-- XXX for now I'm excluding levels that require candyXL.
--
powerUpLevels :: GameMaster -> [Float]
powerUpLevels =
  take 79 . map fst . allLevelAndCost

nextLevel :: GameMaster -> Float -> Maybe (Int, Int, Float)
nextLevel this level =
  let candy = Maybe.fromJust $ candyAtLevel this level
      stardust = Maybe.fromJust $ dustAtLevel this level
  in case filter (> level) $ allLevels this of
       [] -> Nothing
       list -> Just (candy, stardust, minimum list)

getLevelsForStardust :: (Epic.MonadCatch m) => GameMaster -> Int -> m [Float]
getLevelsForStardust this starDust =
  case map snd $ filter (\(dust, _) -> dust == starDust) $ dustAndLevel this of
    [] -> Epic.fail $ "Bad dust amount: " ++ show starDust
    levels -> return levels

getCostForLevel :: GameMaster -> Float -> Cost
getCostForLevel this level =
  Maybe.fromJust $ Data.List.lookup level $ allLevelAndCost this

getStardustForLevel :: GameMaster -> Float -> Int
getStardustForLevel this level =
  Cost.dust $ getCostForLevel this level

lookup :: Epic.MonadCatch m => String -> StringMap a -> String -> m a
lookup what hash key =
  case HashMap.lookup (sanitize key) hash of
    Just val -> return val
    Nothing -> Epic.fail $ "No such " ++ what ++ ": " ++ key

sanitize :: String -> String
sanitize string =
  let nonWordChars = Regex.mkRegex "\\W"
  in Util.toUpper $ Regex.subRegex nonWordChars string "_"

makeGameMaster :: Epic.MonadCatch m => [Yaml.Object] -> m GameMaster
makeGameMaster yamlObjects = do
  itemTemplates <- getItemTemplates yamlObjects
  types <- getTypes itemTemplates
  pvpFastMoves <- getPvpFastMoves types itemTemplates
  pvpChargedMoves <- getPvpChargedMoves types itemTemplates
  moves <- getMoves (makeMaybeMove types pvpFastMoves pvpChargedMoves)
    itemTemplates
  forms <- getForms itemTemplates
  pokemonBases <-
    makeObjects "pokemonSettings" (getSpeciesForPokemonBase forms)
      (makePokemonBase types moves forms)
      (filter (hasFormIfRequired forms) itemTemplates)
  cpMultipliers <- do
    playerLevel <- getFirst itemTemplates "playerLevel"
    getObjectValue playerLevel "cpMultiplier"
  let getFromPokemonUpgrades name = do
        pokemonUpgrades <- getFirst itemTemplates "pokemonUpgrades"
        getObjectValue pokemonUpgrades name
  stardustCost <- getFromPokemonUpgrades "stardustCost"
  candyCost <- getFromPokemonUpgrades "candyCost"
  shadowStardustMultiplier <- getFromPokemonUpgrades "shadowStardustMultiplier"
  shadowCandyMultiplier <- getFromPokemonUpgrades "shadowCandyMultiplier"
  purifiedStardustMultiplier <- getFromPokemonUpgrades "purifiedStardustMultiplier"
  purifiedCandyMultiplier <- getFromPokemonUpgrades "purifiedCandyMultiplier"
  xlCandyCost <- getFromPokemonUpgrades "xlCandyCost"
  luckyPowerUpStardustDiscountPercent <- do
     luckyPokemonSetttings <- getFirst itemTemplates "luckyPokemonSettings"
     getObjectValue luckyPokemonSetttings "powerUpStardustDiscountPercent"
  weatherBonusMap <- do
    weatherBonusSettings <- getFirst itemTemplates "weatherBonusSettings"
    attackBonusMultiplier <-
      getObjectValue weatherBonusSettings "attackBonusMultiplier"
    weatherAffinityMap <-
      makeObjects "weatherAffinities" (getNameFromKey "weatherCondition")
        (makeWeatherAffinity types) itemTemplates
    return $
      foldr (\ (wstring, ptypes) map ->
        let weather = toWeather wstring
            m = foldr
              (\ ptype map -> HashMap.insert ptype attackBonusMultiplier map)
              HashMap.empty
              ptypes
        in HashMap.insert weather m map)
      HashMap.empty
      $ HashMap.toList weatherAffinityMap
  return $ GameMaster.new types moves forms pokemonBases cpMultipliers
    stardustCost candyCost
    shadowStardustMultiplier shadowCandyMultiplier
    purifiedStardustMultiplier purifiedCandyMultiplier
    xlCandyCost
    luckyPowerUpStardustDiscountPercent
    weatherBonusMap

-- The yaml file is one big array of "templates":
-- - templateId: AR_TELEMETRY_SETTINGS
--   data:
--     templateId: AR_TELEMETRY_SETTINGS
-- What we really want is the "data" hash from each "template" element.
-- So get the template array then map over it to extract the data.
--
-- Here it's nice to use Yaml.Parser because it will error if we don't
-- get a [ItemTemplate], i.e., it checks that the Yaml.Values are the
-- correct type thanks to type inference.
--
getItemTemplates :: Epic.MonadCatch m => [Yaml.Object] -> m [ItemTemplate]
getItemTemplates yamlObjects =
  Epic.toEpic $ mapM (Yaml.parseEither (.: "data")) yamlObjects

getTypes :: Epic.MonadCatch m => [ItemTemplate] -> m (StringMap Type)
getTypes itemTemplates = do
  battleSettings <- getFirst itemTemplates "battleSettings"
  stab <- getObjectValue battleSettings "sameTypeAttackBonusMultiplier"
  makeObjects "typeEffective" (getNameFromKey "attackType")
    (makeType stab) itemTemplates

makeType :: Epic.MonadCatch m => Float -> ItemTemplate -> m Type
makeType stab itemTemplate = do
  attackScalar <- getObjectValue itemTemplate "attackScalar"
  let effectiveness = HashMap.fromList $ zip effectivenessOrder attackScalar
  name <- getObjectValue itemTemplate "attackType"
  return $ Type.new name effectiveness stab

effectivenessOrder :: [String]
effectivenessOrder =
  map (\ ptype -> "POKEMON_TYPE_" ++ Util.toUpper ptype)
    ["normal",
     "fighting",
     "flying",
     "poison",
     "ground",
     "rock",
     "bug",
     "ghost",
     "steel",
     "fire",
     "water",
     "grass",
     "electric",
     "psychic",
     "ice",
     "dragon",
     "dark",
     "fairy"]

-- This is tricky.  Some of the PVE moves don't have a corresponding PVP
-- move.  In that case makeMaybeMove will return (m Nothing) for the
-- itemTemplate instead of (m Just Move), then the Nothings will be removed
-- from the StringMap.
--
getMoves :: Epic.MonadCatch m =>
  (ItemTemplate -> m (Maybe Move)) -> [ItemTemplate] ->
  m (StringMap Move)
getMoves makeMaybeMove itemTemplates = do
  maybeMoveMap <- makeObjects "moveSettings" (getNameFromKey "movementId")
    makeMaybeMove itemTemplates
  -- Use (mapMaybe id) to discard any Nothing values, and turn Just Move
  -- into Move values.
  return $ HashMap.mapMaybe id maybeMoveMap

makeMaybeMove :: Epic.MonadCatch m =>
  StringMap Type -> StringMap PvpFastMove ->
  StringMap PvpChargedMove -> ItemTemplate -> m (Maybe Move)
makeMaybeMove types pvpFastMoves pvpChargedMoves itemTemplate = do
  let getTemplateValue text = getObjectValue itemTemplate text
  name <- getTemplateValue "movementId"
  let maybeMoveStats = if List.isSuffixOf "_FAST" name
        then case HashMap.lookup name pvpFastMoves of
          Nothing -> Nothing
          Just pvpFastMove -> Just (PvpFastMove.power pvpFastMove,
            PvpFastMove.energyDelta pvpFastMove,
            PvpFastMove.durationTurns pvpFastMove)
        else case HashMap.lookup name pvpChargedMoves of
          Nothing -> Nothing
          -- Charged moves used to get a durationTurns of 'error "Charged
          -- moves have no durationTurns"' which was clever but broke
          -- the GAME_MASTER cache because it had to be evaluated to write
          -- it to the cache and it just threw the error.  So just use 0.
          Just pvpChargedMove -> Just (PvpChargedMove.power pvpChargedMove,
            PvpChargedMove.energyDelta pvpChargedMove,
            0)
  case maybeMoveStats of
    Nothing -> return Nothing
    Just (pvpPower, pvpEnergyDelta, pvpDurationTurns) -> do
      Just <$> (Move.new
        <$> pure name
        <*> do
          typeName <- getTemplateValue "pokemonType"
          get types typeName
        <*> getObjectValueWithDefault 0 itemTemplate "power"
        <*> ((/1000) <$> getTemplateValue "durationMs")
        <*> getTemplateValue "damageWindowStartMs"
        <*> getObjectValueWithDefault 0 itemTemplate "energyDelta"
        <*> pure pvpPower
        <*> pure pvpEnergyDelta
        <*> pure pvpDurationTurns
        <*> pure False)

isFastMove :: ItemTemplate -> Bool
isFastMove itemTemplate = case getObjectValue itemTemplate "uniqueId" of
    Left _ -> error $ "Move doesn't have a uniqueId: " ++ show itemTemplate
    Right uniqueId -> List.isSuffixOf "_FAST" uniqueId

isChargedMove :: ItemTemplate -> Bool
isChargedMove = not . isFastMove

getPvpFastMoves :: Epic.MonadCatch m =>
  StringMap Type -> [ItemTemplate] -> m (StringMap PvpFastMove)
getPvpFastMoves types itemTemplates =
  getPvpMoves isFastMove (makePvpFastMove types) itemTemplates

getPvpChargedMoves :: Epic.MonadCatch m =>
  StringMap Type -> [ItemTemplate] -> m (StringMap PvpChargedMove)
getPvpChargedMoves types itemTemplates =
  getPvpMoves isChargedMove (makePvpChargedMove types) itemTemplates

getPvpMoves :: Epic.MonadCatch m =>
  (ItemTemplate -> Bool) -> (ItemTemplate -> m a) -> [ItemTemplate]
  -> m (StringMap a)
getPvpMoves pred makePvpMove itemTemplates =
  makeSomeObjects pred "combatMove" (getNameFromKey "uniqueId")
    makePvpMove itemTemplates

makePvpFastMove :: Epic.MonadCatch m =>
  StringMap Type -> ItemTemplate -> m PvpFastMove
makePvpFastMove types itemTemplate =
  let getTemplateValue = getObjectValue itemTemplate
      getTemplateValueWithDefault dflt text =
        getObjectValueWithDefault dflt itemTemplate text
  in PvpFastMove.new
    <$> getTemplateValue "uniqueId"
    <*> do
      typeName <- getTemplateValue "type"
      get types typeName
    <*> getTemplateValueWithDefault 0.0 "power"
    <*> getTemplateValueWithDefault 0 "durationTurns"
    <*> getTemplateValueWithDefault 0 "energyDelta"
    <*> pure False

makePvpChargedMove :: Epic.MonadCatch m =>
  StringMap Type -> ItemTemplate -> m PvpChargedMove
makePvpChargedMove types itemTemplate =
  let getTemplateValue = getObjectValue itemTemplate
      getTemplateValueWithDefault dflt text =
        getObjectValueWithDefault dflt itemTemplate text
  in PvpChargedMove.new
    <$> getTemplateValue "uniqueId"
    <*> do
      typeName <- getTemplateValue "type"
      get types typeName
    <*> getTemplateValueWithDefault 0.0 "power"
    <*> getTemplateValueWithDefault 0 "energyDelta"
    <*> pure False

-- Return a map of pokemon species to a (possibly empty) list of its forms.
--
getForms :: Epic.MonadCatch m => [ItemTemplate] -> m (StringMap [String])
getForms itemTemplates =
  makeObjects "formSettings" (getNameFromKey "pokemon")
    getFormNames itemTemplates

getFormNames :: Epic.MonadCatch m => ItemTemplate -> m [String]
getFormNames formSettings =
  case getObjectValue formSettings "forms" of
    Left _ -> return []
    Right forms -> mapM (\ form -> getObjectValue form "form") forms

-- This is a little goofy because GAME_MASTER is a little goofy.  There are
-- three templates for the two exeggutor forms.  The first and third are
-- redundant with each other:
--   pokemonId: EXEGGUTOR
-- and 
--   pokemonId: EXEGGUTOR
--   form: EXEGGUTOR_ALOLA
-- and
--   pokemonId: EXEGGUTOR
--   form: EXEGGUTOR_NORMAL
-- I want the original exeggutor to be known as just "exeggutor", and
-- the alola form to be known as "exeggutor_alola".  So, if there is a
-- form and the form does not end with "_NORMAL" then use it as the
-- species, else use the pokemonId.  This also works with DEOXYS.
-- Note that we'll add both redundant templates to the pokemonBases
-- hash, but the first one will be overwritten which is fine because
-- except for the form they are identical.
--
getSpeciesForPokemonBase :: Epic.MonadCatch m => StringMap [String] -> ItemTemplate -> m String
getSpeciesForPokemonBase forms itemTemplate = do
  species <- getObjectValue itemTemplate "pokemonId"
  case HashMap.lookup species forms of
    Nothing -> Epic.fail $ "Can't find forms for " ++ species
    Just [] -> return species
    Just _ -> case getObjectValue itemTemplate "form" of
      Right form -> return form
      Left _ -> Epic.fail $ "No form specified for " ++ species      

makePokemonBase :: Epic.MonadCatch m =>
  StringMap Type -> StringMap Move
  -> StringMap [String] -> ItemTemplate -> m PokemonBase
makePokemonBase types moves forms pokemonSettings =
  Epic.catch (do
    let getValue key = getObjectValue pokemonSettings key
        getValueWithDefault dflt key =
          getObjectValueWithDefault dflt pokemonSettings key

    pokemonId <- getValue "pokemonId"

    species <- do
      species <- getSpeciesForPokemonBase forms pokemonSettings
      let normal = Regex.mkRegex "_normal$"
      return $ Regex.subRegex normal (Util.toLower species) ""

    ptypes <- do
      ptype <- getValue "type"
      let ptypes = case getValue "type2" of
            Right ptype2 -> [ptype, ptype2]
            -- XXX This can swallow parse errors?
            Left _ -> [ptype]
      mapM (get types) ptypes
  
    statsObject <- getValue "stats"
    -- Sometimes new pokemon have an empty stats object for a while
    -- so just default to zero instead of choking.
    attack <- getObjectValueWithDefault 0 statsObject "baseAttack"
    defense <- getObjectValueWithDefault 0 statsObject "baseDefense"
    stamina <- getObjectValueWithDefault 0 statsObject "baseStamina"

    evolutions <- do
      case getValue "evolutionBranch" of
        Right evolutionBranch ->
          mapM (\ branch -> do
            evolution <- case getObjectValue branch "form" of
              Right form -> return form
              Left _ -> getObjectValue branch "evolution"
            candyCost <- case getObjectValue branch "candyCost" of
              Right candyCost -> return candyCost
              Left _ -> getValue "candyToEvolve"
            noCandyCostViaTrade <- getObjectValueWithDefault False
              branch "noCandyCostViaTrade"
            return (evolution, candyCost, noCandyCostViaTrade))
            -- Parts of GAME_MASTER seem to be in shambles as gen 4 is
            -- being released.  Filter out seemingly malformed elements
            -- that don't have an evolution.
            $ filter (HashMap.member "evolution") evolutionBranch
        -- XXX This can swallow parse errors?
        Left _ -> return []

    let getLegacyMoves key = do
          moveNames <- getValueWithDefault [] key
          mapM (liftM Move.setLegacy . get moves) moveNames
    legacyQuickMoves <- getLegacyMoves "eliteQuickMove"
    legacyChargeMoves <- getLegacyMoves "eliteCinematicMove"

    -- XXX Smeargle's doesn't have keys for "quickMoves" and
    -- "cinematicMoves".  Instead, those keys are in the template
    -- "SMEARGLE_MOVE_SETTINGS".  Smeargle is the only pokemon like
    -- that.  Since I will never care about smeargle's moves, they are
    -- just returned as [] here.  If they start using this scheme for
    -- other pokemon they will break and I can decide what to do then.
    --
    let getMoves key = if species /= "smeargle"
          then do
            -- Mew has some moves specified multiple times so nub them.
            moveNames <- List.nub <$> getValue key
            mapM (get moves) moveNames
          else return []

    quickMoves <- do
      moves <- getMoves "quickMoves"
      return $ moves ++ legacyQuickMoves
    chargeMoves <- do
      moves <- getMoves "cinematicMoves"
      return $ moves ++ legacyChargeMoves

    let parent = case getValue "parentPokemonId" of
          Right parent -> Just parent
          -- XXX This can swallow parse errors?
          Left _ -> Nothing

    baseCaptureRate <- do
      encounter <- getValue "encounter"
      getObjectValueWithDefault 0 encounter "baseCaptureRate"

    thirdMoveCost <- do
      thirdMove <- getValue "thirdMove"
      -- Smeargle has candyToUnlock but not stardustToUnlock so default it.
      stardustToUnlock <-
        getObjectValueWithDefault 0 thirdMove "stardustToUnlock"
      candyToUnlock <-  getObjectValue thirdMove "candyToUnlock"
      return $ (stardustToUnlock, candyToUnlock)

    purificationCost <- do
      case getValue "shadow" of
        Right shadow -> do
          purificationStardustNeeded <-
            getObjectValue shadow "purificationStardustNeeded"
          purificationCandyNeeded <-
            getObjectValue shadow "purificationCandyNeeded"
          return $ (purificationStardustNeeded, purificationCandyNeeded)
        Left _ -> return $ (0, 0)

    return $ PokemonBase.new pokemonId species ptypes attack defense stamina
       evolutions quickMoves chargeMoves parent baseCaptureRate
       thirdMoveCost purificationCost
    )
  (\ex -> Epic.fail $ ex ++ " in " ++ show pokemonSettings)

makeWeatherAffinity :: Epic.MonadCatch m => StringMap Type -> ItemTemplate -> m [Type]
makeWeatherAffinity types weatherAffinity = do
  ptypes <- getObjectValue weatherAffinity "pokemonType"
  mapM (get types) ptypes

getNameFromKey :: Epic.MonadCatch m => String -> ItemTemplate -> m String
getNameFromKey nameKey itemTemplate =
  getObjectValue itemTemplate nameKey

makeObjects :: Epic.MonadCatch m =>
  String -> (ItemTemplate -> m String) -> (ItemTemplate -> m a)
  -> [ItemTemplate]
  -> m (StringMap a)
makeObjects = makeSomeObjects $ const True

makeSomeObjects :: Epic.MonadCatch m =>
  (ItemTemplate -> Bool)
  -> String -> (ItemTemplate -> m String) -> (ItemTemplate -> m a)
  -> [ItemTemplate]
  -> m (StringMap a)
makeSomeObjects pred filterKey getName makeObject itemTemplates =
  foldr (\ itemTemplate maybeHash -> do
      hash <- maybeHash
      name <- getName itemTemplate
      obj <- makeObject itemTemplate
      return $ HashMap.insert name obj hash)
    (pure HashMap.empty)
    $ filter pred
    $ getAll itemTemplates filterKey

getAll :: [ItemTemplate] -> String -> [ItemTemplate]
getAll itemTemplates filterKey =
  mapMaybe (\ itemTemplate ->
    case getObjectValue itemTemplate filterKey of
      Right value -> Just value
      _ -> Nothing)
    itemTemplates

getFirst :: Epic.MonadCatch m => [ItemTemplate] -> String -> m ItemTemplate
getFirst itemTemplates filterKey =
  case getAll itemTemplates filterKey of
    [head] -> return head
    _ -> Epic.fail $ "Expected exactly one " ++ show filterKey

checkPokemonSettings :: ItemTemplate -> (Yaml.Object -> Bool) -> Bool
checkPokemonSettings itemTemplate predicate =
  case getObjectValue itemTemplate "pokemonSettings" of
    Left _ -> False
    Right pokemonSettings -> predicate pokemonSettings

hasFormIfRequired :: StringMap [String] -> ItemTemplate -> Bool
hasFormIfRequired forms itemTemplate =
  checkPokemonSettings itemTemplate $ \ pokemonSettings ->
    case getObjectValue pokemonSettings "pokemonId" of
      Left _ -> False
      Right species ->
        case HashMap.lookup species forms of
          Nothing -> False
          Just [] -> True
          _ -> case getObjectValue pokemonSettings "form" of
                 Left _ -> False
                 -- I would like to say Right _ -> True but the compiler
                 -- needs to know the type of _ so it can make/use the
                 -- correct variant of getObjectValue.  Rather than trying
                 -- to come up with a complex annotation for getObjectValue,
                 -- it is simpler to annotate form but ignore the value like
                 -- this:
                 Right form -> const True (form :: String)

-- This seems roundabout, but the good thing is that the type "a" is
-- inferred from the usage context so the result is error-checked.
--
getObjectValue :: (Epic.MonadCatch m, Yaml.FromJSON a) => Yaml.Object -> String -> m a
getObjectValue yamlObject key =
  Epic.toEpic $ Yaml.parseEither (.: convertText key) yamlObject

getObjectValueWithDefault :: (Epic.MonadCatch m, Yaml.FromJSON a) => a -> Yaml.Object -> String -> m a
getObjectValueWithDefault dflt yamlObject key =
  Epic.toEpic $ Yaml.parseEither (\p -> p .:? convertText key .!= dflt) yamlObject

get :: Epic.MonadCatch m => StringMap a -> String -> m a
get map key =
  case HashMap.lookup key map of
    Just value -> return value
    _ -> Epic.fail $ "Key not found: " ++ show key

getType :: Epic.MonadCatch m => GameMaster -> String -> m Type
getType this typeName =
  get (GameMaster.types this) ("POKEMON_TYPE_" ++ (Util.toUpper typeName))

getAllTypes :: GameMaster -> [Type]
getAllTypes this =
  HashMap.elems $ types this

getWeatherBonus :: GameMaster -> Maybe Weather -> WeatherBonus
getWeatherBonus this maybeWeather =
  case maybeWeather of
    Just weather ->
      case HashMap.lookup weather (weatherBonusMap this) of
        Just map -> (\ptype -> HashMap.lookupDefault 1 ptype map)
        Nothing -> error $ "No weatherBonusMap for " ++ show weather
    Nothing -> defaultWeatherBonus

defaultWeatherBonus :: WeatherBonus
defaultWeatherBonus =
  const 1

toWeather :: String -> Weather
toWeather string = case string of
  "CLEAR" -> Clear
  "FOG" -> Fog
  "OVERCAST" -> Overcast
  "PARTLY_CLOUDY" -> PartlyCloudy
  "RAINY" -> Rainy
  "SNOW" -> Snow
  "WINDY" -> Windy
  _ -> error $ "Unknown weather: " ++ string

costAtLevel :: GameMaster -> (GameMaster -> [(Int, Float)]) -> Float -> Maybe Int
costAtLevel this func level =
  case nextLevel this level of
    Nothing -> Nothing
    Just _ ->
      case List.find ((== level) . snd) $ func this of
        Just (cost, _) -> Just cost
        Nothing -> Nothing

dustAtLevel :: GameMaster -> Float -> Maybe Int
dustAtLevel this =
  costAtLevel this GameMaster.dustAndLevel

candyAtLevel :: GameMaster -> Float -> Maybe Int
candyAtLevel this =
  costAtLevel this GameMaster.candyAndLevel

commaSeparated :: [String] -> String
commaSeparated [] = ""
commaSeparated [a] = a
commaSeparated [a, b] = a ++ " or " ++ b
commaSeparated list =
  let commaSeparated' [a, b] = a ++ ", or " ++ b
      commaSeparated' (h:t) = h ++ ", " ++ commaSeparated' t
  in commaSeparated' list
