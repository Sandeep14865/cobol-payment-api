       IDENTIFICATION DIVISION.
       PROGRAM-ID. PAYJSON.
      *> Comparison demo, not used by the API: shows what COBOL's own
      *> JSON GENERATE statement (Enterprise COBOL 6.1+, GnuCOBOL 3.2)
      *> produces from the same PAYRSP record the API maps in Python.
      *>
      *> Usage:  echo "1000000001+00000001000C" | bin/PAYMENT | bin/PAYJSON
      *>
      *> GnuCOBOL 3.2 does not implement JSON PARSE, so the request side
      *> of this comparison exists only on Enterprise COBOL.

       DATA DIVISION.
       WORKING-STORAGE SECTION.
           COPY PAYRSP.
       01  WS-JSON                  PIC X(500).
       01  WS-JSON-LEN              PIC 9(4).

       PROCEDURE DIVISION.
       MAIN-PARA.
           ACCEPT PAYMENT-RESPONSE
      *> NAME renames COBOL data names to JSON keys; SUPPRESS leaves
      *> fields out. Without NAME, the keys would be RSP-STATUS etc.
           JSON GENERATE WS-JSON FROM PAYMENT-RESPONSE
               COUNT IN WS-JSON-LEN
               NAME OF RSP-STATUS      IS 'status'
                       RSP-REASON-CODE IS 'reasonCode'
                       RSP-MESSAGE     IS 'message'
                       RSP-ACCOUNT     IS 'account'
                       RSP-NEW-BALANCE IS 'newBalance'
                       RSP-REF-NO      IS 'refNo'
               ON EXCEPTION
                   DISPLAY "PAYJSON: JSON GENERATE failed, JSON-CODE "
                       JSON-CODE UPON SYSERR
                   MOVE 12 TO RETURN-CODE
               NOT ON EXCEPTION
                   DISPLAY WS-JSON(1:WS-JSON-LEN)
           END-JSON
           STOP RUN.
