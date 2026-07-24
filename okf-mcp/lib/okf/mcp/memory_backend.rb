# frozen_string_literal: true

module OKF
  module MCP
    # The residency cache and the corpus holder — the long-lived holder's branch
    # of the kernel's lifecycle asymmetry. One parsed bundle per registered
    # root, re-read only when the on-disk fingerprint (the markdown file list
    # plus the newest mtime) moves; bodies always come from this layer, live
    # from disk and canonical, whichever engine answers search. There is
    # deliberately no disk cache here — the process is the cache; disk-side
    # state is okf-sqlite3's territory.
    class MemoryBackend
      FILTER_KEYS = %i[type tag dir status].freeze

      def initialize
        @mutex = Mutex.new
        @cache = {}
        @corpus_mutex = Mutex.new
        @corpora = {}
      end

      def capabilities
        { name: "memory", ranked: false }
      end

      def refresh(root)
        folder(root)
        nil
      end

      # Engine doctrine, the CLI's exactly: the scan answers by default — no
      # tokenizer recall holes, milliseconds over a resident bundle — and the
      # index (BM25+, page parity) is opt-in by name or implied by fuzzy. The
      # kernel routes and refuses incompatible asks (regexp needs the scan,
      # fuzzy needs the index); those refusals surface as tool errors.
      #
      # Index queries go through a held corpus: one shared index over the whole
      # served set, so federated BM25 scores are comparable by construction
      # (Search.across's own argument). The corpus is built on the first index
      # query, not at boot, and dropped when any member bundle's fingerprint
      # moves — a held index outliving its set is a wrong answer, not a slow one.
      def search_pairs(pairs, terms, fields: nil, regexp: false, fuzzy: false, engine: nil)
        bundles = pairs.map { |slug, root| [ slug, folder(root).bundle ] }
        options = { fields: fields, regexp: regexp, fuzzy: fuzzy, engine: engine }
        if index_query?(engine, fuzzy: fuzzy)
          Bundle::Search.with(corpus_for(pairs), terms, **options)
        else
          Bundle::Search.across(bundles, terms, **options)
        end
      end

      def catalog(root, filters = {})
        folder(root).catalog.select { |row| matches?(row, filters) }
      end

      # The disk handle behind read_concept, index and dirs — those stay on the
      # parsed bundle whichever engine answers search: bodies are read live from
      # disk (canonical), and the directory index needs the authored index.md
      # bodies no derived store carries.
      def folder(root)
        @mutex.synchronize do
          entry = @cache[root]
          print = fingerprint(root)
          unless entry && entry[:fingerprint] == print
            folder = Bundle::Folder.load(root)
            # The threaded HTTP transport can hit these lazy memos from two
            # threads at once; build them once here, under this lock.
            folder.bundle.concept_by_id(nil)
            folder.bundle.paths_by_id
            entry = { folder: folder, fingerprint: print }
            @cache[root] = entry
          end
          entry[:folder]
        end
      end

      private

      # Does this query need the prepared index? A named "index" engine, or
      # fuzzy with no engine named (the kernel would route it to the index
      # anyway). "scan" plus fuzzy deliberately skips the corpus so the kernel
      # can refuse it with its own sentence.
      def index_query?(engine, fuzzy:)
        engine.to_s == "index" || (fuzzy && OKF.blank?(engine))
      end

      # One corpus per served set, keyed by its roots and pinned to the exact
      # folder objects it was built from. #folder returns a new object only
      # when a fingerprint moved, so identity comparison is the staleness check.
      def corpus_for(pairs)
        folders = pairs.map { |slug, root| [ slug, folder(root) ] }
        key = pairs.map { |_, root| root }.sort
        @corpus_mutex.synchronize do
          held = @corpora[key]
          unless held && held[:folders] == folders
            corpus = Bundle::Search.prepare(folders.map { |slug, f| [ slug, f.bundle ] }, engine: "index")
            held = { corpus: corpus, folders: folders }
            @corpora[key] = held
          end
          held[:corpus]
        end
      end

      def matches?(row, filters)
        FILTER_KEYS.all? do |key|
          wanted = filters[key]
          next true if OKF.blank?(wanted)

          case key
          when :tag then Array(row[:tags]).map { |tag| fold(tag) }.include?(fold(wanted))
          when :dir then under_dir?(row[:dir], wanted)
          else fold(row[key]) == fold(wanted)
          end
        end
      end

      # The CLI's one rule for --dir, kept verbatim: a dir names itself and
      # everything beneath it, and "." selects only the root.
      def under_dir?(entry_dir, wanted)
        entry = fold(entry_dir)
        path = fold(wanted).sub(/\/+\z/, "")
        path = "." if path == "root"
        entry == path || entry.start_with?("#{path}/")
      end

      def fold(value)
        value.to_s.downcase
      end

      def fingerprint(root)
        paths = Dir.glob(::File.join(root, "**", "*.md")).sort
        newest = paths.map { |path| ::File.mtime(path).to_f }.max
        [ paths, newest ]
      end
    end
  end
end
