#!/bin/sh
#
# Installs the dependencies, and then runs the tests. This is used by both
# the sytest builds and the synapse ones.
#

set -ex

export PERL5LIB=$WORKSPACE/perl5/lib/perl5
export PERL_MB_OPT=--install_base=$WORKSPACE/perl5
export PERL_MM_OPT=INSTALL_BASE=$WORKSPACE/perl5

cd "`dirname $0`/.."

./install-deps.pl

./run-tests.pl -O tap --all "$@" > results.tap
