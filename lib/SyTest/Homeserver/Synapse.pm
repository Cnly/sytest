package SyTest::Homeserver::Synapse;

use strict;
use warnings;
use 5.010;
use base qw( SyTest::Homeserver );

use Carp;

use Future::Utils qw( try_repeat );

use IO::Async::Process;
use IO::Async::FileStream;

use Cwd qw( getcwd );
use File::Basename qw( dirname );
use File::Path qw( remove_tree );
use List::Util qw( any pairmap );
use POSIX qw( strftime );

use YAML ();

sub _init
{
   my $self = shift;
   my ( $args ) = @_;

   $self->{$_} = delete $args->{$_} for qw(
      ports synapse_dir extra_args python config coverage
      dendron pusher synchrotron federation_reader bind_host
      media_repository
   );

   defined $self->{ports}{$_} or croak "Need a '$_' port\n"
      for qw( client client_unsecure metrics );

   $self->SUPER::_init( $args );
}

sub configure
{
   my $self = shift;
   my %params = @_;

   exists $params{$_} and $self->{$_} = delete $params{$_} for qw(
      print_output filter_output
   );

   $self->SUPER::configure( %params );
}

sub _append
{
   my ( $config, $more ) = @_;
   if( ref $more eq "HASH" ) {
      ref $config eq "HASH" or die "Cannot append HASH to non-HASH";
      _append( $_[0]->{$_}, $more->{$_} ) for keys %$more;
   }
   elsif( ref $more eq "ARRAY" ) {
      push @{ $_[0] }, @$more;
   }
   else {
      die "Not sure how to append ${\ref $more} to config\n";
   }
}

sub append_config
{
   my $self = shift;
   my %more = @_;

   _append( $self->{config}, \%more );
}

