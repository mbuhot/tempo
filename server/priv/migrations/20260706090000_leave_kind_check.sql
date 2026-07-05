-- Close the leave-kind vocabulary: `kind` on `leave` and `leave_policy` may only be
-- one of the four values `shared/leave/kind.gleam` enumerates. An unrecognised value
-- read back from either column is a violated invariant, not a silently-passed string.

ALTER TABLE leave
  ADD CONSTRAINT leave_kind_check
  CHECK (kind IN ('annual', 'sick', 'parental', 'unpaid'));

ALTER TABLE leave_policy
  ADD CONSTRAINT leave_policy_kind_check
  CHECK (kind IN ('annual', 'sick', 'parental', 'unpaid'));
