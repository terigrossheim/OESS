package OESS::Cloud::GCP;

use strict;
use warnings;

use Data::Dumper;
use HTML::Entities;
use JSON;
use JSON::WebToken;
use Log::Log4perl;
use LWP::UserAgent;
use XML::Simple;

=head1 OESS::Cloud::GCP

B<Configuration:>

The credentials for each interconnect must be defined under the
C<cloud> tag in C</etc/oess/database.xml>. Valid interconnect types
for GCP connections are C<gcp-partner-interconnect>. GCP interconnects
should pass a path to service account credentials via
C<google_application_credentials>. To generate these credentials see
https://cloud.google.com/docs/authentication/production#obtaining_and_providing_service_account_credentials_manually

    <connection region="us-east-1"
                interconnect_type="gcp-partner-interconnect"
                interconnect_id="https://www.googleapis.com/..."
                google_application_credentials="/etc/oess/gapi.conf",
                workgroup="GCP" />

Associate credentials with a physical endpoint by setting the
C<interconnect_id> of the interface in the OESS database.

=cut

=head2 new

    my $gcp = OESS::Cloud::GCP->new();

=cut
sub new {
    my $class = shift;
    my %params = @_;

    my $self = bless {
        config => '/etc/oess/database.xml',
        logger => Log::Log4perl->get_logger('OESS.Cloud.GCP'),
        @_
    }, $class;

    $self->{creds} = XML::Simple::XMLin($self->{config});
    $self->{connections} = {};

    my $coder = JSON->new;

    foreach my $conn (@{$self->{creds}->{cloud}->{connection}}) {
        if ($conn->{interconnect_type} ne 'gcp-partner-interconnect') {
            next;
        }

        my $json = do {
            open(my $json_fh, "<:encoding(UTF-8)", $conn->{google_application_credentials})
                or die("Can't open \$conn->{google_application_credentials}\": $!\n");
            local $/;
            <$json_fh>
        };
        my $config = $coder->decode($json);

        $conn->{client_email} = $config->{client_email};
        $conn->{private_key}  = $config->{private_key};
        $conn->{project_id}   = $config->{project_id};
        $conn->{token_uri}    = $config->{token_uri};

        my $time = time;
        my $jwt = JSON::WebToken->encode(
            {
                iss => $conn->{client_email},
                scope => 'https://www.googleapis.com/auth/compute',
                aud => $conn->{token_uri},
                exp => $time + 3600,
                iat => $time,
                prn => $conn->{client_email}
            },
            $conn->{private_key},
            'RS256',
            { typ => 'JWT' }
        );

        my $ua = LWP::UserAgent->new();
        my $response = $ua->post(
            $conn->{token_uri},
            {
                grant_type => encode_entities('urn:ietf:params:oauth:grant-type:jwt-bearer'),
                assertion => $jwt
            }
        );
        if (!$response->is_success()) {
            $self->{logger}->error($response->content);
            next;
        }

        my $data = decode_json($response->content);
        $conn->{access_token} = $data->{access_token};

        $conn->{http} = LWP::UserAgent->new();
        $conn->{http}->default_header(Authorization => "Bearer $conn->{access_token}");

        $self->{connections}->{$conn->{interconnect_id}} = $conn;
    }

    return $self;
}

=head2 get_interconnect_attachments

get_interconnect_attachments returns a list of all attachments
associated with C<interconnect_id>'s project and region. Not that it
may be possible that attachments associated with other interconnects
are also returned.

    my $resp = get_interconnect_attachments(
        interconnect_id => "https://www.googleapis.com/..."
    );

=cut
sub get_interconnect_attachments {
    my $self = shift;
    my %params = @_;

    my $interconnect_id = $params{interconnect_id};

    my $conn    = $self->{connections}->{$interconnect_id};
    my $http    = $conn->{http};
    my $project = $conn->{project_id};
    my $region  = $conn->{region};

    my $api_response = $http->get("https://www.googleapis.com/compute/v1/projects/$project/regions/$region/interconnectAttachments");
    if (!$api_response->is_success) {
        warn "Error:\n";
        warn "Code was ", $api_response->code, "\n";
        warn "Msg: ", $api_response->message, "\n";
        warn $api_response->content, "\n";
        die;
    }

    my $api_data = decode_json($api_response->content);
    # TODO: Find failure modes and log as error
    warn Dumper($api_data);
    return $api_data;
}

