package Koha::Plugin::Com::PTFSEurope::ReprintsDesk;

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

use Modern::Perl;
use strict;
use warnings;

use base            qw(Koha::Plugins::Base);
use Koha::DateUtils qw( dt_from_string );

use File::Basename qw( dirname );
use CGI;

use JSON           qw( encode_json decode_json to_json from_json );
use File::Basename qw( dirname );
use C4::Installer;

use Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Lib::API;
use Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Processor::PlaceOrders;
use Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Processor::GetOrderHistory;
use Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Processor::CheckAvailability;
use Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Processor::EnqueueNotices;
use Koha::Libraries;
use Koha::Patrons;

our $VERSION = "2.0.0";

our $metadata = {
    name            => 'ReprintsDesk',
    author          => 'PTFS-Europe',
    date_authored   => '2022-04-26',
    date_updated    => "2023-12-13",
    minimum_version => '24.05.00.000',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'This plugin is a ReprintsDesk ILL backend and provides Koha API routes enabling access to the Reprints Desk API'
};

sub ill_backend {
    my ( $class, $args ) = @_;
    return 'ReprintsDesk';
}

sub name {
    return 'ReprintsDesk';
}

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    $self->{config} = decode_json( $self->retrieve_data('reprintsdesk_config') || '{}' );

    return $self;
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );
        my $config   = $self->{config};

        # Prepare processing instructions if necessary
        my @processinginstructions = ();
        if ( $config->{processinginstructions} ) {
            my @pairs = split '_', $config->{processinginstructions};
            foreach my $pair (@pairs) {
                my ( $key, $value ) = split ":", $pair;
                push @processinginstructions, { $key => $value };
            }
        }

        # Prepare customer references if necessary
        my @customerreferences = ();
        if ( $config->{customerreferences} ) {
            my @pairs = split '_', $config->{customerreferences};
            foreach my $pair (@pairs) {
                my ( $key, $value ) = split ":", $pair;
                push @customerreferences, { $key => $value };
            }
        }

        $template->param(
            config                      => $self->{config},
            processinginstructions      => \@processinginstructions,
            processinginstructions_size => scalar @processinginstructions,
            customerreferences          => \@customerreferences,
            customerreferences_size     => scalar @customerreferences,
            cwd                         => dirname(__FILE__)
        );
        $self->output_html( $template->output() );
    } else {
        my %blacklist = ( 'save' => 1, 'class' => 1, 'method' => 1 );
        my $hashed    = { map { $_ => ( scalar $cgi->param($_) )[0] } $cgi->param };
        my $p         = {};

        my $processinginstructions = {};
        foreach my $key ( keys %{$hashed} ) {
            if ( !exists $blacklist{$key} && $key !~ /^processinginstructions/ ) {
                $p->{$key} = $hashed->{$key};
            }

            # Create a hash with key and value pairs together
            # Keys are the index of the instructions, so we can keep
            # them in order, values are concatenated instruction IDs and values
            if (   $key =~ /^processinginstructions_id_(\d+)$/
                && length $hashed->{"processinginstructions_id_$1"} > 0
                && length $hashed->{"processinginstructions_value_$1"} > 0 )
            {
                $processinginstructions->{$1} =
                    $hashed->{"processinginstructions_id_$1"} . ":" . $hashed->{"processinginstructions_value_$1"};
            }
        }

        # If we have any processing instructions to store, add them to our hash
        # Note we sort the keys here so they will remain in a predictable order
        my @processing_keys = sort keys %{$processinginstructions};
        if ( scalar @processing_keys > 0 ) {
            my @processing_pairs = ();
            foreach my $processing_key (@processing_keys) {
                push @processing_pairs, $processinginstructions->{$processing_key};
            }
            $p->{processinginstructions} = join "_", @processing_pairs;
        }

        my $customerreferences = {};
        foreach my $key ( keys %{$hashed} ) {
            if ( !exists $blacklist{$key} && $key !~ /^customerreferences/ ) {
                $p->{$key} = $hashed->{$key};
            }

            # Create a hash with key and value pairs together
            # Keys are the index of the references, so we can keep
            # them in order, values are concatenated references IDs and values
            if (   $key =~ /^customerreferences_id_(\d+)$/
                && length $hashed->{"customerreferences_id_$1"} > 0
                && length $hashed->{"customerreferences_value_$1"} > 0 )
            {
                $customerreferences->{$1} =
                    $hashed->{"customerreferences_id_$1"} . ":" . $hashed->{"customerreferences_value_$1"};
            }
        }

        $p->{use_borrower_details} =
            ( exists $hashed->{use_borrower_details} ) ? 1 : 0;

        # If we have any customer references to store, add them to our hash
        # Note we sort the keys here so they will remain in a predictable order
        my @references_keys = sort keys %{$customerreferences};
        if ( scalar @references_keys > 0 ) {
            my @references_pairs = ();
            foreach my $references_key (@references_keys) {
                push @references_pairs, $customerreferences->{$references_key};
            }
            $p->{customerreferences} = join "_", @references_pairs;
        }

        $self->store_data( { reprintsdesk_config => scalar encode_json($p) } );
        print $cgi->redirect(
            -url => '/cgi-bin/koha/plugins/run.pl?class=Koha::Plugin::Com::PTFSEurope::ReprintsDesk&method=configure' );
        exit;
    }
}

sub api_routes {
    my ( $self, $args ) = @_;

    my $spec_str = $self->mbf_read('openapi.json');
    my $spec     = decode_json($spec_str);

    return $spec;
}

