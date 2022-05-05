package Koha::Illbackends::ReprintsDesk::Base;

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

use JSON qw( to_json from_json );
use File::Basename qw( dirname );

use Koha::Illbackends::ReprintsDesk::Lib::API;
use Koha::Libraries;
use Koha::Patrons;

our $VERSION = "1.0.0";

sub new {
    my ($class, $params) = @_;

    my $api = Koha::Illbackends::ReprintsDesk::Lib::API->new($VERSION);

    my $self = {
        _api    => $api
    };

    $self->{_logger} = $params->{logger} if ( $params->{logger} ); 

    bless($self, $class);

    return $self;
}

=head3 create

Handle the "create" flow

=cut

sub create {
    my ($self, $params) = @_;

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
        field_map_json => to_json($self->fieldmap())
    };

    # Check for borrowernumber, but only if we're not receiving an OpenURL
    if (
        !$other->{openurl} &&
        (!$other->{borrowernumber} && defined( $other->{cardnumber} ))
    ) {
        $response->{cardnumber} = $other->{cardnumber};

        # 'cardnumber' here could also be a surname (or in the case of
        # search it will be a borrowernumber).
        my ( $brw_count, $brw ) =
          _validate_borrower( $other->{'cardnumber'}, $stage );

        if ( $brw_count == 0 ) {
            $response->{status} = "invalid_borrower";
            $response->{value}  = $params;
            $response->{stage} = "init";
            $response->{error}  = 1;
            return $response;
        }
        elsif ( $brw_count > 1 ) {
            # We must select a specific borrower out of our options.
            $params->{brw}     = $brw;
            $response->{value} = $params;
            $response->{stage} = "borrowers";
            $response->{error} = 0;
            return $response;
        }
        else {
            $other->{borrowernumber} = $brw->borrowernumber;
        }

        $self->{borrower} = $brw;
    }

    # Initiate process
    if ( !$stage || $stage eq 'init' ) {

        # First thing we want to do, is check if we're receiving
        # an OpenURL and transform it into something we can
        # understand
        if ($other->{openurl}) {
            # We only want to transform once
            delete $other->{openurl};
            $params = _openurl_to_ill($params);
        }

        # Pass the map of form fields in forms that can be used by TT
        # and JS
        $response->{field_map} = $self->fieldmap_sorted;
        $response->{field_map_json} = to_json($self->fieldmap());
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
            $response->{field_map} = $self->fieldmap_sorted;
            $response->{field_map_json} = to_json($self->fieldmap());
            $response->{status} = "missing_branch";
            $response->{error}  = 1;
            $response->{stage}  = 'init';
            $response->{value}  = $params;
            return $response;
        }
        elsif ( !Koha::Libraries->find( $other->{'branchcode'} ) ) {
            # Pass the map of form fields in forms that can be used by TT
            # and JS
            $response->{field_map} = $self->fieldmap_sorted;
            $response->{field_map_json} = to_json($self->fieldmap());
            $response->{status} = "invalid_branch";
            $response->{error}  = 1;
            $response->{stage}  = 'init';
            $response->{value}  = $params;
            return $response;
        }
        elsif ( !$self->_validate_metadata($other)) {
            $response->{field_map} = $self->fieldmap_sorted;
            $response->{field_map_json} = to_json($self->fieldmap());
            $response->{status} = "invalid_metadata";
            $response->{error}  = 1;
            $response->{stage}  = 'init';
            $response->{value}  = $params;
            return $response;
        }
        else {
            # We can submit a request directly to Reprints Desk
            my $result = $self->submit_and_request($params);

            if ($result->{success}) {
                $response->{stage}  = "commit";
                $response->{next} = "illview";
                $response->{params} = $params;
            } else {
                $response->{error}  = 1;
                $response->{stage}  = 'commit';
                $response->{next} = "illview";
                $response->{params} = $params;
                $response->{message} = $result->{message};
            }

            return $response;
        }
    }
}

=head3 cancel

    Cancel a local submission

=cut

sub cancel {
    my ($self, $params) = @_;

    # Update the submission's status
    $params->{request}->status("CANCREQ")->store;
}

=head3 illview

   View and manage an ILL request

=cut

