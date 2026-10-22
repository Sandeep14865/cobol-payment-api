      *> ACCTREC - Account master record (indexed file, key ACCT-ID).
      *> Plays the role of a VSAM KSDS record. The balance is packed
      *> decimal (COMP-3), as it would be on a mainframe, so it never
      *> leaves the program in this form: PAYMENT moves it into the
      *> DISPLAY field RSP-NEW-BALANCE before replying.
       01  ACCOUNT-RECORD.
           05  ACCT-ID              PIC X(10).
           05  ACCT-NAME            PIC X(30).
           05  ACCT-STATUS          PIC X(1).
               88  ACCT-ACTIVE      VALUE 'A'.
               88  ACCT-FROZEN      VALUE 'F'.
           05  ACCT-BALANCE         PIC S9(11)V99 COMP-3.
