# How the COBOL Payment API works

This guide walks through the demo in the order you would meet it: the commands, each file, then one payment traced byte by byte from JSON to COBOL and back. After that come production-style scenarios, a part-by-part comparison with Enterprise COBOL's `JSON GENERATE`/`JSON PARSE` and IBM z/OS Connect, and five questions to test yourself.

---

## 1. The big picture

```
 client                API layer (Python)                       COBOL layer
 ──────   ─────────────────────────────────────────────   ─────────────────────────────
 JSON  →  models.py     check shape (types, sizes)
          main.py       rename JSON keys → COBOL names
          copybook.py   build 23-char PAYREQ record
          cobol_bridge  start bin/PAYMENT, write record  →  ACCEPT PAYMENT-REQUEST
                                                            validate (E001–E005)
                                                            READ ACCOUNTS.DAT by key
                                                            business rules (E006–E008)
                                                            REWRITE new balance
          cobol_bridge  read 94-char record + exit code  ←  DISPLAY PAYMENT-RESPONSE
          copybook.py   slice record into fields             RETURN-CODE 0/4/8/12
          main.py       rename COBOL names → JSON keys,
                        pick HTTP status
 JSON  ←  models.py     serialise
```

The one idea to hold on to: **the copybook is the contract**. COBOL sees the request and response as fixed-width records. Every other part exists to turn JSON into exactly those characters and back. On a mainframe, z/OS Connect or `JSON GENERATE`/`JSON PARSE` does that job; here Python does it, in about 100 lines you can read.

---

## 2. Every command

| Command | What it does | Mainframe counterpart |
|---|---|---|
| `xcode-select --install` | Installs Apple's command-line tools, including the Clang C compiler. GnuCOBOL translates COBOL to C, so it needs a C compiler. | The Language Environment and binder that come with z/OS |
| `brew install gnucobol` | Installs `cobc` (the compiler) and `libcob` (the runtime), plus Berkeley DB, which GnuCOBOL uses for `ORGANIZATION IS INDEXED` files. | Enterprise COBOL compiler + VSAM |
| `python3 -m venv .venv` | Creates a private Python environment in `.venv/`, so the packages for this project do not mix with anything else on the Mac. | — |
| `.venv/bin/pip install -r requirements.txt` | Installs the exact versions of FastAPI (web framework), Pydantic (validation), and Uvicorn (the web server that runs FastAPI). | Installing the z/OS Connect server |
| `make build` | Runs `cobc -x -Wall -I cobol/copybooks -o bin/X cobol/X.cbl` for each program. `-x` = build an executable with a `main`; `-Wall` = all warnings; `-I` = where `COPY` finds copybooks; `-o` = output path. Rebuilds when a `.cbl` or any `.cpy` changes. | Compile + link JCL step with `SYSLIB` pointing at the copybook PDS |
| `make seed` | Runs `bin/ACCTLOAD` with `DD_SEEDFILE` and `DD_ACCTFILE` set. It replaces `data/ACCOUNTS.DAT` with the three demo accounts. | An IDCAMS `DEFINE CLUSTER` + `REPRO` job that loads a KSDS |
| `make run` | Starts Uvicorn on port 8000 with `--reload` (restarts on Python changes). | Starting the z/OS Connect Liberty server |
| `make test` | Runs `tests/curl_tests.sh`, 11 calls with expected outcomes in their titles. | — |
| `make clean` | Deletes `bin/` and the indexed file. | — |
| `curl -s -X POST URL -H 'Content-Type: application/json' -d '{...}'` | `-s` silent, `-X POST` the method, `-H` tells FastAPI the body is JSON, `-d` the body. The test script adds `-w '%{http_code}'` to print the HTTP status. | Any REST client |

The `Makefile` lines `export DD_ACCTFILE = ...` deserve a closer look. In the COBOL, the file is named only by a logical name:

