require 'pg'
require 'connection_pool'
require 'socket'

require_relative 'app/request'
require_relative 'app/database'

server = Socket.new(:INET, :STREAM)
server.setsockopt(:SOL_SOCKET, :SO_REUSEADDR, true)
addr = Socket.pack_sockaddr_in(3000, '0.0.0.0')

server.bind(addr)
server.listen(Socket::SOMAXCONN)

class NotFoundError < StandardError; end
class InvalidDataError < StandardError; end
class InvalidLimitAmountError < StandardError; end

puts 'Listening on port 3000'

@scheduler = {
  readable: {},
  writeable: {},
  fibers: []
}

responder = lambda do |client, status, body|
  client.puts "HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n\r\n#{body.to_json}"
  client.close
end


controller = lambda do |client, request, params|
  case request
  in 'GET /clientes/:id/extrato'
    sql_account = File.read('sql/account.sql')
    sql_ten_transactions = File.read('sql/ten_transactions.sql')

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

      conn.send_query_params(sql_account, [params['id']])

      while conn.is_busy
        # @scheduler[:readable][conn.socket_io] = Fiber.current
        # Fiber.yield
        conn.consume_input
      end

      result = conn.get_result
      conn.discard_results

      account = result.to_a.first
      raise NotFoundError unless account

      conn.send_query_params(sql_ten_transactions, [params['id']])

      while conn.is_busy
        # exemplo para fibers => @scheduler[:fibers] << [Fiber.current, []]
        # @scheduler[:readable][conn.socket_io] = Fiber.current
        # Fiber.yield
        conn.consume_input
      end

      result = conn.get_result
      conn.discard_results

      ten_transactions = result.to_a

      body = {
        "saldo": {
          "total": account['balance'].to_i,
          "data_extrato": Time.now.strftime('%Y=%m-%d'),
          "limite": account['limit_amount'].to_i
        },
        "ultimas_transacoes": ten_transactions.map do |transaction|
          {
            "valor": transaction['amount'].to_i,
            "tipo": transaction['transaction_type'],
            "descricao": transaction['description'],
            "realizada_em": transaction['date']
          }
        end
      }

      Fiber.new(&responder).resume(client, 200, body)
    end
  in 'POST /clientes/:id/transacoes'
    status = 200

    reached_limit = lambda do |balance, amount, limit_amount|
      return false if (balance - amount) > limit_amount

      (balance - amount).abs > limit_amount
    end

    raise InvalidDataError unless params['id'] && params['valor'] && params['tipo'] && params['descricao']
    raise InvalidDataError if params['descricao'] && params['descricao'].empty?
    raise InvalidDataError if params['descricao'] && params['descricao'].size > 10
    raise InvalidDataError if params['valor'] && (!params['valor'].is_a?(Integer) || !params['valor'].positive?)
    raise InvalidDataError unless %w[d c].include?(params['tipo'])

    operator = params['tipo'] == 'd' ? '-' : '+'

    sql_insert_transaction = <<~SQL
      INSERT INTO transactions (account_id, amount, transaction_type, description)
      VALUES ($1, $2, $3, $4)
    SQL

    sql_update_balance = <<~SQL
      UPDATE accounts
      SET balance = balance #{operator} $2
      WHERE id = $1
    SQL

    sql_select_account = <<~SQL
      SELECT
        limit_amount,
        balance
      FROM accounts
      WHERE id = $1
      FOR UPDATE
    SQL

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
        # account = db.resume(conn, sql_select_account, [params['id']]).first
        conn.send_query_params(sql_select_account, [params['id']])

        while conn.is_busy
          # @scheduler[:readable][conn.socket_io] = Fiber.current
          # Fiber.yield
          conn.consume_input
        end

        result = conn.get_result
        conn.discard_results

        account = result.to_a.first

        raise NotFoundError unless account
        limit_amount = account['limit_amount'].to_i
        balance = account['balance'].to_i
        amount = params['valor'].to_i

        raise InvalidDataError if params['tipo'] == 'd' && reached_limit.call(balance, amount, limit_amount)

        # db.resume(conn, sql_insert_transaction, params.values_at('id', 'valor', 'tipo', 'descricao'))
        conn.send_query_params(sql_insert_transaction, params.values_at('id', 'valor', 'tipo', 'descricao'))
        conn.discard_results

        # db.resume(conn, sql_update_balance, params.values_at('id', 'valor'))
        conn.send_query_params(sql_update_balance, params.values_at('id', 'valor'))
        conn.discard_results

        body = {
          "limite": account['limit_amount'].to_i,
          "saldo": account['balance'].to_i
        }

        Fiber.new(&responder).resume(client, status, body)

      end
    end
  else
    raise NotFoundError
  end
rescue InvalidDataError
  Fiber.new(&responder).resume(client, 422, {})
rescue NotFoundError
  Fiber.new(&responder).resume(client, 404, {})
end

acceptor = lambda do |io|
  loop do
    client, _ = io.accept_nonblock
    request, params = Request.parse(client)

    # Fiber.new(&controller).resume(client, request, params)
    @scheduler[:fibers] << [controller, [client, request, params]]
    rescue IO::WaitReadable, Errno::EINTR, IO::EAGAINWaitReadable
      @scheduler[:readable][io] = Fiber.current
      Fiber.yield
    end
end

Fiber.new(&acceptor).resume(server)

# Event Loop (async)
loop do
  #  Calling Callbacks
  @scheduler[:fibers].each_with_index do |(handle, args), idx|
    if handle.is_a?(Fiber)
      handle.resume(*args) if handle.alive?
      @scheduler[:fibers].delete_at(idx) # unless handle.alive?
    elsif handle.is_a?(Proc)
      fiber = Fiber.new(&handle)
      fiber.resume(*args)
      @scheduler[:fibers].delete_at(idx) # unless fiber.alive?
    end
  end

  # reading
  readable = @scheduler[:readable].keys
  reads, _, _ = IO.select(readable, nil, nil, 0.1)

  # nonblocking
  # itera sobre a lista de sockets prontos
  reads&.each do |io|
      fiber = @scheduler[:readable].delete(io)
      fiber.resume
  end

  # writable
  writeable = @scheduler[:writeable].keys
  _, writes, _ = IO.select(nil, writeable, nil, 0.1)

  # nonblocking
  # itera sobre a lista de sockets prontos
  writes&.each do |io|
      fiber = @scheduler[:writeable].delete(io)
      fiber.resume()
  end
end
