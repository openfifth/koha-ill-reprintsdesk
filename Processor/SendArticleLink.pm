package Koha::Illbackends::ReprintsDesk::Processor::SendArticleLink;

use Modern::Perl;
use POSIX;

use parent qw(Koha::Illrequest::SupplierUpdateProcessor);

sub new {
    my ( $class ) = @_;
    my $self = $class->SUPER::new('backend', 'ReprintsDesk', 'Send article link');
    bless $self, $class;
    return $self;
}

sub run {
    my ( $self, $update, $status ) = @_;
    # Parse the update
    # Look for the pertinent elements
    # Create a notice
    # Queue the notice
    # Add an update to the staff notes with timestamp of notice creation
    # Update the request status to Completed
    my $update_body = $update->{update};
    my $request = $update->{request};

    # Get the elements we need
    my $address = $update_body->{ArticleExchangeAddress};
    my $password = $update_body->{ArticleExchangePassword};

    # If we've not got what we need, record that fact and bail
    if (length $address == 0 || length $password == 0) {
        push @{$status->{error}}, "Unable to access article address and/or password";
        return $status;
    }

    my $update_text = <<"END_MESSAGE";
    Your request has been fulfilled, it can be accessed here:
    URL: $address
    Password: $password
END_MESSAGE

    # Try to send the notice
    my $ret = $request->send_patron_notice(
        'ILL_REQUEST_UPDATE',
        $update_text
    );

    my $timestamp = POSIX::strftime("%d/%m/%Y %H:%M:%S\n", localtime);
    # Update the passed hashref with how we got on
    if ($ret->{result} && scalar @{$ret->{result}->{success}} > 0) {
        # Record success        
        push @{$status->{success}}, join(',', @{$ret->{result}->{success}});
        # Add a note to the request
        $request->append_to_note("Fulfilment notice sent to patron at $timestamp");
        # Set the status to completed
        $request->status('COMP');
    }
    if ($ret->{result} && scalar @{$ret->{result}->{fail}} > 0) {
        # Record the problem
        push @{$status->{error}}, join(',', @{$ret->{result}->{fail}});
        # Add a note to the request
        $request->append_to_note("Unable to send fulfilment notice to patron at $timestamp");
    }
}

1;