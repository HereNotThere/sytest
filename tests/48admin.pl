use Future::Utils qw( repeat );
use Time::HiRes qw( time );
use URI::Escape qw( uri_escape );


# poll the status endpoint until it completes. Returns the final status.
sub await_purge_complete {
   my ( $admin_user, $purge_id ) = @_;

   my $delay = 0.1;

   return repeat( sub {
      my ( $prev_trial ) = @_;

      # delay if this isn't the first time around the loop
      (
         $prev_trial ? delay( $delay *= 1.5 ) : Future->done
      )->then( sub {
         do_request_json_for( $admin_user,
            method   => "GET",
            full_uri => "/_synapse/admin/v1/purge_history_status/$purge_id",
         )
      })->then( sub {
         my ($body) = @_;
         assert_json_keys( $body, "status" );
         Future->done( $body->{status} );
      })
   }, while => sub { $_[0]->get eq 'active' });
}

test "/whois",
   requires => [ $main::API_CLIENTS[0] ],

   do => sub {
      my ( $http ) = @_;

      my $user;

      # Register a user, rather than using a fixture, because we want to very
      # tightly control the actions taken by that user.
      # Conceivably this API may change based on the number of API calls the
      # user made, for instance.

      matrix_register_user( $http, "admin" )
      ->then( sub {
         ( $user ) = @_;

         # Synapse flushes IP addresses to the database every 5 seconds, so we
         # need to keep checking because the IP address won't appear for a few
         # seconds (unless the worker that flushes the IP addresses is the same
         # as the one that handles /whois).
         repeat_until_true sub {
            do_request_json_for( $user,
               method => "GET",
               uri    => "/v3/admin/whois/".$user->user_id,
            )->then( sub {
               my ( $body ) = @_;

               assert_json_keys( $body, qw( devices user_id ) );
               assert_eq( $body->{user_id}, $user->user_id, "user_id" );
               assert_json_object( $body->{devices} );

               # Whether we've found a connection with the right keys
               # (ip, last_seen, user_agent).
               my $found_connections = 0;

               foreach my $value ( values %{ $body->{devices} } ) {
                  assert_json_keys( $value, "sessions" );
                  assert_json_list( $value->{sessions} );
                  assert_json_keys( $value->{sessions}[0], "connections" );
                  assert_json_list( $value->{sessions}[0]{connections} );
                  # The `connections` may not yet be populated. If there *is* a connection,
                  # we check that it has the right shape. If `connections` is still empty, we
                  # tell `repeat_until_true` to retry by returning a falsey value.
                  foreach my $connection ( @{ $value->{sessions}[0]{connections} } ) {
                     assert_json_keys(
                        $connection,
                        qw( ip last_seen user_agent )
                     );

                     $found_connections = 1;
                  }
               }

               Future->done( $found_connections );
            });
         }, initial_delay => 0.5;
      });
   };

