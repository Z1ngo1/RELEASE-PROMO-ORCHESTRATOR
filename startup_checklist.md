# Release & Promo Orchestrator, Startup Checklist

An IBM Z Xplore learning project. Stack: 4 CICS COBOL programs + 1 batch
COBOL program + DB2 + a Flask/JS frontend, all running through the CICS
region's own built-in HTTP support.

> A note on the userid used throughout this checklist: `Z73460` is my own
> TSO userid on IBM Z Xplore. This is a shared learning environment where
> every student has their own individual profile, dataset prefix, and CICS
> region. If you're using this checklist as a reference for your own setup,
> replace `Z73460` everywhere it appears with your own userid.

Profile used in this checklist: `Z73460`, APPLID `CXZ73460`, host
`s0w1.dal-ebis.ihost.com` / `204.90.115.200`.

---

## 1. Architecture (for reference)

```
Browser → Flask (app.py, foreground SSH) → CICS Web Support (port 4558) → URIMAP → COBOL program → DB2
```

| Program | Type | Table | Functions |
|---|---|---|---|
| RELSMGR | CICS | RELEASE_T | ADD/GET/LIST/UPD/DEL |
| PROMGR | CICS | PROMO_T | ADD/GET/LIST/UPD/DEL |
| EVTMGR | CICS | EXT_EVENT_T | ADD/GET/LIST/UPD/DEL |
| CLASHRDR | CICS | CLASH_SCORE_T | GET only, read-only |
| CLSHBAT | Batch | CLASH_SCORE_T | Recalculates risk scores for all CONFIRMED releases |

All four CICS programs share the same `TCPIPSERVICE(DFH$WUTC)` on port
4558 and the same `DB2ENTRY(CSMID)` with `TRANSID(CWBA)`,
`AUTHID(Z73460)`. Full CRUD, including DELETE, is implemented for all
three editable entities.

---

## 2. Startup sequence (after an Xplore session was idle)

**Step 1, Connect to the mainframe:**
```bash
ssh z73460@204.90.115.200
```
(replace `z73460` with your own userid)

**Step 2, Confirm the CICS region is actually up.** Log into your 3270
session (APPLID `CXZ73460`). If the region doesn't respond, the Xplore
session likely hasn't finished initializing yet, wait, or check the
course's own status instructions.

**Step 3, Check the DB2 connection status:**
```
CEMT INQUIRE DB2CONN
```
Look for `Connectst(Connected)`. If `Notconnected`:
```
CEMT SET DB2CONN CONNECTED
```
**This is the single most common cause of "everything suddenly broke."**
DB2CONN drops to `NOTCONNECTED` after `DB2ENTRY` state changes
(DISABLED→ENABLED) or sometimes just after a long idle period. It shows
up as abend `AEY9`, or, if you're testing over HTTP, as `AWBM` in the log
(a generic wrapper, the real cause, `AEY9`, is logged just before it;
check SDSF).

**Step 4, Confirm all four URIMAPs exist and are enabled:**
```
CEMT INQUIRE URIMAP(RELSMGR1)
CEMT INQUIRE URIMAP(PROMGR1)
CEMT INQUIRE URIMAP(EVTMGR1)
CEMT INQUIRE URIMAP(CLASHRDR)
```
All should show `Ena`. If any are missing entirely, reinstall the group:
```
CEDA INSTALL GROUP(ORCHGRP)
```

**Step 5, Quick backend smoke test (from SSH):**
```bash
curl -s "http://s0w1.dal-ebis.ihost.com:4558/relsmgr/list" --output -
```
Expect a JSON array. If you get an HTML `500 Internal Server Error`
page instead, see the Diagnostics section below.

**Step 6, Start Flask (in a separate SSH window/session):**
```bash
cd ~/cicspy
python3 app.py
```
Note the port from the `Running on http://204.90.115.200:XXXXX` line -
it's random every run (`port=0`).

**Step 7, Open the site** in a browser at `http://204.90.115.200:XXXXX`.

---

## 3. Diagnostics: when something isn't working

