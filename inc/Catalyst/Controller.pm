#line 1
package Catalyst::Controller;

#switch to BEGIN { extends qw/ ... /; } ?
use base qw/Catalyst::Component Catalyst::AttrContainer/;
use Moose;

use Scalar::Util qw/blessed/;
use Catalyst::Exception;
use Catalyst::Utils;
use Class::Inspector;

has path_prefix =>
    (
     is => 'rw',
     isa => 'Str',
     init_arg => 'path',
     predicate => 'has_path_prefix',
    );

has action_namespace =>
    (
     is => 'rw',
     isa => 'Str',
     init_arg => 'namespace',
     predicate => 'has_action_namespace',
    );

has actions =>
    (
     is => 'rw',
     isa => 'HashRef',
     init_arg => undef,
    );

# isa => 'ClassName|Catalyst' ?
has _application => (is => 'rw');
sub _app{ shift->_application(@_) } 

sub BUILD {
    my ($self, $args) = @_;
    my $action  = delete $args->{action}  || {};
    my $actions = delete $args->{actions} || {};
    my $attr_value = $self->merge_config_hashes($actions, $action);
    $self->actions($attr_value);
}

#line 68

#I think both of these could be attributes. doesn't really seem like they need
#to ble class data. i think that attributes +default would work just fine
__PACKAGE__->mk_classdata($_) for qw/_dispatch_steps _action_class/;

__PACKAGE__->_dispatch_steps( [qw/_BEGIN _AUTO _ACTION/] );
__PACKAGE__->_action_class('Catalyst::Action');


sub _DISPATCH : Private {
    my ( $self, $c ) = @_;

    foreach my $disp ( @{ $self->_dispatch_steps } ) {
        last unless $c->forward($disp);
    }

    $c->forward('_END');
}

sub _BEGIN : Private {
    my ( $self, $c ) = @_;
    my $begin = ( $c->get_actions( 'begin', $c->namespace ) )[-1];
    return 1 unless $begin;
    $begin->dispatch( $c );
    return !@{ $c->error };
}

sub _AUTO : Private {
    my ( $self, $c ) = @_;
    my @auto = $c->get_actions( 'auto', $c->namespace );
    foreach my $auto (@auto) {
        $auto->dispatch( $c );
        return 0 unless $c->state;
    }
    return 1;
}

sub _ACTION : Private {
    my ( $self, $c ) = @_;
    if (   ref $c->action
        && $c->action->can('execute')
        && $c->req->action )
    {
        $c->action->dispatch( $c );
    }
    return !@{ $c->error };
}

sub _END : Private {
    my ( $self, $c ) = @_;
    my $end = ( $c->get_actions( 'end', $c->namespace ) )[-1];
    return 1 unless $end;
    $end->dispatch( $c );
    return !@{ $c->error };
}

around new => sub {
    my $orig = shift;
    my $self = shift;
    my $app = $_[0];
    my $new = $self->$orig(@_);
    $new->_application( $app );
    return $new;
};

sub action_for {
    my ( $self, $name ) = @_;
    my $app = ($self->isa('Catalyst') ? $self : $self->_application);
    return $app->dispatcher->get_action($name, $self->action_namespace);
}

#my opinion is that this whole sub really should be a builder method, not 
#something that happens on every call. Anyone else disagree?? -- groditi
## -- apparently this is all just waiting for app/ctx split
around action_namespace => sub {
    my $orig = shift;
    my ( $self, $c ) = @_;

    if( ref($self) ){
        return $self->$orig if $self->has_action_namespace;
    } else {
        return $self->config->{namespace} if exists $self->config->{namespace};
    }

    my $case_s;
    if( $c ){
        $case_s = $c->config->{case_sensitive};
    } else {
        if ($self->isa('Catalyst')) {
            $case_s = $self->config->{case_sensitive};
        } else {
            if (ref $self) {
                $case_s = $self->_application->config->{case_sensitive};
            } else {
                confess("Can't figure out case_sensitive setting");
            }
        }
    }

    my $namespace = Catalyst::Utils::class2prefix(ref($self) || $self, $case_s) || '';
    $self->$orig($namespace) if ref($self);
    return $namespace;
};

#Once again, this is probably better written as a builder method
around path_prefix => sub {
    my $orig = shift;
    my $self = shift;
    if( ref($self) ){
      return $self->$orig if $self->has_path_prefix;
    } else {
      return $self->config->{path} if exists $self->config->{path};
    }
    my $namespace = $self->action_namespace(@_);
    $self->$orig($namespace) if ref($self);
    return $namespace;
};


