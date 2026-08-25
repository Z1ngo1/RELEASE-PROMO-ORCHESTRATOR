      *----------------------------------------------------------------*
      * SQLCA.CPY - SQL COMMUNICATION AREA                             *
      * INCLUDE IN EVERY COBOL PROGRAM THAT USES EXEC SQL.             *
      * USAGE: EXEC SQL INCLUDE SQLCA END-EXEC                         *
      *        (OR COPY SQLCA IN WORKING-STORAGE IF NOT USING          *
      *         THE PRECOMPILER AUTO-INCLUDE)                          *
      *----------------------------------------------------------------*
           EXEC SQL 
             INCLUDE SQLCA 
           END-EXEC.                             
