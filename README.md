# COBOL Payment API

A REST API that lets any program make a payment by sending JSON over HTTP, while the actual business logic runs in a **COBOL program**.

- **Python (FastAPI)** is the front door. It accepts JSON, checks its shape, and translates it into the fixed-width record format COBOL understands.
- **COBOL (GnuCOBOL)** is the engine. It validates the payment, updates the account balance in an indexed file, and replies with a status, the new balance, and a reference number.

This is the same pattern banks use to put a REST API in front of existing mainframe COBOL (for example with IBM z/OS Connect), shrunk down so it runs on a Mac.

**Contents:** [Architecture](#architecture) · [What happens on one request](#what-happens-on-one-request) · [Input](#input-what-you-send) · [Output](#output-what-you-get-back) · [All possible results](#all-possible-results) · [Setup](#setup-on-a-mac) · [Run](#run-it) · [Test](#test-it) · [Project files](#project-files) · [Troubleshooting](#troubleshooting)

For a deeper, line-by-line explanation, and a comparison with Enterprise COBOL `JSON GENERATE`/`JSON PARSE` and z/OS Connect, see [GUIDE.md](GUIDE.md).

---

## Architecture

```
 ┌──────────┐  HTTP + JSON   ┌───────────────────────────────┐  stdin: 23-char record   ┌──────────────────┐        ┌──────────────┐
 │  Client  │ ─────────────▶ │  FastAPI app (Python)         │ ───────────────────────▶ │  PAYMENT         │ ─────▶ │ ACCOUNTS.DAT │
 │ (curl,   │                │                               │                          │  (COBOL program) │ read / │ (indexed     │
 │  app,    │                │  models.py     check JSON     │  stdout: 94-char record  │                  │ rewrite│  file, like  │
 │  browser)│ ◀───────────── │  copybook.py   JSON ⇄ record  │ ◀─────────────────────── │  validates,      │ ◀───── │  VSAM KSDS)  │
 └──────────┘  HTTP + JSON   │  cobol_bridge  run COBOL      │  exit code: 0/4/8/12     │  posts payment   │        └──────────────┘
                             │  main.py       routes, HTTP   │                          └──────────────────┘
                             └───────────────────────────────┘
```

There are three layers, and each has one job:

| Layer | Technology | Job | Knows about |
|---|---|---|---|
| **API layer** | Python 3.13, FastAPI, Pydantic, Uvicorn | Speak HTTP and JSON. Check the request is well formed. Convert between JSON and COBOL records. Choose the HTTP status code. | JSON, HTTP, and the record layout |
| **Business layer** | COBOL, compiled with GnuCOBOL 3.2 | Apply the payment rules. Update the balance. Generate the reference number. | Records and the account file only. It has no idea HTTP or JSON exist. |
| **Data layer** | Indexed file `data/ACCOUNTS.DAT` (Berkeley DB, via GnuCOBOL) | Store accounts, keyed by account number. | — |

### How Python and COBOL talk to each other

They don't share memory or a network connection. For **every** payment, Python starts the compiled COBOL program `bin/PAYMENT` as a new process and talks to it through three channels:

| Channel | Direction | Carries |
|---|---|---|
| **stdin** | Python → COBOL | One request record, exactly 23 characters, one line |
| **stdout** | COBOL → Python | One response record, exactly 94 characters, one line |
| **exit code** | COBOL → Python | COBOL's `RETURN-CODE`: 0 approved, 4 declined, 8 rejected/not found, 12 system error |

COBOL also writes one log line to **stderr**. Python copies it into the server log, but it's never part of the response.

### The copybook is the contract

Both sides must agree on exactly which characters sit where in each record. That agreement is written down in COBOL **copybooks**:

- [`cobol/copybooks/PAYREQ.cpy`](cobol/copybooks/PAYREQ.cpy) — request record
- [`cobol/copybooks/PAYRSP.cpy`](cobol/copybooks/PAYRSP.cpy) — response record

The COBOL program includes them with `COPY`. The Python file [`app/copybook.py`](app/copybook.py) describes the same layouts in Python. **If a copybook changes, `copybook.py` must change with it.** If they get out of step, the API notices the wrong record length and refuses the reply (HTTP 503) rather than returning wrong numbers.

### Who checks what

Checks are split on purpose:

- **Python checks the format**: is it valid JSON, are the fields present, will each value *fit* in its COBOL field? A value that can't fit (for example 3 decimal places in a 2-decimal field) never reaches COBOL.
- **COBOL checks the business rules**: is the account number all digits, is the amount positive and under the limit, does the account exist, is it frozen, is there enough money? These rules live in one place, so any other program that calls `PAYMENT` gets the same rules.

---

## What happens on one request

Request: debit 125.50 from account `1000000001`, which has 1,500.00.

| Step | Where | What happens | Data at this point |
|---|---|---|---|
| 1 | Client | Sends `POST /payment` | `{"account":"1000000001","amount":125.50,"type":"DEBIT"}` |
| 2 | [`models.py`](app/models.py) | Pydantic checks the JSON: account ≤ 10 characters, amount ≤ 11 digits with ≤ 2 decimals, type is `DEBIT` or `CREDIT`, no extra fields. Amount becomes an exact `Decimal`, never a float. | `account="1000000001"`, `amount=Decimal("125.50")`, `type=DEBIT` |
| 3 | [`main.py`](app/main.py) | Renames JSON fields to COBOL field names. `DEBIT` becomes the code `D`. | `REQ-ACCOUNT="1000000001"`, `REQ-AMOUNT=125.50`, `REQ-TYPE="D"` |
| 4 | [`copybook.py`](app/copybook.py) | Builds the fixed-width record: account padded to 10, amount as sign + 11 digits with the decimal point removed, type as 1 character. | `1000000001+00000012550D` |
| 5 | [`cobol_bridge.py`](app/cobol_bridge.py) | Starts `bin/PAYMENT`, writes the record to its stdin, waits up to 5 seconds. Only one payment runs at a time, so two can't change the same balance at once. | — |
| 6 | [`PAYMENT.cbl`](cobol/PAYMENT.cbl) | `ACCEPT` reads the line into the request fields by position. Validates, reads the account, subtracts, `REWRITE`s the new balance, builds the reference number. | Balance in file: 1,500.00 → 1,374.50 |
| 7 | [`PAYMENT.cbl`](cobol/PAYMENT.cbl) | `DISPLAY` writes the response record to stdout and exits with return code 0. | `APPROVED0000PAYMENT POSTED…1000000001+0000000137450PY2026102216244029` |
| 8 | [`copybook.py`](app/copybook.py) | Cuts the 94 characters at fixed positions, strips padding, converts the balance back to a `Decimal`. | `RSP-STATUS="APPROVED"`, `RSP-NEW-BALANCE=1374.50`, … |
| 9 | [`main.py`](app/main.py) | Renames back to JSON names, sets missing values to `null`, picks HTTP 200 for `APPROVED`. | — |
| 10 | Client | Receives the response | `{"status":"APPROVED", … ,"new_balance":"1374.50","ref_no":"PY2026102216244029"}` |

---

## Input: what you send

**`POST /payment`** with header `Content-Type: application/json`.

```json
{
  "account": "1000000001",
  "amount": 125.50,
  "type": "DEBIT"
}
```

| Field | JSON type | Required | Rules checked by Python (HTTP 422 if broken) | Rules checked by COBOL | Becomes COBOL field |
|---|---|---|---|---|---|
| `account` | string | yes | 1–10 printable ASCII characters | Must be exactly 10 digits (E001), must exist (E006), must not be frozen (E007) | `REQ-ACCOUNT PIC X(10)` |
| `amount` | number or string, e.g. `125.50` or `"125.50"` | yes | At most 9 digits before the decimal point and 2 after | Must be greater than 0 (E003), at most 10,000.00 (E005), a debit must not overdraw the account (E008) | `REQ-AMOUNT PIC S9(9)V99 SIGN LEADING SEPARATE` |
| `type` | string | yes | Exactly `"DEBIT"` (take money out) or `"CREDIT"` (put money in) | Must be `D` or `C` (E004) | `REQ-TYPE PIC X(1)`: `DEBIT`→`D`, `CREDIT`→`C` |

Any other field in the JSON is rejected (HTTP 422), so a typo like `"ammount"` is caught instead of silently ignored.

### The request record COBOL receives (23 characters)

| Positions | Length | Field | Format | Example |
|---|---|---|---|---|
| 1–10 | 10 | `REQ-ACCOUNT` | Text, padded with spaces on the right | `1000000001` |
| 11–22 | 12 | `REQ-AMOUNT` | Sign (`+`/`-`), then 11 digits; the last 2 are decimals | `+00000012550` = 125.50 |
| 23 | 1 | `REQ-TYPE` | `D` or `C` | `D` |

---

## Output: what you get back

Every response that reaches COBOL has the same JSON shape:

```json
{
  "status": "APPROVED",
  "reason_code": "0000",
  "message": "PAYMENT POSTED",
  "account": "1000000001",
  "new_balance": "1374.50",
  "ref_no": "PY2026102216244029"
}
```

| Field | JSON type | Meaning | Comes from COBOL field |
|---|---|---|---|
| `status` | string | Outcome: `APPROVED`, `DECLINED`, `REJECTED`, `NOTFOUND` or `ERROR` | `RSP-STATUS PIC X(8)` |
| `reason_code` | string | `0000` on success, otherwise `E001`–`E008` or `E999` (see the [table below](#all-possible-results)) | `RSP-REASON-CODE PIC X(4)` |
| `message` | string | Human-readable explanation | `RSP-MESSAGE PIC X(40)`, trailing spaces removed |
| `account` | string | The account from the request, echoed back | `RSP-ACCOUNT PIC X(10)` |
| `new_balance` | string or `null` | Balance after the payment, as a string so no cents are lost to floating-point rounding. **Only set when `APPROVED`**; otherwise `null`. | `RSP-NEW-BALANCE PIC S9(11)V99 SIGN LEADING SEPARATE` |
| `ref_no` | string or `null` | Unique reference for the payment: `PY` + date and time to the hundredth of a second. **Only set when `APPROVED`**; otherwise `null`. | `RSP-REF-NO PIC X(18)`, all spaces → `null` |

### The response record COBOL sends (94 characters)

| Positions | Length | Field | Example |
|---|---|---|---|
| 1–8 | 8 | `RSP-STATUS` | `APPROVED` |
| 9–12 | 4 | `RSP-REASON-CODE` | `0000` |
| 13–52 | 40 | `RSP-MESSAGE` | `PAYMENT POSTED` + 26 spaces |
| 53–62 | 10 | `RSP-ACCOUNT` | `1000000001` |
| 63–76 | 14 | `RSP-NEW-BALANCE` | `+0000000137450` = 1,374.50 |
| 77–94 | 18 | `RSP-REF-NO` | `PY2026102216244029` |

### Errors that never reach COBOL

If the JSON is malformed or doesn't fit the record, FastAPI answers **422** with its standard error format and COBOL is never called:

```json
{"detail":[{"type":"decimal_max_places","loc":["body","amount"],"msg":"Decimal input should have no more than 2 decimal places","input":1.005,"ctx":{"decimal_places":2}}]}
```

If the COBOL program can't be run, takes longer than 5 seconds, or replies with a record of the wrong length, the API answers **503**:

```json
{"detail":"Payment service unavailable"}
```

The real cause is written to the server log.

---

## All possible results

| `status` | `reason_code` | `message` | HTTP | COBOL return code | When |
|---|---|---|---|---|---|
| `APPROVED` | `0000` | PAYMENT POSTED | 200 | 0 | Payment posted, balance updated |
| `REJECTED` | `E001` | ACCOUNT MUST BE 10 DIGITS | 400 | 8 | Account contains a non-digit or is shorter than 10 |
| `REJECTED` | `E002` | AMOUNT IS NOT A VALID NUMBER | 400 | 8 | Only when COBOL is called directly; the API always sends a valid number |
| `REJECTED` | `E003` | AMOUNT MUST BE GREATER THAN ZERO | 400 | 8 | Amount is 0 or negative |
| `REJECTED` | `E004` | TYPE MUST BE D (DEBIT) OR C (CREDIT) | 400 | 8 | Only when COBOL is called directly; the API only sends D or C |
| `DECLINED` | `E005` | AMOUNT EXCEEDS SINGLE PAYMENT LIMIT | 422 | 4 | Amount over 10,000.00 |
| `NOTFOUND` | `E006` | ACCOUNT NOT FOUND | 404 | 8 | No account with that number |
| `DECLINED` | `E007` | ACCOUNT IS FROZEN | 422 | 4 | Account status is `F` |
| `DECLINED` | `E008` | INSUFFICIENT FUNDS | 422 | 4 | A debit would make the balance negative |
| `ERROR` | `E999` | ACCOUNT FILE ERROR, FILE STATUS nn | 500 | 12 | The account file is missing or can't be opened/updated |
| — | — | *(FastAPI error list)* | 422 | — | JSON is malformed or doesn't fit the record; COBOL not called |
| — | — | Payment service unavailable | 503 | — | COBOL program missing, timed out, or replied with a bad record |

Nothing in the account file changes unless the status is `APPROVED`.

---

## Setup on a Mac

Tested on macOS 26.4 with GnuCOBOL 3.2, Python 3.13, FastAPI 0.159, Pydantic 2.14 and Uvicorn 0.54.

**1. Install Apple's command-line tools** (C compiler; GnuCOBOL turns COBOL into C and compiles that):

```bash
xcode-select --install
```

**2. Install GnuCOBOL** with [Homebrew](https://brew.sh). This also installs Berkeley DB, which GnuCOBOL uses for indexed files:

```bash
brew install gnucobol
```

**3. Get the code** and go to the project folder:

```bash
git clone https://github.com/Sandeep14865/cobol-payment-api.git
```

```bash
cd cobol-payment-api
```

**4. Create a Python virtual environment**, a private folder `.venv/` for this project's Python packages:

```bash
python3 -m venv .venv
```

**5. Install the Python packages** (FastAPI, Pydantic, Uvicorn at pinned versions):

```bash
.venv/bin/pip install -r requirements.txt
```

---

## Run it

All commands run from the `cobol-payment-api` folder.

**1. Compile the COBOL programs** into `bin/`:

```bash
make build
```

**2. Create the account file** `data/ACCOUNTS.DAT` from `data/accounts.seed`. Run this again any time to reset the balances:

```bash
make seed
```

**3. Start the API** on http://127.0.0.1:8000:

```bash
make run
```

Leave this terminal open. Each payment prints log lines here, including one written by the COBOL program itself, which shows the call really reached COBOL:

```
INFO cobol_bridge: PAYMENT stderr: PAYMENT: APPROVED 0000 ACCT=1000000001 RC=+000000000
INFO payment_api: payment account=1000000001 status=APPROVED reason=0000 rc=0
```

Interactive API docs, where you can try requests from the browser, are at http://127.0.0.1:8000/docs. Stop the server with `Ctrl+C`.

### Demo accounts

Created by `make seed`:

| Account | Name | Status | Starting balance |
|---|---|---|---|
| `1000000001` | Alice Johnson | Active | 1,500.00 |
| `1000000002` | Bob Smith | Active | 25.00 |
| `1000000003` | Carol Diaz | Frozen | 9,000.00 |

---

## Test it

Open a **second** terminal in `cobol-payment-api`, with the server running and freshly seeded.

**Run all 11 test scenarios:**

```bash
make test
```

Each one prints the request, the response and the HTTP status. The title says what to expect.

**Or try one at a time:**

Approved debit:

```bash
curl -s -X POST http://127.0.0.1:8000/payment -H 'Content-Type: application/json' -d '{"account":"1000000001","amount":125.50,"type":"DEBIT"}'
```

```json
{"status":"APPROVED","reason_code":"0000","message":"PAYMENT POSTED","account":"1000000001","new_balance":"1374.50","ref_no":"PY2026102216244029"}
```

Approved credit:

```bash
curl -s -X POST http://127.0.0.1:8000/payment -H 'Content-Type: application/json' -d '{"account":"1000000001","amount":"74.50","type":"CREDIT"}'
```

```json
{"status":"APPROVED","reason_code":"0000","message":"PAYMENT POSTED","account":"1000000001","new_balance":"1449.00","ref_no":"PY2026102216244032"}
```

Declined, not enough money (HTTP 422):

```bash
curl -s -X POST http://127.0.0.1:8000/payment -H 'Content-Type: application/json' -d '{"account":"1000000002","amount":50,"type":"DEBIT"}'
```

```json
{"status":"DECLINED","reason_code":"E008","message":"INSUFFICIENT FUNDS","account":"1000000002","new_balance":null,"ref_no":null}
```

Unknown account (HTTP 404):

```bash
curl -s -X POST http://127.0.0.1:8000/payment -H 'Content-Type: application/json' -d '{"account":"9999999999","amount":10,"type":"CREDIT"}'
```

```json
{"status":"NOTFOUND","reason_code":"E006","message":"ACCOUNT NOT FOUND","account":"9999999999","new_balance":null,"ref_no":null}
```

Health check:

```bash
curl -s http://127.0.0.1:8000/health
```

```json
{"status":"ok"}
```

Reference numbers contain the current date and time, so yours will differ.

### Call the COBOL program without Python

COBOL works on its own. Give it a 23-character request record and it prints a 94-character response record:

```bash
echo "1000000001+00000012550D" | DD_ACCTFILE=data/ACCOUNTS.DAT bin/PAYMENT
```

```
APPROVED0000PAYMENT POSTED                          1000000001+0000000137450PY2026102216222601
PAYMENT: APPROVED 0000 ACCT=1000000001 RC=+000000000
```

The first line is the response record (stdout). The second is the log line (stderr). `DD_ACCTFILE` tells the program where its account file is. The COBOL refers to the file only by the logical name `ACCTFILE`, much as a mainframe program refers to a JCL DD name.

---

## Project files

```
cobol-payment-api/
├── README.md                this file
├── GUIDE.md                 in-depth walkthrough, mainframe comparison, self-test questions
├── Makefile                 build / seed / run / test / clean
├── requirements.txt         pinned Python packages
├── cobol/
│   ├── PAYMENT.cbl          the business program: validates and posts one payment
│   ├── ACCTLOAD.cbl         creates ACCOUNTS.DAT from the seed file
│   ├── PAYJSON.cbl          side demo: COBOL's own JSON GENERATE (not used by the API)
│   └── copybooks/
│       ├── PAYREQ.cpy       request record layout (23 chars)
│       ├── PAYRSP.cpy       response record layout (94 chars)
│       └── ACCTREC.cpy      account record layout (balance stored as packed decimal)
├── app/
│   ├── main.py              HTTP routes; maps JSON names ⇄ COBOL names; picks HTTP status
│   ├── models.py            JSON request/response definitions and format checks
│   ├── copybook.py          Python copy of PAYREQ/PAYRSP; builds and reads records
│   └── cobol_bridge.py      runs bin/PAYMENT; timeout, locking, error handling
├── data/
│   ├── accounts.seed        demo accounts as plain text
│   └── ACCOUNTS.DAT         indexed account file (created by make seed, not in git)
├── bin/                     compiled COBOL programs (created by make build, not in git)
└── tests/
    └── curl_tests.sh        11 curl scenarios
```

| Command | What it does |
|---|---|
| `make build` | Compiles each `.cbl` with `cobc -x -Wall -I cobol/copybooks`. Recompiles when a program or copybook changes. |
| `make seed` | Rebuilds `data/ACCOUNTS.DAT` with the demo balances. |
| `make run` | Starts the API with auto-reload on Python changes. |
| `make test` | Runs `tests/curl_tests.sh` against the running API. |
| `make clean` | Deletes `bin/` and `data/ACCOUNTS.DAT`. |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `curl: (7) Failed to connect` | The API isn't running | `make run` in another terminal |
| Every payment returns 503 | `bin/PAYMENT` is missing, or out of step with `copybook.py` | `make build`, and check the server log for the real reason |
| `status: ERROR`, `E999`, file status 35 | `data/ACCOUNTS.DAT` doesn't exist | `make seed` |
| `GET /health` returns 503 | Binary or data file missing; the response says which | `make build` and/or `make seed` |
| Balances aren't what the examples show | Earlier tests already changed them | `make seed` to reset |
| `cobc: command not found` | GnuCOBOL not installed | `brew install gnucobol` |

## Known limitations

This is a demo, not production code:

- **Reference numbers can repeat** if two payments are approved within the same hundredth of a second.
- **Safe for one server process only.** The lock that prevents two payments changing the same balance at once lives inside the Python process. Running several Uvicorn workers would need locking in the data layer instead.
- **A retried request posts twice.** There's no idempotency key.
- **No authentication or HTTPS.**
- **ASCII only.** A real mainframe uses EBCDIC and packed-decimal fields, which `copybook.py` doesn't handle.

[GUIDE.md](GUIDE.md) discusses each of these and how production systems solve them.
