# Manual Verification Tests
## Release & Promo Orchestrator

These are the actual tests run against the live system to confirm each part
of the stack works. Two layers: HTTP (curl, this file) and DB2 (SQL, see
`backend/ddl/VERIFSCR.sql`).

---

## HTTP layer, curl tests

All tests use `HOST="s0w1.dal-ebis.ihost.com:4558"`. Run from USS or any
machine with network access to the z/OS host.

### RELSMGR

```bash
HOST="s0w1.dal-ebis.ihost.com:4558"

# List all releases
curl -s "http://$HOST/relsmgr/list"

# Get one release
curl -s "http://$HOST/relsmgr/get?id=REL1"

# Add a release
curl -s "http://$HOST/relsmgr/add" -X POST \
  -d "title=ToDelete&genre=DRAMA&platform=STREAMING&releaseDate=2025-09-01&windowEnd=2025-10-01&market=US"

# Update a release, send every field, not just the changed one
curl -s "http://$HOST/relsmgr/upd" -X POST \
  -d "id=REL1&title=Updated Title&genre=COMEDY&platform=LINEAR&releaseDate=2025-09-05&windowEnd=2025-11-05&market=EU&status=CONFIRMED"

# Delete a release, fails with -532 if promo items or clash scores still exist
curl -s "http://$HOST/relsmgr/del" -X POST -d "id=REL5"
```

### PROMGR

```bash
# List promo items for REL1
curl -s "http://$HOST/promgr/list?relId=REL1"

# Get one promo item
curl -s "http://$HOST/promgr/get?id=PRO1"

# Add a promo item (dueDate optional)
curl -s "http://$HOST/promgr/add" -X POST \
  -d "relId=REL1&itemName=ToDelete&status=PENDING&owner=Test"

# Update a promo item, send itemName too, not just status
curl -s "http://$HOST/promgr/upd" -X POST \
  -d "id=PRO1&itemName=Updated Item&status=DONE&dueDate=2025-08-20&owner=New Owner"

# Delete a promo item
curl -s "http://$HOST/promgr/del" -X POST -d "id=PRO6"
```

### EVTMGR

```bash
# List all events
curl -s "http://$HOST/evtmgr/list"

# Get one event
curl -s "http://$HOST/evtmgr/get?id=EVT1"

# Add an event (evtEnd optional)
curl -s "http://$HOST/evtmgr/add" -X POST \
  -d "evtName=ToDelete&evtDate=2025-09-01&genre=DRAMA&market=US&severity=LOW"

# Update an event, send all fields
curl -s "http://$HOST/evtmgr/upd" -X POST \
  -d "id=EVT1&evtName=FIFA WORLD CUP FINAL&evtDate=2025-11-15&evtEnd=2025-11-15&genre=SPORT&market=GLOBAL&severity=HIGH"

# Delete an event
curl -s "http://$HOST/evtmgr/del" -X POST -d "id=EVT5"
```

### CLASHRDR

```bash
# Get clash scores for REL1
curl -s "http://$HOST/clashrdr/get?id=REL1"
```

---

## DB2 layer, SQL verification

See `backend/ddl/VERIFSCR.sql`, 6 queries run via SPUFI:

1. Count of scored pairs (expect 6 for 4 CONFIRMED releases)
2. Full score listing, highest risk first
3. Score check for a specific known pair
4. Confirm a DRAFT release was NOT scored (expect 0 rows)
5. Human-readable report joined to release titles
6. Simulates exactly what CLASHRDR's own query returns for one release

Run these after any CLSHBAT rescore to confirm the batch job did what it
was supposed to.
