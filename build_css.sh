#!/bin/sh
set -eu

./vendor/tailwindcss -i static/app.css -o static/app.gen.css --minify