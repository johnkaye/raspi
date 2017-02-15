package Common;

#
# Common functions
#

use strict;
use warnings;

use Data::Dumper;

use Exporter qw{ import };

our @EXPORT_OK = qw{
    save_token
    retrieve_token
};


sub save_token
{
    my ($args) = @_;

    my @required_args = qw{ application token expires_in};

    foreach my $required ( @required_args )
    {
        if ( not $args->{$required} )
        {
            print qq{Required argument '$required' not supplied.\n};
            return;
        }
    }

    my $token_filename = q{token_} . $args->{'application'} . q{.txt};

    my ( $sec, $min, $hour, $day, $mth, $year ) = ( localtime() )[0, 1, 2, 3, 4, 5];
    my $literal_time = scalar localtime();
    my $epoch_time   = time();

    open my $fh, ">", $token_filename or die "Can't open $token_filename: $!";

    $year += 1900;
    $mth   = sprintf( "%02d", $mth + 1 );
    $day   = sprintf( "%02d", $day );
    $hour  = sprintf( "%02d", $hour );
    $min   = sprintf( "%02d", $min );
    $sec   = sprintf( "%02d", $sec );

    print $fh qq{$args->{'token'}\n};
    print $fh qq{$args->{'expires_in'}\n};
    print $fh qq{$epoch_time\n};
    print $fh $year, $mth, $day, q{-}, $hour, $min, $sec, qq{\n};
    print $fh qq{$literal_time\n};

    close $fh;

    chmod 666, $token_filename;

    return 1;
}

sub retrieve_token
{
    my ($args) = @_;

    my $application = $args->{'application'};

    ## set defaults
    my $token        = 'no_token';
    my $expires_in   = 0;
    my $current_ts   = time();
    my $epoch_ts     = $current_ts;
    my $age          = $current_ts;
    my $numerical_ts = 0;
    my $literal_ts   = 0;

    if ( not $application )
    {
        print qq{Required 'application' not supplied.\n};
        return;
    }

    my $token_filename = q{token_} . $application . q{.txt};

    my $is_open = 1;

    open my $fh, "<", $token_filename or $is_open = 0;

    if ( $is_open )
    {
        $token = <$fh>;
        chomp $token;

        $expires_in = <$fh>;
        chomp $expires_in;

        $epoch_ts = <$fh>;
        chomp $epoch_ts;

        $numerical_ts = <$fh>;
        chomp $numerical_ts;

        $literal_ts = <$fh>;
        chomp $literal_ts;

        close $fh;

        $age = $current_ts - $epoch_ts;
    }

    return {
        'token'      => $token,
        'expires_in' => $expires_in,
        'age'        => $age,
        'epoch'      => $epoch_ts,
        'numerical'  => $numerical_ts,
        'literal'    => $literal_ts,
    };
}

1;

__END__

=head1 NAME

Common - common functions, initially for the sms sending application

=head1 SYNOPSIS

  use Common qw{
    save_token
    retrieve_token
  };
  
  save_token({
    'application' => $application,
    'token'       => $token,
    'expires_in'  => $expires_in,
  });

  my $app_data = retrieve_token({
    'application' => $application,
  });

=head1 DESCRIPTION

A module containing functions to save and retrieve
an OAuth access token for a named application.

All the functions take a reference to a hash of named arguments.

=head1 FUNCTIONS

=head2 save_token

  save_token({
    'application' => $application,
    'token'       => $token,
    'expires_in'  => $expires_in,
  });

Saves a token and a timestamp, for a named application, in a file.
$expires_in is the number of seconds that the token is valid for.
Returns true on success.

=head2 retrieve_token

  my $app_data = retrieve_token({
    'application' => $application,
  });

  if ( $app_data->{'age'} < $app_data->{'expires_in'} - 60 )
  {
    return {
      'token'      => $app_data->{'token'},
      'expires_in' => $app_data->{'expires_in'},
      'age'        => $app_data->{'age'},
    };
  }

Retrieves an access token, together with its age in seconds
and the number of seconds that the token is valid for,
from a storage file for a named application.

=head1 AUTHOR

John Kaye E<lt>jkaye29@gmail.comE<gt>