sub start
{
   my $self = shift;

   my $port = $self->{ports}{client};
   my $output = $self->{output};

   my $hs_dir = $self->{hs_dir};

   my $db_config_path = "database.yaml";
   my $db_config_abs_path = "$hs_dir/${db_config_path}";
   my $db  = ":memory:"; #"$hs_dir/homeserver.db";

   my ( $db_type, %db_args, $db_config );
   if( -f $db_config_abs_path ) {
      $db_config = YAML::LoadFile( $db_config_abs_path );
      if( $db_config->{name} eq "psycopg2") {
          $db_type = "pg";
          %db_args = %{ $db_config->{args} };
      }
      elsif ($db_config->{name} eq "sqlite3") {
          $db_type = "sqlite";
          $db_args{path} = $db_config->{args}->{database};
      }
      else {
         die "Unrecognised DB type '$db_config->{name}' in $db_config_abs_path";
      }
   }
   else {
      $db_type = "sqlite";
      $db_args{path} = $db;
      $db_config = { name => "sqlite3", args => { database => $db } };
      $self->write_yaml_file( $db_config_path, $db_config );
   }

   if( defined $db_type ) {
      my $clear_meth = "clear_db_${db_type}";
      $self->$clear_meth( %db_args );
   }

   # Clean up the media_store directory each time, or else it fills up with
   # thousands of automatically-generated avatar images
   if( -d "$hs_dir/media_store" ) {
      remove_tree( "$hs_dir/media_store" );
   }

   if( -d "$hs_dir/uploads" ) {
      remove_tree( "$hs_dir/uploads" );
   }

   my $cwd = getcwd;
   my $log = "$hs_dir/homeserver.log";

   my $listeners = [];
   my $bind_host = $self->{bind_host};

   if( $self->{dendron} ) {
      # If we are running synapse behind dendron then only bind the unsecure
      # port for synapse.
      $self->{ports}{client_unsecure} or
         croak "Need an unsecure client port if running synapse behind dendron";
   }
   else {
      push @$listeners, {
         type => "http",
         port => $port,
         bind_address => $bind_host,
         tls => 1,
         resources => [{
            names => [ "client", "federation", "replication" ], compress => 0
         }]
      };
   }

   if( my $unsecure_port = $self->{ports}{client_unsecure} ) {
      push @$listeners, {
         type => "http",
         port => $unsecure_port,
         bind_address => $bind_host,
         tls => 0,
         resources => [{
            names => [ "client", "federation", "replication" ], compress => 0
         }]
      }
   }

   push @$listeners, {
      type => "metrics",
      port => $self->{ports}{metrics},
      bind_address => $bind_host,
      tls => 0,
   };

   my $cert_file = "$hs_dir/cert.pem";
   my $key_file = "$hs_dir/key.pem";
   my $log_config_file = "$hs_dir/log.config";

   my $macaroon_secret_key = "secret_$port";
   my $registration_shared_secret = "reg_secret";

   my $config_path = $self->write_yaml_file( config => {
        "server_name" => "$bind_host:$port",
        "log_file" => "$log",
        (-f $log_config_file) ? ("log_config" => $log_config_file) : (),
        "tls_certificate_path" => $cert_file,
        "tls_private_key_path" => $key_file,
        "tls_dh_params_path" => "$cwd/keys/tls.dh",
        "rc_messages_per_second" => 1000,
        "rc_message_burst_count" => 1000,
        "enable_registration" => "true",
        "database" => $db_config,
        "database_config" => $db_config_path,
        "macaroon_secret_key" => $macaroon_secret_key,
        "registration_shared_secret" => $registration_shared_secret,

        "use_frozen_events" => "true",

        "invite_3pid_guest" => "true",

        # Metrics are always useful
        "enable_metrics" => 1,

        "perspectives" => { servers => {} },

        # Stack traces are useful
        "full_twisted_stacktraces" => "true",

        "listeners" => $listeners,

        "bcrypt_rounds" => 0,
        "start_pushers" => (not $self->{pusher}),

        "url_preview_enabled" => "true",
        "url_preview_ip_range_blacklist" => [],

        "media_store_path" => "$hs_dir/media_store",
        "uploads_path" => "$hs_dir/uploads_path",

        %{ $self->{config} },
   } );

   my $pusher_config_path = $self->write_yaml_file( pusher => {
      "worker_app"             => "synapse.app.pusher",
      "worker_log_file"        => "$log.pusher",
      "worker_replication_url" => "http://$bind_host:$self->{ports}{client_unsecure}/_synapse/replication",
      "worker_listeners"       => [
         {
            type      => "http",
            resources => [{ names => ["metrics"] }],
            bind_address => $bind_host,
            port      => $self->{ports}{pusher_metrics},
         },
         {
            type => "manhole",
            port => $self->{ports}{pusher_manhole},
            bind_address => $bind_host,
         },
      ],
   } );

   my $synchrotron_config_path = $self->write_yaml_file( synchrotron => {
      "worker_app"             => "synapse.app.synchrotron",
      "worker_log_file"        => "$log.synchrotron",
      "worker_replication_url" => "http://$bind_host:$self->{ports}{client_unsecure}/_synapse/replication",
      "worker_listeners"       => [
         {
            type      => "http",
            resources => [{ names => ["client"] }],
            port      => $self->{ports}{synchrotron},
            bind_address => $bind_host,
         },
         {
            type => "manhole",
            port => $self->{ports}{synchrotron_manhole},
            bind_address => $bind_host,
         },
         {
            type      => "http",
            resources => [{ names => ["metrics"] }],
            port      => $self->{ports}{synchrotron_metrics},
            bind_address => $bind_host,
         },
      ],
   } );

   my $federation_reader_config_path = $self->write_yaml_file( federation_reader => {
      "worker_app"             => "synapse.app.federation_reader",
      "worker_log_file"        => "$log.federation_reader",
      "worker_replication_url" => "http://$bind_host:$self->{ports}{client_unsecure}/_synapse/replication",
      "worker_listeners"       => [
         {
            type      => "http",
            resources => [{ names => ["federation"] }],
            port      => $self->{ports}{federation_reader},
            bind_address => $bind_host,
         },
         {
            type => "manhole",
            port => $self->{ports}{federation_reader_manhole},
            bind_address => $bind_host,
         },
         {
            type      => "http",
            resources => [{ names => ["metrics"] }],
            port      => $self->{ports}{federation_reader_metrics},
            bind_address => $bind_host,
         },
      ],
   } );


   my $media_repository_config_path = $self->write_yaml_file( media_repository => {
      "worker_app"             => "synapse.app.media_repository",
      "worker_log_file"        => "$log.media_repository",
      "worker_replication_url" => "http://$bind_host:$self->{ports}{client_unsecure}/_synapse/replication",
      "worker_listeners"       => [
         {
            type      => "http",
            resources => [{ names => ["media"] }],
            port      => $self->{ports}{media_repository},
            bind_address => $bind_host,
         },
         {
            type => "manhole",
            port => $self->{ports}{media_repository_manhole},
            bind_address => $bind_host,
         },
         {
            type      => "http",
            resources => [{ names => ["metrics"] }],
            port      => $self->{ports}{media_repository_metrics},
            bind_address => $bind_host,
         },
      ],
   } );

   $self->{logpath} = $log;

   {
      # create or truncate
      open my $tmph, ">", $log or die "Cannot open $log for writing - $!";
   }

   my $pythonpath = (
      exists $ENV{PYTHONPATH}
      ? "$self->{synapse_dir}:$ENV{PYTHONPATH}"
      : "$self->{synapse_dir}"
   );

   my @synapse_command = ( $self->{python} );

   if( $self->{coverage} ) {
      # Ensures that even --generate-config has coverage reports. This is intentional
      push @synapse_command,
         "-m", "coverage", "run", "-p", "--source=$self->{synapse_dir}/synapse";
   }

   push @synapse_command,
      "-m", "synapse.app.homeserver",
      "--config-path" => $config_path,
      "--server-name" => "$bind_host:$port";

   $output->diag( "Generating config for port $port" );

   my @config_command = (
      @synapse_command, "--generate-config", "--report-stats=no"
   );

   my @command;

   if( $self->{dendron} ) {
      $db_type eq "pg" or die "Dendron can only run against postgres";

      my @db_arg_pairs = pairmap { $a eq "database" ? "dbname=$b" : "$a=$b" } %db_args;

      @command = (
         $self->{dendron},
         "--synapse-python" => $self->{python},
         "--synapse-config" => $config_path,
         "--synapse-url" => "http://$bind_host:$self->{ports}{client_unsecure}",
         "--synapse-postgres" => join( " ", @db_arg_pairs ),
         "--macaroon-secret" => $macaroon_secret_key,
         "--server-name" => "$bind_host:$port",
         "--cert-file" => $cert_file,
         "--key-file" => $key_file,
         "--addr" => "$bind_host:$port",
      );

      if ( $self->{pusher} ) {
         push @command, "--pusher-config" => $pusher_config_path;
      }

      if ( $self->{synchrotron} ) {
         push @command,
            "--synchrotron-config" => $synchrotron_config_path,
            "--synchrotron-url" => "http://$bind_host:$self->{ports}{synchrotron}";
      }

      if ( $self->{federation_reader} ) {
         push @command,
            "--federation-reader-config" => $federation_reader_config_path,
            "--federation-reader-url" => "http://$bind_host:$self->{ports}{federation_reader}";
      }

      if ( $self->{media_repository} ) {
         push @command,
            "--media-repository-config" => $media_repository_config_path,
            "--media-repository-url" => "http://$bind_host:$self->{ports}{media_repository}";
      }
   }
   else {
      @command = @synapse_command
   }

   my $env = {
      "PYTHONPATH" => $pythonpath,
      "PATH" => $ENV{PATH},
      "PYTHONDONTWRITEBYTECODE" => "Don't write .pyc files",
   };

   my $loop = $self->loop;
   $loop->run_child(
      setup => [ env => $env ],

      command => [ @config_command ],

      on_finish => sub {
         my ( $pid, $exitcode, $stdout, $stderr ) = @_;

         if( $exitcode != 0 ) {
            print STDERR $stderr;
            exit $exitcode;
         }

         $output->diag( "Starting server for port $port" );
         $self->add_child(
            $self->{proc} = IO::Async::Process->new(
               setup => [ env => $env ],

               command => [ @command, @{ $self->{extra_args} } ],

               on_finish => $self->_capture_weakself( 'on_finish' ),
            )
         );

         $output->diag( "Connecting to server $port" );

         $self->adopt_future(
            $self->await_connectable( $bind_host, $port )->then( sub {
               $output->diag( "Connected to server $port" );

               $self->started_future->done;
            })
         );

         $self->open_logfile;
      }
   );
}

