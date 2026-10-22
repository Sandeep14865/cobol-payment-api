      *> BALREQ - Balance inquiry request record (10 bytes, DISPLAY).
      *> The API layer builds this record from the URL path and writes
      *> it to the program's stdin as one line.
      *>
      *>  Offset Len  Field            Example
      *>  ------ ---  ---------------  ---------------
      *>       0  10  BRQ-ACCOUNT      1000000001
       01  BALANCE-REQUEST.
           05  BRQ-ACCOUNT          PIC X(10).
