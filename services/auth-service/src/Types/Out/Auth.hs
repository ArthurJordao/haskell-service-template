module Types.Out.Auth
  ( AuthTokens (..),
  )
where

import Data.Aeson (FromJSON, ToJSON)
import RIO

data AuthTokens = AuthTokens
  { accessToken :: Text,
    refreshToken :: Text,
    tokenType :: Text,
    expiresIn :: Int
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)