```cobol
SELECT ACCOUNT-FILE ASSIGN TO "ACCTFILE"
```

At run time, GnuCOBOL looks up the environment variable `DD_ACCTFILE` to find the real path. That is the same separation JCL gives you:

```jcl
//ACCTFILE DD DSN=PROD.PAYMENT.ACCOUNTS.KSDS,DISP=SHR
```

The program never contains a real file name, so the same binary runs against test or production data. `cobol_bridge.py` sets `DD_ACCTFILE` explicitly for each call, so the API does not depend on how it was started.

---

## 3. Every file

### `cobol/copybooks/PAYREQ.cpy` — request record (23 characters)

```cobol
       01  PAYMENT-REQUEST.
           05  REQ-ACCOUNT          PIC X(10).
           05  REQ-AMOUNT           PIC S9(9)V99
                                    SIGN IS LEADING SEPARATE.
           05  REQ-TYPE             PIC X(1).
               88  REQ-DEBIT        VALUE 'D'.
               88  REQ-CREDIT       VALUE 'C'.
```

- `PIC X(10)`: 10 characters, any content, padded with spaces on the right.
- `PIC S9(9)V99`: signed, 9 integer digits, an **implied** decimal point (`V`, not stored), 2 decimals. Normally the sign lives inside the last digit (a "zoned overpunch": +125.50 is stored as `0000001255{`). `SIGN IS LEADING SEPARATE` puts it in its own character instead: `+00000012550`. That costs one byte but is plain text any language can produce. Section 4 shows what the overpunch form looks like on z/OS.
- `88` levels are named conditions. `IF REQ-DEBIT` means `IF REQ-TYPE = 'D'`. JSON has `"DEBIT"`; COBOL has `D`. Translating between them is part of the mapping.

The comment block in the copybook lists offsets. That table is what Python codes against.

### `cobol/copybooks/PAYRSP.cpy` — response record (94 characters)

Status (8), reason code (4), message (40), account (10), new balance `S9(11)V99` with separate sign (14), reference number (18). The balance field is 2 digits wider than the request amount, because a balance can grow beyond any one payment.

### `cobol/copybooks/ACCTREC.cpy` — account master record

Key `ACCT-ID`, name, status (`A`/`F` as 88 levels), and `ACCT-BALANCE PIC S9(11)V99 COMP-3`. `COMP-3` is packed decimal: two digits per byte, sign in the last half-byte, 7 bytes for 13 digits. It is how mainframes store money. It is used only inside COBOL: the interface records stay `DISPLAY` so Python can read them as text. Moving a `COMP-3` field to a `DISPLAY` field (`MOVE WS-NEW-BALANCE TO RSP-NEW-BALANCE`) is how COBOL converts between them.

### `cobol/PAYMENT.cbl` — the business program

| Paragraph | Job |
|---|---|
| `MAIN-PARA` | `INITIALIZE` the response (spaces in text fields, zeros in numbers), `ACCEPT` one line from stdin into `PAYMENT-REQUEST`, run each step only while `WS-OK`, `DISPLAY` the response on stdout, log one line to **stderr** (`UPON SYSERR`), `STOP RUN` (exit status = `RETURN-CODE`). |
| `VALIDATE-REQUEST` | Checks that need no file: account numeric (E001), amount numeric (E002), amount > 0 (E003), type D or C (E004), amount ≤ 10,000.00 (E005). `EVALUATE TRUE` stops at the first true `WHEN`, so the "> 0" check can trust the "numeric" check above it. |
| `OPEN-ACCOUNT-FILE` | `OPEN I-O` (read and update). Any file status other than `00` is a system error. |
| `READ-ACCOUNT` | Random `READ` by key. Status `23` = record not found (E006). |
| `APPLY-PAYMENT` | Frozen (E007), compute new balance in `COMP-3`, negative = insufficient funds (E008), `REWRITE`, build the reference number from `FUNCTION CURRENT-DATE`, set `APPROVED`. |
| `SYSTEM-ERROR` | E999 with the file status in the message, `RETURN-CODE 12`. |

