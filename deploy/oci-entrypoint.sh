#!/bin/sh
set -eu
cd /app
./bin/firstmate_port eval 'FirstmatePort.Release.migrate()'
exec ./bin/firstmate_port start
