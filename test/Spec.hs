import Network.HTTP.Client (defaultManagerSettings, httpLbs, newManager, parseRequest, responseBody, responseStatus)
import Network.HTTP.Types.Status (status200)
import Network.Wai.Handler.Warp (testWithApplication)
import RIO
import Server (App (..), Config (..), app)
import Test.Hspec

spec :: Spec
spec = describe "Server" $ do
  it "respond with 200 on status" $ do
    let testConfig = Config {port = 8080, environment = "test"}
    logOptions <- logOptionsHandle stderr True
    withLogFunc logOptions $ \logFunc -> do
      let testApp = App {appLogFunc = logFunc, config = testConfig}
      testWithApplication (pure $ app testApp) $ \port' -> do
        manager <- newManager defaultManagerSettings
        request <- parseRequest ("http://localhost:" <> show port' <> "/status")
        response <- httpLbs request manager
        responseStatus response `shouldBe` status200
        responseBody response `shouldBe` "\"OK\""

  it "respond with 200 and list of accounts on /accounts" $ do
    let testConfig = Config {port = 8080, environment = "test"}
    logOptions <- logOptionsHandle stderr True
    withLogFunc logOptions $ \logFunc -> do
      let testApp = App {appLogFunc = logFunc, config = testConfig}
      testWithApplication (pure $ app testApp) $ \port' -> do
        manager <- newManager defaultManagerSettings
        request <- parseRequest ("http://localhost:" <> show port' <> "/accounts")
        response <- httpLbs request manager
        responseStatus response `shouldBe` status200
        -- Assuming the response body is a JSON array of accounts
        responseBody response `shouldBe` "[{\"accountId\":1,\"accountName\":\"Alice\"},{\"accountId\":2,\"accountName\":\"Bob\"}]"

main :: IO ()
main = hspec spec
