package Catalyst::Plugin::AutoCRUD::Controller::Root;

use strict;
use warnings FATAL => 'all';

use base 'Catalyst::Controller';
use Catalyst::Utils;
use SQL::Translator::AutoCRUD::Quick;
use File::Basename;

__PACKAGE__->mk_classdata(_site_conf_cache => {});

# the templates are squirreled away in ../templates
(my $pkg_path = __PACKAGE__) =~ s{::}{/}g;
my (undef, $directory, undef) = fileparse(
    $INC{ $pkg_path .'.pm' }
);

sub base : Chained PathPart('autocrud') CaptureArgs(0) {
    my ($self, $c) = @_;

    $c->stash->{current_view} = 'AutoCRUD::TT';
    $c->stash->{cpac_version} = 'CPAC v'
        . $Catalyst::Plugin::AutoCRUD::VERSION;
    $c->stash->{cpac_site} = 'default';
    $c->stash->{template} = 'list.tt';
    $c->stash->{cpac} = {};

    # load enough metadata to display schema and sources
    if (!exists $self->_site_conf_cache->{dispatch}) {
        my $dispatch = {};
        foreach my $backend ($self->_enumerate_backends($c)) {
            my $new_dispatch = $c->forward($backend, 'dispatch_table');
            for (keys %$new_dispatch) {$new_dispatch->{$_}->{backend} = $backend}
            $dispatch = merge_hashes($dispatch, $new_dispatch);
        }
        $self->_site_conf_cache->{dispatch} = $dispatch;
        $c->log->debug("autocrud: generated global dispatch table") if $c->debug;
    }

    # cpac.c.<schema>.t.<source>.<property>
    $c->stash->{cpac}->{c} = $self->_site_conf_cache->{dispatch};
}

sub _enumerate_backends {
    my ($self, $c) = @_;

    my @backends = @{ $c->config->{'Plugin::AutoCRUD'}->{backends} };
    $c->log->debug('autocrud: backends are '. join ',', @backends) if $c->debug;
    return @backends;
}

sub merge_hashes { return Catalyst::Utils::merge_hashes(@_) }

# =====================================================================

# old back-compat /<schema>/<source> which uses default site
# also good for friendly URLs which use default site

sub no_db : Chained('base') PathPart('') Args(0) {
    my ($self, $c) = @_;
    $c->forward('no_schema');
}

sub db : Chained('base') PathPart('') CaptureArgs(1) {
    my ($self, $c) = @_;
    $c->forward('schema');
}

sub no_table : Chained('db') PathPart('') Args(0) {
    my ($self, $c) = @_;
    $c->forward('no_source');
}

sub table : Chained('db') PathPart('') Args(1) {
    my ($self, $c) = @_;
    $c->forward('source');
}

# new RPC-style which specifies site, schema, source explicitly
# like /site/<site>/schema/<schema>/source/<source>

sub site : Chained('base') PathPart CaptureArgs(1) {
    my ($self, $c, $site) = @_;
    $c->stash->{cpac_site} = $site;
}

sub no_schema : Chained('site') PathPart('') Args(0) {
    my ($self, $c) = @_;
    $c->detach('err_message');
}

sub schema : Chained('site') PathPart CaptureArgs(1) {
    my ($self, $c, $db) = @_;
    $c->stash->{cpac_db} = $db;
}

sub no_source : Chained('schema') PathPart('') Args(0) {
    my ($self, $c) = @_;
    $c->detach('err_message');
}

# we know both the schema and the source here
sub source : Chained('schema') PathPart Args(1) {
    my ($self, $c) = @_;
    $c->forward('bootstrap');

    $c->stash->{cpac_title} = $c->stash->{cpac}->{c}
        ->{$c->stash->{cpac_db}}
        ->{t}->{$c->stash->{cpac_table}}->{display_name} .' List';

    # allow frontend override in non-default site (default will be full-fat)
    $c->stash->{cpac_frontend} ||= $c->stash->{cpac}->{g}->{frontend};
    my $fend = 'Controller::AutoCRUD::'. ucfirst $c->stash->{cpac_frontend};
    if ($c->controller($fend)) {
        $c->log->debug(sprintf 'autocrud: forwarding to f/end %s', $fend)
            if $c->debug;
        $c->forward($fend);
    }
}

