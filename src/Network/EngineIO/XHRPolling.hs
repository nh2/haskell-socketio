{-# LANGUAGE OverloadedStrings, NamedFieldPuns, ExistentialQuantification, LambdaCase, GeneralizedNewtypeDeriving #-}

module Network.EngineIO.XHRPolling where

import Network.Wai
import Data.Monoid
import Data.Foldable (for_)
import Data.Conduit
import Data.Conduit.Binary (sinkLbs)
import Network.Wai.Handler.Warp
import Control.Monad.IO.Class
import Network.HTTP.Types.Status
import Network.HTTP.Types.Method
import Control.Concurrent
import Data.Map.Strict as Map (Map, insertLookupWithKey, updateLookupWithKey)
import qualified Data.Map.Strict as Map
import Data.UUID
import Data.UUID.V4 (nextRandom)
import Data.IORef
import Data.Maybe
import Control.Monad
import qualified Data.ByteString.Char8 as BS -- TODO import encoding instead of Char8?
import qualified Data.ByteString.Lazy.Char8 as BSL
import Control.Applicative

import Network.EngineIO

-- TODO use types or modules to make sure we always send a payload,
--      never accidentally a raw encoded packet

-- TODO restrict to /engine.io
-- STEP-1: Transport establishes a connection
app :: State -> (Client -> IO MessageHandler) -> Application
app state onConnect Request{ requestMethod = method, queryString = queryItems, requestBody = body, requestBodyLength = bodyLength }
  | method == methodGet  = runResourceT . liftIO $ handleGet
  | method == methodPost = handlePost
  | otherwise            = warn "bad method"
  where

    handleGet = case fromMaybe "" <$> lookup "sid" queryItems of
      Just querySid -> warnEither $
                         withClient state querySid $ \Client{ mvar } -> do
                           payload <- takeMVar mvar
                           respondOk (encodePayload payload)

      Nothing       -> newClient state Polling onConnect >>= \case
                         Left err      -> warn err
                         Right payload -> respondOk $ encodePayload payload

    handlePost = case fromMaybe "" <$> lookup "sid" queryItems of
      Nothing       -> warn "missing sid"
      Just querySid -> case bodyLength of
        ChunkedBody   -> warn "chunked POSTs are not allowed"
        KnownLength _ -> do

          allBody <- body $$ sinkLbs -- sinkLBS forces the whole LBS already

          case decodePayload (BSL.toStrict allBody) of
            Left err                -> warn err
            Right (Payload [])      -> warn "no packets in client payload"
            Right (Payload packets) -> warnEither $

               withClient state querySid $ \client ->

                -- Stop on first error when processing packets
                firstM (map (process client) packets) >>= \case
                  Just err -> warn err
                  Nothing  -> respondOk "" -- all fine

    respondOk bs = return $ responseLBS status200 [] bs

warn :: (MonadIO m) => String -> m Response
warn msg = do
  liftIO $ putStrLn msg
  return $ responseLBS status500 [] (BSL.pack msg) -- TODO send some proper json?

warnEither :: (MonadIO m) => m (Either String Response) -> m Response
warnEither = (>>= either warn return)


withClient :: (MonadIO m) => State -> SIDBS -> (Client -> m a) -> m (Either String a)
withClient State{ clientMapRef = cmr } sid f = case fromString (BS.unpack sid) of
  Nothing -> return . Left $ "sid uuid in bad format"
  Just s  -> do m'client <- lookupClient s `liftM` liftIO (readIORef cmr)
                case m'client of
                  Nothing -> return . Left $ "client with SID " ++ show s ++ " is not known"
                  Just c  -> Right `liftM` f c


-- A new client, put them into the clientMap and wait until they get a message
newClient :: State -> Transport -> (Client -> IO MessageHandler) -> IO (Either String Payload)
newClient State{ clientMapRef = cmr } transport onConnect = do
  m <- newEmptyMVar
  newSid <- nextRandom
  client <- do let clientWithoutHandler = Client m newSid transport Nothing
               messageHandler <- onConnect clientWithoutHandler
               return $ clientWithoutHandler { messageHandler = Just messageHandler }
  failed <- atomicWithClientMap cmr (addClient client)
  if failed
    then return $ Left "client already polling"
    else do
      -- STEP-2: Respond OPEN packet
      -- TODO make parameter
      -- TODO implement flashsocket, websocket
      -- The starting transport (Polling) must not be used here (otherwise we
      -- get probes on an already working transport, for which the client will
      -- expect immediate responses).
      let transports = []
      -- TODO use Builder
      let openPacket = Packet Open $ Just $ mconcat
                         [ "{ \"sid\": \"",        sid, "\""
                         , ", \"upgrades\": ",     upgrades
                         , ", \"pingTimeout\": ",  pingTimeout
                         , ", \"pingInterval\": ", pingInterval
                         , " }"]
          sid = BS.pack (toString newSid)
          upgrades = encodeTransports transports
          -- TODO make parameter
          -- TODO is this ms? Check protocol
          pingTimeout  = "1000"
          pingInterval = "1000"

          payload = Payload [openPacket]

      return $ Right payload

process :: (MonadIO m) => Client -> Packet -> m (Maybe String)
process Client{ mvar, messageHandler } p = case p of
  Packet Ping msg  -> do liftIO $ putStrLn "responding ping with pong ..."
                         liftIO . putMVar mvar $ Payload [Packet Pong msg] -- send back same data
                         liftIO $ putStrLn "responded pong"
                         return Nothing
  Packet Close _ -> do liftIO $ putStrLn "received close"
                       -- TODO not sure if we should send noop; we have to put something into the mvar
                       liftIO . putMVar mvar $ Payload [Packet Noop Nothing]
                       return Nothing
  Packet Message msg -> do liftIO $ putStrLn "received message"
                           liftIO $ case messageHandler of
                             Nothing -> putStrLn "BUG: Client got message but has no handler"
                             Just f  -> for_ msg f
                           return Nothing
  Packet typ _   -> return . Just $ "unhandled POST packet type " ++ show typ
                    -- don't process remaining packages ps

-- | Executes the actions until one returns something.
firstM :: (Monad m) => [m (Maybe a)] -> m (Maybe a)
firstM []     = return Nothing
firstM (x:xs) = x >>= maybe (firstM xs) (return . Just)

-- type SID = UUID
type SIDBS = BS.ByteString

-- class Transport t where
--   receive :: t ->
--   send :: t -> SID -> Payload -> IO Bool

data Client = Client
  { mvar :: MVar Payload
  , sid :: UUID
  , currentTransport :: Transport
  , messageHandler :: Maybe MessageHandler -- TODO unclean to be here
  }


instance Show Client where
  show (Client _ sid _ _) = "Client { sid = " ++ show sid ++ " }"

newtype ClientMap = ClientMap (Map UUID Client) deriving (Show)

data State = State
  { clientMapRef :: IORef ClientMap
  } deriving (Eq)

emptyClientMap :: ClientMap
emptyClientMap = ClientMap Map.empty


addClient :: Client -> ClientMap -> Maybe ClientMap
addClient client (ClientMap cm) = case insertLookupWithKey f (sid client) client cm of
  (Just _,  _) -> Nothing -- client was already in, that's bad
  (Nothing, m) -> Just (ClientMap m)
  where
    f _key old _new = old -- don't do anything (doesn't really matter, we return Nothing in that case)


