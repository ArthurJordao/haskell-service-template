module Types.Out.Scopes
  ( ScopeInfo (..),
    UserWithScopes (..),
  )
where

import Data.Aeson (ToJSON)
import RIO

data ScopeInfo = ScopeInfo
  { id :: Int64,
    name :: Text,
    description :: Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON)

data UserWithScopes = UserWithScopes
  { id :: Int64,
    email :: Text,
    scopes :: [Text]
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON)
