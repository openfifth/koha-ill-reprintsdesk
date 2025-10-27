use Modern::Perl;

use Test::NoWarnings;
use Test::More tests => 2;
use Test::Mojo;
use Test::MockModule;

use File::Basename qw( dirname );
use MIME::Base64   qw( encode_base64 );

BEGIN {
    my $plugin_file = dirname(__FILE__) . "/../..";
    unshift @INC, $plugin_file;
}

{

    package My::DummyResponse;
    sub decoded_content { $_[0]->{_decoded_content} }
    1;
}

use Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Api;

use t::lib::Mocks;
use t::lib::TestBuilder;

my $builder = t::lib::TestBuilder->new;
my $schema  = Koha::Database->new->schema;

my $t = Test::Mojo->new('Koha::REST::V1');
t::lib::Mocks::mock_preference( 'RESTBasicAuth', 1 );

subtest 'Backend_Availability() tests' => sub {

    plan tests => 6;

    $schema->storage->txn_begin;

    $schema->storage->dbh->do( "DELETE FROM plugin_data WHERE plugin_key = ?", undef, 'reprintsdesk_config' );

    my $librarian = $builder->build_object(
        {
            class => 'Koha::Patrons',
            value => { flags => 2**28 }
        }
    );
    my $password = 'thePassword123';
    $librarian->set_password( { password => $password, skip_validation => 1 } );
    my $userid = $librarian->userid;

    subtest 'configuration not ok (red)' => sub {

        $t->get_ok( "//$userid:$password@/api/v1/contrib/reprintsdesk/ill_backend_availability_reprintsdesk?metadata="
                . encode_base64('{ "cardnumber" : "42", "title" : "hello" }') )->status_is(400)
            ->json_is( { error => "Plugin configuration is empty." } );
    };

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

    subtest 'ArticleShelf_CheckAvailability returned error (red)' => sub {

        my $plugin_API = Test::MockModule->new('Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Lib::API');
        $plugin_API->mock(
            'ArticleShelf_CheckAvailability',
            sub {
                my ( $self, $http_request_obj ) = @_;
                return bless {
                    _code            => 200,
                    _decoded_content =>
                        '{"errors":[{"message": "this is an error"}],"outputXmlNode":"<outputXmlNode><output xmlns=\\"\\"><citations\\/><\\/output><\\/outputXmlNode>","result":{"ArticleShelf_CheckAvailabilityResult":1,"outputXmlNode":{"_":"<outputXmlNode><output xmlns=\\"\\"><citations\\/><\\/output><\\/outputXmlNode>","_MIXED_ELEMENT_MODE":"ATTRIBUTES"},"xmlData":{},"xmlOutput":{}}}',
                    _headers => { 'Content-Type' => 'application/json' },
                    },
                    'My::DummyResponse';
            }
        );

        $t->get_ok(
            "//$userid:$password@/api/v1/contrib/reprintsdesk/ill_backend_availability_reprintsdesk?metadata="
                . encode_base64('{"cardnumber":"42","title":"hello", "doi":"10.1016/j.brachy.2014.11.007"}') )
            ->status_is(400)->json_is( { error => 'ArticleShelf_CheckAvailability returned error this is an error' } );
    };

    subtest 'Missing ISSN/ISBN or year for price check (red)' => sub {

        my $plugin_API = Test::MockModule->new('Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Lib::API');
        $plugin_API->mock(
            'ArticleShelf_CheckAvailability',
            sub {
                my ( $self, $http_request_obj ) = @_;
                return bless {
                    _code            => 200,
                    _decoded_content =>
                        '{"errors":[],"outputXmlNode":"<outputXmlNode><output xmlns=\\"\\"><citations\\/><\\/output><\\/outputXmlNode>","result":{"ArticleShelf_CheckAvailabilityResult":1,"outputXmlNode":{"_":"<outputXmlNode><output xmlns=\\"\\"><citations\\/><\\/output><\\/outputXmlNode>","_MIXED_ELEMENT_MODE":"ATTRIBUTES"},"xmlData":{},"xmlOutput":{}}}',
                    _headers => { 'Content-Type' => 'application/json' },
                    },
                    'My::DummyResponse';
            }
        );

        $t->get_ok(
            "//$userid:$password@/api/v1/contrib/reprintsdesk/ill_backend_availability_reprintsdesk?metadata="
                . encode_base64('{"cardnumber":"42","title":"hello", "doi":"10.1016/j.brachy.2014.11.007"}') )
            ->status_is(404)
            ->json_is( { error => 'Article not immediately available. Missing ISSN/ISBN or year for price check.' } );
    };

    subtest 'Available with price above threshold (green)' => sub {

        my $plugin_API = Test::MockModule->new('Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Lib::API');
        $plugin_API->mock(
            'ArticleShelf_CheckAvailability',
            sub {
                my ( $self, $http_request_obj ) = @_;
                return bless {
                    _code            => 200,
                    _decoded_content =>
                        '{"errors":[],"outputXmlNode":"<outputXmlNode><output xmlns=\\"\\"><citations\\/><\\/output><\\/outputXmlNode>","result":{"ArticleShelf_CheckAvailabilityResult":1,"outputXmlNode":{"_":"<outputXmlNode><output xmlns=\\"\\"><citations\\/><\\/output><\\/outputXmlNode>","_MIXED_ELEMENT_MODE":"ATTRIBUTES"},"xmlData":{},"xmlOutput":{}}}',
                    _headers => { 'Content-Type' => 'application/json' },
                    },
                    'My::DummyResponse';
            }
        );

        $plugin_API->mock(
            'Order_GetPriceEstimate2',
            sub {
                my ( $self, $http_request_obj ) = @_;
                return bless {
                    _code            => 200,
                    _decoded_content =>
                        '{"errors":[],"result":{"outputXmlNode":{},"xmlData":{},"xmlOutput":{"_":"<xmlOutput><output xmlns=\\"\\"><standardNumber>0007-1323<\\/standardNumber><year>1975<\\/year><totalpages>10<\\/totalpages><pricetypeid>2<\\/pricetypeid><servicecharge>4.00<\\/servicecharge><copyrightcharge>58.00<\\/copyrightcharge><disclaimer><![CDATA[Dislcaimer]]><\\/disclaimer><\\/output><\\/xmlOutput>","_MIXED_ELEMENT_MODE":"ATTRIBUTES"}},"xmlOutput":"<xmlOutput><output xmlns=\\"\\"><standardNumber>0007-1323<\\/standardNumber><year>1975<\\/year><totalpages>10<\\/totalpages><pricetypeid>2<\\/pricetypeid><servicecharge>4.00<\\/servicecharge><copyrightcharge>58.00<\\/copyrightcharge><disclaimer><![CDATA[Dislcaimer]]><\\/disclaimer><\\/output><\\/xmlOutput>"}',
                    _headers => { 'Content-Type' => 'application/json' },
                    },
                    'My::DummyResponse';
            }
        );

        $t->get_ok(
            "//$userid:$password@/api/v1/contrib/reprintsdesk/ill_backend_availability_reprintsdesk?metadata="
                . encode_base64(
                '{"cardnumber":"42","title":"hello", "issn":"someissn", "year":"1999", "doi":"10.1016/j.brachy.2014.11.007"}'
                )
        )->status_is(200)->json_is(
            {
                success =>
                    'Attention: Price of 62$ is above the configured threshold of 50$. Request will be put on \'Standby\''
            }
        );
    };

    subtest 'Available with price under threshold (green)' => sub {

        my $plugin_API = Test::MockModule->new('Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Lib::API');
        $plugin_API->mock(
            'ArticleShelf_CheckAvailability',
            sub {
                my ( $self, $http_request_obj ) = @_;
                return bless {
                    _code            => 200,
                    _decoded_content =>
                        '{"errors":[],"outputXmlNode":"<outputXmlNode><output xmlns=\\"\\"><citations\\/><\\/output><\\/outputXmlNode>","result":{"ArticleShelf_CheckAvailabilityResult":1,"outputXmlNode":{"_":"<outputXmlNode><output xmlns=\\"\\"><citations\\/><\\/output><\\/outputXmlNode>","_MIXED_ELEMENT_MODE":"ATTRIBUTES"},"xmlData":{},"xmlOutput":{}}}',
                    _headers => { 'Content-Type' => 'application/json' },
                    },
                    'My::DummyResponse';
            }
        );

        $plugin_API->mock(
            'Order_GetPriceEstimate2',
            sub {
                my ( $self, $http_request_obj ) = @_;
                return bless {
                    _code            => 200,
                    _decoded_content =>
                        '{"errors":[],"result":{"outputXmlNode":{},"xmlData":{},"xmlOutput":{"_":"<xmlOutput><output xmlns=\\"\\"><standardNumber>0007-1323<\\/standardNumber><year>1975<\\/year><totalpages>10<\\/totalpages><pricetypeid>2<\\/pricetypeid><servicecharge>4.00<\\/servicecharge><copyrightcharge>28.00<\\/copyrightcharge><disclaimer><![CDATA[Dislcaimer]]><\\/disclaimer><\\/output><\\/xmlOutput>","_MIXED_ELEMENT_MODE":"ATTRIBUTES"}},"xmlOutput":"<xmlOutput><output xmlns=\\"\\"><standardNumber>0007-1323<\\/standardNumber><year>1975<\\/year><totalpages>10<\\/totalpages><pricetypeid>2<\\/pricetypeid><servicecharge>4.00<\\/servicecharge><copyrightcharge>28.00<\\/copyrightcharge><disclaimer><![CDATA[Dislcaimer]]><\\/disclaimer><\\/output><\\/xmlOutput>"}',
                    _headers => { 'Content-Type' => 'application/json' },
                    },
                    'My::DummyResponse';
            }
        );

        $t->get_ok(
            "//$userid:$password@/api/v1/contrib/reprintsdesk/ill_backend_availability_reprintsdesk?metadata="
                . encode_base64(
                '{"cardnumber":"42","title":"hello", "issn":"someissn", "year":"1999", "doi":"10.1016/j.brachy.2014.11.007"}'
                )
        )->status_is(200)
            ->json_is(
            { success => 'Price of 32$ is below or equal to the configured threshold of 50$. Request can be placed.' }
            );
    };

    subtest 'Immediately available (green)' => sub {

        my $plugin_API = Test::MockModule->new('Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Lib::API');
        $plugin_API->mock(
            'ArticleShelf_CheckAvailability',
            sub {
                my ( $self, $http_request_obj ) = @_;
                return bless {
                    _code            => 200,
                    _decoded_content =>
                        '{"errors":[],"outputXmlNode":"<outputXmlNode><output xmlns=\\"\\"><citations><citation><doi><![CDATA[10.1016\\/j.brachy.2014.11.007]]><\\/doi><archiveid><![CDATA[3607110]]><\\/archiveid><\\/citation><\\/citations><\\/output><\\/outputXmlNode>","result":{"ArticleShelf_CheckAvailabilityResult":1,"outputXmlNode":{"_":"<outputXmlNode><output xmlns=\\"\\"><citations><citation><doi><![CDATA[10.1016\\/j.brachy.2014.11.007]]><\\/doi><archiveid><![CDATA[3607110]]><\\/archiveid><\\/citation><\\/citations><\\/output><\\/outputXmlNode>","_MIXED_ELEMENT_MODE":"ATTRIBUTES"},"xmlData":{},"xmlOutput":{}}}',
                    _headers => { 'Content-Type' => 'application/json' },
                    },
                    'My::DummyResponse';
            }
        );

        $t->get_ok(
            "//$userid:$password@/api/v1/contrib/reprintsdesk/ill_backend_availability_reprintsdesk?metadata="
                . encode_base64('{"cardnumber":"42","title":"hello", "doi":"10.1016/j.brachy.2014.11.007"}') )
            ->status_is(200)->json_is( { success => 'Article is immediately available' } );
    };

    $schema->storage->txn_rollback;
};
