{-# LANGUAGE DataKinds, FlexibleInstances, OverloadedStrings, PolyKinds,
             ScopedTypeVariables, TypeFamilies, TypeOperators #-}
module Soenke where

import           Control.Concurrent
import           Control.Monad
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Either
import           Data.Aeson
import           Data.ByteString.Lazy (ByteString)
import           Data.Proxy
import           Data.String.Conversions
import           Data.Text (Text)
import           GHC.TypeLits
import           Network.HTTP.Client        (Manager, defaultManagerSettings,
                                             newManager)
import qualified Network.HTTP.Client        as Http.Client
import           Network.HTTP.Types
import           Network.URI
import           Network.Wai
import           System.IO.Unsafe           (unsafePerformIO)


-- * Url Layout

-- $url_layout
-- These types allow you to specify a url layout for a REST API using a type
-- alias. The defined API doesn't really have value. It is convenient to define
-- a Proxy for every API.
--
-- The provided constructors are used in 'HasServer' and 'HasClient'.

-- | Endpoint for simple GET requests. The server doesn't receive any arguments
-- and serves the contained type as JSON.
data Get a

-- | Endpoint for POST requests.
data Post a

-- | The contained API (second argument) can be found under @("/" ++ path)@
-- (path being the first argument).
data (path :: k) :> a = Proxy path :> a
infixr 9 :>

-- | Union of two APIs, first takes precedence in case of overlap.
data a :<|> b = a :<|> b
infixr 8 :<|>


-- * Implementing Servers

-- | 'serve' allows you to implement an API and produce a wai 'Application'.
serve :: HasServer layout => Proxy layout -> Server layout -> Application
serve p server = toApplication (route p server)

toApplication :: RoutingApplication -> Application
toApplication ra = \ request respond -> do
  m <- ra request
  case m of
    Nothing -> respond $ responseLBS notFound404 [] "not found"
    Just response -> respond response

type RoutingApplication =
  Request -> IO (Maybe Response)

class HasServer layout where
  type Server layout :: *
  route :: Proxy layout -> Server layout -> RoutingApplication

instance ToJSON result => HasServer (Get result) where
  type Server (Get result) = EitherT (Int, String) IO result
  route Proxy action request
    | null (pathInfo request) && requestMethod request == methodGet = do
        e <- runEitherT action
        return $ Just $ case e of
          Right output ->
            responseLBS ok200 [("Content-Type", "application/json")] (encode output)
          Left (status, message) ->
            responseLBS (mkStatus status (cs message)) [] (cs message)
    | otherwise = return Nothing

instance ToJSON a => HasServer (Post a) where
  type Server (Post a) = EitherT (Int, String) IO a

  route Proxy action request
    | null (pathInfo request) && requestMethod request == methodPost = do
        e <- runEitherT action
        return $ Just $ case e of
          Right out ->
            responseLBS status201 [("Content-Type", "application/json")] (encode out)
          Left (status, message) ->
            responseLBS (mkStatus status (cs message)) [] (cs message)
    | otherwise = return Nothing

instance (KnownSymbol path, HasServer sublayout) => HasServer (path :> sublayout) where
  type Server (path :> sublayout) = Server sublayout
  route Proxy subserver request = case pathInfo request of
    (first : rest)
      | first == cs (symbolVal proxyPath)
      -> route (Proxy :: Proxy sublayout) subserver request{
           pathInfo = rest
         }
    _ -> return Nothing

    where proxyPath = Proxy :: Proxy path

instance (HasServer a, HasServer b) => HasServer (a :<|> b) where
  type Server (a :<|> b) = Server a :<|> Server b
  route Proxy (a :<|> b) request = do
    m <- route (Proxy :: Proxy a) a request
    case m of
      Nothing -> route (Proxy :: Proxy b) b request
      Just response -> return $ Just response


-- * Accessing APIs as a Client

-- | 'client' allows you to produce operations to query an API from a client.
client :: forall layout . HasClient layout => Proxy layout -> Client layout
client Proxy = clientWithRoute (Proxy :: Proxy layout) defReq

class HasClient layout where
  type Client layout :: *
  clientWithRoute :: Proxy layout -> Req -> Client layout

data Req = Req
  { reqPath  :: String
  , qs       :: QueryText
  , reqBody  :: ByteString
  }

defReq :: Req
defReq = Req "" [] ""

appendToPath :: String -> Req -> Req
appendToPath p req =
  req { reqPath = reqPath req ++ "/" ++ p }

appendToQueryString :: Text       -- ^ param name
                    -> Maybe Text -- ^ param value
                    -> Req
                    -> Req
appendToQueryString pname pvalue req
  | pvalue == Nothing = req
  | otherwise         = req { qs = qs req ++ [(pname, pvalue)]
                            }

setRQBody :: ByteString -> Req -> Req
setRQBody b req = req { reqBody = b }

reqToRequest :: (Functor m, MonadThrow m) => Req -> URI -> m Http.Client.Request
reqToRequest req uri = fmap (setrqb . setQS ) $ Http.Client.parseUrl url

  where url = show $ nullURI { uriPath = reqPath req }
                       `relativeTo` uri

        setrqb r = r { Http.Client.requestBody = Http.Client.RequestBodyLBS (reqBody req) }
        setQS = Http.Client.setQueryString $ queryTextToQuery (qs req)

{-# NOINLINE __manager #-}
__manager :: MVar Manager
__manager = unsafePerformIO (newManager defaultManagerSettings >>= newMVar)

__withGlobalManager :: (Manager -> IO a) -> IO a
__withGlobalManager action = modifyMVar __manager $ \ manager -> do
  result <- action manager
  return (manager, result)

instance FromJSON result => HasClient (Get result) where
  type Client (Get result) = URI -> EitherT String IO result
  clientWithRoute Proxy req uri = do
    innerRequest <- liftIO $ reqToRequest req uri

    innerResponse <- liftIO $ __withGlobalManager $ \ manager ->
      Http.Client.httpLbs innerRequest manager
    when (Http.Client.responseStatus innerResponse /= ok200) $
      left ("HTTP GET request failed with status: " ++ show (Http.Client.responseStatus innerResponse))
    maybe (left "HTTP GET request returned invalid json") return $
      decode' (Http.Client.responseBody innerResponse)

instance FromJSON a => HasClient (Post a) where
  type Client (Post a) = URI -> EitherT String IO a

  clientWithRoute Proxy req uri = do
    partialRequest <- liftIO $ reqToRequest req uri

    let request = partialRequest { Http.Client.method = methodPost
                                 }

    innerResponse <- liftIO . __withGlobalManager $ \ manager ->
      Http.Client.httpLbs request manager

    when (Http.Client.responseStatus innerResponse /= status201) $
      left ("HTTP POST request failed with status: " ++ show (Http.Client.responseStatus innerResponse))

    maybe (left "HTTP POST request returned invalid json") return $
      decode' (Http.Client.responseBody innerResponse)

instance (KnownSymbol path, HasClient sublayout) => HasClient (path :> sublayout) where
  type Client (path :> sublayout) = Client sublayout

  clientWithRoute Proxy req =
     clientWithRoute (Proxy :: Proxy sublayout) $
       appendToPath p req

    where p = symbolVal (Proxy :: Proxy path)

instance (HasClient a, HasClient b) => HasClient (a :<|> b) where
  type Client (a :<|> b) = Client a :<|> Client b
  clientWithRoute Proxy req =
    clientWithRoute (Proxy :: Proxy a) req :<|>
    clientWithRoute (Proxy :: Proxy b) req