#line 1
package Catalyst;

use Moose;
extends 'Catalyst::Component';
use bytes;
use Catalyst::Exception;
use Catalyst::Log;
use Catalyst::Request;
use Catalyst::Request::Upload;
use Catalyst::Response;
use Catalyst::Utils;
use Catalyst::Controller;
use Devel::InnerPackage ();
use File::stat;
use Module::Pluggable::Object ();
use Text::SimpleTable ();
use Path::Class::Dir ();
use Path::Class::File ();
use Time::HiRes qw/gettimeofday tv_interval/;
use URI ();
use URI::http;
use URI::https;
use Scalar::Util qw/weaken blessed/;
use Tree::Simple qw/use_weak_refs/;
use Tree::Simple::Visitor::FindByUID;
use attributes;
use utf8;
use Carp qw/croak carp/;

BEGIN { require 5.008001; }

has stack => (is => 'rw', default => sub { [] });
has stash => (is => 'rw', default => sub { {} });
has state => (is => 'rw', default => 0);
has stats => (is => 'rw');
has action => (is => 'rw');
has counter => (is => 'rw', default => sub { {} });
has request => (is => 'rw', default => sub { $_[0]->request_class->new({}) }, required => 1, lazy => 1);
has response => (is => 'rw', default => sub { $_[0]->response_class->new({}) }, required => 1, lazy => 1);
has namespace => (is => 'rw');

attributes->import( __PACKAGE__, \&namespace, 'lvalue' );

sub depth { scalar @{ shift->stack || [] }; }
sub comp { shift->component(@_) }

sub req {
    # carp "the use of req() is deprecated in favour of request()";
    my $self = shift; return $self->request(@_);
}
sub res {
    # carp "the use of res() is deprecated in favour of response()";
    my $self = shift; return $self->response(@_);
}

# For backwards compatibility
sub finalize_output { shift->finalize_body(@_) };

# For statistics
our $COUNT     = 1;
our $START     = time;
our $RECURSION = 1000;
our $DETACH    = "catalyst_detach\n";

#I imagine that very few of these really need to be class variables. if any.
#maybe we should just make them attributes with a default?
__PACKAGE__->mk_classdata($_)
  for qw/components arguments dispatcher engine log dispatcher_class
  engine_class context_class request_class response_class stats_class 
  setup_finished/;

__PACKAGE__->dispatcher_class('Catalyst::Dispatcher');
__PACKAGE__->engine_class('Catalyst::Engine::CGI');
__PACKAGE__->request_class('Catalyst::Request');
__PACKAGE__->response_class('Catalyst::Response');
__PACKAGE__->stats_class('Catalyst::Stats');

# Remember to update this in Catalyst::Runtime as well!

our $VERSION = '5.7013';

sub import {
    my ( $class, @arguments ) = @_;

    # We have to limit $class to Catalyst to avoid pushing Catalyst upon every
    # callers @ISA.
    return unless $class eq 'Catalyst';

    my $caller = caller();
    return if $caller eq 'main';
    my $meta = Moose::Meta::Class->initialize($caller);
    #Moose->import({ into => $caller }); #do we want to do this?

    unless ( $caller->isa('Catalyst') ) {
        my @superclasses = ($meta->superclasses, $class, 'Catalyst::Controller');
        $meta->superclasses(@superclasses);
    }
    unless( $meta->has_method('meta') ){
        $meta->add_method(meta => sub { Moose::Meta::Class->initialize("${caller}") } );
    }

    $caller->arguments( [@arguments] );
    $caller->setup_home;
}

#line 331

sub forward { my $c = shift; no warnings 'recursion'; $c->dispatcher->forward( $c, @_ ) }

#line 346

sub detach { my $c = shift; $c->dispatcher->detach( $c, @_ ) }

#line 373

around stash => sub {
    my $orig = shift;
    my $c = shift;
    my $stash = $orig->($c);
    if (@_) {
        my $new_stash = @_ > 1 ? {@_} : $_[0];
        croak('stash takes a hash or hashref') unless ref $new_stash;
        foreach my $key ( keys %$new_stash ) {
          $stash->{$key} = $new_stash->{$key};
        }
    }

    return $stash;
};


#line 407

sub error {
    my $c = shift;
    if ( $_[0] ) {
        my $error = ref $_[0] eq 'ARRAY' ? $_[0] : [@_];
        croak @$error unless ref $c;
        push @{ $c->{error} }, @$error;
    }
    elsif ( defined $_[0] ) { $c->{error} = undef }
    return $c->{error} || [];
}


#line 434

sub clear_errors {
    my $c = shift;
    $c->error(0);
}


# search via regex
sub _comp_search {
    my ( $c, @names ) = @_;

    foreach my $name (@names) {
        foreach my $component ( keys %{ $c->components } ) {
            return $c->components->{$component} if $component =~ /$name/i;
        }
    }

    return undef;
}

# try explicit component names
sub _comp_explicit {
    my ( $c, @names ) = @_;

    foreach my $try (@names) {
        return $c->components->{$try} if ( exists $c->components->{$try} );
    }

    return undef;
}

# like component, but try just these prefixes before regex searching,
#  and do not try to return "sort keys %{ $c->components }"
sub _comp_prefixes {
    my ( $c, $name, @prefixes ) = @_;

    my $appclass = ref $c || $c;

    my @names = map { "${appclass}::${_}::${name}" } @prefixes;

    my $comp = $c->_comp_explicit(@names);
    return $comp if defined($comp);
    $comp = $c->_comp_search($name);
    return $comp;
}

