module Service.Kafka
  ( KafkaProducer,
    KafkaConsumer,
    ConsumerConfig (..),
    TopicHandler (..),
    HasKafkaProducer (..),
    Settings (..),
    DeadLetterMessage (..),
    decoder,
    startProducer,
    startConsumer,
    produceMessage,
    produceMessageWithCid,
    consumerLoop,
    runConsumerLoop,
  )
where

import qualified Control.Concurrent as CC
import Data.Aeson (ToJSON, Value, decode, encode)
import qualified Data.Aeson as Aeson
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import qualified Data.Map.Strict as Map
import qualified Data.Text.Encoding as TE
import Kafka.Consumer
import Kafka.Producer hiding (produceMessage)
import Kafka.Types (Headers)
import RIO
import qualified RIO.ByteString as BS
import qualified RIO.ByteString.Lazy as BL
import RIO.Text (pack, unpack)
import Text.Read (reads)
import Service.CorrelationId (CorrelationId (..), HasCorrelationId (..), HasLogContext (..), appendCorrelationId, generateCorrelationId, logErrorC, logInfoC, logWarnC)
import System.Envy (FromEnv (..), decodeEnv, env, (.!=))
import System.IO.Error (mkIOError, userErrorType)

data Settings = Settings
  { kafkaBroker :: !Text,
    kafkaGroupId :: !Text,
    kafkaDeadLetterTopic :: !Text,
    kafkaMaxRetries :: !Int
  }
  deriving (Show, Eq)

instance FromEnv Settings where
  fromEnv _ =
    Settings
      <$> (pack <$> (env "KAFKA_BROKER" .!= "localhost:9092"))
      <*> (pack <$> (env "KAFKA_GROUP_ID" .!= "haskell-service-group"))
      <*> (pack <$> (env "KAFKA_DEAD_LETTER_TOPIC" .!= "DEADLETTER"))
      <*> (env "KAFKA_MAX_RETRIES" .!= 3)

decoder :: (HasLogFunc env) => RIO env Settings
decoder = do
  result <- liftIO $ decodeEnv
  case result of
    Left err -> do
      logWarn $ "Failed to decode Kafka settings, using defaults: " <> displayShow err
      return $ Settings (pack "localhost:9092") (pack "haskell-service-group") (pack "DEADLETTER") 3
    Right settings -> return settings

class HasKafkaProducer env where
  produceKafkaMessage :: (ToJSON a) => TopicName -> Maybe Text -> a -> RIO env ()

data TopicHandler env = TopicHandler
  { topic :: !TopicName,
    handler :: !(Value -> RIO env ())
  }

data ConsumerConfig env = ConsumerConfig
  { brokerAddress :: !Text,
    groupId :: !Text,
    topicHandlers :: ![TopicHandler env],
    deadLetterTopic :: !TopicName,
    maxRetries :: !Int,
    consumerRecordMessageMetrics :: Text -> UTCTime -> UTCTime -> Either SomeException () -> RIO env (),
    consumerRecordOffsetMetrics :: Text -> Int -> Int -> Int -> RIO env ()
  }

data DeadLetterMessage = DeadLetterMessage
  { originalTopic :: !Text,
    originalMessage :: !Value,
    originalHeaders :: ![(Text, Text)],
    errorType :: !Text,
    errorDetails :: !Text,
    correlationId :: !Text,
    timestamp :: !UTCTime,
    retryCount :: !Int
  }
  deriving (Show, Eq, Generic)

instance ToJSON DeadLetterMessage

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
          <> Kafka.Consumer.extraProps (Map.fromList [("auto.offset.reset", "earliest")])

  let topicList = map topic (topicHandlers config)
  let kafkaSubscription = topics topicList

  consumer <- newConsumer consumerProps kafkaSubscription
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

sendToDeadLetter ::
  (HasLogFunc env, HasLogContext env, HasKafkaProducer env) =>
  TopicName ->
  ByteString ->
  Headers ->
  Text ->
  Text ->
  CorrelationId ->
  RIO env ()
