package LetterBBS::Model::Setting;

#============================================================================
# LetterBBS ver2 - 設定値モデル
#============================================================================

use strict;
use warnings;
use utf8;

sub new {
    my ($class, $db) = @_;
    return bless { db => $db }, $class;
}

sub dbh { return $_[0]->{db}->dbh }

sub get {
    my ($self, $key) = @_;
    my ($value) = $self->dbh->selectrow_array(
        "SELECT value FROM settings WHERE key = ?", undef, $key
    );
    return $value;
}

sub set {
    my ($self, $key, $value) = @_;
    $self->dbh->do(
        "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, datetime('now','localtime'))",
        undef, $key, $value
    );
}

sub get_all {
    my ($self) = @_;
    my $rows = $self->dbh->selectall_arrayref(
        "SELECT key, value FROM settings", { Slice => {} }
    );
    my %settings;
    for my $row (@$rows) {
        $settings{$row->{key}} = $row->{value};
    }
    return \%settings;
}

sub set_bulk {
    my ($self, %data) = @_;
    my $sth = $self->dbh->prepare(
        "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, datetime('now','localtime'))"
    );
    for my $key (keys %data) {
        $sth->execute($key, $data{$key});
    }
}

1;
