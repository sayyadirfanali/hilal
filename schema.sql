CREATE TABLE IF NOT EXISTS mosques (
  id        INTEGER PRIMARY KEY,
  name      TEXT NOT NULL,
  address   TEXT NOT NULL,
  lat       REAL NOT NULL,
  lng       REAL NOT NULL,
  timezone  TEXT NOT NULL -- 'Asia/Kolkata'
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