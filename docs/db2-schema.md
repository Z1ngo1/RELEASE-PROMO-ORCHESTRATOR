# DB2 Schema Reference
## Release & Promo Orchestrator, Schema Z73460, Subsystem DBDG

---

## Table Creation Order

FK dependencies require this exact order when running `CREATTAB.sql`:

```
1. EXT_EVENT_T    - no FK dependencies
2. RELEASE_T      - no FK dependencies
3. PROMO_T        - FK -> RELEASE_T
4. CLASH_SCORE_T  - FK -> RELEASE_T (twice: RELEASE_ID and CLASH_WITH_ID)
5. CHANGE_LOG     - no FK dependencies (audit log, standalone)
```

---

## Tables

### `Z73460.EXT_EVENT_T` - External events

External calendar events (sports finals, holidays, etc.) that influence clash risk
scoring. CLSHBAT reads this table; EVTMGR maintains it.

| Column        | Type         | Null | Notes                                          |
|---------------|--------------|------|------------------------------------------------|
| EVENT_ID      | CHAR(10)     | N    | PK. Short ID, e.g. `EVT1`. Generated via SEQ_EVENT in EVTMGR. |
| EVENT_NAME    | VARCHAR(100) | N    | Human-readable name, e.g. `FIFA WORLD CUP FINAL` |
| EVENT_DATE    | DATE         | N    | Start date of the event                         |
| EVENT_END     | DATE         | Y    | End date. NULL means single-day event. CHECK: EVENT_END >= EVENT_DATE |
| IMPACT_GENRE  | CHAR(20)     | N    | Genre most affected. `GLOBAL` means all genres. |
| IMPACT_MARKET | CHAR(20)     | N    | Market most affected. `GLOBAL` means all markets. |
| SEVERITY      | CHAR(10)     | N    | `LOW`, `MEDIUM`, or `HIGH`                      |

**CHECK constraints:** SEVERITY in (LOW, MEDIUM, HIGH), IMPACT_GENRE in (DRAMA, COMEDY,
SPORT, DOCUMENTARY, THRILLER, OTHER, GLOBAL), IMPACT_MARKET in (US, EU, APAC, LATAM,
GLOBAL), EVENT_END >= EVENT_DATE when not null

**Indexes:** `IX_EVT_DATE` on (EVENT_DATE, EVENT_END), used by CLSHBAT proximity query.
`IX_EVT_MARKET_GENRE` on (IMPACT_MARKET, IMPACT_GENRE), used by CLSHBAT eligibility filter

---

### `Z73460.RELEASE_T` - Release calendar

Master table. Every title release lives here. All other tables reference it.

| Column        | Type         | Null | Notes                                          |
|---------------|--------------|------|------------------------------------------------|
| RELEASE_ID    | CHAR(10)     | N    | PK. Short ID, e.g. `REL1`. Generated via SEQ_RELEASE in RELSMGR. |
| TITLE         | VARCHAR(100) | N    | Title name                                     |
| GENRE         | CHAR(20)     | N    | One of the allowed genre values                |
| PLATFORM      | CHAR(20)     | N    | STREAMING, LINEAR, or THEATRICAL               |
| RELEASE_DATE  | DATE         | N    | Scheduled release date                          |
| WINDOW_END    | DATE         | N    | End of promo/release window. CHECK: >= RELEASE_DATE |
| TARGET_MARKET | CHAR(20)     | N    | Target audience market                          |
| STATUS        | CHAR(10)     | N    | Default DRAFT. CLSHBAT only scores CONFIRMED releases. |
| ADDED_TS      | TIMESTAMP    | N    | Set to CURRENT TIMESTAMP on INSERT             |
| UPDATED_TS    | TIMESTAMP    | N    | Set to CURRENT TIMESTAMP on INSERT and UPDATE  |