# for AJAX calls
sub call : Chained('schema') PathPart('source') CaptureArgs(1) {
    my ($self, $c) = @_;
    $c->forward('bootstrap');
    $c->stash->{cpac_backend} = $c->stash->{cpac}->{c}->{$c->stash->{cpac_db}}->{backend};
}

# =====================================================================

# we know only the schema or no schema, or there is a problem
sub err_message : Private {
    my ($self, $c) = @_;
    $c->forward('build_site_config');

    # if there's only one schema, then we choose it and skip straight to
    # the tables display.
    if (scalar keys %{$c->stash->{cpac}->{c}} == 1) {
        $c->stash->{cpac_db} = [keys %{$c->stash->{cpac}->{c}}]->[0];
    }

    $c->stash->{cpac_frontend} ||= $c->stash->{cpac}->{g}->{frontend};
    $c->stash->{template} = 'tables.tt';
}

# just to factor out the pulling of conf and meta from package caches
sub bootstrap : Private {
    my ($self, $c, $table) = @_;
    $c->stash->{cpac_table} = $table;

    $c->forward('build_site_config');
    $c->forward('acl');
    $c->forward('do_meta');
}

# build site config for filtering the frontend
sub build_site_config : Private {
    my ($self, $c) = @_;
    my $current = $c->stash->{cpac_site};

    # if we have it cached
    if (scalar keys %{ $self->_site_conf_cache->{sites}->{$current} }) {
        $c->log->debug(sprintf "autocrud: retrieving cached config for site [%s]",
            $current) if $c->debug;

        $c->stash->{cpac}->{c} = merge_hashes(
            $c->stash->{cpac}->{c},
            $self->_site_conf_cache->{sites}->{$current});
        $c->stash->{cpac}->{g} = delete $c->stash->{cpac}->{c}->{cpac_general};
        return;
    }

    # percolate user preferences down to table level.
    # this duplicates everything, but what we actually copy to config is
    # only the keys in the defaults hashes.
    my $user = $c->config->{'Plugin::AutoCRUD'}->{sites}->{$current} || {};
    foreach my $sc (keys %{ $c->stash->{cpac}->{c} }) {
        $user->{$sc} = merge_hashes(
            ($user->{$sc} || {}),
            _one_level_of($user));

        foreach my $so (keys %{ $c->stash->{cpac}->{c}->{$sc}->{t} }) {
            $user->{$sc}->{$so} = merge_hashes(
                ($user->{$sc}->{$so} || {}),
                _one_level_of($user->{$sc}));
        }
    }

    my %site_defaults   = ( frontend => 'full-fat' );
    my %schema_defaults = ( hidden => 'no' );
    my %source_defaults = (
        create_allowed => 'yes',
        update_allowed => 'yes',
        delete_allowed => 'yes',
        dumpmeta_allowed => ($ENV{AUTOCRUD_TESTING} ? 'yes' : 'no'),
        hidden => 'no',
    );

    # need to end up with a data structure which is easy to use in a
    # template. the cpac_general key avoids name collision with schema,
    # and is moved to {g} for use in template stash.
    my $site = { cpac_general => merge_hashes(
        \%site_defaults,
        _one_level_of($user, \%site_defaults)) };

    foreach my $sc (keys %{ $c->stash->{cpac}->{c} }) {
        $site->{$sc} = merge_hashes(
            \%schema_defaults,
            _one_level_of($user->{$sc}, \%schema_defaults));

        foreach my $so (keys %{ $c->stash->{cpac}->{c}->{$sc}->{t} }) {
            $site->{$sc}->{t}->{$so} = merge_hashes(
                \%source_defaults,
                _one_level_of($user->{$sc}->{$so}, \%source_defaults));
        }
    }

    $self->_site_conf_cache->{sites}->{$current} = $site;
    $c->stash->{cpac}->{c} = merge_hashes($c->stash->{cpac}->{c}, $site);
    $c->stash->{cpac}->{g} = delete $c->stash->{cpac}->{c}->{cpac_general};

    $c->log->debug(sprintf "autocrud: loaded config for site [%s]",
            $c->stash->{cpac_site}) if $c->debug;
}

# returns a new hash containing only defined SCALAR values of $hash
# and optionally, $hash keys will be limited to those keys in $filter
sub _one_level_of {
    my ($hash, $filter) = @_;
    return {} unless ref $hash eq ref {};
    my $retval = {
        map {($_ => $hash->{$_})}
            grep {exists $hash->{$_} and defined $hash->{$_}
                  and (ref $hash->{$_} eq ref '')} keys %$hash
    };
    return $retval unless ref $filter eq ref {};
    return {
        map {($_ => $retval->{$_})}
            grep {exists $retval->{$_}} keys %$filter
    };
}

