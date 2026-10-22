"""JSON shapes of the API. Pydantic checks structure (types, sizes that
must fit the COBOL fields); business rules stay in COBOL."""

from decimal import Decimal
from enum import Enum
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class PaymentType(str, Enum):
    DEBIT = "DEBIT"
    CREDIT = "CREDIT"


class PaymentRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    # max_length matches PIC X(10). Whether it is all digits is a
    # business rule, checked by COBOL (reason code E001).
    account: str = Field(min_length=1, max_length=10, examples=["1000000001"])
    # max_digits/decimal_places match PIC S9(9)V99. Whether it is
    # positive and within the limit is checked by COBOL (E003, E005).
    amount: Decimal = Field(max_digits=11, decimal_places=2, examples=["125.50"])
    type: PaymentType


class PaymentResponse(BaseModel):
    status: Literal["APPROVED", "DECLINED", "REJECTED", "NOTFOUND", "ERROR"]
    reason_code: str
    message: str
    account: str
    new_balance: Decimal | None  # only set when APPROVED
    ref_no: str | None  # only set when APPROVED