=head2 delete_interconnect_attachment

delete_interconnect_attachment removes the GCP interconnect attachment
C<connection_id>. Once deleted, the underly VLAN will once again be
available for provisioning.

    my $resp = delete_interconnect_attachment(
        interconnect_id => "https://www.googleapis.com/...",
        connection_id   => "" # Interconnect attachment name
    );

=cut
sub delete_interconnect_attachment {
    my $self = shift;
    my %params = @_;

    my $interconnect_id = $params{interconnect_id};
    my $attachment_name = $params{connection_id};

    my $conn    = $self->{connections}->{$interconnect_id};
    my $http    = $conn->{http};
    my $project = $conn->{project_id};
    my $region  = $conn->{region};

    my $api_response = $http->delete("https://www.googleapis.com/compute/v1/projects/$project/regions/$region/interconnectAttachments/$attachment_name");
    if (!$api_response->is_success) {
        warn "Error:\n";
        warn "Code was ", $api_response->code, "\n";
        warn "Msg: ", $api_response->message, "\n";
        warn $api_response->content, "\n";
        die;
    }

    my $api_data = decode_json($api_response->content);
    # TODO: Find failure modes and log as error
    warn Dumper($api_data);
    return $api_data;
}

=head2 insert_interconnect_attachment

    my $resp = insert_interconnect_attachment(
        interconnect_id   => "https://www.googleapis.com/...",
        interconnect_name => "rtsw.chic.net.internet2.edu - xe-7/0/1",    # Optional metadata
        bandwidth     => "BPS_50M",
        connection_id => "GCP L3VPN 1",                                   # Interconnect attachment name
        pairing_key => "00000000-0000-0000-0000-000000000000/us-east1/1",
        portal_url  => "https://al2s.net.internet2.edu/...",              # Optional metadata
        vlan        => 300
    );

insert_interconnect_attachment creates a new GCP interconnect
attachment under project C<$self->{config}->{project_id}> that's
associated with the customers C<pairing_key>.

After a small period of time, the information required to configure a
BGP peering will be available via C<get_interconnect_attachement>.

Once the BGP peering has been configured by OESS and the customer
approves the interconnect attachement created by this method traffic
can be forwarded.

=cut
sub insert_interconnect_attachment {
    my $self = shift;
    my %params = @_;

    my $cloud_interconnect_id   = $params{interconnect_id};
    my $cloud_interconnect_name = $params{interconnect_name} || "";
    my $bandwidth     = $params{bandwidth};
    my $connection_id = $params{connection_id};
    my $pairing_key = $params{pairing_key};
    my $portal_url  = $params{portal_url} || "https://al2s.net.internet2.edu/oess/";
    my $vlan        = $params{vlan};

    my $conn    = $self->{connections}->{$cloud_interconnect_id};
    my $http    = $conn->{http};
    my $project = $conn->{project_id};
    my $region  = $conn->{region};

    my $payload = {
        name            => $connection_id,
        interconnect    => $cloud_interconnect_id,
        type            => "PARTNER_PROVIDER",
        pairingKey      => $pairing_key,
        vlanTag8021q    => $vlan,
        bandwidth       => $bandwidth,
        partnerAsn      => 55038,
        partnerMetadata => {
            partnerName      => "Internet2",
            interconnectName => $cloud_interconnect_name,
            portalUrl        => $portal_url
        }
    };

    my $req = HTTP::Request->new("POST", "https://www.googleapis.com/compute/v1/projects/$project/regions/$region/interconnectAttachments");
    $req->header("Content-Type" => "application/json");
    $req->content( encode_json($payload) );

    my $api_response = $http->request($req);
    if (!$api_response->is_success) {
        # TODO Handle errors better

        warn "Error:\n";
        warn "Code was ", $api_response->code, "\n";
        warn "Msg: ", $api_response->message, "\n";
        warn $api_response->content, "\n";
        die;
    }

    my $api_data = decode_json($api_response->content);
    # TODO: Find failure modes and log as error
    warn Dumper($api_data);
    return $api_data;
}

return 1;
