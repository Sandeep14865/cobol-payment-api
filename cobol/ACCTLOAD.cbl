       IDENTIFICATION DIVISION.
       PROGRAM-ID. ACCTLOAD.
      *> Builds (or rebuilds) the indexed account master from a text
      *> seed file. Run it once before starting the API, and again any
      *> time you want to reset the demo balances.
      *>
      *> SEEDFILE: line sequential, one account per line:
      *>   cols  1-10 account id
      *>   cols 11-40 name
      *>   col  41    status (A = active, F = frozen)
      *>   cols 42-55 balance, sign + 13 digits, 2 implied decimals

       ENVIRONMENT DIVISION.
       INPUT-OUTPUT SECTION.
       FILE-CONTROL.
           SELECT SEED-FILE ASSIGN TO "SEEDFILE"
               ORGANIZATION IS LINE SEQUENTIAL
               FILE STATUS IS WS-SEED-STATUS.
           SELECT ACCOUNT-FILE ASSIGN TO "ACCTFILE"
               ORGANIZATION IS INDEXED
               ACCESS MODE IS SEQUENTIAL
               RECORD KEY IS ACCT-ID
               FILE STATUS IS WS-ACCT-STATUS.

       DATA DIVISION.
       FILE SECTION.
       FD  SEED-FILE.
       01  SEED-RECORD.
           05  SEED-ID              PIC X(10).
           05  SEED-NAME            PIC X(30).
           05  SEED-STATUS          PIC X(1).
           05  SEED-BALANCE         PIC S9(11)V99
                                    SIGN IS LEADING SEPARATE.

       FD  ACCOUNT-FILE.
           COPY ACCTREC.

       WORKING-STORAGE SECTION.
       01  WS-SEED-STATUS           PIC XX.
       01  WS-ACCT-STATUS           PIC XX.
       01  WS-EOF-FLAG              PIC X VALUE 'N'.
           88  WS-EOF               VALUE 'Y'.
       01  WS-COUNT                 PIC 9(5) VALUE ZERO.

       PROCEDURE DIVISION.
       MAIN-PARA.
           OPEN INPUT SEED-FILE
           IF WS-SEED-STATUS NOT = '00'
               DISPLAY "ACCTLOAD: cannot open SEEDFILE, status "
                   WS-SEED-STATUS UPON SYSERR
               MOVE 12 TO RETURN-CODE
               STOP RUN
           END-IF
      *> OPEN OUTPUT replaces any existing account file.
           OPEN OUTPUT ACCOUNT-FILE
           IF WS-ACCT-STATUS NOT = '00'
               DISPLAY "ACCTLOAD: cannot open ACCTFILE, status "
                   WS-ACCT-STATUS UPON SYSERR
               MOVE 12 TO RETURN-CODE
               STOP RUN
           END-IF

      *> Records must arrive in ascending key order (sequential load).
           PERFORM UNTIL WS-EOF
               READ SEED-FILE
                   AT END
                       SET WS-EOF TO TRUE
                   NOT AT END
                       MOVE SEED-ID      TO ACCT-ID
                       MOVE SEED-NAME    TO ACCT-NAME
                       MOVE SEED-STATUS  TO ACCT-STATUS
                       MOVE SEED-BALANCE TO ACCT-BALANCE
                       WRITE ACCOUNT-RECORD
                       IF WS-ACCT-STATUS = '00'
                           ADD 1 TO WS-COUNT
                       ELSE
                           DISPLAY "ACCTLOAD: write failed for "
                               SEED-ID ", status " WS-ACCT-STATUS
                               UPON SYSERR
                           MOVE 8 TO RETURN-CODE
                       END-IF
               END-READ
           END-PERFORM

           CLOSE SEED-FILE ACCOUNT-FILE
           DISPLAY "ACCTLOAD: loaded " WS-COUNT " accounts"
           STOP RUN.
