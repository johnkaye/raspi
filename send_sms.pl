#!/usr/bin/perl

use strict;
use warnings;

use LWP::Simple;
use HTTP::Cookies;
use JSON;

use lib '/kbin';

use Common qw{
    save_token
    retrieve_token
};

use Data::Dumper;

### 'myAlert' SMS app

### Go to https://dev.telstra.com to see MyApps
### Login with the following values from send_sms.conf
###     username
###     password

### Usage send_sms.pl [ mobile_number [ "message" ] ]

my $config = _read_config();

#print Dumper( $config );

my $base_dir = '/kbin';

my $Token_Request_Url = q{https://api.telstra.com/v1/oauth/token};
my $Send_Sms_Url      = q{https://api.telstra.com/v1/sms/messages};

my $mobile_number = $ARGV[0] || $config->{'my_mobile'};

if ( not $mobile_number =~ m{ \A 04 \d{8} \z }smx )
{
    die "Error: Invalid mobile number supplied <$mobile_number>";
}

my $message = $ARGV[1] || q{Hello from John's myAlert SMS app};

print qq{\nRequesting token for SMS API ...\n};
print qq{\nMobile:     $mobile_number\n};
print qq{Message:    $message\n};


### request OAuth access token from Telstra
### using key and secret for myAlert app

my $agent = LWP::UserAgent->new();

$agent->agent('MyAlert SMS Testing - Perl/0.1');
$agent->timeout(60);

my $response = _get_access_token({
    'agent'  => $agent,
    'url'    => $Token_Request_Url,
    'config' => $config,
});

my $access_token = $response->{'token'};

#print qq{\nNow, use the access_token to send an SMS\n};


### Got the OAuth2 token, now send the SMS

my $sms_json = qq({"to": "$mobile_number", "body": "$message"});

#print qq{\nSMS_JSON: $sms_json\n};

my $sms_result = _send_sms({
    'agent'   => $agent,
    'url'     => $Send_Sms_Url,
    'token'   => $access_token,
    'json'    => $sms_json,
});

if ( $sms_result->is_error() )
{
    die "\nERROR: $sms_result->{'info'}\n";
}
else
{
    my $content      = from_json( $sms_result->content() );
    my $response_msg = $sms_result->message();

    print qq{SMS_RESULT: $response_msg\n};
    print qq{MESSAGE_ID: $content->{'messageId'}\n};
}


exit;

###########################################################
#
# Subroutines
#

sub _get_access_token
{
    my ($args) = @_;

    my $agent     = $args->{'agent'};
    my $token_url = $args->{'url'};
    my $config    = $args->{'config'};

    my $application = q{telstra_sms};

    my $app_data = retrieve_token({ 'application' => $application });

    if ( $app_data->{'age'} < $app_data->{'expires_in'} - 60 )
    {
        return {
            'token'      => $app_data->{'token'},
            'expires_in' => $app_data->{'expires_in'},
            'age'        => $app_data->{'age'},
        };
    }

    my $token       = q{};
    my $expires_in  = 0;

    my $client_id     = $config->{'client_id'};
    my $client_secret = $config->{'client_secret'};

    my $request = HTTP::Request->new();

    $request->header( 'Content-Type' => 'application/x-www-form-urlencoded' );

    my $post_data = [
        'client_id'     => $client_id,
        'client_secret' => $client_secret,
        'grant_type'    => 'client_credentials',
        'scope'         => 'SMS',
    ];

    $request->content( $post_data );

    my $response = $agent->post( $token_url, $post_data );

    if ( $response->is_success() )
    {
        my $content = $response->decoded_content();

        ( $token )      = $content =~ m{ access_token\"\: \s \" ( \S+ ) \" }smx;
        ( $expires_in ) = $content =~ m{ expires_in\"\: \s \" ( \d+ ) \" }smx;

        save_token({
            'application' => $application,
            'token'       => $token,
            'expires_in'  => $expires_in,
        });
    }
    else
    {
        print Dumper( $response );
        die "\nFailed to get access token: ", $response->status_line();
    }

    return { 'token' => $token, 'expires_in' => $expires_in };
}


#=========================================
# Send sms message, using the access token
#
sub _send_sms
{
    my ($args) = @_;

    my $agent = $args->{'agent'};
    my $url   = $args->{'url'};
    my $token = $args->{'token'};
    my $json  = $args->{'json'};

    my $request = HTTP::Request->new( 'POST', $url );

    $request->header( 'Content-Type'  => 'application/json' );
    $request->header( 'Authorization' => 'Bearer ' . $token );

    $request->content( $json );

    my $sms_response = $agent->request( $request );

#    print Dumper( $sms_response );

    return $sms_response;
}


#============================================
# Read config data, including secret data
#
sub _read_config
{
    my $config_file = '/kbin/send_sms.conf';
    my $config_data = {};

    open my $fh, '<', $config_file or die "Can't open $config_file: $!";

    while ( my $line = <$fh> )
    {
        next unless $line =~ m{~~~};

        chomp $line;

        my ( $key, $value ) = split '~~~', $line;

        $config_data->{$key} = $value;
    }

    close $fh;

    return $config_data;
}

__END__


