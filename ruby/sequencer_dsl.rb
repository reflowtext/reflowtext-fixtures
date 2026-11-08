# frozen_string_literal: true

# A tiny step-sequencer DSL for Halcyon Instruments drum machines.
#
# Patterns are written as Ruby, read like a score, and compile to a flat list
# of timed events the firmware can play. Nothing here touches hardware: the
# output is data, so it can be printed, diffed, tested and sent later.
#
#   song = Halcyon::Sequencer.compose "Night Ferry", bpm: 112 do
#     swing 0.12
#
#     pattern :verse, steps: 16 do
#       kick  "x...x...x..x.x.."
#       snare "....x.......x..."
#       hat   "x.x.x.x.x.x.x.x.", velocity: 70
#     end
#
#     arrange :verse, :verse, :fill
#   end
#
#   song.events.first(4).each { |event| puts event }

module Halcyon
  module Sequencer
    class Error < StandardError; end

    VOICES = {
      kick:    { note: 36, default_velocity: 110 },
      snare:   { note: 38, default_velocity: 100 },
      clap:    { note: 39, default_velocity: 95 },
      hat:     { note: 42, default_velocity: 80 },
      open_hat: { note: 46, default_velocity: 85 },
      tom_low: { note: 45, default_velocity: 100 },
      tom_high: { note: 50, default_velocity: 100 },
      rim:     { note: 37, default_velocity: 90 },
    }.freeze

    # One note-on, positioned in ticks from the start of the song.
    Event = Data.define(:tick, :voice, :note, :velocity) do
      def to_s
        format("%6d  %-9s note=%-3d vel=%d", tick, voice, note, velocity)
      end
    end

    # Glyphs in a step string. Anything else is a typo, and we say so.
    STEP_GLYPHS = {
      "x" => 1.0,   # normal hit
      "X" => 1.25,  # accent
      "o" => 0.6,   # ghost note
      "." => nil,   # rest
      "-" => nil,   # rest, for readability in long rows
    }.freeze

    class Track
      attr_reader :voice, :steps, :velocity, :probability

      def initialize(voice, row, steps:, velocity: nil, probability: 1.0)
        spec = VOICES.fetch(voice) { raise Error, "unknown voice #{voice.inspect}; try one of #{VOICES.keys.join(', ')}" }
        cleaned = row.delete(" |")

        unless cleaned.length == steps
          raise Error, "#{voice}: row has #{cleaned.length} steps, pattern expects #{steps}"
        end

        bad = cleaned.chars.uniq - STEP_GLYPHS.keys
        raise Error, "#{voice}: unknown step glyph(s) #{bad.map(&:inspect).join(', ')}" if bad.any?

        @voice       = voice
        @note        = spec[:note]
        @velocity    = velocity || spec[:default_velocity]
        @probability = probability.clamp(0.0, 1.0)
        @steps       = cleaned.chars.map { STEP_GLYPHS[_1] }
      end

      def hits
        return enum_for(:hits) unless block_given?

        steps.each_with_index do |scale, index|
          next if scale.nil?

          yield index, (velocity * scale).round.clamp(1, 127), @note
        end
      end
    end

    class Pattern
      attr_reader :name, :steps, :tracks

      def initialize(name, steps:)
        @name   = name
        @steps  = steps
        @tracks = []
      end

      # Every voice becomes a method inside a pattern block: `kick "x..."`.
      VOICES.each_key do |voice|
        define_method(voice) do |row, **options|
          @tracks << Track.new(voice, row, steps: steps, **options)
        end
      end

      # Euclidean rhythm: spread `hits` as evenly as possible over the bar.
      # euclid :rim, 5 gives "x..x.x..x.x..x.." style figures for free.
      def euclid(voice, hits, rotate: 0, **options)
        raise Error, "#{voice}: cannot place #{hits} hits in #{steps} steps" if hits > steps

        row = Array.new(steps) { |i| ((i * hits) % steps) < hits ? "x" : "." }
        send(voice, row.rotate(-rotate).join, **options)
      end

      def method_missing(name, *args, **kwargs)
        raise Error, "pattern #{@name.inspect}: unknown voice or command `#{name}`" if args.first.is_a?(String)

        super
      end

      def respond_to_missing?(name, include_private = false) = VOICES.key?(name) || super
    end

    class Song
      PPQN = 96 # ticks per quarter note

      attr_reader :title, :bpm, :patterns, :arrangement

      def initialize(title, bpm:)
        raise Error, "bpm must be between 40 and 300" unless (40..300).cover?(bpm)

        @title       = title
        @bpm         = bpm
        @swing       = 0.0
        @patterns    = {}
        @arrangement = []
        @seed        = title.sum
      end

      def swing(amount)
        @swing = amount.to_f.clamp(0.0, 0.5)
      end

      def pattern(name, steps: 16, &body)
        raise Error, "pattern #{name.inspect} is defined twice" if @patterns.key?(name)

        built = Pattern.new(name, steps: steps)
        built.instance_eval(&body)
        @patterns[name] = built.freeze
      end

      def arrange(*names, times: 1)
        missing = names - @patterns.keys
        raise Error, "arrangement uses undefined pattern(s): #{missing.join(', ')}" if missing.any?

        @arrangement.concat(names * times)
      end

      def ticks_per_step(pattern) = (PPQN * 4) / pattern.steps

      # Compile the arrangement to absolute-tick events, applying swing to the
      # off-beat steps and a deterministic per-song roll for probability.
      def events
        rng    = Random.new(@seed)
        cursor = 0

        @arrangement.flat_map do |name|
          pat  = @patterns.fetch(name)
          step = ticks_per_step(pat)

          bar = pat.tracks.flat_map do |track|
            track.hits.filter_map do |index, velocity, note|
              next if rng.rand > track.probability

              offset = index.odd? ? (step * @swing).round : 0
              Event.new(tick: cursor + index * step + offset, voice: track.voice, note:, velocity:)
            end
          end

          cursor += step * pat.steps
          bar
        end.sort_by { [_1.tick, _1.note] }
      end

      def duration_seconds
        total_ticks = @arrangement.sum { |n| ticks_per_step(@patterns[n]) * @patterns[n].steps }
        total_ticks / PPQN.to_f * 60.0 / bpm
      end

      def summary
        lines = ["#{title} — #{bpm} bpm, swing #{(@swing * 100).round}%, #{format('%.1f', duration_seconds)}s"]
        @patterns.each_value do |pat|
          lines << format("  %-8s %2d steps  %s", pat.name, pat.steps, pat.tracks.map(&:voice).join(" "))
        end
        lines << "  order: #{@arrangement.join(' → ')}"
        lines.join("\n")
      end
    end

    def self.compose(title, bpm: 120, &body)
      song = Song.new(title, bpm: bpm)
      song.instance_eval(&body)
      raise Error, "#{title}: nothing arranged" if song.arrangement.empty?

      song
    end
  end
end

if $PROGRAM_NAME == __FILE__
  song = Halcyon::Sequencer.compose "Night Ferry", bpm: 112 do
    swing 0.12

    pattern :verse do
      kick  "x...|x...|x..x|.x.."
      snare "....|x...|....|x..."
      hat   "x.x.|x.x.|x.x.|x.xo", velocity: 70
    end

    pattern :fill do
      kick     "x...|x...|x.x.|xxxx"
      snare    "..o.|x.o.|..xx|XXXX"
      euclid :rim, 5, rotate: 2, velocity: 60
      open_hat "....|....|....|...x", probability: 0.5
    end

    arrange :verse, times: 3
    arrange :fill
  end

  puts song.summary
  puts
  song.events.first(12).each { puts _1 }
end
