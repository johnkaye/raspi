package SmartPlug;

#
# Original script was based on: 
#  http://forums.ninjablocks.com/index.php?p=/discussion/2931/aldi-remote-controlled-power-points-5-july-2014/p1
#  and http://pastebin.ca/2818088

use strict;
use IO::Socket;
use IO::Select;
use Data::Dumper;

my $log_file = '/tmp/' . __PACKAGE__ . '.log';
my $DEBUG = 1; # If true, writes to the log file
my $port  = 10000;

my $mac_address = {
    'study'    => 'AC:CF:23:21:5B:28',
    'backroom' => 'AC:CF:23:24:52:0E',
    'patio'    => 'AC:CF:23:79:29:18',   # smartplug_3 - back patio
};

my $target = {
    1 => 'study',
    2 => 'backroom',
    3 => 'patio',
};

my $fbk_preamble = pack('C*', (0x68,0x64,0x00,0x1e,0x63,0x6c));
my $ctl_preamble = pack('C*', (0x68,0x64,0x00,0x17,0x64,0x63));
my $ctl_on       = pack('C*', (0x00,0x00,0x00,0x00,0x01));
my $ctl_off      = pack('C*', (0x00,0x00,0x00,0x00,0x00));
my $twenties     = pack('C*', (0x20,0x20,0x20,0x20,0x20,0x20));
my $onoff        = pack('C*', (0x68,0x64,0x00,0x17,0x73,0x66));
my $subscribed   = pack('C*', (0x68,0x64,0x00,0x18,0x63,0x6c));

my $fh = undef;
if ( $DEBUG )
{
    open $fh, '>>', $log_file;
}

#==============================
# create instance of SmartPlug
#
sub new
{
    my ( $class, $args ) = @_;

    print $fh qq{Called new()\n} if $DEBUG;

    my $plug_id   = $args->{'plug_id'};
    my $command   = $args->{'command'};
    my $number    = q{};
    my $location  = q{};
    my $mac_addr  = q{};
    my $self      = {};

    if ( not defined $plug_id or $plug_id eq q{} )
    {
        set_error( q{'plug_id' not provided, must be either mac_address, location or number} );
        return;
    }

    if ( $plug_id =~ m{\A\d\z} )
    {
        $number   = $plug_id;
        $location = $target->{$number};
        $mac_addr = $mac_address->{$location};
    }
    elsif ( $plug_id =~ m{\A\w+\z} )
    {
        $location = $plug_id;
        $mac_addr = $mac_address->{$location};
    }
    elsif ( $plug_id =~ m{\A\w{2}:\w{2}:\w{2}:\w{2}:\w{2}:\w{2}\z} )
    {
        $mac_addr = $plug_id;
    }
    else
    {
        set_error( q{Invalid 'plug_id', must be either mac_address (XX:XX:XX:XX:XX:XX), location or number} ); 
        return;
    }

    my @mac = (); #split( ':', $mac_addr );
    @mac    = map { hex("0x".$_) } split( ':', $mac_addr );

    if ( not scalar @mac == 6 )
    {
        set_error( q{mac_address is not in expected format XX:XX:XX:XX:XX:XX} );
        return;
    }

    my $mac = pack('C*', @mac);

    my $plug = undef;
    # make a few attempts to find the smart plug
    foreach (1..4)
    {
        $plug = _find_plug($mac);
        last if defined $plug;
        sleep 1;
    }

    if ( not defined($plug) )
    {
        set_error( qq{Could not find smart plug with mac of $mac_addr} );
        return;
    }

    $self = {
        mac_addr => $mac_addr,
        location => $location,
        number   => $number,
        mac      => $mac,
        saddr    => $plug->{saddr},
        socket   => $plug->{socket},
        status   => $plug->{status},
    };

    bless( $self, $class );

    # return smart_plug object
    return $self;
}

#######################################################
# Methods and private subroutines
# Note: the original script was written to control Bauhn smartplugs
#

