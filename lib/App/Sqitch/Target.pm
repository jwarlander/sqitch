package App::Sqitch::Target;

use 5.010;
use Moo;
use strict;
use warnings;
use App::Sqitch::Types qw(Maybe URIDB Str Dir Engine Sqitch File Plan);
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use Path::Class qw(dir file);
use namespace::autoclean;

has name => (
    is       => 'ro',
    isa      => Str,
    required => 1,
);

has uri  => (
    is   => 'ro',
    isa  => URIDB,
    required => 1,
    handles => {
        engine_key => 'canonical_engine',
        dsn        => 'dbi_dsn',
        username   => 'user',
        password   => 'password',
    },
);

has sqitch => (
    is       => 'ro',
    isa      => Sqitch,
    required => 1,
);

has engine => (
    is      => 'ro',
    isa     => Engine,
    lazy    => 1,
    default => sub {
        my $self   = shift;
        require App::Sqitch::Engine;
        App::Sqitch::Engine->load({
            sqitch => $self->sqitch,
            target => $self,
        });
    },
);

sub _fetch {
    my ($self, $key) = @_;
    my $sqitch = $self->sqitch;
    if (my $val = $sqitch->options->{$key}) {
        return $val;
    }

    my $config = $sqitch->config;
    return $config->get( key => "target." . $self->name . ".$key" )
        || $config->get( key => "core." . $self->engine->key . ".$key")
        || $config->get( key => "core.$key");
}

has registry => (
    is  => 'ro',
    isa => Str,
    lazy => 1,
    default => sub {
        my $self = shift;
        $self->_fetch('registry') || $self->engine->default_registry;
    },
);

has client => (
    is       => 'ro',
    isa      => Str,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        $self->_fetch('client') || do {
            my $client = $self->engine->default_client;
            return $client if $^O ne 'MSWin32';
            return $client if $client =~ /[.](?:exe|bat)$/;
            return $client . '.exe';
        };
    },
);

has plan_file => (
    is       => 'ro',
    isa      => File,
    lazy     => 1,
    default => sub {
        my $self = shift;
        if (my $f = $self->_fetch('plan_file') ) {
            return file $f;
        }
        return $self->top_dir->file('sqitch.plan')->cleanup;
    },
);

has plan => (
    is       => 'ro',
    isa      => Plan,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        # XXX Update to reference target.
        App::Sqitch::Plan->new(
            sqitch => $self->sqitch,
            file   => $self->plan_file,
        );
    },
);

has top_dir => (
    is      => 'ro',
    isa     => Dir,
    lazy    => 1,
    default => sub {
        dir shift->_fetch('top_dir') || ();
    },
);

has deploy_dir => (
    is      => 'ro',
    isa     => Dir,
    lazy    => 1,
    default => sub {
        my $self = shift;
        if ( my $dir = $self->_fetch('deploy_dir') ) {
            return dir $dir;
        }
        $self->top_dir->subdir('deploy')->cleanup;
    },
);

has revert_dir => (
    is      => 'ro',
    isa     => Dir,
    lazy    => 1,
    default => sub {
        my $self = shift;
        if ( my $dir = $self->_fetch('revert_dir') ) {
            return dir $dir;
        }
        $self->top_dir->subdir('revert')->cleanup;
    },
);

has verify_dir => (
    is      => 'ro',
    isa     => Dir,
    lazy    => 1,
    default => sub {
        my $self = shift;
        if ( my $dir = $self->_fetch('verify_dir') ) {
            return dir $dir;
        }
        $self->top_dir->subdir('verify')->cleanup;
    },
);

has extension => (
    is      => 'ro',
    isa     => Str,
    lazy    => 1,
    default => sub {
        shift->_fetch('extension') || 'sql';
    },
);

# If no name:
#   a. use URI for name; or
#   b. Look for core.$engine.target.
# If no URI:
#   a. Use name if it exists and contains a colon; or
#   b. If name exists: look for target.$name.uri or die; or
#   c. Default to "db:$engine:"
# If still no name, use URI.

# Need to move command-line options into a hash, remove accessors in App::Sqitch.
# Remove attributes here from App::Sqitch and Engine.

sub BUILDARGS {
    my $class = shift;
    my $p = @_ == 1 && ref $_[0] ? { %{ +shift } } : { @_ };
    my $sqitch = $p->{sqitch} or return $p;

    # The name defaults to the URI, if we have one.
    if (my $uri = $p->{uri}) {
        if (!$p->{name}) {
            # Set the URI as the name, sans password.
            if ($uri->password) {
                $uri = $uri->clone;
                $uri->password(undef);
            }
            $p->{name} = $uri->as_string;

        }
        return $p;
    }

    # If no name, try to find the default.
    my $uri;
    my $ekey = $sqitch->options->{engine} || $sqitch->config->get(
        key => 'core.engine'
    ) or hurl target => __(
        'No engine specified; use --engine or set core.engine'
    );

    my $name = $p->{name} ||= $sqitch->config->get(
        key => "core.$ekey.target"
    );

    # If no URI, we have to find one.
    if (!$name) {
        # Fall back on the default.
        $uri = "db:$ekey:";
    } elsif ($name =~ /:/) {
        # The name is a URI.
        $uri = URI::db->new($name);
        $name = undef;
    } else {
        # Well then, there had better be a config with a URI.
        $uri = $sqitch->config->get( key => "target.$name.uri" ) or do {
            # Die on no section or no URI.
            hurl target => __x(
                'Cannot find target "{target}"',
                target => $name
            ) unless %{ $sqitch->config->get_section(
                section => "target.$name"
            ) };
            hurl target => __x(
                'No URI associated with target "{target}"',
                target => $name,
            );
        };
    }

    # Instantiate the URI.
    require URI::db;
    $uri = $p->{uri} = URI::db->new( $uri );

    # Override parts with command-line options.
    my $opts = $sqitch->options;
    if (my $host = $opts->{db_host}) {
        $uri->host($host);
    }

    if (my $port = $opts->{db_port}) {
        $uri->port($port);
    }

    if (my $user = $opts->{db_username}) {
        $uri->user($user);
    }

    if (my $db = $opts->{db_name}) {
        $uri->dbname($db);
    }

    unless ($name) {
        # Set the name.
        if ($uri->password) {
            # Remove the password from the name.
            my $tmp = $uri->clone;
            $tmp->password(undef);
            $p->{name} = $tmp->as_string;
        } else {
            $p->{name} = $uri->as_string;
        }
    }

    return $p;
}

1;
__END__