**CHECK constraints:** STATUS in (DRAFT, CONFIRMED, RELEASED, CANCELLED), GENRE in
(DRAMA, COMEDY, SPORT, DOCUMENTARY, THRILLER, OTHER), PLATFORM in (STREAMING, LINEAR,
THEATRICAL), TARGET_MARKET in (US, EU, APAC, LATAM, GLOBAL), WINDOW_END >= RELEASE_DATE

**Indexes:** `IX_REL_DATE` on (RELEASE_DATE, WINDOW_END). `IX_REL_STATUS` on (STATUS),
used by CLSHBAT outer/inner cursor. `IX_REL_MARKET_GENRE` on (TARGET_MARKET, GENRE)

---

### `Z73460.PROMO_T` - Promo checklist items

One release has zero or many promo items. Written and maintained by PROMGR.

| Column     | Type        | Null | Notes                                             |
|------------|-------------|------|---------------------------------------------------|
| PROMO_ID   | CHAR(10)    | N    | PK. Short ID, e.g. `PRO1`. Generated via SEQ_PROMO. |
| RELEASE_ID | CHAR(10)    | N    | FK -> RELEASE_T. DELETE on RELEASE_T fails with -532 if promo items exist. |
| ITEM_NAME  | VARCHAR(80) | N    | e.g. `TRAILER UPLOADED`, `PRESS KIT SENT`         |
| STATUS     | CHAR(10)    | N    | Default PENDING                                   |
| DUE_DATE   | DATE        | Y    | Target completion date. Optional.                 |
| OWNER      | VARCHAR(50) | Y    | Team or person responsible. Optional.             |
| UPDATED_TS | TIMESTAMP   | N    | Set to CURRENT TIMESTAMP on INSERT and UPDATE     |

**CHECK constraints:** STATUS in (PENDING, IN-PROG, DONE)

**Indexes:** `IX_PRO_RELEASE` on (RELEASE_ID, STATUS), used by PROMGR LST cursor

---

### `Z73460.CLASH_SCORE_T` - Pairwise clash risk scores

Written exclusively by CLSHBAT batch job. CLASHRDR CICS program reads it (never writes).
The table is fully cleared and rebuilt on every CLSHBAT run.

| Column        | Type         | Null | Notes                                          |
|---------------|--------------|------|------------------------------------------------|
| SCORE_ID      | CHAR(10)     | N    | PK. Short ID, e.g. `SCR1`. Generated via SEQ_SCORE. |
| RELEASE_ID    | CHAR(10)     | N    | FK -> RELEASE_T. Always the lower-ID release in the pair. |
| CLASH_WITH_ID | CHAR(10)     | N    | FK -> RELEASE_T. Always the higher-ID release in the pair. |
| RISK_SCORE    | DECIMAL(5,2) | N    | 0.00-100.00. CHECK enforced.                   |
| SCORE_FACTORS | VARCHAR(200) | Y    | Human-readable breakdown, e.g. `OVERLAP=24d,MARKET=MATCH,GENRE=NO,EVTPROX=4d-MED` |
| SCORED_TS     | TIMESTAMP    | N    | When CLSHBAT wrote this row                    |

**CHECK constraints:** RISK_SCORE between 0.00 and 100.00, RELEASE_ID <> CLASH_WITH_ID
(no self-scoring)

**Important:** CLSHBAT uses inner cursor `WHERE RELEASE_ID > :HV-A-ID`, so each pair is
scored exactly once with the lower-ID release always in RELEASE_ID. To find all scores
involving a given release, query both columns: `WHERE RELEASE_ID = ? OR CLASH_WITH_ID = ?`.
CLASHRDR currently only queries RELEASE_ID, the Flask UI handles both sides via JavaScript.

**Indexes:** `IX_SCR_RELEASE` on (RELEASE_ID, RISK_SCORE DESC), used by CLASHRDR cursor.
`IX_SCR_SCORED_TS` on (SCORED_TS)

---

### `Z73460.CHANGE_LOG` - Audit log

Written by RELSMGR, PROMGR, and EVTMGR on every ADD, UPD, and DEL. Best-effort, the
WRITE-CHANGE-LOG paragraph does not check SQLCODE so a log failure never blocks the main
operation.

