#!/usr/bin/perl

### grab_power_stats.pl

# Read current solar power output from ECU
# Read grid power input from Eagle smart meter reader
# Return the data in the format required by MRTG

use strict;
use warnings;

use IO::Socket;
use Data::Dumper;

use lib '/kbin';

use Grab qw{ get_content };

use Date::Format qw{ time2str };

my $DEBUG = 0; # if true, prints messages and doesn't update the $day_generation_file

# initialise variables for current power - for rgraph display
my $current_power = 0;
#my $power_csv_file = '/kbin/power.csv';
my $power_csv_file = '/var/www/htdocs/power.csv';

my $ecu_url    = q{http://192.168.1.81/cgi-bin/home};
my $eagle_host = q{192.168.1.6};
my $eagle_port = q{5002};
my $eagle_mac  = q{0xd8d5b90000000f85};

my $eagle_cmd = qq{<LocalCommand>
  <Name>get_instantaneous_demand</Name>
  <MacId>$eagle_mac</MacId>
</LocalCommand>};

my $log_file            = '/kbin/ecu.log';
my $day_generation_file = '/kbin/generation_of_current_day.txt';

my $uptime_msg = q{some time};
my $content    = q{};

### get average solar power output (watts) for a 5 minute sample period

my $result = get_content(
	'url' => $ecu_url,
);

if ( $result->{'error'} )
{
	$uptime_msg = q{a while, but now the ECU result is: } . $result->{'info'};
}
else
{
	$content = $result->{'data'};
}

if ( $DEBUG )
{
    print qq{\nSOLAR_HTML: \n}, $content, qq{\n\n}; # DEBUG
}

my $current_day_generation = 0;
my $saved_day_generation   = 0;
my $generated              = 0;
my $average_solar_watts    = 0;

if ( $content =~ m{ Generation \s Of \s Current \s Day </td><td \s align=center> (\d+ [.] \d+) \s kWh }smx )
{
	$current_day_generation = $1;
}

# get last saved day generation, then save the latest value

if ( -e $day_generation_file )
{
	# get last saved day generation value
	open my $fh, "<", $day_generation_file
		or die "Can't open $day_generation_file: $!";

	while ( my $line = <$fh> )
	{
		$saved_day_generation = $line;
	}

	close $fh;

	if ( $DEBUG )
	{
		print qq{DEBUG - Current Generation for the Day: $current_day_generation\n};
	}
	else
	{
		# save the current day generation value
		open $fh, ">", $day_generation_file
			or die "Can't open $day_generation_file: $!";

		print $fh $current_day_generation, qq{\n};

		close $fh;
	}
}

$generated = $current_day_generation - $saved_day_generation;

# reset generated value for a new day
$generated = $generated < 0 ? 0 : $generated;

# power is sampled every 5 minutes, so calculate average watt-hours
$average_solar_watts = sprintf( "%.1f", $generated * 12 * 1000 );

### get current grid power demand (watts) from Eagle smart meter reader

my $socket = IO::Socket::INET->new(
	'PeerAddr' => $eagle_host,
	'PeerPort' => $eagle_port,
	'Proto'    => 'tcp',
	'Type'     => SOCK_STREAM,
    'timeout'  => 10,
#) or die "Couldn't connect to $eagle_host:$eagle_port: $!" if $DEBUG;
);

# send the get_instantaneous_demand command

my $grid_demand = 0;

if ( $socket )
{
	print $socket $eagle_cmd, qq{\n};

	my $xml_string   = q{};
	my $found_demand = 0;
	 
	LINE: while ( my $xml_line = <$socket> )
	{
        #if ( $DEBUG )
        #{
        #    print qq{\nEAGLE-XML> $xml_line\n};
        #}

		if ( $xml_line =~ m{ <InstantaneousDemand }smx )
		{
			$xml_string .= $xml_line;

			$found_demand = 1;

			next LINE;
		}

		if ( $xml_line =~ m{ </InstantaneousDemand }smx )
		{
			$xml_string .= $xml_line;

			$found_demand = 0;

			next LINE;
		}

		if ( $found_demand )
		{
			$xml_string .= $xml_line;
		}
	}

    if ( $DEBUG )
    {
        print qq{\nEAGLE_XML:\n$xml_string\n};
    }

	close $socket;

	# extract meter data from the xml string
	my $meter_data = xml_data( $xml_string );

    if ( $DEBUG )
    {
        print Dumper({ 'METER_DATA' => $meter_data });
    }

	my $multiplier = hex $meter_data->{'Multiplier'};
	my $divisor    = hex $meter_data->{'Divisor'};

    # grid 'demand' is a 24-bit (6-character) signed integer
	my $demand_raw = hex substr $meter_data->{'Demand'}, -6;

    if ( $DEBUG )
    {
        print qq{\nRAW_DEMAND:  $demand_raw\n};
        print qq{MULTIPLIER:  $multiplier\n};
        print qq{DIVISOR:     $divisor\n};
    }

    # adjust for negative value (power to the grid)
    my $demand = $demand_raw >= 2**23
               ? $demand_raw - 2**24
               : $demand_raw;

    if ( $DEBUG )
    {
        print qq{GRID_DEMAND: $demand\n\n};
    }

	$grid_demand = ( $demand * $multiplier ) / $divisor;

	$grid_demand = $grid_demand < 0 ? 0 : $grid_demand;

	$grid_demand = sprintf( "%.1f", $grid_demand * 1000 );
}
else
{
	$uptime_msg .= q{ (but eagle could not be contacted)}
}

print qq{$average_solar_watts\n};
print qq{$grid_demand\n};
print qq{$uptime_msg\n};
print qq{Solar power generation and Grid power usage\n};

open my $fh, '>>', $log_file or die "Can't open $log_file: $!";
print $fh time, q{ }, qq{$average_solar_watts $grid_demand\n};
close $fh;

# write csv file for current power display
$current_power = sprintf( "%02f", ( $average_solar_watts - $grid_demand ) / 1000 );

open my $cfh, '>', $power_csv_file or die "Can't open $power_csv_file: $!";
print $cfh qq{$current_power\n};
close $cfh;


exit;

#======================
# Subroutine: xml_data
#
# given an xml string, return a hash of data keyed by the tags
# Note: unable to install XML::Simple on a raspberry pi using CPAN

sub xml_data
{
        my ($xml_string) = @_;

        my @xml_lines = split qq{\n}, $xml_string;
        my %xml       = ();

        foreach my $xml_line ( @xml_lines )
        {
                chomp $xml_line;

                if ( $xml_line =~ m{ \A \s* < ([A-Z][A-Za-z0-9]*) \b [^>]* > (.*?) </\1> }smx )
                {
                        $xml{$1} = $2;
                }
        }

        return \%xml;
}

