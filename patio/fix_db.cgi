#!/usr/local/bin/perl
use strict;
use DBI;
print "Content-Type: text/plain\n\n";

my $db_file = './data/letterbbs.db';
my $dbh = DBI->connect("dbi:SQLite:dbname=$db_file", "", "", { RaiseError => 1, PrintError => 1 });

my $rows = $dbh->do("UPDATE threads SET last_author = author WHERE last_author = '' OR last_author IS NULL");
print "Success: $rows threads updated.\n";
$dbh->disconnect();