Return codes follow the mainframe batch convention: 0 OK, 4 warning, 8 error, 12 severe. On z/OS these become the step's condition code that later JCL steps can test.

Why stdout is "sacred": the response must be exactly one 94-character line. A stray `DISPLAY "DEBUG..."` would break the record, and the API would correctly refuse it (see scenario 5.6). Diagnostics go to stderr, which Python logs separately. That mirrors the split between a CICS COMMAREA (data) and the job log / `SYSOUT` (messages).

### `cobol/ACCTLOAD.cbl` — loads the account file

Reads `data/accounts.seed` (line sequential), moves each field into `ACCOUNT-RECORD` (the `MOVE` of the `SIGN LEADING SEPARATE` seed balance into the `COMP-3` balance is the conversion), and `WRITE`s it. `OPEN OUTPUT` on an indexed file replaces it. Records must be in ascending key order because the file is opened for sequential access.

### `cobol/PAYJSON.cbl` — comparison demo, not used by the API

Reads a `PAYRSP` record from stdin and lets COBOL itself produce JSON with `JSON GENERATE`. Try it:

```bash
echo "1000000001+00000001000C" | DD_ACCTFILE=data/ACCOUNTS.DAT bin/PAYMENT 2>/dev/null | bin/PAYJSON
```

```json
{"PAYMENT-RESPONSE":{"status":"APPROVED","reasonCode":"0000","message":"PAYMENT POSTED","account":"1000000001","newBalance":1510.00,"refNo":"PY2026102216225959"}}
```

and for a declined payment:

```json
{"PAYMENT-RESPONSE":{"status":"DECLINED","reasonCode":"E008","message":"INSUFFICIENT FUNDS","account":"1000000002","newBalance":0.00,"refNo":" "}}
```

Compare with what the Python API returns for the same declined case: `"new_balance":null,"ref_no":null`. Section 6 explains the differences.

### `data/accounts.seed`

Three 55-character lines matching `SEED-RECORD` in `ACCTLOAD.cbl`. Generated with `printf '%-10s%-30s%s%s\n'` so the widths are exact; hand-editing fixed-width files is a classic source of off-by-one bugs.

### `app/models.py` — the JSON contract

Pydantic models are the API's equivalent of the copybook: they describe the JSON. Two rules decide what goes here and what stays in COBOL:

- **Here**: anything needed to build a valid record. `max_length=10` (it must fit `PIC X(10)`), `max_digits=11, decimal_places=2` (it must fit `S9(9)V99`), `type` must be `DEBIT` or `CREDIT` (there is no other code to send), and `extra="forbid"` (unknown JSON keys are an error, not silently dropped).
- **In COBOL**: business rules. Is the account all digits? Is the amount positive? Under the limit? Funded? Those can change without touching the API, and other callers of `PAYMENT` (a batch job, a CICS screen) get the same rules.

`new_balance` and `ref_no` are optional (`| None`) because they mean something only when the payment is approved.

### `app/copybook.py` — the copybook, in Python

`Field(name, length, kind, scale)` describes one 05-level item. `Layout` lays fields back to back and knows the total length. `encode` turns a dict into a record; `decode` does the reverse. Two kinds cover this demo: `"X"` (`PIC X(n)`) and `"S9V"` (`PIC S9(n)V9(d) SIGN LEADING SEPARATE`).

It deliberately **raises** instead of truncating: a too-long string, a third decimal place, a number that overflows, or non-ASCII text all become `RecordMappingError`. COBOL's own `MOVE` would truncate silently, which is how corrupted records get created.

### `app/cobol_bridge.py` — the subprocess call

`call_payment()`:

