-- 20260705150000_availability.sql — Phase B availability inputs. work_schedule is a
-- per-weekday temporal fact (FOR PORTION set-from-date, like engineer_location);
-- focus_block and holiday are plain rows carrying only audit_id (the Phase C meeting
-- pattern). holiday_region.region uses '' for nationwide so the composite PK and every
-- FK stay enforced; engineer_location.region is normalized to '' and gains the FK.
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE holiday_region (
  country text NOT NULL,
  region  text NOT NULL DEFAULT '',
  name    text NOT NULL,
  PRIMARY KEY (country, region)
);

CREATE TABLE holiday (
  country    text   NOT NULL,
  region     text   NOT NULL DEFAULT '',
  holiday_on date   NOT NULL,
  name       text   NOT NULL,
  audit_id   bigint NOT NULL REFERENCES event_log (id),
  PRIMARY KEY (country, region, holiday_on),
  FOREIGN KEY (country, region) REFERENCES holiday_region (country, region)
);
CREATE INDEX holiday_audit_id_idx ON holiday (audit_id);

CREATE TABLE work_schedule (
  engineer_id bigint    NOT NULL REFERENCES engineer (id),
  weekday     int       NOT NULL CHECK (weekday BETWEEN 0 AND 6),
  valid_at    daterange NOT NULL,
  starts      time      NOT NULL,
  ends        time      NOT NULL,
  audit_id    bigint    NOT NULL REFERENCES event_log (id),
  CHECK (starts < ends),
  PRIMARY KEY (engineer_id, weekday, valid_at WITHOUT OVERLAPS) DEFERRABLE INITIALLY IMMEDIATE
);
CREATE INDEX work_schedule_audit_id_idx ON work_schedule (audit_id);

CREATE TABLE focus_block (
  id          bigint    GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  engineer_id bigint    NOT NULL REFERENCES engineer (id),
  busy_at     tstzrange NOT NULL,
  title       text      NOT NULL,
  audit_id    bigint    NOT NULL REFERENCES event_log (id)
);
CREATE INDEX focus_block_audit_id_idx ON focus_block (audit_id);
CREATE INDEX focus_block_busy_gist ON focus_block USING gist (engineer_id, busy_at);

INSERT INTO holiday_region (country, region, name) VALUES
  ('AU', '', 'Australia'), ('AU', 'AU-NSW', 'New South Wales'),
  ('US', '', 'United States'), ('US', 'US-CA', 'California'),
  ('GB', '', 'United Kingdom'), ('GB', 'GB-LND', 'London');

UPDATE engineer_location SET region = '' WHERE region IS NULL;
ALTER TABLE engineer_location
  ALTER COLUMN region SET NOT NULL,
  ALTER COLUMN region SET DEFAULT '';
ALTER TABLE engineer_location
  ADD FOREIGN KEY (country, region) REFERENCES holiday_region (country, region);
