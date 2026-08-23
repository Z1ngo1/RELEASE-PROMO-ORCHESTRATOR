      *----------------------------------------------------------------*
      * EVTMGR.CBL                                                     *
      * CICS COBOL PROGRAM - EXTERNAL EVENT MANAGER                    *
      *                                                                *
      * ADD/GET/LIST/UPD/DEL FOR Z73460.EXT_EVENT_T VIA CICS WEB       *
      * SUPPORT (TCPIPSERVICE + URIMAP + WEB EXTRACT/READ/SEND, NO     *
      * Z/OS CONNECT). MAIN-LOGIC ROUTES ON WS-HTTP-PATH/WS-HTTP-      *
      * METHOD. EVENTS ARE STANDALONE - NO FK TO RELEASE_T. CLSHBAT    *
      * READS THIS TABLE TO SCORE HOW CLOSE A RELEASE WINDOW SITS TO   *
      * A TRACKED EVENT, BUT NOTHING WRITES BACK TO EXT_EVENT_T FROM   *
      * THE BATCH SIDE.                                                *
      *----------------------------------------------------------------*
       IDENTIFICATION DIVISION.
       PROGRAM-ID. EVTMGR.
       ENVIRONMENT DIVISION.
       DATA DIVISION.
       WORKING-STORAGE SECTION.

       COPY SQLCA.

      *----------------------------------------------------------------*
      * REQUEST FIELDS - POPULATED BY EXTRACT-QUERY-FIELDS FOR GET     *
      * REQUESTS, OR EXTRACT-FORM-FIELDS FOR POST REQUESTS.            *
      *----------------------------------------------------------------*
       01 WS-REQ-EVT-ID         PIC X(10).
       01 WS-REQ-EVT-NAME       PIC X(100).
       01 WS-REQ-EVT-DATE       PIC X(10).
       01 WS-REQ-EVT-END        PIC X(10).
       01 WS-REQ-GENRE          PIC X(20).
       01 WS-REQ-MARKET         PIC X(20).
       01 WS-REQ-SEVERITY       PIC X(10).

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
       01 HV-EVT-ID            PIC X(10).
       01 HV-EVT-NAME          PIC X(100).
       01 HV-EVT-DATE          PIC X(10).
       01 HV-EVT-END           PIC X(10).
       01 HV-GENRE             PIC X(20).
       01 HV-MARKET            PIC X(20).
       01 HV-SEVERITY          PIC X(10).
       01 HV-NEXT-SEQ          PIC S9(18) COMP.
       01 HV-LOG-ID            PIC S9(18) COMP.
       01 HV-LOG-ENTITY-TYPE   PIC X(10).
       01 HV-LOG-ENTITY-ID     PIC X(10).
       01 HV-LOG-ACTION        PIC X(6).
       01 HV-LOG-DETAILS       PIC X(200).

      *----------------------------------------------------------------*
      * WORKING VARIABLES                                              *
      *----------------------------------------------------------------*
       01 WS-SQLCODE-DISP      PIC S9(9) SIGN LEADING SEPARATE.
       01 WS-JSON-ROW          PIC X(400).
       01 WS-FIRST-ROW         PIC X(1) VALUE 'Y'.
       01 WS-SEQ-CHAR          PIC Z(6)9.
       01 WS-NEW-ID            PIC X(10).

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
      * NOTE /LIST DOES NOT CALL EXTRACT-QUERY-FIELDS - LIST-EVENTS    *
      * TAKES NO FILTER AND RETURNS EVERY ROW, UNLIKE PROMGR'S LIST    *
      * WHICH IS SCOPED TO ONE RELEASE. EVERY BRANCH ENDS UP AT WEB    *
      * SEND, WHICH RETURNS WHATEVER JSON ENDED UP IN WS-RESPONSE.     *
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
               WHEN WS-HTTP-PATH(1:12) = '/evtmgr/list'
                 PERFORM LIST-EVENTS THRU LIST-EVENTS-EXIT
               WHEN WS-HTTP-PATH(1:11) = '/evtmgr/get'
                 PERFORM EXTRACT-QUERY-FIELDS
                 PERFORM GET-EVENT
               WHEN WS-HTTP-METHOD = 'POST' AND
                    WS-HTTP-PATH(1:11) = '/evtmgr/add'
                 PERFORM EXTRACT-FORM-FIELDS
                 PERFORM ADD-EVENT THRU ADD-EVENT-EXIT
               WHEN WS-HTTP-METHOD = 'POST' AND
                    WS-HTTP-PATH(1:11) = '/evtmgr/upd'
                 PERFORM EXTRACT-FORM-FIELDS
                 PERFORM UPD-EVENT THRU UPD-EVENT-EXIT
               WHEN WS-HTTP-METHOD = 'POST' AND
                    WS-HTTP-PATH(1:11) = '/evtmgr/del'
                 PERFORM EXTRACT-FORM-FIELDS
                 PERFORM DEL-EVENT
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
      * EXTRACT-QUERY-FIELDS - FOR GET REQUESTS, E.G. ?id=EVT1. NOT    *
      * CALLED BY LIST-EVENTS, WHICH TAKES NO FILTER.                  *
      *----------------------------------------------------------------*
       EXTRACT-QUERY-FIELDS.
           MOVE SPACES TO WS-REQ-EVT-ID.
           MOVE 10 TO WS-FIELD-LEN.
           EXEC CICS WEB READ
                     QUERYPARM('id')
                     VALUE(WS-REQ-EVT-ID)
                     VALUELENGTH(WS-FIELD-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

      *----------------------------------------------------------------*
      * EXTRACT-FORM-FIELDS - FOR POST REQUESTS, FORM-ENCODED BODY     *
      *----------------------------------------------------------------*
       EXTRACT-FORM-FIELDS.
           MOVE SPACES TO WS-REQ-EVT-ID WS-REQ-EVT-NAME WS-REQ-EVT-DATE
                          WS-REQ-EVT-END WS-REQ-GENRE WS-REQ-MARKET
                          WS-REQ-SEVERITY.

           MOVE 10 TO WS-FIELD-LEN.
           EXEC CICS WEB READ FORMFIELD('id')
                     VALUE(WS-REQ-EVT-ID) VALUELENGTH(WS-FIELD-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

           MOVE 100 TO WS-FIELD-LEN.
           EXEC CICS WEB READ FORMFIELD('evtName')
                     VALUE(WS-REQ-EVT-NAME) VALUELENGTH(WS-FIELD-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

           MOVE 10 TO WS-FIELD-LEN.
           EXEC CICS WEB READ FORMFIELD('evtDate')
                     VALUE(WS-REQ-EVT-DATE) VALUELENGTH(WS-FIELD-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

           MOVE 10 TO WS-FIELD-LEN.
           EXEC CICS WEB READ FORMFIELD('evtEnd')
                     VALUE(WS-REQ-EVT-END) VALUELENGTH(WS-FIELD-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

           MOVE 20 TO WS-FIELD-LEN.
           EXEC CICS WEB READ FORMFIELD('genre')
                     VALUE(WS-REQ-GENRE) VALUELENGTH(WS-FIELD-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

           MOVE 20 TO WS-FIELD-LEN.
           EXEC CICS WEB READ FORMFIELD('market')
                     VALUE(WS-REQ-MARKET) VALUELENGTH(WS-FIELD-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

           MOVE 10 TO WS-FIELD-LEN.
           EXEC CICS WEB READ FORMFIELD('severity')
                     VALUE(WS-REQ-SEVERITY) VALUELENGTH(WS-FIELD-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

      *----------------------------------------------------------------*
      * VALIDATE-EVENT-INPUT                                           *
      * SHARED VALIDATION FOR ADD-EVENT AND UPD-EVENT. GENRE HERE      *
      * ALLOWS GLOBAL AS AN EXTRA OPTION ON TOP OF THE USUAL LIST -    *
      * THAT DIFFERS FROM RELSMGR'S GENRE CHECK, WHERE A RELEASE       *
      * CANNOT BE GLOBAL BUT AN EVENT CAN (E.G. A WORLDWIDE HOLIDAY    *
      * THAT ISN'T TIED TO ANY ONE GENRE). BOTH EVTDATE AND EVTEND ARE *
      * FORMAT-CHECKED, BUT EVTEND IS OPTIONAL (SPACES PASSES).        *
      *                                                                *
      * CALL WITH PERFORM ... THRU VALIDATE-EVENT-INPUT-EXIT; CHECK    *
      * WS-DATE-OK ON RETURN THE SAME WAY AS RELSMGR'S EQUIVALENT.     *
      *----------------------------------------------------------------*
       VALIDATE-EVENT-INPUT.
           MOVE 'Y' TO WS-DATE-OK.

           EVALUATE FUNCTION TRIM(WS-REQ-GENRE)
               WHEN 'DRAMA' WHEN 'COMEDY' WHEN 'SPORT'
               WHEN 'DOCUMENTARY' WHEN 'THRILLER' WHEN 'OTHER' WHEN
                    'GLOBAL'
                 CONTINUE
               WHEN OTHER
                 MOVE '{"error":"Invalid genre"}' TO WS-RESPONSE
                 MOVE 'N' TO WS-DATE-OK
                 GO TO VALIDATE-EVENT-INPUT-EXIT
           END-EVALUATE.

           EVALUATE FUNCTION TRIM(WS-REQ-MARKET)
               WHEN 'US' WHEN 'EU' WHEN 'APAC' WHEN 'LATAM' WHEN
                    'GLOBAL'
                 CONTINUE
               WHEN OTHER
                 MOVE '{"error":"Invalid market"}' TO WS-RESPONSE
                 MOVE 'N' TO WS-DATE-OK
                 GO TO VALIDATE-EVENT-INPUT-EXIT
           END-EVALUATE.

           IF WS-REQ-EVT-DATE = SPACES
              MOVE '{"error":"evtDate is required"}' TO WS-RESPONSE
              MOVE 'N' TO WS-DATE-OK
              GO TO VALIDATE-EVENT-INPUT-EXIT
           END-IF.
           MOVE WS-REQ-EVT-DATE TO WS-DATE-CHECK.
           PERFORM VALIDATE-DATE-FORMAT THRU VALIDATE-DATE-FORMAT-EXIT.
           IF WS-DATE-OK = 'N'
              MOVE '{"error":"Invalid evtDate, expected YYYY-MM-DD"}'
                   TO WS-RESPONSE
              GO TO VALIDATE-EVENT-INPUT-EXIT
           END-IF.

           MOVE WS-REQ-EVT-END TO WS-DATE-CHECK.
           PERFORM VALIDATE-DATE-FORMAT THRU VALIDATE-DATE-FORMAT-EXIT.
           IF WS-DATE-OK = 'N'
              MOVE '{"error":"Invalid evtEnd, expected YYYY-MM-DD"}'
                   TO WS-RESPONSE
           END-IF.

       VALIDATE-EVENT-INPUT-EXIT.
           EXIT.

      *----------------------------------------------------------------*
      * ADD-EVENT                                                      *
      * VALIDATES INPUT, GETS THE NEXT SEQ_EVENT VALUE, AND BUILDS A   *
      * SHORT ID LIKE EVT6 THE SAME WAY RELSMGR/PROMGR DO. TWO INSERT  *
      * BLOCKS HANDLE EVTEND BEING OPTIONAL - DB2 NEEDS AN EXPLICIT    *
      * NULL LITERAL WHEN THE FIELD WAS LEFT BLANK, NOT AN EMPTY HOST  *
      * VARIABLE. ON SUCCESS, ALSO WRITES AN ADD ENTRY TO CHANGE_LOG.  *
      *----------------------------------------------------------------*
       ADD-EVENT.
           PERFORM VALIDATE-EVENT-INPUT THRU VALIDATE-EVENT-INPUT-EXIT.
           IF WS-DATE-OK = 'N'
              GO TO ADD-EVENT-EXIT
           END-IF.

           EXEC SQL
             SELECT NEXT VALUE FOR Z73460.SEQ_EVENT
             INTO :HV-NEXT-SEQ
             FROM SYSIBM.SYSDUMMY1
           END-EXEC.

           IF SQLCODE NOT = 0
              MOVE '{"error":"SEQ fetch failed"}' TO WS-RESPONSE
              GO TO ADD-EVENT-EXIT
           END-IF.

           MOVE SPACES      TO WS-NEW-ID.
           MOVE HV-NEXT-SEQ TO WS-SEQ-CHAR.
           STRING 'EVT'       DELIMITED SIZE
                  FUNCTION TRIM(WS-SEQ-CHAR) DELIMITED SIZE
                  INTO WS-NEW-ID.

           MOVE FUNCTION TRIM(WS-REQ-EVT-NAME) TO HV-EVT-NAME.
           MOVE WS-REQ-EVT-DATE                TO HV-EVT-DATE.
           MOVE WS-REQ-EVT-END                 TO HV-EVT-END.
           MOVE FUNCTION TRIM(WS-REQ-GENRE)    TO HV-GENRE.
           MOVE FUNCTION TRIM(WS-REQ-MARKET)   TO HV-MARKET.
           MOVE FUNCTION TRIM(WS-REQ-SEVERITY) TO HV-SEVERITY.
           MOVE WS-NEW-ID                      TO HV-EVT-ID.

           IF WS-REQ-EVT-END = SPACES
               EXEC SQL
                 INSERT INTO Z73460.EXT_EVENT_T
                   (EVENT_ID, EVENT_NAME, EVENT_DATE, EVENT_END,
                    IMPACT_GENRE, IMPACT_MARKET, SEVERITY)
                 VALUES
                   (:HV-EVT-ID, :HV-EVT-NAME, :HV-EVT-DATE, NULL,
                    :HV-GENRE, :HV-MARKET, :HV-SEVERITY)
               END-EXEC
           ELSE
               EXEC SQL
                 INSERT INTO Z73460.EXT_EVENT_T
                   (EVENT_ID, EVENT_NAME, EVENT_DATE, EVENT_END,
                    IMPACT_GENRE, IMPACT_MARKET, SEVERITY)
                 VALUES
                   (:HV-EVT-ID, :HV-EVT-NAME, :HV-EVT-DATE, :HV-EVT-END,
                    :HV-GENRE, :HV-MARKET, :HV-SEVERITY)
               END-EXEC
           END-IF.

           IF SQLCODE = 0
              STRING '{"eventId":"'   DELIMITED SIZE
                     WS-NEW-ID        DELIMITED SPACE
                     '","message":"Event added"}' DELIMITED SIZE
                     INTO WS-RESPONSE
              MOVE 'EVENT'   TO HV-LOG-ENTITY-TYPE
              MOVE WS-NEW-ID TO HV-LOG-ENTITY-ID
              MOVE 'ADD'     TO HV-LOG-ACTION
              MOVE SPACES    TO HV-LOG-DETAILS
              STRING 'name=' DELIMITED SIZE
                     FUNCTION TRIM(HV-EVT-NAME) DELIMITED SIZE
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

       ADD-EVENT-EXIT.
           EXIT.

      *----------------------------------------------------------------*
      * GET-EVENT - SELECT SINGLE ROW BY EVENT_ID, RETURN AS JSON.     *
      * EVENT_END IS NULLABLE, HENCE THE COALESCE TO "" IN THE SELECT. *
      *----------------------------------------------------------------*
       GET-EVENT.
           MOVE FUNCTION TRIM(WS-REQ-EVT-ID) TO HV-EVT-ID.

           EXEC SQL
             SELECT EVENT_ID, EVENT_NAME, CHAR(EVENT_DATE,ISO),
                    COALESCE(CHAR(EVENT_END,ISO),""), IMPACT_GENRE,
                    IMPACT_MARKET, SEVERITY
             INTO   :HV-EVT-ID, :HV-EVT-NAME, :HV-EVT-DATE, :HV-EVT-END,
                    :HV-GENRE, :HV-MARKET, :HV-SEVERITY
             FROM   Z73460.EXT_EVENT_T
             WHERE  EVENT_ID = :HV-EVT-ID
           END-EXEC.

           EVALUATE SQLCODE
               WHEN 0
                 PERFORM BUILD-EVENT-JSON-OBJ
                 MOVE WS-JSON-ROW TO WS-RESPONSE
               WHEN 100
                 MOVE '{"error":"Event not found"}' TO WS-RESPONSE
               WHEN OTHER
                 MOVE SQLCODE TO WS-SQLCODE-DISP
                 STRING '{"error":"SELECT failed","sqlcode":"'
                                         DELIMITED SIZE
                        WS-SQLCODE-DISP  DELIMITED SPACE
                        '"}'             DELIMITED SIZE
                        INTO WS-RESPONSE
           END-EVALUATE.

      *----------------------------------------------------------------*
      * LIST-EVENTS                                                    *
      * CURSOR SCAN OF EVERY ROW IN EXT_EVENT_T, ORDERED BY EVENT      *
      * DATE - NO FILTER, UNLIKE PROMGR'S LIST-PROMOS WHICH IS SCOPED  *
      * TO ONE RELEASE. SAME POINTER-BASED JSON ARRAY BUILD AS THE     *
      * OTHER TWO PROGRAMS' LIST PARAGRAPHS.                           *
      *----------------------------------------------------------------*
       LIST-EVENTS.
           MOVE SPACES TO WS-RESPONSE.
           MOVE 1     TO WS-RESP-PTR.
           MOVE 'Y'   TO WS-FIRST-ROW.

           STRING '[' DELIMITED SIZE
                  INTO WS-RESPONSE WITH POINTER WS-RESP-PTR.

           EXEC SQL DECLARE EVT-CURSOR CURSOR FOR
             SELECT EVENT_ID, EVENT_NAME, CHAR(EVENT_DATE,ISO),
                    COALESCE(CHAR(EVENT_END,ISO),""), IMPACT_GENRE,
                    IMPACT_MARKET, SEVERITY
             FROM   Z73460.EXT_EVENT_T
             ORDER BY EVENT_DATE ASC
           END-EXEC.

           EXEC SQL
             OPEN EVT-CURSOR
           END-EXEC.

           IF SQLCODE NOT = 0
              MOVE SQLCODE TO WS-SQLCODE-DISP
              STRING '{"error":"OPEN CURSOR failed","sqlcode":"'
                                      DELIMITED SIZE
                     WS-SQLCODE-DISP  DELIMITED SPACE
                     '"}'             DELIMITED SIZE
                     INTO WS-RESPONSE
              GO TO LIST-EVENTS-EXIT
           END-IF.

           PERFORM UNTIL SQLCODE NOT = 0
               EXEC SQL FETCH EVT-CURSOR
                 INTO :HV-EVT-ID, :HV-EVT-NAME, :HV-EVT-DATE,
                      :HV-EVT-END, :HV-GENRE, :HV-MARKET, :HV-SEVERITY
               END-EXEC
               IF SQLCODE = 0
                  PERFORM BUILD-EVENT-JSON-OBJ
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
             CLOSE EVT-CURSOR
           END-EXEC.

           STRING ']' DELIMITED SIZE
                  INTO WS-RESPONSE WITH POINTER WS-RESP-PTR.

       LIST-EVENTS-EXIT.
           EXIT.

      *----------------------------------------------------------------*
      * UPD-EVENT                                                      *
      * UPDATES EVERY EDITABLE FIELD - EVTNAME, EVTDATE, EVTEND,       *
      * GENRE, MARKET, SEVERITY. RUNS THE SAME VALIDATE-EVENT-INPUT    *
      * CHECKS AS ADD-EVENT. TWO UPDATE BLOCKS HANDLE EVTEND THE SAME  *
      * WAY ADD-EVENT DOES - AN EXPLICIT NULL WHEN THE CALLER SENT     *
      * SPACES, SO CLEARING EVTEND ON AN EXISTING EVENT ACTUALLY       *
      * WORKS (NOT JUST SETTING IT ON ADD). ON SUCCESS, ALSO WRITES    *
      * AN UPD ENTRY TO CHANGE_LOG.                                    *
      *----------------------------------------------------------------*
       UPD-EVENT.
           PERFORM VALIDATE-EVENT-INPUT THRU VALIDATE-EVENT-INPUT-EXIT.
           IF WS-DATE-OK = 'N'
              GO TO UPD-EVENT-EXIT
           END-IF.

           MOVE FUNCTION TRIM(WS-REQ-EVT-ID)   TO HV-EVT-ID.
           MOVE FUNCTION TRIM(WS-REQ-EVT-NAME) TO HV-EVT-NAME.
           MOVE WS-REQ-EVT-DATE                TO HV-EVT-DATE.
           MOVE WS-REQ-EVT-END                 TO HV-EVT-END.
           MOVE FUNCTION TRIM(WS-REQ-GENRE)    TO HV-GENRE.
           MOVE FUNCTION TRIM(WS-REQ-MARKET)   TO HV-MARKET.
           MOVE FUNCTION TRIM(WS-REQ-SEVERITY) TO HV-SEVERITY.

           IF WS-REQ-EVT-END = SPACES
               EXEC SQL
                 UPDATE Z73460.EXT_EVENT_T
                 SET    EVENT_NAME    = :HV-EVT-NAME,
                        EVENT_DATE    = :HV-EVT-DATE,
                        EVENT_END     = NULL,
                        IMPACT_GENRE  = :HV-GENRE,
                        IMPACT_MARKET = :HV-MARKET,
                        SEVERITY      = :HV-SEVERITY
                 WHERE  EVENT_ID = :HV-EVT-ID
               END-EXEC
           ELSE
               EXEC SQL
                 UPDATE Z73460.EXT_EVENT_T
                 SET    EVENT_NAME    = :HV-EVT-NAME,
                        EVENT_DATE    = :HV-EVT-DATE,
                        EVENT_END     = :HV-EVT-END,
                        IMPACT_GENRE  = :HV-GENRE,
                        IMPACT_MARKET = :HV-MARKET,
                        SEVERITY      = :HV-SEVERITY
                 WHERE  EVENT_ID = :HV-EVT-ID
               END-EXEC
           END-IF.

           EVALUATE SQLCODE
               WHEN 0
                 STRING '{"eventId":"'     DELIMITED SIZE
                        HV-EVT-ID          DELIMITED SPACE
                        '","message":"Event updated"}' DELIMITED SIZE
                        INTO WS-RESPONSE
                 MOVE 'EVENT'   TO HV-LOG-ENTITY-TYPE
                 MOVE HV-EVT-ID TO HV-LOG-ENTITY-ID
                 MOVE 'UPD'     TO HV-LOG-ACTION
                 MOVE SPACES    TO HV-LOG-DETAILS
                 STRING 'severity set to ' DELIMITED SIZE
                        FUNCTION TRIM(HV-SEVERITY) DELIMITED SIZE
                        INTO HV-LOG-DETAILS
                 PERFORM WRITE-CHANGE-LOG
               WHEN 100
                 MOVE '{"error":"Event not found"}' TO WS-RESPONSE
               WHEN OTHER
                 MOVE SQLCODE TO WS-SQLCODE-DISP
                 STRING '{"error":"UPDATE failed","sqlcode":"'
                                         DELIMITED SIZE
                        WS-SQLCODE-DISP  DELIMITED SPACE
                        '"}'             DELIMITED SIZE
                        INTO WS-RESPONSE
           END-EVALUATE.

       UPD-EVENT-EXIT.
           EXIT.

      *----------------------------------------------------------------*
      * DEL-EVENT                                                      *
      * PLAIN DELETE BY EVENT_ID. NO TABLE HAS AN FK TO EXT_EVENT_T,   *
      * SO NO -532 HANDLING IS NEEDED HERE. NOTE THIS DOES NOT         *
      * RETROACTIVELY RECALCULATE ANY CLASH_SCORE_T ROWS THAT WERE     *
      * SCORED USING THIS EVENT'S PROXIMITY - RERUN CLSHBAT IF THAT    *
      * MATTERS. ON SUCCESS, ALSO WRITES A DEL ENTRY TO CHANGE_LOG.    *
      *----------------------------------------------------------------*
       DEL-EVENT.
           MOVE FUNCTION TRIM(WS-REQ-EVT-ID) TO HV-EVT-ID.

           EXEC SQL
             DELETE FROM Z73460.EXT_EVENT_T
             WHERE EVENT_ID = :HV-EVT-ID
           END-EXEC.

           EVALUATE SQLCODE
               WHEN 0
                 STRING '{"eventId":"'   DELIMITED SIZE
                        HV-EVT-ID        DELIMITED SPACE
                        '","message":"Event deleted"}' DELIMITED SIZE
                        INTO WS-RESPONSE
                 MOVE 'EVENT'   TO HV-LOG-ENTITY-TYPE
                 MOVE HV-EVT-ID TO HV-LOG-ENTITY-ID
                 MOVE 'DEL'     TO HV-LOG-ACTION
                 MOVE SPACES    TO HV-LOG-DETAILS
                 STRING 'event deleted' DELIMITED SIZE
                        INTO HV-LOG-DETAILS
                 PERFORM WRITE-CHANGE-LOG
               WHEN 100
                 MOVE '{"error":"Event not found"}' TO WS-RESPONSE
               WHEN OTHER
                 MOVE SQLCODE TO WS-SQLCODE-DISP
                 STRING '{"error":"DELETE failed","sqlcode":"'
                                         DELIMITED SIZE
                        WS-SQLCODE-DISP  DELIMITED SPACE
                        '"}'             DELIMITED SIZE
                        INTO WS-RESPONSE
           END-EVALUATE.

      *----------------------------------------------------------------*
      * BUILD-EVENT-JSON-OBJ                                           *
      * BUILDS ONE JSON OBJECT INTO WS-JSON-ROW FROM THE CURRENT HOST  *
      * VARIABLES. USED BY GET-EVENT (SINGLE OBJECT) AND LIST-EVENTS   *
      * (ONE CALL PER FETCHED ROW, APPENDED TO AN ARRAY).              *
      *----------------------------------------------------------------*
       BUILD-EVENT-JSON-OBJ.
           MOVE SPACES TO WS-JSON-ROW.
           MOVE 1      TO WS-JSON-PTR.
           STRING
               '{"eventId":"'       DELIMITED SIZE
               FUNCTION TRIM(HV-EVT-ID)      DELIMITED SIZE
               '","eventName":"'    DELIMITED SIZE
               FUNCTION TRIM(HV-EVT-NAME)    DELIMITED SIZE
               '","eventDate":"'    DELIMITED SIZE
               FUNCTION TRIM(HV-EVT-DATE)    DELIMITED SIZE
               '","eventEnd":"'     DELIMITED SIZE
               FUNCTION TRIM(HV-EVT-END)     DELIMITED SIZE
               '","impactGenre":"'  DELIMITED SIZE
               FUNCTION TRIM(HV-GENRE)       DELIMITED SIZE
               '","impactMarket":"' DELIMITED SIZE
               FUNCTION TRIM(HV-MARKET)      DELIMITED SIZE
               '","severity":"'     DELIMITED SIZE
               FUNCTION TRIM(HV-SEVERITY)    DELIMITED SIZE
               '"}'                 DELIMITED SIZE
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
      * DAY 01-31 (NO PER-MONTH DAY COUNT CHECK). SPACES IS TREATED    *
      * AS VALID HERE - THE CALLER DECIDES IF AN EMPTY DATE IS OK.     *
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