1. Encodes the request record.
2. Takes `_payment_lock`, so only one `PAYMENT` runs at a time (it does read → check → rewrite, which must not interleave).
3. `subprocess.run([bin/PAYMENT], input=record+"\n", capture_output=True, text=True, encoding="ascii", timeout=5, env={..., DD_ACCTFILE})`.
4. Logs each stderr line.
5. Rejects any exit status other than 0/4/8/12 (a crash or a `libcob` runtime error).
6. Strips only the trailing newline (trailing spaces are data) and decodes 94 characters. Wrong length = `CobolCallError`.

Every failure becomes a `CobolCallError`, which `main.py` turns into HTTP 503.

### `app/main.py` — routes and mapping

`POST /payment` does three numbered steps:

1. **JSON → COBOL names**: `account → REQ-ACCOUNT`, `amount → REQ-AMOUNT`, `type → REQ-TYPE` via `TYPE_CODES` (`DEBIT → D`).
2. **Call**: `RecordMappingError` → 422; `CobolCallError` → 503.
3. **COBOL names → JSON**: `RSP-STATUS → status` and so on. `new_balance` only when approved; blank `ref_no` → `null`. `HTTP_STATUS` picks the HTTP code from `RSP-STATUS`.

`GET /health` reports whether the binary and the data file exist.

### `tests/curl_tests.sh`

Eleven calls: two approvals, every COBOL reason code reachable through the API, and three requests that Pydantic rejects before COBOL ever runs.

---

## 4. One payment, step by step

Request:

```json
{"account":"1000000001","amount":125.50,"type":"DEBIT"}
```

**Step 1 — Pydantic** parses it into `account="1000000001"`, `amount=Decimal("125.50")`, `type=PaymentType.DEBIT`. `Decimal`, not `float`: `0.1 + 0.2` is not `0.3` in floating point, and money must be exact, just like COBOL's fixed-point decimals.

**Step 2 — rename** (`main.py`):

```python
{"REQ-ACCOUNT": "1000000001", "REQ-AMOUNT": Decimal("125.50"), "REQ-TYPE": "D"}
```

**Step 3 — encode** (`copybook.py`):

| Field | Rule | Characters |
|---|---|---|
| REQ-ACCOUNT | pad right to 10 | `1000000001` |
| REQ-AMOUNT | ×10² → 12550, sign, zero-fill to 11 digits | `+00000012550` |
| REQ-TYPE | pad right to 1 | `D` |

Record: `1000000001+00000012550D` (23 characters) + newline.

**Step 4 — COBOL reads it.** `ACCEPT PAYMENT-REQUEST` copies the line into the group item. The group is just 23 bytes of storage; the 05 levels are names for positions within it. There is no parsing: `REQ-AMOUNT` *is* bytes 11–22, and the `V` in its picture makes COBOL treat `00000012550` as 125.50.

**Step 5 — COBOL works.** Validation passes; `READ` finds Alice with `ACCT-BALANCE` 1500.00 (packed: `X'0000000150000C'`); `COMPUTE WS-NEW-BALANCE = ACCT-BALANCE - REQ-AMOUNT` gives 1374.50; `REWRITE`; reference number from the clock.

**Step 6 — COBOL replies** with one 94-character line and exit status 0:

```
APPROVED0000PAYMENT POSTED                          1000000001+0000000137450PY2026102216244029
|  8   ||4 ||               40                     ||  10    ||    14      ||       18       |
```

**Step 7 — decode** (`copybook.py`) slices `[0:8] [8:12] [12:52] [52:62] [62:76] [76:94]`, strips padding from text, and turns `+0000000137450` into `Decimal("1374.50")`.

**Step 8 — rename and respond** (`main.py`): status `APPROVED` → HTTP 200:

```json
{"status":"APPROVED","reason_code":"0000","message":"PAYMENT POSTED","account":"1000000001","new_balance":"1374.50","ref_no":"PY2026102216244029"}
```

