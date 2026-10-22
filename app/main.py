"""FastAPI front end for the COBOL PAYMENT and BALINQ programs."""

import logging
from datetime import datetime
from typing import Annotated

from fastapi import FastAPI, HTTPException, Path, Response

from .cobol_bridge import (
    ACCOUNT_FILE,
    BALINQ_BIN,
    PAYMENT_BIN,
    CobolCallError,
    call_balance_inquiry,
    call_payment,
)
from .copybook import RecordMappingError
from .models import AccountStatus, BalanceResponse, PaymentRequest, PaymentResponse, PaymentType

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
log = logging.getLogger("payment_api")

app = FastAPI(title="COBOL Payment API", version="1.1.0")

# JSON enum value -> 1-character code in REQ-TYPE (88 REQ-DEBIT / REQ-CREDIT)
TYPE_CODES = {PaymentType.DEBIT: "D", PaymentType.CREDIT: "C"}

# 1-character code in BRS-ACCT-STATUS (88 ACCT-ACTIVE / ACCT-FROZEN) -> JSON enum value
ACCOUNT_STATUS_NAMES = {"A": AccountStatus.ACTIVE, "F": AccountStatus.FROZEN}

# RSP-STATUS / BRS-STATUS -> HTTP status code
HTTP_STATUS = {
    "APPROVED": 200,
    "FOUND": 200,
    "DECLINED": 422,  # valid request, refused by a business rule
    "REJECTED": 400,  # request content invalid
    "NOTFOUND": 404,
    "ERROR": 500,
}


def _call_cobol(call, request_fields: dict):
    """Run a COBOL call and turn bridge failures into HTTP errors."""
    try:
        return call(request_fields)
    except RecordMappingError as e:
        raise HTTPException(status_code=422, detail=str(e))
    except CobolCallError as e:
        log.error("COBOL call failed: %s", e)
        raise HTTPException(status_code=503, detail="Payment service unavailable")


@app.post("/payment", response_model=PaymentResponse)
def post_payment(req: PaymentRequest, response: Response):
    # 1. JSON -> COBOL field values
    request_fields = {
        "REQ-ACCOUNT": req.account,
        "REQ-AMOUNT": req.amount,
        "REQ-TYPE": TYPE_CODES[req.type],
    }

    # 2. Call COBOL
    result = _call_cobol(call_payment, request_fields)

    # 3. COBOL field values -> JSON
    f = result.fields
    approved = f["RSP-STATUS"] == "APPROVED"
    body = PaymentResponse(
        status=f["RSP-STATUS"],
        reason_code=f["RSP-REASON-CODE"],
        message=f["RSP-MESSAGE"],
        account=f["RSP-ACCOUNT"],
        new_balance=f["RSP-NEW-BALANCE"] if approved else None,
        ref_no=f["RSP-REF-NO"] or None,
    )
    log.info(
        "payment account=%s status=%s reason=%s rc=%d",
        body.account, body.status, body.reason_code, result.return_code,
    )
    response.status_code = HTTP_STATUS[body.status]
    return body


@app.get("/accounts/{account}/balance", response_model=BalanceResponse)
def get_balance(
    account: Annotated[str, Path(min_length=1, max_length=10, examples=["1000000001"])],
    response: Response,
):
    # 1. URL path -> COBOL field values
    request_fields = {"BRQ-ACCOUNT": account}

    # 2. Call COBOL
    result = _call_cobol(call_balance_inquiry, request_fields)

    # 3. COBOL field values -> JSON
    f = result.fields
    found = f["BRS-STATUS"] == "FOUND"
    try:
        body = BalanceResponse(
            status=f["BRS-STATUS"],
            reason_code=f["BRS-REASON-CODE"],
            message=f["BRS-MESSAGE"],
            account=f["BRS-ACCOUNT"],
            name=f["BRS-NAME"] if found else None,
            account_status=ACCOUNT_STATUS_NAMES[f["BRS-ACCT-STATUS"]] if found else None,
            balance=f["BRS-BALANCE"] if found else None,
            as_of=datetime.strptime(f["BRS-AS-OF"], "%Y%m%d%H%M%S") if found else None,
        )
    except (KeyError, ValueError) as e:
        # Unknown account status code or unreadable timestamp from COBOL
        log.error("bad response record from BALINQ: %r", e)
        raise HTTPException(status_code=503, detail="Payment service unavailable")
    log.info(
        "balance account=%s status=%s reason=%s rc=%d",
        body.account, body.status, body.reason_code, result.return_code,
    )
    response.status_code = HTTP_STATUS[body.status]
    return body


@app.get("/health")
def health():
    checks = {
        "payment_bin": PAYMENT_BIN.exists(),
        "balance_bin": BALINQ_BIN.exists(),
        "account_file": ACCOUNT_FILE.exists(),
    }
    if not all(checks.values()):
        raise HTTPException(status_code=503, detail=checks)
    return {"status": "ok"}
