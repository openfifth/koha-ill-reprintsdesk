use Modern::Perl;

# use Test::NoWarnings;
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

use Koha::Plugin::Com::PTFSEurope::ReprintsDesk;
use Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Lib::API;
use Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Processor::GetOrderHistory;

use t::lib::Mocks;
use t::lib::TestBuilder;

my $builder = t::lib::TestBuilder->new;
my $schema  = Koha::Database->new->schema;

subtest 'run() tests' => sub {
    plan tests => 1;

    $schema->storage->txn_begin;

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

    subtest 'Returned User_GetOrderHistoryResult' => sub {

        my $plugin_API = Test::MockModule->new('Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Lib::API');
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

        my $rpdesk_request = $builder->build_sample_ill_request( { 'backend' => 'ReprintsDesk', 'status' => 'READY' } );
        $rpdesk_request->orderid('123456')->store;
        my $attributes = [
            { type => 'doi',  value => 'mydoi' },
            { type => 'issn', value => '123' },
            { type => 'year', value => '1991' },
            { type => 'rndId', value => '54321' },
        ];

        $rpdesk_request->extended_attributes( \@$attributes );

        my $processor = Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Processor::GetOrderHistory->new;

        is( $rpdesk_request->discard_changes->status, 'READY', 'status is READY' );


        $processor->run();
        is( $rpdesk_request->discard_changes->status, 'COMP', 'status is COMP, updated from ReprintsDesk' );

    };
    $schema->storage->txn_rollback;
};
