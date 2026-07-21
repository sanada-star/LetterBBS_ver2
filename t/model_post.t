use strict;
use warnings;
use Test::More;
use lib 'patio/lib';
use LetterBBS::Model::Post;

{
    package Local::PostDBH;

    sub new { bless { reply_sql => '', do_sql => [] }, shift }
    sub selectrow_hashref { return { id => 1, thread_id => 7, seq_no => 0 } }
    sub selectall_arrayref {
        my ($self, $sql) = @_;
        $self->{reply_sql} = $sql;
        return [];
    }
    sub do {
        my ($self, $sql) = @_;
        push @{$self->{do_sql}}, $sql;
        return 1;
    }
}

{
    package Local::PostDB;

    sub new { bless { dbh => Local::PostDBH->new }, shift }
    sub dbh { $_[0]->{dbh} }
}

my $db = Local::PostDB->new;
LetterBBS::Model::Post->new($db)->list_by_thread(7, page => 1, per_page => 10);

like(
    $db->dbh->{reply_sql},
    qr/ORDER BY seq_no DESC/,
    'page 1 selects newest replies first'
);

my $dbh = $db->dbh;
LetterBBS::Model::Post->new($db)->update(9, body => 'edited');
like(
    join("\n", @{$dbh->{do_sql}}),
    qr/UPDATE\s+posts/i,
    'editing a post updates the post'
);
unlike(
    join("\n", @{$dbh->{do_sql}}),
    qr/UPDATE\s+threads/i,
    'editing a post does not bump thread activity'
);

done_testing;