sub api_namespace {
    my ($self) = @_;

    return 'reprintsdesk';
}

sub install() {
    return 1;
}

sub upgrade {
    my ( $self, $args ) = @_;

    my $dt = dt_from_string();
    $self->store_data( { last_upgraded => $dt->ymd('-') . ' ' . $dt->hms(':') } );

    return 1;
}

sub uninstall() {
    return 1;
}

=head2 ILL availability methods

=head3 availability_check_info

Utilized if the AutoILLBackend sys pref is enabled

=cut

sub availability_check_info {
    my ( $self, $params ) = @_;

    my $endpoint = '/api/v1/contrib/' . $self->api_namespace . '/ill_backend_availability_reprintsdesk?metadata=';

    return {
        endpoint         => $endpoint,
        name             => $metadata->{name},
    };
}

=head2 ILL backend methods

=head3 new_ill_backend

Required method utilized by I<Koha::ILL::Request> load_backend

=cut

sub new_ill_backend {
    my ( $self, $params ) = @_;

    my $api        = Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Lib::API->new($VERSION);
    my $log_tt_dir = dirname(__FILE__) . '/'. name() .'/intra-includes/log/';

    $self->{_api}      = $api;
    $self->{templates} = {
        'REPRINTS_DESK_MIGRATE_IN'            => $log_tt_dir . 'reprints_desk_migrate_in.tt',
        'REPRINTS_DESK_REQUEST_SUCCEEDED'     => $log_tt_dir . 'reprints_desk_request_succeeded.tt',
        'REPRINTS_DESK_REQUEST_ORDER_UPDATED' => $log_tt_dir . 'reprints_desk_request_order_updated.tt',
        'REPRINTS_DESK_REQUEST_FAILED'        => $log_tt_dir . 'reprints_desk_request_failed.tt'
    };
    $self->{_logger}                 = $params->{logger} if ( $params->{logger} );
    $self->{backend_wide_processors} = [
        Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Processor::PlaceOrders->new,
        Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Processor::GetOrderHistory->new,
        Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Processor::CheckAvailability->new,
        Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Processor::EnqueueNotices->new
    ];

    return $self;
}

=head3 create

Handle the "create" flow

=cut

sub create {
    my ( $self, $params ) = @_;

    my $other = $params->{other};
    my $stage = $other->{stage};

    my $response = {
        cwd            => dirname(__FILE__),
        backend        => $self->name,
        method         => "create",
        stage          => $stage,
        branchcode     => $other->{branchcode},
        cardnumber     => $other->{cardnumber},
        status         => "",
        message        => "",
        error          => 0,
        field_map      => $self->fieldmap_sorted,
        field_map_json => to_json( $self->fieldmap() )
    };

    # Check for borrowernumber, but only if we're not receiving an OpenURL
    if ( !$other->{openurl}
        && ( !$other->{borrowernumber} && defined( $other->{cardnumber} ) ) )
    {
        $response->{cardnumber} = $other->{cardnumber};

        # 'cardnumber' here could also be a surname (or in the case of
        # search it will be a borrowernumber).
        my ( $brw_count, $brw ) =
            _validate_borrower( $other->{'cardnumber'}, $stage );

        if ( $brw_count == 0 ) {
            $response->{status} = "invalid_borrower";
            $response->{value}  = $params;
            $response->{stage}  = "init";
            $response->{error}  = 1;
            return $response;
        } elsif ( $brw_count > 1 ) {

            # We must select a specific borrower out of our options.
            $params->{brw}     = $brw;
            $response->{value} = $params;
            $response->{stage} = "borrowers";
            $response->{error} = 0;
            return $response;
        } else {
            $other->{borrowernumber} = $brw->borrowernumber;
        }

        $self->{borrower} = $brw;
    }

    # Initiate process
    if ( !$stage || $stage eq 'init' ) {

        # First thing we want to do, is check if we're receiving
        # an OpenURL and transform it into something we can
        # understand
        if ( $other->{openurl} ) {

            # We only want to transform once
            delete $other->{openurl};
            $params = _openurl_to_reprints_desk($params);
        }

        # Pass the map of form fields in forms that can be used by TT
        # and JS
        $response->{field_map}      = $self->fieldmap_sorted;
        $response->{field_map_json} = to_json( $self->fieldmap() );

        # We just need to request the snippet that builds the Creation
        # interface.
        $response->{stage} = 'init';
        $response->{value} = $params;
        return $response;
    }

    # Validate form and perform search if valid
    elsif ( $stage eq 'validate' || $stage eq 'form' ) {

        if ( _fail( $other->{'branchcode'} ) ) {

            # Pass the map of form fields in forms that can be used by TT
            # and JS
            $response->{field_map}      = $self->fieldmap_sorted;
            $response->{field_map_json} = to_json( $self->fieldmap() );
            $response->{status}         = "missing_branch";
            $response->{error}          = 1;
            $response->{stage}          = 'init';
            $response->{value}          = $params;
            return $response;
        } elsif ( !Koha::Libraries->find( $other->{'branchcode'} ) ) {

            # Pass the map of form fields in forms that can be used by TT
            # and JS
            $response->{field_map}      = $self->fieldmap_sorted;
            $response->{field_map_json} = to_json( $self->fieldmap() );
            $response->{status}         = "invalid_branch";
            $response->{error}          = 1;
            $response->{stage}          = 'init';
            $response->{value}          = $params;
            return $response;
        } elsif ( !$self->_validate_metadata($other) ) {
            $response->{field_map}      = $self->fieldmap_sorted;
            $response->{field_map_json} = to_json( $self->fieldmap() );
            $response->{status}         = "invalid_metadata";
            $response->{error}          = 1;
            $response->{stage}          = 'init';
            $response->{value}          = $params;
            return $response;
        } else {
            my $result = $self->create_submission($params);
            $response->{stage}  = 'commit';
            $response->{next}   = "illview";
            $response->{params} = $params;
            return $response;
        }
    }
}

