#!/usr/bin/perl

# program: grab_modem.pl
# author:  John Kaye

# Send email to advise of the new WAN IP address
# when the IP address changes, eg. at modem restart

use strict;
use warnings;

use lib "/kbin";

use Net::FTP;
use MIME::Lite;

use Grab qw{
    get_content
};

my $modem = {
	'realm'    => 'Netgear',
	'location' => '192.168.1.1',
    'url'      => 'http://192.168.1.1/RgSetup.asp',
};

my $to_email   = q{jkaye29@gmail.com};
my $from_email = q{no-reply@thekayes.noip.me};
my $subject    = q{};

## get last saved ip address
my $last_address;

my $web_file = '/kbin/index.html';
my $ip_file  = '/home/jkaye/bigpond_ip';

my $fh;
open ($fh, "<", $ip_file) or die "Can't open $ip_file: $!";
while ( <$fh> )
{
    $last_address = $_;
    chomp $last_address;
}
close $fh;

$last_address ||= q{127.0.0.1};

#print qq{\nLast IP: $last_address\n}; # DEBUG

# get password
my $cipher_file   = q{grab_modem.cip};
my $cipher_string = q{};
my @cipher        = [];

open ($fh, "<", $cipher_file) or die "Can't open $cipher_file: $!";
while ( <$fh> )
{
    $cipher_string = $_;
    chomp $cipher_string;

    @cipher = split q{,}, $cipher_string;
}
close $fh;

my $word = join( '', map { chr($_) } @cipher );

#print qq{\n$word\n}; # DEBUG

my $content = q{};
my $result  = get_content(
    'location' => $modem->{'location'},
    'realm'    => $modem->{'realm'},
    'username' => 'admin',
    'password' => $word,
    'url'      => $modem->{'url'},
    'method'   => 'GET',
);

if ( $result->{'error'} )
{
    print "\nERROR: $result->{'info'}\n";
}
else
{
    $content = $result->{'data'};
}

#$content =~ m{ wan_ip \s = \s "(\S+)" }smx; # Linksys
#$content =~ m{ Lease\sTime .+ IP\sAddress</B></TD>\s<TD>(\S+) \s }smx; # D-Link
#$content =~ m{ WAN\sIP</div>\n(\d{3}\.\d{1,3}\.\d{1,3}\.\d{1,3}) }smx; # DD-WRT
#$content =~ m{ wan_ipaddr:\s\'(\d{3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\' }smx; # Tomato

$content =~ m{
	IP \s Address: </td>
	<td>
    <b>
	(\d{2,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})
    </b>
	</td>
}smx; # NetGear

my $ip_address = $1;

if ( not $ip_address )
{
	die "Could not get ip_address from modem";
}

#print "This IP: $ip_address\n"; # DEBUG

#
# send email if IP address has changed
#
if ( $ip_address ne $last_address )
{
    # we have a new IP address
    print "BigPond IP address changed from $last_address to $ip_address\n";

    # update the ip address file
    open ($fh, ">", $ip_file) or die "Can't open $ip_file for write: $!";
    print $fh $ip_address, "\n";
    close $fh;

	# send an email to John Kaye

	my $message = q{};

	$message .= qq{Hi John,\n\nYour Bigpond IP address has changed.\n\n};
	$message .= qq{Old IP address: $last_address\n\n};
	$message .= qq{New IP address: $ip_address\n\n};
	$message .= qq{\nRegards,\nJohn's PA (the computer in the cupboard)\n};

	# create MIME object
	my $mail_item = MIME::Lite->new(
		'To'      => $to_email,
		'From'    => $from_email,
		'Subject' => 'BigPond IP address has changed to: ' . $ip_address,
		'Data'    => $message,
	);

	# send the email
	$mail_item->send();

	print qq{Email sent to John\n};
}
else
{
	print qq{BigPond IP address: $ip_address\n};
}
 
exit;

