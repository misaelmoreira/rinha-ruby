SELECT
    limit_amount,
    balance
FROM accounts
WHERE id = $1