=head3 illview

   View and manage an ILL request

=cut

sub illview {
    my ( $self, $params ) = @_;

    return {
        field_map_json => to_json( fieldmap() ),
        method         => "illview"
    };
}

=head3 edititem

Edit an item's metadata

=cut

sub edititem {
    my ( $self, $params ) = @_;

    # Don't allow editing of requested or completed submissions
    return {
        cwd    => dirname(__FILE__),
        method => 'illlist'
    } if ( $params->{request}->status eq 'REQ' || $params->{request}->status eq 'COMP' );

    my $other = $params->{other};
    my $stage = $other->{stage};
    if ( !$stage || $stage eq 'init' ) {
        my $attrs = $params->{request}->illrequestattributes->unblessed;
        foreach my $attr ( @{$attrs} ) {
            $other->{ $attr->{type} } = $attr->{value};
        }
        return {
            cwd            => dirname(__FILE__),
            error          => 0,
            status         => '',
            message        => '',
            method         => 'edititem',
            stage          => 'form',
            value          => $params,
            field_map      => $self->fieldmap_sorted,
            field_map_json => to_json( $self->fieldmap )
        };
    } elsif ( $stage eq 'form' ) {

        # Update submission
        my $submission = $params->{request};
        $submission->updated( DateTime->now );
        $submission->store;

        # We may be receiving a submitted form due to the user having
        # changed request material type, so we just need to go straight
        # back to the form, the type has been changed in the params
        if ( defined $other->{change_type} ) {
            delete $other->{change_type};
            return {
                cwd            => dirname(__FILE__),
                error          => 0,
                status         => '',
                message        => '',
                method         => 'edititem',
                stage          => 'form',
                value          => $params,
                field_map      => $self->fieldmap_sorted,
                field_map_json => to_json( $self->fieldmap )
            };
        }

        # ...Populate Illrequestattributes
        # generate $request_details
        # We do this with a 'dump all and repopulate approach' inside
        # a transaction, easier than catering for create, update & delete
        my $dbh    = C4::Context->dbh;
        my $schema = Koha::Database->new->schema;
        $schema->txn_do(
            sub {
                # Delete all existing attributes for this request
                $dbh->do(
                    q|
                    DELETE FROM illrequestattributes WHERE illrequest_id=?
                |, undef, $submission->id
                );

                # Insert all current attributes for this request
                my $fields = $self->fieldmap;

                # First insert our Reprints Desk fields
                foreach my $field ( %{$other} ) {
                    my $value = $other->{$field};
                    if ( $other->{$field}
                        && length $other->{$field} > 0 )
                    {
                        my @bind = (
                            $submission->id,
                            column_exists( 'illrequestattributes', 'backend' ) ? "ReprintsDesk" : (),
                            $field, $value, 0
                        );

                        $dbh->do(
                            q|
                            INSERT IGNORE INTO illrequestattributes
                            (illrequest_id,|
                                . ( column_exists( 'illrequestattributes', 'backend' ) ? q|backend,| : q|| ) . q|
                             type, value, readonly) VALUES
                            (?, ?, ?, ?, ?)
                        |, undef, @bind
                        );
                    }
                }

                # Now insert our core equivalents, if an equivalently named Rapid field
                # doesn't already exist
                foreach my $field ( %{$other} ) {
                    my $value = $other->{$field};
                    if (   $other->{$field}
                        && $fields->{$field}->{ill}
                        && length $other->{$field} > 0
                        && !$fields->{ $fields->{$field}->{ill} } )
                    {
                        my @bind = (
                            $submission->id,
                            column_exists( 'illrequestattributes', 'backend' ) ? "ReprintsDesk" : (),
                            $field, $value, 0
                        );

                        $dbh->do(
                            q|
                            INSERT IGNORE INTO illrequestattributes
                            (illrequest_id,|
                                . ( column_exists( 'illrequestattributes', 'backend' ) ? q|backend,| : q|| ) . q|
                             type, value, readonly) VALUES
                            (?, ?, ?, ?, ?)
                        |, undef, @bind
                        );
                    }
                }
            }
        );

        # Create response
        return {
            cwd            => dirname(__FILE__),
            error          => 0,
            status         => '',
            message        => '',
            method         => 'create',
            stage          => 'commit',
            next           => 'illview',
            value          => $params,
            field_map      => $self->fieldmap_sorted,
            field_map_json => to_json( $self->fieldmap )
        };
    }
}

=head3 do_join

If a field should be joined with another field for storage as a core
value or display, then do it

=cut

sub do_join {
    my ( $self, $field, $metadata ) = @_;
    my $fields = $self->fieldmap;
    my $value  = $metadata->{$field};
    my $join   = $fields->{$field}->{join};
    if ( $join && $metadata->{$join} && $value ) {
        my @to_join = ( $value, $metadata->{$join} );
        $value = join " ", @to_join;
    }
    return $value;
}