`new_balance` is a JSON **string**. Pydantic serialises `Decimal` that way so no client parses it into a float and loses cents. `JSON GENERATE` emits a JSON **number** (`1374.50`). Both are common; pick one per API and document it.

### The same request on z/OS

On a mainframe the record is EBCDIC, and the amount would normally be zoned decimal without a separate sign:

| | This demo (ASCII) | z/OS (EBCDIC, code page 1047) |
|---|---|---|
| `REQ-ACCOUNT` | `31 30 30 ... 31` | `F1 F0 F0 ... F1` |
| `REQ-AMOUNT` as `S9(9)V99` with `SIGN LEADING SEPARATE` | `2B 30 ... 35 35 30` (`+00000012550`) | `4E F0 ... F5 F5 F0` |
| `REQ-AMOUNT` as `S9(9)V99` (default zoned) | — | `F0 ... F5 F5 C0` (last byte: zone `C` = positive, digit 0; prints as `{`) |
| `REQ-AMOUNT` as `S9(9)V99 COMP-3` | — | `00 00 00 12 55 0C` (packed: 11 digits + sign nibble `C` = 6 bytes) |

The converter has to know the code page and every field's `USAGE`. z/OS Connect and `JSON GENERATE`/`PARSE` do this for you because they read the copybook. `copybook.py` handles only the two kinds this demo needs.

---

## 5. Production-style scenarios

Each scenario lists what happens in the demo, which layer owns it, and how it plays out on a mainframe.

**5.1 Happy path (curl test 1).** Covered in section 4. On z/OS Connect + CICS: JSON → COMMAREA by the server, `EXEC CICS LINK PROGRAM('PAYMENT') COMMAREA(...)`, program reads with `EXEC CICS READ FILE('ACCTFILE') UPDATE`, `REWRITE`, `RETURN`, COMMAREA → JSON.

**5.2 Business decline: insufficient funds (test 3).** COBOL sets `DECLINED`/`E008`/RC 4, does not rewrite. Python maps `DECLINED` → 422 and leaves `new_balance` null. The HTTP code is a design decision: some APIs return 200 with `"status":"DECLINED"` (the call worked; the answer was no), others 402 or 422. In z/OS Connect this is a response-code mapping rule on a field value (`RSP-STATUS = 'DECLINED'` → 422).

**5.3 Bad input caught at two levels (tests 6–11).** A three-decimal amount never reaches COBOL (Pydantic, 422), because it cannot be represented in `S9(9)V99`. A negative amount *can* be represented, so it goes to COBOL, which rejects it (E003, 400). The line is: the API layer enforces the **format**, COBOL enforces the **rules**. E002 and E004 cannot be reached through the API, but stay in COBOL as defence in depth: other callers exist, and you can trigger them with `echo ... | bin/PAYMENT`.

**5.4 Data file unavailable.** Point `DD_ACCTFILE` at a missing file: `OPEN` returns file status 35, COBOL replies `ERROR`/`E999`/RC 12, API returns 500 with the status in the message. On z/OS this is the CICS file being closed or disabled (`NOTOPEN` condition), or a missing DD in batch.

**5.5 COBOL hangs or is missing.** `timeout=5` kills a hung run; a missing binary raises `FileNotFoundError`. Both → 503 "Payment service unavailable", the detail only in the server log. A timeout is the hard case: the program may have already rewritten the balance. The client cannot know whether the payment happened. Real payment APIs solve this with an idempotency key (see question 1).

**5.6 Copybook drift.** Someone widens `RSP-MESSAGE` to `X(60)` and redeploys only COBOL. The reply is now 114 characters; `PAYRSP.decode` raises, the API answers 503, nothing is mis-mapped. Without the length check, every field after the message would be shifted 20 characters and the balance could be read from the wrong bytes. On z/OS Connect the service must be regenerated from the new copybook; a stale mapping produces the same misalignment (or a length error, depending on settings). `JSON GENERATE` cannot drift, because it compiles against the copybook itself.

