SELECT
  amount,
  transaction_type,
  description,
  TO_CHAR(date, 'YYYY-MM-DD HH:MI:SS.US') AS date
FROM
  transactions
WHERE
  transactions.account_id = $1
ORDER BY date DESC
LIMIT 10