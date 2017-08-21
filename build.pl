#!/usr/bin/perl

use strict;
use warnings;

use Config;
use Cwd;
use Data::Dumper;
use File::Basename;
use File::Copy;
use Getopt::Long;
use IPC::Cmd qw/run can_run/;
use Net::Domain;
use Term::ANSIColor;

my $GLOBAL_PATH_TO_SCRIPT_FILE;
my $GLOBAL_PATH_TO_SCRIPT_DIR;
my $GLOBAL_PATH_TO_TOP;
my $CWD;

my %CFG = ();

BEGIN
{
   $ENV{ANSI_COLORS_DISABLED} = 1 if ( !-t STDOUT );
   $GLOBAL_PATH_TO_SCRIPT_FILE = Cwd::abs_path(__FILE__);
   $GLOBAL_PATH_TO_SCRIPT_DIR  = dirname($GLOBAL_PATH_TO_SCRIPT_FILE);
   $GLOBAL_PATH_TO_TOP         = dirname($GLOBAL_PATH_TO_SCRIPT_DIR);
   $CWD                        = getcwd();
}

chdir($GLOBAL_PATH_TO_TOP);

##############################################################################################

sub LoadConfiguration($)
{
   my $args = shift;

   my $cfg_name    = $args->{name};
   my $cmd_hash    = $args->{hash_src};
   my $default_sub = $args->{default_sub};

   my @cfg_list = ();
   push( @cfg_list, "config.build" );
   push( @cfg_list, ".build.last_no_ts" ) if ( $ENV{ENV_RESUME_FLAG} );

   my $val;
   my $src;

   if ( !defined $val )
   {
      y/A-Z_/a-z-/ foreach ( my $cmd_name = $cfg_name );

      if ( $cmd_hash && exists $cmd_hash->{$cmd_name} )
      {
         $val = $cmd_hash->{$cmd_name};
         $src = "cmdline";
      }
   }

   if ( !defined $val )
   {
      foreach my $file_basename (@cfg_list)
      {
         my $file = "$GLOBAL_PATH_TO_SCRIPT_DIR/$file_basename";
         my $hash = LoadProperties($file)
           if ( -f $file );

         if ( $hash && exists $hash->{$cfg_name} )
         {
            $val = $hash->{$cfg_name};
            $src = $file_basename;
            last;
         }
      }
   }

   if ( !defined $val )
   {
      if ($default_sub)
      {
         $val = &$default_sub($cfg_name);
         $src = "default";
      }
   }

   if ( defined $val )
   {
      if ( ref($val) eq "HASH" )
      {
         foreach my $k ( keys %{$val} )
         {
            $CFG{$cfg_name}{$k} = ${$val}{$k};

            printf( " %-35s: %-17s : %s\n", $cfg_name, $cmd_hash ? $src : "detected", $k . " => " . ${$val}{$k} );
         }
      }
      else
      {
         $CFG{$cfg_name} = $val;

         printf( " %-35s: %-17s : %s\n", $cfg_name, $cmd_hash ? $src : "detected", $val );
      }
   }
}

