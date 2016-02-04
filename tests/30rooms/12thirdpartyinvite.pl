my $invitee_email = 'lemurs@monkeyworld.org';

test "Can invite existing 3pid",
   requires => [ local_user_fixtures( 2 ), id_server_fixture() ],

   do => sub {
      my ( $inviter, $invitee, $id_server ) = @_;

      my $invitee_mxid = $invitee->user_id;

      my $room_id;

      $id_server->bind_identity( undef, "email", $invitee_email, $invitee )
      ->then( sub {
         matrix_create_and_join_room( [ $inviter ], visibility => "private" )
      })->then( sub {
         ( $room_id ) = @_;

         do_request_json_for( $inviter,
            method => "POST",
            uri    => "/r0/rooms/$room_id/invite",

            content => {
               id_server    => $id_server->name,
               medium       => "email",
               address      => $invitee_email,
            },
         );
      })->then( sub {
         matrix_get_room_state( $inviter, $room_id,
            type      => "m.room.member",
            state_key => $invitee_mxid,
         );
      })->on_done( sub {
         my ( $body ) = @_;

         log_if_fail "Body", $body;
         assert_eq( $body->{membership}, "invite",
            'invited user membership' );
      });
   };

test "Can invite existing 3pid in createRoom",
   requires => [ local_user_fixtures( 2 ), id_server_fixture() ],

   do => sub {
      my ( $inviter, $invitee, $id_server ) = @_;

      my $invitee_mxid = $invitee->user_id;

      my $room_id;

      $id_server->bind_identity( undef, "email", $invitee_email, $invitee )
      ->then( sub {
         my $invite_info = {
            medium    => "email",
            address   => $invitee_email,
            id_server => $id_server->name,
         };
         matrix_create_room( $inviter, invite_3pid => [ $invite_info ] );
      })->then( sub {
         ( $room_id ) = @_;

         matrix_get_room_state( $inviter, $room_id,
            type      => "m.room.member",
            state_key => $invitee_mxid,
         );
      })->on_done( sub {
         my ( $body ) = @_;

         log_if_fail "Body", $body;
         assert_eq( $body->{membership}, "invite",
            'invited user membership' );
      });
   };


test "Can invite unbound 3pid",
   requires => [ local_user_fixtures( 2 ), $main::HOMESERVER_INFO[0],
                 id_server_fixture() ],

   do => sub {
      my ( $inviter, $invitee, $info, $id_server ) = @_;
      my $hs_uribase = $info->client_location;

      can_invite_unbound_3pid( $inviter, $invitee, $hs_uribase, $id_server );
   };

test "Can invite unbound 3pid over federation",
   requires => [ local_user_fixture(), remote_user_fixture(),
                 $main::HOMESERVER_INFO[1], id_server_fixture() ],

   do => sub {
      my ( $inviter, $invitee, $info, $id_server ) = @_;
      my $hs_uribase = $info->client_location;

      can_invite_unbound_3pid( $inviter, $invitee, $hs_uribase, $id_server );
   };

sub can_invite_unbound_3pid
{
   my ( $inviter, $invitee, $hs_uribase, $id_server ) = @_;

   my $room_id;

   matrix_create_room( $inviter, visibility => "private" )
   ->then( sub {
      ( $room_id ) = @_;

      do_3pid_invite( $inviter, $room_id, $id_server->name, $invitee_email )
   })->then( sub {
      $id_server->bind_identity( $hs_uribase, "email", $invitee_email, $invitee );
   })->then( sub {
      matrix_get_room_state( $inviter, $room_id,
         type      => "m.room.member",
         state_key => $invitee->user_id,
      )
   })->then( sub {
      my ( $body ) = @_;

      log_if_fail "m.room.member invite", $body;
      assert_eq( $body->{third_party_invite}{display_name}, 'Bob', 'invite display name' );

      matrix_join_room( $invitee, $room_id )
   })->then( sub {
      matrix_get_room_state( $inviter, $room_id,
         type      => "m.room.member",
         state_key => $invitee->user_id,
      )
   })->followed_by( assert_membership( "join" ) );
}

