package Koha::Illbackends::ReprintsDesk::Processor::EnqueueNotices;

use Modern::Perl;

use parent qw(Koha::Illrequest::SupplierUpdateProcessor);
use Koha::Illbackends::ReprintsDesk::Base;

sub new {
    my ( $class ) = @_;
    my $self = $class->SUPER::new('backend', 'ReprintsDesk', 'EnqueueNotices');
    bless $self, $class;
    return $self;
}

# Instructions:
# - staffClientBaseURL sys pref needs to be correctly set to the staff URL
# - ILL_REQUEST_DIGEST notice template (HTML message) needs to exist containing only [% additional_text %] in body
# - ILLDefaultStaffEmail sys pref or inbound_ill_address for the branch needs to be set to receive email
# - The below config needs to exist in <config> at /etc/koha/sites/koha-conf.xml (changed appropriately)
# <smtp_server>
#    <host>__SMTP_HOST__</host>
#    <port>__SMTP_PORT__</port>
#    <timeout>__SMTP_TIMEOUT__</timeout>
#    <ssl_mode>__SMTP_SSL_MODE__</ssl_mode>
#    <user_name>__SMTP_USER_NAME__</user_name>
#    <password>__SMTP_PASSWORD__</password>
#    <debug>__SMTP_DEBUG__</debug>
# </smtp_server>

sub run {
    my ( $self, $update, $options, $status ) = @_;

    $self->{do_debug} = $options->{debug};
    $self->{dry_run} = $options->{dry_run};
    $self->{env} = $options->{env};

    my $rd = Koha::Illbackends::ReprintsDesk::Base->new( { logger => Koha::Illrequest::Logger->new } );
    my $status_graph = $rd->status_graph;
    my $dbh   = C4::Context->dbh;

    my $time_interval = $self->{env} && $self->{env} eq 'prod' ? 'AND updated <= NOW() - INTERVAL 1 DAY' : '';
    my $query = "status != 'COMP' " . $time_interval . " ORDER BY updated DESC;";
    my $notice_code = 'ILL_REQUEST_DIGEST';
    my $staff_url = C4::Context->preference('staffClientBaseURL');
    $staff_url =~ s{/\z}{}; # Remove possible trailing slash

    # Prepare the branches query
    my $branches_query = "SELECT DISTINCT branchcode FROM illrequests WHERE " . $query;
    my $sthh = $dbh->prepare($branches_query);
    $sthh->execute();
    my $branches_hash = $sthh->fetchall_arrayref( {} );

    # Bail if we got nothing to work with
    my $branches_count = scalar @{$branches_hash};
    if ( $branches_count == 0 ) {
        die ("No hanging requests. Bailing");
    }

    # For each branch containing hanging requests, prepare the notice message
    my @branches = Koha::Libraries->search( $branches_hash )->as_list();
    foreach my $branch (@branches) {

        # Get the hanging requests from this library
        my $requests_query = "SELECT * FROM illrequests WHERE branchcode = '" . $branch->branchcode . "' AND " . $query;
        my $sth = $dbh->prepare($requests_query);
        $sth->execute();
        my $ill_requests_hash = $sth->fetchall_arrayref( {} );
        my $requests_count = scalar @{$ill_requests_hash};

        # Prepare the notice message text
        my $message_text = "There are " . $requests_count . " requests at " . $branch->branchname . " not yet processed by Reprints Desk:<br/>\n";
        $self->debug_msg("Found " . $requests_count . " requests to enqueue");
        foreach my $ill_request_hash (@{$ill_requests_hash}) {
            my $ill_request = Koha::Illrequests->find( $ill_request_hash->{illrequest_id} );

            # Add entry to message text
            $message_text .= sprintf("<a href=\"%s/cgi-bin/koha/ill/ill-requests.pl?method=illview&illrequest_id=%d\">ILL-%d | orderID #%d | %s</a><br/>\n", 
            $staff_url, $ill_request->illrequest_id, $ill_request->illrequest_id, $ill_request->orderid, $status_graph->{$ill_request->status}->{name});
        }

        # Get the staff notices that have been assigned for sending in the syspref
        my $send_staff_notice = C4::Context->preference('ILLSendStaffNotices') // q{};

        # If it hasn't been enabled in the syspref, we don't want to send it
        if ($send_staff_notice !~ /\b$notice_code\b/) {
            die ("ILLSendStaffNotices sys pref does not contain " . $notice_code);
        }

        my $letter = C4::Letters::GetPreparedLetter(
            module                 => 'ill',
            letter_code            => $notice_code,
            substitute  => {
                additional_text    => $message_text
            }
        );

        # Try and get an address to which to send staff notices
        my $to_address = $branch->inbound_ill_address;
        my $from_address = $branch->inbound_ill_address;

        my $params = {
            letter                 => $letter,
            message_transport_type => 'email',
            from_address           => $from_address
        };

        if ($to_address) {
            $params->{to_address} = $to_address;
        } else {
            $self->debug_msg("branchillemail field for library or ILLDefaultStaffEmail system preference are not set");
        }

        if ($letter) {
            C4::Letters::EnqueueLetter($params) or warn "can't enqueue letter $letter";
        } else {
            $self->debug_msg("Please confirm that notice template '" . $notice_code . "' exists");
        }
        $self->debug_msg($message_text);
    }
}

sub debug_msg {
    my ( $self, $msg ) = @_;
    if ($self->{do_debug} && ref $self->{do_debug} eq 'CODE') {
        &{$self->{do_debug}}($self->{dry_run} ? "DRY RUN: $msg" : $msg);
    }
};

1;