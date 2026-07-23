use strict;
use warnings;
use utf8;

use File::Spec;
use File::Temp qw(tempfile);
use IPC::Open3;
use JSON::PP qw(decode_json);
use Symbol qw(gensym);
use Test::More;

my $admin_cgi = File::Spec->catfile('patio', 'admin.cgi');
open my $source_fh, '<:encoding(UTF-8)', $admin_cgi
    or die "Cannot read $admin_cgi: $!";
my $source = do { local $/; <$source_fh> };
close $source_fh;

my ($parser_source) = $source =~ /(#--- 管理画面用CGIパラメータ取得 ---.*)\z/s;
die 'Cannot find the admin CGI parameter parser' unless defined $parser_source;

sub run_parser {
    my (%args) = @_;
    my ($script_fh, $script_path) = tempfile(SUFFIX => '.pl');
    binmode $script_fh, ':encoding(UTF-8)';
    print {$script_fh} <<'PERL';
use strict;
use warnings;
use utf8;
use JSON::PP ();
PERL
    print {$script_fh} $parser_source;
    print {$script_fh} <<'PERL';

package main;
my $cgi = _build_admin_cgi();
my @ids = $cgi->param('ids');
print JSON::PP::encode_json({
    ids    => \@ids,
    scalar => scalar $cgi->param('ids'),
    action => scalar $cgi->param('action'),
});
PERL
    close $script_fh;

    local %ENV = (
        %ENV,
        REQUEST_METHOD => 'POST',
        CONTENT_TYPE   => $args{content_type},
        CONTENT_LENGTH => length($args{body}),
        QUERY_STRING   => ($args{query_string} // ''),
    );

    my $stderr = gensym;
    my $pid = open3(my $stdin, my $stdout, $stderr, $^X, $script_path);
    binmode $stdin;
    print {$stdin} $args{body};
    close $stdin;

    my $json = do { local $/; <$stdout> };
    my $error = do { local $/; <$stderr> };
    waitpid $pid, 0;
    is($? >> 8, 0, "parser child exits successfully: $error");

    return decode_json($json);
}

my $urlencoded = run_parser(
    content_type => 'application/x-www-form-urlencoded',
    body         => 'ids=1&ids=2&action=thread_exec',
);

is_deeply($urlencoded->{ids}, ['1', '2'],
    'returns every duplicate URL-encoded value in list context');
is($urlencoded->{scalar}, '2',
    'preserves the last URL-encoded value in scalar context');
is($urlencoded->{action}, 'thread_exec',
    'preserves an ordinary URL-encoded scalar parameter');

my $boundary = 'letterbbs-test-boundary';
my $multipart_body = join '',
    "--$boundary\r\n",
    "Content-Disposition: form-data; name=\"ids\"\r\n\r\n",
    "3\r\n",
    "--$boundary\r\n",
    "Content-Disposition: form-data; name=\"ids\"\r\n\r\n",
    "4\r\n",
    "--$boundary\r\n",
    "Content-Disposition: form-data; name=\"action\"\r\n\r\n",
    "thread_exec\r\n",
    "--$boundary--\r\n";

my $multipart = run_parser(
    content_type => "multipart/form-data; boundary=$boundary",
    body         => $multipart_body,
);

is_deeply($multipart->{ids}, ['3', '4'],
    'returns every duplicate multipart value in list context');
is($multipart->{scalar}, '4',
    'preserves the last multipart value in scalar context');
is($multipart->{action}, 'thread_exec',
    'preserves an ordinary multipart scalar parameter');

done_testing;
