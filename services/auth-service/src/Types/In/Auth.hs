module Types.In.Auth
  ( RegisterRequest (..),
    LoginRequest (..),
    RefreshRequest (..),
    LogoutRequest (..),
  )
where

import Data.Aeson (FromJSON, ToJSON)
import RIO

data RegisterRequest = RegisterRequest
  { email :: !Text,
    password :: !Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data LoginRequest = LoginRequest
  { email :: !Text,
    password :: !Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data RefreshRequest = RefreshRequest
  { refreshToken :: !Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data LogoutRequest = LogoutRequest
  { refreshToken :: !Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)