=head3 mark_completed

Mark a request as completed (status = COMP).

=cut

sub mark_completed {
    my ($self) = @_;
    $self->status('COMP')->store;
    $self->completed( dt_from_string() )->store;
    return {
        error   => 0,
        status  => '',
        message => '',
        method  => 'mark_completed',
        stage   => 'commit',
        next    => 'illview',
    };
}

=head3 ready

Mark this request as 'READY'

=cut

sub ready {
    my ( $self, $params ) = @_;
    my $other = $params->{other};

    my $request = Koha::ILL::Requests->find( $other->{illrequest_id} );

    $request->status('READY');
    $request->updated( DateTime->now );
    $request->store;

    return {
        error   => 0,
        status  => '',
        message => '',
        method  => 'ready',
        stage   => 'commit',
        next    => 'illview',
        value   => $params,
    };
}

=head3 mark_new

Mark this request as 'NEW'

=cut

sub mark_new {
    my ( $self, $params ) = @_;
    my $other = $params->{other};

    my $request = Koha::ILL::Requests->find( $other->{illrequest_id} );

    $request->status('NEW');
    $request->updated( DateTime->now );
    $request->store;

    return {
        error   => 0,
        status  => '',
        message => '',
        method  => 'mark_new',
        stage   => 'commit',
        next    => 'illview',
        value   => $params,
    };
}

=head3 migrate

Migrate a request into or out of this backend

=cut

sub migrate {
    my ( $self, $params ) = @_;
    my $other = $params->{other};

    my $stage = $other->{stage};
    my $step  = $other->{step};

    my $fields = $self->fieldmap;

    my $request = Koha::ILL::Requests->find( $other->{illrequest_id} );

    # Record where we're migrating from, so we can log that
    my $migrating_from = $request->backend;

    if ( $request->status eq 'REQ' ) {
        # The orderid is no longer applicable
        $request->orderid(undef);
    }
    $request->status('MIG');
    $request->backend( $self->name );
    $request->updated( DateTime->now );
    $request->store;

    # Translate the core metadata into our schema
    my $all_attrs = $request->illrequestattributes->unblessed;

    # For each attribute, if the property name is a core one we change it to the Reprints Desk
    # equivalent, otherwise we can skip it as it already exists in the attributes list
    foreach my $attr ( @{$all_attrs} ) {
        my $rd_field_name = $self->find_reprints_desk_property( $attr->{type} );

        # If we've found a Reprints Desk field name and an attribute doesn't already exist
        # with this name, create a new one
        if ( $rd_field_name && !$self->find_illrequestattribute( $all_attrs, $rd_field_name ) ) {
            Koha::ILL::Request::Attribute->new(
                {
                    illrequest_id => $request->illrequest_id,

                    # Check required for compatibility with installations before bug 33970
                    column_exists( 'illrequestattributes', 'backend' ) ? ( backend => "ReprintsDesk" ) : (),
                    type  => $rd_field_name,
                    value => $attr->{value},
                }
            )->store;
        }
    }

    # Log that the migration took place
    if ( $self->_logger ) {
        my $payload = {
            modulename   => 'ILL',
            actionname   => 'REPRINTS_DESK_MIGRATE_IN',
            objectnumber => $request->id,
            infos        => to_json(
                {
                    log_origin    => $self->name,
                    migrated_from => $migrating_from,
                    migrated_to   => $self->name
                }
            )
        };
        $self->_logger->log_something($payload);
    }

    return {
        error   => 0,
        status  => '',
        message => '',
        method  => 'migrate',
        stage   => 'commit',
        next    => 'illview',
        value   => $params,
    };

}

=head3 _validate_metadata

Ensure the metadata we've got conforms to the order
API specification

=cut

sub _validate_metadata {
    my ( $self, $metadata ) = @_;
    return 1;
}

=head3 create_submission

Create a local submission, for later Reprints Desk request creation

=cut

sub create_submission {
    my ( $self, $params ) = @_;

    my $patron = Koha::Patrons->find( $params->{other}->{borrowernumber} );

    my $request = $params->{request};
    $request->borrowernumber( $patron->borrowernumber );
    $request->branchcode( $params->{other}->{branchcode} );
    $request->status('NEW');
    $request->batch_id(
        $params->{other}->{ill_batch_id} ? $params->{other}->{ill_batch_id} : $params->{other}->{batch_id} );
    $request->backend( $self->name );
    $request->placed( DateTime->now );
    $request->updated( DateTime->now );

    $request->store;

    $params->{other}->{type} = 'article';

    # Store the request attributes
    $self->create_illrequestattributes( $request, $params->{other} );

    # Now store the core equivalents
    $self->create_illrequestattributes( $request, $params->{other}, 1 );

    return $request;
}

=head3

Store metadata for a given request for our Reprints Desk fields

=cut

