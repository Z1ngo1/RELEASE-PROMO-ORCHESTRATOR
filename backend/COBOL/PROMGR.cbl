      *----------------------------------------------------------------*
      * PROMGR.CBL                                                     *
      * CICS COBOL PROGRAM - PROMO CHECKLIST MANAGER                   *
      *                                                                *
      * ADD/GET/LIST/UPD/DEL FOR Z73460.PROMO_T VIA CICS WEB SUPPORT   *
      * (TCPIPSERVICE + URIMAP + WEB EXTRACT/READ/SEND, NO Z/OS        *
      * CONNECT). MAIN-LOGIC ROUTES ON WS-HTTP-PATH/WS-HTTP-METHOD.    *
      * EVERY PROMO ITEM BELONGS TO A RELEASE VIA RELEASE_ID (FK) -    *
      * THAT LINK IS SET ON ADD AND NEVER CHANGES ON UPD, MOVING A     *
      * PROMO TO A DIFFERENT RELEASE IS TREATED AS OUT OF SCOPE.       *
      *----------------------------------------------------------------*
       IDENTIFICATION DIVISION.
       PROGRAM-ID. PROMGR.
       ENVIRONMENT DIVISION.
       DATA DIVISION.
       WORKING-STORAGE SECTION.

       COPY SQLCA.

      *----------------------------------------------------------------*
      * REQUEST FIELDS - POPULATED BY EXTRACT-QUERY-FIELDS FOR GET     *
      * REQUESTS, OR EXTRACT-FORM-FIELDS FOR POST REQUESTS.            *
      *----------------------------------------------------------------*
       01 WS-REQ-PROMO-ID       PIC X(10).
       01 WS-REQ-REL-ID         PIC X(10).
       01 WS-REQ-ITEM-NAME      PIC X(80).
       01 WS-REQ-STATUS         PIC X(10).
       01 WS-REQ-DUE-DATE       PIC X(10).
       01 WS-REQ-OWNER          PIC X(50).

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
       01 HV-PROMO-ID          PIC X(10).
       01 HV-RELEASE-ID        PIC X(10).
       01 HV-ITEM-NAME         PIC X(80).
       01 HV-STATUS            PIC X(10).
       01 HV-DUE-DATE          PIC X(10).
       01 HV-OWNER             PIC X(50).
       01 HV-UPDATED-TS        PIC X(26).
       01 HV-NEXT-SEQ          PIC S9(18) COMP.
       01 HV-DUE-DATE-IND      PIC S9(4) COMP.
       01 HV-OWNER-IND         PIC S9(4) COMP.
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
               WHEN WS-HTTP-PATH(1:12) = '/promgr/list'
                 PERFORM EXTRACT-QUERY-FIELDS
                 PERFORM LIST-PROMOS THRU LIST-PROMOS-EXIT
               WHEN WS-HTTP-PATH(1:11) = '/promgr/get'
                 PERFORM EXTRACT-QUERY-FIELDS
                 PERFORM GET-PROMO
               WHEN WS-HTTP-METHOD = 'POST' AND
                    WS-HTTP-PATH(1:11) = '/promgr/add'
                 PERFORM EXTRACT-FORM-FIELDS
                 PERFORM ADD-PROMO THRU ADD-PROMO-EXIT
               WHEN WS-HTTP-METHOD = 'POST' AND
                    WS-HTTP-PATH(1:11) = '/promgr/upd'
                 PERFORM EXTRACT-FORM-FIELDS
                 PERFORM UPD-PROMO THRU UPD-PROMO-EXIT
               WHEN WS-HTTP-METHOD = 'POST' AND
                    WS-HTTP-PATH(1:11) = '/promgr/del'
                 PERFORM EXTRACT-FORM-FIELDS
                 PERFORM DEL-PROMO
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
      * EXTRACT-QUERY-FIELDS - FOR GET REQUESTS: /promgr/get?id=PRO1   *
      * OR /promgr/list?relId=REL1. BOTH FIELDS ARE READ EVERY TIME -  *
      * WHICHEVER ONE THE CALLER DIDN'T SEND JUST STAYS SPACES.        *
      *----------------------------------------------------------------*
       EXTRACT-QUERY-FIELDS.
           MOVE SPACES TO WS-REQ-PROMO-ID WS-REQ-REL-ID.

           MOVE 10 TO WS-FIELD-LEN.
           EXEC CICS WEB READ
                     QUERYPARM('id')
                     VALUE(WS-REQ-PROMO-ID)
                     VALUELENGTH(WS-FIELD-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

           MOVE 10 TO WS-FIELD-LEN.
           EXEC CICS WEB READ
                     QUERYPARM('relId')
                     VALUE(WS-REQ-REL-ID)
                     VALUELENGTH(WS-FIELD-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

      *----------------------------------------------------------------*
      * EXTRACT-FORM-FIELDS - FOR POST REQUESTS, FORM-ENCODED BODY     *
      *----------------------------------------------------------------*
       EXTRACT-FORM-FIELDS.
           MOVE SPACES TO WS-REQ-PROMO-ID WS-REQ-REL-ID WS-REQ-ITEM-NAME
                          WS-REQ-STATUS WS-REQ-DUE-DATE WS-REQ-OWNER.

           MOVE 10 TO WS-FIELD-LEN.
           EXEC CICS WEB READ FORMFIELD('id')
                     VALUE(WS-REQ-PROMO-ID) VALUELENGTH(WS-FIELD-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

           MOVE 10 TO WS-FIELD-LEN.
           EXEC CICS WEB READ FORMFIELD('relId')
                     VALUE(WS-REQ-REL-ID) VALUELENGTH(WS-FIELD-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

           MOVE 80 TO WS-FIELD-LEN.
           EXEC CICS WEB READ FORMFIELD('itemName')
                     VALUE(WS-REQ-ITEM-NAME) VALUELENGTH(WS-FIELD-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

           MOVE 10 TO WS-FIELD-LEN.
           EXEC CICS WEB READ FORMFIELD('status')
                     VALUE(WS-REQ-STATUS) VALUELENGTH(WS-FIELD-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

           MOVE 10 TO WS-FIELD-LEN.
           EXEC CICS WEB READ FORMFIELD('dueDate')
                     VALUE(WS-REQ-DUE-DATE) VALUELENGTH(WS-FIELD-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

           MOVE 50 TO WS-FIELD-LEN.
           EXEC CICS WEB READ FORMFIELD('owner')
                     VALUE(WS-REQ-OWNER) VALUELENGTH(WS-FIELD-LEN)
                     RESP(WS-CICS-RESP)
           END-EXEC.

      *----------------------------------------------------------------*
      * ADD-PROMO                                                      *
      * VALIDATES DUEDATE FORMAT (OPTIONAL FIELD - SPACES PASSES THE   *
      * CHECK, SEE VALIDATE-DATE-FORMAT), THEN GETS THE NEXT SEQ_PROMO *
      * VALUE AND BUILDS A SHORT ID LIKE PRO6 THE SAME WAY RELSMGR     *
      * BUILDS REL IDS. TWO SEPARATE INSERT BLOCKS HANDLE THE CASE     *
      * WHERE DUEDATE WAS LEFT BLANK - DB2 NEEDS AN EXPLICIT NULL      *
      * LITERAL THERE, NOT AN EMPTY HOST VARIABLE, SO THE BRANCH       *
      * PICKS WHICH INSERT TO RUN BASED ON WS-REQ-DUE-DATE. ON         *
      * SUCCESS, ALSO WRITES AN ADD ENTRY TO CHANGE_LOG.               *
      *----------------------------------------------------------------*
       ADD-PROMO.
           MOVE WS-REQ-DUE-DATE TO WS-DATE-CHECK.
           PERFORM VALIDATE-DATE-FORMAT THRU VALIDATE-DATE-FORMAT-EXIT.
           IF WS-DATE-OK = 'N'
              MOVE '{"error":"Invalid dueDate, expected YYYY-MM-DD"}'
                   TO WS-RESPONSE
              GO TO ADD-PROMO-EXIT
           END-IF.

           EXEC SQL
             SELECT NEXT VALUE FOR Z73460.SEQ_PROMO
             INTO :HV-NEXT-SEQ
             FROM SYSIBM.SYSDUMMY1
           END-EXEC.

           IF SQLCODE NOT = 0
              MOVE '{"error":"SEQ fetch failed"}' TO WS-RESPONSE
              GO TO ADD-PROMO-EXIT
           END-IF.

           MOVE SPACES      TO WS-NEW-ID.
           MOVE HV-NEXT-SEQ TO WS-SEQ-CHAR.
           STRING 'PRO'                      DELIMITED SIZE
                  FUNCTION TRIM(WS-SEQ-CHAR) DELIMITED SIZE
                  INTO WS-NEW-ID.

           MOVE FUNCTION TRIM(WS-REQ-REL-ID)      TO HV-RELEASE-ID.
           MOVE FUNCTION TRIM(WS-REQ-ITEM-NAME)   TO HV-ITEM-NAME.
           MOVE 'PENDING'                         TO HV-STATUS.
           MOVE WS-REQ-DUE-DATE                   TO HV-DUE-DATE.
           MOVE FUNCTION TRIM(WS-REQ-OWNER)       TO HV-OWNER.
           MOVE WS-NEW-ID                         TO HV-PROMO-ID.

           IF WS-REQ-DUE-DATE = SPACES
               EXEC SQL
                 INSERT INTO Z73460.PROMO_T
                   (PROMO_ID, RELEASE_ID, ITEM_NAME, STATUS, DUE_DATE,
                   OWNER, UPDATED_TS)
                 VALUES
                   (:HV-PROMO-ID, :HV-RELEASE-ID, :HV-ITEM-NAME,
                   :HV-STATUS, NULL, :HV-OWNER, CURRENT TIMESTAMP)
               END-EXEC
           ELSE
               EXEC SQL
                 INSERT INTO Z73460.PROMO_T
                   (PROMO_ID, RELEASE_ID, ITEM_NAME, STATUS, DUE_DATE,
                    OWNER, UPDATED_TS)
                 VALUES
                   (:HV-PROMO-ID, :HV-RELEASE-ID, :HV-ITEM-NAME,
                    :HV-STATUS, :HV-DUE-DATE, :HV-OWNER,
                    CURRENT TIMESTAMP)
               END-EXEC
           END-IF.

           IF SQLCODE = 0
              STRING '{"promoId":"'   DELIMITED SIZE
                     WS-NEW-ID        DELIMITED SPACE
                     '","message":"Promo item added"}'
                                      DELIMITED SIZE
                     INTO WS-RESPONSE
              MOVE 'PROMO'   TO HV-LOG-ENTITY-TYPE
              MOVE WS-NEW-ID TO HV-LOG-ENTITY-ID
              MOVE 'ADD'     TO HV-LOG-ACTION
              MOVE SPACES    TO HV-LOG-DETAILS
              STRING 'item=' DELIMITED SIZE
                     FUNCTION TRIM(HV-ITEM-NAME) DELIMITED SIZE
                     ' release=' DELIMITED SIZE
                     FUNCTION TRIM(HV-RELEASE-ID) DELIMITED SIZE
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

       ADD-PROMO-EXIT.
           EXIT.

      *----------------------------------------------------------------*
      * GET-PROMO - SELECT SINGLE ROW BY PROMO_ID, RETURN AS JSON.     *
      * DUEDATE AND OWNER ARE NULLABLE, SO BOTH GET NULL INDICATOR     *
      * HOST VARIABLES - THESE ARE SET BY DB2 BUT NOT ACTUALLY         *
      * CHECKED HERE, SINCE COALESCE IN THE SELECT ALREADY GUARANTEES  *
      * A NON-NULL '' STRING WHEN THE UNDERLYING COLUMN IS NULL.       *
      *----------------------------------------------------------------*
       GET-PROMO.
           MOVE FUNCTION TRIM(WS-REQ-PROMO-ID) TO HV-PROMO-ID.

           EXEC SQL
             SELECT PROMO_ID, RELEASE_ID, ITEM_NAME, STATUS,
                    COALESCE(CHAR(DUE_DATE,ISO),""),
                    COALESCE(TRIM(OWNER),""), CHAR(UPDATED_TS)
             INTO   :HV-PROMO-ID, :HV-RELEASE-ID, :HV-ITEM-NAME,
                    :HV-STATUS, :HV-DUE-DATE :HV-DUE-DATE-IND,
                    :HV-OWNER :HV-OWNER-IND, :HV-UPDATED-TS
             FROM   Z73460.PROMO_T
             WHERE  PROMO_ID = :HV-PROMO-ID
           END-EXEC.

           EVALUATE SQLCODE
               WHEN 0
                 PERFORM BUILD-PROMO-JSON-OBJ
                 MOVE WS-JSON-ROW TO WS-RESPONSE
               WHEN 100
                 MOVE '{"error":"Promo item not found"}' TO WS-RESPONSE
               WHEN OTHER
                 MOVE SQLCODE TO WS-SQLCODE-DISP
                 STRING '{"error":"SELECT failed","sqlcode":"'
                                         DELIMITED SIZE
                        WS-SQLCODE-DISP  DELIMITED SPACE
                        '"}'              DELIMITED SIZE
                        INTO WS-RESPONSE
           END-EVALUATE.

      *----------------------------------------------------------------*
      * LIST-PROMOS                                                    *
      * CURSOR SCAN FILTERED TO ONE RELEASE_ID, ORDERED BY PROMO_ID.   *
      * SAME POINTER-BASED JSON ARRAY BUILD AS RELSMGR'S LIST-RELEASES *
      * - WS-RESPONSE CLEARED FIRST, COMMA SKIPPED ON THE FIRST ROW.   *
      *----------------------------------------------------------------*
       LIST-PROMOS.
           MOVE FUNCTION TRIM(WS-REQ-REL-ID) TO HV-RELEASE-ID.
           MOVE SPACES TO WS-RESPONSE.
           MOVE 1 TO WS-RESP-PTR.
           MOVE 'Y' TO WS-FIRST-ROW.

           STRING '[' DELIMITED SIZE
                  INTO WS-RESPONSE WITH POINTER WS-RESP-PTR.

           EXEC SQL DECLARE PRO-CURSOR CURSOR FOR
             SELECT PROMO_ID, RELEASE_ID, ITEM_NAME, STATUS,
                    COALESCE(CHAR(DUE_DATE,ISO),""),
                    COALESCE(TRIM(OWNER),""), CHAR(UPDATED_TS)
             FROM   Z73460.PROMO_T
             WHERE  RELEASE_ID = :HV-RELEASE-ID
             ORDER BY PROMO_ID ASC
           END-EXEC.

           EXEC SQL
             OPEN PRO-CURSOR
           END-EXEC.

           IF SQLCODE NOT = 0
              MOVE SQLCODE TO WS-SQLCODE-DISP
              STRING '{"error":"OPEN CURSOR failed","sqlcode":"'
                                      DELIMITED SIZE
                     WS-SQLCODE-DISP  DELIMITED SPACE
                     '"}'             DELIMITED SIZE
                     INTO WS-RESPONSE
              GO TO LIST-PROMOS-EXIT
           END-IF.

           PERFORM UNTIL SQLCODE NOT = 0
               EXEC SQL FETCH PRO-CURSOR
                 INTO :HV-PROMO-ID, :HV-RELEASE-ID, :HV-ITEM-NAME,
                      :HV-STATUS, :HV-DUE-DATE, :HV-OWNER,
                      :HV-UPDATED-TS
               END-EXEC

               IF SQLCODE = 0
                  PERFORM BUILD-PROMO-JSON-OBJ
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
             CLOSE PRO-CURSOR
           END-EXEC.

           STRING ']' DELIMITED SIZE
                  INTO WS-RESPONSE WITH POINTER WS-RESP-PTR.

       LIST-PROMOS-EXIT.
           EXIT.

      *----------------------------------------------------------------*
      * UPD-PROMO                                                      *
      * UPDATES ITEMNAME, STATUS, DUEDATE, OWNER FOR AN EXISTING ROW.  *
      * RELEASE_ID IS DELIBERATELY NOT UPDATABLE HERE - REPARENTING A  *
      * PROMO ITEM TO A DIFFERENT RELEASE WOULD BE A MOVE OPERATION,   *
      * NOT AN EDIT, AND IS OUT OF SCOPE. VALIDATES DUEDATE FORMAT THE *
      * SAME WAY AS ADD-PROMO BEFORE TOUCHING THE DATABASE. ON         *
      * SUCCESS, ALSO WRITES AN UPD ENTRY TO CHANGE_LOG.               *
      *----------------------------------------------------------------*
       UPD-PROMO.
           MOVE WS-REQ-DUE-DATE TO WS-DATE-CHECK.
           PERFORM VALIDATE-DATE-FORMAT THRU VALIDATE-DATE-FORMAT-EXIT.
           IF WS-DATE-OK = 'N'
              MOVE '{"error":"Invalid dueDate, expected YYYY-MM-DD"}'
                   TO WS-RESPONSE
              GO TO UPD-PROMO-EXIT
           END-IF.

           MOVE FUNCTION TRIM(WS-REQ-PROMO-ID) TO HV-PROMO-ID.
           MOVE FUNCTION TRIM(WS-REQ-ITEM-NAME) TO HV-ITEM-NAME.
           MOVE FUNCTION TRIM(WS-REQ-STATUS)   TO HV-STATUS.
           MOVE FUNCTION TRIM(WS-REQ-OWNER)    TO HV-OWNER.
           MOVE WS-REQ-DUE-DATE                TO HV-DUE-DATE.

           EXEC SQL
               UPDATE Z73460.PROMO_T
               SET    ITEM_NAME  = :HV-ITEM-NAME,
                      STATUS     = :HV-STATUS,
                      OWNER      = :HV-OWNER,
                      DUE_DATE   = :HV-DUE-DATE,
                      UPDATED_TS = CURRENT TIMESTAMP
               WHERE  PROMO_ID = :HV-PROMO-ID
           END-EXEC.

           EVALUATE SQLCODE
               WHEN 0
                 STRING '{"promoId":"'     DELIMITED SIZE
                        HV-PROMO-ID        DELIMITED SPACE
                        '","message":"Promo item updated"}'
                                           DELIMITED SIZE
                        INTO WS-RESPONSE
                 MOVE 'PROMO'     TO HV-LOG-ENTITY-TYPE
                 MOVE HV-PROMO-ID TO HV-LOG-ENTITY-ID
                 MOVE 'UPD'       TO HV-LOG-ACTION
                 MOVE SPACES      TO HV-LOG-DETAILS
                 STRING 'status set to ' DELIMITED SIZE
                        FUNCTION TRIM(HV-STATUS) DELIMITED SIZE
                        INTO HV-LOG-DETAILS
                 PERFORM WRITE-CHANGE-LOG
               WHEN 100
                 MOVE '{"error":"Promo item not found"}' TO WS-RESPONSE
               WHEN OTHER
                 MOVE SQLCODE TO WS-SQLCODE-DISP
                 STRING '{"error":"UPDATE failed","sqlcode":"'
                                         DELIMITED SIZE
                        WS-SQLCODE-DISP  DELIMITED SPACE
                        '"}'             DELIMITED SIZE
                        INTO WS-RESPONSE
           END-EVALUATE.

       UPD-PROMO-EXIT.
           EXIT.

      *----------------------------------------------------------------*
      * DEL-PROMO                                                      *
      * PLAIN DELETE BY PROMO_ID. NO OTHER TABLE HAS AN FK BACK TO     *
      * PROMO_T, SO THIS NEEDS NO -532 HANDLING LIKE RELSMGR'S         *
      * DEL-RELEASE DOES. ON SUCCESS, ALSO WRITES A DEL ENTRY TO       *
      * CHANGE_LOG.                                                    *
      *----------------------------------------------------------------*
       DEL-PROMO.
           MOVE FUNCTION TRIM(WS-REQ-PROMO-ID) TO HV-PROMO-ID.

           EXEC SQL
             DELETE FROM Z73460.PROMO_T
             WHERE PROMO_ID = :HV-PROMO-ID
           END-EXEC.

           EVALUATE SQLCODE
               WHEN 0
                 STRING '{"promoId":"'   DELIMITED SIZE
                        HV-PROMO-ID      DELIMITED SPACE
                        '","message":"Promo item deleted"}'
                                         DELIMITED SIZE
                        INTO WS-RESPONSE
                 MOVE 'PROMO'     TO HV-LOG-ENTITY-TYPE
                 MOVE HV-PROMO-ID TO HV-LOG-ENTITY-ID
                 MOVE 'DEL'       TO HV-LOG-ACTION
                 MOVE SPACES      TO HV-LOG-DETAILS
                 STRING 'promo item deleted' DELIMITED SIZE
                        INTO HV-LOG-DETAILS
                 PERFORM WRITE-CHANGE-LOG
               WHEN 100
                 MOVE '{"error":"Promo item not found"}' TO WS-RESPONSE
               WHEN OTHER
                 MOVE SQLCODE TO WS-SQLCODE-DISP
                 STRING '{"error":"DELETE failed","sqlcode":"'
                                         DELIMITED SIZE
                        WS-SQLCODE-DISP  DELIMITED SPACE
                        '"}'             DELIMITED SIZE
                        INTO WS-RESPONSE
           END-EVALUATE.

      *----------------------------------------------------------------*
      * BUILD-PROMO-JSON-OBJ                                           *
      * BUILDS ONE JSON OBJECT INTO WS-JSON-ROW FROM THE CURRENT HOST  *
      * VARIABLES. USED BY GET-PROMO (SINGLE OBJECT) AND LIST-PROMOS   *
      * (ONE CALL PER FETCHED ROW, APPENDED TO AN ARRAY).              *
      *----------------------------------------------------------------*
       BUILD-PROMO-JSON-OBJ.
           MOVE SPACES TO WS-JSON-ROW.
           MOVE 1      TO WS-JSON-PTR.
           STRING
               '{"promoId":"'              DELIMITED SIZE
               FUNCTION TRIM(HV-PROMO-ID)  DELIMITED SIZE
               '","releaseId":"'           DELIMITED SIZE
               FUNCTION TRIM(HV-RELEASE-ID) DELIMITED SIZE
               '","itemName":"'            DELIMITED SIZE
               FUNCTION TRIM(HV-ITEM-NAME) DELIMITED SIZE
               '","status":"'              DELIMITED SIZE
               FUNCTION TRIM(HV-STATUS)    DELIMITED SIZE
               '","dueDate":"'             DELIMITED SIZE
               FUNCTION TRIM(HV-DUE-DATE)  DELIMITED SIZE
               '","owner":"'               DELIMITED SIZE
               FUNCTION TRIM(HV-OWNER)     DELIMITED SIZE
               '"}'                        DELIMITED SIZE
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
