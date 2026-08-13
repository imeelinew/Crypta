#!/bin/zsh
set -euo pipefail

if [[ $# -ne 2 ]]; then
    print -u2 "Usage: $0 <marketing-version> <build-number>"
    exit 64
fi

version="$1"
build="$2"
project_file="${0:A:h:h}/Crypta.xcodeproj/project.pbxproj"
bundle_id="com.eli.Crypta"

if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' ]]; then
    print -u2 "Invalid marketing version: $version"
    exit 64
fi
if [[ ! "$build" =~ '^[1-9][0-9]*$' ]]; then
    print -u2 "Build number must be a positive integer: $build"
    exit 64
fi

ruby - "$project_file" "$version" "$build" "$bundle_id" <<'RUBY'
path, version, build, bundle_id = ARGV
contents = File.binread(path)
build_re = /(CURRENT_PROJECT_VERSION = )([^;]+)(;[\s\S]*?PRODUCT_BUNDLE_IDENTIFIER = #{Regexp.escape(bundle_id)};)/
marketing_re = /(MARKETING_VERSION = )([^;]+)(;\n\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = #{Regexp.escape(bundle_id)};)/
build_hits = contents.scan(build_re).length
marketing_hits = contents.scan(marketing_re).length
abort "Unexpected CURRENT_PROJECT_VERSION app entries: #{build_hits}" unless build_hits == 2
abort "Unexpected MARKETING_VERSION app entries: #{marketing_hits}" unless marketing_hits == 2
contents.gsub!(build_re) { "#{$1}#{build}#{$3}" }
contents.gsub!(marketing_re) { "#{$1}#{version}#{$3}" }
File.binwrite(path, contents)
RUBY

print "Crypta version set to ${version} (${build})"
