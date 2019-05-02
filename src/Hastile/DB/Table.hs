{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE QuasiQuotes           #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeOperators         #-}

module Hastile.DB.Table where

import qualified Control.Exception.Base        as ControlException
import qualified Control.Monad.IO.Class        as MonadIO
import qualified Data.Either                   as DataEither
import qualified Data.Map.Strict               as DataMapStrict
import           Data.String.Here.Interpolated
import qualified Data.Text                     as Text
import qualified Data.Text.Encoding            as TextEncoding
import qualified Hasql.Decoders                as HasqlDecoders
import qualified Hasql.Encoders                as HasqlEncoders
import qualified Hasql.Pool                    as HasqlPool
import qualified Hasql.Statement               as HasqlStatement
import qualified Hasql.Transaction             as HasqlTransaction
import qualified Hasql.Transaction.Sessions    as HasqlTransactionSession
import qualified Katip

import qualified Hastile.DB                    as DB
import qualified Hastile.Lib.Log               as LibLog
import qualified Hastile.Types.Config          as Config
import qualified Hastile.Types.Layer           as Layer

checkConfig :: Katip.LogEnv -> FilePath -> Config.Config -> IO ()
checkConfig logEnv cfgFile Config.Config{..} = do
  pool <- HasqlPool.acquire (_configPgPoolSize, _configPgTimeout, TextEncoding.encodeUtf8 _configPgConnection)
  let layers = map (uncurry Layer.Layer) $ DataMapStrict.toList _configLayers
  result <- mapM (checkLayerExists pool) layers
  case DataEither.lefts result of
    [] ->
      pure ()
    errs ->
      ControlException.bracket (pure logEnv) (\_ -> pure ()) $ \le ->
        Katip.runKatipContextT le (mempty :: Katip.LogContexts) mempty (LibLog.logErrors cfgFile errs)
  HasqlPool.release pool

checkLayerExists :: MonadIO.MonadIO m => HasqlPool.Pool -> Layer.Layer -> m (Either String ())
checkLayerExists pool layer = do
  let layerTableName = Layer.layerTableName layer
  er <- checkLayerExists' pool layerTableName
  case er of
    Left err      -> pure . Left $ Text.unpack err
    Right Nothing -> pure . Left $ "Could not find table: \'" <> Text.unpack layerTableName <> "\'"
    Right _       -> pure $ Right ()

checkLayerExists' :: (MonadIO.MonadIO m) => HasqlPool.Pool -> Text.Text -> m (Either Text.Text (Maybe Text.Text))
checkLayerExists' pool layerTableName =
  DB.runTransaction HasqlTransactionSession.Read pool action
  where
    action = HasqlTransaction.statement layerTableName checkLayerExistsQuery

checkLayerExistsQuery :: HasqlStatement.Statement Text.Text (Maybe Text.Text)
checkLayerExistsQuery =
  HasqlStatement.Statement sql (HasqlEncoders.param HasqlEncoders.text) decoder False
  where
    sql = [i|
      SELECT to_regclass($1) :: VARCHAR;
    |]
    decoder = HasqlDecoders.singleRow $ HasqlDecoders.nullableColumn HasqlDecoders.text

    -- HasqlStatement.Statement sql HasqlEncoders.unit (HasqlDecoders.rowList Token.tokenDecoder) False
    -- (HasqlDecoders.rowList Token.tokenDecoder)
    -- DB.runTransaction HasqlTransactionSession.Read pool action
    -- where
    --   action = HasqlTransaction.statement () getTokensQuery

wkbGeometryTables :: MonadIO.MonadIO m => HasqlPool.Pool -> m (Either Text.Text [Text.Text])
wkbGeometryTables pool =
  DB.runTransaction HasqlTransactionSession.Read pool action
  where
    action = HasqlTransaction.statement () wkbGeometryTablesQuery

wkbGeometryTablesQuery :: HasqlStatement.Statement () [Text.Text]
wkbGeometryTablesQuery =
  HasqlStatement.Statement sql HasqlEncoders.unit decoder False
  where
    sql = [i|
      SELECT
        table_name
      FROM
        information_schema.COLUMNS
      WHERE
        column_name = 'wkb_geometry'
      AND
        udt_name = 'geometry'
    |]
    decoder = HasqlDecoders.rowList $ HasqlDecoders.column HasqlDecoders.text
