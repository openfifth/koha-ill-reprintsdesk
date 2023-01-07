package Koha::Illbackends::ReprintsDesk::Lib::API;

# Copyright PTFS Europe 2022
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use strict;
use warnings;

use LWP::UserAgent;
use HTTP::Request;
use JSON qw( encode_json );
use CGI;
use URI;

use Koha::Logger;
use C4::Context;

=head1 NAME

ReprintsDesk - Client interface to ReprintsDesk API plugin (koha-plugin-reprintsdesk)

=cut


sub new {
    my ($class) = @_;

    my $cgi = new CGI;

    my $interface = C4::Context->interface;
    my $url = $interface eq "intranet" ?
        C4::Context->preference('staffClientBaseURL') :
        C4::Context->preference('OPACBaseURL');

    # We need a URL to continue, otherwise we can't make the API call to
    # the ReprintsDesk API plugin
    if (!$url) {
        Koha::Logger->get->warn("Syspref staffClientBaseURL or OPACBaseURL not set!");
        die;
    }

    my $uri = URI->new($url);

    my $self = {
        ua      => LWP::UserAgent->new,
        cgi     => new CGI,
        logger  => Koha::Logger->get({ category => 'Koha.Illbackends.ReprintsDesk.Lib.API' }),
        baseurl => $uri->scheme . "://" . $uri->host . ":" . $uri->port . "/api/v1/contrib/reprintsdesk"
    };

    bless $self, $class;
    return $self;
}

=head3 Order_PlaceOrder2

Make a call to the /Order_PlaceOrder2 API

=cut

sub Order_PlaceOrder2 {
    my ($self, $metadata, $borrowernumber) = @_;

    my $borrower = Koha::Patrons->find( $borrowernumber );

    my @address1_arr = grep { defined && length $_ > 0 } ($borrower->streetnumber, $borrower->address, $borrower->address2);
    my $address1_str = join ", ", @address1_arr;

    # Request including passed metadata
    my $body = {
        orderdetail => $metadata,
        deliveryprofile => {
            firstname   => $borrower->firstname || "",
            lastname    => $borrower->surname || "",
            address1    => $address1_str,
            city        => $borrower->city || "",
            statecode   => $metadata->{statecode} || "",
            statename   => $metadata->{statename} || "",
            zip         => $metadata->{zipcode} || "",
            countrycode => $metadata->{countrycode} || "",
            phone       => $borrower->phone || "",
            fax         => $borrower->fax || "",
            email       => $borrower->email || ""
        }
    };

    my $request = HTTP::Request->new( 'POST', $self->{baseurl} . "/placeorder2" );

    $request->header( "Content-type" => "application/json" );
    $request->content( encode_json($body) );

    return $self->{ua}->request( $request );
}

=head3 Order_GetOrderInfo

Make a call to the Order_GetOrderInfo API

=cut

sub Order_GetOrderInfo {
    my ($self, $request_id) = @_;

    my $body = encode_json({
        orderid => $request_id
    });

    my $request = HTTP::Request->new( 'POST', $self->{baseurl} . "/Order_GetOrderInfo" );

    $request->header( "Content-type" => "application/json" );
    $request->content( $body );

    return $self->{ua}->request( $request );
}

1;
