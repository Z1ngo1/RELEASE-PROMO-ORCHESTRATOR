# CICS Web Support Configuration Guide
## Release & Promo Orchestrator - Real System Reference

Everything in this document reflects the actual deployed state on
`s0w1.dal-ebis.ihost.com`, port 4558, schema Z73460, DB2 subsystem DBDG.
All CEDA commands and curl tests were run and confirmed working on the live system.

---

## How CICS Web Support routes requests

```
Flask (requests library)
  |  HTTP GET or POST to http://s0w1.dal-ebis.ihost.com:4558/relsmgr/list
  v
CICS TCPIPSERVICE DFH$WUTC (port 4558, already existed, not created by this project)
  |
  v
URIMAP (e.g. RELSMGR1) matches the incoming URI path
  |  No TRANSACTION() clause on any URIMAP, CWBA is the implicit default
  v
CWBA (CICS Web Support default transaction)
  |  Looks up the PROGRAM associated with the matching URIMAP
  v
COBOL program (e.g. RELSMGR)
  |  EXEC CICS WEB EXTRACT HTTPMETHOD(...) PATH(...)
  |  EXEC CICS WEB READ QUERYPARM(...) or FORMFIELD(...)
  |  EXEC SQL ...
  |  EXEC CICS WEB SEND FROM(WS-RESPONSE) MEDIATYPE('application/json')
  |             HOSTCODEPAGE('1047') CHARACTERSET('utf-8')
  v
HTTP JSON response back to Flask
```

**Key fact:** There are no custom transactions like RELS, PROM, CLSH, EVTM on
this system. CICS Web Support uses transaction **CWBA** for all inbound HTTP requests
automatically. No `TRANSACTION()` clause is needed or specified in any URIMAP definition.

---

## CICS Resource Definitions

All resources were defined interactively via CEDA in a 3270 session and installed with
CEDA INSTALL. No JCL was used for any CICS resource definition.

### TCPIPSERVICE, already existed, not created by this project

```
CEMT INQUIRE TCPIPSERVICE(DFH$WUTC)
```

Port 4558, protocol HTTP.

---

### DB2ENTRY

```
CEMT INQUIRE DB2ENTRY(CSMID)
```

`TRANSID(CWBA)`, `AUTHID(Z73460)`, `PLAN(Z73460)`, group `ORCHGRP`.

This entry associates transaction CWBA with DB2 plan Z73460 under auth ID Z73460.

---

### DB2CONN, check before testing

```
CEMT INQUIRE DB2CONN
```

Must show `Connectst(Connected)`. If it shows `Notconnected`:

```
CEMT SET DB2CONN CONNECTED
```

All CICS programs will fail with abend AEY9 if DB2CONN is not connected. If you see
`AWBM` in the CICS log, look for AEY9 just before it, that is DB2CONN not connected.

---

### Programs and Group

All four CICS COBOL programs are installed in group `ORCHGRP`:

| Program  | Purpose |
|----------|---------|
| RELSMGR  | Release full CRUD |
| PROMGR   | Promo checklist full CRUD |
| EVTMGR   | External event full CRUD |
| CLASHRDR | Clash score reader (GET only) |

Install: `CEDA INSTALL GROUP(ORCHGRP)`

---

### URIMAPs, actual definitions as deployed

No `TRANSACTION()` clause on any URIMAP. CWBA handles all HTTP automatically.

```
CEDA DEFINE URIMAP(RELSMGR1) GROUP(ORCHGRP)
     USAGE(SERVER) SCHEME(HTTP) HOST(*)
     PATH(/relsmgr/*)
     TCPIPSERVICE(DFH$WUTC)

CEDA DEFINE URIMAP(PROMGR1) GROUP(ORCHGRP)
     USAGE(SERVER) SCHEME(HTTP) HOST(*)
     PATH(/promgr/*)
     TCPIPSERVICE(DFH$WUTC)

CEDA DEFINE URIMAP(EVTMGR1) GROUP(ORCHGRP)
     USAGE(SERVER) SCHEME(HTTP) HOST(*)
     PATH(/evtmgr/*)
     TCPIPSERVICE(DFH$WUTC)

CEDA DEFINE URIMAP(CLASHRDR) GROUP(ORCHGRP)
     USAGE(SERVER) SCHEME(HTTP) HOST(*)
     PATH(/clashrdr/*)
     TCPIPSERVICE(DFH$WUTC)
```

Install all: `CEDA INSTALL GROUP(ORCHGRP)`

Check status:

```
CEMT INQUIRE URIMAP(RELSMGR1)
CEMT INQUIRE URIMAP(PROMGR1)
CEMT INQUIRE URIMAP(EVTMGR1)
CEMT INQUIRE URIMAP(CLASHRDR)
```

All should show `Ena`. If any shows `Dis`, use `CEMT SET URIMAP(...) ENABLED`.

---

## URL Reference

Base URL: `http://s0w1.dal-ebis.ihost.com:4558`

### RELSMGR - /relsmgr/*

