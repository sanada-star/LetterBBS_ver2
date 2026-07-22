use strict;
use warnings;
use Test::More;
use lib 'patio/lib';
use LetterBBS::Model::Thread;

{
    package Local::ThreadDBH;
    sub new { bless { calls => [] }, shift }
    sub do {
        my ($self, $sql, $attrs, @bind) = @_;
        push @{$self->{calls}}, { sql => $sql, bind => \@bind };
        return 1;
    }
}

{
    package Local::ThreadDB;
    sub new { bless { dbh => Local::ThreadDBH->new }, shift }
    sub dbh { $_[0]->{dbh} }
}

subtest 'ordinary thread metadata update touches activity time' => sub {
    my $db = Local::ThreadDB->new;
    LetterBBS::Model::Thread->new($db)->update(7, is_locked => 1);
    like($db->dbh->{calls}[0]{sql}, qr/updated_at\s*=\s*\?/, 'activity timestamp is updated by default');
};

subtest 'post-edit metadata update can preserve activity time' => sub {
    my $db = Local::ThreadDB->new;
    LetterBBS::Model::Thread->new($db)->update(
        7,
        has_image     => 0,
        touch_activity => 0,
    );
    like($db->dbh->{calls}[0]{sql}, qr/has_image\s*=\s*\?/, 'image metadata is updated');
    unlike($db->dbh->{calls}[0]{sql}, qr/updated_at\s*=\s*\?/, 'activity timestamp is preserved');
    is_deeply($db->dbh->{calls}[0]{bind}, [0, 7], 'internal option is not stored as a column');
};

done_testing;
