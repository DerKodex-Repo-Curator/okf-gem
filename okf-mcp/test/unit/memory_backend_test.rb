# frozen_string_literal: true

require "test_helper"

class MemoryBackendTest < OKF::TestCase
  setup do
    @dir = Dir.mktmpdir("okf-mcp-memory")
    File.write(File.join(@dir, "note.md"), "---\ntype: Note\ntitle: One\n---\n\nThe first body.\n")
    @backend = OKF::MCP::MemoryBackend.new
  end

  teardown do
    FileUtils.rm_rf(@dir)
  end

  test "refresh warms the residency and returns nothing — the backend duck type" do
    assert_nil @backend.refresh(@dir)
  end

  test "the folder is resident until the fingerprint moves" do
    first = @backend.folder(@dir)
    assert_same first, @backend.folder(@dir), "unchanged files, same parsed folder"

    write_note("A different body.", mtime: Time.now + 2)
    second = @backend.folder(@dir)
    refute_same first, second
    assert_match(/A different body/, second.bundle.concepts.first.body)
  end

  test "the corpus is held across index queries and dropped when a member changes" do
    pairs = [ [ "scratch", @dir ] ]
    first = @backend.search_pairs(pairs, [ "body" ], engine: "index")
    assert_equal 1, first.length

    # Held: the same corpus answers again (observed via object identity of the
    # held folders — a rebuild would re-read the folder).
    resident = @backend.folder(@dir)
    @backend.search_pairs(pairs, [ "body" ], engine: "index")
    assert_same resident, @backend.folder(@dir)

    write_note("A rewritten body with zeppelins.", mtime: Time.now + 2)
    rows = @backend.search_pairs(pairs, [ "zeppelins" ], engine: "index")
    assert_equal 1, rows.length, "the held index outliving its set would have missed the edit"
  end

  test "the scan answers by default and fuzzy routes to the index" do
    pairs = [ [ "scratch", @dir ] ]
    scan = @backend.search_pairs(pairs, [ "first" ])
    assert_equal 1, scan.length

    # One substitution, inside the 0.2 × length edit budget (a transposition
    # like "frist" costs two edits and would miss).
    fuzzy = @backend.search_pairs(pairs, [ "furst" ], fuzzy: true)
    assert_equal 1, fuzzy.length
  end

  test "catalog filters by type, tag, dir prefix and status" do
    FileUtils.mkdir_p(File.join(@dir, "deep"))
    File.write(File.join(@dir, "deep", "two.md"),
      "---\ntype: Guide\ntitle: Two\ntags: [x]\nstatus: draft\n---\n\nBody.\n")

    assert_equal [ "deep/two" ], @backend.catalog(@dir, type: "Guide").map { |row| row[:id] }
    assert_equal [ "deep/two" ], @backend.catalog(@dir, tag: "x").map { |row| row[:id] }
    assert_equal [ "deep/two" ], @backend.catalog(@dir, dir: "deep").map { |row| row[:id] }
    assert_equal [ "note" ], @backend.catalog(@dir, dir: ".").map { |row| row[:id] }
    assert_equal [ "deep/two" ], @backend.catalog(@dir, status: "draft").map { |row| row[:id] }
  end

  private

  # An edit the fingerprint must see: same file list, newer mtime. The explicit
  # utime matters — two writes inside one clock tick would otherwise fingerprint
  # identically and the test would pass or fail by filesystem timestamp
  # granularity.
  def write_note(body, mtime:)
    path = File.join(@dir, "note.md")
    File.write(path, "---\ntype: Note\ntitle: One\n---\n\n#{body}\n")
    File.utime(mtime, mtime, path)
  end
end
