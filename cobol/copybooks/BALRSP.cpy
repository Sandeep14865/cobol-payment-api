      *> BALRSP - Balance inquiry response record (121 bytes, DISPLAY).
      *> The program writes this record to stdout as one line. The API
      *> layer slices it by the offsets below and turns it into JSON.
      *>
      *>  Offset Len  Field            Example
      *>  ------ ---  ---------------  ------------------
      *>       0   8  BRS-STATUS       FOUND
      *>       8   4  BRS-REASON-CODE  0000
      *>      12  40  BRS-MESSAGE      ACCOUNT FOUND
      *>      52  10  BRS-ACCOUNT      1000000001
      *>      62  30  BRS-NAME         ALICE JOHNSON
      *>      92   1  BRS-ACCT-STATUS  A
      *>      93  14  BRS-BALANCE      +0000000150000 (= 1500.00)
      *>     107  14  BRS-AS-OF        20261022163015 (YYYYMMDDHHMMSS)
       01  BALANCE-RESPONSE.
           05  BRS-STATUS           PIC X(8).
               88  BRS-FOUND        VALUE 'FOUND'.
               88  BRS-REJECTED     VALUE 'REJECTED'.
               88  BRS-NOTFOUND     VALUE 'NOTFOUND'.
               88  BRS-ERROR        VALUE 'ERROR'.
           05  BRS-REASON-CODE      PIC X(4).
           05  BRS-MESSAGE          PIC X(40).
           05  BRS-ACCOUNT          PIC X(10).
           05  BRS-NAME             PIC X(30).
           05  BRS-ACCT-STATUS      PIC X(1).
           05  BRS-BALANCE          PIC S9(11)V99
                                    SIGN IS LEADING SEPARATE.
           05  BRS-AS-OF            PIC X(14).