# Find possible names for a prefix 

sub _comp_names {
    my ( $c, @prefixes ) = @_;

    my $appclass = ref $c || $c;

    my @pre = map { "${appclass}::${_}::" } @prefixes;

    my @names;

    COMPONENT: foreach my $comp ($c->component) {
        foreach my $p (@pre) {
            if ($comp =~ s/^$p//) {
                push(@names, $comp);
                next COMPONENT;
            }
        }
    }

    return @names;
}

# Return a component if only one matches.
sub _comp_singular {
    my ( $c, @prefixes ) = @_;

    my $appclass = ref $c || $c;

    my ( $comp, $rest ) =
      map { $c->_comp_search("^${appclass}::${_}::") } @prefixes;
    return $comp unless $rest;
}

# Filter a component before returning by calling ACCEPT_CONTEXT if available
sub _filter_component {
    my ( $c, $comp, @args ) = @_;
    if ( eval { $comp->can('ACCEPT_CONTEXT'); } ) {
        return $comp->ACCEPT_CONTEXT( $c, @args );
    }
    else { return $comp }
}

#line 535

sub controller {
    my ( $c, $name, @args ) = @_;
    return $c->_filter_component( $c->_comp_prefixes( $name, qw/Controller C/ ),
        @args )
      if ($name);
    return $c->component( $c->action->class );
}

#line 559

sub model {
    my ( $c, $name, @args ) = @_;
    return $c->_filter_component( $c->_comp_prefixes( $name, qw/Model M/ ),
        @args )
      if $name;
    if (ref $c) {
        return $c->stash->{current_model_instance} 
          if $c->stash->{current_model_instance};
        return $c->model( $c->stash->{current_model} )
          if $c->stash->{current_model};
    }
    return $c->model( $c->config->{default_model} )
      if $c->config->{default_model};
    return $c->_filter_component( $c->_comp_singular(qw/Model M/) );

}

#line 582

sub controllers {
    my ( $c ) = @_;
    return $c->_comp_names(qw/Controller C/);
}


#line 604

sub view {
    my ( $c, $name, @args ) = @_;
    return $c->_filter_component( $c->_comp_prefixes( $name, qw/View V/ ),
        @args )
      if $name;
    if (ref $c) {
        return $c->stash->{current_view_instance} 
          if $c->stash->{current_view_instance};
        return $c->view( $c->stash->{current_view} )
          if $c->stash->{current_view};
    }
    return $c->view( $c->config->{default_view} )
      if $c->config->{default_view};
    return $c->_filter_component( $c->_comp_singular(qw/View V/) );
}

#line 626

sub models {
    my ( $c ) = @_;
    return $c->_comp_names(qw/Model M/);
}


#line 638

sub views {
    my ( $c ) = @_;
    return $c->_comp_names(qw/View V/);
}

#line 654

sub component {
    my $c = shift;

    if (@_) {

        my $name = shift;

        my $appclass = ref $c || $c;

        my @names = (
            $name, "${appclass}::${name}",
            map { "${appclass}::${_}::${name}" }
              qw/Model M Controller C View V/
        );

        my $comp = $c->_comp_explicit(@names);
        return $c->_filter_component( $comp, @_ ) if defined($comp);

        $comp = $c->_comp_search($name);
        return $c->_filter_component( $comp, @_ ) if defined($comp);
    }

    return sort keys %{ $c->components };
}



#line 699

around config => sub {
    my $orig = shift;
    my $c = shift;

    $c->log->warn("Setting config after setup has been run is not a good idea.")
      if ( @_ and $c->setup_finished );

    $c->$orig(@_);
};

#line 736

sub debug { 0 }

#line 762

sub path_to {
    my ( $c, @path ) = @_;
    my $path = Path::Class::Dir->new( $c->config->{home}, @path );
    if ( -d $path ) { return $path }
    else { return Path::Class::File->new( $c->config->{home}, @path ) }
}

#line 780

