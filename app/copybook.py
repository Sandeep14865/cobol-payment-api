"""Python mirror of the COBOL copybooks PAYREQ and PAYRSP.

Each Field says how wide a COBOL field is and how its characters are
encoded. Fields are laid out back to back in the order given, exactly
as the 05-level items follow each other in the copybook. If a copybook
changes, this file must change with it.
"""

from dataclasses import dataclass
from decimal import Decimal


class RecordMappingError(ValueError):
    """A value does not fit its COBOL field, or a record is malformed."""


@dataclass(frozen=True)
class Field:
    name: str  # COBOL data name, used as the dict key
    length: int  # characters the field occupies in the record
    kind: str  # "X": PIC X(n)   "S9V": PIC S9(n)V9(d) SIGN LEADING SEPARATE
    scale: int = 0  # digits after the implied decimal point (the V)


class Layout:
    def __init__(self, name: str, *fields: Field):
        self.name = name
        self.fields = fields
        self.record_length = sum(f.length for f in fields)

    def encode(self, values: dict) -> str:
        """dict of Python values -> one fixed-width record."""
        return "".join(_encode_field(f, values[f.name]) for f in self.fields)

    def decode(self, record: str) -> dict:
        """One fixed-width record -> dict of Python values."""
        if len(record) != self.record_length:
            raise RecordMappingError(
                f"{self.name}: expected {self.record_length} characters, "
                f"got {len(record)}"
            )
        values, offset = {}, 0
        for f in self.fields:
            values[f.name] = _decode_field(f, record[offset : offset + f.length])
            offset += f.length
        return values


def _encode_field(f: Field, value) -> str:
    if f.kind == "X":
        # COBOL pads alphanumeric fields with spaces on the right. We
        # refuse to truncate: silently cutting data is how records break.
        if not value.isascii() or not value.isprintable():
            raise RecordMappingError(f"{f.name}: only printable ASCII is allowed")
        if len(value) > f.length:
            raise RecordMappingError(f"{f.name}: longer than {f.length} characters")
        return value.ljust(f.length)

    if f.kind == "S9V":
        # Sign character, then digits with the decimal point removed:
        # 125.50 in S9(9)V99 -> "+00000012550".
        digits = f.length - 1
        scaled = Decimal(value).scaleb(f.scale)
        if scaled != scaled.to_integral_value():
            raise RecordMappingError(f"{f.name}: more than {f.scale} decimal places")
        n = int(scaled)
        if abs(n) >= 10**digits:
            raise RecordMappingError(f"{f.name}: too large for the field")
        return ("-" if n < 0 else "+") + str(abs(n)).zfill(digits)

    raise RecordMappingError(f"{f.name}: unknown field kind {f.kind!r}")


def _decode_field(f: Field, text: str):
    if f.kind == "X":
        return text.rstrip()  # drop COBOL's space padding

    if f.kind == "S9V":
        sign, digits = text[0], text[1:]
        if sign not in "+-" or not digits.isdigit():
            raise RecordMappingError(f"{f.name}: {text!r} is not a signed number")
        value = Decimal(digits).scaleb(-f.scale)
        return -value if sign == "-" else value

    raise RecordMappingError(f"{f.name}: unknown field kind {f.kind!r}")


# cobol/copybooks/PAYREQ.cpy (23 characters)
PAYREQ = Layout(
    "PAYMENT-REQUEST",
    Field("REQ-ACCOUNT", 10, "X"),
    Field("REQ-AMOUNT", 12, "S9V", scale=2),  # S9(9)V99 + sign
    Field("REQ-TYPE", 1, "X"),
)

# cobol/copybooks/PAYRSP.cpy (94 characters)
PAYRSP = Layout(
    "PAYMENT-RESPONSE",
    Field("RSP-STATUS", 8, "X"),
    Field("RSP-REASON-CODE", 4, "X"),
    Field("RSP-MESSAGE", 40, "X"),
    Field("RSP-ACCOUNT", 10, "X"),
    Field("RSP-NEW-BALANCE", 14, "S9V", scale=2),  # S9(11)V99 + sign
    Field("RSP-REF-NO", 18, "X"),
)
