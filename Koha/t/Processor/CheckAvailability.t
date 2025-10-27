use Modern::Perl;

use Test::NoWarnings;
use Test::More tests => 2;
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
use Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Processor::CheckAvailability;

use t::lib::Mocks;
use t::lib::TestBuilder;

my $builder = t::lib::TestBuilder->new;
my $schema  = Koha::Database->new->schema;

subtest 'run() tests' => sub {
    plan tests => 6;

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

    subtest 'No \'NEW\' requests found. Bailing' => sub {

        throws_ok {
            Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Processor::CheckAvailability->new->run(
                undef,
                { debug => \&debug_msg }
            );
        }
        qr/No NEW requests found\. Bailing/, "dies with expected message";
    };

    subtest 'Found 1 \'NEW\' requests that results in unknown copyright charge' => sub {

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
                        '{"errors":[],"result":{"outputXmlNode":{},"xmlData":{},"xmlOutput":{"_":"<xmlOutput><output xmlns=\\"\\"><standardNumber>0007-1323<\\/standardNumber><year>1975<\\/year><totalpages>10<\\/totalpages><pricetypeid>2<\\/pricetypeid><servicecharge>4.00<\\/servicecharge><copyrightcharge>-1.00<\\/copyrightcharge><disclaimer><![CDATA[Dislcaimer]]><\\/disclaimer><\\/output><\\/xmlOutput>","_MIXED_ELEMENT_MODE":"ATTRIBUTES"}},"xmlOutput":"<xmlOutput><output xmlns=\\"\\"><standardNumber>0007-1323<\\/standardNumber><year>1975<\\/year><totalpages>10<\\/totalpages><pricetypeid>2<\\/pricetypeid><servicecharge>4.00<\\/servicecharge><copyrightcharge>-1.00<\\/copyrightcharge><disclaimer><![CDATA[Dislcaimer]]><\\/disclaimer><\\/output><\\/xmlOutput>"}',
                    _headers => { 'Content-Type' => 'application/json' },
                    },
                    'My::DummyResponse';
            }
        );

        my $rpdesk_request = $builder->build_sample_ill_request( { 'backend' => 'ReprintsDesk', 'status' => 'NEW' } );

        my $attributes = [
            { type => 'doi',  value => 'mydoi' },
            { type => 'issn', value => '123' },
            { type => 'year', value => '1991' },
        ];

        $rpdesk_request->extended_attributes( \@$attributes );
        my $processor = Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Processor::CheckAvailability->new;
        my $output;
        {
            local *STDERR;
            open STDERR, '>', \$output;

            $processor->run( undef, { debug => \&debug_msg } );
        }

        like(
            $output,
            qr/Found 1 NEW requests/,
            "prints expected message to CLI"
        );

        is( $rpdesk_request->discard_changes->status, 'STANDBY', 'status is STANDBY because copyright charge unknown' );
        like(
            $rpdesk_request->discard_changes->notesstaff,
            qr/Price may be inaccurate. Copyright charge returned 'unknown'./,
            'Staff notes correctly appended.'
        );
        is( $rpdesk_request->discard_changes->cost, 'Unknown', 'cost is unknown because well it\'s unknown' );

    };

    subtest 'Found 1 \'NEW\' requests that results in known price above price threshold' => sub {

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
                        '{"errors":[],"result":{"outputXmlNode":{},"xmlData":{},"xmlOutput":{"_":"<xmlOutput><output xmlns=\\"\\"><standardNumber>0007-1323<\\/standardNumber><year>1975<\\/year><totalpages>10<\\/totalpages><pricetypeid>2<\\/pricetypeid><servicecharge>4.00<\\/servicecharge><copyrightcharge>52.00<\\/copyrightcharge><disclaimer><![CDATA[Dislcaimer]]><\\/disclaimer><\\/output><\\/xmlOutput>","_MIXED_ELEMENT_MODE":"ATTRIBUTES"}},"xmlOutput":"<xmlOutput><output xmlns=\\"\\"><standardNumber>0007-1323<\\/standardNumber><year>1975<\\/year><totalpages>10<\\/totalpages><pricetypeid>2<\\/pricetypeid><servicecharge>4.00<\\/servicecharge><copyrightcharge>52.00<\\/copyrightcharge><disclaimer><![CDATA[Dislcaimer]]><\\/disclaimer><\\/output><\\/xmlOutput>"}',
                    _headers => { 'Content-Type' => 'application/json' },
                    },
                    'My::DummyResponse';
            }
        );

        my $rpdesk_request = $builder->build_sample_ill_request( { 'backend' => 'ReprintsDesk', 'status' => 'NEW' } );

        my $attributes = [
            { type => 'doi',  value => 'mydoi' },
            { type => 'issn', value => '123' },
            { type => 'year', value => '1991' },
        ];

        $rpdesk_request->extended_attributes( \@$attributes );
        my $processor = Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Processor::CheckAvailability->new;
        my $output;
        {
            local *STDERR;
            open STDERR, '>', \$output;

            $processor->run( undef, { debug => \&debug_msg } );
        }

        like(
            $output,
            qr/Found 1 NEW requests/,
            "prints expected message to CLI"
        );

        is(
            $rpdesk_request->discard_changes->status, 'STANDBY',
            'status is STANDBY because known price is above threshold'
        );
        like(
            $rpdesk_request->discard_changes->notesstaff,
            qr/Price is above configured threshold of '50'. Request is standing by./,
            'Staff notes correctly appended.'
        );
        is( $rpdesk_request->discard_changes->cost, '56', 'cost is known and set accordingly' );

    };

    subtest 'Found 1 \'NEW\' requests that results in known price below price threshold' => sub {

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
                        '{"errors":[],"result":{"outputXmlNode":{},"xmlData":{},"xmlOutput":{"_":"<xmlOutput><output xmlns=\\"\\"><standardNumber>0007-1323<\\/standardNumber><year>1975<\\/year><totalpages>10<\\/totalpages><pricetypeid>2<\\/pricetypeid><servicecharge>4.00<\\/servicecharge><copyrightcharge>12.00<\\/copyrightcharge><disclaimer><![CDATA[Dislcaimer]]><\\/disclaimer><\\/output><\\/xmlOutput>","_MIXED_ELEMENT_MODE":"ATTRIBUTES"}},"xmlOutput":"<xmlOutput><output xmlns=\\"\\"><standardNumber>0007-1323<\\/standardNumber><year>1975<\\/year><totalpages>10<\\/totalpages><pricetypeid>2<\\/pricetypeid><servicecharge>4.00<\\/servicecharge><copyrightcharge>12.00<\\/copyrightcharge><disclaimer><![CDATA[Dislcaimer]]><\\/disclaimer><\\/output><\\/xmlOutput>"}',
                    _headers => { 'Content-Type' => 'application/json' },
                    },
                    'My::DummyResponse';
            }
        );

        my $rpdesk_request = $builder->build_sample_ill_request( { 'backend' => 'ReprintsDesk', 'status' => 'NEW' } );

        my $attributes = [
            { type => 'doi',  value => 'mydoi' },
            { type => 'issn', value => '123' },
            { type => 'year', value => '1991' },
        ];

        $rpdesk_request->extended_attributes( \@$attributes );
        my $processor = Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Processor::CheckAvailability->new;
        my $output;
        {
            local *STDERR;
            open STDERR, '>', \$output;

            $processor->run( undef, { debug => \&debug_msg } );
        }

        like(
            $output,
            qr/Found 1 NEW requests/,
            "prints expected message to CLI"
        );

        is(
            $rpdesk_request->discard_changes->status, 'READY',
            'status is READY because known price is above threshold'
        );
        like(
            $rpdesk_request->discard_changes->notesstaff,
            qr/Price is below or equal to configured threshold of '50'. Request is ready to be placed./,
            'Staff notes correctly appended.'
        );
        is( $rpdesk_request->discard_changes->cost, '16', 'cost is known and set accordingly' );

    };

    subtest 'Found 1 \'NEW\' requests that results in immediatly available request for free' => sub {

        my $plugin_API = Test::MockModule->new('Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Lib::API');
        $plugin_API->mock(
            'ArticleShelf_CheckAvailability',
            sub {
                my ( $self, $http_request_obj ) = @_;
                return bless {
                    _code            => 200,
                    _decoded_content =>
                        '{"errors":[],"outputXmlNode":"<outputXmlNode><output xmlns=\\"\\"><citations><citation><doi><![CDATA[mydoi]]><\\/doi><archiveid><![CDATA[3607110]]><\\/archiveid><\\/citation><\\/citations><\\/output><\\/outputXmlNode>","result":{"ArticleShelf_CheckAvailabilityResult":1,"outputXmlNode":{"_":"<outputXmlNode><output xmlns=\\"\\"><citations><citation><doi><![CDATA[mydoi]]><\\/doi><archiveid><![CDATA[3607110]]><\\/archiveid><\\/citation><\\/citations><\\/output><\\/outputXmlNode>","_MIXED_ELEMENT_MODE":"ATTRIBUTES"},"xmlData":{},"xmlOutput":{}}}',
                    _headers => { 'Content-Type' => 'application/json' },
                    },
                    'My::DummyResponse';
            }
        );

        my $rpdesk_request = $builder->build_sample_ill_request( { 'backend' => 'ReprintsDesk', 'status' => 'NEW' } );

        my $attributes = [
            { type => 'doi',  value => 'mydoi' },
            { type => 'issn', value => '123' },
            { type => 'year', value => '1991' },
        ];

        $rpdesk_request->extended_attributes( \@$attributes );

        my $stderr_output;
        {
            local *STDERR;
            open STDERR, '>', \$stderr_output;

            my $processor = Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Processor::CheckAvailability->new;
            throws_ok {
                $processor->run( undef, { debug => \&debug_msg } );
            }
            qr/All requests are immediately available. Skipping price check step/, "dies with expected message";
        }

        like(
            $stderr_output,
            qr/Found 1 NEW requests in ReprintsDesk backend. Checking availability:/,
            "prints expected message to STDERR"
        );

        is(
            $rpdesk_request->discard_changes->status, 'READY',
            'status is READY because its free'
        );
        like(
            $rpdesk_request->discard_changes->notesstaff,
            qr//,
            'Staff notes correctly not appended.'
        );
        is( $rpdesk_request->discard_changes->cost, '0', 'cost should be 0 for free requests' );

    };

    subtest 'Found 2 \'NEW\' requests that results in 1 immediatly available request for free and 1 above price check' => sub {

        my $plugin_API = Test::MockModule->new('Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Lib::API');
        $plugin_API->mock(
            'ArticleShelf_CheckAvailability',
            sub {
                my ( $self, $http_request_obj ) = @_;
                return bless {
                    _code            => 200,
                    _decoded_content =>
                        '{"errors":[],"outputXmlNode":"<outputXmlNode><output xmlns=\\"\\"><citations><citation><doi><![CDATA[mydoi]]><\\/doi><archiveid><![CDATA[3607110]]><\\/archiveid><\\/citation><\\/citations><\\/output><\\/outputXmlNode>","result":{"ArticleShelf_CheckAvailabilityResult":1,"outputXmlNode":{"_":"<outputXmlNode><output xmlns=\\"\\"><citations><citation><doi><![CDATA[mydoi]]><\\/doi><archiveid><![CDATA[3607110]]><\\/archiveid><\\/citation><\\/citations><\\/output><\\/outputXmlNode>","_MIXED_ELEMENT_MODE":"ATTRIBUTES"},"xmlData":{},"xmlOutput":{}}}',
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
                        '{"errors":[],"result":{"outputXmlNode":{},"xmlData":{},"xmlOutput":{"_":"<xmlOutput><output xmlns=\\"\\"><standardNumber>0007-1323<\\/standardNumber><year>1975<\\/year><totalpages>10<\\/totalpages><pricetypeid>2<\\/pricetypeid><servicecharge>4.00<\\/servicecharge><copyrightcharge>52.00<\\/copyrightcharge><disclaimer><![CDATA[Dislcaimer]]><\\/disclaimer><\\/output><\\/xmlOutput>","_MIXED_ELEMENT_MODE":"ATTRIBUTES"}},"xmlOutput":"<xmlOutput><output xmlns=\\"\\"><standardNumber>0007-1323<\\/standardNumber><year>1975<\\/year><totalpages>10<\\/totalpages><pricetypeid>2<\\/pricetypeid><servicecharge>4.00<\\/servicecharge><copyrightcharge>52.00<\\/copyrightcharge><disclaimer><![CDATA[Dislcaimer]]><\\/disclaimer><\\/output><\\/xmlOutput>"}',
                    _headers => { 'Content-Type' => 'application/json' },
                    },
                    'My::DummyResponse';
            }
        );

        my $rpdesk_request = $builder->build_sample_ill_request( { 'backend' => 'ReprintsDesk', 'status' => 'NEW' } );
        my $rpdesk_request_2 = $builder->build_sample_ill_request( { 'backend' => 'ReprintsDesk', 'status' => 'NEW' } );

        my $attributes = [
            { type => 'doi',  value => 'mydoi' },
            { type => 'issn', value => '123' },
            { type => 'year', value => '1991' },
        ];

        my $attributes_2 = [
            { type => 'doi',  value => 'anotherdoi' },
            { type => 'issn', value => '123' },
            { type => 'year', value => '1991' },
        ];

        $rpdesk_request->extended_attributes( \@$attributes );
        $rpdesk_request_2->extended_attributes( \@$attributes_2 );
        my $processor = Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Processor::CheckAvailability->new;
        my $output;
        {
            local *STDERR;
            open STDERR, '>', \$output;

            $processor->run( undef, { debug => \&debug_msg } );
        }

        my $rpdesk_request_1_id = $rpdesk_request->illrequest_id;
        my $rpdesk_request_2_id = $rpdesk_request_2->illrequest_id;

        like(
            $output,
            qr/Illrequest #$rpdesk_request_1_id - Checking DOI: mydoi/,
            "prints expected message to CLI"
        );

        like(
            $output,
            qr/ILL request #$rpdesk_request_1_id status has been updated to READY: DOI:mydoi is immediately available/,
            "prints expected message to CLI"
        );

        like(
            $output,
            qr/Illrequest #$rpdesk_request_2_id - Checking DOI: anotherdoi/,
            "prints expected message to CLI"
        );

        like(
            $output,
            qr/Price check for request #$rpdesk_request_2_id returned 4.00\$ service charge and 52.00\$ copyright charge for a total of 56\$/,
            "prints expected message to CLI"
        );

        like(
            $output,
            qr/Request #$rpdesk_request_2_id Price is above configured threshold of '50'. Request is standing by./,
            "prints expected message to CLI"
        );

        is(
            $rpdesk_request->discard_changes->status, 'READY',
            'status is READY because its free'
        );
        like(
            $rpdesk_request->discard_changes->notesstaff,
            qr//,
            'Staff notes correctly not appended.'
        );
        is( $rpdesk_request->discard_changes->cost, '0', 'cost should be 0 for free requests' );

        is(
            $rpdesk_request_2->discard_changes->status, 'STANDBY',
            'status is STANDBY because its not free'
        );
        like(
            $rpdesk_request_2->discard_changes->notesstaff,
            qr//,
            'Staff notes correctly not appended.'
        );
        is( $rpdesk_request_2->discard_changes->cost, '56', 'cost should not be free here' );

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
