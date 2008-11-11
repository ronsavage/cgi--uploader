#!/usr/bin/perl
#
# Name:
# use.cgi.uploader.pl.
#
# Note:
# Need use lib here because CGI scripts don't have access to
# the PerlSwitches used in httpd.conf.

use lib '/home/ron/perl.modules/CGI-Up/lib';
use strict;
use warnings;

use CGI::Up::Test;

# ----------------

CGI::Up::Test -> new() -> use_cgi_uploader();
