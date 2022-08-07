{-

CREATE SEQUENCE domains_id_seq;
CREATE TABLE IF NOT EXISTS domains (
  id int8 PRIMARY KEY,
  domain text UNIQUE NOT NULL,
  rank int4
);

CREATE INDEX domains_domain_idx ON domains (domain);

-}

module DB.Domain where

import Data.Coerce (coerce)
import Data.Functor.Identity
import Data.Int (Int32)
import Data.Text (Text)
import GHC.Generics (Generic)
import Prelude hiding (null)
import Rel8 hiding (Enum)
import Types


data Domain f = Domain
  { dom_id :: Column f DomainId
  , dom_domain :: Column f Text
  , dom_rank :: Column f (Maybe Int32)
  }
  deriving stock Generic
  deriving anyclass Rel8able

deriving instance Eq (Domain Identity)
deriving instance Show (Domain Identity)

emptyDomain :: Domain Identity
emptyDomain = Domain
  { dom_id = DomainId 0
  , dom_domain = ""
  , dom_rank = Nothing
  }



nextDomainId :: Query (Expr DomainId)
nextDomainId = fmap coerce $ pure $ nextval "domains_id_seq"


domainsSchema :: TableSchema (Domain Name)
domainsSchema = TableSchema
  { name    = "domains"
  , schema  = Just "public"
  , columns = Domain
      { dom_id = "id"
      , dom_domain = "domain"
      , dom_rank = "rank"
      }
  }

