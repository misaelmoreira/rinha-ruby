require_relative 'database'

class BankStatement
  class NotFoundError < StandardError; end

  def self.call(*args)
    new(*args).call
  end

  def initialize(account_id)
    @account_id = account_id
  end

  def call
    result = {}

    Database.pool.with do |conn|

      poll_status = conn.connect_poll

      until poll_status == PG::PGRES_POLLING_OK || poll_status == PG::PGRES_POLLING_FAILED
        case poll_status
        in PG::PGRES_POLLING_READING
          @scheduler[:readable][conn.socket_io] = Fiber.current
          Fiber.yield
        in PG::PGRES_POLLING_WRITING
          @scheduler[:writeable][conn.socket_io] = Fiber.current
          Fiber.yield
        end

        poll_status = conn.connect_poll
      end

      conn.transaction do
        account = send_query(conn, sql_select_account, [@account_id]).first
        raise NotFoundError unless account

        result["saldo"] = {
          "total": account['balance'].to_i,
          "data_extrato": Time.now.strftime("%Y-%m-%d"),
          "limite": account['limit_amount'].to_i
        }

        ten_transactions = send_query(conn, sql_ten_transactions, [@account_id])
        ten_transactions = [] unless ten_transactions

        result["ultimas_transacoes"] = ten_transactions.map do |transaction|
          {
            "valor": transaction['amount'].to_i,
            "tipo": transaction['transaction_type'],
            "descricao": transaction['description'],
            "realizada_em": transaction['date']
          }
        end
      end

      result
    end
  end

  private

  def send_query(conn, sql, params)
    conn.send_query_params(sql, params)

    while conn.is_busy
      # @scheduler[:readable][conn.socket_io] = Fiber.current
      # Fiber.yield
      conn.consume_input
    end

    result = conn.get_result

    conn.discard_results

    result.to_a
  end

  def sql_ten_transactions
    <<~SQL
      SELECT amount, transaction_type, description, TO_CHAR(date, 'YYYY-MM-DD HH:MI:SS.US') AS date
      FROM transactions
      WHERE transactions.account_id = $1
      ORDER BY date DESC
      LIMIT 10
    SQL
  end

  def sql_select_account
    <<~SQL
      SELECT balance, limit_amount
      FROM accounts
      WHERE id = $1
    SQL
  end
end
