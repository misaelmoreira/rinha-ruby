require "socket"
require 'json'

require_relative "app/request"
require_relative 'app/handler'

server = Socket.new(:INET, :STREAM)
server.setsockopt(:SOL_SOCKET, :SO_REUSEADDR, true)
addr = Socket.pack_sockaddr_in(3000, "0.0.0.0")

server.bind(addr)
server.listen(Socket::SOMAXCONN)

puts "Listening on port 3000"

@scheduler = {
  readable: {},
  writeable: {},
  fibers: [],
}

controller = lambda do |client|
  Handler.call(client)
end

acceptor = lambda do |io|
  loop do
    client, _ = io.accept_nonblock

    @scheduler[:fibers] << [controller, [client]]
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
      @scheduler[:fibers].delete_at(idx) 
    elsif handle.is_a?(Proc)
      fiber = Fiber.new(&handle)
      fiber.resume(*args)
      @scheduler[:fibers].delete_at(idx)
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