sub InitGlobalBuildVars()
{
   {
      my $destination_name_func = sub {
         return "$CFG{BUILD_OS}-$CFG{BUILD_RELEASE}-$CFG{BUILD_RELEASE_NO_SHORT}-$CFG{BUILD_TS}-$CFG{BUILD_TYPE}-$CFG{BUILD_NO}";
      };

      my $build_dir_func = sub {
         return "$CFG{BUILD_SOURCES_BASE_DIR}/.staging/$CFG{DESTINATION_NAME}";
      };

      my %cmd_hash = ();

      my @cmd_args = (
         { name => "BUILD_NO",                   type => "=i",  hash_src => \%cmd_hash, default_sub => sub { return GetNewBuildNo(); }, },
         { name => "BUILD_TS",                   type => "=i",  hash_src => \%cmd_hash, default_sub => sub { return GetNewBuildTs(); }, },
         { name => "BUILD_OS",                   type => "=s",  hash_src => \%cmd_hash, default_sub => sub { return GetBuildOS(); }, },
         { name => "BUILD_DESTINATION_BASE_DIR", type => "=s",  hash_src => \%cmd_hash, default_sub => sub { return "$GLOBAL_PATH_TO_TOP/BUILDS"; }, },
         { name => "BUILD_SOURCES_BASE_DIR",     type => "=s",  hash_src => \%cmd_hash, default_sub => sub { return $GLOBAL_PATH_TO_TOP; }, },
         { name => "BUILD_RELEASE",              type => "=s",  hash_src => \%cmd_hash, default_sub => sub { Die("@_ not specified"); }, },
         { name => "BUILD_RELEASE_NO",           type => "=s",  hash_src => \%cmd_hash, default_sub => sub { Die("@_ not specified"); }, },
         { name => "BUILD_RELEASE_CANDIDATE",    type => "=s",  hash_src => \%cmd_hash, default_sub => sub { Die("@_ not specified"); }, },
         { name => "BUILD_TYPE",                 type => "=s",  hash_src => \%cmd_hash, default_sub => sub { Die("@_ not specified"); }, },
         { name => "BUILD_THIRDPARTY_SERVER",    type => "=s",  hash_src => \%cmd_hash, default_sub => sub { Die("@_ not specified"); }, },
         { name => "BUILD_PROD_FLAG",            type => "!",   hash_src => \%cmd_hash, default_sub => sub { return 1; }, },
         { name => "BUILD_DEBUG_FLAG",           type => "!",   hash_src => \%cmd_hash, default_sub => sub { return 0; }, },
         { name => "BUILD_DEV_TOOL_BASE_DIR",    type => "=s",  hash_src => \%cmd_hash, default_sub => sub { return "$ENV{HOME}/.zm-dev-tools"; }, },
         { name => "INTERACTIVE",                type => "!",   hash_src => \%cmd_hash, default_sub => sub { return 1; }, },
         { name => "GIT_OVERRIDES",              type => "=s%", hash_src => \%cmd_hash, default_sub => sub { return {}; }, },
         { name => "GIT_DEFAULT_TAG",            type => "=s",  hash_src => \%cmd_hash, default_sub => sub { return undef; }, },
         { name => "GIT_DEFAULT_REMOTE",         type => "=s",  hash_src => \%cmd_hash, default_sub => sub { return undef; }, },
         { name => "GIT_DEFAULT_BRANCH",         type => "=s",  hash_src => \%cmd_hash, default_sub => sub { return undef; }, },
         { name => "STOP_AFTER_CHECKOUT",        type => "!",   hash_src => \%cmd_hash, default_sub => sub { return 0; }, },
         { name => "ANT_OPTIONS",                type => "=s",  hash_src => \%cmd_hash, default_sub => sub { return undef; }, },
         { name => "BUILD_HOSTNAME",             type => "=s",  hash_src => \%cmd_hash, default_sub => sub { return Net::Domain::hostfqdn; }, },
         { name => "DEPLOY_URL_PREFIX",          type => "=s",  hash_src => \%cmd_hash, default_sub => sub { $CFG{LOCAL_DEPLOY} = 1; return "http://" + Net::Domain::hostfqdn + ":8008"; }, },

         { name => "BUILD_ARCH",             type => "", hash_src => undef, default_sub => sub { return GetBuildArch(); }, },
         { name => "BUILD_RELEASE_NO_SHORT", type => "", hash_src => undef, default_sub => sub { my $x = $CFG{BUILD_RELEASE_NO}; $x =~ s/[.]//g; return $x; }, },
         { name => "DESTINATION_NAME",       type => "", hash_src => undef, default_sub => sub { return &$destination_name_func; }, },
         { name => "BUILD_DIR",              type => "", hash_src => undef, default_sub => sub { return &$build_dir_func; }, },
      );

      {
         my @cmd_opts =
           map { $_->{opt} =~ y/A-Z_/a-z-/; $_; }    # convert the opt named to lowercase to make command line options
           map { { opt => $_->{name}, opt_s => $_->{type} } }    # create a new hash with keys opt, opt_s
           grep { $_->{type} }                                   # get only names which have a valid type
           @cmd_args;

         my $help_func = sub {
            print "Usage: $0 <options>\n";
            print "Supported options: \n";
            print "   --" . "$_->{opt}$_->{opt_s}\n" foreach (@cmd_opts);
            exit(0);
         };

         if ( !GetOptions( \%cmd_hash, ( map { $_->{opt} . $_->{opt_s} } @cmd_opts ), help => $help_func ) )
         {
            print Die("wrong commandline options, use --help");
         }
      }

      print "=========================================================================================================\n";
      LoadConfiguration($_) foreach (@cmd_args);
      print "=========================================================================================================\n";

      Die( "Bad version '$CFG{BUILD_RELEASE_NO}'", "$@" )
        if ( $CFG{BUILD_RELEASE_NO} !~ m/^\d+[.]\d+[.]\d+$/ );
   }

   foreach my $x (`grep -o '\\<[E][N][V]_[A-Z_]*\\>' '$GLOBAL_PATH_TO_SCRIPT_FILE' | sort | uniq`)
   {
      chomp($x);
      my $fmt2v = " %-35s: %s\n";
      printf( $fmt2v, $x, defined $ENV{$x} ? $ENV{$x} : "(undef)" );
   }

   print "=========================================================================================================\n";
   {
      $ENV{PATH} = "$CFG{BUILD_DEV_TOOL_BASE_DIR}/bin/Sencha/Cmd/4.0.2.67:$CFG{BUILD_DEV_TOOL_BASE_DIR}/bin:$ENV{PATH}";

      my $cc    = DetectPrerequisite("cc");
      my $cpp   = DetectPrerequisite("c++");
      my $java  = DetectPrerequisite( "java", $ENV{JAVA_HOME} ? "$ENV{JAVA_HOME}/bin" : "" );
      my $javac = DetectPrerequisite( "javac", $ENV{JAVA_HOME} ? "$ENV{JAVA_HOME}/bin" : "" );
      my $mvn   = DetectPrerequisite("mvn");
      my $ant   = DetectPrerequisite("ant");
      my $ruby  = DetectPrerequisite("ruby");
      my $make  = DetectPrerequisite("make");

      $ENV{JAVA_HOME} ||= dirname( dirname( Cwd::realpath($javac) ) );
      $ENV{PATH} = "$ENV{JAVA_HOME}/bin:$ENV{PATH}";

      my $fmt2v = " %-35s: %s\n";
      printf( $fmt2v, "USING javac", "$javac (JAVA_HOME=$ENV{JAVA_HOME})" );
      printf( $fmt2v, "USING java",  $java );
      printf( $fmt2v, "USING maven", $mvn );
      printf( $fmt2v, "USING ant",   $ant );
      printf( $fmt2v, "USING cc",    $cc );
      printf( $fmt2v, "USING c++",   $cpp );
      printf( $fmt2v, "USING ruby",  $ruby );
      printf( $fmt2v, "USING make",  $make );
   }

   print "=========================================================================================================\n";

   print "NOTE: THIS WILL STOP AFTER CHECKOUTS\n"
     if ( $CFG{STOP_AFTER_CHECKOUT} );

   if ( $CFG{INTERACTIVE} )
   {
      print "Press enter to proceed";
      read STDIN, $_, 1;
   }
}

sub Prepare()
{
   RemoveTargetInDir( ".zcs-deps",   $ENV{HOME} ) if ( $ENV{ENV_CACHE_CLEAR_FLAG} );
   RemoveTargetInDir( ".ivy2/cache", $ENV{HOME} ) if ( $ENV{ENV_CACHE_CLEAR_FLAG} );

   open( FD, ">", "$GLOBAL_PATH_TO_SCRIPT_DIR/.build.last_no_ts" );
   print FD "BUILD_NO=$CFG{BUILD_NO}\n";
   print FD "BUILD_TS=$CFG{BUILD_TS}\n";
   close(FD);

   System( "mkdir", "-p", "$CFG{BUILD_DIR}" );
   System( "mkdir", "-p", "$CFG{BUILD_DIR}/logs" );
   System( "mkdir", "-p", "$ENV{HOME}/.zcs-deps" );
   System( "mkdir", "-p", "$ENV{HOME}/.ivy2/cache" );

   System( "find", $CFG{BUILD_DIR}, "-type", "f", "-name", ".built.*", "-delete" ) if ( $ENV{ENV_CACHE_CLEAR_FLAG} );

   my @TP_JARS = (
      "https://files.zimbra.com/repository/ant-1.7.0-ziputil-patched/ant-1.7.0-ziputil-patched-1.0.jar",
      "https://files.zimbra.com/repository/ant-contrib/ant-contrib-1.0b1.jar",
      "https://files.zimbra.com/repository/jruby/jruby-complete-1.6.3.jar",
      "https://files.zimbra.com/repository/applet/plugin.jar",
      "https://files.zimbra.com/repository/servlet-api/servlet-api-3.1.jar",
      "https://files.zimbra.com/repository/unbound-ldapsdk/unboundid-ldapsdk-2.3.5-se.jar",
   );

   for my $j_url (@TP_JARS)
   {
      if ( my $f = "$ENV{HOME}/.zcs-deps/" . basename($j_url) )
      {
         if ( !-f $f )
         {
            System( "wget", $j_url, "-O", "$f.tmp" );
            System( "mv", "$f.tmp", $f );
         }
      }
   }

   my ( $MAJOR, $MINOR, $MICRO ) = split( /[.]/, $CFG{BUILD_RELEASE_NO} );

   EchoToFile( "$GLOBAL_PATH_TO_SCRIPT_DIR/RE/BUILD", $CFG{BUILD_NO} );
   EchoToFile( "$GLOBAL_PATH_TO_SCRIPT_DIR/RE/MAJOR", $MAJOR );
   EchoToFile( "$GLOBAL_PATH_TO_SCRIPT_DIR/RE/MINOR", $MINOR );
   EchoToFile( "$GLOBAL_PATH_TO_SCRIPT_DIR/RE/MICRO", "${MICRO}_$CFG{BUILD_RELEASE_CANDIDATE}" );

   close(FD);
}

sub EvalFile($;$)
{
   my $fname = shift;

   my $file = "$GLOBAL_PATH_TO_SCRIPT_DIR/$fname";

   Die( "Error in '$file'", "$@" )
     if ( !-f $file );

   my @ENTRIES;

   eval `cat '$file'`;
   Die( "Error in '$file'", "$@" )
     if ($@);

   return \@ENTRIES;
}

sub LoadRepos()
{
   my @agg_repos = ();

   push( @agg_repos, @{ EvalFile("instructions/$CFG{BUILD_TYPE}_repo_list.pl") } );

   return \@agg_repos;
}


sub LoadRemotes()
{
   my %details = @{ EvalFile("instructions/$CFG{BUILD_TYPE}_remote_list.pl") };

   return \%details;
}


sub LoadBuilds($)
{
   my $repo_list = shift;

   my @agg_builds = ();

   push( @agg_builds, @{ EvalFile("instructions/$CFG{BUILD_TYPE}_staging_list.pl") } );

   my %repo_hash = map { $_->{name} => 1 } @$repo_list;

   my @filtered_builds =
     grep { my $d = $_->{dir}; $d =~ s/\/.*//; $repo_hash{$d} }    # extract the repository from the 'dir' entry, filter out entries which do not exist in repo_list
     @agg_builds;

   return \@filtered_builds;
}


sub Checkout($)
{
   my $repo_list = shift;

   print "\n";
   print "=========================================================================================================\n";
   print " Processing " . scalar(@$repo_list) . " repositories\n";
   print "=========================================================================================================\n";
   print "\n";

   my $repo_remote_details = LoadRemotes();

   for my $repo_details (@$repo_list)
   {
      Clone( $repo_details, $repo_remote_details );
   }
}


sub RemoveTargetInDir($$)
{
   my $target = shift;
   my $chdir  = shift;

   s/\/\/*/\//g, s/\/*$// for ( my $sane_target = $target );    #remove multiple slashes, and ending slashes, dots

   if ( $sane_target && $chdir && -d $chdir )
   {
      eval
      {
         Run( cd => $chdir, child => sub { System( "rm", "-rf", $sane_target ); } );
      };
   }
}

sub EmitArchiveAccessInstructions($)
{
   my $archive_names = shift;

   if ( -f "/etc/redhat-release" )
   {
      return <<EOM_DUMP;
#########################################
# INSTRUCTIONS TO ACCESS FROM CLIENT BOX
#########################################

sudo bash -s <<"EOM_SCRIPT"
cat > /etc/yum.repos.d/zimbra-packages.repo <<EOM
@{[
   join("\n",
      map {
"[$_]
name=Zimbra Package Archive ($_)
baseurl=$CFG{DEPLOY_URL_PREFIX}/$CFG{DESTINATION_NAME}/archives/$_/
enabled=1
gpgcheck=0
protect=0"
      }
      @$archive_names
   )]}
EOM
yum clean all
EOM_SCRIPT
EOM_DUMP
   }
   else
   {
      return <<EOM_DUMP;
#########################################
# INSTRUCTIONS TO ACCESS FROM CLIENT BOX
#########################################

sudo bash -s <<"EOM_SCRIPT"
cat > /etc/apt/sources.list.d/zimbra-packages.list << EOM
@{[
   join("\n",
      map {
"deb [trusted=yes] $CFG{DEPLOY_URL_PREFIX}/$CFG{DESTINATION_NAME}/archives/$_ ./ # Zimbra Package Archive ($_)"
      }
      @$archive_names
   )]}
EOM
apt-get update
EOM_SCRIPT
EOM_DUMP
   }
}


sub Build($)
{
   my $repo_list = shift;

   my @ALL_BUILDS = @{ LoadBuilds($repo_list) };

   my $tool_attributes = {
      ant => [
         "-Ddebug=$CFG{BUILD_DEBUG_FLAG}",
         "-Dis-production=$CFG{BUILD_PROD_FLAG}",
         "-Dzimbra.buildinfo.platform=$CFG{BUILD_OS}",
         "-Dzimbra.buildinfo.version=$CFG{BUILD_RELEASE_NO}_$CFG{BUILD_RELEASE_CANDIDATE}_$CFG{BUILD_NO}",
         "-Dzimbra.buildinfo.type=$CFG{BUILD_TYPE}",
         "-Dzimbra.buildinfo.release=$CFG{BUILD_TS}",
         "-Dzimbra.buildinfo.date=$CFG{BUILD_TS}",
         "-Dzimbra.buildinfo.host=$CFG{BUILD_HOSTNAME}",
         "-Dzimbra.buildinfo.buildnum=$CFG{BUILD_NO}",
      ],
      make => [
         "debug=$CFG{BUILD_DEBUG_FLAG}",
         "is-production=$CFG{BUILD_PROD_FLAG}",
         "zimbra.buildinfo.platform=$CFG{BUILD_OS}",
         "zimbra.buildinfo.version=$CFG{BUILD_RELEASE_NO}_$CFG{BUILD_RELEASE_CANDIDATE}_$CFG{BUILD_NO}",
         "zimbra.buildinfo.type=$CFG{BUILD_TYPE}",
         "zimbra.buildinfo.release=$CFG{BUILD_TS}",
         "zimbra.buildinfo.date=$CFG{BUILD_TS}",
         "zimbra.buildinfo.host=$CFG{BUILD_HOSTNAME}",
         "zimbra.buildinfo.buildnum=$CFG{BUILD_NO}",
      ],
   };

   push( @{ $tool_attributes->{ant} }, $CFG{ANT_OPTIONS} )
     if ( $CFG{ANT_OPTIONS} );

   my $cnt = 0;
   for my $build_info (@ALL_BUILDS)
   {
      ++$cnt;

      if ( my $dir = $build_info->{dir} )
      {
         my $target_dir = "$CFG{BUILD_DIR}/$dir";

         next
           unless ( !defined $ENV{ENV_BUILD_INCLUDE} || grep { $dir =~ /$_/ } split( ",", $ENV{ENV_BUILD_INCLUDE} ) );

         RemoveTargetInDir( $dir, $CFG{BUILD_DIR} )
           if ( ( $ENV{ENV_FORCE_REBUILD} && grep { $dir =~ /$_/ } split( ",", $ENV{ENV_FORCE_REBUILD} ) ) );

         print "=========================================================================================================\n";
         print color('blue') . "BUILDING: $dir ($cnt of " . scalar(@ALL_BUILDS) . ")" . color('reset') . "\n";
         print "\n";

         if ( $ENV{ENV_RESUME_FLAG} && -f "$target_dir/.built.$CFG{BUILD_TS}" )
         {
            print color('yellow') . "SKIPPING... [TO REBUILD REMOVE '$target_dir']" . color('reset') . "\n";
            print "=========================================================================================================\n";
            print "\n";
         }
         else
         {
            unlink glob "$target_dir/.built.*";

            Run(
               cd    => $dir,
               child => sub {

                  my $abs_dir = Cwd::abs_path();

                  if ( my $tool_seq = $build_info->{tool_seq} || [ "ant", "mvn", "make" ] )
                  {
                     for my $tool (@$tool_seq)
                     {
                        if ( my $targets = $build_info->{ $tool . "_targets" } )    #Known values are: ant_targets, mvn_targets, make_targets
                        {
                           eval { System( $tool, "clean" ) if ( !$ENV{ENV_SKIP_CLEAN_FLAG} ); };

                           System( $tool, @{ $tool_attributes->{$tool} || [] }, @$targets );
                        }
                     }
                  }

                  if ( my $stage_cmd = $build_info->{stage_cmd} )
                  {
                     &$stage_cmd
                  }

                  if ( my $deploy_pkg_into = $build_info->{deploy_pkg_into} )
                  {
                     $deploy_pkg_into = "bundle"
                       if ( $deploy_pkg_into eq "zimbra-foss" && !$ENV{ENV_ENABLE_ARCHIVE_ZIMBRA_FOSS} );

                     $deploy_pkg_into .= "-$ENV{ENV_ARCHIVE_SUFFIX_STR}"
                       if ( $deploy_pkg_into ne "bundle" && $ENV{ENV_ARCHIVE_SUFFIX_STR} );

                     my $packages_path = "$CFG{BUILD_DIR}/zm-packages/$deploy_pkg_into";

                     System( "mkdir", "-p", $packages_path );
                     System("rsync -av build/dist/[urc]* '$packages_path/'");
                  }

                  if ( !exists $build_info->{partial} )
                  {
                     system( "mkdir", "-p", "$target_dir" );
                     System( "touch", "$target_dir/.built.$CFG{BUILD_TS}" );
                  }
               },
            );

            print "\n";
            print "=========================================================================================================\n";
            print "\n";
         }
      }
   }

   Run(
      cd    => "$GLOBAL_PATH_TO_SCRIPT_DIR",
      child => sub {
         System( "rsync", "-az", "--delete", ".", "$CFG{BUILD_DIR}/zm-build" );
         System( "mkdir", "-p", "$CFG{BUILD_DIR}/zm-build/$CFG{BUILD_ARCH}" );

         my @ALL_PACKAGES = ();
         push( @ALL_PACKAGES, @{ EvalFile("instructions/$CFG{BUILD_TYPE}_package_list.pl") } );
         push( @ALL_PACKAGES, "zcs-bundle" );

         for my $package_script (@ALL_PACKAGES)
         {
            if ( !defined $ENV{ENV_PACKAGE_INCLUDE} || grep { $package_script =~ /$_/ } split( ",", $ENV{ENV_PACKAGE_INCLUDE} ) )
            {
               System(
                  "  releaseNo='$CFG{BUILD_RELEASE_NO}' \\
                     releaseCandidate='$CFG{BUILD_RELEASE_CANDIDATE}' \\
                     branch='$CFG{BUILD_RELEASE}-$CFG{BUILD_RELEASE_NO_SHORT}' \\
                     buildNo='$CFG{BUILD_NO}' \\
                     os='$CFG{BUILD_OS}' \\
                     buildType='$CFG{BUILD_TYPE}' \\
                     repoDir='$CFG{BUILD_DIR}' \\
                     arch='$CFG{BUILD_ARCH}' \\
                     buildTimeStamp='$CFG{BUILD_TS}' \\
                     buildLogFile='$CFG{BUILD_DIR}/logs/build.log' \\
                     zimbraThirdPartyServer='$CFG{BUILD_THIRDPARTY_SERVER}' \\
                        bash $GLOBAL_PATH_TO_SCRIPT_DIR/instructions/bundling-scripts/$package_script.sh
                  "
               );
            }
         }
      },
   );
}


sub Deploy()
{
   print "\n";
   print "=========================================================================================================\n";
   print color('blue') . "DEPLOYING ARTIFACTS" . color('reset') . "\n";
   print "\n";
   print "\n";

   my $destination_dir = "$CFG{BUILD_DESTINATION_BASE_DIR}/$CFG{DESTINATION_NAME}";

   System( "mkdir", "-p", "$destination_dir/archives" );

   my @archive_names = map { basename($_) } grep { -d $_ && $_ !~ m/\/bundle$/ } glob("$CFG{BUILD_DIR}/zm-packages/*");

   foreach my $archive_name (@archive_names)
   {
      System( "rsync", "-av", "--delete", "$CFG{BUILD_DIR}/zm-packages/$archive_name/", "$destination_dir/archives/$archive_name" );

      if ( -f "/etc/redhat-release" )
      {
         if ( !$CFG{LOCAL_DEPLOY} || DetectPrerequisite( "createrepo", "", 1 ) )
         {
            System("cd '$destination_dir/archives/$archive_name' && createrepo '.'");
         }
      }
      else
      {
         if ( !$CFG{LOCAL_DEPLOY} || DetectPrerequisite( "dpkg-scanpackages", "", 1 ) )
         {
            System("cd '$destination_dir/archives/$archive_name' && dpkg-scanpackages '.' /dev/null > Packages");
         }
      }
   }

   EchoToFile( "$destination_dir/archive-access.txt", EmitArchiveAccessInstructions( \@archive_names ) );

   System("cp $CFG{BUILD_DIR}/zm-build/zcs-*.$CFG{BUILD_TS}.tgz $destination_dir/");

   if ( $CFG{LOCAL_DEPLOY} )
   {
      if ( !-f "/etc/nginx/conf.d/zimbra-pkg-archives-host.conf" || !`pgrep -f -P1 '[n]ginx'` )
      {
         print "\n";
         print "=========================================================================================================\n";
         print <<EOM_DUMP;
@{[color('bold white')]}
############################################
# INSTRUCTIONS TO SETUP NGINX PACKAGES HOST
############################################
@{[color('reset')]}
# You might need to resolve network, firewall, selinux, permissions issues appropriately before proceeding:

# sudo sed -i -e s/^SELINUX=enforcing/SELINUX=permissive/ /etc/selinux/config
# sudo setenforce permissive
# sudo systemctl stop firewalld
# sudo ufw disable
@{[color('yellow')]}
sudo bash -s <<"EOM_SCRIPT"
[ -f /etc/redhat-release ] && ( yum install -y epel-release && yum install -y nginx && service nginx start )
[ -f /etc/redhat-release ] || ( apt-get -y install nginx && service nginx start )
tee /etc/nginx/conf.d/zimbra-pkg-archives-host.conf <<EOM
server {
  listen 8008;
  location / {
     root $CFG{BUILD_DESTINATION_BASE_DIR};
     autoindex on;
  }
}
EOM
service httpd stop 2>/dev/null
service nginx restart
service nginx status
EOM_SCRIPT
@{[color('reset')]}
EOM_DUMP
      }
   }

   print "\n";
   print "=========================================================================================================\n";
   print "\n";
}


sub GetNewBuildNo()
{
   my $line = 1000;

   my $file = "$GLOBAL_PATH_TO_SCRIPT_DIR/.build.number";

   if ( -f $file )
   {
      open( FD1, "<", $file );
      $line = <FD1>;
      close(FD1);

      $line += 1;
   }

   open( FD2, ">", $file );
   printf( FD2 "%s\n", $line );
   close(FD2);

   return $line;
}

sub GetNewBuildTs()
{
   chomp( my $x = `date +'%Y%m%d%H%M%S'` );

   return $x;
}


sub GetBuildOS()
{
   our $detected_os = undef;

   sub detect_os
   {
      chomp( $detected_os = `$GLOBAL_PATH_TO_SCRIPT_DIR/rpmconf/Build/get_plat_tag.sh` )
        if ( !$detected_os );

      return $detected_os
        if ($detected_os);

      Die("Unknown OS");
   }

   return detect_os();
}

sub GetBuildArch()    # FIXME - use standard mechanism
{
   chomp( my $PROCESSOR_ARCH = `uname -m | grep -o 64` );

   my $b_os = $CFG{BUILD_OS};

   return "amd" . $PROCESSOR_ARCH
     if ( $b_os =~ /UBUNTU/ );

   return "x86_" . $PROCESSOR_ARCH
     if ( $b_os =~ /RHEL/ || $b_os =~ /CENTOS/ );

   Die("Unknown Arch");
}


##############################################################################################

sub Clone($$)
{
   my $repo_details        = shift;
   my $repo_remote_details = shift;

   my $repo_name       = $repo_details->{name};
   my $repo_branch     = $CFG{GIT_OVERRIDES}->{"$repo_name.branch"} || $repo_details->{branch} || $CFG{GIT_DEFAULT_BRANCH} || "develop";
   my $repo_tag        = $CFG{GIT_OVERRIDES}->{"$repo_name.tag"} || $repo_details->{tag} || $CFG{GIT_DEFAULT_TAG} if ( $CFG{GIT_OVERRIDES}->{"$repo_name.tag"} || !$CFG{GIT_OVERRIDES}->{"$repo_name.branch"} );
   my $repo_remote     = $CFG{GIT_OVERRIDES}->{"$repo_name.remote"} || $repo_details->{remote} || $CFG{GIT_DEFAULT_REMOTE} || "gh-zm";
   my $repo_url_prefix = $CFG{GIT_OVERRIDES}->{"$repo_remote.url-prefix"} || $repo_remote_details->{$repo_remote}->{'url-prefix'} || Die( "unresolved url-prefix for remote='$repo_remote'", "" );

   $repo_url_prefix =~ s,/*$,,;

   my $repo_dir = "$CFG{BUILD_SOURCES_BASE_DIR}/$repo_name";

   if ( !-d $repo_dir )
   {
      my @clone_cmd_args = ( "git", "clone" );

      push( @clone_cmd_args, "--depth=1" ) if ( not $ENV{ENV_GIT_FULL_CLONE} );
      push( @clone_cmd_args, "-b", $repo_tag ? $repo_tag : $repo_branch );
      push( @clone_cmd_args, "$repo_url_prefix/$repo_name.git", "$repo_dir" );

      System(@clone_cmd_args);

      RemoveTargetInDir( $repo_name, $CFG{BUILD_DIR} );
   }
   else
   {
      if ( !defined $ENV{ENV_GIT_UPDATE_INCLUDE} || grep { $repo_name =~ /$_/ } split( ",", $ENV{ENV_GIT_UPDATE_INCLUDE} ) )
      {
         if ($repo_tag)
         {
            print "\n";
            Run( cd => $repo_dir, child => sub { System( "git", "checkout", $repo_tag ); } );

            RemoveTargetInDir( $repo_name, $CFG{BUILD_DIR} );
         }
         else
         {
            print "\n";
            Run(
               cd    => $repo_dir,
               child => sub {
                  my $z = System( "git", "pull", "--ff-only" );

                  if ( "@{$z->{out}}" !~ /Already up-to-date/ )
                  {
                     RemoveTargetInDir( $repo_name, $CFG{BUILD_DIR} );
                  }
               },
            );
         }
      }
   }
}

sub System(@)
{
   my $cmd_str = "@_";

   print color('green') . "#: pwd=@{[Cwd::getcwd()]}" . color('reset') . "\n";
   print color('green') . "#: $cmd_str" . color('reset') . "\n";

   $! = 0;
   my ( $success, $error_message, $full_buf, $stdout_buf, $stderr_buf ) = run( command => \@_, verbose => 1 );

   Die( "cmd='$cmd_str'", $error_message )
     if ( !$success );

   return { msg => $error_message, out => $stdout_buf, err => $stderr_buf };
}


sub LoadProperties($)
{
   my $f = shift;

   my $x = SlurpFile($f);

   my @cfg_kvs =
     map { $_ =~ s/^\s+|\s+$//g; $_ }    # trim
     map { split( /=/, $_, 2 ) }         # split around =
     map { $_ =~ s/#.*$//g; $_ }         # strip comments
     grep { $_ !~ /^\s*#/ }              # ignore comments
     grep { $_ !~ /^\s*$/ }              # ignore empty lines
     @$x;

   my %ret_hash = ();
   for ( my $e = 0 ; $e < scalar @cfg_kvs ; $e += 2 )
   {
      my $probe_key = $cfg_kvs[$e];
      my $probe_val = $cfg_kvs[ $e + 1 ];

      if ( $probe_key =~ /^%(.*)/ )
      {
         my @val_kv_pair = split( /=/, $probe_val, 2 );

         $ret_hash{$1}{ $val_kv_pair[0] } = $val_kv_pair[1];
      }
      else
      {
         $ret_hash{$probe_key} = $probe_val;
      }
   }

   return \%ret_hash;
}


sub SlurpFile($)
{
   my $f = shift;

   open( FD, "<", "$f" ) || Die( "In open for read", "file='$f'" );

   chomp( my @x = <FD> );
   close(FD);

   return \@x;
}


sub EchoToFile($$)
{
   my $f = shift;
   my $w = shift;

   open( FD, ">", "$f" ) || Die( "In open for write", "file='$f'" );
   print FD $w . "\n";
   close(FD);
}


sub DetectPrerequisite($;$$)
{
   my $util_name       = shift;
   my $additional_path = shift || "";
   my $warn_only       = shift || 0;

   chomp( my $detected_util = `PATH="$additional_path:\$PATH" \\which "$util_name" 2>/dev/null | sed -e 's,//*,/,g'` );

   return $detected_util
     if ($detected_util);

   Die(
      "Prerequisite '$util_name' missing in PATH"
        . "\nTry: "
        . "\n   [ -f /etc/redhat-release ] && sudo yum install perl-Data-Dumper perl-IPC-Cmd gcc-c++ java-1.8.0-openjdk ant ant-junit ruby maven wget rpm-build createrepo"
        . "\n   [ -f /etc/redhat-release ] || sudo apt-get install software-properties-common openjdk-8-jdk ant ant-optional ruby git maven build-essential",
      "",
      $warn_only
   );
}


sub Run(%)
{
   my %args  = (@_);
   my $chdir = $args{cd};
   my $child = $args{child};

   my $child_pid = fork();

   Die("FAILURE while forking")
     if ( !defined $child_pid );

   if ( $child_pid != 0 )    # parent
   {
      while ( waitpid( $child_pid, 0 ) == -1 ) { }

      Die( "child $child_pid died", einfo($?) )
        if ( $? != 0 );
   }
   else
   {
      Die( "chdir to '$chdir' failed", einfo($?) )
        if ( $chdir && !chdir($chdir) );

      $! = 0;
      &$child;
      exit(0);
   }
}

sub einfo()
{
   my @SIG_NAME = split( / /, $Config{sig_name} );

   return "ret=" . ( $? >> 8 ) . ( ( $? & 127 ) ? ", sig=SIG" . $SIG_NAME[ $? & 127 ] : "" );
}

sub Die($;$$)
{
   my $msg       = shift;
   my $info      = shift || "";
   my $warn_only = shift || 0;

   my $err = "$!";

   print "\n" if ( !$warn_only );
   print "\n";
   print "=========================================================================================================\n";
   print color('red') . "FAILURE MSG" . color('reset') . " : $msg\n"  if ( !$warn_only );
   print color('red') . "WARNING MSG" . color('reset') . " : $msg\n"  if ($warn_only);
   print color('red') . "SYSTEM ERR " . color('reset') . " : $err\n"  if ($err);
   print color('red') . "EXTRA INFO " . color('reset') . " : $info\n" if ($info);
   print "\n";
   print "=========================================================================================================\n";

   if ( !$warn_only )
   {
      print color('red');
      print "--Stack Trace-- ($$)\n";
      my $i = 1;

      while ( ( my @call_details = ( caller( $i++ ) ) ) )
      {
         print $call_details[1] . ":" . $call_details[2] . " called from " . $call_details[3] . "\n";
      }
      print color('reset');
      print "\n";
      print "=========================================================================================================\n";

      die "END"
   }
}

##############################################################################################

sub main()
{
   InitGlobalBuildVars();

   my $all_repos = LoadRepos();

   Prepare();

   Checkout($all_repos);

   if ( !$CFG{STOP_AFTER_CHECKOUT} )
   {
      Build($all_repos);

      Deploy();
   }
}

main();

##############################################################################################
