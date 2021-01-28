{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}

module Main where

import qualified Commonmark.Syntax as CM
import Data.Conflict (Conflict (..))
import qualified Data.Conflict as Conflict
import qualified Data.Conflict.Patch as Conflict
import qualified Data.Map as Map
import Data.Tagged (Tagged (..))
import qualified Data.Text as T
import G.FileSystem (directoryTreeIncremental)
import qualified G.Markdown as M
import qualified G.Markdown.WikiLink as M
import Options.Applicative
import Reflex
import Reflex.Dom.Builder.Static (renderStatic)
import qualified Reflex.Dom.Pandoc as PR
import Reflex.Host.Headless (runHeadlessApp)
import System.Directory (removeFile)
import System.FilePath (addExtension, addTrailingPathSeparator, dropExtension, takeExtension, takeFileName)
import Text.Pandoc.Definition (Pandoc)

cliParser :: Parser (FilePath, FilePath)
cliParser =
  (,)
    <$> fmap
      addTrailingPathSeparator
      (strArgument (metavar "INPUT" <> help "Input directory path (.md files)"))
    <*> fmap
      addTrailingPathSeparator
      (strArgument (metavar "OUTPUT" <> help "Output directory path (must exist)"))

main :: IO ()
main = do
  (inputDir, outputDir) <- execParser $ info (cliParser <**> helper) fullDesc
  runHeadlessApp $ do
    res <- runPipe <$> directoryTreeIncremental [".*/**"] inputDir
    drainPipe (generateHtmlFiles outputDir) res
    pure never

drainPipe ::
  forall t m k v.
  ( Reflex t,
    PerformEvent t m,
    MonadSample t m,
    MonadIO m,
    MonadIO (Performable m),
    Ord k,
    Show k
  ) =>
  -- | Function that does the draining of individual values in the Incremental.
  (forall m1. MonadIO m1 => k -> Maybe v -> m1 ()) ->
  -- | The @Incremental@ coming out at the end of the pipeline.
  Incremental t (PatchMap k v) ->
  m ()
drainPipe f fsIncFinal = do
  -- Process initial data.
  x0 <- sample $ currentIncremental fsIncFinal
  liftIO $ putTextLn $ "INI " <> show (void x0)
  forM_ (Map.toList . unPatchMap $ patchMapInitialize x0) $
    uncurry f
  let xE = updatedIncremental fsIncFinal
  -- Process patches.
  performEvent_ $
    ffor xE $ \m -> do
      liftIO $ putTextLn $ "EVT " <> show (void m)
      forM_ (Map.toList . unPatchMap $ m) $ uncurry f
  pure ()
  where
    -- We "cheat" by treating the initial map as a patch map, that "adds" all
    -- initial data.
    patchMapInitialize :: Map k v -> PatchMap k v
    patchMapInitialize = PatchMap . fmap Just

-- | Pipe the filesystem three through until determining the "final" data.
runPipe ::
  Reflex t =>
  Incremental t (PatchMap FilePath ByteString) ->
  Incremental t (PatchMap ID (Either (Conflict FilePath ByteString) (FilePath, Either M.ParserError Pandoc)))
runPipe x =
  x
    & pipeFilterExt ".md"
    & pipeFlattenFsTree (Tagged . T.replace " " "-" . T.toLower . toText . dropExtension . takeFileName)
    & pipeParseMarkdown (M.wikiLinkSpec <> M.markdownSpec)

generateHtmlFiles ::
  MonadIO m =>
  FilePath ->
  ID ->
  Maybe (Either (Conflict FilePath ByteString) (FilePath, Either M.ParserError Pandoc)) ->
  m ()
generateHtmlFiles outputDir (Tagged fId) mv = do
  let k = addExtension (toString fId) ".html"
      g = outputDir <> k
  case mv of
    Just (Left conflict) -> do
      liftIO $ putTextLn $ "CON " <> show conflict
      writeFileBS g $ "<p style='color: red'>" <> show conflict <> "</p>"
    Just (Right (_fp, eres)) -> do
      case eres of
        Left (Tagged err) -> do
          liftIO $ putTextLn $ "ERR " <> err
          writeFileText g $ "<pre>" <> err <> "</pre>"
        Right doc -> do
          liftIO $ putTextLn $ "WRI " <> toText k
          s <- liftIO $ renderPandoc doc
          writeFileBS g $ "<pre>" <> s <> "</pre>"
    Nothing -> do
      liftIO $ putTextLn $ "DEL " <> toText k
      liftIO $ removeFile g
  where
    renderPandoc :: Pandoc -> IO ByteString
    renderPandoc =
      fmap snd . renderStatic . PR.elPandoc PR.defaultConfig

pipeFilterExt ::
  Reflex t =>
  String ->
  Incremental t (PatchMap FilePath v) ->
  Incremental t (PatchMap FilePath v)
pipeFilterExt ext =
  let f :: FilePath -> v -> Maybe v
      f = \fs x -> guard (takeExtension fs == ext) >> pure x
   in unsafeMapIncremental
        (Map.mapMaybeWithKey f)
        (PatchMap . Map.mapMaybeWithKey f . unPatchMap)

pipeParseMarkdown ::
  (Reflex t, Functor f, Functor g, M.MarkdownSyntaxSpec m il bl) =>
  CM.SyntaxSpec m il bl ->
  Incremental t (PatchMap ID (f (g ByteString))) ->
  Incremental t (PatchMap ID (f (g (Either M.ParserError Pandoc))))
pipeParseMarkdown spec =
  unsafeMapIncremental
    (Map.mapWithKey $ \fId -> (fmap . fmap) (parse fId))
    (PatchMap . Map.mapWithKey ((fmap . fmap . fmap) . parse) . unPatchMap)
  where
    parse :: ID -> ByteString -> Either M.ParserError Pandoc
    parse (Tagged (toString -> fn)) = M.parseMarkdown spec fn . decodeUtf8

-- | ID of a Markdown file
type ID = Tagged "ID" Text

pipeFlattenFsTree ::
  forall t v.
  (Reflex t) =>
  -- | How to flatten the file path.
  (FilePath -> ID) ->
  Incremental t (PatchMap FilePath v) ->
  Incremental t (PatchMap ID (Either (Conflict FilePath v) (FilePath, v)))
pipeFlattenFsTree toKey = do
  unsafeMapIncrementalWithOldValue
    (Conflict.resolveConflicts toKey)
    (Conflict.applyPatch toKey)

-- | Like `unsafeMapIncremental` but the patch function also takes the old
-- target.
unsafeMapIncrementalWithOldValue ::
  (Reflex t, Patch p, Patch p') =>
  (PatchTarget p -> PatchTarget p') ->
  (PatchTarget p -> p -> p') ->
  Incremental t p ->
  Incremental t p'
unsafeMapIncrementalWithOldValue f g x =
  let x0 = currentIncremental x
      xE = updatedIncremental x
   in unsafeBuildIncremental (f <$> sample x0) $ uncurry g <$> attach x0 xE