sub _find_plug
{
    my ($mac, $socket) = @_;

    my $plug;
    my $reversed_mac = scalar(reverse($mac));
    my $subscribe    = $fbk_preamble.$mac.$twenties.$reversed_mac.$twenties;

    if ( not defined $socket )
    {
        $socket = IO::Socket::INET->new(Proto=>'udp', LocalPort=>$port, Broadcast=>1);
        if ( not $socket )
        {
            set_error( qq{Could not create UDP listen socket: $!\n} );
            return;
        }
    }

    $socket->autoflush();

    my $select = IO::Select->new($socket) || die "Could not create instance of IO::Select: $!\n";

    my $to_addr = sockaddr_in($port, INADDR_BROADCAST);
    my $send_ret = $socket->send($subscribe, 0, $to_addr);

    if ( not $send_ret )
    {
        set_error( qq{Send error: $!\n} );
        return;
    }

    my $n = 0;
    while($n < 3)
    {
        my @ready = $select->can_read(0.5);
        foreach my $fh (@ready)
            {
            my $packet;
            my $from = $socket->recv($packet,1024) || die "recv: $!";
            if ((substr($packet,0,6) eq $subscribed) && (substr($packet,6,6) eq $mac))
            {
                my ($port, $iaddr) = sockaddr_in($from);
                my $is_plug_on  = (substr($packet,-1,1) eq chr(1));
                my $status      = $is_plug_on ? 'on' : 'off';
                $plug->{on}     = $status;
                $plug->{status} = $is_plug_on ? 'on' : 'off';
                $plug->{mac}    = $mac;
                $plug->{saddr}  = $from;
                $plug->{socket} = $socket;
                return $plug;
            }
        }
        $n++;
    }

    close($socket);

    return;

} # find_plug()


sub _command
{
    my ( $plug, $action ) = @_;

    my $mac            = $plug->mac();
    my $command_string = q{};

    if ($action eq "on") {
        $command_string = $ctl_preamble.$mac.$twenties.$ctl_on;
    }
    if ($action eq "off") {
        $command_string = $ctl_preamble.$mac.$twenties.$ctl_off;
    }

    my $select = IO::Select->new($plug->{socket}) ||
                     die "Could not create Select: $!\n";

    my $n        = 0;
    my $send_ret = undef;

    while ($n < 2)
    {
        $send_ret = $plug->socket()->send( $command_string, 0, $plug->saddr() );
        if ( not $send_ret )
        {
            set_error( qq{Send error: $!} );
            return;
        }

        my @ready = $select->can_read(0.5);
        foreach my $fh (@ready)
        {
            my $packet = undef;
            my $reply  = $plug->socket()->recv($packet,1024);
            if ( not $reply )
            {
                set_error( qq{Receive error: $!} );
            }

            my @data       = unpack("C*", $packet);
            my @packet_mac = @data[6..11];


            if ( (substr($packet,0,6) eq $onoff) && (substr($packet,6,6) eq $mac) )
            {
                return 1;
            }
        }
        $n++;
    }
    return 0;
}


#======================
# Error string handling
#
{
    my $errstr = q{};

    sub set_error
    {
        $errstr = shift;
        print $fh qq{Called set_error(): $errstr\n} if $DEBUG;
        return 1;
    }

    sub get_error
    {
        return $errstr;
    }
}


#=========
# Commands
#
sub status
{
    my $self = shift;

    my $plug        = undef;
    my $plug_status = undef;

    foreach (1..5)
    {
        $plug        = _find_plug( $self->mac(), $self->socket() );
        $plug_status = $plug->{status};
        last if $plug_status;
    }
    $self->{status} = $plug_status;

    print $fh qq{Called status(): '$plug_status'\n} if $DEBUG;
    if ( not $plug_status )
    {
        my $error = $self->get_error();
        print $fh qq{Status Error: $error\n};
    }

    return $self->{status};
}

sub on
{
    my $plug = shift;
    my $command_ret = $plug->_command( 'on' );

    print $fh qq{Called on()\n} if $DEBUG;

    if ( not $command_ret )
    {
        return;
    }
    else
    {
        return 'on';
    }
}

sub off
{
    my $plug = shift;
    my $command_ret = $plug->_command( 'off' );

    print $fh qq{Called off()\n} if $DEBUG;

    if ( not $command_ret )
    {
        return;
    }
    else
    {
        return 'off';
    }
}


#=================
# Accessor methods
#

sub mac
{
    my $self = shift;
    return $self->{mac};
}

sub mac_addr
{
    my $self = shift;
    return $self->{mac_addr};
}

sub location
{
    my $self = shift;
    return $self->{location};
}

sub number
{
    my $self = shift;
    return $self->{number};
}

sub saddr
{
    my $self = shift;
    return $self->{saddr};
}

sub socket
{
    my $self = shift;
    return $self->{socket};
}

1;

__END__

=head1 NAME

SmartPlug - class for wifi smart plug access and control

=head1 SYNOPSIS

use SmartPlug;

my $plug = SmartPlug->new({
    'plug_id' => 2, 
});

my $plug = SmartPlug->new({
    'plug_id' => 'study',
});

my $plug = SmartPlug->new({
    'plug_id' => 'AC:CF:23:21:5B:28',
});

if ( not defined $plug )
{
    my $error = SmartPlug->get_error());
    print qq{\nERROR: $error\n} if $error;
}

print qq{Location: } . $plug->location() . qq{\n};
print qq{MAC addr: } . $plug->mac_addr() . qq{\n};
print qq{Status:   } . $plug->status()   . qq{\n};

