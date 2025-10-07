module Service.Kafka (
  KafkaProducer,
  KafkaConsumer,
  ConsumerConfig (..),
  TopicHandler (..),
  HasKafkaProducer (..),
  Settings (..),
  decoder,
  startProducer,
  startConsumer,
  produceMessage,
  produceMessageWithCid,
  consumerLoop,
) where

import Data.Aeson (FromJSON, ToJSON, Value, decode, encode)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Kafka.Consumer
import Kafka.Producer hiding (produceMessage)
import Kafka.Types (KafkaError (..), headersFromList, headersToList)
import Service.CorrelationId (CorrelationId (..), HasCorrelationId (..), HasLogContext (..), generateCorrelationId, appendCorrelationId, logInfoC, logWarnC, logErrorC)
import RIO
import qualified RIO.ByteString.Lazy as BL
import RIO.Text (pack)
import qualified RIO.ByteString as BS
import System.Envy (FromEnv (..), decodeEnv, env, (.!=))
import System.IO.Error (mkIOError, userErrorType)

data Settings = Settings
  { kafkaBroker :: !Text,
    kafkaGroupId :: !Text
  }
  deriving (Show, Eq)

instance FromEnv Settings where
  fromEnv _ =
    Settings
      <$> (pack <$> (env "KAFKA_BROKER" .!= "localhost:9092"))
      <*> (pack <$> (env "KAFKA_GROUP_ID" .!= "haskell-service-group"))

decoder :: (HasLogFunc env) => RIO env Settings
decoder = do
  result <- liftIO $ decodeEnv
  case result of
    Left err -> do
      logWarn $ "Failed to decode Kafka settings, using defaults: " <> displayShow err
      return $ Settings (pack "localhost:9092") (pack "haskell-service-group")
    Right settings -> return settings

class HasKafkaProducer env where
  produceKafkaMessage :: ToJSON a => TopicName -> Maybe Text -> a -> RIO env ()


data TopicHandler env = TopicHandler
  { topic :: !TopicName,
    handler :: !(Value -> RIO env ())
  }


data ConsumerConfig env = ConsumerConfig
  { brokerAddress :: !Text,
    groupId :: !Text,
    topicHandlers :: ![TopicHandler env]
  }


startProducer ::
  (HasLogFunc env) =>
  Text ->
  RIO env KafkaProducer
startProducer brokerAddr = do
  logInfo "Initializing Kafka producer"

  let producerProps =
        Kafka.Producer.brokersList [BrokerAddress brokerAddr]
          <> Kafka.Producer.logLevel KafkaLogInfo

  producer <- newProducer producerProps
  case producer of
    Left err -> do
      logError $ "Failed to create Kafka producer: " <> displayShow err
      throwIO (mkIOError userErrorType ("Kafka producer error: " ++ show err) Nothing Nothing)
    Right prod -> do
      logInfo "Kafka producer created successfully"
      return prod


startConsumer ::
  (HasLogFunc env) =>
  ConsumerConfig env ->
  RIO env KafkaConsumer
startConsumer config = do
  logInfo "Initializing Kafka consumer"

  let configGroupId = config.groupId
      consumerProps =
        Kafka.Consumer.brokersList [BrokerAddress (brokerAddress config)]
          <> Kafka.Consumer.groupId (ConsumerGroupId configGroupId)
          <> noAutoCommit
          <> Kafka.Consumer.logLevel KafkaLogInfo

  let topicList = map topic (topicHandlers config)
  let subscription = topics topicList

  consumer <- newConsumer consumerProps subscription
  case consumer of
    Left err -> do
      logError $ "Failed to create Kafka consumer: " <> displayShow err
      throwIO (mkIOError userErrorType ("Kafka consumer error: " ++ show err) Nothing Nothing)
    Right cons -> do
      logInfo $ "Kafka consumer created successfully, subscribed to topics: " <> displayShow topicList
      return cons


produceMessage ::
  (HasLogFunc env) =>
  KafkaProducer ->
  TopicName ->
  Maybe ByteString ->
  Maybe ByteString ->
  RIO env ()
produceMessage producer topicName key value = do
  let record =
        ProducerRecord
          { prTopic = topicName,
            prPartition = UnassignedPartition,
            prKey = key,
            prValue = value,
            prHeaders = headersFromList []
          }

  result <- liftIO $ produceMessage' producer record (const $ return ())
  case result of
    Left err -> logError $ "Failed to produce message: " <> displayShow err
    Right _ -> logInfo $ "Message produced to topic: " <> displayShow topicName


produceMessageWithCid ::
  (HasLogFunc env, HasLogContext env, ToJSON a) =>
  KafkaProducer ->
  TopicName ->
  Maybe Text ->
  a ->
  CorrelationId ->
  RIO env ()
produceMessageWithCid producer topicName key value cid = do
  let cidHeader = ("X-Correlation-Id", TE.encodeUtf8 $ unCorrelationId cid)
      keyBytes = fmap TE.encodeUtf8 key
      valueBytes = Just $ BL.toStrict $ encode value
      record =
        ProducerRecord
          { prTopic = topicName,
            prPartition = UnassignedPartition,
            prKey = keyBytes,
            prValue = valueBytes,
            prHeaders = headersFromList [cidHeader]
          }

  result <- liftIO $ produceMessage' producer record (const $ return ())
  case result of
    Left err -> logErrorC $ "Failed to produce message: " <> displayShow err
    Right _ -> logInfoC $ "Message produced to topic: " <> displayShow topicName


consumerLoop ::
  (HasLogFunc env, HasCorrelationId env, HasLogContext env) =>
  KafkaConsumer ->
  ConsumerConfig env ->
  RIO env ()
consumerLoop consumer config = do
  let handlerMap = Map.fromList [(topic h, handler h) | h <- topicHandlers config]

  forever $ do
    msg <- pollMessage consumer (Timeout 1000)
    case msg of
      Left (KafkaResponseError RdKafkaRespErrTimedOut) -> pure ()
      Left err -> logError $ "Kafka consumer error: " <> displayShow err
      Right record@(ConsumerRecord {..}) -> do
        let maybeHeaderCid = lookup "X-Correlation-Id" (headersToList crHeaders)
        baseCid <- case maybeHeaderCid of
          Just cidBytes | not (BS.null cidBytes) ->
            return $ CorrelationId $ TE.decodeUtf8 cidBytes
          _ ->
            generateCorrelationId

        cid <- appendCorrelationId baseCid

        let cidText = unCorrelationId cid
        local (set correlationIdL cid . set logContextL (Map.singleton "cid" cidText)) $ do
          logInfoC $
            "Received message from topic: "
              <> displayShow crTopic
              <> " partition: "
              <> displayShow crPartition
              <> " offset: "
              <> displayShow crOffset

          case Map.lookup crTopic handlerMap of
            Just h -> do
              case crValue of
                Nothing -> logWarnC "Received message with no value"
                Just valueBytes -> do
                  case decode (BL.fromStrict valueBytes) of
                    Nothing -> logErrorC "Failed to decode message as JSON"
                    Just jsonValue -> do
                      h jsonValue
                      void $ commitAllOffsets OffsetCommit consumer
            Nothing ->
              logWarnC $ "No handler configured for topic: " <> displayShow crTopic