lookupClient :: UUID -> ClientMap -> Maybe Client
lookupClient sid (ClientMap cm) = Map.lookup sid cm


removeClientBySID :: UUID -> ClientMap -> Maybe ClientMap
removeClientBySID sid (ClientMap cm) = case updateLookupWithKey f sid cm of
  (Nothing, _) -> Nothing -- client was not in, that's bad
  (Just _,  m) -> Just (ClientMap m)
  where
    f _key _old = Nothing -- remove the value


atomicWithClientMap :: IORef ClientMap -> (ClientMap -> Maybe ClientMap) -> IO Bool
atomicWithClientMap ref f = atomicModifyIORef ref $ \cm -> case f cm of
  Just newCm -> (newCm, False)
  Nothing    -> (cm,    True) -- this is the bad case


type MessageHandler = BS.ByteString -> IO ()


data SocketIOServer = SocketIOServer
  { state          :: State
  , pollingBackend :: Maybe PollingBackend
  }

data SocketIOSettings = SocketIOSettings
  { port       :: Int
  , transports :: [Transport]
  , onConnect  :: Client -> IO MessageHandler
  }

defaultSocketIOSettings :: SocketIOSettings
defaultSocketIOSettings = SocketIOSettings
  { port       = 1234
  , transports = [Websocket, Flashsocket, Polling]
  , onConnect  = const $ return (\_ -> return ())
  }

newSocketIOServer :: SocketIOSettings -> IO SocketIOServer
newSocketIOServer SocketIOSettings{ port, transports, onConnect } = do

  state <- State <$> newIORef emptyClientMap

  -- Start polling backend
  m'pollingBackend <- if Polling `elem` transports
                        then do m <- newEmptyMVar
                                _ <- forkIO $ run port (app state onConnect) >> putMVar m ()
                                return (Just $ PollingBackend m)
                        else return Nothing

  return $ SocketIOServer
    { state          = state
    , pollingBackend = m'pollingBackend
    }

-- TODO change this to `run` and make it actually start everything?
waitSocketIOServer :: SocketIOServer -> IO ()
waitSocketIOServer SocketIOServer { pollingBackend } =
  for_ pollingBackend $ \PollingBackend { finishedMvar = m } ->
    takeMVar m

data PollingBackend = PollingBackend
  { finishedMvar :: MVar ()
  }


-- TODO remove
main :: IO ()
main = do
  server@SocketIOServer{ state } <- newSocketIOServer defaultSocketIOSettings
    { onConnect = \_client -> do
        putStrLn "client connected"
        return $ \bytes -> do
          putStrLn $ "client sent: " ++ show bytes
    }

  _ <- forkIO $ forever $ do
    pingAllClients state
    threadDelay 1000000

  waitSocketIOServer server

  where
    pingAllClients State{ clientMapRef = r } = do
      ClientMap cm <- readIORef r
      forM (Map.toList cm) $ \(_, Client{ mvar }) ->
        tryPutMVar mvar (Payload [Packet Message (Just "hello")])
