package Catalyst::Plugin::AutoCRUD::Controller::AJAX;

use strict;
use warnings FATAL => 'all';

use base 'Catalyst::Controller';

sub _filter_datetime {
    my $val = shift;
    if (eval { $val->isa( 'DateTime' ) }) {
        my $iso = $val->iso8601;
        $iso =~ s/T/ /;
        return $iso;
    }
    else {
        $val =~ s/(\.\d+)?[+-]\d\d$//;
        return $val;
    }
}

my %filter_for = (
    timefield => {
        to_ext => \&_filter_datetime,
        from_ext   => sub { shift },
    },
    xdatetime => {
        to_ext => \&_filter_datetime,
        from_ext   => sub { shift },
    },
    checkbox => {
        to_ext => sub {
            my $val = shift;
            return 1 if $val eq 'true' or $val eq '1';
            return 0;
        },
        from_ext   => sub {
            my $val = shift;
            return 1 if $val eq 'on' or $val eq '1';
            return 0;
        },
    },
    numberfield => {
        to_ext => sub { shift },
        from_ext   => sub {
            my $val = shift;
            return undef if !defined $val or $val eq '';
            return $val;
        },
    },
);

# we're going to check that calls to this RPC operation are allowed
sub acl : Private {
    my ($self, $c) = @_;
    my $site = $c->stash->{cpac}->{g}->{site};
    my $db = $c->stash->{cpac}->{g}->{db};
    my $table = $c->stash->{cpac}->{g}->{table};

    my $acl_for = {
        create   => 'create_allowed',
        update   => 'update_allowed',
        'delete' => 'delete_allowed',
        dumpmeta      => 'dumpmeta_allowed',
        dumpmeta_html => 'dumpmeta_allowed',
    };
    my $action = [split m{/}, $c->action]->[-1];
    my $acl = $acl_for->{ $action } or return;

    if ($c->stash->{cpac}->{c}->{$db}->{t}->{$table}->{$acl} ne 'yes') {
        my $msg = "Access forbidden by configuration to [$site]->[$db]->[$table]->[$action]";
        $c->log->debug($msg) if $c->debug;

        $c->response->content_type('text/plain; charset=utf-8');
        $c->response->body($msg);
        $c->response->status('403');
        $c->detach();
    }
}

sub base : Chained('/autocrud/root/call') PathPart('') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->forward('acl');

    my $page   = $c->req->params->{'page'}  || 1;
    my $limit  = $c->req->params->{'limit'} || 10;
    my $sortby = $c->req->params->{'sort'}  || $c->stash->{cpac}->{g}->{default_sort};
    (my $dir   = $c->req->params->{'dir'}   || 'ASC') =~ s/\s//g;

    @{$c->stash}{qw/ cpac_page cpac_limit cpac_sortby cpac_dir /}
        = ($page, $limit, $sortby, $dir);

    $c->stash->{current_view} = 'AutoCRUD::JSON';
}

sub end : ActionClass('RenderView') {}

sub filter_from_ext : Private {
    my ($self, $c) = @_;
    my $conf = $c->stash->{cpac}->{tc};
    my $meta = $c->stash->{cpac}->{tm};
    my @columns = @{$conf->{cols}};

    my $do_filter = sub {
        my ($c, $ci, $col) = @_;
        return unless exists $c->req->params->{$col}
            and defined $c->req->params->{$col};

        if ($ci->extra('extjs_xtype')
            and exists $filter_for{ $ci->extra('extjs_xtype') }) {

            $c->req->params->{$col} =
                $filter_for{ $ci->extra('extjs_xtype') }->{from_ext}->(
                    $c->req->params->{$col}
                );
        }
    };

    # filter data types coming from the Ext form
    foreach my $col (@columns) {
        my $ci = $meta->f->{$col};
        if ($ci->is_foreign_key) {
            next unless $ci->extra('ref_table');
            my $link = $c->stash->{cpac}->{m}->t->{ $ci->extra('ref_table') };
            next unless $link->extra('fields');

            foreach my $fcol (@{$link->extra('fields')}) {
                my $fci = $link->f->{$fcol};
                $do_filter->($c, $fci, "$col.$fcol");
            }
        }
        else {
            $do_filter->($c, $ci, $col);
        }
    }
}

