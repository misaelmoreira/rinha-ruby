require 'pg'
require 'connection_pool'

class Database
  DEFAULT_POOL_SIZE = 10
  DEFAULT_PORT = 5431

  def self.pool
    @pool ||= ConnectionPool.new(size: pool_size, timeout: 300) { new_connection }
  end

  def self.new_connection
    config = {
      host: ENV.fetch('DATABASE_HOST', 'localhost'),
      port: ENV.fetch('DATABASE_PORT', DEFAULT_PORT),
      user: ENV.fetch('DATABASE_USER', 'postgres'),
      password: ENV.fetch('DATABASE_PASSWORD', 'postgres'),
      dbname: ENV.fetch('DATABASE_NAME', 'postgres')
    }

    PG::Connection.connect(config)
  end

  def self.pool_size
    ENV.fetch('DB_POOL_SIZE', DEFAULT_POOL_SIZE).to_i
  end
end
