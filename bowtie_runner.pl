#!/usr/bin/perl

use strict;
use warnings;

use JSON::Schema::Modern;
use Mojo::JSON qw(decode_json encode_json false true);
use Mojo::URL;
use Try::Tiny;

my %dialect = (
    'https://json-schema.org/draft/2020-12/schema' => 'draft2020-12',
    'https://json-schema.org/draft/2019-09/schema' => 'draft2019-09',
    'http://json-schema.org/draft-07/schema#'      => 'draft7',
    'http://json-schema.org/draft-06/schema#'      => 'draft6',
    'http://json-schema.org/draft-04/schema#'      => 'draft4',
);

sub resource_pointers_for {
    my ($schema) = @_;
    my %pointers;
    my $walk;
    $walk = sub {
        my ( $node, $pointer, $base ) = @_;
        return if ref $node ne 'HASH';
        my $current = $base;
        if ( defined $node->{'$id'} && !ref $node->{'$id'} ) {
            my $id = $node->{'$id'};
            $current =
              length $base
              ? Mojo::URL->new($id)->to_abs( Mojo::URL->new($base) )->to_string
              : $id;
            $pointers{$current} = $pointer;
        }
        for my $key ( keys %$node ) {
            $walk->( $node->{$key}, "$pointer/$key", $current );
        }
    };
    $walk->( $schema, '', '' );
    return \%pointers;
}

sub keyword_location_for {
    my ( $absolute, $evaluated, $pointers ) = @_;
    my $fragment;
    if ( defined $absolute && length $absolute ) {
        my $hash = index $absolute, '#';
        if ( $hash >= 0 ) {
            my $base = substr $absolute, 0, $hash;
            $fragment = substr $absolute, $hash + 1;
            $fragment = $pointers->{$base} . $fragment
              if length $base && exists $pointers->{$base};
        }
        else {
            $fragment = $absolute;
        }
    }
    else {
        $fragment = defined $evaluated ? $evaluated : '';
    }
    return "#$fragment";
}

sub bowtie_annotations {
    my ( $result, $pointers ) = @_;
    return [] if !$result->valid;
    my @annotations;
    for my $annotation ( $result->annotations ) {
        push @annotations,
          {
            keyword          => $annotation->keyword,
            instanceLocation => $annotation->instance_location,
            keywordLocation  => keyword_location_for(
                $annotation->absolute_keyword_location,
                $annotation->keyword_location,
                $pointers
            ),
            annotation => $annotation->annotation,
          };
    }
    return \@annotations;
}

my $started = 0;
my $schema;
my $os = qx/lsb_release -is/;
chomp $os;
my $os_version = qx/lsb_release -rs/;
chomp $os_version;

my %cmds = (
    start => sub () {
        my $request = shift;
        die 'Wrong version!' unless $request->{version} == 1;
        $started = 1;
        return {
            version        => 1,
            implementation => {
                name     => 'JSON-Schema-Modern',
                version  => $JSON::Schema::Modern::VERSION,
                homepage => 'https://metacpan.org/release/JSON-Schema-Modern/',
                issues   =>
                  'https://github.com/karenetheridge/JSON-Schema-Modern/issues',
                source =>
                  'https://github.com/karenetheridge/JSON-Schema-Modern',
                dialects         => [ keys %dialect ],
                language         => 'perl',
                language_version => $^V,
                os               => $os,
                os_version       => $os_version,
            },
        };
    },
    dialect => sub () {
        my $request = shift;
        die 'Not started!' unless $started;
        if ( exists $dialect{ $request->{dialect} } ) {
            $schema = $dialect{ $request->{dialect} };
            return { ok => true };
        }
        else {
            return { ok => false };
        }
    },
    run => sub () {
        my $request = shift;
        die 'Not started!' unless $started;
        my $js = JSON::Schema::Modern->new( specification_version => $schema );
        my $case = $request->{case};
        my $want_annotations =
          exists $request->{output} && $request->{output} eq 'annotations';
        while ( my ( $url, $content ) = each %{ $case->{registry} } ) {
            try {
                $js->add_schema( $url, $content );
            }
            catch {
                return {
                    errored => true,
                    seq     => $request->{seq},
                    context => { traceback => $_ },
                };
            };
        }
        my $resource_pointers =
          $want_annotations ? resource_pointers_for( $case->{schema} ) : undef;
        my @results = ();
        foreach my $test ( @{ $case->{tests} } ) {
            try {
                my $result =
                  $want_annotations
                  ? $js->evaluate( $test->{instance}, $case->{schema},
                    { collect_annotations => 1 } )
                  : $js->evaluate( $test->{instance}, $case->{schema} );
                push @results,
                  $want_annotations
                  ? {
                    valid       => $result->valid,
                    annotations =>
                      bowtie_annotations( $result, $resource_pointers ),
                  }
                  : { valid => $result->valid };
            }
            catch {
                return {
                    errored => true,
                    seq     => $request->{seq},
                    context => { traceback => $_ },
                };
            };
        }
        return {
            seq     => $request->{seq},
            results => \@results,
        };
    },
    stop => sub () {
        die 'Not started!' unless $started;
        exit;
    },
);

local $| = 1;    # autoflush
while (<>) {
    my $request  = decode_json($_);
    my $response = $cmds{ $request->{cmd} }($request);
    print encode_json($response), "\n";
}
