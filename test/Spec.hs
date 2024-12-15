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

main :: IO ()
main = hspec spec