**5.7 Concurrent payments.** Twenty parallel `curl` credits of 1.00 to Bob (25.00) end at exactly 45.00: `_payment_lock` serialises the read–rewrite. Without it, two runs could both read 25.00 and both write 26.00 (a lost update). The lock only works inside one Python process; with `uvicorn --workers 4` you would need a lock the processes share, or record locking in the data layer. CICS gives you that with `READ UPDATE`, which holds the record until `REWRITE` or task end; VSAM RLS does the same across systems.

**5.8 Non-ASCII input.** `"account":"10000é0001"` is 10 characters and passes Pydantic, but `copybook.py` refuses it (422) because the record is ASCII. On z/OS the question becomes "does this character exist in the EBCDIC code page?", and z/OS Connect raises a conversion error.

**5.9 Logging and tracing.** Every call logs the COBOL stderr line and a summary (`account, status, reason, rc`). In production you would add a request ID, pass it into the record, and have COBOL log it, so one payment can be followed across both layers (on z/OS: the CICS task number and z/OS Connect request ID in SMF records).

---

## 6. Part-by-part comparison

| Part | This demo | Enterprise COBOL `JSON GENERATE` / `JSON PARSE` | IBM z/OS Connect |
|---|---|---|---|
| **Where JSON is handled** | Outside COBOL, in Python | Inside the COBOL program | Outside COBOL, in the z/OS Connect server (Liberty) |
| **Interface definition** | Copybook + hand-written mirror in `copybook.py` | The copybook itself, compiled into the program | Copybook imported by the API toolkit, which generates the JSON schema and mapping |
| **JSON → COBOL** | Pydantic + `PAYREQ.encode` | `JSON PARSE json-text INTO PAYMENT-REQUEST` (V6.2+). Matches JSON names to data names; `NAME` overrides; missing members leave the field unchanged, so `INITIALIZE` first | Generated request mapping; the server builds the COMMAREA or container bytes |
| **COBOL → JSON** | `PAYRSP.decode` + `PaymentResponse` | `JSON GENERATE out FROM PAYMENT-RESPONSE COUNT n` (V6.1+) | Generated response mapping |
| **Field names** | Explicit in `main.py` (`RSP-NEW-BALANCE` → `new_balance`) | `NAME OF RSP-NEW-BALANCE IS 'newBalance'`; without it, keys are the COBOL names (`RSP-NEW-BALANCE`) and the 01 level becomes a wrapper object | Renamed in the mapping editor; the 01 wrapper is not exposed |
| **Hiding fields** | `None` unless approved | `SUPPRESS`; V6.3 adds conditional `SUPPRESS ... WHEN SPACES/ZERO`. Without it, you get `"refNo":" "` and `"newBalance":0.00`, as `PAYJSON` shows | Omit fields; conditional mapping rules |
| **Codes ↔ enums** | `TYPE_CODES` dict (`DEBIT` ↔ `D`) | Your own COBOL code before/after the statement | Value mapping, or left to the program |
| **Numbers** | `Decimal`, sent as a JSON string | JSON number from the `PIC` | JSON number, type/range derived from the `PIC` |
| **Character encoding** | ASCII only | EBCDIC in program; JSON text in UTF-8 (or UTF-16 national) | Automatic EBCDIC ↔ UTF-8 using the configured code page |
| **Errors in conversion** | `RecordMappingError` → 422 / `CobolCallError` → 503 | `ON EXCEPTION`, `JSON-CODE` and `JSON-STATUS` special registers | HTTP 400/500 with a z/OS Connect error message |
| **Transport to COBOL** | New process per call, stdin/stdout, exit code | None of its own: the program still needs CICS web support, MQ, or batch to receive the HTTP request | IPIC to CICS (COMMAREA or channel), IMS Connect, Db2, MQ, WOLA |
| **Program lifetime** | Started and ended for every call (milliseconds of overhead) | Whatever the host does (CICS keeps it loaded) | CICS keeps it loaded; many concurrent tasks |
| **HTTP status** | `HTTP_STATUS` dict on `RSP-STATUS` | Not its concern | Response-code mapping rules on field values |
| **Concurrency** | `threading.Lock` (one process) | Host's job | CICS `READ UPDATE` locks, VSAM RLS |
| **Security** | None | — | TLS, SAF/RACF, JWT/OAuth, identity asserted into CICS |
| **API description** | FastAPI auto-generates OpenAPI at `/docs` | — | OpenAPI document generated from the mapping |

