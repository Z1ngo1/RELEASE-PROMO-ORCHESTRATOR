      *----------------------------------------------------------------*
      *    CLSHBAT.CBL                                                 *
      * BATCH COBOL PROGRAM - CLASH RISK SCORING                       *
      *                                                                *
      * READS ALL CONFIRMED RELEASES FROM Z73460.RELEASE_T. FOR EVERY  *
      * UNIQUE PAIR (A, B) WHERE A.RELEASE_ID < B.RELEASE_ID, SCORES   *
      * THE PAIR 0-100 USING THE LOCKED FORMULA:                       *
      *   COMPONENT 1 - WINDOW OVERLAP     (MAX 40 PTS)                *
      *   COMPONENT 2 - SAME TARGET MARKET (MAX 25 PTS)                *
      *   COMPONENT 3 - SAME GENRE         (MAX 20 PTS)                *
      *   COMPONENT 4 - EVENT PROXIMITY    (MAX 15 PTS)                *
      * WRITES ONE ROW PER PAIR TO Z73460.CLASH_SCORE_T. DELETES ALL   *
      * EXISTING ROWS FIRST (FULL REFRESH, NOT INCREMENTAL) - EVERY    *
      * RUN REPLACES THE WHOLE TABLE FROM SCRATCH.                     *
      *                                                                *
      * NO CICS - PURE BATCH, RUN ON DEMAND VIA CLSHJCL.JCL. THAT SAME *
      * JCL ALSO COMPILES THIS PROGRAM USING IGYWCL (NOT DFHZITCL -    *
      * THIS IS NOT A CICS PROGRAM, SO NO CICS TRANSLATE STEP IS       *
      * NEEDED OR WANTED).                                             *
      *----------------------------------------------------------------*
       IDENTIFICATION DIVISION.
       PROGRAM-ID. CLSHBAT.
       ENVIRONMENT DIVISION.
       DATA DIVISION.
       WORKING-STORAGE SECTION.

           EXEC SQL
             INCLUDE SQLCA
           END-EXEC.

      *----------------------------------------------------------------*
      * RELEASE TABLE (OUTER LOOP)                                     *
      * TWO-CURSOR APPROACH FOR THE PAIRWISE SCAN: OUTER CURSOR        *
      * (REL-A-CURSOR) READS EVERY CONFIRMED RELEASE ONCE, AND FOR     *
      * EACH ONE THE INNER CURSOR (REL-B-CURSOR, DECLARED IN           *
      * SCORE-INNER-LOOP) RE-SCANS CONFIRMED RELEASES WITH             *
      * RELEASE_ID > :HV-A-ID. THAT INEQUALITY IS WHAT GUARANTEES      *
      * EACH PAIR IS SCORED EXACTLY ONCE (NEVER BOTH A/B AND B/A, AND  *
      * NEVER A RELEASE PAIRED WITH ITSELF) WITHOUT NEEDING A SELF-    *
      * JOIN, WHICH DB2 BATCH COBOL DOESN'T HANDLE AS CLEANLY AS A     *
      * NESTED CURSOR SCAN.                                            *
      *----------------------------------------------------------------*

      *----------------------------------------------------------------*
      * HOST VARIABLES - RELEASE A (OUTER)                             *
      *----------------------------------------------------------------*
       01 HV-A-ID              PIC X(10).
       01 HV-A-GENRE           PIC X(20).
       01 HV-A-MARKET          PIC X(20).
       01 HV-A-REL-DATE        PIC X(10).
       01 HV-A-WIN-END         PIC X(10).

      *----------------------------------------------------------------*
      * HOST VARIABLES - RELEASE B (INNER)                             *
      *----------------------------------------------------------------*
       01 HV-B-ID              PIC X(10).
       01 HV-B-GENRE           PIC X(20).
       01 HV-B-MARKET          PIC X(20).
       01 HV-B-REL-DATE        PIC X(10).
       01 HV-B-WIN-END         PIC X(10).

      *----------------------------------------------------------------*
      * HOST VARIABLES - EVENT PROXIMITY                               *
      *----------------------------------------------------------------*
       01 HV-EVT-PROX-DAYS     PIC S9(5) COMP.
       01 HV-EVT-SEVERITY      PIC X(10).
       01 HV-EVT-FOUND         PIC X(1).

      *----------------------------------------------------------------*
      * HOST VARIABLES - CLASH_SCORE_T INSERT                          *
      *----------------------------------------------------------------*
       01 HV-SCORE-ID          PIC X(10).
       01 HV-RISK-SCORE        PIC S9(3)V99 COMP-3.
       01 HV-SCORE-FACTORS     PIC X(200).
       01 HV-NEXT-SEQ          PIC S9(18) COMP.
       01 WS-SEQ-CHAR          PIC Z(6)9.

      *----------------------------------------------------------------*
      * SCORING WORK FIELDS                                            *
      *----------------------------------------------------------------*
       01 WS-OVERLAP-DAYS      PIC S9(5) COMP.
       01 WS-OVERLAP-PTS       PIC S9(3)V99 COMP-3.
       01 WS-MARKET-PTS        PIC S9(3)V99 COMP-3.
       01 WS-GENRE-PTS         PIC S9(3)V99 COMP-3.
       01 WS-EVENT-PTS         PIC S9(3)V99 COMP-3.
       01 WS-TOTAL-SCORE       PIC S9(3)V99 COMP-3.
       01 WS-SEV-MULTIPLIER    PIC S9(1)V99 COMP-3.

      *----------------------------------------------------------------*
      * DATE ARITHMETIC HELPERS                                        *
      * ALL DATE MATH IS DONE IN SQL (VIA DAYS() ON A DATE() CAST OF   *
      * THE X(10) HOST VARIABLE), NOT IN COBOL - DB2'S DATE FUNCTIONS  *
      * HANDLE CALENDAR EDGE CASES (MONTH LENGTHS, LEAP YEARS) THAT    *
      * WOULD OTHERWISE NEED TO BE REIMPLEMENTED BY HAND.              *
      *----------------------------------------------------------------*
       01 HV-OVERLAP-DAYS      PIC S9(9) COMP.
       01 HV-MIN-PROX-A        PIC S9(9) COMP.
       01 HV-MIN-PROX-B        PIC S9(9) COMP.
       01 HV-BEST-PROX         PIC S9(9) COMP.

      *----------------------------------------------------------------*
      * SCORE_FACTORS STRING BUILDING HELPERS                          *
      *----------------------------------------------------------------*
       01 WS-OV-DISP           PIC Z(4)9.
       01 WS-PROX-DISP         PIC Z(4)9.
       01 WS-MARKET-FLAG       PIC X(5).
       01 WS-GENRE-FLAG        PIC X(5).
       01 WS-SEV-SHORT         PIC X(4).

      *----------------------------------------------------------------*
      * COUNTERS AND CONTROL                                           *
      *----------------------------------------------------------------*
       01 WS-PAIRS-SCORED      PIC S9(7) COMP VALUE 0.
       01 WS-PAIRS-DISP        PIC ZZZ,ZZ9.
       01 WS-SQLCODE-SAVE      PIC S9(9) COMP.
       01 WS-RETURN-CODE       PIC S9(4) COMP VALUE 0.
       01 WS-STATUS-FILTER     PIC X(12).

       PROCEDURE DIVISION.

      *----------------------------------------------------------------*
      * MAINLINE                                                       *
      * PURGE, THEN SCORE, THEN REPORT A COUNT AND STOP. WS-RETURN-    *
      * CODE ACTS AS THE SIGNAL FROM PURGE-OLD-SCORES: IF THE DELETE   *
      * FAILS THERE IS NO POINT SCORING ANYTHING, SINCE THE INSERT     *
      * LOOP WOULD JUST BE ADDING TO A TABLE THAT WASN'T PROPERLY      *
      * CLEARED.                                                       *
      *----------------------------------------------------------------*
       MAIN-LOGIC.
           DISPLAY 'CLSHBAT - START'.

           PERFORM PURGE-OLD-SCORES.
           IF WS-RETURN-CODE NOT = 0
              STOP RUN
           END-IF.

           PERFORM SCORE-ALL-PAIRS.

           MOVE WS-PAIRS-SCORED TO WS-PAIRS-DISP.
           DISPLAY 'CLSHBAT - COMPLETE. PAIRS SCORED: ' WS-PAIRS-DISP.

           STOP RUN.

      *----------------------------------------------------------------*
      * PURGE-OLD-SCORES - DELETES ALL ROWS FROM CLASH_SCORE_T BEFORE  *
      * REBUILDING. SQLCODE 100 (NO ROWS TO DELETE) IS TREATED AS OK,  *
      * SAME AS 0 - AN EMPTY TABLE ON A FIRST RUN IS NOT AN ERROR.     *
      *----------------------------------------------------------------*
       PURGE-OLD-SCORES.
           EXEC SQL
             DELETE FROM Z73460.CLASH_SCORE_T
           END-EXEC.

           IF SQLCODE = 0 OR SQLCODE = 100
              DISPLAY 'CLSHBAT - PURGE OK, SQLCODE=' SQLCODE
           ELSE
              DISPLAY 'CLSHBAT - PURGE FAILED, SQLCODE=' SQLCODE
              MOVE 8 TO WS-RETURN-CODE
           END-IF.

      *----------------------------------------------------------------*
      * SCORE-ALL-PAIRS                                                *
      * OPENS THE OUTER CURSOR AND, FOR EVERY FETCHED RELEASE,         *
      * PERFORMS SCORE-INNER-LOOP TO PAIR IT AGAINST EVERY RELEASE     *
      * WITH A HIGHER ID. THE INNER LOOP DECLARES AND CLOSES ITS OWN   *
      * CURSOR ON EACH CALL - SEE THE SQLCODE SAVE/RESTORE NOTE THERE  *
      * FOR WHY THAT'S SAFE TO DO INSIDE THIS OUTER PERFORM UNTIL.     *
      *----------------------------------------------------------------*
       SCORE-ALL-PAIRS.
           MOVE 'CONFIRMED' TO WS-STATUS-FILTER.

           EXEC SQL DECLARE REL-A-CURSOR CURSOR FOR
             SELECT RELEASE_ID, GENRE, TARGET_MARKET,
                    CHAR(RELEASE_DATE,ISO), CHAR(WINDOW_END,ISO)
             FROM   Z73460.RELEASE_T
             WHERE  STATUS = :WS-STATUS-FILTER
             ORDER BY RELEASE_ID ASC
           END-EXEC.

           EXEC SQL
             OPEN REL-A-CURSOR
           END-EXEC.
           IF SQLCODE NOT = 0
              DISPLAY 'CLSHBAT - OPEN REL-A-CURSOR FAILED ' SQLCODE
              MOVE 8 TO WS-RETURN-CODE
              GO TO SCORE-ALL-PAIRS-EXIT
           END-IF.

           PERFORM UNTIL SQLCODE NOT = 0
               EXEC SQL FETCH REL-A-CURSOR
                 INTO :HV-A-ID, :HV-A-GENRE, :HV-A-MARKET,
                      :HV-A-REL-DATE, :HV-A-WIN-END
               END-EXEC

               IF SQLCODE = 0
                  PERFORM SCORE-INNER-LOOP
               END-IF
           END-PERFORM.

           EXEC SQL
             CLOSE REL-A-CURSOR
           END-EXEC.

       SCORE-ALL-PAIRS-EXIT.
           EXIT.

      *----------------------------------------------------------------*
      * SCORE-INNER-LOOP                                               *
      * FOR THE CURRENT A RELEASE, SCANS EVERY B RELEASE WITH A HIGHER *
      * ID. THE SQLCODE SAVE/RESTORE AROUND THIS INNER CURSOR IS       *
      * DELIBERATE AND IMPORTANT: THE OUTER PERFORM UNTIL SQLCODE NOT  *
      * = 0 IN SCORE-ALL-PAIRS IS WATCHING THE SAME SQLCODE VARIABLE.  *
      * WITHOUT SAVING AND RESTORING IT HERE, THE INNER CURSOR         *
      * EXHAUSTING ITS ROWS (SQLCODE +100) WOULD LEAK OUT AND MAKE THE *
      * OUTER LOOP THINK IT WAS DONE TOO, STOPPING AFTER JUST THE      *
      * FIRST A RELEASE INSTEAD OF SCANNING ALL OF THEM.               *
      *----------------------------------------------------------------*
       SCORE-INNER-LOOP.
           MOVE 'CONFIRMED' TO WS-STATUS-FILTER.

           EXEC SQL DECLARE REL-B-CURSOR CURSOR FOR
             SELECT RELEASE_ID, GENRE, TARGET_MARKET,
                    CHAR(RELEASE_DATE,ISO), CHAR(WINDOW_END,ISO)
             FROM   Z73460.RELEASE_T
             WHERE  STATUS = :WS-STATUS-FILTER
             AND    RELEASE_ID > :HV-A-ID
             ORDER BY RELEASE_ID ASC
           END-EXEC.

           EXEC SQL
             OPEN REL-B-CURSOR
           END-EXEC.
           IF SQLCODE NOT = 0
              DISPLAY 'CLSHBAT - OPEN REL-B-CURSOR FAILED ' SQLCODE
              GO TO SCORE-INNER-EXIT
           END-IF.

           MOVE SQLCODE TO WS-SQLCODE-SAVE.

           PERFORM UNTIL SQLCODE NOT = 0
               EXEC SQL FETCH REL-B-CURSOR
                 INTO :HV-B-ID, :HV-B-GENRE, :HV-B-MARKET,
                      :HV-B-REL-DATE, :HV-B-WIN-END
               END-EXEC

               IF SQLCODE = 0
                  PERFORM CALC-SCORE
                  PERFORM WRITE-SCORE
                  ADD 1 TO WS-PAIRS-SCORED
               END-IF
           END-PERFORM.

           EXEC SQL
             CLOSE REL-B-CURSOR
           END-EXEC.
           MOVE WS-SQLCODE-SAVE TO SQLCODE.

       SCORE-INNER-EXIT.
           EXIT.

      *----------------------------------------------------------------*
      * CALC-SCORE                                                     *
      * CALCULATES ALL FOUR SCORING COMPONENTS FOR THE CURRENT A/B     *
      * PAIR AND SUMS THEM INTO WS-TOTAL-SCORE. COMPONENTS 2 AND 3     *
      * (MARKET/GENRE) ARE SIMPLE COBOL COMPARISONS, COMPONENT 1       *
      * (OVERLAP) NEEDS ONE SQL CALL FOR THE DATE MATH, AND COMPONENT  *
      * 4 (EVENT PROXIMITY) IS DELEGATED TO ITS OWN PARAGRAPH SINCE    *
      * IT INVOLVES A SEPARATE QUERY AGAINST EXT_EVENT_T.              *
      *----------------------------------------------------------------*
       CALC-SCORE.
           MOVE 0 TO WS-OVERLAP-PTS
                     WS-MARKET-PTS
                     WS-GENRE-PTS
                     WS-EVENT-PTS.
      *-- COMPONENT 1: WINDOW OVERLAP ----------------------------------
      * OVERLAP DAYS = MIN(A.WINDOW_END, B.WINDOW_END) -               *
      * MAX(A.RELEASE_DATE, B.RELEASE_DATE) + 1, CLAMPED TO 0 IF       *
      * NEGATIVE (WINDOWS DON'T ACTUALLY OVERLAP). THE CASE PICKS      *
      * WHICHEVER WINDOW_END IS EARLIER TO DECIDE WHICH RELEASE_DATE   *
      * TO PAIR IT WITH - THIS IS THE STANDARD INTERVAL-OVERLAP        *
      * FORMULA, JUST WRITTEN AS SQL SO DB2 HANDLES THE DATE MATH.     *
           EXEC SQL
             SELECT
               CASE
                 WHEN (DAYS(DATE(:HV-A-WIN-END)) -
                       DAYS(DATE(:HV-B-WIN-END))) < 0
                 THEN INTEGER(DAYS(DATE(:HV-A-WIN-END)) -
                       DAYS(DATE(:HV-B-REL-DATE)) + 1)
                 ELSE INTEGER(DAYS(DATE(:HV-B-WIN-END)) -
                       DAYS(DATE(:HV-A-REL-DATE)) + 1)
               END
             INTO :HV-OVERLAP-DAYS
             FROM SYSIBM.SYSDUMMY1
           END-EXEC.

           IF HV-OVERLAP-DAYS < 0
              MOVE 0 TO HV-OVERLAP-DAYS
           END-IF.

           EVALUATE TRUE
               WHEN HV-OVERLAP-DAYS = 0
                 MOVE 0  TO WS-OVERLAP-PTS
               WHEN HV-OVERLAP-DAYS <= 7
                 MOVE 10 TO WS-OVERLAP-PTS
               WHEN HV-OVERLAP-DAYS <= 14
                 MOVE 20 TO WS-OVERLAP-PTS
               WHEN HV-OVERLAP-DAYS <= 21
                 MOVE 30 TO WS-OVERLAP-PTS
               WHEN OTHER
                 MOVE 40 TO WS-OVERLAP-PTS
           END-EVALUATE.

      *-- COMPONENT 2: SAME MARKET ------------------------------------
      * FULL 25 PTS IF BOTH RELEASES TARGET THE SAME MARKET, OR IF     *
      * EITHER ONE IS GLOBAL (A GLOBAL RELEASE OVERLAPS EVERY MARKET). *
           IF  HV-A-MARKET = HV-B-MARKET
           OR  HV-A-MARKET = 'GLOBAL             '
           OR  HV-B-MARKET = 'GLOBAL             '
               MOVE 25 TO WS-MARKET-PTS
           END-IF.

      *-- COMPONENT 3: SAME GENRE -------------------------------------
           IF HV-A-GENRE = HV-B-GENRE
               MOVE 20 TO WS-GENRE-PTS
           END-IF.

      *-- COMPONENT 4: EVENT PROXIMITY --------------------------------
           PERFORM CALC-EVENT-PROXIMITY.

      *-- TOTAL --------------------------------------------------------
           COMPUTE WS-TOTAL-SCORE =
               WS-OVERLAP-PTS + WS-MARKET-PTS +
               WS-GENRE-PTS   + WS-EVENT-PTS.

      *-- BUILD SCORE_FACTORS STRING -----------------------------------
           PERFORM BUILD-SCORE-FACTORS.

      *----------------------------------------------------------------*
      * CALC-EVENT-PROXIMITY                                           *
      * FINDS THE SINGLE CLOSEST ELIGIBLE EVENT TO THE A/B PAIR IN ONE *
      * QUERY. AN EVENT IS ELIGIBLE IF ITS IMPACT_MARKET OR            *
      * IMPACT_GENRE MATCHES EITHER RELEASE (OR IS GLOBAL). FOR EACH   *
      * ELIGIBLE EVENT, THE CASE EXPRESSION RETURNS 0 IF EITHER        *
      * RELEASE'S WINDOW ACTUALLY OVERLAPS THE EVENT'S OWN DATE RANGE, *
      * OTHERWISE THE SMALLEST GAP IN DAYS BETWEEN ANY OF THE FOUR     *
      * RELEASE/EVENT DATE COMBINATIONS. MIN() ACROSS ALL ELIGIBLE     *
      * EVENTS THEN PICKS THE CLOSEST ONE OVERALL, AND SEVERITY COMES  *
      * ALONG FOR THE RIDE VIA GROUP BY + ORDER BY + FETCH FIRST 1 ROW.*
      * NO MATCHING EVENT LEAVES HV-EVT-FOUND AT 'N' AND WS-EVENT-PTS  *
      * AT ITS ZEROED DEFAULT FROM CALC-SCORE.                         *
      *----------------------------------------------------------------*
       CALC-EVENT-PROXIMITY.
           MOVE 99999 TO HV-BEST-PROX.
           MOVE SPACES TO HV-EVT-SEVERITY.
           MOVE 'N'    TO HV-EVT-FOUND.
           MOVE 'GLOBAL' TO WS-STATUS-FILTER.
           EXEC SQL
             SELECT INTEGER(MIN(
               CASE
                 WHEN DATE(:HV-A-REL-DATE) BETWEEN
                           EVENT_DATE AND
                           COALESCE(EVENT_END, EVENT_DATE)
                      OR DATE(:HV-A-WIN-END) BETWEEN
                           EVENT_DATE AND
                           COALESCE(EVENT_END, EVENT_DATE)
                      OR DATE(:HV-B-REL-DATE) BETWEEN
                           EVENT_DATE AND
                           COALESCE(EVENT_END, EVENT_DATE)
                      OR DATE(:HV-B-WIN-END) BETWEEN
                           EVENT_DATE AND
                           COALESCE(EVENT_END, EVENT_DATE)
                 THEN 0
                 ELSE LEAST(
                        ABS(DAYS(DATE(:HV-A-REL-DATE)) -
                            DAYS(EVENT_DATE)),
                        ABS(DAYS(DATE(:HV-A-WIN-END))  -
                            DAYS(COALESCE(EVENT_END,EVENT_DATE))),
                        ABS(DAYS(DATE(:HV-B-REL-DATE)) -
                            DAYS(EVENT_DATE)),
                        ABS(DAYS(DATE(:HV-B-WIN-END))  -
                            DAYS(COALESCE(EVENT_END,EVENT_DATE)))
                      )
                 END
             )),
             SEVERITY
             INTO :HV-BEST-PROX, :HV-EVT-SEVERITY
             FROM Z73460.EXT_EVENT_T
             WHERE (IMPACT_MARKET = :HV-A-MARKET
               OR  IMPACT_MARKET = :HV-B-MARKET
               OR  IMPACT_MARKET = :WS-STATUS-FILTER
               OR  IMPACT_GENRE  = :HV-A-GENRE
               OR  IMPACT_GENRE  = :HV-B-GENRE
               OR  IMPACT_GENRE  = :WS-STATUS-FILTER)
             GROUP BY SEVERITY
             ORDER BY 1 ASC
             FETCH FIRST 1 ROW ONLY
           END-EXEC.

           IF SQLCODE = 0 AND HV-BEST-PROX < 99999
              MOVE 'Y' TO HV-EVT-FOUND

               EVALUATE TRUE
                   WHEN HV-BEST-PROX <= 14
                     MOVE 15.00 TO WS-EVENT-PTS
                   WHEN HV-BEST-PROX <= 30
                     MOVE 8.00  TO WS-EVENT-PTS
                   WHEN OTHER
                     MOVE 0     TO WS-EVENT-PTS
               END-EVALUATE

      * SEVERITY MULTIPLIER: HIGH=FULL WEIGHT, MEDIUM=0.75,
      * LOW=0.50 - LOCKED VALUES, MATCH SCORING-FORMULA.MD.
               EVALUATE FUNCTION TRIM(HV-EVT-SEVERITY)
                   WHEN 'HIGH'
                     MOVE 1.00 TO WS-SEV-MULTIPLIER
                   WHEN 'MEDIUM'
                     MOVE 0.75 TO WS-SEV-MULTIPLIER
                   WHEN 'LOW'
                     MOVE 0.50 TO WS-SEV-MULTIPLIER
                   WHEN OTHER
                     MOVE 1.00 TO WS-SEV-MULTIPLIER
               END-EVALUATE

               COMPUTE WS-EVENT-PTS ROUNDED =
                       WS-EVENT-PTS * WS-SEV-MULTIPLIER
           END-IF.

      *----------------------------------------------------------------*
      * BUILD-SCORE-FACTORS                                            *
      * BUILDS THE HUMAN-READABLE SCORE_FACTORS STRING SHOWN IN THE    *
      * UI, E.G. OVERLAP=24d,MARKET=MATCH,GENRE=NO,EVTPROX=4d-MED.     *
      * TWO BRANCHES (EVENT FOUND / NOT FOUND) SINCE THE PROXIMITY     *
      * PORTION ONLY MAKES SENSE WHEN AN EVENT WAS ACTUALLY MATCHED -  *
      * OTHERWISE IT JUST SAYS EVTPROX=NONE.                           *
      *----------------------------------------------------------------*
       BUILD-SCORE-FACTORS.
           MOVE SPACES TO HV-SCORE-FACTORS.
           MOVE HV-OVERLAP-DAYS TO WS-OV-DISP.

           IF WS-MARKET-PTS > 0
              MOVE 'MATCH' TO WS-MARKET-FLAG
           ELSE
              MOVE 'NO   ' TO WS-MARKET-FLAG
           END-IF.

           IF WS-GENRE-PTS > 0
              MOVE 'MATCH' TO WS-GENRE-FLAG
           ELSE
              MOVE 'NO   ' TO WS-GENRE-FLAG
           END-IF.

           IF HV-EVT-FOUND = 'Y'
               MOVE HV-BEST-PROX TO WS-PROX-DISP
               EVALUATE FUNCTION TRIM(HV-EVT-SEVERITY)
                   WHEN 'HIGH'   MOVE 'HIGH' TO WS-SEV-SHORT
                   WHEN 'MEDIUM' MOVE 'MED ' TO WS-SEV-SHORT
                   WHEN 'LOW'    MOVE 'LOW ' TO WS-SEV-SHORT
                   WHEN OTHER    MOVE '?   ' TO WS-SEV-SHORT
               END-EVALUATE
               STRING
                   'OVERLAP='                  DELIMITED SIZE
                   FUNCTION TRIM(WS-OV-DISP)   DELIMITED SIZE
                   'd,MARKET='                 DELIMITED SIZE
                   WS-MARKET-FLAG              DELIMITED SPACE
                   ',GENRE='                   DELIMITED SIZE
                   WS-GENRE-FLAG               DELIMITED SPACE
                   ',EVTPROX='                 DELIMITED SIZE
                   FUNCTION TRIM(WS-PROX-DISP) DELIMITED SIZE
                   'd-'                        DELIMITED SIZE
                   WS-SEV-SHORT                DELIMITED SPACE
                   INTO HV-SCORE-FACTORS
           ELSE
               STRING
                   'OVERLAP='                  DELIMITED SIZE
                   FUNCTION TRIM(WS-OV-DISP)   DELIMITED SIZE
                   'd,MARKET='                 DELIMITED SIZE
                   WS-MARKET-FLAG              DELIMITED SPACE
                   ',GENRE='                   DELIMITED SIZE
                   WS-GENRE-FLAG               DELIMITED SPACE
                   ',EVTPROX=NONE'             DELIMITED SIZE
                   INTO HV-SCORE-FACTORS
           END-IF.

      *----------------------------------------------------------------*
      * WRITE-SCORE                                                    *
      * GETS THE NEXT SEQ_SCORE VALUE, BUILDS A SHORT ID LIKE SCR7 THE *
      * SAME WAY THE ONLINE PROGRAMS BUILD THEIRS (MOVE SPACES FIRST   *
      * TO AVOID LEFTOVER BYTES FROM A LONGER PRIOR ID), THEN INSERTS  *
      * ONE ROW. FAILURES HERE ARE LOGGED WITH THE PAIR THAT FAILED SO *
      * A BAD RUN CAN BE DIAGNOSED FROM THE JOB OUTPUT WITHOUT NEEDING *
      * TO RE-RUN WITH EXTRA TRACING.                                  *
      *----------------------------------------------------------------*
       WRITE-SCORE.
           EXEC SQL
             SELECT NEXT VALUE FOR Z73460.SEQ_SCORE
             INTO :HV-NEXT-SEQ
             FROM SYSIBM.SYSDUMMY1
           END-EXEC.

           IF SQLCODE NOT = 0
              DISPLAY 'CLSHBAT - SEQ_SCORE FAILED SQLCODE=' SQLCODE
              MOVE 8 TO WS-RETURN-CODE
              GO TO WRITE-SCORE-EXIT
           END-IF.

           MOVE SPACES      TO HV-SCORE-ID.
           MOVE HV-NEXT-SEQ TO WS-SEQ-CHAR.
           STRING 'SCR'   DELIMITED SIZE
                  FUNCTION TRIM(WS-SEQ-CHAR) DELIMITED SIZE
                  INTO HV-SCORE-ID.

           MOVE WS-TOTAL-SCORE TO HV-RISK-SCORE.

           EXEC SQL
             INSERT INTO Z73460.CLASH_SCORE_T
               (SCORE_ID, RELEASE_ID, CLASH_WITH_ID, RISK_SCORE,
                SCORE_FACTORS, SCORED_TS)
             VALUES
               (:HV-SCORE-ID, :HV-A-ID, :HV-B-ID, :HV-RISK-SCORE,
                :HV-SCORE-FACTORS, CURRENT TIMESTAMP)
           END-EXEC.

           IF SQLCODE NOT = 0
              DISPLAY 'CLSHBAT - INSERT FAILED SQLCODE=' SQLCODE
                      ' PAIR=' HV-A-ID '/' HV-B-ID
              MOVE 8 TO WS-RETURN-CODE
           END-IF.

       WRITE-SCORE-EXIT.
           EXIT.
