-- 20260708090000_contract_rate.sql — a contract's negotiated day rate per level,
-- versioned over time (issue #31). Most engagements bill the firm-wide `rate_card`,
-- but a negotiated contract locks in its own day rate for a level, scoped to that
-- one contract. Billing prefers this row over `rate_card` when one covers the
-- agreed date. The PERIOD FK pins every version inside the contract's own signed
-- term (`contract_terms`) — a negotiated rate cannot outlive the term it was struck
-- under. The PK is DEFERRABLE so the single-statement delete-then-insert upsert
-- (clip the version covering the effective date, open the next from there) can
-- carve a row's end at the same instant the next row opens.
CREATE TABLE contract_rate (
  contract_id int NOT NULL REFERENCES contract (id),
  level       int NOT NULL CONSTRAINT contract_rate_level_check CHECK (level BETWEEN 1 AND 7),
  day_rate    numeric(10,2) NOT NULL,
  effective_during daterange NOT NULL,
  audit_id    bigint NOT NULL REFERENCES event_log (id),
  CONSTRAINT contract_rate_no_overlap
    PRIMARY KEY (contract_id, level, effective_during WITHOUT OVERLAPS)
    DEFERRABLE INITIALLY IMMEDIATE,
  CONSTRAINT contract_rate_within_term
    FOREIGN KEY (contract_id, PERIOD effective_during)
    REFERENCES contract_terms (contract_id, PERIOD term)
);
CREATE INDEX contract_rate_audit_id_idx ON contract_rate (audit_id);
