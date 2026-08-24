# Clash Risk Scoring Formula
## Release & Promo Orchestrator, CLSHBAT Algorithm Reference

These are the locked, authoritative values. The COBOL program CLSHBAT is the
implementation. This document describes exactly what it does.

---

## Overview

CLSHBAT calculates a risk score between 0 and 100 for every unique pair of
CONFIRMED releases. A higher score means the two titles are more likely to
compete for the same audience at the same time.

Scores are stored in `Z73460.CLASH_SCORE_T` and displayed in the Flask dashboard.
The table is fully cleared and rebuilt every time CLSHBAT runs, scores always
reflect the current state of RELEASE_T and EXT_EVENT_T at the time of the last run.

---

## Four Scoring Components

| Component       | Max points | Trigger                                              |
|-----------------|------------|------------------------------------------------------|
| Window overlap  | 40         | How many days the two release windows overlap        |
| Same market     | 25         | Both releases target the same market (or either is GLOBAL) |
| Same genre      | 20         | Both releases have the same genre                    |
| Event proximity | 15         | A release window is within 30 days of a relevant external event |

**Total: 0-100**

---

## Component 1, Window Overlap (max 40 pts)

Computed in SQL using the `DAYS()` scalar function to avoid COBOL date arithmetic.

The overlap calculation finds MIN(WINDOW_END_A, WINDOW_END_B) minus
MAX(RELEASE_DATE_A, RELEASE_DATE_B) plus 1. The COBOL CASE expression implements this
by picking which WINDOW_END is earlier and pairing it with the other release's
RELEASE_DATE:

```sql
CASE
  WHEN (DAYS(DATE(A.WINDOW_END)) - DAYS(DATE(B.WINDOW_END))) < 0
  THEN INTEGER(DAYS(DATE(A.WINDOW_END)) - DAYS(DATE(B.RELEASE_DATE)) + 1)
  ELSE INTEGER(DAYS(DATE(B.WINDOW_END)) - DAYS(DATE(A.RELEASE_DATE)) + 1)
END
```

If the result is negative (windows do not overlap at all), it is clamped to 0.

The overlap day count is then mapped to points using a step scale:

| Overlap days | Points |
|---|---|
| 0 | 0 |
| 1-7 | 10 |
| 8-14 | 20 |
| 15-21 | 30 |
| 22+ | 40 |

---

## Component 2, Same Market (max 25 pts)

Full 25 points if both releases share the same TARGET_MARKET, **or** if either
release has TARGET_MARKET = `GLOBAL`. A GLOBAL release competes in every market.

```cobol
IF  HV-A-MARKET = HV-B-MARKET
OR  HV-A-MARKET = 'GLOBAL'
OR  HV-B-MARKET = 'GLOBAL'
    MOVE 25 TO WS-MARKET-PTS
```

All-or-nothing: 0 or 25, no partial credit.

---

## Component 3, Same Genre (max 20 pts)

Full 20 points if both releases have the same GENRE. Exact match only.

```cobol
IF HV-A-GENRE = HV-B-GENRE
    MOVE 20 TO WS-GENRE-PTS
```

All-or-nothing: 0 or 20, no partial credit.

---

## Component 4, Event Proximity (max 15 pts, with severity multiplier)

Finds the single closest eligible external event to the release pair in one SQL query
against `Z73460.EXT_EVENT_T`.

**Eligibility:** An event is eligible if its IMPACT_MARKET or IMPACT_GENRE matches
either release, or is `GLOBAL`.

**Proximity:** For each eligible event, the CASE expression returns:
- `0` if any of the four date points (A release date, A window end, B release date,
  B window end) falls within the event's own date range
- Otherwise the smallest gap in days between any of those four points and the event's
  start or end date (via `LEAST(ABS(...), ABS(...), ABS(...), ABS(...))`)

`MIN()` across all eligible events then picks the overall closest one, and `SEVERITY`
comes along via `GROUP BY SEVERITY ORDER BY 1 ASC FETCH FIRST 1 ROW ONLY`.

**Raw points from proximity:**