sub create_illrequestattributes {
    my ( $self, $request, $metadata, $core ) = @_;

    # Get the canonical list of metadata fields
    my $fields = $self->fieldmap;

    # Get any existing illrequestattributes for this request,
    # so we can avoid trying to create duplicates
    my $existing_attrs = $request->illrequestattributes->unblessed;
    my $existing_hash  = {};
    foreach my $a ( @{$existing_attrs} ) {
        $existing_hash->{ lc $a->{type} } = $a->{value};
    }

    # Iterate our list of fields
    foreach my $field ( keys %{$fields} ) {
        if (
            # If we're working with core metadata, check if this field
            # has a core equivalent
            ( ( $core && $fields->{$field}->{ill} ) || !$core )
            && $metadata->{$field}
            && length $metadata->{$field} > 0
            )
        {
            my $att_type  = $core ? $fields->{$field}->{ill} : $field;
            my $att_value = $metadata->{$field};

            # If core, we might need to join
            if ($core) {
                $att_value = $self->do_join( $field, $metadata );
            }

            # If it doesn't already exist for this request
            if ( !exists $existing_hash->{ lc $att_type } ) {
                my $data = {
                    illrequest_id => $request->illrequest_id,

                    # Check required for compatibility with installations before bug 33970
                    column_exists( 'illrequestattributes', 'backend' ) ? ( backend => "ReprintsDesk" ) : (),
                    type     => $att_type,
                    value    => $att_value,
                    readonly => 0
                };
                Koha::ILL::Request::Attribute->new($data)->store;
            }
        }
    }
}

=head3 prep_submission_metadata

Given a submission's metadata, probably from a form,
but maybe as an ILL::Request::Attributes object,
and a partly constructed hashref, add any metadata that
is appropriate for this material type

=cut

sub prep_submission_metadata {
    my ( $self, $metadata, $return ) = @_;

    $return = $return //= {};

    my $metadata_hashref = {};

    if ( ref $metadata eq "Koha::ILL::Request::Attributes" ) {
        while ( my $attr = $metadata->next ) {
            $metadata_hashref->{ $attr->type } = $attr->value;
        }
    } else {
        $metadata_hashref = $metadata;
    }

    # Get our canonical field list
    my $fields = $self->fieldmap;

    # Iterate our list of fields
    foreach my $field ( keys %{$fields} ) {
        if ( $metadata_hashref->{$field}
            && length $metadata_hashref->{$field} > 0 )
        {
            $metadata_hashref->{$field} =~ s/  / /g;
            if ( $fields->{$field}->{api_max_length} ) {
                $return->{$field} = substr( $metadata_hashref->{$field}, 0, $fields->{$field}->{api_max_length} );
            } else {
                $return->{$field} = $metadata_hashref->{$field};
            }
        }
    }

    return $return;
}

=head3 submit_and_request

Creates a local submission, then uses the returned ID to create
a Reprints Desk request

=cut

sub submit_and_request {
    my ( $self, $params ) = @_;

    # First we create a submission
    my $submission = $self->create_submission($params);

    # Now use the submission to try and create a request with Reprints Desk
    return $self->create_request($submission);
}

=head3 create_request

Take a previously created submission and send it to Reprints Desk
in order to create a request

=cut

sub create_request {
    my ( $self, $submission ) = @_;

    my $metadata = {};

    $metadata = $self->prep_submission_metadata(
        $submission->illrequestattributes,
        $metadata
    );

    # We may need to remove fields prior to sending the request
    my $fields = fieldmap();
    foreach my $field ( keys %{$fields} ) {
        if ( $fields->{$field}->{no_submit} ) {
            delete $metadata->{$field};
        }
    }

    my $backend_api = Koha::Plugin::Com::PTFSEurope::ReprintsDesk->new->new_ill_backend;

    # Make the request with Reprints Desk via the koha-plugin-reprintsdesk API
    my $response =
        $backend_api->{_api}->Order_PlaceOrder2( $metadata, $submission->borrowernumber, $submission->illrequest_id );

    # If the call to Reprints Desk was successful,
    # add the Reprints Desk request ID to our submission's metadata
    my $body = from_json( $response->decoded_content );

    if ( scalar @{ $body->{errors} } == 0 && $body->{result}->{Order_PlaceOrder2Result} == 1 ) {
        my $request_id = $body->{result}->{orderID};
        if ( $request_id && length $request_id > 0 ) {
            Koha::ILL::Request::Attribute->new(
                {
                    illrequest_id => $submission->illrequest_id,

                    # Check required for compatibility with installations before bug 33970
                    column_exists( 'illrequestattributes', 'backend' ) ? ( backend => "ReprintsDesk" ) : (),
                    type  => 'orderId',
                    value => $request_id
                }
            )->store;
        }
        my $rnd_id = $body->{result}->{rndID};
        if ( $rnd_id && length $rnd_id > 0 ) {
            Koha::ILL::Request::Attribute->new(
                {
                    illrequest_id => $submission->illrequest_id,

                    # Check required for compatibility with installations before bug 33970
                    column_exists( 'illrequestattributes', 'backend' ) ? ( backend => "ReprintsDesk" ) : (),
                    type  => 'rndId',
                    value => $rnd_id
                }
            )->store;
        }

        # Add the Reprints Desk ID to the orderid field
        $submission->orderid($request_id);

        # Update the submission status
        $submission->status('REQ')->store;

        # Log the outcome
        $self->log_request_outcome(
            {
                outcome => 'REPRINTS_DESK_REQUEST_SUCCEEDED',
                request => $submission
            }
        );

        return { success => 1 };
    }

    # The call to Reprints Desk failed for some reason. Add the message we got back from the API
    # to the submission's Staff Notes
    my $errors = join '. ', map { $_->{message} . ( $_->{path} ? ' path: ' . $_->{path} : '' ) } @{ $body->{errors} };

    $submission->append_to_note("Reprints Desk request failed:\n$errors");

    # Log the outcome
    $self->log_request_outcome(
        {
            outcome => 'REPRINTS_DESK_REQUEST_FAILED',
            request => $submission,
            message => $errors
        }
    );

    $submission->status('ERROR')->store;

    # Return the message
    return {
        success => 0,
        message => $errors
    };

}

