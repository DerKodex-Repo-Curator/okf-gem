# frozen_string_literal: true

require "stringio"
require "webrick"

require_relative "server"

module OKF
  module MCP
    # Bridges the SDK's StreamableHTTPTransport — a plain Rack app — onto the
    # WEBrick that okf already depends on, mirroring the kernel's
    # server/runner pattern (rack and webrick both arrive via the okf gem).
    # Stateless JSON mode: every POST is a self-contained JSON-RPC exchange
    # answered with a single JSON object, so plain buffered responses hold —
    # no SSE stream to keep open. The SDK validates Host/Origin against DNS
    # rebinding for locally bound servers.
    module HTTP
      module_function

      # The Hosts the SDK's StreamableHTTPTransport admits without any extra
      # allowlist — its DNS-rebinding protection accepts these out of the box.
      LOOPBACK_HOSTS = %w[127.0.0.1 ::1 localhost].freeze

      def serve(server, bind:, port:, out: $stderr)
        app = app_for(server, bind: bind)
        httpd = build(app, bind: bind, port: port)
        %w[INT TERM].each { |signal| trap(signal) { httpd.shutdown } }
        # The listener's own port, not the asked-for one: with --port 0 the OS
        # picks, and a boot line reporting 0 would name a port nothing answers.
        bound = httpd.listeners.first.addr[1]
        out.puts("okf-mcp listening on http://#{bind}:#{bound}")
        httpd.start
      end

      # The SDK transport wired to the server, in stateless JSON mode. A
      # non-loopback bind (e.g. 0.0.0.0) is refused by the SDK's DNS-rebinding
      # guard unless its Host is allowlisted; loopback binds keep the SDK
      # defaults. Protection itself stays on either way.
      def app_for(server, bind:, allowed_hosts: allowed_hosts_for(bind))
        options = { stateless: true, enable_json_response: true }
        options[:allowed_hosts] = allowed_hosts if allowed_hosts
        app = ::MCP::Server::Transports::StreamableHTTPTransport.new(server, **options)
        server.transport = app
        app
      end

      # The Host allowlist a bind address needs: nil for loopback (the SDK
      # already admits it), [ bind ] otherwise — each entry matches the bare
      # host on any port or a full host:port.
      def allowed_hosts_for(bind)
        return nil if LOOPBACK_HOSTS.include?(bind)

        [ bind ]
      end

      # Returns an unstarted server so tests can drive an ephemeral port.
      def build(app, bind:, port:)
        httpd = WEBrick::HTTPServer.new(
          BindAddress: bind,
          Port: port,
          Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN),
          AccessLog: []
        )
        httpd.mount_proc("/") { |request, response| handle(app, request, response) }
        httpd
      end

      def handle(app, request, response)
        status, headers, body = app.call(env_for(request))
        response.status = status
        headers.each { |name, value| response[name] = value }
        buffer = String.new
        body.each { |chunk| buffer << chunk }
        response.body = buffer
      ensure
        body.close if body.respond_to?(:close)
      end

      def env_for(request)
        env = {
          "REQUEST_METHOD" => request.request_method,
          "SCRIPT_NAME" => "",
          "PATH_INFO" => request.path,
          "QUERY_STRING" => request.query_string.to_s,
          "SERVER_NAME" => request.host.to_s,
          "SERVER_PORT" => request.port.to_s,
          "rack.url_scheme" => "http",
          "rack.input" => StringIO.new(request.body.to_s),
          "rack.errors" => $stderr
        }
        request.each do |name, value|
          key = name.upcase.tr("-", "_")
          key = "HTTP_#{key}" unless %w[CONTENT_TYPE CONTENT_LENGTH].include?(key)
          env[key] = value
        end
        env
      end
    end
  end
end
