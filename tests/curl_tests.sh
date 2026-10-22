#!/usr/bin/env bash
# Calls POST /payment with one request per scenario and prints the HTTP
# status and JSON body. Run "make seed" first for the expected balances.
# Usage: ./tests/curl_tests.sh [base-url]

BASE="${1:-http://127.0.0.1:8000}"

call() {
  local title="$1" body="$2"
  echo "== $title"
  echo "   request : $body"
  curl -s -w '\n   http    : %{http_code}\n' -X POST "$BASE/payment" \
    -H 'Content-Type: application/json' -d "$body" | sed '1s/^/   response: /'
  echo
}

call "1. Debit approved (1500.00 - 125.50)" '{"account":"1000000001","amount":125.50,"type":"DEBIT"}'
call "2. Credit approved"                   '{"account":"1000000001","amount":"74.50","type":"CREDIT"}'
call "3. Insufficient funds (E008)"         '{"account":"1000000002","amount":50,"type":"DEBIT"}'
call "4. Frozen account (E007)"             '{"account":"1000000003","amount":10,"type":"CREDIT"}'
call "5. Unknown account (E006)"            '{"account":"9999999999","amount":10,"type":"CREDIT"}'
call "6. Account not numeric (E001)"        '{"account":"ABC1234567","amount":10,"type":"CREDIT"}'
call "7. Negative amount (E003)"            '{"account":"1000000001","amount":-5,"type":"DEBIT"}'
call "8. Over single-payment limit (E005)"  '{"account":"1000000001","amount":10000.01,"type":"DEBIT"}'
call "9. Three decimals (Pydantic)"         '{"account":"1000000001","amount":1.005,"type":"DEBIT"}'
call "10. Unknown type (Pydantic)"          '{"account":"1000000001","amount":1,"type":"REFUND"}'
call "11. Account too long (Pydantic)"      '{"account":"10000000011","amount":1,"type":"DEBIT"}'
