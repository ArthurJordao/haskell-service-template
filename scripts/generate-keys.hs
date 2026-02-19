#!/usr/bin/env stack
-- stack --resolver lts-22.43 script --package jose --package aeson --package bytestring
{-# LANGUAGE OverloadedStrings #-}

import Crypto.JOSE.JWA.JWK (Crv (..), KeyMaterialGenParam (..))
import Crypto.JOSE.JWK (JWK, genJWK)
import Data.Aeson (Value (..), eitherDecodeStrict', encode)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL

main :: IO ()
main = do
  privJwk <- genJWK (ECGenParam P_256)
  let privBytes = encode privJwk
  pubJwk <- mkPublicJwk privBytes
  putStrLn "# auth-service/.env"
  putStr "JWT_PRIVATE_KEY='"
  BL.putStr privBytes
  putStrLn "'"
  putStrLn ""
  putStrLn "# all other services/.env"
  putStr "JWT_PUBLIC_KEY='"
  BL.putStr (encode pubJwk)
  putStrLn "'"

-- | Build a public JWK from a private JWK by removing the 'd' key component.
mkPublicJwk :: BL.ByteString -> IO JWK
mkPublicJwk privBytes =
  case (eitherDecodeStrict' (BL.toStrict privBytes) :: Either String Value) of
    Left err -> fail $ "Failed to decode JWK JSON: " <> err
    Right (Object km) ->
      case (eitherDecodeStrict' (BL.toStrict (encode (Object (KM.delete "d" km)))) :: Either String JWK) of
        Left err -> fail $ "Failed to create public JWK: " <> err
        Right jwk -> return jwk
    Right _ -> fail "JWK did not serialize as a JSON object"