sendToDeadLetter originalTopic messageBytes headers errorType errorDetails cid = do
  timestamp <- liftIO getCurrentTime
  let originalMessage = case decode (BL.fromStrict messageBytes) of
        Just val -> val
        Nothing -> Aeson.String $ TE.decodeUtf8 messageBytes

      headersList = map (\(k, v) -> (TE.decodeUtf8 k, TE.decodeUtf8 v)) (headersToList headers)

      dlm = DeadLetterMessage
        { originalTopic = case originalTopic of TopicName t -> t,
          originalMessage = originalMessage,
          originalHeaders = headersList,
          errorType = errorType,
          errorDetails = errorDetails,
          correlationId = unCorrelationId cid,
          timestamp = timestamp,
          retryCount = 0
        }

  logErrorC $ "Sending message to dead letter queue: " <> display errorType <> " - " <> display errorDetails
  produceKafkaMessage (TopicName "DEADLETTER") Nothing dlm

consumerLoop ::
  (HasLogFunc env, HasCorrelationId env, HasLogContext env, HasKafkaProducer env) =>
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
      Right (ConsumerRecord {..}) -> do
        let maybeHeaderCid = lookup "X-Correlation-Id" (headersToList crHeaders)
        baseCid <- case maybeHeaderCid of
          Just cidBytes
            | not (BS.null cidBytes) ->
                return $ CorrelationId $ TE.decodeUtf8 cidBytes
          _ ->
            generateCorrelationId

        cid <- appendCorrelationId baseCid

        let cidText = unCorrelationId cid
        local (set correlationIdL cid . set logContextL (Map.singleton "cid" cidText)) $ do
          logInfoC
            $ "--> "
            <> displayShow crTopic
            <> " (partition="
            <> displayShow crPartition
            <> " offset="
            <> displayShow crOffset
            <> ")"

          case Map.lookup crTopic handlerMap of
            Just h -> do
              case crValue of
                Nothing -> do
                  logWarnC "Received message with no value"
                  void $ commitAllOffsets OffsetCommit consumer
                Just valueBytes -> do
                  case decode (BL.fromStrict valueBytes) of
                    Nothing -> do
                      sendToDeadLetter crTopic valueBytes crHeaders "JSON_DECODE_ERROR" "Failed to decode message as JSON" cid
                      void $ commitAllOffsets OffsetCommit consumer
                    Just jsonValue -> do
                      -- Handler execution with automatic metrics collection
                      let topicText = case crTopic of TopicName t -> t
                          -- Convert partition to Int by parsing the show output
                          partitionText = pack $ show crPartition
                          partitionId = case reads (unpack partitionText) of
                            [(p, "")] -> p
                            _ -> 0 -- Default to 0 if parsing fails
                          -- Convert offset to Int by parsing the show output
                          offsetText = pack $ show crOffset
                          currentOffset = case reads (unpack offsetText) of
                            [(o, "")] -> o
                            _ -> 0 -- Default to 0 if parsing fails
                      start <- liftIO getCurrentTime
                      result <- tryAny (h jsonValue)
                      end <- liftIO getCurrentTime

                      -- Record metrics via config callbacks
                      consumerRecordMessageMetrics config topicText start end result

                      let highWaterMark = currentOffset + 1
                      consumerRecordOffsetMetrics config topicText partitionId currentOffset highWaterMark

                      let ms = round (diffUTCTime end start * 1000) :: Int
                      case result of
                        Left ex -> do
                          logErrorC $ "<-- " <> display topicText <> " FAILED (" <> displayShow ms <> "ms): " <> displayShow ex
                          sendToDeadLetter crTopic valueBytes crHeaders "HANDLER_ERROR" (pack $ show ex) cid
                          void $ commitAllOffsets OffsetCommit consumer
                        Right _ -> do
                          logInfoC $ "<-- " <> display topicText <> " OK (" <> displayShow ms <> "ms)"
                          void $ commitAllOffsets OffsetCommit consumer
            Nothing -> do
              logWarnC $ "No handler configured for topic: " <> displayShow crTopic
              void $ commitAllOffsets OffsetCommit consumer

-- | Start and run the Kafka consumer loop. If 'topicHandlers' is empty
-- (the service only produces), this blocks the thread forever without
-- opening a Kafka connection, so callers can always use @race_@ unconditionally.
runConsumerLoop ::
  (HasLogFunc env, HasCorrelationId env, HasLogContext env, HasKafkaProducer env) =>
  ConsumerConfig env ->
  RIO env ()
runConsumerLoop config
  | null (topicHandlers config) = liftIO $ forever $ CC.threadDelay maxBound
  | otherwise = do
      consumer <- startConsumer config
      consumerLoop consumer config
