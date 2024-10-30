package Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Processor::EnqueueNotices;

use Modern::Perl;
use JSON qw( from_json );

use parent qw(Koha::ILL::Request::SupplierUpdateProcessor);
use Koha::Plugin::Com::PTFSEurope::ReprintsDesk;

sub new {
    my ($class) = @_;
    my $self = $class->SUPER::new( 'backend', 'ReprintsDesk', 'EnqueueNotices' );
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
    $self->{dry_run}  = $options->{dry_run};
    $self->{env}      = $options->{env};
    $self->{rd} =
        Koha::Plugin::Com::PTFSEurope::ReprintsDesk->new->new_ill_backend( { logger => Koha::ILL::Request::Logger->new } );

    # Get branches that contain not 'COMP' requests
    # FIXME: There must be a prettier/better way of doing this
    my $dbh            = C4::Context->dbh;
    my $time_interval  = $self->{env} && $self->{env} eq 'prod' ? 'AND updated <= NOW() - INTERVAL 2 DAY' : '';
    my $branches_query = "SELECT DISTINCT branchcode
        FROM illrequests
        WHERE backend = 'ReprintsDesk' AND status != 'COMP'" . $time_interval;
    my $sth = $dbh->prepare($branches_query);
    $sth->execute();
    my $branches_hash = $sth->fetchall_arrayref( {} );

    # Bail if we got nothing to work with
    if ( scalar @{$branches_hash} == 0 ) {
        die("No hanging requests. Bailing");
    }

    # Get orderIDs from open orders in User_GetOrderHistory's response
    my %open_order_ids_hash = $self->_get_open_order_ids;

    # For each branch containing hanging requests, prepare the notice message
    my @branches = Koha::Libraries->search($branches_hash)->as_list();
    foreach my $branch (@branches) {

        # Get the requests not updated in over 24 hours
        my $one_day_ago = DateTime->now( time_zone => 'local' )->subtract( days => 2 );
        my $requests    = Koha::ILL::Requests->search(
            {
                branchcode => $branch->branchcode,
                status     => { '!=', 'COMP' },
                backend    => 'ReprintsDesk',
                (
                    $self->{env} eq 'prod' ? ( updated => { '<=' => $one_day_ago->ymd . "T" . $one_day_ago->hms } ) : ()
                )
            },
            { order_by => { -desc => 'updated' } }
        );

        my $found_orders_count;
        my $lost_orders_count;
        my $new_orders_count;
        my $new_orders_rows   = '';
        my $found_orders_rows = '';
        my $lost_orders_rows  = '';

        # Prepare the notice message text
        $self->debug_msg( "Found " . $requests->count . " requests to enqueue for branch " . $branch->branchname );
        foreach my $ill_request ( $requests->as_list ) {
            if ( $ill_request->status eq 'READY' ) {
                die('There is a READY request, check that cron for PlaceOrders is in place');
            }
            if ( $ill_request->status eq 'NEW' ) {
                $new_orders_rows .= $self->_get_html_order_row($ill_request);
                $new_orders_count++;
                next;
            }

            # Hanging orders, check if they're in User_GetOrderHistory response or not
            if ( exists( $open_order_ids_hash{ $ill_request->orderid } ) ) {
                $found_orders_rows .= $self->_get_html_order_row($ill_request);
                $found_orders_count++;
            } else {
                $lost_orders_rows .= $self->_get_html_order_row($ill_request);
                $lost_orders_count++;
            }
        }

        my $new_orders_html_table =
            $new_orders_rows
            ? $self->_get_html_email_message( "There are "
                . $new_orders_count
                . " new requests at "
                . $branch->branchname
                . " that need approval by a Staff member:<br/>\n", $new_orders_rows )
            : '';

        my $found_orders_html_table =
            $found_orders_rows
            ? $self->_get_html_email_message( "There are "
                . $found_orders_count
                . " requests at "
                . $branch->branchname
                . " still in process by Reprints Desk:<br/>\n", $found_orders_rows )
            : '';

        my $lost_orders_html_table =
            $lost_orders_rows
            ? $self->_get_html_email_message( "There are "
                . $lost_orders_count
                . " requests at "
                . $branch->branchname
                . " that need manual checking:<br/>\n", $lost_orders_rows )
            : '';

        $self->_enqueue_letter( $branch, $new_orders_html_table . $lost_orders_html_table . $found_orders_html_table );
    }
}

