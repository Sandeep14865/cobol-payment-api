"""FastAPI front end for the COBOL PAYMENT program."""

import logging

from fastapi import FastAPI, HTTPException, Response

from .cobol_bridge import ACCOUNT_FILE, PAYMENT_BIN, CobolCallError, call_payment
from .copybook import RecordMappingError
from .models import PaymentRequest, PaymentResponse, PaymentType

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
log = logging.getLogger("payment_api")

app = FastAPI(title="COBOL Payment API", version="1.0.0")

# JSON enum value -> 1-character code in REQ-TYPE (88 REQ-DEBIT / REQ-CREDIT)
TYPE_CODES = {PaymentType.DEBIT: "D", PaymentType.CREDIT: "C"}

# RSP-STATUS -> HTTP status code
HTTP_STATUS = {
    "APPROVED": 200,
    "DECLINED": 422,  # valid request, refused by a business rule
    "REJECTED": 400,  # request content invalid
    "NOTFOUND": 404,
    "ERROR": 500,
}


@app.post("/payment", response_model=PaymentResponse)
def post_payment(req: PaymentRequest, response: Response):
    # 1. JSON -> COBOL field values
    request_fields = {
        "REQ-ACCOUNT": req.account,
        "REQ-AMOUNT": req.amount,
        "REQ-TYPE": TYPE_CODES[req.type],
    }

    # 2. Call COBOL
    try:
        result = call_payment(request_fields)
    except RecordMappingError as e:
        raise HTTPException(status_code=422, detail=str(e))
    except CobolCallError as e:
        log.error("COBOL call failed: %s", e)
        raise HTTPException(status_code=503, detail="Payment service unavailable")

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


@app.get("/health")
def health():
    ok = PAYMENT_BIN.exists() and ACCOUNT_FILE.exists()
    if not ok:
        raise HTTPException(
            status_code=503,
            detail={"payment_bin": PAYMENT_BIN.exists(), "account_file": ACCOUNT_FILE.exists()},
        )
    return {"status": "ok"}
