#!/usr/bin/env perl

use strict;
use warnings;

package VideoProcessor;

use Moose;

use Const::Fast qw( const );
use IPC::Run3 qw( run3 );
use MooseX::Getopt ();
use Moose::Util::TypeConstraints
    qw( as coerce from message subtype where via );
use MooseX::Types::Common::String qw( LowerCaseSimpleStr NonEmptySimpleStr );
use MooseX::Types::Path::Tiny qw( Dir Paths );
use Try::Tiny qw( catch try );

with 'MooseX::Getopt::Dashes';

MooseX::Getopt::OptionTypeMap->add_option_type_to_map( Dir, '=s' );

has dir => (
    is => 'ro',
    isa => Dir,
    coerce => 1,
    required => 1,
    documentation => 'Directory to search for videos',
);

subtype 'FileExtension',
    as LowerCaseSimpleStr,
    where { $_ =~ m/^[a-z0-9]{1,50}$/ },
    message { 'file extensions must contain only lowercase letters and numbers.' };

coerce 'FileExtension',
    from NonEmptySimpleStr,
    via { $_ =~ s/^\s|\s+$//g; lc $_ };     # left and right trim

subtype 'FileExtensionList',
    as 'ArrayRef[ FileExtension ]';

coerce 'FileExtensionList',
    from NonEmptySimpleStr,
    via {
        [
            map { s/^\s+|\s+$//gr }
            split /,/, lc $_
        ]
    };

{
    const my @SOURCE_EXTENSIONS => qw( mov avi );
    has source_extensions => (
        is => 'ro',
        isa => 'FileExtensionList',
        coerce => 1,
        default => sub { return \@SOURCE_EXTENSIONS; },
        documentation => 'Extensions used by video files to edit. Defaults to: ' . (join ', ', @SOURCE_EXTENSIONS),
    );
}

{
    const my $TARGET_EXTENSION => 'mp4';
    has target_extension => (
        is => 'ro',
        isa => 'FileExtension',
        coerce => 1,
        default => sub { return 'mp4' },
        documentation => 'Extension for processed videos. Defaults to: ' . $TARGET_EXTENSION,
    );
}

has _source_extension_regex => (
    is => 'ro',
    isa => 'RegexpRef',
    lazy => 1,
    builder => '_build_source_extension_regex',
);

has _paths_to_process => (
    is => 'ro',
    isa => Paths,
    lazy => 1,
    builder => '_build_paths_to_process',
);

const my @HANDBRAKE_COMMAND => (
    '/usr/local/bin/HandBrakeCLI',
    '--format' => 'av_mp4',          # use mp4 container
    '-O',                            # optimize mp4 files for HTTP streaming
    '--encoder' => 'x264',           # create an H.264 video
    '--encopts' => 'ref=5:analyse=all:rc-lookahead=60:vbv-maxrate=17500:trellis=2:subme=10:bframes=5:level=3.1:direct=auto:vbv-bufsize=17500:b-adapt=2:me=umh:merange=24',
    '--quality' => '16',
    '--two-pass',
    '--rate' => '30',
    '--pfr',
    '--aencoder' => 'ca_aac',        # create an AAC audio
    '--crop' => '0:0:0:0',           # don't crop
    '--auto-anamorphic',
);

sub _build_source_extension_regex {
    my $self = shift;

    my $regex_text
        = '\.(?i)(?:' . (join '|', @{ $self->source_extensions } ) . ')$';

    return qr/$regex_text/;
}

sub _build_paths_to_process {
    my $self = shift;

    return [
        grep { $_->is_file }
        $self->dir->children( $self->_source_extension_regex )
    ];
}

sub process_dir {
    my $self = shift;

    if (scalar @{ $self->_paths_to_process } == 0) {
        print 'No files found in dir with the source extension(s).';
        exit;
    }

    # Process the files
    my $i;
    my $num_paths = scalar @{ $self->_paths_to_process };
    foreach my $in_path (@{ $self->_paths_to_process }) {
        $i++;
        try {
            print "[$i/$num_paths] Processing $in_path\n";
            my $out_path = $self->_output_path_for( $in_path );
            $self->_process_with_handbrake( $in_path, $out_path );
            $self->_replicate_path_dates( $in_path, $out_path );
        }
        catch {
            warn "An error occurred while processing $in_path. No cleanup efforts were made.\n$_\n";
        };
    }
}

sub _output_path_for {
    my ( $self, $in_path ) = @_;

    return $in_path->parent->child(
        $in_path->basename( $self->_source_extension_regex )
        . q{.}
        . $self->target_extension
    );
}

sub _process_with_handbrake {
    my ( $self, $in_path, $out_path ) = @_;

    my @cmd = (
        @HANDBRAKE_COMMAND,
        '-i' => $in_path->stringify,
        '-o' => $out_path->stringify
    );

    run3 \@cmd, \undef, \my $out, \my $err;

    if ( $? >> 8) {
        my $message;
        $message
            .= '> HandBrakeCLI STDERR ' . ('>' x 58) . "\n"
            . $err . ('<' x 80) . "\n"
            if $err ne '';
        $message
            .= '> HandBrakeCLI STDOUT ' . ('>' x 58) . "\n"
            . $out . ('<' x 80) . "\n"
            if $out ne '';
        die $message;
    }
}

sub _replicate_path_dates {
    my ( $self, $source, $target ) = @_;

    my $source_mtime = @{ $source->stat }[9];
    utime $source_mtime, $source_mtime, $target->stringify;
}

__PACKAGE__->meta->make_immutable;

1;

package main;

VideoProcessor->new_with_options->process_dir;

exit;
