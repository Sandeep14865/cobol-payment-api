       IDENTIFICATION DIVISION.
       PROGRAM-ID. PAYMENT.
      *> Validates and posts one payment against the account master.
      *>
      *> Input : one PAYMENT-REQUEST record (copybook PAYREQ) on stdin.
      *> Output: one PAYMENT-RESPONSE record (copybook PAYRSP) on stdout.
      *> Logs  : diagnostic lines on stderr (never on stdout, which is
      *>         reserved for the response record).
      *>
      *> RETURN-CODE:  0 approved
      *>               4 declined by a business rule
      *>               8 rejected (bad input) or account not found
      *>              12 system error (file problem)

       ENVIRONMENT DIVISION.
       INPUT-OUTPUT SECTION.
       FILE-CONTROL.
      *> "ACCTFILE" is a logical name, like a JCL DD name. At run time
      *> GnuCOBOL looks up the environment variable DD_ACCTFILE to find
      *> the real file path.
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
           COPY PAYREQ.
           COPY PAYRSP.

       01  WS-FILE-STATUS           PIC XX.
       01  WS-FILE-OPEN-FLAG        PIC X VALUE 'N'.
           88  WS-FILE-OPEN         VALUE 'Y'.
       01  WS-OUTCOME-FLAG          PIC X VALUE 'Y'.
           88  WS-OK                VALUE 'Y'.
           88  WS-FAILED            VALUE 'N'.
       01  WS-NEW-BALANCE           PIC S9(11)V99 COMP-3.
       01  WS-SINGLE-TXN-LIMIT      PIC S9(9)V99 COMP-3
                                    VALUE 10000.00.
       01  WS-TIMESTAMP             PIC X(21).

       PROCEDURE DIVISION.
       MAIN-PARA.
           INITIALIZE PAYMENT-RESPONSE
           ACCEPT PAYMENT-REQUEST
           MOVE REQ-ACCOUNT TO RSP-ACCOUNT

           PERFORM VALIDATE-REQUEST
           IF WS-OK
               PERFORM OPEN-ACCOUNT-FILE
           END-IF
           IF WS-OK
               PERFORM READ-ACCOUNT
           END-IF
           IF WS-OK
               PERFORM APPLY-PAYMENT
           END-IF
           IF WS-FILE-OPEN
               CLOSE ACCOUNT-FILE
           END-IF

           DISPLAY PAYMENT-RESPONSE
           DISPLAY "PAYMENT: " RSP-STATUS " " RSP-REASON-CODE
               " ACCT=" REQ-ACCOUNT " RC=" RETURN-CODE
               UPON SYSERR
           STOP RUN.

      *> Field-level checks that need no file access. EVALUATE TRUE
      *> stops at the first WHEN that is true, so later checks can
      *> rely on earlier ones (e.g. the amount is numeric).
       VALIDATE-REQUEST.
           EVALUATE TRUE
               WHEN REQ-ACCOUNT IS NOT NUMERIC
                   MOVE 'REJECTED' TO RSP-STATUS
                   MOVE 'E001' TO RSP-REASON-CODE
                   MOVE 'ACCOUNT MUST BE 10 DIGITS' TO RSP-MESSAGE
                   MOVE 8 TO RETURN-CODE
                   SET WS-FAILED TO TRUE
               WHEN REQ-AMOUNT IS NOT NUMERIC
                   MOVE 'REJECTED' TO RSP-STATUS
                   MOVE 'E002' TO RSP-REASON-CODE
                   MOVE 'AMOUNT IS NOT A VALID NUMBER' TO RSP-MESSAGE
                   MOVE 8 TO RETURN-CODE
                   SET WS-FAILED TO TRUE
               WHEN REQ-AMOUNT NOT > ZERO
                   MOVE 'REJECTED' TO RSP-STATUS
                   MOVE 'E003' TO RSP-REASON-CODE
                   MOVE 'AMOUNT MUST BE GREATER THAN ZERO'
                       TO RSP-MESSAGE
                   MOVE 8 TO RETURN-CODE
                   SET WS-FAILED TO TRUE
               WHEN NOT (REQ-DEBIT OR REQ-CREDIT)
                   MOVE 'REJECTED' TO RSP-STATUS
                   MOVE 'E004' TO RSP-REASON-CODE
                   MOVE 'TYPE MUST BE D (DEBIT) OR C (CREDIT)'
                       TO RSP-MESSAGE
                   MOVE 8 TO RETURN-CODE
                   SET WS-FAILED TO TRUE
               WHEN REQ-AMOUNT > WS-SINGLE-TXN-LIMIT
                   MOVE 'DECLINED' TO RSP-STATUS
                   MOVE 'E005' TO RSP-REASON-CODE
                   MOVE 'AMOUNT EXCEEDS SINGLE PAYMENT LIMIT'
                       TO RSP-MESSAGE
                   MOVE 4 TO RETURN-CODE
                   SET WS-FAILED TO TRUE
           END-EVALUATE.

       OPEN-ACCOUNT-FILE.
           OPEN I-O ACCOUNT-FILE
           IF WS-FILE-STATUS = '00'
               SET WS-FILE-OPEN TO TRUE
           ELSE
               PERFORM SYSTEM-ERROR
           END-IF.

       READ-ACCOUNT.
           MOVE REQ-ACCOUNT TO ACCT-ID
           READ ACCOUNT-FILE
           EVALUATE WS-FILE-STATUS
               WHEN '00'
                   CONTINUE
               WHEN '23'
                   MOVE 'NOTFOUND' TO RSP-STATUS
                   MOVE 'E006' TO RSP-REASON-CODE
                   MOVE 'ACCOUNT NOT FOUND' TO RSP-MESSAGE
                   MOVE 8 TO RETURN-CODE
                   SET WS-FAILED TO TRUE
               WHEN OTHER
                   PERFORM SYSTEM-ERROR
           END-EVALUATE.

      *> Business rules that need the account record, then the update.
      *> RSP-NEW-BALANCE and RSP-REF-NO are only filled in when the
      *> payment is approved.
       APPLY-PAYMENT.
           IF ACCT-FROZEN
               MOVE 'DECLINED' TO RSP-STATUS
               MOVE 'E007' TO RSP-REASON-CODE
               MOVE 'ACCOUNT IS FROZEN' TO RSP-MESSAGE
               MOVE 4 TO RETURN-CODE
               EXIT PARAGRAPH
           END-IF

           IF REQ-DEBIT
               COMPUTE WS-NEW-BALANCE = ACCT-BALANCE - REQ-AMOUNT
           ELSE
               COMPUTE WS-NEW-BALANCE = ACCT-BALANCE + REQ-AMOUNT
           END-IF

           IF WS-NEW-BALANCE < ZERO
               MOVE 'DECLINED' TO RSP-STATUS
               MOVE 'E008' TO RSP-REASON-CODE
               MOVE 'INSUFFICIENT FUNDS' TO RSP-MESSAGE
               MOVE 4 TO RETURN-CODE
               EXIT PARAGRAPH
           END-IF

           MOVE WS-NEW-BALANCE TO ACCT-BALANCE
           REWRITE ACCOUNT-RECORD
           IF WS-FILE-STATUS NOT = '00'
               PERFORM SYSTEM-ERROR
               EXIT PARAGRAPH
           END-IF

      *> Reference number: "PY" + YYYYMMDDHHMMSS + hundredths.
           MOVE FUNCTION CURRENT-DATE TO WS-TIMESTAMP
           STRING 'PY' WS-TIMESTAMP(1:16) DELIMITED BY SIZE
               INTO RSP-REF-NO
           END-STRING
           MOVE WS-NEW-BALANCE TO RSP-NEW-BALANCE
           MOVE 'APPROVED' TO RSP-STATUS
           MOVE '0000' TO RSP-REASON-CODE
           MOVE 'PAYMENT POSTED' TO RSP-MESSAGE
           MOVE 0 TO RETURN-CODE.

       SYSTEM-ERROR.
           MOVE 'ERROR' TO RSP-STATUS
           MOVE 'E999' TO RSP-REASON-CODE
           STRING 'ACCOUNT FILE ERROR, FILE STATUS '
               WS-FILE-STATUS DELIMITED BY SIZE
               INTO RSP-MESSAGE
           END-STRING
           MOVE 12 TO RETURN-CODE
           SET WS-FAILED TO TRUE.