sub acl : Private {
    my ($self, $c) = @_;

    my $site = $c->stash->{cpac_site};
    my $db = $c->stash->{cpac_db};
    my $table = $c->stash->{cpac_table};

    # ACLs on the schema and source from site config
    if ($c->stash->{cpac}->{c}->{$db}->{hidden} eq 'yes') {
        if ($site eq 'default') {
            $c->detach('verboden', [$c->uri_for( $self->action_for('no_db') )]);
        }
        else {
            $c->detach('verboden', [$c->uri_for( $self->action_for('no_schema'), [$site] )]);
        }
    }
    if ($c->stash->{cpac}->{c}->{$db}->{t}->{$table}->{hidden} eq 'yes') {
        if ($site eq 'default') {
            $c->detach('verboden', [$c->uri_for( $self->action_for('no_table'), [$db] )]);
        }
        else {
            $c->detach('verboden', [$c->uri_for( $self->action_for('no_source'), [$site, $db] )]);
        }
    }
}

sub verboden : Private {
    my ($self, $c, $target, $code) = @_;
    $code ||= 303; # 3xx so RenderView skips template
    $c->response->redirect( $target, $code );
    # detaches -> end
}

# we know both the schema and the source here
sub do_meta : Private {
    my ($self, $c) = @_;

    my $site = $c->stash->{cpac_site};
    my $db = $c->stash->{cpac_db};
    my $table = $c->stash->{cpac_table};

    $c->detach('err_message') if !exists $c->stash->{cpac}->{c}->{$db}
        or !exists $c->stash->{cpac}->{c}->{$db}->{t}->{$table};

    # it's the whole schema, because related table data is also required.
    if (!exists $self->_site_conf_cache->{meta}->{$db}) {
        $self->_site_conf_cache->{meta}->{$db} = SQL::Translator::AutoCRUD::Quick->new(
            $c->forward($c->stash->{cpac}->{c}->{$db}->{backend}, 'schema_metadata'));
        $c->log->debug("autocrud: generated schema metadata for [$db]") if $c->debug;
    }

    $c->stash->{cpac}->{m} = $self->_site_conf_cache->{meta}->{$db};
    $c->log->debug("autocrud: retrieved cached schema metadata for [$db]") if $c->debug;

    foreach my $so (keys %{ $c->stash->{cpac}->{c}->{$db}->{t} }) {
        my $user = $c->config->{'Plugin::AutoCRUD'}->{sites}->{$site}->{$db}->{$so} || {};
        my $source = $c->stash->{cpac}->{c}->{$db}->{t}->{$so};

        # columns from the user conf can be loaded (for current db only - lazy)
        $source->{cols} = ((ref $user->{columns} eq ref []) and scalar @{$user->{columns}})
            ? $user->{columns} : $c->stash->{cpac}->{m}->t->{$so}->extra('col_order');

        # headings from the user conf can be loaded (for current db only - lazy)
        foreach my $f ($c->stash->{cpac}->{m}->t->{$so}->get_fields) {
            $source->{headings}->{$f->name} =
                $user->{headings}->{$f->name} || $f->extra('display_name');
        }
    }

    # set up helper for templates
    $c->stash->{cpac}->{t} = $c->stash->{cpac}->{c}->{$db}->{t}->{$table};
}

sub helloworld : Chained('base') Args(0) {
    my ($self, $c) = @_;
    $c->forward('build_site_config');
    $c->stash->{cpac_title} = 'Hello World';
    $c->stash->{template} = 'helloworld.tt';
}

sub end : ActionClass('RenderView') {
    my ($self, $c) = @_;
    my $frontend = $c->stash->{cpac_frontend} || 'full-fat';

    $c->stash->{cpac}->{g} = merge_hashes(
        $c->stash->{cpac}->{g},
        _one_level_of($c->config->{'Plugin::AutoCRUD'}));

    my $tt_path = $c->config->{'Plugin::AutoCRUD'}->{tt_path};
    $tt_path = (defined $tt_path ? (ref $tt_path eq '' ? [$tt_path] : $tt_path ) : [] );

    push @$tt_path, "$directory../templates/$frontend";
    $c->stash->{additional_template_paths} = $tt_path;
}

1;
__END__