sub illview {
    my ($self, $params) = @_;

    return {
        field_map_json => to_json(fieldmap()),
        method         => "illview"
    };
}

=head3 edititem

Edit an item's metadata

=cut

sub edititem {
    my ($self, $params) = @_;

    # Don't allow editing of requested submissions
    return {
        cwd    => dirname(__FILE__),
        method => 'illlist'
    } if $params->{request}->status ne 'NEW';

    my $other = $params->{other};
    my $stage = $other->{stage};
    if ( !$stage || $stage eq 'init' ) {
        my $attrs = $params->{request}->illrequestattributes->unblessed;
        foreach my $attr(@{$attrs}) {
            $other->{$attr->{type}} = $attr->{value};
        }
        return {
            cwd     => dirname(__FILE__),
            error   => 0,
            status  => '',
            message => '',
            method  => 'edititem',
            stage   => 'form',
            value   => $params,
            field_map => $self->fieldmap_sorted,
            field_map_json => to_json($self->fieldmap)
        };
    } elsif ( $stage eq 'form' ) {
        # Update submission
        my $submission = $params->{request};
        $submission->updated( DateTime->now );
        $submission->store;

        # We may be receiving a submitted form due to the user having
        # changed request material type, so we just need to go straight
        # back to the form, the type has been changed in the params
        if (defined $other->{change_type}) {
            delete $other->{change_type};
            return {
                cwd     => dirname(__FILE__),
                error   => 0,
                status  => '',
                message => '',
                method  => 'edititem',
                stage   => 'form',
                value   => $params,
                field_map => $self->fieldmap_sorted,
                field_map_json => to_json($self->fieldmap)
            };
        }

        # ...Populate Illrequestattributes
        # generate $request_details
        # We do this with a 'dump all and repopulate approach' inside
        # a transaction, easier than catering for create, update & delete
        my $dbh    = C4::Context->dbh;
        my $schema = Koha::Database->new->schema;
        $schema->txn_do(
            sub{
                # Delete all existing attributes for this request
                $dbh->do( q|
                    DELETE FROM illrequestattributes WHERE illrequest_id=?
                |, undef, $submission->id);
                # Insert all current attributes for this request
                my $fields = $self->fieldmap;

                # First insert our Reprints Desk fields
                foreach my $field(%{$other}) {
                    my $value = $other->{$field};
                    if (
                        $other->{$field} &&
                        length $other->{$field} > 0
                    ) {
                        my @bind = ($submission->id, $field, $value, 0);
                        $dbh->do ( q|
                            INSERT INTO illrequestattributes
                            (illrequest_id, type, value, readonly) VALUES
                            (?, ?, ?, ?)
                        |, undef, @bind);
                    }
                }

                # Now insert our core equivalents, if an equivalently named Rapid field
                # doesn't already exist
                foreach my $field(%{$other}) {
                    my $value = $other->{$field};
                    if (
                        $other->{$field} &&
                        $fields->{$field}->{ill} &&
                        length $other->{$field} > 0 &&
                        !$fields->{$fields->{$field}->{ill}}
                    ) {
                        my @bind = ($submission->id, $fields->{$field}->{ill}, $value, 0);
                        $dbh->do ( q|
                            INSERT INTO illrequestattributes
                            (illrequest_id, type, value, readonly) VALUES
                            (?, ?, ?, ?)
                        |, undef, @bind);
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
            field_map_json => to_json($self->fieldmap)
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
    my $value = $metadata->{$field};
    my $join = $fields->{$field}->{join};
    if ($join && $metadata->{$join} && $value) {
        my @to_join = ( $value, $metadata->{$join} );
        $value = join " ", @to_join;
    }
    return $value;
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

    # Recieve a new request from another backend and suppliment it with
    # anything we require specifically for this backend.
    if ( !$stage || $stage eq 'immigrate' ) {
        my $original_request =
          Koha::Illrequests->find( $other->{illrequest_id} );
        my $new_request = $params->{request};
        $new_request->borrowernumber( $original_request->borrowernumber );
        $new_request->branchcode( $original_request->branchcode );
        $new_request->status('NEW');
        $new_request->backend( $self->name );
        $new_request->placed( DateTime->now );
        $new_request->updated( DateTime->now );
        $new_request->store;

        # Map from Koha's core fields to our metadata fields
        my $original_id = $original_request->illrequest_id;
        my @original_attributes = $original_request->illrequestattributes->search(
            { illrequest_id => $original_id }
        );
        my @attributes = keys %{$fields};

        # Look for an equivalent Reprints Desk attribute 
        # for every bit of metadata we receive and, if it exists, map it to the
        # new property
        my $new_attributes = {};
        foreach my $old(@original_attributes) {
            my $reprints_desk = $self->find_reprints_desk_property($old->type);
            if ($reprints_desk) {
                $new_attributes->{$reprints_desk} = $old->value;
            }
        }
        $new_attributes->{migrated_from} = $original_request->illrequest_id;
        while ( my ( $type, $value ) = each %{$new_attributes} ) {
            Koha::Illrequestattribute->new(
                {
                    illrequest_id => $new_request->illrequest_id,
                    type          => $type,
                    value         => $value,
                    readonly      => 0
                }
            )->store;
        }

        return {
            error   => 0,
            status  => '',
            message => '',
            method  => 'migrate',
            stage   => 'commit',
            next    => 'emigrate',
            value   => $params,
            field_map => $self->fieldmap_sorted,
            field_map_json => to_json($self->fieldmap)
        };
    
    } elsif ($stage eq 'emigrate') {
        # We need to update our local submission
        # Get the request we've migrated from
        my $new_request = $params->{request};
        my $from_id = $new_request->illrequestattributes->find(
            { type => 'migrated_from' } )->value;
        my $request = Koha::Illrequests->find($from_id);        

        $self->cancel({ request => $request });        

        return {
            error   => 0,
            status  => '',
            message => '',
            method  => 'migrate',
            stage   => 'commit',
            next    => 'illview',
            value   => $params,
            field_map => $self->fieldmap_sorted,
            field_map_json => to_json($self->fieldmap)
        };
    }
}

=head3 _validate_metadata

Ensure the metadata we've got conforms to the order
API specification

=cut

sub _validate_metadata {
    my ($self, $metadata) = @_;

    my $valid = 0;
    if ($metadata->{countrycode} eq 'US') {
        $valid = $metadata->{statecode} && length $metadata->{statecode} > 0;
    } else {
        $valid = $metadata->{statename} && length $metadata->{statename} > 0;
    }
    return $valid;
}

=head3 create_submission

Create a local submission, for later Reprints Desk request creation

=cut

sub create_submission {
    my ($self, $params) = @_;

    my $patron = Koha::Patrons->find( $params->{other}->{borrowernumber} );

    my $request = $params->{request};
    $request->borrowernumber($patron->borrowernumber);
    $request->branchcode($params->{other}->{branchcode});
    $request->status('NEW');
    $request->backend($self->name);
    $request->placed(DateTime->now);
    $request->updated(DateTime->now);

    $request->store;

    # Store the request attributes
    $self->create_illrequestattributes($request, $params->{other});
    # Now store the core equivalents
    $self->create_illrequestattributes($request, $params->{other}, 1);

    return $request;
}

=head3

Store metadata for a given request for our Reprints Desk fields

=cut

sub create_illrequestattributes {
    my ($self, $request, $metadata, $core) = @_;

    # Get the canonical list of metadata fields
    my $fields = $self->fieldmap;

    # Get any existing illrequestattributes for this request,
    # so we can avoid trying to create duplicates
    my $existing_attrs = $request->illrequestattributes->unblessed;
    my $existing_hash = {};
    foreach my $a(@{$existing_attrs}) {
        $existing_hash->{lc $a->{type}} = $a->{value};
    }
    # Iterate our list of fields
    foreach my $field (keys %{$fields}) {
        if (
            # If we're working with core metadata, check if this field
            # has a core equivalent
            (($core && $fields->{$field}->{ill}) || !$core) &&
            $metadata->{$field} &&
            length $metadata->{$field} > 0
        ) {
            my $att_type = $core ? $fields->{$field}->{ill} : $field;
            my $att_value = $metadata->{$field};
            # If core, we might need to join
            if ($core) {
                $att_value = $self->do_join($field, $metadata);
            }
            # If it doesn't already exist for this request
            if (!exists $existing_hash->{lc $att_type}) {
                my $data = {
                    illrequest_id => $request->illrequest_id,
                    type          => $att_type,
                    value         => $att_value,
                    readonly      => 0
                };
                Koha::Illrequestattribute->new($data)->store;
            }
        }
    }
}

=head3 prep_submission_metadata

Given a submission's metadata, probably from a form,
but maybe as an Illrequestattributes object,
and a partly constructed hashref, add any metadata that
is appropriate for this material type

=cut

sub prep_submission_metadata {
    my ($self, $metadata, $return) = @_;

    $return = $return //= {};

    my $metadata_hashref = {};

    if (ref $metadata eq "Koha::Illrequestattributes") {
        while (my $attr = $metadata->next) {
            $metadata_hashref->{$attr->type} = $attr->value;
        }
    } else {
        $metadata_hashref = $metadata;
    }

    # Get our canonical field list
    my $fields = $self->fieldmap;

    # Iterate our list of fields
    foreach my $field(keys %{$fields}) {
        if (
            $metadata_hashref->{$field} &&
            length $metadata_hashref->{$field} > 0
        ) {
            $metadata_hashref->{$field}=~s/  / /g;
            $return->{$field} = $metadata_hashref->{$field};
        }
    }

    return $return;
}

=head3 submit_and_request

Creates a local submission, then uses the returned ID to create
a Reprints Desk request

=cut

sub submit_and_request {
    my ($self, $params) = @_;

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
    my ($self, $submission) = @_;

    my $metadata = {};

    $metadata = $self->prep_submission_metadata(
        $submission->illrequestattributes,
        $metadata
    );

    # We may need to remove fields prior to sending the request
    my $fields = fieldmap();
    foreach my $field(keys %{$fields}) {
        if ($fields->{$field}->{no_submit}) {
            delete $metadata->{$field};
        }
    }

    # Make the request with Reprints Desk via the koha-plugin-reprintsdesk API
    my $response = $self->{_api}->Order_PlaceOrder2( $metadata, $submission->borrowernumber );

    # If the call to Reprints Desk was successful,
    # add the Reprints Desk request ID to our submission's metadata
    my $body = from_json($response->decoded_content);
    if ($response->is_success && $body->{result}->{IsSuccessful}) {
        my $request_id = $body->{result}->{orderID};
        if ($request_id && length $request_id > 0) {
            Koha::Illrequestattribute->new({
                illrequest_id => $submission->illrequest_id,
                type          => 'orderId',
                value         => $request_id
            })->store;
        }
        # Add the Reprints Desk ID to the orderid field
        $submission->orderid($request_id);
        # Update the submission status
        $submission->status('REQ')->store;

        # Log the outcome
        $self->log_request_outcome({
            outcome => 'REPRINTSDESK_REQUEST_SUCCEEDED',
            request => $submission
        });

        return { success => 1 };
    }
    # The call to Reprints Desk failed for some reason. Add the message we got back from the API
    # to the submission's Staff Notes
    $submission->append_to_note("Reprints Desk request failed:\n" . $body->{result}->{VerificationNote});

    # Log the outcome
    $self->log_request_outcome({
        outcome => 'REPRINTSDESK_REQUEST_FAILED',
        request => $submission,
        message => $body->{result}->{VerificationNote}
    });

    # Return the message
    return {
        success => 0,
        message => $body->{result}->{VerificationNote}
    };

}

=head3 confirm

A wrapper around create_request allowing us to
provide the "confirm" method required by
the status graph

=cut

sub confirm {
    my ($self, $params) = @_;

    my $return = $self->create_request($params->{request});

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
    my ($self, $params) = @_;

    if ( $self->{_logger} ) {
        # TODO: This is a transitionary measure, we have removed set_data
        # in Bug 20750, so calls to it won't work. But since 20750 is
        # only in 19.05+, they only won't work in earlier
        # versions. So we're temporarily going to allow for both cases
        my $payload = {
            modulename   => 'ILL',
            actionname   => $params->{outcome},
            objectnumber => $params->{request}->id,
            infos        => to_json({
                log_origin => $self->name,
                response  => $params->{message}
            })
        };
        if ($self->{_logger}->can('set_data')) {
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

=head3 metadata

Return a hashref containing canonical values from the key/value
illrequestattributes store

=cut

sub metadata {
    my ( $self, $request ) = @_;

    my $attrs = $request->illrequestattributes;
    my $fields = $self->fieldmap;

    my $metadata = {};
    my $metadata_keyed_on_prop = {};

    while (my $attr = $attrs->next) {
        if ($fields->{$attr->type}) {
            my $label = $fields->{$attr->type}->{label};
            $metadata->{$label} = $attr->value;
            $metadata_keyed_on_prop->{$attr->type} = $attr->value;
        }
    }

    # OPAC list view uses completely different property names for author
    # and title. Cater for that.
    my $title_key = $fields->{atitle}->{label};
    # We might need to join this field with something else
    $metadata->{Author} = $self->do_join('aufirst', $metadata_keyed_on_prop);
    $metadata->{Title} = $metadata->{$title_key} if $metadata->{$title_key};

    return $metadata;
}

=head3 attach_processors

Receive a Koha::Illrequest::SupplierUpdate and attach
any processors we have for it

=cut

sub attach_processors {
    my ( $self, $update ) = @_;

    foreach my $processor(@{$self->{processors}}) {
        if (
            $processor->{target_source_type} eq $update->{source_type} &&
            $processor->{target_source_name} eq $update->{source_name}
        ) {
            $update->attach_processor($processor);
        }
    }
}

=head3 get_supplier_update

Called as a backend capability, receives a local request object
and gets the latest update from Reprints Desk using their
Order_GetOrderInfo request
Return Koha::Illrequest::SupplierUpdate representing the update

=cut

sub get_supplier_update {
    my ( $self, $params ) = @_;

    my $request = $params->{request};
    my $delay = $params->{delay};

    # Find the submission's Reprints Desk ID
    my $reprints_desk_request_id = $request->illrequestattributes->find({
        illrequest_id => $request->illrequest_id,
        type          => "orderID"
    });

    if (!$reprints_desk_request_id) {
        # No Reprints Desk request, we can't do anything
        print "Request " . $request->illrequest_id . " does not contain a Reprints Desk orderID\n";
        return;
    }

    if ($delay) {
        sleep($delay);
    }

    my $response = $self->{_api}->Order_GetOrderInfo(
        $reprints_desk_request_id->value
    );

    my $body = from_json($response->decoded_content);
    if ($response->is_success && $body->{result}->{IsSuccessful}) {
        return Koha::Illrequest::SupplierUpdate->new(
            'backend',
            $self->name,
            $body->{result},
            $request
        );
    }
}

=head3 capabilities

    $capability = $backend->capabilities($name);

Return the sub implementing a capability selected by NAME, or 0 if that
capability is not implemented.

=cut

sub capabilities {
    my ( $self, $name ) = @_;
    my ($query) = @_;
    my $capabilities = {
        # View and manage a request
        illview => sub { illview(@_); },
        # Migrate
        migrate => sub { $self->migrate(@_); },
        # Return whether we are ready to display availability
        should_display_availability => sub { _can_create_request(@_) },
        get_supplier_update => sub { $self->get_supplier_update(@_) }
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
            prev_actions   => [ 'NEW' ],
            id             => 'EDITITEM',
            name           => 'Edited item metadata',
            ui_method_name => 'Edit item metadata',
            method         => 'edititem',
            next_actions   => [],
            ui_method_icon => 'fa-edit',
        },
        # Override REQ so we can rename the button
        # Talk about a sledgehammer to crack a nut
        REQ => {
            prev_actions   => [ 'NEW', 'REQREV', 'QUEUED', 'CANCREQ' ],
            id             => 'REQ',
            name           => 'Requested',
            ui_method_name => 'Request from Reprints Desk',
            method         => 'confirm',
            next_actions   => [ 'REQREV', 'COMP', 'CHK' ],
            ui_method_icon => 'fa-check',
        },
        MIG => {
            prev_actions =>
              [ 'NEW', 'REQ', 'GENREQ', 'REQREV', 'QUEUED', 'CANCREQ', ],
            id             => 'MIG',
            name           => 'Switched provider',
            ui_method_name => 'Switch provider',
            method         => 'migrate',
            next_actions   => [],
            ui_method_icon => 'fa-search',
        },        
    };
}

sub name {
    return "ReprintsDesk";
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

=head3 find_reprints_desk_property

Given a core property name, find the equivalent Reprints Desk
name. Or undef if there is not one

=cut

sub find_reprints_desk_property {
    my ($self, $core) = @_;
    my $fields = $self->fieldmap;
    foreach my $field(keys %{$fields}) {
        if ($fields->{$field}->{ill} && $fields->{$field}->{ill} eq $core) {
            return $field;
        }
    }
}

=head3 _openurl_to_ill

Take a hashref of OpenURL parameters and return
those same parameters but transformed to the ILL
schema

=cut

sub _openurl_to_ill {
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
        pmid    => 'pmid',
        title   => 'title',
        pages   => 'pages'
    };

    my $return = {};
    # First make sure our keys are correct
    foreach my $meta_key(keys %{$params->{other}}) {
        # If we are transforming this property...
        if (exists $transform_metadata->{$meta_key}) {
            # ...do it if we have valid mapping
            if (length $transform_metadata->{$meta_key} > 0) {
                $return->{$transform_metadata->{$meta_key}} = $params->{other}->{$meta_key};
            }
        } else {
            # Otherwise, pass it through untransformed
            $return->{$meta_key} = $params->{other}->{$meta_key};
        }
    }
    $params->{other} = $return;
    return $params;
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

    foreach my $key (sort {
        $fields->{$a}->{position} <=> $fields->{$b}->{position}
    } keys %{$fields}) {
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
  exclude = Do not include on the entry form
  type = Does an element contain a string value or an array of string values?
  label = Display label
  ill   = The core ILL equivalent field
  help = Display help text

=cut

sub fieldmap {
    return {
        title => {
            type      => "string",
            label     => "Journal title",
            ill       => "title",
            position  => 0
        },
        atitle => {
            type      => "string",
            label     => "Article title",
            ill       => "article_title",
            position  => 1
        },
        aufirst => {
            type      => "string",
            label     => "Author's first name",
            ill       => "article_author",
            position  => 2,
            join      => "aulast"
        },
        aulast => {
            no_submit => 1,
            type      => "string",
            label     => "Author's last name",
            position  => 3
        },
        volume => {
            type      => "string",
            label     => "Volume number",
            ill       => "volume",
            position  => 4
        },
        issue => {
            type      => "string",
            label     => "Journal issue number",
            ill       => "issue",
            position  => 5
        },
        date => {
            type      => "string",
            ill       => "item_date",
            position  => 7,
            label     => "Item publication date"
        },
        pages => {
            type      => "string",
            label     => "Pages in journal",
            ill       => "pages",
            position  => 8
        },
        spage => {
            type      => "string",
            label     => "First page of article in journal",
            ill       => "spage",
            position  => 8
        },
        epage => {
            type      => "string",
            label     => "Last page of article in journal",
            ill       => "epage",
            position  => 9
        },
        doi => {
            type      => "string",
            label     => "DOI",
            ill       => "doi",
            position  => 10
        },
        pmid => {
            type      => "string",
            label     => "PubMed ID",
            ill       => "pmid",
            position  => 11
        },
        isbn => {
            type      => "string",
            label     => "ISBN",
            ill       => "isbn",
            position  => 12
        },
        issn => {
            type      => "string",
            label     => "ISSN",
            ill       => "issn",
            position  => 13
        },
        eissn => {
            type      => "string",
            label     => "EISSN",
            ill       => "eissn",
            position  => 14
        },
        countrycode => {
            type      => "string",
            label     => "Country code of requester",
            ill       => "countrycode",
            position  => 15
        },
        statecode => {
            type      => "string",
            label     => "Two letter state code of requester",
            ill       => "statecode",
            position  => 16
        },
        statename => {
            type      => "string",
            label     => "State name of requester",
            ill       => "statename",
            position  => 17
        },
        ordertypeid => {
            hide      => 1,
            type      => "string",
            position  => 98 
        },
        deliverymethodid => {
            hide      => 1,
            type      => "string",
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
        $brws = $patrons->search( { $criterium => $input } );
        $count = $brws->count;
    }
    if ( $count == 1 ) {
        $brw = $brws->next;
    }
    else {
        $brw = $brws;    # found multiple results
    }
    return ( $count, $brw );
}


1;
