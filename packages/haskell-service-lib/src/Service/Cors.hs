module Service.Cors (corsMiddleware) where

import Data.String (fromString)
import Network.Wai (Middleware)
import Network.Wai.Middleware.Cors
import RIO

corsMiddleware :: [String] -> Middleware
corsMiddleware origins = cors $ \_ -> Just CorsResourcePolicy
  { corsOrigins        = Just (map fromString origins, True)
  , corsMethods        = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
  , corsRequestHeaders = ["Authorization", "Content-Type", "X-Correlation-Id"]
  , corsExposedHeaders = Nothing
  , corsMaxAge         = Just 86400
  , corsVaryOrigin     = False
  , corsRequireOrigin  = False
  , corsIgnoreFailures = True
  }