sub plugin {
    my ( $class, $name, $plugin, @args ) = @_;
    $class->_register_plugin( $plugin, 1 );

    eval { $plugin->import };
    $class->mk_classdata($name);
    my $obj;
    eval { $obj = $plugin->new(@args) };

    if ($@) {
        Catalyst::Exception->throw( message =>
              qq/Couldn't instantiate instant plugin "$plugin", "$@"/ );
    }

    $class->$name($obj);
    $class->log->debug(qq/Initialized instant plugin "$plugin" as "$name"/)
      if $class->debug;
}

#line 811

sub setup {
    my ( $class, @arguments ) = @_;
    $class->log->warn("Running setup twice is not a good idea.")
      if ( $class->setup_finished );

    unless ( $class->isa('Catalyst') ) {

        Catalyst::Exception->throw(
            message => qq/'$class' does not inherit from Catalyst/ );
    }

    if ( $class->arguments ) {
        @arguments = ( @arguments, @{ $class->arguments } );
    }

    # Process options
    my $flags = {};

    foreach (@arguments) {

        if (/^-Debug$/) {
            $flags->{log} =
              ( $flags->{log} ) ? 'debug,' . $flags->{log} : 'debug';
        }
        elsif (/^-(\w+)=?(.*)$/) {
            $flags->{ lc $1 } = $2;
        }
        else {
            push @{ $flags->{plugins} }, $_;
        }
    }

    $class->setup_home( delete $flags->{home} );

    $class->setup_log( delete $flags->{log} );
    $class->setup_plugins( delete $flags->{plugins} );
    $class->setup_dispatcher( delete $flags->{dispatcher} );
    $class->setup_engine( delete $flags->{engine} );
    $class->setup_stats( delete $flags->{stats} );

    for my $flag ( sort keys %{$flags} ) {

        if ( my $code = $class->can( 'setup_' . $flag ) ) {
            &$code( $class, delete $flags->{$flag} );
        }
        else {
            $class->log->warn(qq/Unknown flag "$flag"/);
        }
    }

    eval { require Catalyst::Devel; };
    if( !$@ && $ENV{CATALYST_SCRIPT_GEN} && ( $ENV{CATALYST_SCRIPT_GEN} < $Catalyst::Devel::CATALYST_SCRIPT_GEN ) ) {
        $class->log->warn(<<"EOF");
You are running an old script!

  Please update by running (this will overwrite existing files):
    catalyst.pl -force -scripts $class

  or (this will not overwrite existing files):
    catalyst.pl -scripts $class

EOF
    }
    
    if ( $class->debug ) {
        my @plugins = map { "$_  " . ( $_->VERSION || '' ) } $class->registered_plugins;

        if (@plugins) {
            my $t = Text::SimpleTable->new(74);
            $t->row($_) for @plugins;
            $class->log->debug( "Loaded plugins:\n" . $t->draw . "\n" );
        }

        my $dispatcher = $class->dispatcher;
        my $engine     = $class->engine;
        my $home       = $class->config->{home};

        $class->log->debug(qq/Loaded dispatcher "$dispatcher"/);
        $class->log->debug(qq/Loaded engine "$engine"/);

        $home
          ? ( -d $home )
          ? $class->log->debug(qq/Found home "$home"/)
          : $class->log->debug(qq/Home "$home" doesn't exist/)
          : $class->log->debug(q/Couldn't find home/);
    }

    # Call plugins setup
    {
        no warnings qw/redefine/;
        local *setup = sub { };
        $class->setup;
    }

    # Initialize our data structure
    $class->components( {} );

    $class->setup_components;

    if ( $class->debug ) {
        my $t = Text::SimpleTable->new( [ 63, 'Class' ], [ 8, 'Type' ] );
        for my $comp ( sort keys %{ $class->components } ) {
            my $type = ref $class->components->{$comp} ? 'instance' : 'class';
            $t->row( $comp, $type );
        }
        $class->log->debug( "Loaded components:\n" . $t->draw . "\n" )
          if ( keys %{ $class->components } );
    }

    # Add our self to components, since we are also a component
    if( $class->isa('Catalyst::Controller') ){
      $class->components->{$class} = $class;
    }

    $class->setup_actions;

    if ( $class->debug ) {
        my $name = $class->config->{name} || 'Application';
        $class->log->info("$name powered by Catalyst $Catalyst::VERSION");
    }
    $class->log->_flush() if $class->log->can('_flush');

    $class->setup_finished(1);
}

#line 956

sub uri_for {
    my ( $c, $path, @args ) = @_;

    if ( Scalar::Util::blessed($path) ) { # action object
        my $captures = ( scalar @args && ref $args[0] eq 'ARRAY'
                         ? shift(@args)
                         : [] );
        $path = $c->dispatcher->uri_for_action($path, $captures);
        return undef unless defined($path);
        $path = '/' if $path eq '';
    }

    undef($path) if (defined $path && $path eq '');

    my $params =
      ( scalar @args && ref $args[$#args] eq 'HASH' ? pop @args : {} );

    carp "uri_for called with undef argument" if grep { ! defined $_ } @args;
    s/([^$URI::uric])/$URI::Escape::escapes{$1}/go for @args;

    unshift(@args, $path);

    unless (defined $path && $path =~ s!^/!!) { # in-place strip
        my $namespace = $c->namespace;
        if (defined $path) { # cheesy hack to handle path '../foo'
           $namespace =~ s{(?:^|/)[^/]+$}{} while $args[0] =~ s{^\.\./}{};
        }
        unshift(@args, $namespace || '');
    }
    
    # join args with '/', or a blank string
    my $args = join('/', grep { defined($_) } @args);
    $args =~ s/\?/%3F/g; # STUPID STUPID SPECIAL CASE
    $args =~ s!^/!!;
    my $base = $c->req->base;
    my $class = ref($base);
    $base =~ s{(?<!/)$}{/};

    my $query = '';

    if (my @keys = keys %$params) {
      # somewhat lifted from URI::_query's query_form
      $query = '?'.join('&', map {
          s/([;\/?:@&=+,\$\[\]%])/$URI::Escape::escapes{$1}/go;
          s/ /+/g;
          my $key = $_;
          my $val = $params->{$_};
          $val = '' unless defined $val;
          (map {
              $_ = "$_";
              utf8::encode( $_ ) if utf8::is_utf8($_);
              # using the URI::Escape pattern here so utf8 chars survive
              s/([^A-Za-z0-9\-_.!~*'() ])/$URI::Escape::escapes{$1}/go;
              s/ /+/g;
              "${key}=$_"; } ( ref $val eq 'ARRAY' ? @$val : $val ));
      } @keys);
    }

    my $res = bless(\"${base}${args}${query}", $class);
    $res;
}

#line 1024

sub welcome_message {
    my $c      = shift;
    my $name   = $c->config->{name};
    my $logo   = $c->uri_for('/static/images/catalyst_logo.png');
    my $prefix = Catalyst::Utils::appprefix( ref $c );
    $c->response->content_type('text/html; charset=utf-8');
    return <<"EOF";
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN"
    "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
    <head>
    <meta http-equiv="Content-Language" content="en" />
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
        <title>$name on Catalyst $VERSION</title>
        <style type="text/css">
            body {
                color: #000;
                background-color: #eee;
            }
            div#content {
                width: 640px;
                margin-left: auto;
                margin-right: auto;
                margin-top: 10px;
                margin-bottom: 10px;
                text-align: left;
                background-color: #ccc;
                border: 1px solid #aaa;
            }
            p, h1, h2 {
                margin-left: 20px;
                margin-right: 20px;
                font-family: verdana, tahoma, sans-serif;
            }
            a {
                font-family: verdana, tahoma, sans-serif;
            }
            :link, :visited {
                    text-decoration: none;
                    color: #b00;
                    border-bottom: 1px dotted #bbb;
            }
            :link:hover, :visited:hover {
                    color: #555;
            }
            div#topbar {
                margin: 0px;
            }
            pre {
                margin: 10px;
                padding: 8px;
            }
            div#answers {
                padding: 8px;
                margin: 10px;
                background-color: #fff;
                border: 1px solid #aaa;
            }
            h1 {
                font-size: 0.9em;
                font-weight: normal;
                text-align: center;
            }
            h2 {
                font-size: 1.0em;
            }
            p {
                font-size: 0.9em;
            }
            p img {
                float: right;
                margin-left: 10px;
            }
            span#appname {
                font-weight: bold;
                font-size: 1.6em;
            }
        </style>
    </head>
    <body>
        <div id="content">
            <div id="topbar">
                <h1><span id="appname">$name</span> on <a href="http://catalyst.perl.org">Catalyst</a>
                    $VERSION</h1>
             </div>
             <div id="answers">
                 <p>
                 <img src="$logo" alt="Catalyst Logo" />
                 </p>
                 <p>Welcome to the  world of Catalyst.
                    This <a href="http://en.wikipedia.org/wiki/MVC">MVC</a>
                    framework will make web development something you had
                    never expected it to be: Fun, rewarding, and quick.</p>
                 <h2>What to do now?</h2>
                 <p>That really depends  on what <b>you</b> want to do.
                    We do, however, provide you with a few starting points.</p>
                 <p>If you want to jump right into web development with Catalyst
                    you might want want to start with a tutorial.</p>
<pre>perldoc <a href="http://cpansearch.perl.org/dist/Catalyst-Manual/lib/Catalyst/Manual/Tutorial.pod">Catalyst::Manual::Tutorial</a></code>
</pre>
<p>Afterwards you can go on to check out a more complete look at our features.</p>
<pre>
<code>perldoc <a href="http://cpansearch.perl.org/dist/Catalyst-Manual/lib/Catalyst/Manual/Intro.pod">Catalyst::Manual::Intro</a>
<!-- Something else should go here, but the Catalyst::Manual link seems unhelpful -->
</code></pre>
                 <h2>What to do next?</h2>
                 <p>Next it's time to write an actual application. Use the
                    helper scripts to generate <a href="http://cpansearch.perl.org/search?query=Catalyst%3A%3AController%3A%3A&amp;mode=all">controllers</a>,
                    <a href="http://cpansearch.perl.org/search?query=Catalyst%3A%3AModel%3A%3A&amp;mode=all">models</a>, and
                    <a href="http://cpansearch.perl.org/search?query=Catalyst%3A%3AView%3A%3A&amp;mode=all">views</a>;
                    they can save you a lot of work.</p>
                    <pre><code>script/${prefix}_create.pl -help</code></pre>
                    <p>Also, be sure to check out the vast and growing
                    collection of <a href="http://cpansearch.perl.org/search?query=Catalyst%3A%3APlugin%3A%3A&amp;mode=all">plugins for Catalyst on CPAN</a>;
                    you are likely to find what you need there.
                    </p>

                 <h2>Need help?</h2>
                 <p>Catalyst has a very active community. Here are the main places to
                    get in touch with us.</p>
                 <ul>
                     <li>
                         <a href="http://dev.catalyst.perl.org">Wiki</a>
                     </li>
                     <li>
                         <a href="http://lists.rawmode.org/mailman/listinfo/catalyst">Mailing-List</a>
                     </li>
                     <li>
                         <a href="irc://irc.perl.org/catalyst">IRC channel #catalyst on irc.perl.org</a>
                     </li>
                 </ul>
                 <h2>In conclusion</h2>
                 <p>The Catalyst team hopes you will enjoy using Catalyst as much 
                    as we enjoyed making it. Please contact us if you have ideas
                    for improvement or other feedback.</p>
             </div>
         </div>
    </body>
</html>
EOF
}

#line 1193

sub dispatch { my $c = shift; $c->dispatcher->dispatch( $c, @_ ) }

#line 1206

sub dump_these {
    my $c = shift;
    [ Request => $c->req ], 
    [ Response => $c->res ], 
    [ Stash => $c->stash ],
    [ Config => $c->config ];
}

#line 1225

sub execute {
    my ( $c, $class, $code ) = @_;
    $class = $c->component($class) || $class;
    $c->state(0);

    if ( $c->depth >= $RECURSION ) {
        my $action = $code->reverse();
        $action = "/$action" unless $action =~ /->/;
        my $error = qq/Deep recursion detected calling "${action}"/;
        $c->log->error($error);
        $c->error($error);
        $c->state(0);
        return $c->state;
    }

    my $stats_info = $c->_stats_start_execute( $code ) if $c->use_stats;

    push( @{ $c->stack }, $code );
    
    eval { $c->state( $code->execute( $class, $c, @{ $c->req->args } ) || 0 ) };

    $c->_stats_finish_execute( $stats_info ) if $c->use_stats and $stats_info;
    
    my $last = pop( @{ $c->stack } );

    if ( my $error = $@ ) {
        if ( !ref($error) and $error eq $DETACH ) { die $DETACH if $c->depth > 1 }
        else {
            unless ( ref $error ) {
                no warnings 'uninitialized';
                chomp $error;
                my $class = $last->class;
                my $name  = $last->name;
                $error = qq/Caught exception in $class->$name "$error"/;
            }
            $c->error($error);
            $c->state(0);
        }
    }
    return $c->state;
}

sub _stats_start_execute {
    my ( $c, $code ) = @_;

    return if ( ( $code->name =~ /^_.*/ )
        && ( !$c->config->{show_internal_actions} ) );

    my $action_name = $code->reverse();
    $c->counter->{$action_name}++;

    my $action = $action_name;
    $action = "/$action" unless $action =~ /->/;

    # determine if the call was the result of a forward
    # this is done by walking up the call stack and looking for a calling
    # sub of Catalyst::forward before the eval
    my $callsub = q{};
    for my $index ( 2 .. 11 ) {
        last
        if ( ( caller($index) )[0] eq 'Catalyst'
            && ( caller($index) )[3] eq '(eval)' );

        if ( ( caller($index) )[3] =~ /forward$/ ) {
            $callsub = ( caller($index) )[3];
            $action  = "-> $action";
            last;
        }
    }

    my $uid = $action_name . $c->counter->{$action_name};

    # is this a root-level call or a forwarded call?
    if ( $callsub =~ /forward$/ ) {

        # forward, locate the caller
        if ( my $parent = $c->stack->[-1] ) {
            $c->stats->profile(
                begin  => $action, 
                parent => "$parent" . $c->counter->{"$parent"},
                uid    => $uid,
            );
        }
        else {

            # forward with no caller may come from a plugin
            $c->stats->profile(
                begin => $action,
                uid   => $uid,
            );
        }
    }
    else {
        
        # root-level call
        $c->stats->profile(
            begin => $action,
            uid   => $uid,
        );
    }
    return $action;

}

sub _stats_finish_execute {
    my ( $c, $info ) = @_;
    $c->stats->profile( end => $info );
}

#line 1338

#Why does this exist? This is no longer safe and WILL NOT WORK.
# it doesnt seem to be used anywhere. can we remove it?
sub _localize_fields {
    my ( $c, $localized, $code ) = ( @_ );

    my $request = delete $localized->{request} || {};
    my $response = delete $localized->{response} || {};
    
    local @{ $c }{ keys %$localized } = values %$localized;
    local @{ $c->request }{ keys %$request } = values %$request;
    local @{ $c->response }{ keys %$response } = values %$response;

    $code->();
}

#line 1359

sub finalize {
    my $c = shift;

    for my $error ( @{ $c->error } ) {
        $c->log->error($error);
    }

    # Allow engine to handle finalize flow (for POE)
    my $engine = $c->engine;
    if ( my $code = $engine->can('finalize') ) {
        $engine->$code($c);
    }
    else {

        $c->finalize_uploads;

        # Error
        if ( $#{ $c->error } >= 0 ) {
            $c->finalize_error;
        }

        $c->finalize_headers;

        # HEAD request
        if ( $c->request->method eq 'HEAD' ) {
            $c->response->body('');
        }

        $c->finalize_body;
    }
    
    if ($c->use_stats) {        
        my $elapsed = sprintf '%f', $c->stats->elapsed;
        my $av = $elapsed == 0 ? '??' : sprintf '%.3f', 1 / $elapsed;
        $c->log->info(
            "Request took ${elapsed}s ($av/s)\n" . $c->stats->report . "\n" );        
    }

    return $c->response->status;
}

#line 1406

sub finalize_body { my $c = shift; $c->engine->finalize_body( $c, @_ ) }

#line 1414

sub finalize_cookies { my $c = shift; $c->engine->finalize_cookies( $c, @_ ) }

#line 1422

sub finalize_error { my $c = shift; $c->engine->finalize_error( $c, @_ ) }

#line 1430

sub finalize_headers {
    my $c = shift;

    my $response = $c->response; #accessor calls can add up?

    # Check if we already finalized headers
    return if $response->finalized_headers;

    # Handle redirects
    if ( my $location = $response->redirect ) {
        $c->log->debug(qq/Redirecting to "$location"/) if $c->debug;
        $response->header( Location => $location );

        #Moose TODO: we should probably be using a predicate method here ?
        if ( !$response->body ) {
            # Add a default body if none is already present
            $response->body(
                qq{<html><body><p>This item has moved <a href="$location">here</a>.</p></body></html>}
            );
        }
    }

    # Content-Length
    if ( $response->body && !$response->content_length ) {

        # get the length from a filehandle
        if ( blessed( $response->body ) && $response->body->can('read') )
        {
            my $stat = stat $response->body;
            if ( $stat && $stat->size > 0 ) {
                $response->content_length( $stat->size );
            }
            else {
                $c->log->warn('Serving filehandle without a content-length');
            }
        }
        else {
            # everything should be bytes at this point, but just in case
            $response->content_length( bytes::length( $response->body ) );
        }
    }

    # Errors
    if ( $response->status =~ /^(1\d\d|[23]04)$/ ) {
        $response->headers->remove_header("Content-Length");
        $response->body('');
    }

    $c->finalize_cookies;

    $c->engine->finalize_headers( $c, @_ );

    # Done
    $response->finalized_headers(1);
}

#line 1496

sub finalize_read { my $c = shift; $c->engine->finalize_read( $c, @_ ) }

#line 1504

sub finalize_uploads { my $c = shift; $c->engine->finalize_uploads( $c, @_ ) }

#line 1512

sub get_action { my $c = shift; $c->dispatcher->get_action(@_) }

#line 1521

sub get_actions { my $c = shift; $c->dispatcher->get_actions( $c, @_ ) }

#line 1529

sub handle_request {
    my ( $class, @arguments ) = @_;

    # Always expect worst case!
    my $status = -1;
    eval {
        if ($class->debug) {
            my $secs = time - $START || 1;
            my $av = sprintf '%.3f', $COUNT / $secs;
            my $time = localtime time;
            $class->log->info("*** Request $COUNT ($av/s) [$$] [$time] ***");
        }

        my $c = $class->prepare(@arguments);
        $c->dispatch;
        $status = $c->finalize;   
    };

    if ( my $error = $@ ) {
        chomp $error;
        $class->log->error(qq/Caught exception in engine "$error"/);
    }

    $COUNT++;
    
    if(my $coderef = $class->log->can('_flush')){
        $class->log->$coderef();
    }
    return $status;
}

#line 1567

sub prepare {
    my ( $class, @arguments ) = @_;

    # XXX
    # After the app/ctxt split, this should become an attribute based on something passed
    # into the application.
    $class->context_class( ref $class || $class ) unless $class->context_class;
   
    my $c = $class->context_class->new({});

    # For on-demand data
    $c->request->_context($c);
    $c->response->_context($c);

    #surely this is not the most efficient way to do things...
    $c->stats($class->stats_class->new)->enable($c->use_stats);
    if ( $c->debug ) {
        $c->res->headers->header( 'X-Catalyst' => $Catalyst::VERSION );            
    }

    #XXX reuse coderef from can
    # Allow engine to direct the prepare flow (for POE)
    if ( $c->engine->can('prepare') ) {
        $c->engine->prepare( $c, @arguments );
    }
    else {
        $c->prepare_request(@arguments);
        $c->prepare_connection;
        $c->prepare_query_parameters;
        $c->prepare_headers;
        $c->prepare_cookies;
        $c->prepare_path;

        # Prepare the body for reading, either by prepare_body
        # or the user, if they are using $c->read
        $c->prepare_read;
        
        # Parse the body unless the user wants it on-demand
        unless ( $c->config->{parse_on_demand} ) {
            $c->prepare_body;
        }
    }

    my $method  = $c->req->method  || '';
    my $path    = $c->req->path    || '/';
    my $address = $c->req->address || '';

    $c->log->debug(qq/"$method" request for "$path" from "$address"/)
      if $c->debug;

    $c->prepare_action;

    return $c;
}

#line 1628

sub prepare_action { my $c = shift; $c->dispatcher->prepare_action( $c, @_ ) }

#line 1636

sub prepare_body {
    my $c = shift;

    #Moose TODO: what is  _body ??
    # Do we run for the first time?
    return if defined $c->request->{_body};

    # Initialize on-demand data
    $c->engine->prepare_body( $c, @_ );
    $c->prepare_parameters;
    $c->prepare_uploads;

    if ( $c->debug && keys %{ $c->req->body_parameters } ) {
        my $t = Text::SimpleTable->new( [ 35, 'Parameter' ], [ 36, 'Value' ] );
        for my $key ( sort keys %{ $c->req->body_parameters } ) {
            my $param = $c->req->body_parameters->{$key};
            my $value = defined($param) ? $param : '';
            $t->row( $key,
                ref $value eq 'ARRAY' ? ( join ', ', @$value ) : $value );
        }
        $c->log->debug( "Body Parameters are:\n" . $t->draw );
    }
}

#line 1668

sub prepare_body_chunk {
    my $c = shift;
    $c->engine->prepare_body_chunk( $c, @_ );
}

#line 1679

sub prepare_body_parameters {
    my $c = shift;
    $c->engine->prepare_body_parameters( $c, @_ );
}

#line 1690

sub prepare_connection {
    my $c = shift;
    $c->engine->prepare_connection( $c, @_ );
}

#line 1701

sub prepare_cookies { my $c = shift; $c->engine->prepare_cookies( $c, @_ ) }

#line 1709

sub prepare_headers { my $c = shift; $c->engine->prepare_headers( $c, @_ ) }

#line 1717

sub prepare_parameters {
    my $c = shift;
    $c->prepare_body_parameters;
    $c->engine->prepare_parameters( $c, @_ );
}

#line 1729

sub prepare_path { my $c = shift; $c->engine->prepare_path( $c, @_ ) }

#line 1737

sub prepare_query_parameters {
    my $c = shift;

    $c->engine->prepare_query_parameters( $c, @_ );

    if ( $c->debug && keys %{ $c->request->query_parameters } ) {
        my $t = Text::SimpleTable->new( [ 35, 'Parameter' ], [ 36, 'Value' ] );
        for my $key ( sort keys %{ $c->req->query_parameters } ) {
            my $param = $c->req->query_parameters->{$key};
            my $value = defined($param) ? $param : '';
            $t->row( $key,
                ref $value eq 'ARRAY' ? ( join ', ', @$value ) : $value );
        }
        $c->log->debug( "Query Parameters are:\n" . $t->draw );
    }
}

#line 1760

sub prepare_read { my $c = shift; $c->engine->prepare_read( $c, @_ ) }

#line 1768

sub prepare_request { my $c = shift; $c->engine->prepare_request( $c, @_ ) }

#line 1776

sub prepare_uploads {
    my $c = shift;

    $c->engine->prepare_uploads( $c, @_ );

    if ( $c->debug && keys %{ $c->request->uploads } ) {
        my $t = Text::SimpleTable->new(
            [ 12, 'Parameter' ],
            [ 26, 'Filename' ],
            [ 18, 'Type' ],
            [ 9,  'Size' ]
        );
        for my $key ( sort keys %{ $c->request->uploads } ) {
            my $upload = $c->request->uploads->{$key};
            for my $u ( ref $upload eq 'ARRAY' ? @{$upload} : ($upload) ) {
                $t->row( $key, $u->filename, $u->type, $u->size );
            }
        }
        $c->log->debug( "File Uploads are:\n" . $t->draw );
    }
}

#line 1804

sub prepare_write { my $c = shift; $c->engine->prepare_write( $c, @_ ) }

#line 1829

sub read { my $c = shift; return $c->engine->read( $c, @_ ) }

#line 1837

sub run { my $c = shift; return $c->engine->run( $c, @_ ) }

#line 1845

sub set_action { my $c = shift; $c->dispatcher->set_action( $c, @_ ) }

#line 1853

sub setup_actions { my $c = shift; $c->dispatcher->setup_actions( $c, @_ ) }

#line 1865

sub setup_components {
    my $class = shift;

    my @paths   = qw( ::Controller ::C ::Model ::M ::View ::V );
    my $config  = $class->config->{ setup_components };
    my $extra   = delete $config->{ search_extra } || [];
    
    push @paths, @$extra;
        
    my $locator = Module::Pluggable::Object->new(
        search_path => [ map { s/^(?=::)/$class/; $_; } @paths ],
        %$config
    );

    my @comps = sort { length $a <=> length $b } $locator->plugins;
    my %comps = map { $_ => 1 } @comps;
    
    for my $component ( @comps ) {

        # We pass ignore_loaded here so that overlay files for (e.g.)
        # Model::DBI::Schema sub-classes are loaded - if it's in @comps
        # we know M::P::O found a file on disk so this is safe

        Catalyst::Utils::ensure_class_loaded( $component, { ignore_loaded => 1 } );
        #Class::MOP::load_class($component);

        my $module  = $class->setup_component( $component );
        my %modules = (
            $component => $module,
            map {
                $_ => $class->setup_component( $_ )
            } grep { 
              not exists $comps{$_}
            } Devel::InnerPackage::list_packages( $component )
        );
        
        for my $key ( keys %modules ) {
            $class->components->{ $key } = $modules{ $key };
        }
    }
}

#line 1911

sub setup_component {
    my( $class, $component ) = @_;

    unless ( $component->can( 'COMPONENT' ) ) {
        return $component;
    }

    my $suffix = Catalyst::Utils::class2classsuffix( $component );
    my $config = $class->config->{ $suffix } || {};

    my $instance = eval { $component->COMPONENT( $class, $config ); };

    if ( my $error = $@ ) {
        chomp $error;
        Catalyst::Exception->throw(
            message => qq/Couldn't instantiate component "$component", "$error"/
        );
    }

    Catalyst::Exception->throw(
        message =>
        qq/Couldn't instantiate component "$component", "COMPONENT() didn't return an object-like value"/
    ) unless blessed($instance);

    return $instance;
}

#line 1944

sub setup_dispatcher {
    my ( $class, $dispatcher ) = @_;

    if ($dispatcher) {
        $dispatcher = 'Catalyst::Dispatcher::' . $dispatcher;
    }

    if ( my $env = Catalyst::Utils::env_value( $class, 'DISPATCHER' ) ) {
        $dispatcher = 'Catalyst::Dispatcher::' . $env;
    }

    unless ($dispatcher) {
        $dispatcher = $class->dispatcher_class;
    }

    Class::MOP::load_class($dispatcher);

    # dispatcher instance
    $class->dispatcher( $dispatcher->new );
}

#line 1971

sub setup_engine {
    my ( $class, $engine ) = @_;

    if ($engine) {
        $engine = 'Catalyst::Engine::' . $engine;
    }

    if ( my $env = Catalyst::Utils::env_value( $class, 'ENGINE' ) ) {
        $engine = 'Catalyst::Engine::' . $env;
    }

    if ( $ENV{MOD_PERL} ) {

        # create the apache method
        $class->meta->add_method('apache' => sub { shift->engine->apache });

        my ( $software, $version ) =
          $ENV{MOD_PERL} =~ /^(\S+)\/(\d+(?:[\.\_]\d+)+)/;

        $version =~ s/_//g;
        $version =~ s/(\.[^.]+)\./$1/g;

        if ( $software eq 'mod_perl' ) {

            if ( !$engine ) {

                if ( $version >= 1.99922 ) {
                    $engine = 'Catalyst::Engine::Apache2::MP20';
                }

                elsif ( $version >= 1.9901 ) {
                    $engine = 'Catalyst::Engine::Apache2::MP19';
                }

                elsif ( $version >= 1.24 ) {
                    $engine = 'Catalyst::Engine::Apache::MP13';
                }

                else {
                    Catalyst::Exception->throw( message =>
                          qq/Unsupported mod_perl version: $ENV{MOD_PERL}/ );
                }

            }

            # install the correct mod_perl handler
            if ( $version >= 1.9901 ) {
                *handler = sub  : method {
                    shift->handle_request(@_);
                };
            }
            else {
                *handler = sub ($$) { shift->handle_request(@_) };
            }

        }

        elsif ( $software eq 'Zeus-Perl' ) {
            $engine = 'Catalyst::Engine::Zeus';
        }

        else {
            Catalyst::Exception->throw(
                message => qq/Unsupported mod_perl: $ENV{MOD_PERL}/ );
        }
    }

    unless ($engine) {
        $engine = $class->engine_class;
    }

    Class::MOP::load_class($engine);
    #unless (Class::Inspector->loaded($engine)) {
    #    require Class::Inspector->filename($engine);
    #}

    # check for old engines that are no longer compatible
    my $old_engine;
    if ( $engine->isa('Catalyst::Engine::Apache')
        && !Catalyst::Engine::Apache->VERSION )
    {
        $old_engine = 1;
    }

    elsif ( $engine->isa('Catalyst::Engine::Server::Base')
        && Catalyst::Engine::Server->VERSION le '0.02' )
    {
        $old_engine = 1;
    }

    elsif ($engine->isa('Catalyst::Engine::HTTP::POE')
        && $engine->VERSION eq '0.01' )
    {
        $old_engine = 1;
    }

    elsif ($engine->isa('Catalyst::Engine::Zeus')
        && $engine->VERSION eq '0.01' )
    {
        $old_engine = 1;
    }

    if ($old_engine) {
        Catalyst::Exception->throw( message =>
              qq/Engine "$engine" is not supported by this version of Catalyst/
        );
    }

    # engine instance
    $class->engine( $engine->new );
}

#line 2089

sub setup_home {
    my ( $class, $home ) = @_;

    if ( my $env = Catalyst::Utils::env_value( $class, 'HOME' ) ) {
        $home = $env;
    }

    $home ||= Catalyst::Utils::home($class);

    if ($home) {
        #I remember recently being scolded for assigning config values like this
        $class->config->{home} ||= $home;
        $class->config->{root} ||= Path::Class::Dir->new($home)->subdir('root');
    }
}

#line 2111

sub setup_log {
    my ( $class, $debug ) = @_;

    unless ( $class->log ) {
        $class->log( Catalyst::Log->new );
    }

    my $env_debug = Catalyst::Utils::env_value( $class, 'DEBUG' );
    if ( defined($env_debug) ? $env_debug : $debug ) {
        $class->meta->add_method('debug' => sub { 1 });
        $class->log->debug('Debug messages enabled');
    }
}

#line 2131

#line 2137

sub setup_stats {
    my ( $class, $stats ) = @_;

    Catalyst::Utils::ensure_class_loaded($class->stats_class);

    my $env = Catalyst::Utils::env_value( $class, 'STATS' );
    if ( defined($env) ? $env : ($stats || $class->debug ) ) {
        $class->meta->add_method('use_stats' => sub { 1 });
        $class->log->debug('Statistics enabled');
    }
}


#line 2165

{

    sub registered_plugins {
        my $proto = shift;
        return sort keys %{ $proto->_plugins } unless @_;
        my $plugin = shift;
        return 1 if exists $proto->_plugins->{$plugin};
        return exists $proto->_plugins->{"Catalyst::Plugin::$plugin"};
    }

    sub _register_plugin {
        my ( $proto, $plugin, $instant ) = @_;
        my $class = ref $proto || $proto;

        # no ignore_loaded here, the plugin may already have been
        # defined in memory and we don't want to error on "no file" if so

        Class::MOP::load_class( $plugin );

        $proto->_plugins->{$plugin} = 1;
        unless ($instant) {
            no strict 'refs';
            if( $class->can('meta') ){
              my @superclasses = ($plugin, $class->meta->superclasses );
              $class->meta->superclasses(@superclasses);
            } else {
              unshift @{"$class\::ISA"}, $plugin;
            }
        }
        return $class;
    }

    sub setup_plugins {
        my ( $class, $plugins ) = @_;

        $class->_plugins( {} ) unless $class->_plugins;
        $plugins ||= [];
        for my $plugin ( reverse @$plugins ) {

            unless ( $plugin =~ s/\A\+// ) {
                $plugin = "Catalyst::Plugin::$plugin";
            }

            $class->_register_plugin($plugin);
        }
    }
}

#line 2233

sub use_stats { 0 }


#line 2244

sub write {
    my $c = shift;

    # Finalize headers if someone manually writes output
    $c->finalize_headers;

    return $c->engine->write( $c, @_ );
}

#line 2260

sub version { return $Catalyst::VERSION }

#line 2448

no Moose;

1;
