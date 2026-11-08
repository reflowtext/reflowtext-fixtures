# frozen_string_literal: true

# Release tasks for the Halcyon Instruments firmware and patch library.
#
#   rake -T                      list everything
#   rake firmware:build[pulse8]  build one board
#   rake release VERSION=4.2.0   the whole pipeline, in order
#
# Tasks are idempotent: run any of them twice and the second run does nothing
# that the first already did. File tasks carry most of that weight.

require "rake/clean"
require "date"
require "digest"
require "json"
require "time"

BOARDS       = %w[pulse8 tidewater mono-k].freeze
BUILD_DIR    = "build"
DIST_DIR     = "dist"
BUNDLE       = File.join(BUILD_DIR, "factory-patches.json")
MANIFEST     = File.join(DIST_DIR, "manifest.json")
PATCH_SRC    = FileList["patches/**/*.hpatch"]
FIRMWARE_SRC = FileList["firmware/src/**/*.{c,h}", "firmware/boards/*.ld"]

CLEAN.include(BUILD_DIR)
CLOBBER.include(DIST_DIR)

def version
  @version ||= ENV.fetch("VERSION") { File.read("VERSION").strip }.tap do |v|
    abort "VERSION #{v.inspect} is not MAJOR.MINOR.PATCH" unless v.match?(/\A\d+\.\d+\.\d+\z/)
  end
end

def say(message)
  $stdout.puts "\e[1;36m==>\e[0m #{message}"
end

def sha256(path) = Digest::SHA256.file(path).hexdigest

directory BUILD_DIR
directory DIST_DIR

namespace :firmware do
  BOARDS.each do |board|
    image = File.join(BUILD_DIR, "#{board}.bin")

    file image => [BUILD_DIR, *FIRMWARE_SRC, "firmware/boards/#{board}.ld"] do
      say "compiling #{board}"
      sh "make", "-C", "firmware", "BOARD=#{board}", "OUT=../#{image}", "VERSION=#{version}", verbose: false
      size = File.size(image)
      limit = board == "mono-k" ? 256 * 1024 : 512 * 1024
      if size > limit
        rm image
        abort "#{board}: image is #{size} bytes, over the #{limit}-byte flash budget"
      end
      say format("%s: %.1f KiB of %d KiB", board, size / 1024.0, limit / 1024)
    end
  end

  desc "Build firmware for one board, or all boards when none is named"
  task :build, [:board] do |_, args|
    targets = args[:board] ? [args[:board]] : BOARDS
    unknown = targets - BOARDS
    abort "unknown board(s): #{unknown.join(', ')}. Known: #{BOARDS.join(', ')}" if unknown.any?

    targets.each { |b| Rake::Task[File.join(BUILD_DIR, "#{b}.bin")].invoke }
  end

  desc "Run the firmware unit tests on the host"
  task :test do
    sh "make", "-C", "firmware", "test", verbose: false
  end
end

namespace :patches do
  file BUNDLE => [BUILD_DIR, *PATCH_SRC] do
    say "bundling #{PATCH_SRC.size} factory patches"

    patches = PATCH_SRC.sort.map do |path|
      fields = File.readlines(path, chomp: true)
                   .reject { _1.strip.empty? || _1.start_with?("#") }
                   .to_h { _1.split("=", 2).map(&:strip) }

      name = fields.fetch("name") { abort "#{path}: patch has no name" }
      { "name" => name, "bank" => File.basename(File.dirname(path)), "params" => fields.except("name") }
    end

    duplicates = patches.group_by { [_1["bank"], _1["name"]] }.select { |_, v| v.size > 1 }.keys
    abort "duplicate patch names: #{duplicates.map { _1.join('/') }.join(', ')}" if duplicates.any?

    File.write(BUNDLE, JSON.pretty_generate({ "version" => version, "patches" => patches }))
  end

  desc "Validate and bundle factory patches"
  task bundle: BUNDLE

  desc "Show how many patches each bank holds"
  task :stats do
    PATCH_SRC.group_by { File.basename(File.dirname(_1)) }
             .sort_by { |bank, _| bank }
             .each { |bank, files| puts format("%-12s %3d", bank, files.size) }
  end
end

namespace :dist do
  desc "Copy images and patches into dist/ with a checksummed manifest"
  task package: ["firmware:build", "patches:bundle", DIST_DIR] do
    artifacts = BOARDS.map { File.join(BUILD_DIR, "#{_1}.bin") } + [BUNDLE]

    entries = artifacts.map do |src|
      dest = File.join(DIST_DIR, File.basename(src).sub(/(\.\w+)\z/, "-#{version}\\1"))
      cp src, dest, verbose: false unless File.exist?(dest) && sha256(dest) == sha256(src)
      { "file" => File.basename(dest), "bytes" => File.size(dest), "sha256" => sha256(dest) }
    end

    File.write(MANIFEST, JSON.pretty_generate({
      "product"    => "halcyon-firmware",
      "version"    => version,
      "built_at"   => Time.now.utc.iso8601,
      "artifacts"  => entries,
    }))
    say "packaged #{entries.size} artifacts into #{DIST_DIR}/"
  end

  desc "Verify every file in the manifest against its checksum"
  task :verify do
    manifest = JSON.parse(File.read(MANIFEST))
    failures = manifest["artifacts"].reject { sha256(File.join(DIST_DIR, _1["file"])) == _1["sha256"] }
    abort "checksum mismatch: #{failures.map { _1['file'] }.join(', ')}" if failures.any?

    say "all #{manifest['artifacts'].size} artifacts verified"
  end
end

namespace :changelog do
  desc "Draft release notes from commit subjects since the last tag"
  task :draft do
    last_tag = `git describe --tags --abbrev=0 2>/dev/null`.strip
    range    = last_tag.empty? ? "HEAD" : "#{last_tag}..HEAD"
    subjects = `git log --format=%s #{range}`.lines(chomp: true)

    sections = subjects.group_by do |s|
      case s
      when /\Afeat/i then "Added"
      when /\Afix/i  then "Fixed"
      when /\Aperf/i then "Faster"
      else "Other"
      end
    end

    puts "## #{version} — #{Date.today.iso8601}"
    %w[Added Fixed Faster Other].each do |title|
      next unless sections[title]

      puts "\n### #{title}"
      sections[title].each { puts "- #{_1.sub(/\A\w+(\(\S+\))?:\s*/, '')}" }
    end
  end
end

desc "Run every test suite"
task test: ["firmware:test"]

desc "Full release: test, build, package, verify"
task release: %w[test dist:package dist:verify] do
  say "release #{version} is ready in #{DIST_DIR}/"
end

task default: :test
