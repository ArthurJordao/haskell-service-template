module Types.In.DLQ
  ( IncomingDeadLetter (..),
  )
where

import Data.Aeson (FromJSON)
import qualified Data.Aeson as Aeson
import Data.Time.Clock (UTCTime)
import RIO

data IncomingDeadLetter = IncomingDeadLetter
  { originalTopic :: Text,
    originalMessage :: Aeson.Value,
    originalHeaders :: [(Text, Text)],
    errorType :: Text,
    errorDetails :: Text,
    correlationId :: Text,
    timestamp :: UTCTime,
    retryCount :: Int
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON IncomingDeadLetter where
  parseJSON = Aeson.withObject "IncomingDeadLetter" $ \o ->
    IncomingDeadLetter
      <$> o Aeson..: "originalTopic"
      <*> o Aeson..: "originalMessage"
      <*> o Aeson..: "originalHeaders"
      <*> o Aeson..: "errorType"
      <*> o Aeson..: "errorDetails"
      <*> o Aeson..: "correlationId"
      <*> o Aeson..: "timestamp"
      <*> o Aeson..: "retryCount"
