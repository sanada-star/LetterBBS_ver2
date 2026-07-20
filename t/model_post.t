use strict;
use warnings;
use Test::More;
use lib 'patio/lib';
use LetterBBS::Model::Post;

{
    package Local::PostDBH;

    sub new { bless { reply_sql => '' }, shift }
    sub selectrow_hashref { return { id => 1, thread_id => 7, seq_no => 0 } }
    sub selectall_arrayref {
        my ($self, $sql) = @_;
        $self->{reply_sql} = $sql;
        return [];
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

done_testing;