test "/purge_history",
   requires => [ local_admin_fixture(), local_user_and_room_fixtures() ],
   implementation_specific => ['synapse'],

   do => sub {
      my ( $admin, $user, $room_id ) = @_;

      my $last_event_id;

      matrix_put_room_state( $user, $room_id,
         type    => "m.room.name",
         content => { name => "A room name" },
      )->then( sub {
         matrix_sync( $user )
      })->then( sub {
         repeat( sub {
            my $msgnum = $_[0];

            matrix_send_room_text_message_synced( $user, $room_id,
               body => "Message $msgnum",
            )
         }, foreach => [ 1 .. 10 ])
      })->then( sub {
         ( $last_event_id ) = @_;

         await_message_in_room( $user, $room_id, $last_event_id ),
      })->then( sub {
         do_request_json_for( $user,
            method   => "POST",
            full_uri => "/_synapse/admin/v1/purge_history/$room_id/${ \uri_escape( $last_event_id ) }",
            content  => {}
         )->main::expect_http_403;  # Must be server admin
      })->then( sub {
         do_request_json_for( $admin,
            method   => "POST",
            full_uri => "/_synapse/admin/v1/purge_history/$room_id/${ \uri_escape( $last_event_id ) }",
            content  => {}
         )
      })->then( sub {
         my ( $body ) = @_;

         assert_json_keys( $body, "purge_id" );
         my $purge_id = $body->{purge_id};
         await_purge_complete( $admin, $purge_id );
      })->then( sub {
         my ( $purge_status ) = @_;
         assert_eq( $purge_status, 'complete' );

         # Test that /sync with an existing token still works.
         matrix_sync_again( $user )
      })->then( sub {
         # Test that an initial /sync has the correct data.
         matrix_sync( $user )
      })->then( sub {
         my ( $body ) = @_;

         assert_json_keys( $body->{rooms}{join}, $room_id );
         my $room =  $body->{rooms}{join}{$room_id};

         log_if_fail( "Room", $room->{timeline}{events} );

         # The only message event should be the last one.
         all {
            $_->{type} ne "m.room.message" || $_->{event_id} eq $last_event_id
         } @{ $room->{timeline}{events} } or die "Expected no message events";

         # Ensure we still see the state.
         foreach my $expected_type( qw(
            m.room.create
            m.room.member
            m.room.power_levels
            m.room.name
         ) ) {
            any { $_->{type} eq $expected_type } @{ $room->{state}{events} }
               or die "Expected state event of type $expected_type";
         }

         Future->done( 1 );
      })
   };

test "/purge_history by ts",
   requires => [ local_admin_fixture(), local_user_and_room_fixtures() ],
   implementation_specific => ['synapse'],

   do => sub {
      my ( $admin, $user, $room_id ) = @_;

      my ($last_event_id, $last_event_ts);

      # we send 9 messages, get the current ts, and
      # then send one more.
      matrix_put_room_state( $user, $room_id,
         type    => "m.room.name",
         content => { name => "A room name" },
      )->then( sub {
         matrix_sync( $user )
      })->then( sub {
         repeat( sub {
            my $msgnum = $_[0];

            matrix_send_room_text_message_synced( $user, $room_id,
               body => "Message $msgnum",
            )
         }, foreach => [ 1 .. 9 ])
      })->then( sub {
         $last_event_ts = time();
         delay(0.01);
      })->then( sub {
         matrix_send_room_text_message_synced( $user, $room_id,
            body => "Message 10",
         );
      })->then( sub {
         ( $last_event_id ) = @_;
         await_message_in_room( $user, $room_id, $last_event_id ),
      })->then( sub {
         do_request_json_for( $admin,
            method   => "POST",
            full_uri => "/_synapse/admin/v1/purge_history/$room_id",
            content  => {
               purge_up_to_ts => int($last_event_ts * 1000),
            },
         )
      })->then( sub {
         my ( $body ) = @_;

         assert_json_keys( $body, "purge_id" );
         my $purge_id = $body->{purge_id};
         await_purge_complete( $admin, $purge_id );
      })->then( sub {
         my ( $purge_status ) = @_;
         assert_eq( $purge_status, 'complete' );

         # Test that /sync with an existing token still works.
         matrix_sync_again( $user )
      })->then( sub {
         # Test that an initial /sync has the correct data.
         matrix_sync( $user )
      })->then( sub {
         my ( $body ) = @_;

         assert_json_keys( $body->{rooms}{join}, $room_id );
         my $room =  $body->{rooms}{join}{$room_id};

         log_if_fail( "Room", $room->{timeline}{events} );

         # The only message event should be the last one.
         all {
            $_->{type} ne "m.room.message" || $_->{event_id} eq $last_event_id
         } @{ $room->{timeline}{events} } or die "Expected no message events";
         Future->done( 1 );
      })
   };

