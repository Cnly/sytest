test "POST /rooms/:room_id/join can join a room",
   requires => [qw( do_request_json_for more_users room_id
                    can_initial_sync )],

   do => sub {
      my ( $do_request_json_for, $more_users, $room_id ) = @_;
      my $user = $more_users->[0];

      $do_request_json_for->( $user,
         method => "POST",
         uri    => "/rooms/$room_id/join",

         content => {},
      );
   },

   check => sub {
      my ( $do_request_json_for, $more_users, $room_id ) = @_;
      my $user = $more_users->[0];

      $do_request_json_for->( $user,
         method => "GET",
         uri    => "/initialSync",
      )->then( sub {
         my ( $body ) = @_;

         json_list_ok( $body->{rooms} );

         my $found;
         foreach my $room ( @{ $body->{rooms} } ) {
            json_keys_ok( $room, qw( room_id membership ));

            next unless $room->{room_id} eq $room_id;
            $found++;

            $room->{membership} eq "join" or
               die "Expected room membership to be 'join'";
         }

         $found or
            die "Failed to find expected room";

         provide can_join_room_by_id => 1;

         Future->done(1);
      });
   };

test "POST /join/:room_alias can join a room",
   requires => [qw( do_request_json_for more_users room_id room_alias
                    can_initial_sync )],

   do => sub {
      my ( $do_request_json_for, $more_users, undef, $room_alias ) = @_;
      my $user = $more_users->[1];

      $do_request_json_for->( $user,
         method => "POST",
         uri    => "/join/$room_alias",
         params => { access_token => $user->access_token },

         content => {},
      );
   },

   check => sub {
      my ( $do_request_json_for, $more_users, $room_id ) = @_;
      my $user = $more_users->[1];

      $do_request_json_for->( $user,
         method => "GET",
         uri    => "/initialSync",
         params => { access_token => $user->access_token },
      )->then( sub {
         my ( $body ) = @_;

         json_list_ok( $body->{rooms} );

         my $found;
         foreach my $room ( @{ $body->{rooms} } ) {
            json_keys_ok( $room, qw( room_id membership ));

            next unless $room->{room_id} eq $room_id;
            $found++;

            $room->{membership} eq "join" or
               die "Expected room membership to be 'join'";
         }

         $found or
            die "Failed to find expected room";

         provide can_join_room_by_alias => 1;

         Future->done(1);
      });
   };
