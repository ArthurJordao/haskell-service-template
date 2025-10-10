module KafkaSpec (spec) where

import Data.Aeson (Value (..), decode, encode)
import Kafka.Consumer (TopicName (..))
import RIO
import Service.Kafka (ConsumerConfig (..), HasKafkaProducer (..), TopicHandler (..))
import Service.Test.Kafka
import Test.Hspec

-- | Test environment with mock Kafka
data TestEnv = TestEnv
  { testLogFunc :: !LogFunc,
    mockKafkaState :: !MockKafkaState,
    producedMessages :: !(TVar [Text])
  }

instance HasLogFunc TestEnv where
  logFuncL = lens testLogFunc (\x y -> x {testLogFunc = y})

-- | Instance for mock Kafka producer in tests
instance HasKafkaProducer TestEnv where
  produceKafkaMessage topic key value = do
    state <- view (to mockKafkaState)
    mockProduceMessage (MockProducer state) topic key value

-- | Create a test environment
mkTestEnv :: IO TestEnv
mkTestEnv = do
  logOptions <- logOptionsHandle stderr False
  (logFunc, _cleanup) <- newLogFunc logOptions :: IO (LogFunc, IO ())
  state <- newMockKafkaState
  messages <- newTVarIO []
  return $ TestEnv logFunc state messages

-- | Handler that appends to the messages list
testHandler :: TVar [Text] -> Value -> RIO TestEnv ()
testHandler messagesVar jsonValue = do
  -- Decode the JSON string value
  case decode @Text (encode jsonValue) of
    Just msgText -> do
      logInfo $ "Handler received: " <> display msgText
      atomically $ modifyTVar' messagesVar (msgText :)
    Nothing -> logInfo "Failed to decode message as Text"

-- | Handler that produces another message (cascading test)
cascadingHandler :: TVar [Text] -> Value -> RIO TestEnv ()
cascadingHandler messagesVar jsonValue = do
  -- Decode the JSON string value
  case decode @Text (encode jsonValue) of
    Just msgText -> do
      logInfo $ "Cascading handler received: " <> display msgText
      atomically $ modifyTVar' messagesVar (msgText :)

      -- If message is "trigger", produce a new message to "result-topic"
      when (msgText == "trigger") $ do
        logInfo "Producing cascaded message"
        produceKafkaMessage (TopicName "result-topic") Nothing ("cascaded" :: Text)
    Nothing -> logInfo "Failed to decode message as Text"

spec :: Spec
spec = describe "Kafka Mock" $ do
  it "processes messages produced during test" $ do
    env <- mkTestEnv
    runRIO env $ do
      let config =
            ConsumerConfig
              { brokerAddress = "mock",
                groupId = "test-group",
                topicHandlers =
                  [ TopicHandler
                      { topic = TopicName "test-topic",
                        handler = testHandler (producedMessages env)
                      }
                  ]
              }

      -- Produce a message
      produceKafkaMessage (TopicName "test-topic") Nothing ("hello world" :: Text)

      -- Process all messages
      let consumer = MockConsumer (mockKafkaState env)
      processAllMessages consumer config

      -- Verify the handler was called
      messages <- readTVarIO (producedMessages env)
      liftIO $ messages `shouldBe` ["hello world"]

  it "processes cascading messages (handler produces messages)" $ do
    env <- mkTestEnv
    runRIO env $ do
      let config =
            ConsumerConfig
              { brokerAddress = "mock",
                groupId = "test-group",
                topicHandlers =
                  [ TopicHandler
                      { topic = TopicName "trigger-topic",
                        handler = cascadingHandler (producedMessages env)
                      },
                    TopicHandler
                      { topic = TopicName "result-topic",
                        handler = testHandler (producedMessages env)
                      }
                  ]
              }

      -- Produce initial trigger message
      produceKafkaMessage (TopicName "trigger-topic") Nothing ("trigger" :: Text)

      -- Process all messages (should handle cascading)
      let consumer = MockConsumer (mockKafkaState env)
      processAllMessages consumer config

      -- Verify both messages were processed
      messages <- readTVarIO (producedMessages env)
      liftIO $ messages `shouldBe` ["cascaded", "trigger"]

  it "handles multiple messages in sequence" $ do
    env <- mkTestEnv
    runRIO env $ do
      let config =
            ConsumerConfig
              { brokerAddress = "mock",
                groupId = "test-group",
                topicHandlers =
                  [ TopicHandler
                      { topic = TopicName "test-topic",
                        handler = testHandler (producedMessages env)
                      }
                  ]
              }

      -- Produce multiple messages
      produceKafkaMessage (TopicName "test-topic") Nothing ("message1" :: Text)
      produceKafkaMessage (TopicName "test-topic") Nothing ("message2" :: Text)
      produceKafkaMessage (TopicName "test-topic") Nothing ("message3" :: Text)

      -- Process all messages
      let consumer = MockConsumer (mockKafkaState env)
      processAllMessages consumer config

      -- Verify all messages were processed (in reverse order due to how we append)
      messages <- readTVarIO (producedMessages env)
      liftIO $ messages `shouldBe` ["message3", "message2", "message1"]
