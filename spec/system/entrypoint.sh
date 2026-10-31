#!/bin/sh
set -eu

# PostgreSQL runs for the psql specs; pg_ctlcluster comes from postgresql-common.
version=$(ls /etc/postgresql)
pg_ctlcluster "$version" main start

exec /usr/sbin/sshd -D -e