sub _get_open_order_ids {
    my ($self)               = @_;
    my $open_orders_response = $self->{rd}->{_api}->User_GetOrderHistory(1);
    my $body                 = from_json( $open_orders_response->decoded_content );
    if ( scalar @{ $body->{errors} } == 0 && $body->{result}->{User_GetOrderHistoryResult} == 1 ) {
        my $dom            = XML::LibXML->load_xml( string => $body->{xmlData} );
        my @orders         = $dom->findnodes('/xmlData/orders/order/orderdetail/orderid');
        my @open_order_ids = map( $_->textContent, @orders );
        return map { $open_order_ids[$_] => $_ } 0 .. $#open_order_ids;
    } else {
        die( 'GetOrderHistory returned error ' . join '.', map { $_->{message} } @{ $body->{errors} } );
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
    <th>Batch</th>
    <th>Status</th>
    <th>Order ID</th>
    <th>Updated at</th>
    <th>ReprintsDesk Order Status Page</th>
  </tr>
  $rows
</table>
</body>
</html>
HTML
}

sub _get_html_order_row {
    my ( $self, $ill_request ) = @_;
    my $status_graph = $self->{rd}->status_graph;
    my $staff_url    = C4::Context->preference('staffClientBaseURL');
    $staff_url =~ s{/\z}{};    # Remove possible trailing slash

    my $rndId = $ill_request->illrequestattributes->find(
        {
            illrequest_id => $ill_request->illrequest_id,
            type          => "rndId"
        }
    );
    my $rpdesk_api_www_url = $self->{env} && $self->{env} eq 'prod' ? 'www' : 'wwwstg';
    my $rpdesk_os_link =
        $rndId
        ? 'https://'
        . $rpdesk_api_www_url
        . '.reprintsdesk.com/landing/os.aspx?o='
        . $ill_request->orderid . '&r='
        . $rndId->value
        : '';

    my $ill_request_batch = Koha::Illbatches->find( $ill_request->batch_id );
    my $ill_batch_name    = $ill_request_batch ? $ill_request_batch->name : '';
    my $ill_batch_id      = $ill_request_batch ? $ill_request_batch->id   : '';

    return sprintf( "
        <tr>
            <td>
                <a href=\"%s/cgi-bin/koha/ill/ill-requests.pl?method=illview&illrequest_id=%d\">ILL-%d</a>
            </td>
            <td>
                <a href=\"%s/cgi-bin/koha/ill/ill-requests.pl?batch_id=%d\">%s</a>
            </td>
            <td>%s</td>
            <td>#%d</td>
            <td>%s</td>
            <td>
                <a href=\"%s\">%s</a>
            </td>
        </tr>
        ",

        # request id with link col
        $staff_url, $ill_request->illrequest_id, $ill_request->illrequest_id,

        # batch name with link col
        $staff_url, $ill_batch_id, $ill_batch_name,

        # status row
        $status_graph->{ $ill_request->status }->{name},

        # orderid row
        ( $ill_request->orderid ? $ill_request->orderid : '0' ),

        # updated at row
        $ill_request->updated,

        # RPdesk order status page link
        $rpdesk_os_link, $rpdesk_os_link );
}

sub _enqueue_letter {
    my ( $self, $branch, $message_text ) = @_;
    my $notice_code       = 'ILL_REQUEST_DIGEST';
    my $send_staff_notice = C4::Context->preference('ILLSendStaffNotices') // q{};

    if ( $send_staff_notice !~ /\b$notice_code\b/ ) {
        die( "ILLSendStaffNotices sys pref does not contain " . $notice_code );
    }

    my $letter = C4::Letters::GetPreparedLetter(
        module      => 'ill',
        letter_code => $notice_code,
        substitute  => { additional_text => $message_text }
    );

    # Try and get an address to which to send staff notices
    my $to_address   = $branch->inbound_ill_address;
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
        $self->debug_msg( "Please confirm that notice template '" . $notice_code . "' exists" );
    }
}

sub debug_msg {
    my ( $self, $msg ) = @_;
    if ( $self->{do_debug} && ref $self->{do_debug} eq 'CODE' ) {
        &{ $self->{do_debug} }( $self->{dry_run} ? "DRY RUN: $msg" : $msg );
    }
}

1;
