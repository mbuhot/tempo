-- 20260705120000_meeting.sql — meetings for the scheduling subsystem (Phase C). Unlike
-- every other domain table these rows are plain and mutable: a reschedule is an in-place
-- UPDATE of meeting_at, a cancel flips status. Only audit_id links each change to
-- event_log (who/when); no bitemporal period is kept. meeting is an identity anchor so a
-- future detail dimension can be added without touching it.
CREATE TABLE meeting (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY);

CREATE TABLE meeting_detail (
  meeting_id bigint    NOT NULL PRIMARY KEY REFERENCES meeting (id),
  meeting_at tstzrange NOT NULL,
  meeting_tz text      NOT NULL,
  title      text      NOT NULL,
  location   text,
  status     text      NOT NULL DEFAULT 'scheduled',
  client_id  bigint    REFERENCES client (id),
  project_id bigint    REFERENCES project (id),
  audit_id   bigint    NOT NULL REFERENCES event_log (id)
);
CREATE INDEX meeting_detail_audit_id_idx ON meeting_detail (audit_id);

CREATE TABLE meeting_attendee (
  meeting_id  bigint NOT NULL REFERENCES meeting (id) ON DELETE CASCADE,
  engineer_id bigint NOT NULL REFERENCES engineer (id),
  attendance  text   NOT NULL DEFAULT 'required',
  PRIMARY KEY (meeting_id, engineer_id)
);
