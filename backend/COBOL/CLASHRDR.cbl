      *----------------------------------------------------------------*
      * CLASHRDR.CBL                                                   *
      * CICS COBOL PROGRAM - CLASH SCORE READER                        *
      *                                                                *
      * READ-ONLY. RETURNS ALL CLASH SCORE ROWS FROM                   *
      * Z73460.CLASH_SCORE_T FOR A GIVEN RELEASE_ID, VIA CICS WEB      *
      * SUPPORT (NO Z/OS CONNECT). ONE ENDPOINT ONLY:                  *
      *   GET /clashrdr/get?id=REL1                                    *
      * ONLY MATCHES RELEASE_ID, NOT CLASH_WITH_ID - SEE THE NOTE ON   *
      * THAT IN GET-CLASH-SCORES BELOW, IT MATTERS FOR HOW THE SITE    *
      * READS THIS DATA. THIS PROGRAM NEVER WRITES TO ANY DB2 TABLE -  *
      * CLASH_SCORE_T IS WRITTEN ONLY BY THE CLSHBAT BATCH JOB.        *
      *----------------------------------------------------------------*
       IDENTIFICATION DIVISION.
       PROGRAM-ID. CLASHRDR.
       ENVIRONMENT DIVISION.
       DATA DIVISION.
       WORKING-STORAGE SECTION.

       COPY SQLCA.

      *----------------------------------------------------------------*
      * REQUEST FIELDS - POPULATED BY EXTRACT-QUERY-FIELDS.            *
      *----------------------------------------------------------------*
       01 WS-REQ-ID             PIC X(10).

      *----------------------------------------------------------------*
      * RESPONSE BUFFER                                                *
      *----------------------------------------------------------------*
       01 WS-RESPONSE          PIC X(16000).
       01 WS-RESP-LEN          PIC S9(8) COMP VALUE 16000.
       01 WS-RESP-ACTUAL-LEN   PIC S9(8) COMP.
       01 WS-RESP-PTR          PIC S9(8) COMP.
       01 WS-JSON-PTR          PIC S9(8) COMP.
       01 WS-JSON-LEN          PIC S9(8) COMP.

      *----------------------------------------------------------------*
      * DB2 HOST VARIABLES                                             *
      *----------------------------------------------------------------*
       01 HV-RELEASE-ID        PIC X(10).
       01 HV-SCORE-ID          PIC X(10).
       01 HV-CLASH-WITH        PIC X(10).
       01 HV-RISK-SCORE        PIC S9(3)V99 COMP-3.
       01 HV-SCORE-FACTORS     PIC X(200).
       01 HV-SCORED-TS         PIC X(26).

      *----------------------------------------------------------------*
      * WORKING VARIABLES                                              *
      *----------------------------------------------------------------*
       01 WS-SQLCODE-DISP      PIC S9(9) SIGN LEADING SEPARATE.
       01 WS-SCORE-DISPLAY     PIC ZZZ.99.
       01 WS-JSON-ROW          PIC X(500).
       01 WS-FIRST-ROW         PIC X(1) VALUE 'Y'.
       01 WS-SANITIZE-IDX      PIC S9(4) COMP.

      *----------------------------------------------------------------*
      * CICS WEB SUPPORT FIELDS                                        *
      *----------------------------------------------------------------*
       01 WS-HTTP-METHOD       PIC X(10).
       01 WS-HTTP-METHOD-LEN   PIC S9(8) COMP.
       01 WS-HTTP-PATH         PIC X(100).
       01 WS-HTTP-PATH-LEN     PIC S9(8) COMP.
       01 WS-CICS-RESP         PIC S9(8) COMP.
       01 WS-FIELD-LEN         PIC S9(8) COMP.

       PROCEDURE DIVISION.

      *----------------------------------------------------------------*
      * MAIN-LOGIC                                                     *
      * ONLY ONE ROUTE - GET /clashrdr/get - SAME SIMPLE IF/ELSE       *
      * PATTERN AS LOGRDR (BOTH PROGRAMS ARE SINGLE-ENDPOINT READERS,  *
      * SO THEY DON'T NEED THE EVALUATE/PATH-PREFIX ROUTING THE FOUR   *
      * CRUD PROGRAMS USE).                                            *
      *----------------------------------------------------------------*
       MAIN-LOGIC.
           MOVE SPACES TO WS-RESPONSE.
           MOVE SPACES TO WS-HTTP-PATH.
           MOVE SPACES TO WS-HTTP-METHOD.
           MOVE 100 TO WS-HTTP-PATH-LEN.
           MOVE 10  TO WS-HTTP-METHOD-LEN.

           EXEC CICS WEB EXTRACT
                     HTTPMETHOD(WS-HTTP-METHOD)
                     METHODLENGTH(WS-HTTP-METHOD-LEN)
                     PATH(WS-HTTP-PATH)
                     PATHLENGTH(WS-HTTP-PATH-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

           IF WS-HTTP-METHOD NOT = 'GET' OR
              WS-HTTP-PATH(1:13) NOT = '/clashrdr/get'
              MOVE '{"error":"CLASHRDR only supports GET/clashrdr/get"}'
                       TO WS-RESPONSE
           ELSE
              PERFORM EXTRACT-QUERY-FIELDS
              PERFORM GET-CLASH-SCORES THRU GET-CLASH-SCORES-EXIT
           END-IF.

           COMPUTE WS-RESP-ACTUAL-LEN =
               FUNCTION LENGTH(FUNCTION TRIM(WS-RESPONSE)).

           EXEC CICS WEB SEND
                     FROM(WS-RESPONSE)
                     FROMLENGTH(WS-RESP-ACTUAL-LEN)
                     MEDIATYPE('application/json')
                     HOSTCODEPAGE('1047')
                     CHARACTERSET('utf-8')
                     RESP(WS-CICS-RESP)
           END-EXEC.

           EXEC CICS
             RETURN
           END-EXEC.

      *----------------------------------------------------------------*
      * EXTRACT-QUERY-FIELDS - /clashrdr/get?id=REL1                   *
      *----------------------------------------------------------------*
       EXTRACT-QUERY-FIELDS.
           MOVE SPACES TO WS-REQ-ID.
           MOVE 10 TO WS-FIELD-LEN.
           EXEC CICS WEB READ
                     QUERYPARM('id')
                     VALUE(WS-REQ-ID)
                     VALUELENGTH(WS-FIELD-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

      *----------------------------------------------------------------*
      * GET-CLASH-SCORES                                               *
      * CURSOR OVER CLASH_SCORE_T FILTERED TO RELEASE_ID = :HV-        *
      * RELEASE-ID, RISK SCORE DESCENDING. IMPORTANT ASYMMETRY:        *
      * CLSHBAT ALWAYS STORES THE LOWER OF THE TWO IDS IN A PAIR AS    *
      * RELEASE_ID AND THE HIGHER ONE AS CLASH_WITH_ID (BECAUSE OF THE *
      * RELEASE_ID > :HV-A-ID CONDITION IN ITS INNER CURSOR). SO THIS  *
      * QUERY ONLY FINDS PAIRS WHERE THE REQUESTED ID WAS THE LOWER    *
      * ONE - CALLING /clashrdr/get?id=REL2 WILL MISS THE REL1/REL2    *
      * PAIR ENTIRELY, EVEN THOUGH REL2 IS CLEARLY INVOLVED IN IT. THE *
      * FLASK LAYER WORKS AROUND THIS BY CALLING CLASHRDR ONCE PER     *
      * RELEASE WHEN BUILDING THE DASHBOARD, SO EVERY RELEASE STILL    *
      * ENDS UP SHOWING ITS PAIRS OVERALL - JUST NOT FROM A SINGLE     *
      * CALL TO THIS ENDPOINT ALONE.                                   *
      *----------------------------------------------------------------*
       GET-CLASH-SCORES.
           MOVE FUNCTION TRIM(WS-REQ-ID) TO HV-RELEASE-ID.
           MOVE SPACES TO WS-RESPONSE.
           MOVE 1      TO WS-RESP-PTR.
           MOVE 'Y'    TO WS-FIRST-ROW.

           STRING '[' DELIMITED SIZE
                  INTO WS-RESPONSE WITH POINTER WS-RESP-PTR.

           EXEC SQL DECLARE CLASH-CURSOR CURSOR FOR
             SELECT SCORE_ID, RELEASE_ID, CLASH_WITH_ID, RISK_SCORE,
                    COALESCE(SCORE_FACTORS,""),
                    SUBSTR(CHAR(SCORED_TS),1,10)
             FROM   Z73460.CLASH_SCORE_T
             WHERE  RELEASE_ID = :HV-RELEASE-ID
             ORDER BY RISK_SCORE DESC
           END-EXEC.

           EXEC SQL
             OPEN CLASH-CURSOR
           END-EXEC.

           IF SQLCODE NOT = 0
              MOVE SQLCODE TO WS-SQLCODE-DISP
              STRING '{"error":"OPEN CURSOR failed","sqlcode":"'
                                      DELIMITED SIZE
                     WS-SQLCODE-DISP  DELIMITED SPACE
                     '"}'             DELIMITED SIZE
                     INTO WS-RESPONSE
              GO TO GET-CLASH-SCORES-EXIT
           END-IF.

           PERFORM UNTIL SQLCODE NOT = 0
               EXEC SQL FETCH CLASH-CURSOR
                 INTO :HV-SCORE-ID, :HV-RELEASE-ID, :HV-CLASH-WITH,
                      :HV-RISK-SCORE, :HV-SCORE-FACTORS, :HV-SCORED-TS
               END-EXEC

               IF SQLCODE = 0
                  PERFORM SANITIZE-SCORE-ID
                  PERFORM SANITIZE-SCORE-FACTORS
                  MOVE HV-RISK-SCORE TO WS-SCORE-DISPLAY
                  PERFORM BUILD-CLASH-JSON-OBJ
                  IF WS-FIRST-ROW = 'N'
                     STRING ',' DELIMITED SIZE
                            INTO WS-RESPONSE WITH POINTER WS-RESP-PTR
                  ELSE
                     MOVE 'N' TO WS-FIRST-ROW
                  END-IF
                  STRING WS-JSON-ROW(1:WS-JSON-LEN) DELIMITED SIZE
                         INTO WS-RESPONSE WITH POINTER WS-RESP-PTR
               END-IF
           END-PERFORM.

           EXEC SQL
             CLOSE CLASH-CURSOR
           END-EXEC.

           STRING ']' DELIMITED SIZE
                  INTO WS-RESPONSE WITH POINTER WS-RESP-PTR.

       GET-CLASH-SCORES-EXIT.
           EXIT.

      *----------------------------------------------------------------*
      * SANITIZE-SCORE-ID                                              *
      * SAME CLASS OF BUG AS SANITIZE-SCORE-FACTORS BELOW, BUT FOR     *
      * THE 10-BYTE SCORE_ID FIELD - OLD CLSHBAT WRITES (BEFORE THE    *
      * MOVE SPACES FIX) LEFT TRAILING LOW-VALUE GARBAGE AFTER THE     *
      * SHORT ID TEXT (E.G. "SCR25" PLUS 5 LOW-VALUE BYTES), WHICH IS  *
      * INVALID INSIDE A JSON STRING. NEW ROWS DON'T HAVE THIS         *
      * PROBLEM SINCE THE FIX; THIS IS SAFETY NET FOR OLD ONES.        *
      *----------------------------------------------------------------*
       SANITIZE-SCORE-ID.
           PERFORM VARYING WS-SANITIZE-IDX FROM 1 BY 1
                   UNTIL WS-SANITIZE-IDX > 10
               IF HV-SCORE-ID(WS-SANITIZE-IDX:1) < SPACE
                  MOVE SPACE TO HV-SCORE-ID(WS-SANITIZE-IDX:1)
               END-IF
           END-PERFORM.

      *----------------------------------------------------------------*
      * SANITIZE-SCORE-FACTORS                                         *
      * SCANS HV-SCORE-FACTORS BYTE BY BYTE AND BLANKS OUT ANYTHING    *
      * BELOW SPACE (COVERS LOW-VALUES AND ANY OTHER LEFTOVER BINARY   *
      * GARBAGE FROM OLD BUGGY WRITES), THEN REPLACES ANY LITERAL      *
      * DOUBLE-QUOTE WITH A SINGLE QUOTE SO IT CAN NEVER BREAK THE     *
      * JSON STRING IT GETS EMBEDDED INTO. SAME PATTERN ALREADY        *
      * PROVEN FIXING THIS EXACT CLASS OF BUG IN LOGRDR.               *
      *----------------------------------------------------------------*
       SANITIZE-SCORE-FACTORS.
           PERFORM VARYING WS-SANITIZE-IDX FROM 1 BY 1
                   UNTIL WS-SANITIZE-IDX > 200
               IF HV-SCORE-FACTORS(WS-SANITIZE-IDX:1) < SPACE
                  MOVE SPACE TO HV-SCORE-FACTORS(WS-SANITIZE-IDX:1)
               END-IF
           END-PERFORM.
           INSPECT HV-SCORE-FACTORS REPLACING ALL '"' BY ''''.

      *----------------------------------------------------------------*
      * BUILD-CLASH-JSON-OBJ                                           *
      * BUILDS ONE JSON OBJECT INTO WS-JSON-ROW FROM THE CURRENT HOST  *
      * VARIABLES. RISKSCORE IS EMITTED UNQUOTED (IT'S A JSON NUMBER,  *
      * NOT A STRING) VIA WS-SCORE-DISPLAY, WHICH ALREADY HOLDS THE    *
      * FORMATTED DIGITS FROM GET-CLASH-SCORES BEFORE THIS RUNS.       *
      *----------------------------------------------------------------*
       BUILD-CLASH-JSON-OBJ.
           MOVE SPACES TO WS-JSON-ROW.
           MOVE 1      TO WS-JSON-PTR.
           STRING
               '{"scoreId":"'       DELIMITED SIZE
               FUNCTION TRIM(HV-SCORE-ID)      DELIMITED SIZE
               '","releaseId":"'    DELIMITED SIZE
               FUNCTION TRIM(HV-RELEASE-ID)    DELIMITED SIZE
               '","clashWithId":"'  DELIMITED SIZE
               FUNCTION TRIM(HV-CLASH-WITH)    DELIMITED SIZE
               '","riskScore":'     DELIMITED SIZE
               WS-SCORE-DISPLAY                DELIMITED SIZE
               ',"scoreFactors":"'  DELIMITED SIZE
               FUNCTION TRIM(HV-SCORE-FACTORS) DELIMITED SIZE
               '","scoredTs":"'     DELIMITED SIZE
               FUNCTION TRIM(HV-SCORED-TS)     DELIMITED SIZE
               '"}'                 DELIMITED SIZE
               INTO WS-JSON-ROW WITH POINTER WS-JSON-PTR.
           COMPUTE WS-JSON-LEN = WS-JSON-PTR - 1.
