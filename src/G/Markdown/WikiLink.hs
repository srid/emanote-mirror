{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}

module G.Markdown.WikiLink
  ( wikiLinkSpec,
    WikiLinkID,
    WikiLinkLabel,
    parseWikiLinkUrl,
  )
where

import qualified Commonmark as CM
import qualified Commonmark.Inlines as CM
import Commonmark.TokParsers (noneOfToks, symbol)
import Data.Tagged (Tagged (..), untag)
import qualified Data.Text as T
import qualified Text.Megaparsec as M
import qualified Text.Parsec as P
import Text.Read
import qualified Text.Show (Show (..))

-- | The inner text of a wiki link.
type WikiLinkID = Tagged "WikiLinkID" Text

data WikiLinkLabel
  = WikiLinkLabel_Unlabelled
  | -- | [[Foo]]#
    WikiLinkLabel_Branch
  | -- | #[[Foo]]
    WikiLinkLabel_Tag
  deriving (Eq, Ord)

instance Show WikiLinkLabel where
  show = \case
    WikiLinkLabel_Unlabelled -> "link:nolbl"
    WikiLinkLabel_Branch -> "link:branch"
    WikiLinkLabel_Tag -> "link:tag"

instance Read WikiLinkLabel where
  readsPrec _ s
    | s == show WikiLinkLabel_Unlabelled =
      [(WikiLinkLabel_Unlabelled, "")]
    | s == show WikiLinkLabel_Branch =
      [(WikiLinkLabel_Branch, "")]
    | s == show WikiLinkLabel_Tag =
      [(WikiLinkLabel_Tag, "")]
    | otherwise = []

wikiLinkSpec ::
  (Monad m, CM.IsBlock il bl, CM.IsInline il) =>
  CM.SyntaxSpec m il bl
wikiLinkSpec =
  mempty
    { CM.syntaxInlineParsers = [pLink]
    }
  where
    pLink ::
      (Monad m, CM.IsInline il) =>
      CM.InlineParser m il
    pLink =
      P.try $
        P.choice
          [ -- All neuron type links; not propagating link type for now.
            cmAutoLink WikiLinkLabel_Branch <$> P.try (wikiLinkP 3),
            cmAutoLink WikiLinkLabel_Tag <$> P.try (symbol '#' *> wikiLinkP 2),
            cmAutoLink WikiLinkLabel_Branch <$> P.try (wikiLinkP 2 <* symbol '#'),
            cmAutoLink WikiLinkLabel_Unlabelled <$> P.try (wikiLinkP 2)
          ]
    wikiLinkP :: Monad m => Int -> P.ParsecT [CM.Tok] s m WikiLinkID
    wikiLinkP n = do
      void $ M.count n $ symbol '['
      s <-
        fmap CM.untokenize $
          some $
            noneOfToks [CM.Symbol ']', CM.Symbol '[', CM.LineEnd]
      void $ M.count n $ symbol ']'
      pure $ Tagged s
    cmAutoLink :: CM.IsInline a => WikiLinkLabel -> WikiLinkID -> a
    cmAutoLink lbl iD =
      CM.link (renderWikiLinkUrl iD) (show lbl) $ CM.str (untag iD)

-- | Make [[Foo]] link to "Foo". In future, make this configurable.
renderWikiLinkUrl :: WikiLinkID -> Text
renderWikiLinkUrl (Tagged s) = s

-- | Parse what was rendered by renderWikiLinkUrl
-- TODO: Extract label!
parseWikiLinkUrl :: Maybe Text -> Text -> Maybe (WikiLinkLabel, WikiLinkID)
parseWikiLinkUrl mtitle s = do
  guard $ not $ ":" `T.isInfixOf` s
  guard $ not $ "/" `T.isInfixOf` s
  let linkLabel = fromMaybe WikiLinkLabel_Unlabelled $ readMaybe . toString =<< mtitle
      linkId = Tagged s
  pure (linkLabel, linkId)