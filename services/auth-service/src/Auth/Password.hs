module Auth.Password
  ( hashPassword,
    verifyPassword,
  )
where

import qualified Crypto.KDF.BCrypt as BCrypt
import RIO

-- | Hash a plaintext password using bcrypt (cost factor 12).
-- Returns the standard $2b$12$... bcrypt format as Text for DB storage.
hashPassword :: Text -> IO (Maybe Text)
hashPassword plaintext = do
  (hashed :: ByteString) <- BCrypt.hashPassword 12 (encodeUtf8 plaintext)
  return $ Just $ decodeUtf8Lenient hashed

-- | Verify a plaintext password against a stored bcrypt hash.
verifyPassword :: Text -> Text -> Bool
verifyPassword storedHash plaintext =
  BCrypt.validatePassword (encodeUtf8 plaintext) (encodeUtf8 storedHash)
