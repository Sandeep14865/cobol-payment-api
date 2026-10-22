      *> PAYRSP - Payment response record (94 bytes, all DISPLAY).
      *> The program writes this record to stdout as one line. The API
      *> layer slices it by the offsets below and turns it into JSON.
      *>
      *>  Offset Len  Field            Example
      *>  ------ ---  ---------------  ------------------
      *>       0   8  RSP-STATUS       APPROVED
      *>       8   4  RSP-REASON-CODE  0000
      *>      12  40  RSP-MESSAGE      PAYMENT POSTED
      *>      52  10  RSP-ACCOUNT      1000000001
      *>      62  14  RSP-NEW-BALANCE  +0000000137450 (= 1374.50)
      *>      76  18  RSP-REF-NO       PY2026102216081234
       01  PAYMENT-RESPONSE.
           05  RSP-STATUS           PIC X(8).
               88  RSP-APPROVED     VALUE 'APPROVED'.
               88  RSP-DECLINED     VALUE 'DECLINED'.
               88  RSP-REJECTED     VALUE 'REJECTED'.
               88  RSP-NOTFOUND     VALUE 'NOTFOUND'.
               88  RSP-ERROR        VALUE 'ERROR'.
           05  RSP-REASON-CODE      PIC X(4).
           05  RSP-MESSAGE          PIC X(40).
           05  RSP-ACCOUNT          PIC X(10).
           05  RSP-NEW-BALANCE      PIC S9(11)V99
                                    SIGN IS LEADING SEPARATE.
           05  RSP-REF-NO           PIC X(18).
