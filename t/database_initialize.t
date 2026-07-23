use strict;
use warnings;
use Test::More;

BEGIN {
    package DBI;
    our $errstr = '';
    sub import {}
    $INC{'DBI.pm'} = __FILE__;
}

use lib 'patio/lib';
use LetterBBS::Database;

{
    package Local::Statement;

    sub execute {
        my ($self, @bind) = @_;
        push @{$self->{owner}{events}}, ['execute', $self->{sql}, @bind];
        return 1;
    }
}

{
    package Local::DatabaseDBH;

    sub new {
        my ($class, %args) = @_;
        return bless {
            events             => [],
            schema_exists      => $args{schema_exists} || 0,
            schema_version     => $args{schema_version} || 0,
            fail_version_two   => $args{fail_version_two} || 0,
            fail_version_three => $args{fail_version_three} || 0,
            fts_supported      => exists $args{fts_supported} ? $args{fts_supported} : 1,
            fts_table_exists   => $args{fts_table_exists} || 0,
        }, $class;
    }

    sub selectrow_array {
        my ($self, $sql) = @_;
        push @{$self->{events}}, ['selectrow_array', $sql];
        return $self->{schema_exists} if $sql =~ /sqlite_master/;
        return $self->{schema_version} if $sql =~ /MAX\(version\)/;
        if ($sql =~ /FROM posts_fts/) {
            die "no such table: posts_fts\n" unless $self->{fts_table_exists};
            return 0;
        }
        return 0;
    }

    sub do {
        my ($self, $sql, $attrs, @bind) = @_;
        push @{$self->{events}}, ['do', $sql, @bind];
        if ($sql =~ /CREATE VIRTUAL TABLE IF NOT EXISTS posts_fts/) {
            die "no such module: fts5\n" unless $self->{fts_supported};
            $self->{fts_table_exists} = 1;
        }
        if ($self->{fail_version_two}
                && $sql =~ /INSERT INTO schema_version/
                && @bind && $bind[0] == 2) {
            die "schema version 2 insert failed\n";
        }
        if ($self->{fail_version_three}
                && $sql =~ /INSERT INTO schema_version/
                && @bind && $bind[0] == 3) {
            die "schema version 3 insert failed\n";
        }
        return 1;
    }

    sub prepare {
        my ($self, $sql) = @_;
        push @{$self->{events}}, ['prepare', $sql];
        return bless { owner => $self, sql => $sql }, 'Local::Statement';
    }

    sub begin_work {
        my ($self) = @_;
        push @{$self->{events}}, ['begin_work'];
        return 1;
    }

    sub commit {
        my ($self) = @_;
        push @{$self->{events}}, ['commit'];
        return 1;
    }

    sub rollback {
        my ($self) = @_;
        push @{$self->{events}}, ['rollback'];
        return 1;
    }
}

sub database_for {
    my (%args) = @_;
    my $dbh = Local::DatabaseDBH->new(%args);
    return (bless({ dbh => $dbh }, 'LetterBBS::Database'), $dbh);
}

sub schema_versions {
    my ($dbh) = @_;
    return map { $_->[2] }
        grep { $_->[0] eq 'do' && $_->[1] =~ /INSERT INTO schema_version/ }
        @{$dbh->{events}};
}

sub delete_trigger_sql {
    my ($dbh) = @_;
    my @sql = map { $_->[1] }
        grep { $_->[0] eq 'do' && $_->[1] =~ /CREATE TRIGGER IF NOT EXISTS trg_post_count_delete/ }
        @{$dbh->{events}};
    return $sql[-1];
}

sub event_index {
    my ($dbh, $predicate) = @_;
    for my $index (0 .. $#{$dbh->{events}}) {
        return $index if $predicate->($dbh->{events}[$index]);
    }
    return -1;
}

my $new_trigger_sql;

subtest 'new database finishes at schema version 3' => sub {
    my ($database, $dbh) = database_for(schema_exists => 0);
    $database->initialize();

    is_deeply([schema_versions($dbh)], [1, 2, 3], 'schema versions 1, 2 and 3 are recorded in order');
    my $version_two = event_index($dbh, sub {
        $_[0][0] eq 'do' && $_[0][1] =~ /INSERT INTO schema_version/
            && defined $_[0][2] && $_[0][2] == 2;
    });
    my $commit = event_index($dbh, sub { $_[0][0] eq 'commit' });
    ok($version_two >= 0 && $commit > $version_two, 'version 2 is recorded before commit');
    $new_trigger_sql = delete_trigger_sql($dbh);
    like($new_trigger_sql || '', qr/SELECT COUNT\(\*\) FROM posts/, 'new database uses recalculating trigger');
};

