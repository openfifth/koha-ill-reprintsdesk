package Koha::Illbackends::ReprintsDesk::Processor::EnqueueNotices;

use Modern::Perl;
use JSON qw( from_json );

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

    # Get orderIDs from open orders in User_GetOrderHistory's response
    my %open_order_ids_hash = $self->_get_open_order_ids( $rd );

    # For each branch containing hanging requests, prepare the notice message
    my @branches = Koha::Libraries->search( $branches_hash )->as_list();
    foreach my $branch (@branches) {

        # Get the hanging requests from this library
        my $requests_query = "SELECT * FROM illrequests WHERE branchcode = '" . $branch->branchcode . "' AND " . $query;
        my $sth = $dbh->prepare($requests_query);
        $sth->execute();
        my $ill_requests_hash = $sth->fetchall_arrayref( {} );
        my $requests_count = scalar @{$ill_requests_hash};

        my $found_orders_count;
        my $lost_orders_count;
        my $found_orders_message_text = '';
        my $lost_orders_message_text = '';

        # Prepare the notice message text
        $self->debug_msg("Found " . $requests_count . " requests to enqueue");
        foreach my $ill_request_hash (@{$ill_requests_hash}) {
            my $ill_request = Koha::Illrequests->find( $ill_request_hash->{illrequest_id} );

            my $rndId = $ill_request->illrequestattributes->find({
                illrequest_id => $ill_request->illrequest_id,
                type          => "rndId"
            });
            my $rpdesk_api_www_url = $self->{env} && $self->{env} eq 'prod' ? 'www' : 'wwwstg';
            my $rpdesk_os_link = 'https://' . $rpdesk_api_www_url . '.reprintsdesk.com/landing/os.aspx?o='.$ill_request->orderid.'&r='.$rndId->value;

            # Not a lost order, add entry normally to digest
            if ( $open_order_ids_hash{$ill_request->orderid} ) {
                $found_orders_message_text .= sprintf("<tr><td><a href=\"%s/cgi-bin/koha/ill/ill-requests.pl?method=illview&illrequest_id=%d\">ILL-%d</a></td><td>%s</td><td>#%d</td><td><a href=\"%s\">%s</a></td></tr>", $staff_url, $ill_request->illrequest_id, $ill_request->illrequest_id, $status_graph->{$ill_request->status}->{name}, $ill_request->orderid, $rpdesk_os_link, $rpdesk_os_link);
                $found_orders_count++;
            # This is a lost order, add entry to separate list
            } else {
                $lost_orders_message_text .= sprintf("<tr><td><a href=\"%s/cgi-bin/koha/ill/ill-requests.pl?method=illview&illrequest_id=%d\">ILL-%d</a></td><td>%s</td><td>#%d</td><td><a href=\"%s\">%s</a></td></tr>", $staff_url, $ill_request->illrequest_id, $ill_request->illrequest_id, $status_graph->{$ill_request->status}->{name}, $ill_request->orderid, $rpdesk_os_link, $rpdesk_os_link);
                $lost_orders_count++;
            }
        }

        my $found_orders_html_message = $found_orders_message_text ? $self->_get_html_email_message("There are " . $found_orders_count . " requests at " . $branch->branchname . " still in process by Reprints Desk:<br/>\n", $found_orders_message_text) : '';
        my $lost_orders_html_message = $lost_orders_message_text ? $self->_get_html_email_message("There are " . $lost_orders_count . " unreachable requests at " . $branch->branchname . " that need manual checking:<br/>\n", $lost_orders_message_text) : '';
        my $message_text = $found_orders_html_message . $lost_orders_html_message;

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

sub _get_open_order_ids {
    my ( $self, $rd ) = @_;
    my $open_orders_response = $rd->{_api}->User_GetOrderHistory(1);
    my $body = from_json($open_orders_response->decoded_content);
    if (scalar @{$body->{errors}} == 0 && $body->{result}->{User_GetOrderHistoryResult} == 1) {
        my $dom = XML::LibXML->load_xml(string => $body->{result}->{xmlData}->{_});
        my @orders = $dom->findnodes('/xmlData/orders/order/orderdetail/orderid');
        my @open_order_ids = map( $_->textContent , @orders );
        return map { $open_order_ids[$_] => $_ } 0..$#open_order_ids;
    } else {
        die('GetOrderHistory returned error ' . join '.', map { $_->{message} } @{$body->{errors}});
    }
}

sub _get_html_email_message {
    my ( $self, $header, $rows ) = @_;
    return <<"HTML";
<html>
<head>
<style>
table {
  font-family: arial, sans-serif;
  border-collapse: collapse;
  width: 100%;
}

td, th {
  border: 1px solid #dddddd;
  text-align: left;
  padding: 8px;
}

tr:nth-child(even) {
  background-color: #dddddd;
}
</style>
</head>
<body>
<h3>$header</h3>
<table>
  <tr>
    <th>ILL Request</th>
    <th>Status</th>
    <th>Order ID</th>
    <th>ReprintsDesk Order Status Page</th>
  </tr>
  $rows
</table>
</body>
</html>
HTML
}

sub debug_msg {
    my ( $self, $msg ) = @_;
    if ($self->{do_debug} && ref $self->{do_debug} eq 'CODE') {
        &{$self->{do_debug}}($self->{dry_run} ? "DRY RUN: $msg" : $msg);
    }
};

1;