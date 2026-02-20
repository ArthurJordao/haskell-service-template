{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

module Service.Persist
  ( persistWithMeta,
    deriveEntityMeta,
    HasMeta (..),
  )
where

import Data.Char (isUpper, toLower)
import Data.List (intercalate, isPrefixOf)
import Data.Time (Day (..), UTCTime (..))
import Database.Persist.TH (persistLowerCase)
import Language.Haskell.TH
import Language.Haskell.TH.Quote (QuasiQuoter (..))
import RIO
import Service.Metadata (EntityMetadata (..), HasMeta (..))

-- | Like @persistLowerCase@, but automatically appends @createdAt UTCTime@ and
-- @createdByCid Text@ to every entity block before the first @Unique@ constraint
-- or @deriving@ clause.
persistWithMeta :: QuasiQuoter
persistWithMeta =
  QuasiQuoter
    { quoteExp = \s -> quoteExp persistLowerCase (injectMetaFields s),
      quotePat = error "persistWithMeta: cannot be used in pattern context",
      quoteType = error "persistWithMeta: cannot be used in type context",
      quoteDec = error "persistWithMeta: cannot be used in declaration context"
    }

-- | Preprocess schema text by injecting meta fields into every entity block.
injectMetaFields :: String -> String
injectMetaFields input =
  let blocks = splitBlocks (lines input)
      processed = map processBlock blocks
   in unlines (intercalate [""] processed)

-- | Split lines into non-empty blocks separated by blank lines.
splitBlocks :: [String] -> [[String]]
splitBlocks [] = []
splitBlocks ls =
  let (block, rest) = break isBlankLine ls
      remaining = dropWhile isBlankLine rest
   in if null block
        then splitBlocks remaining
        else block : splitBlocks remaining
  where
    isBlankLine = all (== ' ')

-- | Inject @createdAt UTCTime@ and @createdByCid Text@ into an entity block
-- just before the first @Unique@ constraint or @deriving@ line.
processBlock :: [String] -> [String]
processBlock [] = []
processBlock (firstLine : rest)
  | isEntityLine firstLine =
      let (fieldLines, markerAndRest) = break isInsertionPoint rest
          injection = ["  createdAt UTCTime", "  createdByCid Text"]
       in firstLine : fieldLines ++ injection ++ markerAndRest
  | otherwise = firstLine : rest
  where
    isEntityLine (' ' : _) = False
    isEntityLine [] = False
    isEntityLine _ = True
    isInsertionPoint (' ' : ' ' : 'd' : 'e' : 'r' : 'i' : 'v' : 'i' : 'n' : 'g' : _) = True
    isInsertionPoint (' ' : ' ' : c : _) = isUpper c
    isInsertionPoint _ = False

-- | Generate a 'HasMeta' instance and a smart constructor for a Persistent entity.
--
-- Call this after the @share [mkPersist ...]@ splice so 'reify' can see the
-- generated type.  Example:
--
-- > $(deriveEntityMeta ''User)
--
-- Generates:
--
-- > instance HasMeta User where
-- >   applyMeta meta u = u { userCreatedAt = metaCreatedAt meta
-- >                        , userCreatedByCid = metaCreatedByCid meta }
-- >
-- > mkUser :: Text -> Text -> User
-- > mkUser p1 p2 = User { userEmail = p1, userPasswordHash = p2
-- >                     , userCreatedAt = placeholder, userCreatedByCid = placeholder }
deriveEntityMeta :: Name -> Q [Dec]
deriveEntityMeta typeName = do
  info <- reify typeName
  let entityStr = nameBase typeName
      -- Persistent prefix: lowercase first character only
      -- "User" -> "user", "RefreshToken" -> "refreshToken"
      prefix = case entityStr of
        (c : rest) -> [toLower c] ++ rest
        [] -> error "deriveEntityMeta: empty type name"
      createdAtName = prefix ++ "CreatedAt"
      createdByCidName = prefix ++ "CreatedByCid"

  let (conName, allFields) = case info of
        TyConI (DataD _ _ _ _ [RecC cn flds] _) -> (cn, flds)
        _ ->
          error $
            "deriveEntityMeta: " ++ entityStr
              ++ " must be a record type with exactly one constructor"

  let metaNames = [createdAtName, createdByCidName]
      businessFields = filter (\(n, _, _) -> nameBase n `notElem` metaNames) allFields

      findField nm = case filter (\(n, _, _) -> nameBase n == nm) allFields of
        ((n, _, _) : _) -> n
        [] -> error $ "deriveEntityMeta: field '" ++ nm ++ "' not found in " ++ entityStr

  let createdAtField = findField createdAtName
      createdByCidField = findField createdByCidName

  -- HasMeta instance: applyMeta meta x = x { ...At = metaCreatedAt meta, ...Cid = metaCreatedByCid meta }
  xVar <- newName "x"
  metaVar <- newName "meta"
  let hasMetaDec =
        InstanceD
          Nothing
          []
          (AppT (ConT ''HasMeta) (ConT typeName))
          [ FunD
              'applyMeta
              [ Clause
                  [VarP metaVar, VarP xVar]
                  ( NormalB
                      ( RecUpdE
                          (VarE xVar)
                          [ (createdAtField, AppE (VarE 'metaCreatedAt) (VarE metaVar)),
                            (createdByCidField, AppE (VarE 'metaCreatedByCid) (VarE metaVar))
                          ]
                      )
                  )
                  []
              ]
          ]

  -- Smart constructor: mkEntity :: T1 -> T2 -> ... -> EntityType
  let mkFnName = mkName ("mk" ++ entityStr)
  paramVars <- mapM (\(n, _, _) -> newName (nameBase n)) businessFields

  -- Placeholder values: overwritten by insertWithMeta before any DB access.
  -- Use fully-qualified constructors so no extra imports are needed at splice sites.
  let placeholderTime =
        ConE 'UTCTime
          `AppE` (ConE 'ModifiedJulianDay `AppE` LitE (IntegerL 0))
          `AppE` LitE (IntegerL 0)
  let placeholderText = VarE 'mempty

  let mkBody =
        RecConE
          conName
          ( [(fn, VarE pv) | ((fn, _, _), pv) <- zip businessFields paramVars]
              ++ [(createdAtField, placeholderTime), (createdByCidField, placeholderText)]
          )

  let mkSig =
        SigD mkFnName $
          foldr
            (\(_, _, t) acc -> AppT (AppT ArrowT t) acc)
            (ConT typeName)
            businessFields

  let mkDef =
        FunD
          mkFnName
          [Clause (map VarP paramVars) (NormalB mkBody) []]

  return [hasMetaDec, mkSig, mkDef]