=head3 confirm

A wrapper around create_request allowing us to
provide the "confirm" method required by
the status graph

=cut

sub confirm {
    my ( $self, $params ) = @_;

    my $return = $self->create_request( $params->{request} );

    my $return_value = {
        cwd     => dirname(__FILE__),
        error   => 0,
        status  => "",
        message => "",
        method  => "create",
        stage   => "commit",
        next    => "illview",
        value   => {},
        %{$return}
    };

    return $return_value;
}

=head3 log_request_outcome

Log the outcome of a request to the Reprints Desk API

=cut

sub log_request_outcome {
    my ( $self, $params ) = @_;

    if ( $self->{_logger} ) {

        # TODO: This is a transitionary measure, we have removed set_data
        # in Bug 20750, so calls to it won't work. But since 20750 is
        # only in 19.05+, they only won't work in earlier
        # versions. So we're temporarily going to allow for both cases
        my $payload = {
            modulename   => 'ILL',
            actionname   => $params->{outcome},
            objectnumber => $params->{request}->id,
            infos        => to_json(
                {
                    log_origin => $self->name,
                    response   => $params->{message}
                }
            )
        };
        if ( $self->{_logger}->can('set_data') ) {
            $self->{_logger}->set_data($payload);
        } else {
            $self->{_logger}->log_something($payload);
        }
    }
}

=head3 get_log_template_path

    my $path = $BLDSS->get_log_template_path($action);

Given an action, return the path to the template for displaying
that action log

=cut

sub get_log_template_path {
    my ( $self, $action ) = @_;
    return $self->{templates}->{$action};
}

=head3 backend_metadata

Return a hashref containing canonical values from the key/value
illrequestattributes store

=cut

sub backend_metadata {
    my ( $self, $request ) = @_;

    my $attrs  = $request->illrequestattributes;
    my $fields = $self->fieldmap;

    my $metadata               = {};
    my $metadata_keyed_on_prop = {};

    while ( my $attr = $attrs->next ) {
        if ( $fields->{ $attr->type } ) {
            my $label = $fields->{ $attr->type }->{label};
            $metadata->{$label} = $attr->value;
            $metadata_keyed_on_prop->{ $attr->type } = $attr->value;
        }
    }

    my $rd_title_key = 'Journal title';
    $metadata->{Title} = $metadata->{$rd_title_key} if $metadata->{$rd_title_key};

    return $metadata;
}

=head3 capabilities

    $capability = $backend->capabilities($name);

Return the sub implementing a capability selected by NAME, or 0 if that
capability is not implemented.

=cut

sub capabilities {
    my ( $self, $name ) = @_;
    my $capabilities = {

        # View and manage a request
        illview => sub { illview(@_); },

        # Migrate
        migrate => sub { $self->migrate(@_); },

        # Return whether we can create the request
        # i.e. the create form has been submitted
        can_create_request => sub { _can_create_request(@_) },

        # This is required for compatibility
        # with Koha versions prior to bug 33716
        should_display_availability => sub { _can_create_request(@_) },

        provides_backend_availability_check => sub { return 1; },

        provides_batch_requests => sub { return 1; },

        # We can create ILL requests with data passed from the API
        create_api => sub { $self->create_api(@_) }
    };

    return $capabilities->{$name};
}

=head3 _can_create_request

Given the parameters we've been passed, should we create the request

=cut

sub _can_create_request {
    my ($params) = @_;
    return ( defined $params->{'stage'} ) ? 1 : 0;
}

=head3 status_graph


=cut