| Symptom | Likely cause | Fix |
|---|---|---|
| HTML `500 Internal Server Error` instead of JSON | CICS abend, check SDSF | See "Reading SDSF" below |
| `AWBM` in the SDSF log | Generic wrapper. Look **earlier in the same log** for the real cause (usually `AEY9`) | Look at the real code, not AWBM |
| `AEY9` | DB2CONN is NOTCONNECTED | `CEMT SET DB2CONN CONNECTED` |
| `SQLCODE -805` (package not found) right after a BIND | One of the DB2 packages fell out of the plan's `PKLIST` after `BIND ... ACTION(REPLACE)` | See the PKLIST rule below |
| `SQLCODE -805` appearing suddenly on a program that was working, with a correct PKLIST | That specific program's package is out of sync with the plan (its DBRM/package version is stale) | Recompile just that program: `COMPILE.jcl` with `SET MEMBER=<PROGRAM>`, confirm the BIND step succeeds, retest |
| `SQLCODE -803` (duplicate key) on ADD | Sequence is out of sync with the real max ID already in the table (e.g. after a manual INSERT with a hand-picked ID) | `ALTER SEQUENCE ... RESTART WITH N` (N = current max + 1) |
| `SQLCODE -545` inserting into CHANGE_LOG with ACTION='DEL' | A CHECK constraint that doesn't include 'DEL' | `ALTER TABLE ... DROP/ADD CONSTRAINT`; if that leaves the tablespace in CHECK PENDING, run `REPAIR SET TABLESPACE ... NOCHECKPEND` |
| Empty curl output / "Binary output" warning | Just curl's normal behavior, not a server bug | `curl ... --output -` to force it to print |

### Reading SDSF on a 500 error
```
SDSF → LOG for region CXZ73460
Look for, in chronological order (bottom to top):
  DFHDU0203I  -- "transaction dump was taken for dumpcode: XXXX"
  DFHAC2236   -- "Transaction CWBA abend XXXX in program YYYY"
```
If you see `AWBM`, **that is not the root cause**. `DFHWBBLI` catches the
program's real abend, logs it, sends an HTTP 500 to the client, and then
issues `EXEC ABEND ABCODE('AWBM')` as CICS Web Support's standard way of
ending the transaction. The actual abend code (`AEY9`, `ASRA`, etc.)
appears in the dump **immediately before** the AWBM entry.

---

## 4. The PKLIST rule (important!)

**Any `BIND PLAN(Z73460) ... ACTION(REPLACE)` must list every package
explicitly**, even when the specific job only touches one of them:

```
PKLIST(DSN_DEFAULT_COLLID_Z73460.RELSMGR, -
       DSN_DEFAULT_COLLID_Z73460.PROMGR, -
       DSN_DEFAULT_COLLID_Z73460.EVTMGR, -
       DSN_DEFAULT_COLLID_Z73460.CLASHRDR, -
       DSN_DEFAULT_COLLID_Z73460.CLSHBAT) -
```

This project uses **one shared plan for every program**, not a separate
plan per program. `ACTION(REPLACE)` doesn't add a package to the plan -
it entirely replaces the plan's package list with whatever is listed in
that specific BIND. So even a JCL job that only compiles the batch
program (`CLSHJCL.jcl`) must still re-list every other package the plan
depends on, or those packages silently drop out of the plan and the next
CICS transaction that needs one of them fails with `-805`, even though
the package itself is still physically sitting in the DB2 catalog,
untouched. Using a wildcard (`Z73460.*`) or a short list will break
access to the other programs, this has happened more than once in this
project's history.

Check the current `PKLIST` in:
- `COMPILE.JCL` (the generic compile job used for any CICS program)
- `CLSHJCL.JCL` (compiles + binds + runs CLSHBAT)

**If the PKLIST looks correct but you still get -805**, check the real
package list and the plan's actual PKLIST directly against the DB2
catalog:
```sql
SELECT COLLID, NAME FROM SYSIBM.SYSPACKAGE
WHERE COLLID = 'DSN_DEFAULT_COLLID_Z73460'
ORDER BY NAME;

SELECT PLANNAME, COLLID, NAME
FROM SYSIBM.SYSPACKLIST
WHERE PLANNAME = 'Z73460'
ORDER BY SEQNO;
```
If the package shows up in both lists but you're still getting -805, the
problem is a stale package version, not a missing list entry, recompile
that program (see the diagnostics table above).

---

## 5. CICS resource inventory

