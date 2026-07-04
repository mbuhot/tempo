-- 20260704140000_engineer_location.sql — an engineer's location over time (Phase A of
-- scheduling). `located_during` is the application-time period; the timezone is an IANA
-- TZID (Australia/Sydney), so an engineer's zone on any date is `located_during @> date`.
-- country/region are ISO codes carried as plain text in Phase A; Phase B adds the
-- holiday_region FK. Standalone like engineer_contact (no PERIOD containment).
CREATE TABLE engineer_location (
  engineer_id    bigint    NOT NULL REFERENCES engineer (id),
  located_during daterange NOT NULL,
  country        text      NOT NULL,
  region         text,
  timezone       text      NOT NULL,
  audit_id       bigint    REFERENCES event_log (id),
  CONSTRAINT engineer_location_no_overlap
    PRIMARY KEY (engineer_id, located_during WITHOUT OVERLAPS)
    DEFERRABLE INITIALLY IMMEDIATE
);
CREATE INDEX engineer_location_audit_id_idx ON engineer_location (audit_id);
