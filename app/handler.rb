require 'json'

require_relative 'bank_statement'
require_relative 'transaction'

class Handler
  VALIDATION_ERRORS = [
    PG::InvalidTextRepresentation,
    PG::StringDataRightTruncation,
    Transaction::InvalidDataError,
    Transaction::InvalidLimitAmountError
  ].freeze


  def self.call(*args)
    new(*args).handle
  end

  def initialize(client)
    @client = client
  end

  def handle
    begin
      ########## Request ##########
      request, params = Request.parse(@client)

      ########## Response ##########
      status = nil
      body = '{}'

      case request
      in "GET /clientes/:id/extrato"
        status = 200
        body = BankStatement.call(params['id']).to_json

      in "POST /clientes/:id/transacoes"
        status = 200
        body = Transaction.call(
          params['id'],
          params['valor'],
          params['tipo'],
          params['descricao']
        ).to_json

      else
        raise NotFoundError
      end
    rescue PG::ForeignKeyViolation, BankStatement::NotFoundError, Transaction::NotFoundError
      status = 404
    rescue *VALIDATION_ERRORS => err
      status = 422
      body = { error: err.message }.to_json
    end

    response(@client, body, status)
  end

  def response(cliente, body, status)
    cliente.puts "HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n\r\n#{body}"
    cliente.close
  end
end