sub status_graph {
    return {
        EDITITEM => {
            prev_actions   => ['NEW'],
            id             => 'EDITITEM',
            name           => 'Edited item metadata',
            ui_method_name => 'Edit item metadata',
            method         => 'edititem',
            next_actions   => [],
            ui_method_icon => 'fa-edit',
        },
        CIT => {
            prev_actions   => ['REQ'],
            id             => 'CIT',
            name           => 'Citation Verification',
            ui_method_name => 0,
            method         => 0,
            next_actions   => [ 'COMP', 'MIG', 'KILL' ],
            ui_method_icon => 0,
        },
        SOURCE => {
            prev_actions   => ['REQ'],
            id             => 'SOURCE',
            name           => 'Sourcing',
            ui_method_name => 0,
            method         => 0,
            next_actions   => [ 'COMP', 'MIG', 'KILL' ],
            ui_method_icon => 0,
        },
        ERROR => {
            prev_actions   => [],
            id             => 'ERROR',
            name           => 'Request error',
            ui_method_name => 0,
            method         => 0,
            next_actions   => [ 'MARK_NEW', 'COMP', 'EDITITEM', 'STANDBY', 'READY', 'MIG', 'KILL' ],
            ui_method_icon => 0,
        },
        COMP => {
            prev_actions   => [ 'CIT', 'SOURCE', 'ERROR' ],
            id             => 'COMP',
            name           => 'Order Complete',
            ui_method_name => 'Mark completed',
            method         => 'mark_completed',
            next_actions   => [],
            ui_method_icon => 'fa-check',
        },
        READY => {
            prev_actions   => [ 'ERROR', 'STANDBY' ],
            id             => 'READY',
            name           => 'Request ready',
            ui_method_name => 'Mark request READY',
            method         => 'ready',
            next_actions   => [],
            ui_method_icon => 'fa-check',
        },
        STANDBY => {
            prev_actions   => [ 'NEW', 'ERROR' ],
            id             => 'STANDBY',
            name           => 'Request standing by',
            ui_method_name => 0,
            method         => 0,
            next_actions   => ['READY'],
            ui_method_icon => 'fa-check',
        },
        NEW => {
            prev_actions   => [],
            id             => 'NEW',
            name           => 'New request',
            ui_method_name => 'New request',
            method         => 'create',
            next_actions   => [ 'KILL', 'MIG', 'EDITITEM' ],
            ui_method_icon => 'fa-plus'
        },
        MARK_NEW => {
            prev_actions   => ['ERROR', 'MIG'],
            id             => 'MARK_NEW',
            name           => 'New request',
            ui_method_name => 'Mark request NEW',
            method         => 'mark_new',
            next_actions   => [],
            ui_method_icon => 'fa-refresh'
        },

        # Override REQ so we can rename the button
        # Talk about a sledgehammer to crack a nut
        REQ => {
            prev_actions   => [ 'READY', 'REQREV', 'QUEUED' ],
            id             => 'REQ',
            name           => 'Requested',
            ui_method_name => 'Request from Reprints Desk',
            method         => 'confirm',
            next_actions   => [ 'REQREV', 'CHK' ],
            ui_method_icon => 'fa-check',
        },
        MIG => {
            prev_actions   => [ 'NEW', 'REQ', 'GENREQ', 'REQREV', 'QUEUED' ],
            id             => 'MIG',
            name           => 'Switched provider',
            ui_method_name => 'Switch provider',
            method         => 'migrate',
            next_actions   => [ 'MARK_NEW', 'GENREQ', 'KILL', 'MIG'],
            ui_method_icon => 'fa-search',
        },
    };
}

=head3 _fail

=cut

sub _fail {
    my @values = @_;
    foreach my $val (@values) {
        return 1 if ( !$val or $val eq '' );
    }
    return 0;
}

=head3 find_illrequestattribute

=cut

sub find_illrequestattribute {
    my ( $self, $attributes, $prop ) = @_;
    foreach my $attr ( @{$attributes} ) {
        if ( $attr->{type} eq $prop ) {
            return 1;
        }
    }
}

=head3 find_reprints_desk_property

Given a core property name, find the equivalent Reprints Desk
name. Or undef if there is not one

=cut

sub find_reprints_desk_property {
    my ( $self, $core ) = @_;
    my $fields = $self->fieldmap;
    foreach my $field ( keys %{$fields} ) {
        if ( $fields->{$field}->{ill} && $fields->{$field}->{ill} eq $core ) {
            return $field;
        }
    }
}

=head3 _openurl_to_reprints_desk

Take a hashref of OpenURL parameters and return
those same parameters but transformed to the Reprints Desk
schema

=cut

sub _openurl_to_reprints_desk {
    my ($params) = @_;

    my $transform_metadata = {
        atitle  => 'atitle',
        aufirst => 'aufirst',
        aulast  => 'aulast',
        date    => 'date',
        issue   => 'issue',
        volume  => 'volume',
        isbn    => 'isbn',
        issn    => 'issn',
        eissn   => 'eissn',
        doi     => 'doi',
        pmid    => 'pubmedid',
        title   => 'title',
        pages   => 'pages'
    };

    my $return = {};

    # First make sure our keys are correct
    foreach my $meta_key ( keys %{ $params->{other} } ) {

        # If we are transforming this property...
        if ( exists $transform_metadata->{$meta_key} ) {

            # ...do it if we have valid mapping
            if ( length $transform_metadata->{$meta_key} > 0 ) {
                $return->{ $transform_metadata->{$meta_key} } = $params->{other}->{$meta_key};
            }
        } else {

            # Otherwise, pass it through untransformed
            $return->{$meta_key} = $params->{other}->{$meta_key};
        }
    }
    $params->{other} = $return;
    return $params;
}

=head3 create_api

Create a local submission from data supplied via an
API call

=cut

sub create_api {
    my ( $self, $body, $request ) = @_;

    # We are receiving metadata in core schema, we need to
    # translate to Reprints Desk schema before we can proceed
    # We merge the supplied core metadata with the Reprints Desk
    # equivalents
    foreach my $attr ( @{ $body->{extended_attributes} } ) {
        my $prop    = $attr->{type};
        my $rd_prop = find_core_to_reprints_desk($prop);
        if ($rd_prop) {
            my @value = map { $_->{type} eq $rd_prop ? $_->{value} : () } @{ $body->{extended_attributes} };
            $body->{$rd_prop} = $value[0];
        }
    }

    # Create a submission from our metadata
    # Mung things into the form create_submission expects
    delete $body->{extended_attributes};

    my $submission = $self->create_submission(
        {
            request => $request,
            other   => $body
        }
    );

    return $submission;
}

=head3 find_core_to_reprints_desk

Given a core metadata property, find the element
in fieldmap that has that as the "ill" property

=cut

sub find_core_to_reprints_desk {
    my ($prop) = @_;

    my $fieldmap = fieldmap();

    foreach my $field ( keys %{$fieldmap} ) {
        if ( $fieldmap->{$field}->{ill} && $fieldmap->{$field}->{ill} eq $prop ) {
            return $prop;
        }
    }
}

=head3 fieldmap_sorted