test "Can accept unbound 3pid invite after inviter leaves",
   requires => [ local_user_fixtures( 3 ), $main::HOMESERVER_INFO[0],
                    id_server_fixture() ],

   do => sub {
      my ( $inviter, $other_member, $invitee, $info, $id_server ) = @_;
      my $hs_uribase = $info->client_location;

      my $room_id;

      matrix_create_room( $inviter, visibility => "private" )
      ->then( sub {
         ( $room_id ) = @_;

          matrix_invite_user_to_room( $inviter, $other_member, $room_id );
      })->then( sub {
          matrix_join_room( $other_member, $room_id );
      })->then( sub {
         do_3pid_invite( $inviter, $room_id, $id_server->name, $invitee_email )
      })->then( sub {
         matrix_leave_room( $inviter, $room_id );
      })->then( sub {
         $id_server->bind_identity( $hs_uribase, "email", $invitee_email, $invitee );
      })->then( sub {
         matrix_join_room( $invitee, $room_id )
      })->then( sub {
         matrix_get_room_state( $other_member, $room_id,
            type      => "m.room.member",
            state_key => $invitee->user_id,
         )
      })->followed_by( assert_membership( "join" ) );
   };

test "3pid invite join with wrong but valid signature are rejected",
   requires => [ local_user_fixtures( 2 ), $main::HOMESERVER_INFO[0],
                    id_server_fixture() ],

   do => sub {
      my ( $inviter, $invitee, $info, $id_server ) = @_;
      my $hs_uribase = $info->client_location;

      invite_should_fail( $inviter, $invitee, $hs_uribase, $id_server, sub {
         $id_server->rotate_keys;
         $id_server->bind_identity( $hs_uribase, "email", $invitee_email, $invitee );
      });
   };

test "3pid invite join valid signature but revoked keys are rejected",
   requires => [ local_user_fixtures( 2 ), $main::HOMESERVER_INFO[0],
                    id_server_fixture() ],

   do => sub {
      my ( $inviter, $invitee, $info, $id_server ) = @_;
      my $hs_uribase = $info->client_location;

      invite_should_fail( $inviter, $invitee, $hs_uribase, $id_server, sub {
         $id_server->bind_identity( $hs_uribase, "email", $invitee_email, $invitee,
            sub { $id_server->rotate_keys } );
      });
   };

test "3pid invite join valid signature but unreachable ID server are rejected",
   requires => [ local_user_fixtures( 2 ), $main::HOMESERVER_INFO[0],
                    id_server_fixture() ],

   do => sub {
      my ( $inviter, $invitee, $info, $id_server ) = @_;
      my $hs_uribase = $info->client_location;

      invite_should_fail( $inviter, $invitee, $hs_uribase, $id_server, sub {
         $id_server->bind_identity( $hs_uribase, "email", $invitee_email, $invitee, sub {
            # Stop the server listening by taking its handle away
            $id_server->configure( handle => undef );
         });
      });
   };

sub invite_should_fail {
   my ( $inviter, $invitee, $hs_base_url, $id_server, $bind_sub ) = @_;

   my $room_id;

   matrix_create_room( $inviter, visibility => "private" )
   ->then( sub {
      ( $room_id ) = @_;

      do_3pid_invite( $inviter, $room_id, $id_server->name, $invitee_email )
   })->then( sub {
      $bind_sub->( $id_server );
   })->then( sub {
      matrix_join_room( $invitee, $room_id )
         ->main::expect_http_4xx
   })->then( sub {
      matrix_get_room_state( $inviter, $room_id,
         type      => "m.room.member",
         state_key => $invitee->user_id,
      )
   })->followed_by(assert_membership( undef ) );
}

sub assert_membership {
   my ( $expected_membership ) = @_;

   my $verifier = defined $expected_membership
      ? sub {
         my ( $f ) = @_;

         $f->then( sub {
            my ( $body ) = @_;

            log_if_fail "Body", $body;
            $body->{membership} eq $expected_membership or
               die "Expected invited user membership to be '$expected_membership'";

            Future->done( 1 );
         } )
      }
      : \&main::expect_http_error;
}

sub do_3pid_invite {
   my ( $inviter, $room_id, $id_server, $invitee_email ) = @_;

   do_request_json_for( $inviter,
      method  => "POST",
      uri     => "/r0/rooms/$room_id/invite",
      content => {
         id_server    => $id_server,
         medium       => "email",
         address      => $invitee_email,
      }
   )
}

