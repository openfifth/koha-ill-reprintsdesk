package Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Processor::CheckAvailability;

use Modern::Perl;
use JSON qw( decode_json from_json );

use Encode qw( decode_utf8);
use parent qw(Koha::ILL::Request::SupplierUpdateProcessor);
use Koha::Plugin::Com::PTFSEurope::ReprintsDesk;

sub new {
    my ($class) = @_;
    my $self = $class->SUPER::new( 'backend', 'ReprintsDesk', 'CheckAvailability' );
    bless $self, $class;
    return $self;
}

sub run {
    my ( $self, $update, $options, $status ) = @_;

    $self->{do_debug} = $options->{debug};
    $self->{dry_run}  = $options->{dry_run};
    $self->{env}      = $options->{env};

    my $rd = Koha::Plugin::Com::PTFSEurope::ReprintsDesk->new->new_ill_backend( { logger => Koha::ILL::Request::Logger->new } );

    my $plugin = Koha::Plugin::Com::PTFSEurope::ReprintsDesk->new();
    my $config = decode_json( $plugin->retrieve_data("reprintsdesk_config") || {} );

    my $availability_backend                = 'ReprintsDesk';
    my $availability_check_status           = 'NEW';
    my $status_if_available                 = 'READY';
    my $status_if_unavailable_with_price    = 'STANDBY';
    my $status_if_unavailable_without_price = 'ERROR';

    # Get the local ILL requests we want to work with
    # TODO: Get only the first 15 like PlaceOrders? RPDesk has a max of 50 citations allowed
    my $new_requests = Koha::ILL::Requests->search(
        {
            status  => $availability_check_status,
            backend => $availability_backend
        },
        {
            order_by => { -asc => 'updated' },
            rows     => 30
        }
    );

    die("No $availability_check_status requests found. Bailing") unless $new_requests->count;

    $self->debug_msg(
        sprintf(
            "Found %d %s requests in %s backend. Checking availability:",
            $new_requests->count, $availability_check_status, $availability_backend
        )
    );

    my @ids_to_check;

    # Iterate on local 'NEW' requests, grab their DOI/PMID and store to @ids_to_check
    while ( my $ill_request = $new_requests->next ) {

        # Handle DOI/PMID for availability check
        my @doi_map = map { $_->{type} eq 'doi' ? $_ : () } @{ $ill_request->extended_attributes->unblessed };
        my $doi     = $doi_map[0];

        my @pubmedid_map = map { $_->{type} eq 'pubmedid' ? $_ : () } @{ $ill_request->extended_attributes->unblessed };
        my $pubmedid     = $pubmedid_map[0];

        # Handle standardnumber for price check
        my @issn = map { $_->{type} eq 'issn' ? $_ : () } @{ $ill_request->extended_attributes->unblessed };
        my $issn = $issn[0];

        my @isbn = map { $_->{type} eq 'isbn' ? $_ : () } @{ $ill_request->extended_attributes->unblessed };
        my $isbn = $isbn[0];

        my $standardnumber = $issn ? $issn->{value} : $isbn ? $isbn->{value} : undef;

        # Handle year for price check
        my @year = map { $_->{type} eq 'year' ? $_ : () } @{ $ill_request->extended_attributes->unblessed };
        my $year = $year[0];

        my @date = map { $_->{type} eq 'date' ? $_ : () } @{ $ill_request->extended_attributes->unblessed };
        my $date = $date[0];

        $year = $year // $date;

        my $id_to_push = {
            $doi               ? ( doi  => $doi->{value} )      : (),
            $pubmedid && !$doi ? ( pmid => $pubmedid->{value} ) : (),
            illrequest_id  => $ill_request->illrequest_id,
            available      => 0,
            standardnumber => $standardnumber,
            year           => $year ? $year->{value} : undef
        };

        push( @ids_to_check, $id_to_push ? $id_to_push : () );

        $self->debug_msg(
                  "Illrequest #"
                . $ill_request->illrequest_id . " - "
                . (
                  $id_to_push->{doi}  ? "Checking DOI: " . $id_to_push->{doi}
                : $id_to_push->{pmid} ? "Checking PMID: " . $id_to_push->{pmid}
                :                       "Does not have a DOI or PubmedID. Skipping."
                )
        );
    }

    die("No '$availability_check_status' requests have the required DOI or PubmedID fields. Bailing")
        unless scalar @ids_to_check;

    # ArticleShelf_CheckAvailability API call - Send relevant part of @ids_to_check to the webservice
    my @ids_to_webservice =
        map ( $_->{doi} ? { doi => $_->{doi} } : $_->{pmid} ? { pmid => $_->{pmid} } : (), @ids_to_check );
    my $response = $rd->{_api}->ArticleShelf_CheckAvailability( \@ids_to_webservice );
    my $body     = from_json( $response->decoded_content );
    die( 'ArticleShelf_CheckAvailability returned error ' . join '.', map { $_->{message} } @{ $body->{errors} } )
        unless ( scalar @{ $body->{errors} } == 0 && $body->{result}->{ArticleShelf_CheckAvailabilityResult} == 1 );

    my $dom       = XML::LibXML->load_xml( string => decode_utf8( $body->{outputXmlNode} ) );
    my @citations = $dom->findnodes('/outputXmlNode/output/citations/*');
    $self->debug_msg(
        sprintf(
            "%s returned %d available citations. Checking availability:", $availability_backend, scalar @citations,
        )
    );

    # Iterate on returned citations
    foreach my $citation (@citations) {

        my @doi_el = $citation->getChildrenByTagName('doi');
        my $doi    = $doi_el[0]->textContent if $doi_el[0];

        my @pmid_el = $citation->getChildrenByTagName('pmid');
        my $pmid    = $pmid_el[0]->textContent if $pmid_el[0];

        # Set ->{available} = 1 if DOI/PMID returned by ArticleShelf_CheckAvailability
        # exists within our local $ids_to_check
        foreach my $id_to_check (@ids_to_check) {
            if (   $id_to_check->{doi} && $doi && lc $id_to_check->{doi} eq lc $doi
                || $id_to_check->{pmid} && $pmid && $id_to_check->{pmid} eq $pmid )
            {
                $id_to_check->{available} = 1;
            }
        }
    }
    my @available_ids = map( $_->{available} ? $_ : (), @ids_to_check );

    # Update available requests locally
    foreach my $id_to_update (@available_ids) {
        my $request_to_update = Koha::ILL::Requests->find( $id_to_update->{illrequest_id} );

        if ( $request_to_update->status eq $availability_check_status ) {
            $request_to_update->status($status_if_available)->store if !$options->{dry_run};
            $request_to_update->cost(0)->store if !$options->{dry_run};

            my $id_log_info = $id_to_update->{doi} ? "DOI:" . $id_to_update->{doi} : "PMID:" . $id_to_update->{pmid};
            $self->debug_msg(
                sprintf(
                    "ILL request #%d status has been updated to %s: %s is immediately available",
                    $id_to_update->{illrequest_id}, $status_if_available, $id_log_info
                )
            );
        }
    }

    # Check price for unavailable ids, if there are any
    my @unavailable_ids = map( !$_->{available} ? $_ : (), @ids_to_check );

    die("All requests are immediately available. Skipping price check step") unless scalar @unavailable_ids;

    $self->debug_msg(
        "There are " . scalar @unavailable_ids . " not immediately available citations. Checking price:" );

    # Iterate on unavailable requests locally
    foreach my $unavailable_id (@unavailable_ids) {

        my $unavailable_request_to_update = Koha::ILL::Requests->find( $unavailable_id->{illrequest_id} );

        # Bail if we can't price check
        if ( !$unavailable_id->{standardnumber} || !$unavailable_id->{year} || $unavailable_id->{year} !~ /^\d{4}$/) {
            $self->debug_msg(
                sprintf(
                    "Request #%d does not have a ISSN/ISBN or year. Skipping this price check.",
                    $unavailable_id->{illrequest_id}
                )
            );
            my $note_instructions =
                "Please correct this and mark the request as 'NEW' for a new ReprintsDesk availability and price check.";
            $unavailable_request_to_update->append_to_note(
                "Request is missing 'ISSN' or 'ISBN' required for price check." . $note_instructions )
                unless $unavailable_id->{standardnumber};
            $unavailable_request_to_update->append_to_note(
                "Request is missing 'year' required for price check." . $note_instructions )
                unless $unavailable_id->{year};
            $unavailable_request_to_update->append_to_note(
                "Request 'year' is not in expected format (YYYY) for price check. " . $note_instructions )
                unless $unavailable_id->{year} && $unavailable_id->{year} =~ /^\d{4}$/;
            $unavailable_request_to_update->status($status_if_unavailable_without_price);
            next;
        }

        # Order_GetPriceEstimate2 API call
        my $response = $rd->{_api}->Order_GetPriceEstimate2(
            { standardNumber => $unavailable_id->{standardnumber}, year => $unavailable_id->{year} } );
        my $body = from_json( $response->decoded_content );

        #TODO: Add error handling for Order_GetPriceEstimate2 here
        my $dom = XML::LibXML->load_xml( string => decode_utf8( $body->{xmlOutput} ) );

        my @servicecharge_el = $dom->findnodes('/xmlOutput/output/servicecharge');
        my $servicecharge    = $servicecharge_el[0]->textContent if $servicecharge_el[0];

        my @copyrightcharge         = $dom->findnodes('/xmlOutput/output/copyrightcharge');
        my $copyrightcharge         = $copyrightcharge[0]->textContent if $copyrightcharge[0];
        my $unknown_copyrightcharge = $copyrightcharge eq '-1.00' ? 1 : 0;

        my $totalcharge = $unknown_copyrightcharge ? $servicecharge : $servicecharge + $copyrightcharge;

        $self->debug_msg(
            sprintf(
                "Price check for request #%d returned %s\$ service charge and %s\$ copyright charge for a total of %s\$",
                $unavailable_id->{illrequest_id}, $servicecharge, $copyrightcharge, $totalcharge
            )
        );

        if ( $totalcharge <= $config->{price_threshold} && !$unknown_copyrightcharge) {
            $unavailable_request_to_update->status($status_if_available)->store;
            my $below_message = sprintf(
                "Price is below or equal to configured threshold of '%s'. Request is ready to be placed.",
                $config->{price_threshold}
            );
            $unavailable_request_to_update->append_to_note($below_message);
            $self->debug_msg( "Request #" . $unavailable_id->{illrequest_id} . " " . $below_message );
        } else {
            $unavailable_request_to_update->status($status_if_unavailable_with_price)->store;
            my $above_message = sprintf(
                "Price is above configured threshold of '%s'. Request is standing by.",
                $config->{price_threshold}
            );
            $unavailable_request_to_update->append_to_note($above_message);
            $self->debug_msg( "Request #" . $unavailable_id->{illrequest_id} . " " . $above_message );
        }

        $unavailable_request_to_update->cost($totalcharge)->store;
        $unavailable_request_to_update->append_to_note("Price is in USD currency.");
        $unavailable_request_to_update->append_to_note("Price may be inaccurate. Copyright charge returned 'unknown'.")
            if $unknown_copyrightcharge;
    }
}

sub debug_msg {
    my ( $self, $msg ) = @_;
    if ( $self->{do_debug} && ref $self->{do_debug} eq 'CODE' ) {
        &{ $self->{do_debug} }( $self->{dry_run} ? "DRY RUN: $msg" : $msg );
    }
}

1;