| Column      | Type         | Null | Notes                                           |
|-------------|--------------|------|--------------------------------------------------|
| LOG_ID      | INTEGER      | N    | PK. Populated by COBOL using SEQ_LOG sequence before INSERT. |
| ENTITY_TYPE | CHAR(10)     | N    | `RELEASE`, `PROMO`, or `EVENT`                  |
| ENTITY_ID   | CHAR(10)     | N    | ID of the affected row                          |
| ACTION      | CHAR(6)      | N    | `ADD`, `UPD`, or `DEL`                          |
| DETAILS     | VARCHAR(200) | Y    | Short description of what changed               |
| CHANGED_BY  | CHAR(10)     | N    | Default `Z73460` (TSO user). No auth in MVP.    |
| CHANGED_TS  | TIMESTAMP    | N    | Default CURRENT TIMESTAMP                       |

**CHECK constraints:** ENTITY_TYPE in (RELEASE, PROMO, EVENT), ACTION in (ADD, UPD, DEL)

**Indexes:** `IX_LOG_ENTITY` on (ENTITY_TYPE, ENTITY_ID). `IX_LOG_TS` on (CHANGED_TS DESC)

---

## Sequences

All PKs are generated by COBOL programs fetching the next sequence value via
`SELECT NEXT VALUE FOR Z73460.SEQ_* INTO :HV-NEXT-SEQ FROM SYSIBM.SYSDUMMY1`,
then prepending the entity prefix.

| Sequence           | Used by   | ID prefix      | Example ID         | Cache      |
|--------------------|-----------|----------------|--------------------|------------|
| Z73460.SEQ_RELEASE | RELSMGR   | `REL`          | `REL1`, `REL42`    | **NO CACHE** |
| Z73460.SEQ_PROMO   | PROMGR    | `PRO`          | `PRO1`, `PRO7`     | CACHE 20   |
| Z73460.SEQ_SCORE   | CLSHBAT   | `SCR`          | `SCR1`, `SCR6`     | CACHE 20   |
| Z73460.SEQ_EVENT   | EVTMGR    | `EVT`          | `EVT1`, `EVT3`     | CACHE 20   |
| Z73460.SEQ_LOG     | All CRUD  | (none)         | Integer            | CACHE 20   |

`SEQ_RELEASE` uses `NO CACHE`. Cached sequence values caused stale/duplicate IDs across
different DB2 threads under CICS on this system, a real bug that was hit in production
use. The other four sequences use `CACHE 20` without issue.

All sequences otherwise: `START WITH 1 INCREMENT BY 1 NO MAXVALUE NO CYCLE`.

If a sequence drifts out of sync with the real max ID in the table (e.g. after
restoring seed data), fix with: `ALTER SEQUENCE Z73460.SEQ_RELEASE RESTART WITH N`
where N is one above the current max.

IDs are short (no zero-padding). DB2 `CHAR(10)` columns pad with trailing spaces, and
DB2 character comparison ignores trailing blanks, so `'REL1' = 'REL1      '` is true.
FK joins and cursor lookups all work correctly.

---

## FK Dependency Diagram

```
EXT_EVENT_T          RELEASE_T
    (no FK)              (no FK)
                          |    |
               +----------+    +----------+
               v                          v
           PROMO_T                CLASH_SCORE_T
      (FK: RELEASE_ID)    (FK: RELEASE_ID + CLASH_WITH_ID)
```

`CHANGE_LOG` has no FK relationships, it stores entity IDs as plain CHAR values.

---

## Running the DDL

```
1. backend/ddl/CREATTAB.sql   - creates all 5 tables, sequences, indexes
2. backend/ddl/SEEDDATA.sql   - inserts test data (4 events, 5 releases, 5 promo items)
3. Submit CLSHJCL.jcl         - runs CLSHBAT to populate CLASH_SCORE_T
4. backend/ddl/VERIFSCR.sql   - 6 verification queries to confirm everything looks right
```

All of this is run interactively via SPUFI, one statement or file at a time.
