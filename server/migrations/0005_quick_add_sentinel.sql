-- Per-user singleton for the /log/quick_add sentinel food. Allows
-- INSERT … ON CONFLICT to be the idempotent provisioning path.
CREATE UNIQUE INDEX foods_quick_add_singleton
  ON foods(owner_user_id)
  WHERE source = 'user' AND name = '__quick_add__';