| Closest eligible event | Raw event points |
|---|---|
| 0-14 days away (or overlapping) | 15.00 |
| 15-30 days away | 8.00 |
| More than 30 days away | 0 |

**Severity multiplier applied to raw points:**

| Severity | Multiplier | Example: 15 raw pts | Example: 8 raw pts |
|---|---|---|---|
| HIGH | 1.00 | 15.00 | 8.00 |
| MEDIUM | 0.75 | 11.25 | 6.00 |
| LOW | 0.50 | 7.50 | 4.00 |

If no eligible event exists, event proximity contributes 0 points.

---

## SCORE_FACTORS String Format

The human-readable breakdown stored in `CLASH_SCORE_T.SCORE_FACTORS` and shown
in the dashboard's Clash Risk table.

**With an event found:**
```
OVERLAP=24d,MARKET=MATCH,GENRE=NO,EVTPROX=4d-MED
```

**Without a matching event:**
```
OVERLAP=7d,MARKET=NO,GENRE=MATCH,EVTPROX=NONE
```

Fields: overlap days, MARKET (MATCH or NO), GENRE (MATCH or NO), EVTPROX
(days-SEVERITY abbreviation, or NONE). Severity abbreviations: HIGH, MED, LOW.

---

## Worked Example

This example reflects an actual scored pair pulled from the live database
(`CLASH_SCORE_T`, SCORE_ID `SCR9`), not seed data.

**Release A:** REL1, DRAMA, EU, Sep 05 to Nov 05 2025 (CONFIRMED at the time this
pair was scored)
**Release B:** REL4, COMEDY CLUB S2, COMEDY, STREAMING, EU, Sep 20 to Oct 20 2025

**Component 1, Window overlap:**
- B's WINDOW_END (Oct 20) is earlier than A's WINDOW_END (Nov 05)
- Overlap = DAYS(Oct 20) - DAYS(Sep 05) + 1 = 45 + 1 = 46 days
- 46 days, step scale, **40 pts**

**Component 2, Same market:**
- Both EU, **25 pts**

**Component 3, Same genre:**
- DRAMA vs COMEDY, no match, **0 pts**

**Component 4, Event proximity:**
- EVT4 (US LABOR DAY, Aug 30 to Sep 01, MEDIUM) is eligible. Its IMPACT_GENRE is
  `GLOBAL`, which matches the eligibility check's GLOBAL fallback regardless of
  either release's own genre
- A's RELEASE_DATE (Sep 05) is 4 days after the event's end (Sep 01)
- 4 days is at or under 14, raw pts = 15.00, MEDIUM multiplier 0.75, **11.25 pts**

**Total: 40 + 25 + 0 + 11.25 = 76.25**

SCORE_FACTORS: `OVERLAP=46d,MARKET=MATCH,GENRE=NO,EVTPROX=4d-MED`

Note: because release data changes over time as titles get edited through the
site, the exact pair and numbers that come out of any given CLSHBAT run will
shift too. The arithmetic and rules above are what stay fixed, not any one
specific score.

---

## Pair Selection

CLSHBAT uses a two-cursor approach to score each pair exactly once:

- Outer cursor: all CONFIRMED releases, ordered by RELEASE_ID ASC
- Inner cursor: all CONFIRMED releases WHERE RELEASE_ID > outer RELEASE_ID

This means for 4 CONFIRMED releases there are 4x3/2 = 6 pairs scored,
and the lower-ID release is always stored in `CLASH_SCORE_T.RELEASE_ID`.

The CLSHBAT inner loop saves and restores SQLCODE around the inner cursor
so the outer loop's `PERFORM UNTIL SQLCODE NOT = 0` termination condition is
not contaminated by the inner cursor exhausting its rows (SQLCODE +100).

---

## Rerunning Scores

Submit `CLSHJCL.jcl` from ISPF or USS:

```
submit 'Z73460.ORCH.JCL(CLSHJCL)'
```

CLSHBAT deletes all rows from CLASH_SCORE_T before scoring, so the table always
reflects the current set of CONFIRMED releases and current external events.
Run it after any of: adding a new CONFIRMED release, confirming a DRAFT release,
adding or changing external events.