test "Can backfill purged history",
   # we create three users:
   #  - an admin on server 0
   #  - a room creator on server 0
   #  - a second room member on server 1
   #
   # We then send a bunch of messages on both servers (and make sure that
   # they are received at both ends).
   #
   # We then purge the events on server 0, and do an initialsync to check
   # that the events were actually purged.
   #
   # Finally, we back-paginate on server 0. It should backfill the purged events
   # from server 1 and return them to us.

   requires => [ local_admin_fixture(), local_user_and_room_fixtures(),
                 remote_user_fixture(), qw( can_paginate_room_remotely ) ],
   implementation_specific => ['synapse'],

   # this test is a bit slow.
   timeout => 50,

   do => sub {
      my ( $admin, $user, $room_id, $remote_user ) = @_;

      my @event_ids;
      my $last_event_id;

      matrix_invite_user_to_room_synced( $user, $remote_user, $room_id )
      ->then( sub {
         matrix_join_room_synced( $remote_user, $room_id )
      })->then( sub {
         matrix_put_room_state( $user, $room_id,
            type    => "m.room.name",
            content => { name => "A room name" },
         )
      })->then( sub {
         Future->needs_all(
            matrix_sync( $user ),
            matrix_sync( $remote_user )
         )
      })->then( sub {
         # Send half the messages as the local user...
         repeat( sub {
            my $msgnum = $_[0];

            matrix_send_room_text_message_synced( $user, $room_id,
               body => "Message $msgnum",
            )->on_done( sub { push @event_ids, $_[0]; } )
         }, foreach => [ 0 .. 4 ])
      })->then( sub {
         my ( $last_local_id ) = @_;

         log_if_fail "last_local_id: $last_local_id; waiting for both users to see it";

         # Wait until both users see the last event
         Future->needs_all(
            await_message_in_room( $user, $room_id, $last_local_id ),
            await_message_in_room( $remote_user, $room_id, $last_local_id )
         )
      })->then( sub {
         # ... and half as the remote. This is useful to ensure that both local
         # and remote events are handled correctly.
         repeat( sub {
            my $msgnum = $_[0];

            matrix_send_room_text_message_synced( $remote_user, $room_id,
               body => "Message $msgnum",
            )->on_done( sub { push @event_ids, $_[0]; } )
         }, foreach => [ 5 .. 9 ])
      })->then( sub {
         ( $last_event_id ) = @_;

         log_if_fail "last_event_id: $last_event_id; waiting for both users to see it";

         # Wait until both users see the last event
         Future->needs_all(
            await_message_in_room( $user, $room_id, $last_event_id ),
            await_message_in_room( $remote_user, $room_id, $last_event_id )
         )
      })->then( sub {
         log_if_fail "Purging events before $last_event_id";
         do_request_json_for( $admin,
            method   => "POST",
            full_uri => "/_synapse/admin/v1/purge_history/$room_id/${ \uri_escape( $last_event_id ) }",
            content  => {}
         )
      })->then( sub {
         my ( $body ) = @_;

         assert_json_keys( $body, "purge_id" );
         my $purge_id = $body->{purge_id};
         await_purge_complete( $admin, $purge_id );
      })->then( sub {
         my ( $purge_status ) = @_;
         assert_eq( $purge_status, 'complete' );

         log_if_fail "Purge complete: syncing to check success";

         matrix_sync( $user )
      })->then( sub {
         my ( $body ) = @_;

         assert_json_keys( $body->{rooms}{join}, $room_id );
         my $room =  $body->{rooms}{join}{$room_id};

         log_if_fail( "Room timeline", $room->{timeline}{events} );

         # The only message event should be the last one.
         all {
            $_->{type} ne "m.room.message" || $_->{event_id} eq $last_event_id
         } @{ $room->{timeline}{events} } or die "Expected no message events";

         # Ensure we still see the state.
         foreach my $expected_type( qw(
            m.room.create
            m.room.member
            m.room.power_levels
            m.room.name
         ) ) {
            any { $_->{type} eq $expected_type } @{ $room->{state}{events} }
               or die "Expected state event of type $expected_type";
         }

         my $prev_batch = $room->{timeline}{prev_batch};

         my @missing_event_ids = grep { $_ ne $last_event_id } @event_ids;

         # Keep paginating untill we see all the old messages.
         repeat_until_true {
            log_if_fail "prev_batch: $prev_batch";

            matrix_get_room_messages( $user, $room_id,
               limit => 20,
               from => $prev_batch,
            )->then( sub {
               my ( $body ) = @_;

               log_if_fail( "Pagination result", $body );

               $prev_batch = $body->{end};

               foreach my $event ( @{ $body->{chunk} } ) {
                  @missing_event_ids = grep {
                     $_ ne $event->{event_id}
                  } @missing_event_ids;
               }

               log_if_fail "Missing", \@missing_event_ids;
               return (scalar @missing_event_ids == 0);
            });
         };
      });
   };


