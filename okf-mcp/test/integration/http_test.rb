# frozen_string_literal: true

require_relative "mcp_integration_case"
require "okf/mcp/http"
require "net/http"

# The same server definition over Streamable HTTP: a real WEBrick on a real
# socket, stateless JSON mode — one POST in, one JSON object out — and the
# SDK's DNS-rebinding protection observed from the outside.
class HTTPTest < MCPIntegrationCase
  test "serves initialize and a tool call over one warm process" do
    with_http_server do |port|
      response = post(port, { jsonrpc: "2.0", id: 1, method: "initialize",
                              params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "0" } } })
      assert_equal "okf", JSON.parse(response.body).dig("result", "serverInfo", "name")

      response = post(port, { jsonrpc: "2.0", id: 2, method: "tools/call",
                              params: { name: "search", arguments: { terms: [ "invoices" ] } } })
      result = JSON.parse(response.body).fetch("result")
      refute result["isError"]
      data = JSON.parse(result.dig("content", 0, "text"))
      assert_operator data["total"], :>, 0
    end
  end

  test "a foreign Host header is refused — DNS-rebinding protection stays on" do
    with_http_server do |port|
      response = post(port, { jsonrpc: "2.0", id: 1, method: "initialize",
                              params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "0" } } },
        host: "evil.example")
      assert_equal "403", response.code
    end
  end

  test "the spawned exe serves --http, announces the real port, and dies cleanly on TERM" do
    require "open3"
    require "timeout"
    exe = File.expand_path("../../exe/okf-mcp", __dir__)
    Timeout.timeout(30) do
      Open3.popen3(RbConfig.ruby, "-rbundler/setup", "-I#{File.expand_path("../../lib", __dir__)}",
        exe, "--http", "--port", "0", fixture("knowledge")) do |_stdin, _stdout, stderr, wait|
        match = nil
        while (line = stderr.gets)
          break if (match = line.match(%r{listening on http://127\.0\.0\.1:(\d+)}))
        end
        port = match && match[1].to_i
        refute_nil port
        assert_operator port, :>, 0, "the boot line names the bound port, not the asked-for 0"

        response = post(port, { jsonrpc: "2.0", id: 1, method: "initialize",
                                params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "0" } } })
        assert_equal "okf", JSON.parse(response.body).dig("result", "serverInfo", "name")

        Process.kill("TERM", wait.pid)
        assert_equal 0, wait.value.exitstatus
      end
    end
  end

  test "a non-loopback bind gets itself allowlisted; loopback keeps the SDK defaults" do
    assert_nil OKF::MCP::HTTP.allowed_hosts_for("127.0.0.1")
    assert_nil OKF::MCP::HTTP.allowed_hosts_for("localhost")
    assert_equal [ "0.0.0.0" ], OKF::MCP::HTTP.allowed_hosts_for("0.0.0.0")
  end

  private

  # The composition #serve performs, on an ephemeral port a test can own:
  # the wired transport, the WEBrick bridge, a thread to run it.
  def with_http_server
    registry = OKF::MCP::Registry.from_argv([ fixture("knowledge") ])
    server = OKF::MCP::Server.build(registry, engine: OKF::MCP::MemoryBackend.new)
    app = OKF::MCP::HTTP.app_for(server, bind: "127.0.0.1")
    httpd = OKF::MCP::HTTP.build(app, bind: "127.0.0.1", port: 0)
    thread = Thread.new { httpd.start }
    port = httpd.listeners.first.addr[1]
    begin
      yield port
    ensure
      # shutdown wakes WEBrick's select through its shutdown pipe — usually.
      # A bounded join with a kill fallback keeps a wedged accept loop from
      # hanging the whole suite and swallowing the assertion that failed.
      httpd.shutdown
      thread.kill unless thread.join(5)
    end
  end

  def post(port, payload, host: nil)
    http = Net::HTTP.new("127.0.0.1", port)
    http.open_timeout = 10
    http.read_timeout = 10
    request = Net::HTTP::Post.new("/", "Content-Type" => "application/json", "Accept" => "application/json, text/event-stream")
    request["Host"] = host if host
    request.body = JSON.generate(payload)
    http.request(request)
  end
end
