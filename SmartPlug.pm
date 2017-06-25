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

  my $plug = SmartPlug->new({ 'plug_id' => 'AC:CF:23:21:5B:28'} );

Creates a SmartPlug object (connection) for the device with the given mac address.

=head1 METHODS

On success the appropriate true value for each method is
returned. On failure a false value is returned, upon which
an error message is set and can be returned via the
"errstr" method.

=head2 status

  $plug->status()

Returns the on/off status of the smart plug

=head2 on

  $plug->on()

Sends a command to turn the smart plug on.
Returns the on/off status of the smart plug

=head2 off

  $plug->off()

Sends a command to turn the smart plug on.
Returns the on/off status of the smart plug

=head2 errstr

  print $plug->errstr();

  print SmartPlug->errstr();

Is available as both a class and object method. The class
"errstr" should be inspected when an object has failed to
be created, and the object method when a method call fails
unexpectedly. "errstr" will always contain the last known
error.


=head1 DEPENDENCIES

L<IO::Socket> - used for setting up a TCP/UDP socket

L<IO::Select>

L<Data::Dumper>

=head1 AUTHOR

John Kaye E<lt>jkaye29 @ gmail.comE<gt>
