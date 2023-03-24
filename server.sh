#!/bin/bash

set -e

ADDR=127.0.0.1
PORT=1234
ROOT="$(realpath "${1:-$PWD}")"

LF=$'\n'

tmpdir="$(mktemp -d)"
trap 'rm -r "$tmpdir"' EXIT
trap 'exit' INT

stdhead() {
	code="$1"
	head="$2"
	echo "HTTP/1.0 $code $head"
	echo "Content-Type: text/plain"
	echo "Connection: close"
}

error() {
	code="$1"
	head="$2"
	message="$3"
	echo "HTTP/1.0 $code $head"
	echo "Content-Type: text/plain"
	echo "Connection: close"
	echo
	echo "$code $head"
	echo
	echo "$message"
	exit
}

handle() {
	connection_id="$1"
	response_pipe="$tmpdir/response-$connection_id.pipe"
	event_pipe="$tmpdir/event-$connection_id.pipe"
	mkfifo -m 0600 "$response_pipe" "$event_pipe"
	gnetcat -c -l "$ADDR" -p "$PORT" < "$response_pipe" | sed -E -u 's/\r$//' | (
		read method url version || {
			echo "Connection broken" > "$event_pipe"
			exit
		}
		cat >& /dev/null & # read but ignore headers and whatever else
		echo "$method $url" > "$event_pipe"
		if ! [ "$version" = "HTTP/1.0" -o "$version" = "HTTP/1.1" ]; then
			error 505 'HTTP Version Not Supported' "Version $version is not supported.${LF}Only 1.0 is really supported."
		fi
		if ! [ "$method" = "GET" ]; then
			error 501 'Not Implemented' "Method $method is not implemented.${LF}Only GET is supported."
		fi
		if ! echo "$url" | grep -q '^/'; then
			error 400 'Bad Request' "URL must be host-relative"
		fi
		if echo "$url" | grep -q '/\.'; then
			error 403 'Forbidden' "Dot-files are forbidden"
		fi
		target="$ROOT$url"
		name=$(basename "$url")
		if [ -f "$target" ]; then
			echo "HTTP/1.0 200 OK"
			echo "Connection: close"
			echo
			cat "$target"
			exit
		fi
		if [ -d "$target" ]; then
			if ! echo "$url" | grep -q '/$'; then
				echo "HTTP/1.0 307 Temporary Redirect"
				echo "Connection: close"
				echo "Location: $url/"
				exit
			fi
			ls "$target" 2>/dev/null | {
				echo "HTTP/1.0 200 OK"
				echo "Content-Type: text/html; charset=utf-8"
				echo "Connection: close"
				echo
				echo "<!DOCTYPE html>"
				echo "<title>Directory listing for $url</title>"
				echo "<h1>$name</h1>"
				echo "<p><a href=\"..\">up</a>"
				echo "<ul>"
				while read entry; do
					if [ -d "$target$entry" ]; then
						entry="$entry/";
					elif [ -f "$target$entry" ]; then
						true
					else
						continue
					fi
					echo "<li><a href=\"$entry\">$entry</a>"
				done
				echo "</ul>"
			} || error 403 'Forbidden' "Permission denied for $url"
			exit
		fi
		error 404 'Not Found' "Requested file $url is not found"
	) > "$response_pipe" &
	rm "$response_pipe"
	cat "$event_pipe"
	rm "$event_pipe"
}

echo "Serving $ROOT"

for((i=0;;i++)); do
	handle $i
done
