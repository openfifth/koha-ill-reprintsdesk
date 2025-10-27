use Modern::Perl;

use Test::NoWarnings;
use Test::More tests => 2;
use Test::MockModule;

use File::Basename qw( dirname );

BEGIN {
    my $plugin_file = dirname(__FILE__) . "/../..";
    unshift @INC, $plugin_file;
}

use Koha::Plugin::Com::PTFSEurope::ReprintsDesk;

use t::lib::Mocks;
use t::lib::TestBuilder;

my $builder = t::lib::TestBuilder->new;
my $schema  = Koha::Database->new->schema;

subtest 'migrate() tests' => sub {
    plan tests => 8;

    $schema->storage->txn_begin;

    my $request = $builder->build_sample_ill_request();
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

    $schema->storage->txn_rollback;
};

sub get_value {
    my ( $type, $attributes ) = @_;
    my @values = map { $_->{value} } grep { $_->{type} eq $type } @$attributes;
    return $values[0];
}
