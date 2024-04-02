require_relative 'database'

class Transaction
  class InvalidDataError < StandardError; end
  class InvalidLimitAmountError < StandardError; end
  class NotFoundError < StandardError; end

  def self.call(*args)
    new(*args).call
  end

  def initialize(account_id, amount, transaction_type, description)
    @account_id = account_id
    @amount = amount
    @transaction_type = transaction_type
    @description = description
  end

  def call
    result = {}

    raise InvalidDataError unless @account_id && @amount && @transaction_type && @description
    raise InvalidDataError if @description && @description.empty?
    raise InvalidDataError if @description && @description.size > 10
    raise InvalidDataError if @amount && (!@amount.is_a?(Integer) || !@amount.positive?)
    raise InvalidDataError unless %w[d c].include?(@transaction_type)

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

        limit_amount = account['limit_amount'].to_i
        balance = account['balance'].to_i

        raise InvalidLimitAmountError if @transaction_type == 'd' &&
                                          reaching_limit?(balance, limit_amount, @amount)

        conn.exec_params(sql_insert_transaction, [@account_id, @amount, @transaction_type, @description])
        conn.discard_results

        case @transaction_type
        in 'c' then conn.exec_params(sql_increase_balance, [@account_id, @amount])
        in 'd' then conn.exec_params(sql_decrease_balance, [@account_id, @amount])
        end
        conn.discard_results

        account = send_query(conn, sql_select_account, [@account_id]).first

        result.merge!({
          limite: account['limit_amount'].to_i,
          saldo: account['balance'].to_i
        })
      end
    end

    result
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

  def sql_increase_balance
    <<~SQL
      UPDATE accounts
      SET balance = balance + $2
      WHERE id = $1
    SQL
  end

  def sql_decrease_balance
    <<~SQL
      UPDATE accounts
      SET balance = balance - $2
      WHERE id = $1
    SQL
  end

  def sql_insert_transaction
    <<~SQL
      INSERT INTO transactions (account_id, amount, transaction_type, description)
      VALUES ($1, $2, $3, $4)
    SQL
  end

  def sql_select_account
    <<~SQL
      SELECT balance, limit_amount
      FROM accounts
      WHERE id = $1
      FOR UPDATE
    SQL
  end

  def reaching_limit?(balance, limit_amount, amount)
    return false if (balance - amount) > limit_amount
    (balance - amount).abs > limit_amount
  end
end