Return the fieldmap sorted by "order"
Note: The key of the field is added as a "key"
property of the returned hash

=cut

sub fieldmap_sorted {
    my ($self) = @_;

    my $fields = $self->fieldmap;

    my @out = ();

    foreach my $key ( sort { $fields->{$a}->{position} <=> $fields->{$b}->{position} } keys %{$fields} ) {
        my $el = $fields->{$key};
        $el->{key} = $key;
        push @out, $el;
    }

    return \@out;
}

=head3 fieldmap

All fields expected by the API

Key = API metadata element name
  hide = Make the field hidden in the form
  no_submit = Do not pass to Reprints Desk API
  api_max_length = Max length of field enforced by the Reprints Desk API
  exclude = Do not include on the entry form
  type = Does an element contain a string value or an array of string values?
  label = Display label
  ill   = The core ILL equivalent field
  help = Display help text

=cut

sub fieldmap {
    return {
        title => {
            exclude        => 1,
            type           => "string",
            label          => "Journal title",
            ill            => "title",
            api_max_length => 255,
            position       => 0
        },
        atitle => {
            exclude        => 1,
            type           => "string",
            label          => "Article title",
            ill            => "article_title",
            api_max_length => 255,
            position       => 1
        },
        article_title => {
            exclude        => 1,
            type           => "string",
            label          => "Article title",
            ill            => "article_title",
            api_max_length => 255,
            no_submit      => 1,
            position       => 1
        },
        aufirst => {
            type           => "string",
            label          => "Author's first name",
            ill            => "article_author",
            api_max_length => 50,
            position       => 2,
            join           => "aulast"
        },
        aulast => {
            type           => "string",
            label          => "Author's last name",
            api_max_length => 50,
            position       => 3
        },
        volume => {
            type           => "string",
            label          => "Volume number",
            ill            => "volume",
            api_max_length => 50,
            position       => 4
        },
        issue => {
            type           => "string",
            label          => "Journal issue number",
            ill            => "issue",
            api_max_length => 50,
            position       => 5
        },
        date => {
            type           => "string",
            ill            => "year",
            api_max_length => 50,
            position       => 7,
            label          => "Item publication date"
        },
        pages => {
            type           => "string",
            label          => "Pages in journal",
            ill            => "pages",
            api_max_length => 50,
            position       => 8
        },
        spage => {
            type           => "string",
            label          => "First page of article in journal",
            ill            => "spage",
            api_max_length => 50,
            position       => 8
        },
        epage => {
            type           => "string",
            label          => "Last page of article in journal",
            ill            => "epage",
            api_max_length => 50,
            position       => 9
        },
        doi => {
            type           => "string",
            label          => "DOI",
            ill            => "doi",
            api_max_length => 96,
            position       => 10
        },
        pubmedid => {
            type           => "string",
            label          => "PubMed ID",
            ill            => "pubmedid",
            api_max_length => 16,
            position       => 11
        },
        isbn => {
            type           => "string",
            label          => "ISBN",
            ill            => "isbn",
            api_max_length => 50,
            position       => 12
        },
        issn => {
            type           => "string",
            label          => "ISSN",
            ill            => "issn",
            api_max_length => 50,
            position       => 13
        },
        eissn => {
            type           => "string",
            label          => "EISSN",
            ill            => "eissn",
            api_max_length => 50,
            position       => 14
        },
        orderdateutc => {
            type      => "string",
            label     => "Order date UTC",
            exclude   => 1,
            no_submit => 1,
            position  => 99
        },
        statusdateutc => {
            type      => "string",
            label     => "Status date UTC",
            exclude   => 1,
            no_submit => 1,
            position  => 99
        },
        author => {
            type      => "string",
            label     => "Author",
            ill       => "author",
            exclude   => 1,
            no_submit => 1,
            position  => 99
        },
        year => {
            type      => "string",
            ill       => "year",
            exclude   => 1,
            label     => "Year",
            no_submit => 1,
            position  => 99
        },
        type => {
            type      => "string",
            ill       => "type",
            exclude   => 1,
            label     => "Type",
            no_submit => 1,
            position  => 99
        },
    };
}

=head3 _validate_borrower

=cut

sub _validate_borrower {

    # Perform cardnumber search.  If no results, perform surname search.
    # Return ( 0, undef ), ( 1, $brw ) or ( n, $brws )
    my ( $input, $action ) = @_;

    return ( 0, undef ) if !$input || length $input == 0;

    my $patrons = Koha::Patrons->new;
    my ( $count, $brw );
    my $query = { cardnumber => $input };
    $query = { borrowernumber => $input } if ( $action && $action eq 'search_results' );

    my $brws = $patrons->search($query);
    $count = $brws->count;
    my @criteria = qw/ surname userid firstname end /;
    while ( $count == 0 ) {
        my $criterium = shift @criteria;
        return ( 0, undef ) if ( "end" eq $criterium );
        $brws  = $patrons->search( { $criterium => $input } );
        $count = $brws->count;
    }
    if ( $count == 1 ) {
        $brw = $brws->next;
    } else {
        $brw = $brws;    # found multiple results
    }
    return ( $count, $brw );
}

=head3 _logger

    my $logger = $backend->_logger($logger);
    my $logger = $backend->_logger;
    Getter/Setter for our Logger object.

=cut

sub _logger {
    my ( $self, $logger ) = @_;
    $self->{_logger} = $logger if ($logger);
    return $self->{_logger};
}

1;
