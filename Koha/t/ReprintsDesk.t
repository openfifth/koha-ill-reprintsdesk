use Modern::Perl;

use Test::NoWarnings;
use Test::More tests => 4;
use Test::MockModule;

use File::Basename qw( dirname );

BEGIN {
    my $plugin_file = dirname(__FILE__) . "/../..";
    unshift @INC, $plugin_file;
}

use Koha::Plugin::Com::PTFSEurope::ReprintsDesk;

use Koha::ILL::Request::Logger;
use Koha::ILL::Request;

use t::lib::Mocks;
use t::lib::TestBuilder;

my $builder = t::lib::TestBuilder->new;
my $schema  = Koha::Database->new->schema;

subtest 'migrate() tests' => sub {
    plan tests => 9;

    $schema->storage->txn_begin;

    my $request = $builder->build_sample_ill_request({'orderid'=>'123'});
    is( $request->backend, 'Standard', "Newly created request is Standard" );

    my $attributes = [
        { type => 'title',          value => 'My title' },
        { type => 'article_author', value => 'Henry' }
    ];

    $request->extended_attributes( \@$attributes );

    is(
        $request->extended_attributes->find( { type => 'title' } )->value, get_value( 'title', $attributes ),
        "extended_attributes created correctly"
    );
    is(
        $request->extended_attributes->find( { type => 'article_author' } )->value,
        get_value( 'article_author', $attributes ),
        "extended_attributes created correctly"
    );

    $request->backend_migrate( { illrequest_id => $request->illrequest_id, backend => 'ReprintsDesk' } );
    $request->discard_changes;

    is(
        $request->extended_attributes->find( { type => 'title' } )->value, get_value( 'title', $attributes ),
        "extended_attributes created correctly"
    );
    is(
        $request->extended_attributes->find( { type => 'article_author' } )->value,
        get_value( 'article_author', $attributes ), "extended_attributes created correctly"
    );

    is(
        $request->extended_attributes->find( { type => 'aufirst' } )->value,
        get_value( 'article_author', $attributes ), "article_author correctly mapped to aufirst"
    );
    is( $request->backend, 'ReprintsDesk', "Migrated into ReprintsDesk correctly" );
    is( $request->status,  'NEW',          "Migrated into ReprintsDesk status is 'NEW'" );
    is( $request->orderid, undef,          "Migrated into ReprintsDesk orderId is empty" );

    $schema->storage->txn_rollback;
};

subtest 'create_submission() tests' => sub {
    plan tests => 3;

    $schema->storage->txn_begin;

    t::lib::Mocks::mock_preference( 'ILLOpacUnauthenticatedRequest', 1 );

    my $request = $builder->build_sample_ill_request;
    $request->{_my_backend} = Koha::Plugin::Com::PTFSEurope::ReprintsDesk->new->new_ill_backend(
        {
            config => Koha::ILL::Request->new->_config,
            logger => Koha::ILL::Request::Logger->new
        }
    );

    my $rpdesk_submission = $request->{_my_backend}->create_submission(
        {
            request => $request,
            other   => {
                branchcode                 => $request->branchcode,
                unauthenticated_first_name => 'My first name',
                unauthenticated_last_name  => 'My last name',
                unauthenticated_email      => 'myemail@openfifth.co.uk'
            }
        }
    );

    is( $request->backend, 'ReprintsDesk', "Newly created request is ReprintsDesk" );
    is(
        $request->status, 'UNAUTH',
        "Newly created request lacks borrowernumber and ILLOpacUnauthenticatedRequest is enabled. Must be UNAUTH"
    );

    t::lib::Mocks::mock_preference( 'ILLOpacUnauthenticatedRequest', 0 );
    my $another_submission = $request->{_my_backend}->create_submission(
        {
            request => $request,
            other   => {
                borrowernumber             => $request->borrowernumber,
                branchcode                 => $request->branchcode,
                unauthenticated_first_name => 'My first name',
                unauthenticated_last_name  => 'My last name',
                unauthenticated_email      => 'myemail@openfifth.co.uk'
            }
        }
    );

    is(
        $request->status, 'NEW',
        "Newly created request has borrowernumber and ILLOpacUnauthenticatedRequest is disabled. Must be NEW"
    );

    $schema->storage->txn_rollback;
};

subtest 'status_graph() tests' => sub {
    plan tests => 6;

    $schema->storage->txn_begin;

    my $request = $builder->build_sample_ill_request;
    $request->{_my_backend} = Koha::Plugin::Com::PTFSEurope::ReprintsDesk->new->new_ill_backend(
        {
            config => Koha::ILL::Request->new->_config,
            logger => Koha::ILL::Request::Logger->new
        }
    );

    # STANDBY
    ok(
        ( grep { $_ eq 'MIG' } @{ $request->capabilities->{'STANDBY'}->{next_actions} } ),
        "Next actions for STANDBY contains 'MIG'"
    );

    ok(
        ( grep { $_ eq 'CANCREQ' } @{ $request->capabilities->{'STANDBY'}->{next_actions} } ),
        "Next actions for STANDBY contains 'CANCREQ'"
    );

    # CANCREQ
    ok(
        ( grep { $_ eq 'MIG' } @{ $request->capabilities->{'CANCREQ'}->{next_actions} } ),
        "Next actions for CANCREQ contains 'MIG'"
    );

    # UNAUTH
    ok(
        ( grep { $_ eq 'CANCREQ' } @{ $request->capabilities->{'UNAUTH'}->{next_actions} } ),
        "Next actions for UNAUTH contains 'CANCREQ'"
    );
    ok(
        ( grep { $_ eq 'KILL' } @{ $request->capabilities->{'UNAUTH'}->{next_actions} } ),
        "Next actions for UNAUTH contains 'KILL'"
    );

    # ERROR
    ok(
        ( grep { $_ eq 'CANCREQ' } @{ $request->capabilities->{'ERROR'}->{next_actions} } ),
        "Next actions for ERROR contains 'CANCREQ'"
    );

    $schema->storage->txn_rollback;
};

sub get_value {
    my ( $type, $attributes ) = @_;
    my @values = map { $_->{value} } grep { $_->{type} eq $type } @$attributes;
    return $values[0];
}
