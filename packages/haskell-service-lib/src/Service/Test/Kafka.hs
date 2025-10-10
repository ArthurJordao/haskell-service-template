module Service.Test.Kafka
  ( MockKafkaState (..),
    MockProducer (..),
    MockConsumer (..),
    QueuedMessage (..),
    newMockKafkaState,
    processAllMessages,
    mockProduceMessage,
  )
where

import Data.Aeson (ToJSON, Value, toJSON)
import qualified Data.Map.Strict as Map
import Kafka.Consumer (TopicName (..))
import RIO
import qualified RIO.Seq as Seq
import Service.Kafka (ConsumerConfig (..), TopicHandler (..))

data QueuedMessage = QueuedMessage
  { qmTopic :: !TopicName,
    qmKey :: !(Maybe Text),
    qmValue :: !Value
  }
  deriving (Show, Eq)

data MockKafkaState = MockKafkaState
  { messageQueue :: !(TVar (Seq QueuedMessage)),
    messageCounter :: !(TVar Int),
    consumedMessages :: !(TVar (Seq QueuedMessage))
  }

newtype MockProducer = MockProducer MockKafkaState

newtype MockConsumer = MockConsumer MockKafkaState

newMockKafkaState :: (MonadIO m) => m MockKafkaState
newMockKafkaState = do
  queue <- newTVarIO Seq.empty
  counter <- newTVarIO 0
  consumed <- newTVarIO Seq.empty
  return $ MockKafkaState queue counter consumed

mockProduceMessage ::
  (HasLogFunc env, ToJSON a) =>
  MockProducer ->
  TopicName ->
  Maybe Text ->
  a ->
  RIO env ()
mockProduceMessage (MockProducer state) topic key value = do
  let jsonValue = toJSON value
      msg = QueuedMessage topic key jsonValue
  atomically $ modifyTVar' (messageQueue state) (Seq.|> msg)
  logDebug $ "Mock produced message to topic: " <> displayShow topic

mockPollMessage ::
  (HasLogFunc env) =>
  MockConsumer ->
  RIO env (Maybe (TopicName, Value))
mockPollMessage (MockConsumer state) = do
  maybeMsg <- atomically $ do
    queue <- readTVar (messageQueue state)
    case Seq.viewl queue of
      Seq.EmptyL -> return Nothing
      msg Seq.:< rest -> do
        writeTVar (messageQueue state) rest
        _counter <- readTVar (messageCounter state)
        modifyTVar' (messageCounter state) (+ 1)
        return $ Just msg

  case maybeMsg of
    Nothing -> return Nothing
    Just msg@(QueuedMessage {..}) -> do
      atomically $ modifyTVar' (consumedMessages state) (Seq.|> msg)
      logDebug $ "Mock consumed message from topic: " <> displayShow qmTopic
      return $ Just (qmTopic, qmValue)

processAllMessages ::
  (HasLogFunc env) =>
  MockConsumer ->
  ConsumerConfig env ->
  RIO env ()
processAllMessages mockConsumer config = do
  let handlerMap = Map.fromList [(topic h, handler h) | h <- topicHandlers config]
  go handlerMap
  where
    go handlerMap = do
      maybeMessage <- mockPollMessage mockConsumer
      case maybeMessage of
        Nothing -> return ()
        Just (topicName, jsonValue) -> do
          case Map.lookup topicName handlerMap of
            Just h -> do
              logInfo
                $ "Processing message from topic: "
                <> displayShow topicName
              _ <- h jsonValue
              go handlerMap
            Nothing ->
              logWarn $ "No handler configured for topic: " <> displayShow topicName