sub create : Chained('base') Args(0) {
    my ($self, $c) = @_; 
    $c->forward('filter_from_ext');
    $c->forward($c->stash->{cpac}->{g}->{backend}, 'create');
}

sub list : Chained('base') Args(0) {
    my ($self, $c) = @_;
    # forward to backend action to get data
    $c->forward($c->stash->{cpac}->{g}->{backend}, 'list');

    my $conf = $c->stash->{cpac}->{tc};
    my $meta = $c->stash->{cpac}->{tm};
    my @columns = @{$conf->{cols}};

    # filter data types coming from the db for Ext
    foreach my $row (@{$c->stash->{json_data}->{rows}}) {
        foreach my $col (@columns) {
            my $ci = $meta->f->{$col};

            if ($ci->extra('extjs_xtype')
                and exists $filter_for{ $ci->extra('extjs_xtype') }) {

                $row->{$col} =
                    $filter_for{ $ci->extra('extjs_xtype') }->{to_ext}->(
                        $row->{$col});
            }
        }
    }

    # sneak in a 'top' row for applying the filters
    my %searchrow = ();
    foreach my $col (@columns) {
        my $ci = $meta->f->{$col};

        if ($ci->extra('extjs_xtype') and $ci->extra('extjs_xtype') eq 'checkbox') {
            $searchrow{$col} = '';
        }
        else {
            if (exists $c->req->params->{ 'cpac_filter.'. $col }) {
                $searchrow{$col} = $c->req->params->{ 'cpac_filter.'. $col };
            }
            else {
                $searchrow{$col} = '(click to add filter)';
            }
        }
    }
    unshift @{$c->stash->{json_data}->{rows}}, \%searchrow;
}

sub update : Chained('base') Args(0) {
    my ($self, $c) = @_;
    $c->forward('filter_from_ext');
    $c->forward($c->stash->{cpac}->{g}->{backend}, 'update');
}

sub delete : Chained('base') Args(0) {
    my ($self, $c) = @_;
    $c->forward($c->stash->{cpac}->{g}->{backend}, 'delete');
}

sub list_stringified : Chained('base') Args(0) {
    my ($self, $c) = @_;
    $c->forward($c->stash->{cpac}->{g}->{backend}, 'list_stringified');
}

# send our generated config back in JSON for debugging
sub dumpmeta : Chained('base') Args(0) {
    my ($self, $c) = @_;

    # strip the SQLT objects
    my $meta = scalar $c->stash->{cpac}->{m}->extra;
    foreach my $t (values %{$c->stash->{cpac}->{m}->t}) {
        $meta->{t}->{$t->name} = scalar $t->extra;
        foreach my $f (values %{$t->f}) {
            $meta->{t}->{$t->name}->{f}->{$f->name} = scalar $f->extra;
        }
    }

    # delete the version as it changes
    delete $c->stash->{cpac}->{g}->{version};

    $c->stash->{json_data} = { cpac => {
        meta => $meta,
        conf => $c->stash->{cpac}->{c},
        global => $c->stash->{cpac}->{g},
    } };

    return $self;
}

# send our generated config back to the user in HTML
sub dumpmeta_html : Chained('base') Args(0) {
    my ($self, $c) = @_;
    my $msg = $c->stash->{cpac}->{g}->{version} . ' Metadata Debug Output';

    $c->debug(1);
    $c->error([ $msg ]);
    $c->stash->{dumpmeta} = 1;
    $c->response->body($msg);

    return $self;
}

1;

__END__