my $new_status = $plug->on();

sleep 1;

$new_status = $plug->off();

=head1 DESCRIPTION

This module creates and returns an instance of smart_plug object.
If a valid mac address is provided in the 'plug_id' argument, either
directly or via a plug location name or number, the attributes of the
smart_plug object will include a reference to the socket that is set
up to communicate with the smart plug (remotely switched GPO).

=head1 CONSTRUCTORS

=head2 new

  my $plug = SmartPlug->new('plug_id' => 'AC:CF:23:21:5B:28');

Creates a SmartPlug object (connection) for the device with the given mac address.

=head1 METHODS

TODO: change the following to SmartPlug methods:

On success the appropriate true value for each method is
returned. On failure a false value is returned, upon which
an error message is set and can be returned via the
"errstr" method.

=head2 errstr

  print $survey->errstr();

  print Monash::Survey::Base->errstr();

Is available as both a class and object method. The class
"errstr" should be inspected when an object has failed to
be created, and the object method when a method call fails
unexpectedly. "errstr" will always contain the last known
error.

=head2 survey_id

  $survey->survey_id()

Returns survey id

=head2 title

  $survey->title()

Returns survey title

=head2 url_token

  $survey->url_token()

Returns survey url_token

=head2 form_id

  $survey->form_id()

Returns the survey form_id

=head2 can_change

  $survey->can_change()

Returns 1 or 0 depending if user can change their survey
response

=head2 opening_date

  $survey->opening_date()

Returns survey opening date

=head2 closing_date

  $survey->closing_date()

Returns survey closing date

=head2 report_date

  $survey->report_date()

Returns the last date that a response data report was created

=head2 page_heading

  $survey->page_heading()

Returns the page heading for the survey type

=head2 logo_text

  $survey->logo_text()

Returns the text that will be displayed under the Monash Uni logo

=head2 created_by

  $survey->created_by()

Returns who created survey

=head2 details

  $survey->details()

Returns survey details. Generally introductory text explaining
what the survey is about

=head2 type

  $survey->type()

Returns survey type

=head2 introduction_text

  $survey->introduction_text()

Returns survey introduction_text. Non editable field containing
blurb about survey. Not used by general surveys. Only for
unit evaluation, mseq and monquest.

=head2 closing_text

  $survey->closing_text()

Returns survey closing_text. This is a non-editable field containing
closing text for a survey type. This field is typically used to
hold a privacy statement.

=head2 is_editor

  $survey->is_editor( 'username' => 'jsmith' )

Returns 1 or 0 depending whether the user is an editor or not.
An editor is a person who did not create the survey but has been
granted editing access.

=head2 is_admin

  $survey->is_admin( 'username' => 'jsmith' )

Returns 1 or 0 depending whether the user created the survey, or
if the user has been added as an editor

=head2 is_open

  $survey->is_open()

Returns 1 or 0 depending on whether survey is open

=head2 status

  $survey->status()

Returns 'Pending' if survey opening date is in the future,
'Open' if the survey is open or 'Closed' if the survey is closed.

=head2 is_valid

  $survey->is_valid()

Returns 1 if this is a valid survey for the user to do. Does
the following checks:

  - not before opening date
  - not after closing date
  - user has not submitted the survey (optional)

Populates the errstr() with the correct message

=head2 set_survey_details

my $insert = $survey->set_survey_details(
  'title'        => $title,
  'logo_text'    => $logo_text,
  'form_id'      => $form_id,
  'change'       => $change,
  'opening_date' => $opening_date,
  'closing_date' => $closing_date,
  'created_by'   => scalar( $user->uid() ),
  'details'      => $details,
  'editors'      => 'jsmith,peterh',
);

my $result  = $survey->set_survey_details(
  'report_date'  => 1,
);

Will either create a new survey or update existing survey.  When
updating a survey, you only need to pass the parameters that you
want to change.

On success, a reloaded survey object is returned.

The C<report_date> will be updated to SYSDATE if the survey is
closed and parmater passed is C<1>, otherwise it will be unchanged.

=head2 copy

  my $copy = $survey->copy(
    'new_title'  => 'Survey_2006',
    'created_by' => 'jsmith',
  );

Copies the existing survey details and questions to survey with
new title. Returns survey object of new title. If fails half way
through (e.g details created but not questions), the survey
will need to be deleted and tried again

=head2 delete

  my $delete = $survey->delete();

Deletes survey answers, questions, cal_types and details.


=head1 DEPENDENCIES

L<IO::Socket> - used for setting up a TCP/UDP socket

L<IO::Select>

L<Data::Dumper>

=head1 AUTHOR

John Kaye E<lt>jkaye29@gmail.comE<gt>
