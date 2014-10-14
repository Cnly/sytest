my $displayname = "Testing Displayname";

test "PUT /profile/:user_id/displayname sets my name",
   requires => [qw( first_http_client can_login )],

   check => sub {
      my ( $http, $login ) = @_;
      my ( $user_id, $access_token ) = @$login;

      $http->do_request_json(
         method => "GET",
         uri    => "/profile/$user_id/displayname",
         params => { access_token => $access_token },
      )->then( sub {
         my ( $body ) = @_;

         ref $body eq "HASH" or die "Expected JSON object\n";

         defined $body->{displayname} or die "Expected 'displayname'\n";

         $body->{displayname} eq $displayname or die "Wrong displayname\n";

         provide can_set_displayname => 1;

         Future->done(1);
      });
   },

   do => sub {
      my ( $http, $login ) = @_;
      my ( $user_id, $access_token ) = @$login;

      $http->do_request_json(
         method => "PUT",
         uri    => "/profile/$user_id/displayname",
         params => { access_token => $access_token },

         content => {
            displayname => $displayname,
         },
      );
   };

test "GET /profile/:user_id/displayname publicly accessible",
   requires => [qw( first_http_client can_login can_set_displayname )],

   check => sub {
      my ( $http, $login ) = @_;
      my ( $user_id ) = @$login;

      $http->do_request_json(
         method => "GET",
         uri    => "/profile/$user_id/displayname",
         # no access_token
      )->then( sub {
         my ( $body ) = @_;

         ref $body eq "HASH" or die "Expected JSON object\n";

         defined $body->{displayname} or die "Expected 'displayname'\n";

         $body->{displayname} eq $displayname or die "Wrong displayname\n";

         Future->done(1);
      });
   };
