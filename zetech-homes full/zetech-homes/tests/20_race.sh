#!/usr/bin/env bash
# Two database sessions try to change the SAME listing at the SAME time, both
# holding version 1. Exactly one may win; the other must get a conflict.
# Usage: ./tests/20_race.sh [database]      (run after tests/10_rules_test.sql)
DB=${1:-zh_test}
P="runuser -u postgres -- psql -X -q -t -A -d $DB"
MGR=aaaaaaaa-0000-0000-0000-000000000001
AG1=aaaaaaaa-0000-0000-0000-000000000002
LR="LR/2026/0$((RANDOM % 9000 + 1000))"

# a fresh listing at version 1, created by agent1
ID=$($P <<SQL | tail -1
begin;
select set_config('request.jwt.claim.sub','$AG1',true) \gset
set local role authenticated;
select (public.rpc_create_property(jsonb_build_object('lr_number','$LR','title','Race condition test house',
 'property_type_id',1,'price',9000000,'county_id',(select id from counties where name='Nairobi'),
 'sub_county_id',(select id from sub_counties where name='Westlands'),'location','Test Road 1',
 'description','Race test','bedrooms',2,'bathrooms',1)))->>'id';
commit;
SQL
)
echo "listing $LR (id=$ID) is at version 1; two users both loaded it"

# Session A (agent1) reserves it and keeps its transaction open for 3 seconds
( $P > /tmp/race_a.out <<SQL
begin;
select set_config('request.jwt.claim.sub','$AG1',true) \gset
set local role authenticated;
select 'A (agent1, reserve): ' || (public.rpc_change_status($ID,1,'RESERVED','{"name":"Race Buyer","phone":"0712000111","id_number":"11223344"}',1000))::text;
select pg_sleep(3);
commit;
SQL
) &
sleep 1
# Session B (manager) edits the price from the same version while A is still open
START=$(date +%s)
$P > /tmp/race_b.out <<SQL
begin;
select set_config('request.jwt.claim.sub','$MGR',true) \gset
set local role authenticated;
select 'B (manager, edit price): ' || (public.rpc_update_property($ID,1,'{"price": 1234}'))::text;
commit;
SQL
END=$(date +%s)
wait
grep -h "^[AB] " /tmp/race_a.out /tmp/race_b.out
echo "B waited $((END-START))s: PostgreSQL queued the second writer behind the first one's row lock"
$P -c "select 'final: status=' || status || ', version=' || version || ', price=' || price from properties where id=$ID"
$P -c "select 'active reservations=' || count(*) from reservations where property_id=$ID and status='ACTIVE'"
$P -c "select 'conflicts logged for this listing=' || count(*) from audit_log where action='MVCC_CONFLICT' and target_lr='$LR'"
