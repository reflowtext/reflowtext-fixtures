#!/bin/sh
#
# logslice: print the lines of one or more logs that fall inside a time window.
#
#   logslice -f 09:58 -t 10:04 /var/log/halcyon/sync.log
#   logslice -f 2026-11-06T22:00 -t 2026-11-07T02:00 -c 3 *.log.gz
#   journal-export | logslice -f 14:00 -l ERROR
#
# Portable POSIX sh plus awk; runs the same under dash, ash, busybox and bash.
# Lines without a timestamp (stack traces, wrapped messages) belong to the
# timestamped line above them, so a slice never cuts a trace in half.
#
# Understood timestamp shapes, anywhere in the first 40 characters:
#   2026-11-06T10:02:17Z   2026-11-06 10:02:17.123   [06/Nov/2026:10:02:17
#   10:02:17 (time only: the date part of -f/-t is then ignored)

set -eu

prog=${0##*/}
from=""
to=""
level=""
context=0
show_name=auto

usage() {
	cat <<EOF
usage: $prog -f FROM [-t TO] [-l LEVEL] [-c N] [-H|-h] [FILE...]

  -f FROM   start of the window (inclusive), e.g. 10:00 or 2026-11-06T10:00
  -t TO     end of the window (exclusive); default: end of input
  -l LEVEL  keep only entries whose first line contains LEVEL (e.g. WARN)
  -c N      also print N entries before the window opens
  -H        always prefix lines with the file name
  -h        never prefix lines with the file name

Files ending in .gz or .zst are decompressed on the fly. With no FILE,
standard input is read.
EOF
}

die() {
	printf '%s: %s\n' "$prog" "$*" >&2
	exit 2
}

# Turn "10:02", "10:02:17", "2026-11-06T10:02" or "2026-11-06 10:02:17"
# into a fixed-width sortable key: YYYYMMDDHHMMSS, or HHMMSS when no date.
normalise() {
	printf '%s\n' "$1" | awk '
	{
		s = $0
		gsub(/[-T: ]/, "", s)
		if (s !~ /^[0-9]+$/) exit 1
		n = length(s)
		if (n == 4 || n == 6)   { while (length(s) < 6)  s = s "0"; print s; exit 0 }
		if (n == 12 || n == 14) { while (length(s) < 14) s = s "0"; print s; exit 0 }
		exit 1
	}' || die "cannot read time: $1"
}

while getopts 'f:t:l:c:Hh' opt; do
	case $opt in
	f) from=$(normalise "$OPTARG") ;;
	t) to=$(normalise "$OPTARG") ;;
	l) level=$OPTARG ;;
	c)
		case $OPTARG in
		'' | *[!0-9]*) die "-c needs a number" ;;
		esac
		context=$OPTARG
		;;
	H) show_name=yes ;;
	h) show_name=no ;;
	*)
		usage >&2
		exit 2
		;;
	esac
done
shift $((OPTIND - 1))

[ -n "$from" ] || {
	usage >&2
	exit 2
}

if [ -n "$to" ] && [ "${#from}" -ne "${#to}" ]; then
	die "-f and -t must both have a date, or both be times of day"
fi

if [ "$show_name" = auto ]; then
	if [ $# -gt 1 ]; then show_name=yes; else show_name=no; fi
fi

# Read a file, decompressing when its name says so.
cat_any() {
	case $1 in
	*.gz) gzip -dc -- "$1" ;;
	*.zst) zstd -dcq -- "$1" ;;
	-) cat ;;
	*) cat -- "$1" ;;
	esac
}

slice() {
	awk -v from="$from" -v to="$to" -v level="$level" -v ctx="$context" \
		-v name="$1" -v show="$show_name" '
	BEGIN {
		split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " ")
		for (i = 1; i <= 12; i++) month[m[i]] = sprintf("%02d", i)
		keylen = length(from)
		state = "before"
		kept = 0
	}

	# Extract a sortable key from the start of a line, or "" when none.
	function stamp(line,    head, k, mon) {
		head = substr(line, 1, 40)
		if (match(head, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][T ][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) {
			k = substr(head, RSTART, RLENGTH)
			gsub(/[-T: ]/, "", k)
		} else if (match(head, /[0-9][0-9]\/[A-Z][a-z][a-z]\/[0-9][0-9][0-9][0-9]:[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) {
			k = substr(head, RSTART, RLENGTH)
			mon = month[substr(k, 4, 3)]
			k = substr(k, 8, 4) mon substr(k, 1, 2) substr(k, 13, 2) substr(k, 16, 2) substr(k, 19, 2)
		} else if (match(head, /(^|[^0-9])[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) {
			k = substr(head, RSTART, RLENGTH)
			sub(/^[^0-9]/, "", k)
			gsub(/:/, "", k)
		} else {
			return ""
		}
		# Compare like with like: a time-only window ignores the date.
		return keylen == 6 ? substr(k, length(k) - 5) : k
	}

	function emit(text) {
		if (show == "yes") printf "%s:%s\n", name, text
		else print text
	}

	# An entry is one timestamped line plus its untimestamped followers.
	function flush(    i) {
		if (entry == "") return
		if (state == "inside") {
			if (level == "" || index(first, level) > 0) {
				for (i = 1; i <= nbuf; i++) emit(held[i])
				nbuf = 0
				for (i = 1; i <= nent; i++) emit(lines[i])
				kept++
			}
		} else if (state == "before" && ctx > 0) {
			# Remember the last ctx entries, flattened, in a ring.
			ring[++rn % ctx] = entry
		}
		entry = ""; nent = 0
	}

	{
		sub(/\r$/, "")
		k = stamp($0)
		if (k != "") {
			flush()
			if (state == "before" && k >= from) {
				state = "inside"
				if (ctx > 0) {
					nbuf = 0
					for (i = rn - ctx + 1; i <= rn; i++)
						if (i > 0) {
							c = split(ring[i % ctx], parts, "\n")
							for (j = 1; j <= c; j++) held[++nbuf] = parts[j]
						}
				}
			}
			if (state == "inside" && to != "" && k >= to) {
				state = "after"
				exit
			}
			first = $0
		}
		entry = entry (entry == "" ? "" : "\n") $0
		lines[++nent] = $0
	}

	END {
		flush()
		if (kept == 0) exit 1
	}'
}

status=1
if [ $# -eq 0 ]; then
	set -- -
fi

for file in "$@"; do
	if [ "$file" != - ] && [ ! -r "$file" ]; then
		printf '%s: cannot read %s\n' "$prog" "$file" >&2
		status=2
		continue
	fi
	label=$file
	[ "$file" = - ] && label="(stdin)"
	if cat_any "$file" | slice "$label"; then
		[ "$status" -eq 2 ] || status=0
	fi
done

exit "$status"
