       IDENTIFICATION DIVISION.
       PROGRAM-ID. BALINQ.
      *> Balance inquiry: returns the current balance of one account.
      *> Read-only: opens the account master for INPUT, changes nothing.
      *>
      *> Input : one BALANCE-REQUEST record (copybook BALREQ) on stdin.
      *> Output: one BALANCE-RESPONSE record (copybook BALRSP) on stdout.
      *> Logs  : diagnostic lines on stderr.
      *>
      *> RETURN-CODE:  0 account found
      *>               8 rejected (bad input) or account not found
      *>              12 system error (file problem)

       ENVIRONMENT DIVISION.
       INPUT-OUTPUT SECTION.
       FILE-CONTROL.
      *> Same logical file name as PAYMENT; DD_ACCTFILE gives the path.
           SELECT ACCOUNT-FILE ASSIGN TO "ACCTFILE"
               ORGANIZATION IS INDEXED
               ACCESS MODE IS RANDOM
               RECORD KEY IS ACCT-ID
               FILE STATUS IS WS-FILE-STATUS.

       DATA DIVISION.
       FILE SECTION.
       FD  ACCOUNT-FILE.
           COPY ACCTREC.

       WORKING-STORAGE SECTION.
           COPY BALREQ.
           COPY BALRSP.

       01  WS-FILE-STATUS           PIC XX.
       01  WS-FILE-OPEN-FLAG        PIC X VALUE 'N'.
           88  WS-FILE-OPEN         VALUE 'Y'.
       01  WS-OUTCOME-FLAG          PIC X VALUE 'Y'.
           88  WS-OK                VALUE 'Y'.
           88  WS-FAILED            VALUE 'N'.
       01  WS-TIMESTAMP             PIC X(21).

       PROCEDURE DIVISION.
       MAIN-PARA.
           INITIALIZE BALANCE-RESPONSE
           ACCEPT BALANCE-REQUEST
           MOVE BRQ-ACCOUNT TO BRS-ACCOUNT

           IF BRQ-ACCOUNT IS NOT NUMERIC
               MOVE 'REJECTED' TO BRS-STATUS
               MOVE 'E001' TO BRS-REASON-CODE
               MOVE 'ACCOUNT MUST BE 10 DIGITS' TO BRS-MESSAGE
               MOVE 8 TO RETURN-CODE
               SET WS-FAILED TO TRUE
           END-IF
           IF WS-OK
               PERFORM OPEN-ACCOUNT-FILE
           END-IF
           IF WS-OK
               PERFORM READ-ACCOUNT
           END-IF
           IF WS-FILE-OPEN
               CLOSE ACCOUNT-FILE
           END-IF

           DISPLAY BALANCE-RESPONSE
           DISPLAY "BALINQ: " BRS-STATUS " " BRS-REASON-CODE
               " ACCT=" BRQ-ACCOUNT " RC=" RETURN-CODE
               UPON SYSERR
           STOP RUN.

       OPEN-ACCOUNT-FILE.
           OPEN INPUT ACCOUNT-FILE
           IF WS-FILE-STATUS = '00'
               SET WS-FILE-OPEN TO TRUE
           ELSE
               PERFORM SYSTEM-ERROR
           END-IF.

      *> A frozen account can still be looked at; only payments are
      *> refused. The status is returned so the caller can show it.
       READ-ACCOUNT.
           MOVE BRQ-ACCOUNT TO ACCT-ID
           READ ACCOUNT-FILE
           EVALUATE WS-FILE-STATUS
               WHEN '00'
                   MOVE FUNCTION CURRENT-DATE TO WS-TIMESTAMP
                   MOVE ACCT-NAME TO BRS-NAME
                   MOVE ACCT-STATUS TO BRS-ACCT-STATUS
                   MOVE ACCT-BALANCE TO BRS-BALANCE
                   MOVE WS-TIMESTAMP(1:14) TO BRS-AS-OF
                   MOVE 'FOUND' TO BRS-STATUS
                   MOVE '0000' TO BRS-REASON-CODE
                   MOVE 'ACCOUNT FOUND' TO BRS-MESSAGE
                   MOVE 0 TO RETURN-CODE
               WHEN '23'
                   MOVE 'NOTFOUND' TO BRS-STATUS
                   MOVE 'E006' TO BRS-REASON-CODE
                   MOVE 'ACCOUNT NOT FOUND' TO BRS-MESSAGE
                   MOVE 8 TO RETURN-CODE
               WHEN OTHER
                   PERFORM SYSTEM-ERROR
           END-EVALUATE.

       SYSTEM-ERROR.
           MOVE 'ERROR' TO BRS-STATUS
           MOVE 'E999' TO BRS-REASON-CODE
           STRING 'ACCOUNT FILE ERROR, FILE STATUS '
               WS-FILE-STATUS DELIMITED BY SIZE
               INTO BRS-MESSAGE
           END-STRING
           MOVE 12 TO RETURN-CODE
           SET WS-FAILED TO TRUE.