How to choose, roughly:

- **`JSON GENERATE`/`PARSE`**: the COBOL program already talks to something that carries JSON (CICS web services, MQ, files) and you want no extra tier. You maintain the JSON shape in COBOL.
- **z/OS Connect**: you want to expose existing CICS/IMS programs as REST without changing them, with security, OpenAPI and governance from one place. This demo's Python layer is a hand-written miniature of it.
- **Subprocess, as here**: off-mainframe COBOL (GnuCOBOL, Micro Focus) called by a modern service, often during a migration. Simple and testable, but a process per call and a file-based data store limit throughput.

---

## 7. Known limitations of the demo

- **Reference numbers can collide.** `PY` + clock to the hundredth of a second. Two approvals in the same hundredth get the same number. Production uses a sequence (a control record, a Db2 sequence, or a CICS named counter).
- **No idempotency.** A retried request posts twice.
- **One process.** The lock does not cover several Uvicorn workers or other programs updating the file.
- **No authentication or TLS.**
- **ASCII only**, and `copybook.py` supports only `PIC X` and `SIGN LEADING SEPARATE` numerics: no `COMP-3`, `COMP`, `OCCURS` or `REDEFINES` in the interface records.

---

## 8. Test yourself

Five scenarios, no answers. Work each one out against the code before checking by experiment.

1. **The retry.** A mobile app calls `POST /payment` for a 200.00 debit. COBOL is slow under load: it finishes the `REWRITE` after 5.3 seconds, but `cobol_bridge.py` has already timed out at 5 seconds and the API has returned 503. The app retries and the second call succeeds. What has happened to the balance? Which fields would you add to `PAYREQ.cpy`, what would `PAYMENT.cbl` do with them, and what changes in `models.py` and `main.py`? How would the same retry behave behind z/OS Connect with the program in CICS?

2. **The widened field.** The COBOL team changes `RSP-MESSAGE` to `PIC X(60)`, rebuilds `bin/PAYMENT`, and does not touch Python. Which exact line raises an exception, what HTTP status and body does the client get, and does the payment still post? What would happen with `PAYJSON.cbl` after the same change, and with a z/OS Connect service built from the old copybook?

3. **Four workers.** You start the API with `uvicorn app.main:app --workers 4` and fire 100 concurrent 10.00 debits at an account holding 500.00. What final balances are possible, why does `_payment_lock` not prevent it, and what would you change in `PAYMENT.cbl` (or in the data store) to fix it? What is the CICS equivalent of your fix?

4. **The move to z/OS.** The program is ported to CICS: `ACCOUNTS.DAT` becomes a VSAM KSDS, the request arrives as a COMMAREA through z/OS Connect, and `REQ-AMOUNT` is changed to `PIC S9(9)V99 COMP-3`. Which files in this repository disappear, which become generated artifacts, and which survive unchanged? Write out the hex bytes of `REQ-AMOUNT` for a 125.50 request, and say what `ACCEPT`, `DISPLAY` and `STOP RUN` turn into.

5. **The new requirement.** The product owner wants declined payments to return HTTP 200 instead of 422, and wants an `available_balance` field returned only for `E008` declines. Which copybook, COBOL, and Python changes are needed, in which order would you deploy them to avoid scenario 5.6, and how would you express "only for E008" with `JSON GENERATE` and with z/OS Connect?
