------------------------------------------------------------------
-- RELEASE & PROMO ORCHESTRATOR -- PHASE 3 VERIFICATION QUERIES
-- Run via SPUFI after CLSHJCL completes successfully.
-- Schema qualifier: Z73460
--
-- QUERY 1  - Count of rows written
-- QUERY 2  - Full score listing, highest risk first
-- QUERY 3  - Verify the expected high-score pair REL1/REL2
-- QUERY 4  - Verify REL5 (DRAFT) was NOT scored
-- QUERY 5  - Score breakdown joined to release titles
-- QUERY 6  - CLASHRDR simulation for REL1
------------------------------------------------------------------

------------------------------------------------------------------
-- QUERY 1: How many pairs were scored?
-- Expected: 6 pairs from 4 CONFIRMED releases (n*(n-1)/2 = 6)
-- (REL5 is DRAFT so is excluded)
------------------------------------------------------------------
SELECT COUNT(*) AS PAIRS_SCORED
FROM   Z73460.CLASH_SCORE_T;

------------------------------------------------------------------
-- QUERY 2: All scores, highest risk first
-- Expected: 6 rows, scores between 0 and 100
------------------------------------------------------------------
SELECT SCORE_ID,
       RELEASE_ID,
       CLASH_WITH_ID,
       RISK_SCORE,
       SCORE_FACTORS,
       CHAR(SCORED_TS) AS SCORED_TS
FROM   Z73460.CLASH_SCORE_T
ORDER BY RISK_SCORE DESC;

------------------------------------------------------------------
-- QUERY 3: Verify the known high-score pair
-- REL1 (US DRAMA Sep05-Oct05) vs REL2 (US THRILLER Sep12-Oct12)
-- Expected score: 76.25
-- Overlap=24d(40pts) + Market=US/US(25pts) + Genre=DRAMA/THRILLER(0pts)
--   + Event proximity, MEDIUM severity (15*0.75=11.25pts)
--   = 76.25
------------------------------------------------------------------
SELECT RISK_SCORE,
       SCORE_FACTORS
FROM   Z73460.CLASH_SCORE_T
WHERE  (RELEASE_ID    = 'REL1' AND CLASH_WITH_ID = 'REL2')
OR     (RELEASE_ID    = 'REL2' AND CLASH_WITH_ID = 'REL1');

------------------------------------------------------------------
-- QUERY 4: Confirm DRAFT release REL5 was NOT scored
-- Expected: 0 rows
------------------------------------------------------------------
SELECT COUNT(*) AS DRAFT_ROWS_FOUND
FROM   Z73460.CLASH_SCORE_T
WHERE  RELEASE_ID    = 'REL5'
OR     CLASH_WITH_ID = 'REL5';

------------------------------------------------------------------
-- QUERY 5: Human-readable score report (join to release titles)
-- Shows both release titles alongside their risk score
------------------------------------------------------------------
SELECT A.TITLE      AS RELEASE_A,
       B.TITLE      AS RELEASE_B,
       S.RISK_SCORE,
       S.SCORE_FACTORS
FROM   Z73460.CLASH_SCORE_T  S
JOIN   Z73460.RELEASE_T      A ON A.RELEASE_ID = S.RELEASE_ID
JOIN   Z73460.RELEASE_T      B ON B.RELEASE_ID = S.CLASH_WITH_ID
ORDER BY S.RISK_SCORE DESC;

------------------------------------------------------------------
-- QUERY 6: Simulate what CLASHRDR returns for REL1
-- This is the exact query CLASHRDR uses (from CLASHRDR.CBL)
-- Expected: all rows where RELEASE_ID = REL1
------------------------------------------------------------------
SELECT SCORE_ID,
       RELEASE_ID,
       CLASH_WITH_ID,
       RISK_SCORE,
       SCORE_FACTORS,
       CHAR(SCORED_TS) AS SCORED_TS
FROM   Z73460.CLASH_SCORE_T
WHERE  RELEASE_ID = 'REL1'
ORDER BY RISK_SCORE DESC;
------------------------------------------------------------------
-- END OF VERIFICATION QUERIES
------------------------------------------------------------------