subtest 'version 1 database migrates through versions 2 and 3' => sub {
    my ($database, $dbh) = database_for(schema_exists => 1, schema_version => 1);
    $database->initialize();

    is_deeply([schema_versions($dbh)], [2, 3], 'schema versions 2 and 3 are recorded in order');
    my $begin = event_index($dbh, sub { $_[0][0] eq 'begin_work' });
    my $drop = event_index($dbh, sub {
        $_[0][0] eq 'do' && $_[0][1] =~ /DROP TRIGGER IF EXISTS trg_post_count_delete/;
    });
    my $create = event_index($dbh, sub {
        $_[0][0] eq 'do' && $_[0][1] =~ /CREATE TRIGGER IF NOT EXISTS trg_post_count_delete/;
    });
    my $backfill = event_index($dbh, sub {
        $_[0][0] eq 'do' && $_[0][1] =~ /UPDATE threads SET/ && $_[0][1] =~ /WHERE status = 'active'/;
    });
    my $version_two = event_index($dbh, sub {
        $_[0][0] eq 'do' && $_[0][1] =~ /INSERT INTO schema_version/
            && defined $_[0][2] && $_[0][2] == 2;
    });
    my $commit = event_index($dbh, sub { $_[0][0] eq 'commit' });

    ok($begin >= 0 && $begin < $drop && $drop < $create && $create < $backfill
        && $backfill < $version_two && $version_two < $commit,
        'drop, create, backfill and version recording are committed atomically');
    is(delete_trigger_sql($dbh), $new_trigger_sql, 'new and migrated databases use identical delete trigger SQL');
};

subtest 'version 2 database rebuilds FTS atomically at version 3' => sub {
    my ($database, $dbh) = database_for(schema_exists => 1, schema_version => 2);
    $database->initialize();

    is_deeply([schema_versions($dbh)], [3], 'only schema version 3 is recorded');
    my $drop = event_index($dbh, sub {
        $_[0][0] eq 'do' && $_[0][1] =~ /DROP TRIGGER IF EXISTS trg_fts_insert/;
    });
    my $rebuild = event_index($dbh, sub {
        $_[0][0] eq 'do' && $_[0][1] =~ /posts_fts\(posts_fts\).*rebuild/;
    });
    my $version_three = event_index($dbh, sub {
        $_[0][0] eq 'do' && $_[0][1] =~ /INSERT INTO schema_version/
            && defined $_[0][2] && $_[0][2] == 3;
    });
    my $commit = event_index($dbh, sub { $_[0][0] eq 'commit' });
    ok($drop >= 0 && $drop < $rebuild && $rebuild < $version_three && $version_three < $commit,
        'FTS triggers, rebuild and version recording are committed atomically');
    ok($database->fts_available, 'FTS is available after migrating an existing database');
};

subtest 'version 3 database detects FTS without running DDL on every request' => sub {
    my ($database, $dbh) = database_for(
        schema_exists => 1,
        schema_version => 3,
        fts_table_exists => 1,
    );
    $database->initialize();

    ok($database->fts_available, 'existing FTS table is detected for this process');
    is_deeply([schema_versions($dbh)], [], 'no migration version is recorded');
    my $create_fts = event_index($dbh, sub {
        $_[0][0] eq 'do' && $_[0][1] =~ /CREATE VIRTUAL TABLE/;
    });
    is($create_fts, -1, 'normal startup does not run FTS DDL');
};

subtest 'FTS is rebuilt when it becomes available after a fallback migration' => sub {
    my ($fallback_database, $fallback_dbh) = database_for(
        schema_exists => 1,
        schema_version => 2,
        fts_supported => 0,
    );
    $fallback_database->initialize();
    is_deeply([schema_versions($fallback_dbh)], [3], 'fallback database still records schema version 3');
    ok(!$fallback_database->fts_available, 'LIKE fallback remains active without FTS5');

    my ($restored_database, $restored_dbh) = database_for(
        schema_exists => 1,
        schema_version => 3,
        fts_supported => 1,
        fts_table_exists => 0,
    );
    $restored_database->initialize();
    ok($restored_database->fts_available, 'FTS is activated after support becomes available');
    my $rebuild = event_index($restored_dbh, sub {
        $_[0][0] eq 'do' && $_[0][1] =~ /posts_fts\(posts_fts\).*rebuild/;
    });
    ok($rebuild >= 0, 'all historical posts are rebuilt into the new FTS index');
};

subtest 'failed version recording rolls back migration' => sub {
    my ($database, $dbh) = database_for(
        schema_exists => 1,
        schema_version => 1,
        fail_version_two => 1,
    );

    my $ok = eval { $database->initialize(); 1 };
    ok(!$ok, 'migration failure is rethrown');
    like($@, qr/schema version 2 insert failed/, 'original migration error is retained');
    ok(event_index($dbh, sub { $_[0][0] eq 'rollback' }) >= 0, 'failed migration rolls back');
    is(event_index($dbh, sub { $_[0][0] eq 'commit' }), -1, 'failed migration does not commit');
};

subtest 'failed version 3 recording rolls back the FTS migration' => sub {
    my ($database, $dbh) = database_for(
        schema_exists => 1,
        schema_version => 2,
        fail_version_three => 1,
    );

    my $ok = eval { $database->initialize(); 1 };
    ok(!$ok, 'FTS migration failure is rethrown');
    like($@, qr/schema version 3 insert failed/, 'original FTS migration error is retained');
    ok(event_index($dbh, sub { $_[0][0] eq 'rollback' }) >= 0, 'failed FTS migration rolls back');
    is(event_index($dbh, sub { $_[0][0] eq 'commit' }), -1, 'failed FTS migration does not commit');
};

done_testing;