sub pid
{
   my $self = shift;
   return $self->{proc}->pid;
}

sub kill
{
   my $self = shift;
   my ( $signal ) = @_;

   if( $self->{proc} and my $pid = $self->{proc}->pid ) {
      kill $signal => $pid;
   }
}

sub on_finish
{
   my $self = shift;
   my ( $process, $exitcode ) = @_;

   say $self->pid . " stopped";

   if( $exitcode > 0 ) {
      warn "Process failed ($exitcode)";

      print STDERR "\e[1;35m[server $self->{port}]\e[m: $_\n"
         for @{ $self->{stderr_lines} // [] };

      # Now force all remaining output to be printed
      $self->{print_output}++;
      undef $self->{filter_output};
   }

   $self->await_finish->done( $exitcode );
}

sub open_logfile
{
   my $self = shift;

   $self->add_child(
      $self->{log_stream} = IO::Async::FileStream->new(
         filename => $self->{logpath},
         on_read => $self->_capture_weakself( 'on_synapse_read' ),
      )
   );
}

sub close_logfile
{
   my $self = shift;

   $self->remove_child( delete $self->{log_stream} );
}

sub on_synapse_read
{
   my $self = shift;
   my ( $stream, $bufref, $eof ) = @_;

   while( $$bufref =~ s/^(.*)\n// ) {
      my $line = $1;

      push @{ $self->{stderr_lines} }, $line;
      shift @{ $self->{stderr_lines} } while @{ $self->{stderr_lines} } > 20;

      if( $self->{print_output} ) {
         my $filter = $self->{filter_output};
         if( !$filter or any { $line =~ m/$_/ } @$filter ) {
            print STDERR "\e[1;35m[server $self->{port}]\e[m: $line\n";
         }
      }
   }

   return 0;
}

sub started_future
{
   my $self = shift;
   return $self->{started_future} ||= $self->loop->new_future;
}

sub await_finish
{
   my $self = shift;
   return $self->{finished_future} //= $self->loop->new_future;
}

sub print_output
{
   my $self = shift;
   my ( $on ) = @_;
   $on = 1 unless @_;

   $self->configure( print_output => $on );

   if( $on ) {
      print STDERR "\e[1;35m[server $self->{port}]\e[m: $_\n"
         for @{ $self->{stderr_lines} // [] };
   }

   undef @{ $self->{stderr_lines} };
}

sub rotate_logfile
{
   my $self = shift;
   my ( $newname ) = @_;

   my $logpath = $self->{logpath};

   $newname //= dirname( $logpath ) . strftime( "/homeserver-%Y-%m-%dT%H:%M:%S.log", localtime );

   rename( $logpath, $newname );

   $self->kill( 'HUP' );

   try_repeat {
      -f $logpath and return Future->done(1);

      $self->loop->delay_future( after => 0.5 )->then_done(0);
   } foreach => [ 1 .. 20 ],
     while => sub { !shift->get },
     otherwise => sub { die "Timed out waiting for synapse to recreate its log file" };
}

1;
