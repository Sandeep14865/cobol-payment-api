      *> PAYREQ - Payment request record (23 bytes, all DISPLAY).
      *> This is the interface contract with the caller. The API layer
      *> builds this record from JSON and writes it to the program's
      *> stdin as one line.
      *>
      *>  Offset Len  Field            Example
      *>  ------ ---  ---------------  ---------------
      *>       0  10  REQ-ACCOUNT      1000000001
      *>      10  12  REQ-AMOUNT       +00000012550   (= 125.50)
      *>      22   1  REQ-TYPE         D
       01  PAYMENT-REQUEST.
           05  REQ-ACCOUNT          PIC X(10).
           05  REQ-AMOUNT           PIC S9(9)V99
                                    SIGN IS LEADING SEPARATE.
           05  REQ-TYPE             PIC X(1).
               88  REQ-DEBIT        VALUE 'D'.
               88  REQ-CREDIT       VALUE 'C'.
