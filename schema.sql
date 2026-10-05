CREATE TABLE IF NOT EXISTS mosques (
  id        INTEGER PRIMARY KEY,
  name      TEXT NOT NULL,
  address   TEXT NOT NULL,
  lat       REAL,          -- optional until a location picker exists
  lng       REAL,
  timezone  TEXT NOT NULL  -- 'Asia/Kolkata'
);

CREATE TABLE IF NOT EXISTS timings (
  mosque_id    INTEGER NOT NULL REFERENCES mosques(id),
  prayer       TEXT NOT NULL
               CHECK (prayer IN ('fajr','zuhr','asr','maghrib','isha','jumuah')),
  azan_time    TEXT NOT NULL, -- 'HH:MM'
  jamaat_time  TEXT NOT NULL, -- 'HH:MM'
  updated_at   TEXT NOT NULL, -- UTC ISO-8601
  PRIMARY KEY (mosque_id, prayer)
);

CREATE TABLE IF NOT EXISTS users (
  id          INTEGER PRIMARY KEY,
  email       TEXT NOT NULL UNIQUE,       -- trimmed, lowercase
  blocked     INTEGER NOT NULL DEFAULT 0, -- 1 = may not sign in
  created_at  TEXT NOT NULL               -- UTC ISO-8601
);

CREATE TABLE IF NOT EXISTS sign_in_codes (
  email       TEXT PRIMARY KEY,     -- trimmed, lowercase
  code_hash   TEXT NOT NULL,        -- SHA-256 hex
  attempts    INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL,        -- UTC ISO-8601
  expires_at  TEXT NOT NULL         -- UTC ISO-8601
);

CREATE TABLE IF NOT EXISTS sessions (
  token_hash  TEXT PRIMARY KEY,     -- SHA-256 hex
  user_id     INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at  TEXT NOT NULL,        -- UTC ISO-8601
  expires_at  TEXT NOT NULL         -- UTC ISO-8601
);

CREATE TABLE IF NOT EXISTS follows (
  user_id     INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  mosque_id   INTEGER NOT NULL REFERENCES mosques(id) ON DELETE CASCADE,
  created_at  TEXT NOT NULL,        -- UTC ISO-8601
  PRIMARY KEY (user_id, mosque_id)
);
