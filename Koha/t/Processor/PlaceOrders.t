use Modern::Perl;
use Test::More tests => 1;
use Test::MockModule;
use Test::Exception;
use File::Basename qw( dirname );

BEGIN {
    my $plugin_file = dirname(__FILE__) . "/../../..";
    unshift @INC, $plugin_file;
}

{

    package My::DummyResponse;
    sub decoded_content { $_[0]->{_decoded_content} }
    1;
}

use Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Processor::PlaceOrders;
use t::lib::Mocks;
use t::lib::TestBuilder;

my $builder = t::lib::TestBuilder->new;
my $schema  = Koha::Database->new->schema;

subtest 'run() tests' => sub {
    plan tests => 3;

    $schema->storage->txn_begin;

    Koha::ILL::Requests->delete;

    my $plugin_mock = Test::MockModule->new('Koha::Plugin::Com::PTFSEurope::ReprintsDesk');
    $plugin_mock->mock(
        'retrieve_data',
        sub {
            my ( $self, $param ) = @_;
            if ( $param eq 'reprintsdesk_config' ) {
                return '{
                        "password" : "MyPassword",          "price_threshold" : "50", "useremail" : "myuseremail",
                        "username" : "rpdeskaccountemail ", "city" : "City",
                        "email" : "someotheremail",         "zip" : "ZIP COD", "processinginstructions_value_0" : "2",
                        "userfirstname" : "Library",   "statename" : "London", "pricetypeid" : "2", "address1" : "Address1",
                        "lastname" : "Lastname1",      "environment" : "dev",           "processinginstructions" : "1:2",
                        "billingreference" : "123456", "userlastname" : "userlastname", "use_borrower_details" : 0,
                        "firstname" : "Library",       "processinginstructions_id_0" : "1", "phone" : "000 0000 000",
                        "ordertypeid" : "4",           "countrycode" : "GB",                "deliverymethodid" : "5"
                    }';
            }
            return 1;
        }
    );

    my $plugin_API = Test::MockModule->new('Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Lib::API');
    $plugin_API->mock(
        'Order_PlaceOrder2',
        sub {
            my ( $self, $http_request_obj ) = @_;
            return bless {
                _code            => 200,
                _decoded_content =>
                    '{"errors":[], "result":{"Order_PlaceOrder2Result":1, "orderID":"R12345", "rndID":"RND6789"}}',
                _headers => { 'Content-Type' => 'application/json' },
                },
                'My::DummyResponse';
        }
    );

    $plugin_API->mock(
        'User_GetOrderHistory',
        sub {
            my ( $self, $http_request_obj ) = @_;
            return bless {
                _code            => 200,
                _decoded_content =>
                    '{"errors":[],"result":{"User_GetOrderHistoryResult":1,"outputXmlNode":{},"xmlData":{"_":"<xmlData><orders xmlns=\\"\\"><order><orderdetail><orderid>123456<\\/orderid><orderdateutc>10\\/16\\/2025 10:24:00 AM<\\/orderdateutc><issn><![CDATA[14770520]]><\\/issn><title><![CDATA[Organic & Biomolecular Chemistry]]><\\/title><atitle><![CDATA[The impact of lysyl-phosphatidylglycerol on the interaction of daptomycin with model membranes]]><\\/atitle><volume><![CDATA[20]]><\\/volume><issue><![CDATA[47]]><\\/issue><pages><![CDATA[9319-9329]]><\\/pages><author><![CDATA[Moreira Ryan]]><\\/author><date><![CDATA[2022]]><\\/date><status><![CDATA[Order Complete]]><\\/status><substatus><![CDATA[Order Complete]]><\\/substatus><statusdateutc>10\\/16\\/2025 10:24:00 AM<\\/statusdateutc><\\/orderdetail><\\/order><\\/orders><\\/xmlData>","_MIXED_ELEMENT_MODE":"ATTRIBUTES"},"xmlOutput":{}},"xmlData":"<xmlData><orders xmlns=\\"\\"><order><orderdetail><orderid>123456<\\/orderid><orderdateutc>10\\/16\\/2025 10:24:00 AM<\\/orderdateutc><issn><![CDATA[14770520]]><\\/issn><title><![CDATA[Organic & Biomolecular Chemistry]]><\\/title><atitle><![CDATA[The impact of lysyl-phosphatidylglycerol on the interaction of daptomycin with model membranes]]><\\/atitle><volume><![CDATA[20]]><\\/volume><issue><![CDATA[47]]><\\/issue><pages><![CDATA[9319-9329]]><\\/pages><author><![CDATA[Moreira Ryan]]><\\/author><date><![CDATA[2022]]><\\/date><status><![CDATA[Order Complete]]><\\/status><substatus><![CDATA[Order Complete]]><\\/substatus><statusdateutc>10\\/16\\/2025 10:24:00 AM<\\/statusdateutc><\\/orderdetail><\\/order><\\/orders><\\/xmlData>"}',
                _headers => { 'Content-Type' => 'application/json' },
                },
                'My::DummyResponse';
        }
    );

    subtest 'No \'READY\' requests found' => sub {

        throws_ok {
            Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Processor::PlaceOrders->new->run(
                undef,
                { debug => \&debug_msg }
            );
        }
        qr/No 'READY' requests found\. Bailing/, "dies with expected message";
    };

    subtest 'Found 1 \'READY\' request' => sub {

        my $rpdesk_request = $builder->build_sample_ill_request(
            { 'backend' => 'ReprintsDesk', 'status' => 'READY', 'orderid' => undef } );

        my $attributes = [
            { type => 'doi',  value => 'mydoi' },
            { type => 'issn', value => '123' },
            { type => 'year', value => '1991' },
        ];

        $rpdesk_request->extended_attributes( \@$attributes );
        my $processor = Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Processor::PlaceOrders->new;
        my $output;
        {
            local *STDERR;
            open STDERR, '>', \$output;

            $processor->run( undef, { debug => \&debug_msg } );
        }

        like(
            $output,
            qr/Found 1 'READY' requests/,
            "prints expected message to CLI"
        );

        $rpdesk_request->discard_changes;

        # 2. Test status transition
        is( $rpdesk_request->status, 'REQ', 'status is updated to REQ' );

        # 3. Test that orderid field was updated on the request
        is( $rpdesk_request->orderid, 'R12345', 'orderid field updated from API response' );

        # 4. Test that the specific illrequestattributes were stored
        my $rnd_attr = $rpdesk_request->extended_attributes->find( { type => 'rndId' } );
        ok( $rnd_attr && $rnd_attr->value eq 'RND6789', 'rndId attribute correctly created' );
    };

    subtest 'Somehow a request ended up with an empty orderId but an existing orderId extended_attribute' => sub {

        my $rpdesk_request = $builder->build_sample_ill_request(
            { 'backend' => 'ReprintsDesk', 'status' => 'READY', 'orderid' => undef, 'notesstaff' => undef } );

        my $attributes = [
            { type => 'doi',  value => 'mydoi' },
            { type => 'issn', value => '123' },
            { type => 'year', value => '1991' },
            { type => 'orderId', value => 'my_orderId' },
        ];

        $rpdesk_request->extended_attributes( \@$attributes );
        my $processor = Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Processor::PlaceOrders->new;
        my $output;
        {
            local *STDERR;
            open STDERR, '>', \$output;

            $processor->run( undef, { debug => \&debug_msg } );
        }

        like(
            $output,
            qr/Found 1 'READY' requests/,
            "prints expected message to CLI"
        );

        $rpdesk_request->discard_changes;

        # 2. Test status transition
        is( $rpdesk_request->status, 'REQ', 'status is updated to REQ' );

        # 3. Test that orderid field was updated on the request
        is( $rpdesk_request->orderid, 'R12345', 'orderid field updated from API response' );

        # 4. Test that the specific illrequestattributes were stored
        my $rnd_attr = $rpdesk_request->extended_attributes->find( { type => 'rndId' } );
        ok( $rnd_attr && $rnd_attr->value eq 'RND6789', 'rndId attribute correctly created' );

    };

    $schema->storage->txn_rollback;
};

sub debug_msg {
    my ($msg) = @_;

    if ( ref $msg eq 'HASH' ) {
        use Data::Dumper;
        $msg = Dumper $msg;
    }
    print STDERR "$msg\n";
}
