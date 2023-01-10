package Koha::Illbackends::ReprintsDesk::Processor::GetOrderHistory;

use Modern::Perl;
use JSON qw( from_json );

use parent qw(Koha::Illrequest::SupplierUpdateProcessor);
use Koha::Illbackends::ReprintsDesk::Base;

sub new {
    my ( $class ) = @_;
    my $self = $class->SUPER::new('backend', 'ReprintsDesk', 'GetOrderHistory');
    bless $self, $class;
    return $self;
}

sub run {
    my ( $self, $update, $options, $status ) = @_;

    $self->{do_debug} = $options->{debug};
    $self->{dry_run} = $options->{dry_run};
    $self->{env} = $options->{env};

    my $rd = Koha::Illbackends::ReprintsDesk::Base->new( { logger => Koha::Illrequest::Logger->new } );
    my $response = $rd->{_api}->User_GetOrderHistory(2);
    my $body = from_json($response->decoded_content);

    if (scalar @{$body->{errors}} == 0 && $body->{result}->{User_GetOrderHistoryResult} == 1) {
        my $dom = XML::LibXML->load_xml(string => $body->{result}->{xmlData}->{_});
        my @orders = $dom->findnodes('/xmlData/orders/order/*');

        # Iterate on returned orderdetails
        foreach my $orderdetail(@orders) {

            my @orderid = $orderdetail->getChildrenByTagName('orderid');
            my $ill_request = Koha::Illrequests->find( { orderid => $orderid[0]->textContent } );

            if($ill_request){

                my @rpdesk_status = $orderdetail->getChildrenByTagName('status');
                my $local_status = $ill_request->status;
                my $new_local_status = $self->get_status_from_rpdesk_status($rpdesk_status[0]->textContent);

                # Proceed only if status returned from RPDesk differs from the one in Koha
                if( $local_status ne $new_local_status && !$options->{dry_run}){
                    $self->debug_msg('ILL-'.$ill_request->illrequest_id.' with orderID #'.$orderid[0]->textContent.' local status is '.$local_status.' and RPDesk status is '.$rpdesk_status[0]->textContent);

                    # Metadata details to look for in the response
                    my $metadata_elements = {
                        'orderdateutc', 'issn', 'title', 'atitle', 'volume', 'issue', 'pages', 'author', 'date', 'statusdateutc'
                    };
                    # Update metadata details
                    my $metadata_log;
                    foreach my $metadata_element(%{$metadata_elements}) {
                        my @metadata_array = $orderdetail->getChildrenByTagName($metadata_element);
                        $rd->create_illrequestattributes($ill_request, { $metadata_element => $metadata_array[0]->textContent });
                        $rd->create_illrequestattributes($ill_request, { $metadata_element => $metadata_array[0]->textContent },1);
                        $metadata_log .= $metadata_element . ": " . $metadata_array[0]->textContent . "\n";
                        #FIXME: $metadata_array[0]->textContent may come with non-ASCII (?) characters
                    }

                    # In case RPDesk returns some unkown status (or empty), append this to staff notes and don't update status
                    if( $new_local_status eq 'OTHER' ){
                        my $status_msg = $rpdesk_status[0]->textContent ? $rpdesk_status[0]->textContent : 'empty';
                        # Don't append to note if a previous equal one exists
                        if ( index( $ill_request->notesstaff, "Reprints Desk returned status: " . $status_msg ) == -1 ) {
                            $ill_request->append_to_note("Reprints Desk returned status: " . $status_msg . " at " . DateTime->now);
                        }
                        $ill_request->status('ERROR') if $ill_request->status ne 'ERROR';
                    } else {
                        $self->debug_msg('Updating request status');
                        $ill_request->status($new_local_status);
                    }

                    if( $new_local_status eq 'COMP' ){
                        $ill_request->completed(DateTime->now)->store;

                        # Update accessurl for this completed request
                        my $rndId = $ill_request->illrequestattributes->find({
                            illrequest_id => $ill_request->illrequest_id,
                            type          => "rndId"
                        });
                        my $rpdesk_api_www_url = $self->{env} && $self->{env} eq 'prod' ? 'www' : 'wwwstg';
                        $ill_request->accessurl(
                                'https://' . $rpdesk_api_www_url . '.reprintsdesk.com/landing/dl.aspx?o='.$ill_request->orderid.'&r='.$rndId->value
                            )->store;
                    }

                    # Log the update
                    $rd->log_request_outcome({
                        outcome => 'REPRINTS_DESK_REQUEST_ORDER_UPDATED',
                        request => $ill_request,
                        message => $metadata_log
                    });
                } else {
                    $self->debug_msg('No status update for ILL-'.$ill_request->illrequest_id.' with orderID #'.$orderid[0]->textContent.'. Skipping');
                }
            }
        }
    } else {
        $self->debug_msg('GetOrderHistory returned error ' . join '.', map { $_->{message} } @{$body->{errors}});
    }
}

sub get_status_from_rpdesk_status {
    my ( $self, $rpdesk_status ) = @_;

    my $statuses = {
        'Order Complete' => 'COMP',
        'Citation Verification' => 'CIT',
        'Sourcing' => 'SOURCE'
    };
    return $statuses->{$rpdesk_status} if $statuses->{$rpdesk_status};
    return 'OTHER';
}

sub debug_msg {
    my ( $self, $msg ) = @_;
    if ($self->{do_debug} && ref $self->{do_debug} eq 'CODE') {
        &{$self->{do_debug}}($self->{dry_run} ? "DRY RUN: $msg" : $msg);
    }
};

1;