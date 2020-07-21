module Type.Trout.Client
       ( class HasClients
       , getClients
       , class HasMethodClients
       , getMethodClients
       , asClients
       , JSONClientError(..)
       , class ClientError
       , printError
       ) where

import Prelude

import Affjax (Request, defaultRequest, request)
import Affjax (Error, printError) as Affjax
import Affjax.RequestBody (RequestBody, toMediaType)
import Affjax.RequestBody (json) as AXRequestBody
import Affjax.RequestHeader (RequestHeader(..))
import Affjax.ResponseFormat (json, string) as AXResponseFormat
import Data.Argonaut (class DecodeJson, class EncodeJson, JsonDecodeError, decodeJson, encodeJson, printJsonDecodeError)
import Data.Array ((:), singleton)
import Data.Bifunctor (bimap, lmap, rmap)
import Data.Either (Either)
import Data.Foldable (foldl)
import Data.HTTP.Method as Method
import Data.Maybe (Maybe(..))
import Data.String (joinWith)
import Data.Symbol (class IsSymbol, SProxy(..), reflectSymbol)
import Data.Tuple (Tuple(..))
import Effect.Aff (Aff)
import Prim.Row (class Cons)
import Type.Proxy (Proxy(..))
import Type.Trout (type (:<|>), type (:=), type (:>), Capture, CaptureAll, Header, Lit, Method, QueryParam, QueryParams, ReqBody, Resource)
import Type.Trout.ContentType.HTML (HTML)
import Type.Trout.ContentType.JSON (JSON)
import Type.Trout.Header (class ToHeader, toHeader)
import Type.Trout.PathPiece (class ToPathPiece, toPathPiece)
import Type.Trout.Record as Record

type RequestBuilder =
  { path :: Array String
  , params :: Array (Tuple String String)
  , headers :: Array RequestHeader
  , content :: Maybe RequestBody
  }

emptyRequestBuilder :: RequestBuilder
emptyRequestBuilder = { path: [], params: [], headers: [], content: Nothing }

appendSegment :: String -> RequestBuilder -> RequestBuilder
appendSegment segment req =
  req { path = req.path <> singleton segment }

appendQueryParam :: String -> String -> RequestBuilder -> RequestBuilder
appendQueryParam param value req =
  req { params = req.params <> singleton (Tuple param value) }

appendHeader :: String -> String -> RequestBuilder -> RequestBuilder
appendHeader name value req =
  req { headers = RequestHeader name value : req.headers }

appendContent :: RequestBody -> RequestBuilder -> RequestBuilder
appendContent content req = req
  { content = Just content
  , headers = case toMediaType content of
                Nothing -> req.headers
                Just mt -> ContentType mt : req.headers
  }

toAffjaxRequest :: RequestBuilder -> Request Unit
toAffjaxRequest req = defaultRequest
  { url = "/" <> joinWith "/" req.path <> params
  , headers = req.headers
  , content = req.content
  }
  where
  params = case req.params of
    [] -> ""
    segments -> "?" <> joinWith "&" (map (\(Tuple q x) -> q <> "=" <> x) segments)

class HasClients r mk | r -> mk where
  getClients :: Proxy r -> RequestBuilder -> mk

instance hasClientsAlt :: ( HasClients c1 mk1
                          , HasClients c2 (Record mk2)
                          , IsSymbol name
                          , Cons name mk1 mk2 out
                          )
                          => HasClients (name := c1 :<|> c2) (Record out) where
  getClients _ req = Record.insert name first rest
    where
      name = SProxy :: SProxy name
      first = getClients (Proxy :: Proxy c1) req
      rest = getClients (Proxy :: Proxy c2) req

instance hasClientsNamed :: ( HasClients c mk
                          , IsSymbol name
                          , Cons name mk () out
                          )
                          => HasClients (name := c) (Record out) where
  getClients _ req = Record.insert name clients {}
    where
      name = SProxy :: SProxy name
      clients = getClients (Proxy :: Proxy c) req

instance hasClientsLit :: (HasClients sub subMk, IsSymbol lit)
                          => HasClients (Lit lit :> sub) subMk where
  getClients _ req =
    getClients (Proxy :: Proxy sub) (appendSegment segment req)
    where
      segment = reflectSymbol (SProxy :: SProxy lit)

instance hasClientsCapture :: (HasClients sub subMk, IsSymbol c, ToPathPiece t)
                              => HasClients (Capture c t :> sub) (t -> subMk) where
  getClients _ req x =
    getClients (Proxy :: Proxy sub) (appendSegment (toPathPiece x) req)

