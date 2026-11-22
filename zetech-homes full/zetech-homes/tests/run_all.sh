#!/usr/bin/env bash
# Builds a fresh local test database and loads every SQL file in order.
set -euo pipefail
DB=zh_test
PSQL="runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q -X"
runuser -u postgres -- psql -q -X -c "drop database if exists $DB" -c "create database $DB"
for f in tests/00_supabase_stub.sql supabase/01_schema.sql supabase/02_logic.sql supabase/03_security.sql \
         supabase/04_lookup_data.sql supabase/06_storage.sql; do
  echo "== loading $f"; cat "$f" | $PSQL -d $DB
done