| Resource | Value |
|---|---|
| TCPIPSERVICE | `DFH$WUTC`, port 4558, HTTP |
| DB2CONN Plan | `Z73460` |
| DB2ENTRY | `CSMID`, `TRANSID(CWBA)`, `AUTHID(Z73460)`, group `ORCHGRP` |
| URIMAP RELSMGR1 | `/relsmgr/*` → PROGRAM(RELSMGR), HOST(*) |
| URIMAP PROMGR1 | `/promgr/*` → PROGRAM(PROMGR), HOST(*) |
| URIMAP EVTMGR1 | `/evtmgr/*` → PROGRAM(EVTMGR), HOST(*) |
| URIMAP CLASHRDR | `/clashrdr/*` → PROGRAM(CLASHRDR), HOST(*) |

All URIMAPs use `USAGE(SERVER)`, the default transaction `CWBA`, and
`TCPIPSERVICE(DFH$WUTC)`. There are no custom transaction IDs on this
system, `CWBA` is assigned automatically by CICS Web Support to every
inbound HTTP request.

---

## 6. DB2, tables and sequences

| Table | Sequence | ID format |
|---|---|---|
| RELEASE_T | SEQ_RELEASE (NO CACHE) | RELn |
| PROMO_T | SEQ_PROMO (CACHE 20) | PROn |
| EXT_EVENT_T | SEQ_EVENT (CACHE 20) | EVTn |
| CLASH_SCORE_T | SEQ_SCORE (CACHE 20) | SCRn |
| CHANGE_LOG | SEQ_LOG (CACHE 20) | numeric (LOG_ID) |

### What CACHE/NO CACHE means

`CACHE n` makes DB2 grab a block of n numbers at once and hand them out
from memory, instead of hitting the catalog on every single request.
Faster, but each DB2 thread caches its own block, so under concurrent
load numbers can come out of order or skip around between threads.

`SEQ_RELEASE` uses `NO CACHE` because this actually happened - new
releases sometimes got ID values that didn't match reality, traced to
CICS routing requests through different threads that each held their
own cached block. `NO CACHE` forces every call straight to the catalog,
slower per call but always correct order. The other sequences kept
`CACHE 20` since the problem only ever showed up on `SEQ_RELEASE`.

**Table cleanup order (if you need to wipe everything and start over):**
```sql
DELETE FROM Z73460.CLASH_SCORE_T;
DELETE FROM Z73460.PROMO_T;
DELETE FROM Z73460.RELEASE_T;
DELETE FROM Z73460.EXT_EVENT_T;
DELETE FROM Z73460.CHANGE_LOG;
```
(PROMO_T and CLASH_SCORE_T reference RELEASE_T via FK, delete them
before RELEASE_T itself.)

Reset all sequences to 1:
```sql
ALTER SEQUENCE Z73460.SEQ_RELEASE RESTART WITH 1;
ALTER SEQUENCE Z73460.SEQ_PROMO   RESTART WITH 1;
ALTER SEQUENCE Z73460.SEQ_EVENT   RESTART WITH 1;
ALTER SEQUENCE Z73460.SEQ_SCORE   RESTART WITH 1;
ALTER SEQUENCE Z73460.SEQ_LOG     RESTART WITH 1;
```

---

## 7. Recalculating Clash Risk

`CLASH_SCORE_T` is only ever populated by the `CLSHBAT` batch job, never
by a CICS transaction. It deletes its own old rows (`DELETE FROM
CLASH_SCORE_T`) before every recalculation, no manual cleanup needed.

```
Submit CLSHJCL.JCL
```
Only scores pairs among releases with STATUS = CONFIRMED. This is run
strictly by hand, there's no button for it on the site. That's
intentional: it mirrors how a real production process would separate
"someone edits data" from "someone triggers a recalculation," rather
than firing a recalculation on every single click.

---

## 8. Known, deliberately accepted limitations

- Old rows in `CHANGE_LOG` and `CLASH_SCORE_T` written before the
  `MOVE SPACES` fix was applied may still contain leftover binary
  garbage, this is safely neutralized on read by the sanitizer logic
  in CLASHRDR, but existing rows were never retroactively cleaned up
  (only new rows written after the fix are guaranteed clean).
- PROMO_T's RELEASE_ID cannot be changed via UPD (that would be a
  "move to a different release" operation, not an edit, deliberately
  not implemented).
- No authentication, the site is fully open to anyone with the
  IP/port. Fine for a local demo, not meant for production use.
- CICS Web Support doesn't support `AUTHENTICATE` on a `USAGE(SERVER)`
  URIMAP, integrating RACF login through CICS itself isn't
  architecturally available on this path. A separate layer (e.g.
  checking credentials against USS/SSH from Flask) would be needed for
  that, and hasn't been built.