instance hasClientsCaptureAll :: (HasClients sub subMk, IsSymbol c, ToPathPiece t)
                                 => HasClients (CaptureAll c t :> sub) (Array t -> subMk) where
  getClients _ req xs =
    getClients (Proxy :: Proxy sub) (foldl (flip appendSegment) req (map toPathPiece xs))

instance hasClientsQueryParam :: (HasClients sub subMk, IsSymbol c, ToPathPiece t)
                                 => HasClients (QueryParam c t :> sub) (Maybe t -> subMk) where
  getClients _ req x =
    getClients (Proxy :: Proxy sub) (foldl (flip $ appendQueryParam q) req (map toPathPiece x))
    where
    q = reflectSymbol (SProxy :: SProxy c)

instance hasClientsQueryParams :: (HasClients sub subMk, IsSymbol c, ToPathPiece t)
                                  => HasClients (QueryParams c t :> sub) (Array t -> subMk) where
  getClients _ req x =
    getClients (Proxy :: Proxy sub) (foldl (flip $ appendQueryParam q) req (map toPathPiece x))
    where
    q = reflectSymbol (SProxy :: SProxy c)

instance hasClientsHeader :: (HasClients sub subMk, IsSymbol n, ToHeader t)
                             => HasClients (Header n t :> sub) (t -> subMk) where
  getClients _ req x =
    getClients (Proxy :: Proxy sub) $ appendHeader h (toHeader x) req
    where
    h = reflectSymbol (SProxy :: SProxy n)

instance hasClientsReqBody :: (HasClients sub subMk, EncodeJson a)
                              => HasClients (ReqBody a JSON :> sub) (a -> subMk) where
  getClients _ req x =
    getClients (Proxy :: Proxy sub) $ appendContent (AXRequestBody.json $ encodeJson x) req 

instance hasClientsResource :: (HasClients methods clients)
                              => HasClients (Resource methods) clients where
  getClients _ req =
    getClients (Proxy :: Proxy methods) req

instance hasClientsMethodAlt :: ( IsSymbol method
                                , HasMethodClients method repr cts mk1
                                , HasClients methods (Record mk2)
                                , Cons method mk1 mk2 out
                                )
                                => HasClients
                                   (Method method repr cts :<|> methods)
                                   (Record out) where
  getClients _ req =
    Record.insert method first rest
    where
      method = SProxy :: SProxy method
      cts = Proxy :: Proxy cts
      first = getMethodClients method cts req
      rest = getClients (Proxy :: Proxy methods) req

instance hasClientsMethod :: ( IsSymbol method
                             , HasMethodClients method repr cts mk1
                             , Cons method mk1 () out
                             )
                             => HasClients (Method method repr cts) (Record out) where
  getClients _ req =
    Record.insert method clients {}
    where
      method = SProxy :: SProxy method
      cts = Proxy :: Proxy cts
      clients = getMethodClients method cts req

toMethod :: forall m
          . IsSymbol m
          => SProxy m
         -> Either Method.Method Method.CustomMethod
toMethod p = Method.fromString (reflectSymbol p)

class ClientError e where
  printError :: e -> String

class HasMethodClients method repr cts client | cts -> repr, cts -> client where
  getMethodClients :: SProxy method -> Proxy cts -> RequestBuilder -> client

data JSONClientError
  = RequestError Affjax.Error
  | DecodeError JsonDecodeError

instance clientErrorJSONClientError :: ClientError JSONClientError where
  printError (RequestError e) = Affjax.printError e
  printError (DecodeError e) = printJsonDecodeError e

instance hasMethodClientMethodJson
  :: (DecodeJson r, IsSymbol method)
  => HasMethodClients method r JSON (Aff (Either JSONClientError r)) where
  getMethodClients method _ req = do
    toAffjaxRequest req
      # _ { method = toMethod method, responseFormat = AXResponseFormat.json }
      # request
      # map (bimap RequestError (_.body >>> decodeJson >>> lmap DecodeError) >>> join)

instance clientErrorAffjaxError :: ClientError Affjax.Error where
  printError = Affjax.printError

instance hasMethodClientsHTMLString
  :: IsSymbol method
  => HasMethodClients method String HTML (Aff (Either Affjax.Error String)) where
  getMethodClients method _ req = do
    toAffjaxRequest req
      # _ { method = toMethod method, responseFormat = AXResponseFormat.string }
      # request
      # map (rmap _.body)

asClients :: forall r mk. HasClients r mk => Proxy r -> mk
asClients = flip getClients emptyRequestBuilder
