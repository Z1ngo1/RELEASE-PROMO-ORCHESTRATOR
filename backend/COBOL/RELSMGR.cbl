      *----------------------------------------------------------------*
      * RELSMGR.CBL                                                    *
      * CICS COBOL PROGRAM - RELEASE MANAGER                           *
      *                                                                *
      * ADD/GET/LIST/UPD/DEL FOR Z73460.RELEASE_T VIA CICS WEB SUPPORT *
      * (TCPIPSERVICE + URIMAP + WEB EXTRACT/READ/SEND, NO Z/OS        *
      * CONNECT). MAIN-LOGIC ROUTES ON WS-HTTP-PATH/WS-HTTP-METHOD.    *
      *----------------------------------------------------------------*
       IDENTIFICATION DIVISION.
       PROGRAM-ID. RELSMGR.
       ENVIRONMENT DIVISION.
       DATA DIVISION.
       WORKING-STORAGE SECTION.

      *----------------------------------------------------------------*
      * SQL COMMUNICATION AREA                                         *
      *----------------------------------------------------------------*
       COPY SQLCA.

      *----------------------------------------------------------------*
      * REQUEST FIELDS (populated by EXTRACT-QUERY-FIELDS /            *
      * EXTRACT-FORM-FIELDS, not by GET CONTAINER anymore)             *
      *----------------------------------------------------------------*
       01 WS-REQ-ID             PIC X(10).
       01 WS-REQ-TITLE          PIC X(100).
       01 WS-REQ-GENRE          PIC X(20).
       01 WS-REQ-PLATFORM       PIC X(20).
       01 WS-REQ-REL-DATE       PIC X(10).
       01 WS-REQ-WIN-END        PIC X(10).
       01 WS-REQ-MARKET         PIC X(20).
       01 WS-REQ-STATUS         PIC X(10).

      *----------------------------------------------------------------*
      * RESPONSE BUFFER - LARGE ENOUGH FOR LIST OF UP TO 50 RELEASES   *
      *----------------------------------------------------------------*
       01 WS-RESPONSE          PIC X(32000).
       01 WS-RESP-LEN          PIC S9(8) COMP VALUE 32000.
       01 WS-RESP-PTR          PIC S9(8) COMP.
       01 WS-JSON-PTR          PIC S9(8) COMP.
       01 WS-JSON-LEN          PIC S9(8) COMP.
       01 WS-RESP-ACTUAL-LEN   PIC S9(8) COMP.

      *----------------------------------------------------------------*
      * DB2 HOST VARIABLES                                             *
      *----------------------------------------------------------------*
       01 HV-RELEASE-ID        PIC X(10).
       01 HV-TITLE             PIC X(100).
       01 HV-GENRE              PIC X(20).
       01 HV-PLATFORM          PIC X(20).
       01 HV-REL-DATE          PIC X(10).
       01 HV-WIN-END           PIC X(10).
       01 HV-MARKET            PIC X(20).
       01 HV-STATUS            PIC X(10).
       01 HV-ADDED-TS          PIC X(26).
       01 HV-UPDATED-TS        PIC X(26).
       01 HV-LOG-ID            PIC S9(18) COMP.
       01 HV-LOG-ENTITY-TYPE   PIC X(10).
       01 HV-LOG-ENTITY-ID     PIC X(10).
       01 HV-LOG-ACTION        PIC X(6).
       01 HV-LOG-DETAILS       PIC X(200).

      *----------------------------------------------------------------*
      * SEQUENCE VALUE FOR PK GENERATION                               *
      *----------------------------------------------------------------*
       01 HV-NEXT-SEQ          PIC S9(18) COMP.
       01 WS-SEQ-CHAR          PIC Z(6)9.
       01 WS-NEW-ID            PIC X(10).

      *----------------------------------------------------------------*
      * WORKING VARIABLES                                              *
      *----------------------------------------------------------------*
       01 WS-SQLCODE-DISP      PIC S9(9) SIGN LEADING SEPARATE.
       01 WS-JSON-WORK         PIC X(400).
       01 WS-JSON-ROW          PIC X(500).
       01 WS-FIRST-ROW         PIC X(1) VALUE 'Y'.

      *----------------------------------------------------------------*
      * CICS WEB SUPPORT FIELDS                                        *
      *----------------------------------------------------------------*
       01 WS-HTTP-METHOD       PIC X(10).
       01 WS-HTTP-METHOD-LEN   PIC S9(8) COMP.
       01 WS-HTTP-PATH         PIC X(100).
       01 WS-HTTP-PATH-LEN     PIC S9(8) COMP.
       01 WS-CICS-RESP         PIC S9(8) COMP.
       01 WS-FIELD-LEN         PIC S9(8) COMP.

       01 WS-DATE-CHECK        PIC X(10).
       01 WS-DATE-OK           PIC X(1).
       01 WS-DATE-YYYY         PIC X(4).
       01 WS-DATE-MM           PIC X(2).
       01 WS-DATE-DD           PIC X(2).

       PROCEDURE DIVISION.

      *----------------------------------------------------------------*
      * MAINLINE                                                       *
      * READS THE HTTP METHOD AND PATH VIA WEB EXTRACT, THEN ROUTES    *
      * TO THE RIGHT PARAGRAPH BASED ON PATH SUFFIX (/LIST, /GET,      *
      * /ADD, /UPD, /DEL) AND METHOD (GET FOR READS, POST FOR WRITES). *
      * EVERY BRANCH ENDS UP AT WEB SEND, WHICH RETURNS WHATEVER JSON  *
      * ENDED UP IN WS-RESPONSE - EITHER REAL DATA OR AN ERROR OBJECT. *
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

           EVALUATE TRUE
               WHEN WS-HTTP-PATH(1:13) = '/relsmgr/list'
                 PERFORM EXTRACT-QUERY-FIELDS
                 PERFORM LIST-RELEASES THRU LIST-RELEASES-EXIT
               WHEN WS-HTTP-PATH(1:12) = '/relsmgr/get'
                 PERFORM EXTRACT-QUERY-FIELDS
                 PERFORM GET-RELEASE
               WHEN WS-HTTP-METHOD = 'POST' AND
                    WS-HTTP-PATH(1:12) = '/relsmgr/add'
                 PERFORM EXTRACT-FORM-FIELDS
                 PERFORM ADD-RELEASE THRU ADD-RELEASE-EXIT
               WHEN WS-HTTP-METHOD = 'POST' AND
                    WS-HTTP-PATH(1:12) = '/relsmgr/upd'
                 PERFORM EXTRACT-FORM-FIELDS
                 PERFORM UPD-RELEASE THRU UPD-RELEASE-EXIT
               WHEN WS-HTTP-METHOD = 'POST' AND
                    WS-HTTP-PATH(1:12) = '/relsmgr/del'
                 PERFORM EXTRACT-FORM-FIELDS
                 PERFORM DEL-RELEASE
               WHEN OTHER
                 MOVE '{"error":"Unknown path"}' TO WS-RESPONSE
           END-EVALUATE.

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
      * EXTRACT-QUERY-FIELDS - FOR GET REQUESTS, E.G. ?id=REL1         *
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
      * EXTRACT-FORM-FIELDS - FOR POST REQUESTS, FORM-ENCODED BODY     *
      *----------------------------------------------------------------*
       EXTRACT-FORM-FIELDS.
           MOVE SPACES TO WS-REQ-ID WS-REQ-TITLE WS-REQ-GENRE
                          WS-REQ-PLATFORM WS-REQ-REL-DATE
                          WS-REQ-WIN-END WS-REQ-MARKET WS-REQ-STATUS.

           MOVE 10 TO WS-FIELD-LEN.
           EXEC CICS WEB READ FORMFIELD('id')
                     VALUE(WS-REQ-ID) VALUELENGTH(WS-FIELD-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

           MOVE 100 TO WS-FIELD-LEN.
           EXEC CICS WEB READ FORMFIELD('title')
                     VALUE(WS-REQ-TITLE) VALUELENGTH(WS-FIELD-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

           MOVE 20 TO WS-FIELD-LEN.
           EXEC CICS WEB READ FORMFIELD('genre')
                     VALUE(WS-REQ-GENRE) VALUELENGTH(WS-FIELD-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

           MOVE 20 TO WS-FIELD-LEN.
           EXEC CICS WEB READ FORMFIELD('platform')
                     VALUE(WS-REQ-PLATFORM) VALUELENGTH(WS-FIELD-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

           MOVE 10 TO WS-FIELD-LEN.
           EXEC CICS WEB READ FORMFIELD('releaseDate')
                     VALUE(WS-REQ-REL-DATE) VALUELENGTH(WS-FIELD-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

           MOVE 10 TO WS-FIELD-LEN.
           EXEC CICS WEB READ FORMFIELD('windowEnd')
                     VALUE(WS-REQ-WIN-END) VALUELENGTH(WS-FIELD-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

           MOVE 20 TO WS-FIELD-LEN.
           EXEC CICS WEB READ FORMFIELD('market')
                     VALUE(WS-REQ-MARKET) VALUELENGTH(WS-FIELD-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

           MOVE 10 TO WS-FIELD-LEN.
           EXEC CICS WEB READ FORMFIELD('status')
                     VALUE(WS-REQ-STATUS) VALUELENGTH(WS-FIELD-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

      *----------------------------------------------------------------*
      * VALIDATE-RELEASE-INPUT                                         *
      * SHARED VALIDATION FOR ADD-RELEASE AND UPD-RELEASE - BOTH MUST  *
      * PASS THE SAME GENRE/PLATFORM/MARKET WHITELIST CHECKS AND THE   *
      * SAME YYYY-MM-DD FORMAT CHECK ON BOTH DATE FIELDS, SO THE LOGIC *
      * LIVES HERE ONCE INSTEAD OF BEING DUPLICATED IN BOTH CALLERS.   *
      *                                                                *
      * CALL WITH PERFORM ... THRU VALIDATE-RELEASE-INPUT-EXIT (THERE  *
      * ARE GO TO STATEMENTS INSIDE THAT JUMP STRAIGHT TO THE EXIT ON  *
      * THE FIRST FAILURE). ON RETURN, CHECK WS-DATE-OK: IF 'N', THE   *
      * CALLER SHOULD GO TO ITS OWN -EXIT IMMEDIATELY - WS-RESPONSE IS *
      * ALREADY SET WITH A DESCRIPTIVE ERROR AND NOTHING ELSE SHOULD   *
      * RUN. IF 'Y', ALL FOUR CHECKS PASSED AND IT IS SAFE TO PROCEED. *
      *----------------------------------------------------------------*
       VALIDATE-RELEASE-INPUT.
           MOVE 'Y' TO WS-DATE-OK.

           EVALUATE FUNCTION TRIM(WS-REQ-GENRE)
               WHEN 'DRAMA' WHEN 'COMEDY' WHEN 'SPORT'
               WHEN 'DOCUMENTARY' WHEN 'THRILLER' WHEN 'OTHER'
                 CONTINUE
               WHEN OTHER
                 MOVE '{"error":"Invalid genre"}' TO WS-RESPONSE
                 MOVE 'N' TO WS-DATE-OK
                 GO TO VALIDATE-RELEASE-INPUT-EXIT
           END-EVALUATE.

           EVALUATE FUNCTION TRIM(WS-REQ-PLATFORM)
               WHEN 'STREAMING' WHEN 'LINEAR' WHEN 'THEATRICAL'
                 CONTINUE
               WHEN OTHER
                 MOVE '{"error":"Invalid platform"}' TO WS-RESPONSE
                 MOVE 'N' TO WS-DATE-OK
                 GO TO VALIDATE-RELEASE-INPUT-EXIT
           END-EVALUATE.

           EVALUATE FUNCTION TRIM(WS-REQ-MARKET)
               WHEN 'US' WHEN 'EU' WHEN 'APAC' WHEN 'LATAM' WHEN
                    'GLOBAL'
                 CONTINUE
               WHEN OTHER
                 MOVE '{"error":"Invalid market"}' TO WS-RESPONSE
                 MOVE 'N' TO WS-DATE-OK
                 GO TO VALIDATE-RELEASE-INPUT-EXIT
           END-EVALUATE.

           IF WS-REQ-REL-DATE = SPACES
              MOVE '{"error":"releaseDate is required"}' TO WS-RESPONSE
              MOVE 'N' TO WS-DATE-OK
              GO TO VALIDATE-RELEASE-INPUT-EXIT
           END-IF.
           MOVE WS-REQ-REL-DATE TO WS-DATE-CHECK.
           PERFORM VALIDATE-DATE-FORMAT THRU VALIDATE-DATE-FORMAT-EXIT.
           IF WS-DATE-OK = 'N'
              MOVE '{"error":"Bad releaseDate format"}' TO WS-RESPONSE
              GO TO VALIDATE-RELEASE-INPUT-EXIT
           END-IF.

           IF WS-REQ-WIN-END = SPACES
              MOVE '{"error":"windowEnd is required"}' TO WS-RESPONSE
              MOVE 'N' TO WS-DATE-OK
              GO TO VALIDATE-RELEASE-INPUT-EXIT
           END-IF.
           MOVE WS-REQ-WIN-END TO WS-DATE-CHECK.
           PERFORM VALIDATE-DATE-FORMAT THRU VALIDATE-DATE-FORMAT-EXIT.
           IF WS-DATE-OK = 'N'
              MOVE '{"error":"Bad windowEnd format"}' TO WS-RESPONSE
           END-IF.

       VALIDATE-RELEASE-INPUT-EXIT.
           EXIT.

      *----------------------------------------------------------------*
      * ADD-RELEASE                                                    *
      * VALIDATES INPUT, THEN GETS THE NEXT SEQ_RELEASE VALUE AND      *
      * BUILDS A SHORT ID LIKE REL24 (WS-SEQ-CHAR IS PIC Z(6)9 SO      *
      * LEADING ZEROS ARE SUPPRESSED, FUNCTION TRIM STRIPS THE         *
      * RESULTING LEADING SPACES). WS-NEW-ID IS EXPLICITLY CLEARED     *
      * WITH MOVE SPACES BEFORE THE STRING - WITHOUT THAT, A SHORTER   *
      * NEW ID WOULD LEAVE STALE BYTES FROM A PREVIOUS LONGER VALUE    *
      * SITTING PAST THE END OF THE NEW STRING (THIS BIT A REAL RUN    *
      * ONCE - IDS CAME OUT LOOKING LIKE REL2400023 INSTEAD OF REL24). *
      * ON SUCCESS, ALSO WRITES AN ADD ENTRY TO CHANGE_LOG.            *
      *----------------------------------------------------------------*
       ADD-RELEASE.
           PERFORM VALIDATE-RELEASE-INPUT THRU
                   VALIDATE-RELEASE-INPUT-EXIT.
           IF WS-DATE-OK = 'N'
              GO TO ADD-RELEASE-EXIT
           END-IF.

           EXEC SQL
             SELECT NEXT VALUE FOR Z73460.SEQ_RELEASE
             INTO :HV-NEXT-SEQ
             FROM SYSIBM.SYSDUMMY1
           END-EXEC.

           IF SQLCODE NOT = 0
              MOVE '{"error":"SEQ fetch failed"}' TO WS-RESPONSE
              GO TO ADD-RELEASE-EXIT
           END-IF.

           MOVE SPACES      TO WS-NEW-ID.
           MOVE HV-NEXT-SEQ TO WS-SEQ-CHAR.
           STRING 'REL'                      DELIMITED SIZE
                  FUNCTION TRIM(WS-SEQ-CHAR) DELIMITED SIZE
                  INTO WS-NEW-ID.

           MOVE FUNCTION TRIM(WS-REQ-TITLE)    TO HV-TITLE.
           MOVE FUNCTION TRIM(WS-REQ-GENRE)    TO HV-GENRE.
           MOVE FUNCTION TRIM(WS-REQ-PLATFORM) TO HV-PLATFORM.
           MOVE WS-REQ-REL-DATE                TO HV-REL-DATE.
           MOVE WS-REQ-WIN-END                 TO HV-WIN-END.
           MOVE FUNCTION TRIM(WS-REQ-MARKET)   TO HV-MARKET.
           MOVE 'DRAFT'                        TO HV-STATUS.
           MOVE WS-NEW-ID                      TO HV-RELEASE-ID.

           EXEC SQL
             INSERT INTO Z73460.RELEASE_T
               (RELEASE_ID, TITLE, GENRE, PLATFORM, RELEASE_DATE,
                WINDOW_END, TARGET_MARKET, STATUS, ADDED_TS, UPDATED_TS)
             VALUES
               (:HV-RELEASE-ID, :HV-TITLE, :HV-GENRE, :HV-PLATFORM,
                :HV-REL-DATE, :HV-WIN-END, :HV-MARKET, :HV-STATUS,
                CURRENT TIMESTAMP, CURRENT TIMESTAMP)
           END-EXEC.

           IF SQLCODE = 0
              STRING '{"releaseId":"' DELIMITED SIZE
                     WS-NEW-ID        DELIMITED SPACE
                     '","status":"DRAFT","message":"Release added"}'
                                      DELIMITED SIZE
                     INTO WS-RESPONSE
              MOVE 'RELEASE' TO HV-LOG-ENTITY-TYPE
              MOVE WS-NEW-ID TO HV-LOG-ENTITY-ID
              MOVE 'ADD'     TO HV-LOG-ACTION
              MOVE SPACES    TO HV-LOG-DETAILS
              STRING 'title=' DELIMITED SIZE
                     FUNCTION TRIM(HV-TITLE) DELIMITED SIZE
                     ' status=DRAFT' DELIMITED SIZE
                     INTO HV-LOG-DETAILS
              PERFORM WRITE-CHANGE-LOG
           ELSE
              MOVE SQLCODE TO WS-SQLCODE-DISP
              STRING '{"error":"INSERT failed","sqlcode":"'
                                      DELIMITED SIZE
                     WS-SQLCODE-DISP  DELIMITED SPACE
                     '"}'             DELIMITED SIZE
                     INTO WS-RESPONSE
           END-IF.

       ADD-RELEASE-EXIT.
           EXIT.

      *----------------------------------------------------------------*
      * GET-RELEASE - SELECT SINGLE ROW BY RELEASE_ID, RETURN AS JSON. *
      *----------------------------------------------------------------*
       GET-RELEASE.
           MOVE FUNCTION TRIM(WS-REQ-ID) TO HV-RELEASE-ID.

           EXEC SQL
             SELECT RELEASE_ID, TITLE, GENRE, PLATFORM,
                    CHAR(RELEASE_DATE,ISO), CHAR(WINDOW_END,ISO),
                    TARGET_MARKET, STATUS, CHAR(ADDED_TS),
                    CHAR(UPDATED_TS)
             INTO   :HV-RELEASE-ID, :HV-TITLE, :HV-GENRE,
                    :HV-PLATFORM, :HV-REL-DATE, :HV-WIN-END,
                    :HV-MARKET, :HV-STATUS, :HV-ADDED-TS,
                    :HV-UPDATED-TS
             FROM   Z73460.RELEASE_T
             WHERE  RELEASE_ID = :HV-RELEASE-ID
           END-EXEC.

           EVALUATE SQLCODE
               WHEN 0
                 PERFORM BUILD-RELEASE-JSON-OBJ
                 MOVE WS-JSON-ROW TO WS-RESPONSE
               WHEN 100
                 MOVE '{"error":"Release not found"}' TO WS-RESPONSE
               WHEN OTHER
                 MOVE SQLCODE TO WS-SQLCODE-DISP
                 STRING '{"error":"SELECT failed","sqlcode":"'
                                         DELIMITED SIZE
                        WS-SQLCODE-DISP  DELIMITED SPACE
                        '"}'             DELIMITED SIZE
                        INTO WS-RESPONSE
           END-EVALUATE.

      *----------------------------------------------------------------*
      * LIST-RELEASES                                                  *
      * CURSOR SCAN OF EVERY ROW IN RELEASE_T, ORDERED BY RELEASE      *
      * DATE. BUILDS A JSON ARRAY MANUALLY WITH THE POINTER PHRASE -   *
      * WS-RESPONSE IS CLEARED FIRST, THEN EACH ROW IS APPENDED WITH   *
      * A COMMA SEPARATOR (SKIPPED ON THE FIRST ROW VIA WS-FIRST-ROW). *
      * NO HARD LIMIT ON ROW COUNT OTHER THAN THE 32000-BYTE BUFFER.   *
      *----------------------------------------------------------------*
       LIST-RELEASES.
           MOVE SPACES TO WS-RESPONSE.
           MOVE 1      TO WS-RESP-PTR.
           MOVE 'Y'    TO WS-FIRST-ROW.

           STRING '[' DELIMITED SIZE
                  INTO WS-RESPONSE WITH POINTER WS-RESP-PTR.

           EXEC SQL DECLARE REL-CURSOR CURSOR FOR
             SELECT RELEASE_ID, TITLE, GENRE, PLATFORM,
                    CHAR(RELEASE_DATE,ISO), CHAR(WINDOW_END,ISO),
                    TARGET_MARKET, STATUS, CHAR(ADDED_TS),
                    CHAR(UPDATED_TS)
             FROM   Z73460.RELEASE_T
             ORDER BY RELEASE_DATE ASC
           END-EXEC.

           EXEC SQL
             OPEN REL-CURSOR
           END-EXEC.

           IF SQLCODE NOT = 0
              MOVE SQLCODE TO WS-SQLCODE-DISP
              STRING '{"error":"OPEN CURSOR failed","sqlcode":"'
                                      DELIMITED SIZE
                     WS-SQLCODE-DISP  DELIMITED SPACE
                     '"}'             DELIMITED SIZE
                     INTO WS-RESPONSE
              GO TO LIST-RELEASES-EXIT
           END-IF.

           PERFORM UNTIL SQLCODE NOT = 0
               EXEC SQL FETCH REL-CURSOR
                 INTO :HV-RELEASE-ID, :HV-TITLE, :HV-GENRE,
                      :HV-PLATFORM, :HV-REL-DATE, :HV-WIN-END,
                      :HV-MARKET, :HV-STATUS, :HV-ADDED-TS,
                      :HV-UPDATED-TS
               END-EXEC
               IF SQLCODE = 0
                  PERFORM BUILD-RELEASE-JSON-OBJ
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
             CLOSE REL-CURSOR
           END-EXEC.

           STRING ']' DELIMITED SIZE
                  INTO WS-RESPONSE WITH POINTER WS-RESP-PTR.

       LIST-RELEASES-EXIT.
           EXIT.

      *----------------------------------------------------------------*
      * UPD-RELEASE                                                    *
      * UPDATES EVERY EDITABLE FIELD FOR AN EXISTING ROW - STATUS,     *
      * TITLE, GENRE, PLATFORM, RELEASEDATE, WINDOWEND, MARKET. RUNS   *
      * THE SAME VALIDATE-RELEASE-INPUT CHECKS AS ADD-RELEASE, SO A    *
      * PARTIAL/INVALID FIELD IS REJECTED BEFORE ANY SQL RUNS. BECAUSE *
      * EVERY FIELD IS OVERWRITTEN, THE CALLER (FLASK) MUST ALWAYS     *
      * SEND THE FULL CURRENT RECORD, NOT JUST THE FIELD BEING CHANGED *
      * - THE EDIT FORM ON THE SITE PRE-POPULATES ALL FIELDS FOR THIS  *
      * REASON. ON SUCCESS, ALSO WRITES AN UPD ENTRY TO CHANGE_LOG.    *
      *----------------------------------------------------------------*
       UPD-RELEASE.
           PERFORM VALIDATE-RELEASE-INPUT THRU
                   VALIDATE-RELEASE-INPUT-EXIT.
           IF WS-DATE-OK = 'N'
              GO TO UPD-RELEASE-EXIT
           END-IF.

           MOVE FUNCTION TRIM(WS-REQ-ID)       TO HV-RELEASE-ID.
           MOVE FUNCTION TRIM(WS-REQ-STATUS)   TO HV-STATUS.
           MOVE FUNCTION TRIM(WS-REQ-TITLE)    TO HV-TITLE.
           MOVE FUNCTION TRIM(WS-REQ-GENRE)    TO HV-GENRE.
           MOVE FUNCTION TRIM(WS-REQ-PLATFORM) TO HV-PLATFORM.
           MOVE WS-REQ-REL-DATE                TO HV-REL-DATE.
           MOVE WS-REQ-WIN-END                 TO HV-WIN-END.
           MOVE FUNCTION TRIM(WS-REQ-MARKET)   TO HV-MARKET.

           EXEC SQL
             UPDATE Z73460.RELEASE_T
             SET    STATUS        = :HV-STATUS,
                    TITLE         = :HV-TITLE,
                    GENRE         = :HV-GENRE,
                    PLATFORM      = :HV-PLATFORM,
                    RELEASE_DATE  = :HV-REL-DATE,
                    WINDOW_END    = :HV-WIN-END,
                    TARGET_MARKET = :HV-MARKET,
                    UPDATED_TS    = CURRENT TIMESTAMP
             WHERE  RELEASE_ID = :HV-RELEASE-ID
           END-EXEC.

           EVALUATE SQLCODE
               WHEN 0
                 STRING '{"releaseId":"'  DELIMITED SIZE
                        HV-RELEASE-ID     DELIMITED SPACE
                        '","message":"Release updated"}'
                                          DELIMITED SIZE
                        INTO WS-RESPONSE
                 MOVE 'RELEASE'     TO HV-LOG-ENTITY-TYPE
                 MOVE HV-RELEASE-ID TO HV-LOG-ENTITY-ID
                 MOVE 'UPD'         TO HV-LOG-ACTION
                 MOVE SPACES        TO HV-LOG-DETAILS
                 STRING 'status set to ' DELIMITED SIZE
                        FUNCTION TRIM(HV-STATUS) DELIMITED SIZE
                        INTO HV-LOG-DETAILS
                 PERFORM WRITE-CHANGE-LOG
               WHEN 100
                 MOVE '{"error":"Release not found"}' TO WS-RESPONSE
               WHEN OTHER
                 MOVE SQLCODE TO WS-SQLCODE-DISP
                 STRING '{"error":"UPDATE failed","sqlcode":"'
                                         DELIMITED SIZE
                        WS-SQLCODE-DISP  DELIMITED SPACE
                        '"}'             DELIMITED SIZE
                        INTO WS-RESPONSE
           END-EVALUATE.

       UPD-RELEASE-EXIT.
           EXIT.

      *----------------------------------------------------------------*
      * DEL-RELEASE                                                    *
      * PLAIN DELETE BY RELEASE_ID. PROMO_T AND CLASH_SCORE_T BOTH     *
      * HAVE FOREIGN KEYS BACK TO THIS TABLE, SO DB2 BLOCKS THE        *
      * DELETE WITH SQLCODE -532 IF EITHER STILL HAS ROWS POINTING AT  *
      * THIS RELEASE. THAT IS HANDLED HERE AS A DEDICATED, READABLE    *
      * ERROR MESSAGE RATHER THAN A RAW SQLCODE - THERE IS NO          *
      * AUTOMATIC CASCADE DELETE BY DESIGN, TO AVOID SILENTLY WIPING   *
      * A RELEASE'S PROMO CHECKLIST OR CLASH HISTORY BY ACCIDENT. THE  *
      * CALLER MUST REMOVE DEPENDENT ROWS FIRST. ON SUCCESS, ALSO      *
      * WRITES A DEL ENTRY TO CHANGE_LOG.                              *
      *----------------------------------------------------------------*
       DEL-RELEASE.
           MOVE FUNCTION TRIM(WS-REQ-ID) TO HV-RELEASE-ID.

           EXEC SQL
             DELETE FROM Z73460.RELEASE_T
             WHERE RELEASE_ID = :HV-RELEASE-ID
           END-EXEC.

           EVALUATE SQLCODE
               WHEN 0
                 STRING '{"releaseId":"'  DELIMITED SIZE
                        HV-RELEASE-ID     DELIMITED SPACE
                        '","message":"Release deleted"}'
                                          DELIMITED SIZE
                        INTO WS-RESPONSE
                 MOVE 'RELEASE'     TO HV-LOG-ENTITY-TYPE
                 MOVE HV-RELEASE-ID TO HV-LOG-ENTITY-ID
                 MOVE 'DEL'         TO HV-LOG-ACTION
                 MOVE SPACES        TO HV-LOG-DETAILS
                 STRING 'release deleted' DELIMITED SIZE
                        INTO HV-LOG-DETAILS
                 PERFORM WRITE-CHANGE-LOG
               WHEN 100
                 MOVE '{"error":"Release not found"}' TO WS-RESPONSE
               WHEN -532
                 MOVE '{"error":"Cannot delete - has dependent promo/c
      -               'lash rows"}' TO WS-RESPONSE
               WHEN OTHER
                 MOVE SQLCODE TO WS-SQLCODE-DISP
                 STRING '{"error":"DELETE failed","sqlcode":"'
                                         DELIMITED SIZE
                        WS-SQLCODE-DISP  DELIMITED SPACE
                        '"}'             DELIMITED SIZE
                        INTO WS-RESPONSE
           END-EVALUATE.

      *----------------------------------------------------------------*
      * BUILD-RELEASE-JSON-OBJ                                         *
      * BUILDS ONE JSON OBJECT INTO WS-JSON-ROW FROM THE CURRENT HOST  *
      * VARIABLES. USED BY GET-RELEASE (SINGLE OBJECT RESPONSE) AND    *
      * LIST-RELEASES (ONE CALL PER FETCHED ROW, APPENDED TO AN ARRAY).*
      *----------------------------------------------------------------*
       BUILD-RELEASE-JSON-OBJ.
           MOVE SPACES TO WS-JSON-ROW.
           MOVE 1      TO WS-JSON-PTR.
           STRING
               '{"releaseId":"'         DELIMITED SIZE
               FUNCTION TRIM(HV-RELEASE-ID)  DELIMITED SIZE
               '","title":"'            DELIMITED SIZE
               FUNCTION TRIM(HV-TITLE)       DELIMITED SIZE
               '","genre":"'            DELIMITED SIZE
               FUNCTION TRIM(HV-GENRE)       DELIMITED SIZE
               '","platform":"'         DELIMITED SIZE
               FUNCTION TRIM(HV-PLATFORM)    DELIMITED SIZE
               '","releaseDate":"'      DELIMITED SIZE
               FUNCTION TRIM(HV-REL-DATE)    DELIMITED SIZE
               '","windowEnd":"'        DELIMITED SIZE
               FUNCTION TRIM(HV-WIN-END)     DELIMITED SIZE
               '","targetMarket":"'     DELIMITED SIZE
               FUNCTION TRIM(HV-MARKET)      DELIMITED SIZE
               '","status":"'           DELIMITED SIZE
               FUNCTION TRIM(HV-STATUS)      DELIMITED SIZE
               '"}'                     DELIMITED SIZE
               INTO WS-JSON-ROW WITH POINTER WS-JSON-PTR.
           COMPUTE WS-JSON-LEN = WS-JSON-PTR - 1.

      *----------------------------------------------------------------*
      * WRITE-CHANGE-LOG                                               *
      * BEST-EFFORT AUDIT LOGGING - CALLED AFTER A SUCCESSFUL ADD,     *
      * UPD, OR DEL. GETS THE NEXT SEQ_LOG VALUE AND INSERTS ONE ROW   *
      * INTO CHANGE_LOG. SQLCODE IS INTENTIONALLY NOT CHECKED HERE -   *
      * A FAILURE TO LOG SHOULD NEVER FAIL THE MAIN OPERATION, WHICH   *
      * HAS ALREADY COMMITTED SUCCESSFULLY BY THE TIME THIS RUNS.      *
      *----------------------------------------------------------------*
       WRITE-CHANGE-LOG.
           EXEC SQL
             SELECT NEXT VALUE FOR Z73460.SEQ_LOG
             INTO :HV-LOG-ID
             FROM SYSIBM.SYSDUMMY1
           END-EXEC.

           EXEC SQL
             INSERT INTO Z73460.CHANGE_LOG
               (LOG_ID, ENTITY_TYPE, ENTITY_ID, ACTION, DETAILS,
                CHANGED_TS)
             VALUES
               (:HV-LOG-ID, :HV-LOG-ENTITY-TYPE, :HV-LOG-ENTITY-ID,
               :HV-LOG-ACTION, :HV-LOG-DETAILS, CURRENT TIMESTAMP)
           END-EXEC.

      *----------------------------------------------------------------*
      * VALIDATE-DATE-FORMAT                                           *
      * CHECKS WS-DATE-CHECK AGAINST A YYYY-MM-DD MASK: DASH POSITIONS *
      * AT BYTES 5 AND 8, ALL THREE COMPONENTS NUMERIC, MONTH 01-12,   *
      * DAY 01-31 (NO PER-MONTH DAY COUNT CHECK - GOOD ENOUGH TO CATCH *
      * GARBAGE INPUT, NOT A FULL CALENDAR VALIDATOR). SPACES IS       *
      * TREATED AS VALID HERE - IT IS THE CALLER'S JOB TO DECIDE       *
      * WHETHER AN EMPTY DATE IS ALLOWED FOR A GIVEN FIELD.            *
      *----------------------------------------------------------------*
       VALIDATE-DATE-FORMAT.
           MOVE 'Y' TO WS-DATE-OK.
           IF WS-DATE-CHECK = SPACES
               GO TO VALIDATE-DATE-FORMAT-EXIT
           END-IF.
           IF WS-DATE-CHECK(5:1) NOT = '-' OR
              WS-DATE-CHECK(8:1) NOT = '-'
               MOVE 'N' TO WS-DATE-OK
               GO TO VALIDATE-DATE-FORMAT-EXIT
           END-IF.
           MOVE WS-DATE-CHECK(1:4) TO WS-DATE-YYYY.
           MOVE WS-DATE-CHECK(6:2) TO WS-DATE-MM.
           MOVE WS-DATE-CHECK(9:2) TO WS-DATE-DD.
           IF WS-DATE-YYYY NOT NUMERIC OR
              WS-DATE-MM   NOT NUMERIC OR
              WS-DATE-DD   NOT NUMERIC
               MOVE 'N' TO WS-DATE-OK
               GO TO VALIDATE-DATE-FORMAT-EXIT
           END-IF.
           IF WS-DATE-MM < '01' OR WS-DATE-MM > '12'
               MOVE 'N' TO WS-DATE-OK
               GO TO VALIDATE-DATE-FORMAT-EXIT
           END-IF.
           IF WS-DATE-DD < '01' OR WS-DATE-DD > '31'
               MOVE 'N' TO WS-DATE-OK
           END-IF.

       VALIDATE-DATE-FORMAT-EXIT.
           EXIT.