sub register_actions {
    my ( $self, $c ) = @_;
    my $class = ref $self || $self;
    #this is still not correct for some reason.
    my $namespace = $self->action_namespace($c);
    my $meta = $self->meta;
    my %methods = map{ $_->{code}->body => $_->{name} }
        grep {$_->{class} ne 'Moose::Object'} #ignore Moose::Object methods
            $meta->compute_all_applicable_methods;


    # Advanced inheritance support for plugins and the like
    #moose todo: migrate to eliminate CDI compat
    my @action_cache;
    for my $isa ( $meta->superclasses, $class ) {
        if(my $coderef = $isa->can('_action_cache')){
            push(@action_cache, @{ $isa->$coderef });
        }
    }

    foreach my $cache (@action_cache) {
        my $code   = $cache->[0];
        my $method = delete $methods{$code}; # avoid dupe registers
        next unless $method;
        my $attrs = $self->_parse_attrs( $c, $method, @{ $cache->[1] } );
        if ( $attrs->{Private} && ( keys %$attrs > 1 ) ) {
            $c->log->debug( 'Bad action definition "'
                  . join( ' ', @{ $cache->[1] } )
                  . qq/" for "$class->$method"/ )
              if $c->debug;
            next;
        }
        my $reverse = $namespace ? "${namespace}/${method}" : $method;
        my $action = $self->create_action(
            name       => $method,
            code       => $code,
            reverse    => $reverse,
            namespace  => $namespace,
            class      => $class,
            attributes => $attrs,
        );

        $c->dispatcher->register( $c, $action );
    }
}

sub create_action {
    my $self = shift;
    my %args = @_;

    my $class = (exists $args{attributes}{ActionClass}
                    ? $args{attributes}{ActionClass}[0]
                    : $self->_action_class);

    Class::MOP::load_class($class);
    return $class->new( \%args );
}

sub _parse_attrs {
    my ( $self, $c, $name, @attrs ) = @_;

    my %raw_attributes;

    foreach my $attr (@attrs) {

        # Parse out :Foo(bar) into Foo => bar etc (and arrayify)

        if ( my ( $key, $value ) = ( $attr =~ /^(.*?)(?:\(\s*(.+?)\s*\))?$/ ) )
        {

            if ( defined $value ) {
                ( $value =~ s/^'(.*)'$/$1/ ) || ( $value =~ s/^"(.*)"/$1/ );
            }
            push( @{ $raw_attributes{$key} }, $value );
        }
    }

    #I know that the original behavior was to ignore action if actions was set
    # but i actually think this may be a little more sane? we can always remove
    # the merge behavior quite easily and go back to having actions have
    # presedence over action by modifying the keys. i honestly think this is
    # superior while mantaining really high degree of compat
    my $actions;
    if( ref($self) ) {
        $actions = $self->actions;
    } else {
        my $cfg = $self->config;
        $actions = $self->merge_config_hashes($cfg->{actions}, $cfg->{action});
    }

    %raw_attributes = ((exists $actions->{'*'} ? %{$actions->{'*'}} : ()),
                       %raw_attributes,
                       (exists $actions->{$name} ? %{$actions->{$name}} : ()));


    my %final_attributes;

    foreach my $key (keys %raw_attributes) {

        my $raw = $raw_attributes{$key};

        foreach my $value (ref($raw) eq 'ARRAY' ? @$raw : $raw) {

            my $meth = "_parse_${key}_attr";
            if ( my $code = $self->can($meth) ) {
                ( $key, $value ) = $self->$code( $c, $name, $value );
            }
            push( @{ $final_attributes{$key} }, $value );
        }
    }

    return \%final_attributes;
}

sub _parse_Global_attr {
    my ( $self, $c, $name, $value ) = @_;
    return $self->_parse_Path_attr( $c, $name, "/$name" );
}

sub _parse_Absolute_attr { shift->_parse_Global_attr(@_); }

sub _parse_Local_attr {
    my ( $self, $c, $name, $value ) = @_;
    return $self->_parse_Path_attr( $c, $name, $name );
}

sub _parse_Relative_attr { shift->_parse_Local_attr(@_); }

sub _parse_Path_attr {
    my ( $self, $c, $name, $value ) = @_;
    $value ||= '';
    if ( $value =~ m!^/! ) {
        return ( 'Path', $value );
    }
    elsif ( length $value ) {
        return ( 'Path', join( '/', $self->path_prefix($c), $value ) );
    }
    else {
        return ( 'Path', $self->path_prefix($c) );
    }
}

sub _parse_Regex_attr {
    my ( $self, $c, $name, $value ) = @_;
    return ( 'Regex', $value );
}

sub _parse_Regexp_attr { shift->_parse_Regex_attr(@_); }

sub _parse_LocalRegex_attr {
    my ( $self, $c, $name, $value ) = @_;
    unless ( $value =~ s/^\^// ) { $value = "(?:.*?)$value"; }
    return ( 'Regex', '^' . $self->path_prefix($c) . "/${value}" );
}

sub _parse_LocalRegexp_attr { shift->_parse_LocalRegex_attr(@_); }

sub _parse_ActionClass_attr {
    my ( $self, $c, $name, $value ) = @_;
    unless ( $value =~ s/^\+// ) {
      $value = join('::', $self->_action_class, $value );
    }
    return ( 'ActionClass', $value );
}

sub _parse_MyAction_attr {
    my ( $self, $c, $name, $value ) = @_;

    my $appclass = Catalyst::Utils::class2appclass($self);
    $value = "${appclass}::Action::${value}";

    return ( 'ActionClass', $value );
}

no Moose;

1;

__END__

#line 441
