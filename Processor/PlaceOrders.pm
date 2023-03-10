package Koha::Illbackends::ReprintsDesk::Processor::PlaceOrders;

use Modern::Perl;

use parent qw(Koha::Illrequest::SupplierUpdateProcessor);
use Koha::Illbackends::ReprintsDesk::Base;

sub new {
    my ( $class ) = @_;
    my $self = $class->SUPER::new('backend', 'ReprintsDesk', 'PlaceOrders');
    bless $self, $class;
    return $self;
}

sub run {
    my ( $self, $update, $options, $status ) = @_;

    $self->{do_debug} = $options->{debug};
    $self->{dry_run} = $options->{dry_run};
    $self->{env} = $options->{env};

    my $rd = Koha::Illbackends::ReprintsDesk::Base->new( { logger => Koha::Illrequest::Logger->new } );

    # Prepare the query
    my $dbh   = C4::Context->dbh;
    my $query = "
        SELECT * FROM illrequests
        WHERE status='READY' ORDER BY illrequest_id ASC
        LIMIT 15;
    ";
    my $sth = $dbh->prepare($query);
    $sth->execute();
    my $ill_requests_hash = $sth->fetchall_arrayref( {} );

    # Bail if we got nothing to work with
    my $requests_count = scalar @{$ill_requests_hash};
    if ( $requests_count == 0 ) {
        die ("No 'READY' requests found. Bailing");
    }

    # Attempt to place an order for each 'READY' request
    $self->debug_msg('Found ' . $requests_count . ' \'READY\' requests');
    foreach my $ill_request_hash (@{$ill_requests_hash}) {
        my $ill_request = Koha::Illrequests->find( $ill_request_hash->{illrequest_id} );
        $rd->create_request($ill_request) if !$options->{dry_run};
    }

    $self->debug_msg('Getting order history from RPDesk');
    # Wait a bit before asking RPDesk the history of the orders we just placed
    sleep(10);
    my $get_order_history_proc = Koha::Illbackends::ReprintsDesk::Processor::GetOrderHistory->new;
    $get_order_history_proc->run(undef, { debug => $self->{do_debug}, dry_run => $self->{dry_run}, env = $self->{env} });
}

sub debug_msg {
    my ( $self, $msg ) = @_;
    if ($self->{do_debug} && ref $self->{do_debug} eq 'CODE') {
        &{$self->{do_debug}}($self->{dry_run} ? "DRY RUN: $msg" : $msg);
    }
};

1;