#!/bin/sh
set -eu

db=hilal.db
email="${HILAL_EMAIL:-you@example.com}"

rm -f "$db" "$db-wal" "$db-shm" edits.log
sqlite3 "$db" < schema.sql

sqlite3 "$db" <<'SQL'
BEGIN;

INSERT INTO mosques (id, name, address, lat, lng, timezone) VALUES
  (1, 'Jama Masjid',         'Sector 6, Bhilai',      21.2036,  81.3700, 'Asia/Kolkata'),
  (2, 'Sultan Ahmed Mosque', 'Sultanahmet, Istanbul', 41.0054,  28.9768, 'Europe/Istanbul'),
  (3, 'Istiqlal Mosque',     'Gambir, Jakarta',       -6.1702, 106.8314, 'Asia/Jakarta');

INSERT INTO timings (mosque_id, prayer, azan_time, jamaat_time, updated_at)
VALUES (3, 'fajr', '04:30', '04:45', '2026-10-03T00:00:00Z');

INSERT INTO mosques (name, address, lat, lng, timezone)
SELECT n.column1, c.column1 || ', ' || c.column2, c.column3, c.column4, 'Asia/Kolkata'
FROM (VALUES
  ('Jama Masjid'), ('Madina Masjid'), ('Masjid-e-Noor'), ('Bilal Masjid'),
  ('Masjid-e-Quba'), ('Noorani Masjid'), ('Ghousia Masjid'), ('Masjid Al-Falah'),
  ('Rehmania Masjid'), ('Makki Masjid')
) AS n
CROSS JOIN (VALUES
  ('Supela',        'Bhilai',    21.21, 81.35),
  ('Civil Lines',   'Raipur',    21.25, 81.63),
  ('Mominpura',     'Nagpur',    21.15, 79.09),
  ('Bhendi Bazaar', 'Mumbai',    18.96, 72.83),
  ('Kurla',         'Mumbai',    19.07, 72.88),
  ('Mahim',         'Mumbai',    19.04, 72.84),
  ('Camp',          'Pune',      18.51, 73.88),
  ('Charminar',     'Hyderabad', 17.36, 78.47),
  ('Tolichowki',    'Hyderabad', 17.40, 78.42),
  ('Shivajinagar',  'Bengaluru', 12.98, 77.60),
  ('Triplicane',    'Chennai',   13.06, 80.28),
  ('Park Circus',   'Kolkata',   22.54, 88.37),
  ('Chandni Chowk', 'Delhi',     28.65, 77.23),
  ('Jamia Nagar',   'Delhi',     28.56, 77.28),
  ('Aminabad',      'Lucknow',   26.85, 80.92),
  ('Peer Gate',     'Bhopal',    23.26, 77.40),
  ('Juhapura',      'Ahmedabad', 23.00, 72.53),
  ('Dalgate',       'Srinagar',  34.08, 74.83),
  ('Kuttichira',    'Kozhikode', 11.24, 75.78),
  ('Old City',      'Indore',    22.72, 75.86)
) AS c;

UPDATE mosques
SET lat = round(lat + (id * 37 % 200 - 100) / 10000.0, 4),
    lng = round(lng + (id * 53 % 200 - 100) / 10000.0, 4)
WHERE id > 3;

UPDATE mosques
SET lat = NULL, lng = NULL
WHERE id > 3 AND id % 11 = 0;

INSERT INTO timings (mosque_id, prayer, azan_time, jamaat_time, updated_at)
SELECT
  m.id,
  p.column1,
  strftime('%H:%M', p.column2, '+' || (m.id % 15) || ' minutes'),
  strftime('%H:%M', p.column2, '+' || (m.id % 15 + 15) || ' minutes'),
  '2026-10-03T00:00:00Z'
FROM mosques AS m
CROSS JOIN (VALUES
  ('fajr',    '05:00'),
  ('zuhr',    '13:00'),
  ('asr',     '16:30'),
  ('maghrib', '18:00'),
  ('isha',    '19:30'),
  ('jumuah',  '13:15')
) AS p
WHERE m.id <> 3
  AND (m.id <= 3 OR m.id % 7 <> 0);

INSERT INTO users (email, blocked, created_at) VALUES
  ('blocked@example.com', 1, '2026-10-03T00:00:00Z');

COMMIT;
SQL

sqlite3 "$db" <<SQL
BEGIN;

INSERT INTO users (email, created_at) VALUES
  (lower('$email'), '2026-10-03T00:00:00Z');

INSERT INTO follows (user_id, mosque_id, created_at)
SELECT users.id, m.column1, '2026-10-03T00:00:00Z'
FROM users
CROSS JOIN (VALUES (1), (2), (4), (5)) AS m
WHERE users.email = lower('$email');

COMMIT;
SQL

echo "$db: $(sqlite3 "$db" 'SELECT COUNT(*) FROM mosques') mosques, following 4 as $email"
