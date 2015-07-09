package Grab;

# Grab.pm
#
# Web page grabbing functions
#

use strict;
use warnings;

use Exporter;
use vars qw{ 
	@ISA 
	@EXPORT_OK 
};

@ISA = qw(
	Exporter
);

@EXPORT_OK = qw{
    get_content
};

use HTTP::Cookies;
use LWP::UserAgent;
use URI;

sub get_content
{
	my %ARGS = (@_);

    # check input parameters
    if ( !defined $ARGS{'url'} || !$ARGS{'url'} )
    {
        return _error(
            'msg' => q{Expected argument 'url' not supplied},
        );
    }

    my $url = $ARGS{'url'};

    # $post_data is a ref to an array of pairs (like a hash)
    my $post_data  = $ARGS{'post_data'};

    my $query_list = $ARGS{'query_list'};
    my $method     = $ARGS{'method'} || 'GET';
    my $timeout    = $ARGS{'timeout'} || 20;

    my $server   = $ARGS{'location'};
    my $realm    = $ARGS{'realm'};
    my $username = $ARGS{'username'};
    my $password = $ARGS{'password'};

#	my $user_agent = q{Mozilla/5.0 (Windows NT 6.3; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/37.0.2049.0 Safari/537.36};

	my $user_agent = q{Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:27.0) Gecko/20100101 Firefox/27.0};

    my $response;

    # create user-agent

    my $agent = LWP::UserAgent->new(
		'agent'      => $user_agent,
        'cookie_jar' => HTTP::Cookies->new(
			'file'     => 'my_cookies.txt',
			'autosave' => 1,
		),
	);

    $agent->timeout( $timeout );

    # allow redirection of POST
    push @{ $agent->requests_redirectable() }, 'POST';

    # enable cookies
    $agent->cookie_jar( {} );

    # send username, password if supplied
    if ( $username )
    {
        $agent->credentials(
			$server . q{:80},
			$realm,
			$username => $password,
		);
    }

    if ( uc($method) eq 'GET' )
    {
        $response = $agent->get( $url );
    }
    elsif ( uc($method) eq 'POST' )
    {
        $response = $agent->post(
            $url,
            $post_data,
        );
    }
    else
    {
        return _error(
            'msg' => q{Expected 'method' GET or POST not supplied},
        );
    }

    if ( $response->is_success() )
    {
        return _success(
            'data'  => $response->content(),
        );
    }
    elsif ( $response->is_redirect() )
    {
	print "\nRedirected:\n";
        return _success(
            'data'  => $response->headers_as_string(),
        );
    }
    else     
    {
        my $msg = $response->header('WWW-Authenticate') || 'Error accessing';
        $msg .= "\n" . $response->status_line() . "\n";

        return _error(
            'msg' => $msg,
        );
    }

}


sub _success
{
	my (%args) = @_;

	return {
		'error' => 0,
		'data'  => $args{'data'},
	};
}

sub _error
{
	my (%args) = @_;

	my $msg = $args{'msg'} || 'No error message supplied';
	return {
		'error' => 1,
		'info'  => $msg,
	};
}

#################################################################

1;

__END__

=head1 NAME

Grab - Web page grabber

=head1 SYNOPSIS

    use Grab qw{
        get_content
    };
  
=head1 DESCRIPTION

A module containing functions to grab a web page
and return content data from the grabbed page.

All the functions take named arguments.

=head1 FUNCTIONS

=head2 get_content

    my $contents = get_content(
        'url'      => $url,
        'method'   => 'POST',
        'username' => $username,
        'password' => $password,
    );

    my $contents = get_content(
        'url'      => $url,
    );

Returns a string containing the content section
of the requested web page. C<method>, C<username> and C<password>
are optional parameters. C<method> defaults to C<GET>.

=head1 AUTHOR

John Kaye <jkaye29@gmail.com>
