module Types.In.Scopes
  ( SetScopesRequest (..),
  )
where

import Data.Aeson (FromJSON, ToJSON)
import RIO

data SetScopesRequest = SetScopesRequest
  { scopes :: [Text]
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)