| Action | Method | URL / body |
|--------|--------|------------|
| List all releases | GET | `/relsmgr/list` |
| Get one release | GET | `/relsmgr/get?id=REL1` |
| Add a release | POST | `/relsmgr/add`, form fields: `title`, `genre`, `platform`, `releaseDate`, `windowEnd`, `market` |
| Update a release | POST | `/relsmgr/upd`, form fields: `id`, `title`, `genre`, `platform`, `releaseDate`, `windowEnd`, `market`, `status`, all fields required, not just the changed one |
| Delete a release | POST | `/relsmgr/del`, form field: `id`, fails with SQLCODE -532 if PROMO_T or CLASH_SCORE_T rows exist |

### PROMGR - /promgr/*

| Action | Method | URL / body |
|--------|--------|------------|
| List promo items for a release | GET | `/promgr/list?relId=REL1` |
| Get one promo item | GET | `/promgr/get?id=PRO1` |
| Add a promo item | POST | `/promgr/add`, form fields: `relId`, `itemName`, `status`, `dueDate` (optional), `owner` (optional) |
| Update a promo item | POST | `/promgr/upd`, form fields: `id`, `itemName`, `status`, `dueDate`, `owner`, all fields required |
| Delete a promo item | POST | `/promgr/del`, form field: `id` |

### EVTMGR - /evtmgr/*

| Action | Method | URL / body |
|--------|--------|------------|
| List all events | GET | `/evtmgr/list` |
| Get one event | GET | `/evtmgr/get?id=EVT1` |
| Add an event | POST | `/evtmgr/add`, form fields: `evtName`, `evtDate`, `evtEnd` (optional), `genre`, `market`, `severity` |
| Update an event | POST | `/evtmgr/upd`, form fields: `id`, `evtName`, `evtDate`, `evtEnd`, `genre`, `market`, `severity`, all fields required |
| Delete an event | POST | `/evtmgr/del`, form field: `id` |

### CLASHRDR - /clashrdr/* (GET only)

| Action | Method | URL |
|--------|--------|-----|
| Get clash scores for a release | GET | `/clashrdr/get?id=REL1` |

Returns all rows where `RELEASE_ID = id`. CLASHRDR does not query `CLASH_WITH_ID`,
CLSHBAT always stores the lower-ID release as `RELEASE_ID`, so querying for a
higher-ID release returns no rows. The Flask/JS layer handles both sides client-side.

---

## Confirmed Curl Tests

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

## Expected Response Shapes

| Endpoint type | Success | Not found / error |
|---|---|---|
| List | `[{...}, {...}]`, empty array `[]` if no rows | `{"error":"..."}` on DB2 failure |
| Get single | `{...}` JSON object | `{"error":"...not found"}` |
| Add / upd / del | `{"...Id":"...", "message":"..."}` | `{"error":"...", "sqlcode":"..."}` |

---

## BIND PLAN PKLIST Rule

Any `BIND PLAN(Z73460) ... ACTION(REPLACE)` must list all five packages explicitly,
every time, in both `COMPILE.jcl` and `CLSHJCL.jcl`. This bit us more than once:

```
PKLIST(DSN_DEFAULT_COLLID_Z73460.RELSMGR,  -
       DSN_DEFAULT_COLLID_Z73460.PROMGR,   -
       DSN_DEFAULT_COLLID_Z73460.EVTMGR,   -
       DSN_DEFAULT_COLLID_Z73460.CLASHRDR, -
       DSN_DEFAULT_COLLID_Z73460.CLSHBAT)  -
```

Missing a comma or omitting a package causes `SQLCODE -805` the next time that JCL
runs and rebinds the plan. ACTION(REPLACE) with an incomplete PKLIST silently drops
the missing packages from the plan.

---

## Troubleshooting - Real Issues Encountered on This System

| Symptom | Real cause found | Fix |
|---|---|---|
| `SQLCODE -805` | Package missing from PKLIST | Rebind via COMPILE.jcl with full PKLIST |
| `SQLCODE -532` on DELETE | Dependent PROMO_T or CLASH_SCORE_T rows exist | Delete dependents first |
| `SQLCODE -530` on PROMO add | RELEASE_ID doesn't exist in RELEASE_T | Verify the release ID |
| `SQLCODE -545` on CHANGE_LOG insert | CHECK constraint didn't include `DEL`, was `IN ('ADD','UPD')` only | Fixed via ALTER TABLE + `REPAIR SET NOCHECKPEND` |
| `SQLCODE -798` (avoided) | Would happen if LOG_ID were `GENERATED ALWAYS AS IDENTITY`, real table uses SEQ_LOG instead | n/a, design avoids this |
| Duplicate key on ADD | Sequence out of sync with real MAX(id) after restoring seed data | `ALTER SEQUENCE Z73460.SEQ_RELEASE RESTART WITH N` where N is max+1 |
| Garbled or truncated JSON fields | Missing `MOVE SPACES` before `STRING`, leaving stale bytes past the new value | Add `MOVE SPACES TO WS-JSON-ROW` before each STRING call |
| `AWBM` in CICS log | Generic wrapper abend, real code logged just before it | Look for `AEY9` = DB2CONN not connected; run `CEMT SET DB2CONN CONNECTED` |
| `{"error":"Unknown path"}` | URIMAP matched, program ran, but path check in COBOL didn't match | Check the exact path string in the WHEN clause against what WEB EXTRACT actually returns |
| CICS returns HTML error page instead of JSON | Transaction abended before WEB SEND | Check CICS CEMT for abend, check CICS log |