multi_test "Shutdown room",
   requires => [ local_admin_fixture(), local_user_fixtures( 2 ), remote_user_fixture(),
      room_alias_name_fixture() ],
   implementation_specific => ['synapse'],

   do => sub {
      my ( $admin, $user, $dummy_user, $remote_user, $room_alias_name ) = @_;

      my $server_name = $user->http->server_name;
      my $room_alias = "#$room_alias_name:$server_name";

      my ( $room_id, $new_room_id );

      matrix_create_room_synced( $user,
         room_alias_name => $room_alias_name,
      )->then( sub {
         ( $room_id ) = @_;

         matrix_invite_user_to_room_synced( $user, $remote_user, $room_id );
      })->then( sub {
         matrix_join_room_synced( $remote_user, $room_id );
      })->then( sub {
         do_request_json_for( $admin,
            method   => "DELETE",
            full_uri => "/_synapse/admin/v1/rooms/$room_id",
            content  => {
               new_room_user_id => $dummy_user->user_id,
               block => JSON::true,
               purge => JSON::false,
            },
         );
      })->SyTest::pass_on_done( "Shutdown room returned success" )
      ->then( sub {
         my ( $body ) = @_;

         $new_room_id = $body->{new_room_id};

         log_if_fail "Shutdown room, new room ID", $new_room_id;

         matrix_send_room_text_message( $user, $room_id, body => "Hello" )
         ->main::expect_http_403;
      })->SyTest::pass_on_done( "User cannot post in room" )
      ->then( sub {
         matrix_join_room( $user, $room_id )
         ->main::expect_http_403;
      })->SyTest::pass_on_done( "User cannot rejoin room" )
      ->then( sub {
         matrix_invite_user_to_room( $remote_user, $user, $room_id )
         ->main::expect_http_403;
      })->SyTest::pass_on_done( "Remote users can't invite local users into room" )
      ->then( sub {
         do_request_json_for( $user,
            method => "GET",
            uri    => "/v3/directory/room/$room_alias",
         );
      })->then( sub {
         my ( $body ) = @_;

         assert_json_keys( $body, qw( room_id ));

         $body->{room_id} eq $new_room_id or die "Expected room_id to be new";

         pass( "Aliases were repointed" );

         retry_until_success {
            matrix_get_room_state( $user, $new_room_id,
               type      => "m.room.name",
               state_key => "",
            )->SyTest::pass_on_done( "User was added to new room" )
         }
      })->then( sub {
         matrix_send_room_text_message( $user, $new_room_id, body => "Hello" )
         ->main::expect_http_403;
      })->SyTest::pass_on_done( "User cannot send into new room" );
   };


sub await_message_in_room
{
   my ( $user, $room_id, $event_id ) = @_;

   my $user_id = $user->user_id;

   repeat( sub {
      matrix_sync_again( $user, timeout => 500 )
      ->then( sub {
         my ( $body ) = @_;

         log_if_fail "Sync for $user_id", $body;

         Future->done( any {
            $_->{event_id} eq $event_id
         } @{ $body->{rooms}{join}{$room_id}{timeline}{events} } )
      })
   }, until => sub {
      $_[0]->failure or $_[0]->get
   })->on_done( sub {
      log_if_fail "Found event $event_id for $user_id";
   })
}
