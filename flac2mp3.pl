#!/usr/bin/perl -w
#
# flac2mp3.pl
#
# Version 0.2.8
#
# Converts a directory full of flac files into a corresponding
# directory of mp3 files
#
# Robin Bowes <robin@robinbowes.com>
#
# Release History:
#  - See changelog.txt

use strict;
use FindBin;
use lib "$FindBin::Bin/lib";
use Audio::FLAC::Header;
use Data::Dumper;
use File::Basename;
use File::Find::Rule;
use File::Path;
use File::Spec;
use File::stat;
use Getopt::Long;
use MP3::Tag;

# ------- User-config options start here --------
# Assume flac and lame programs are in the path.
# If not, put full path to programs here.
our $flaccmd = "flac";
our $lamecmd = "lame";

# Modify lame options if required
our @lameargs = qw (
    --preset standard
    --quiet
);

# -------- User-config options end here ---------

our @flacargs = qw (
    --decode
    --stdout
    --silent
);

# FLAC/MP3 tag/frame mapping
# Flac:     ALBUM  ARTIST  TITLE  DATE  GENRE  TRACKNUMBER  COMMENT
# ID3v2:    ALBUM  ARTIST  TITLE  YEAR  GENRE  TRACK        COMMENT
# Frame:    TALB   TPE1    TIT2   TYER  TCON   TRCK         COMM

# hash mapping FLAC tag names to MP3 frames
our %MP3frames = (
    'ALBUM'                   => 'TALB',
    'ARTIST'                  => 'TPE1',
    'COMMENT'                 => 'COMM',
    'COMPOSER'                => 'TCOM',
    'CONDUCTOR'               => 'TPE3',
    'DATE'                    => 'TYER',
    'GENRE'                   => 'TCON',
    'ISRC'                    => 'TSRC',
    'LYRICIST'                => 'TEXT',
    'PUBLISHER'               => 'TPUB',
    'TITLE'                   => 'TIT2',
    'TRACKNUMBER'             => 'TRCK',
    'MUSICBRAINZ_ALBUMID'     => 'TXXX',
    'MUSICBRAINZ_ALBUMSTATUS' => 'TXXX',
    'MUSICBRAINZ_ALBUMTYPE'   => 'TXXX',
    'MUSICBRAINZ_ARTISTID'    => 'TXXX',
    'MUSICBRAINZ_SORTNAME'    => 'TXXX',
    'MUSICBRAINZ_TRACKID'     => 'UFID',
    'MUSICBRAINZ_TRMID'       => 'TXXX',

    #    'REPLAYGAIN_TRACK_PEAK'   => 'TXXX',
    #    'REPLAYGAIN_TRACK_GAIN'   => 'TXXX',
    #    'REPLAYGAIN_ALBUM_PEAK'   => 'TXXX',
    #    'REPLAYGAIN_ALBUM_GAIN'   => 'TXXX',
);

our %MP3frametexts = (
    'COMMENT'                   => 'Short Text',
    'MUSICBRAINZ_ALBUMARTISTID' => 'MusicBrainz Album Artist Id',
    'MUSICBRAINZ_ALBUMID'       => 'MusicBrainz Album Id',
    'MUSICBRAINZ_ALBUMSTATUS'   => 'MusicBrainz Album Status',
    'MUSICBRAINZ_ALBUMTYPE'     => 'MusicBrainz Album Type',
    'MUSICBRAINZ_ARTISTID'      => 'MusicBrainz Artist Id',
    'MUSICBRAINZ_SORTNAME'      => 'MusicBrainz Sortname',
    'MUSICBRAINZ_TRACKID'       => 'MusicBrainz Trackid',
    'MUSICBRAINZ_TRMID'         => 'MusicBrainz TRM Id',
    'REPLAYGAIN_TRACK_PEAK'     => 'REPLAYGAIN_TRACK_PEAK',
    'REPLAYGAIN_TRACK_GAIN'     => 'REPLAYGAIN_TRACK_GAIN',
    'REPLAYGAIN_ALBUM_PEAK'     => 'REPLAYGAIN_ALBUM_PEAK',
    'REPLAYGAIN_ALBUM_GAIN'     => 'REPLAYGAIN_ALBUM_GAIN',
);

# Hash telling us which key to use if a complex frame hash is encountered
# For example, the COMM frame is complex and returns a hash with the
# following keys (with example values):
#   'Language'      => 'ENG'
#   'Description'   => 'Short Text'
#   'Text'      => 'This is the actual comment field'
#
# In this case, we want to use the "Description" to check if this is the
# correct frame.
# We always grab the "Text" for the frame data.
our %Complex_Frame_Keys
    = ( 'COMM' => 'Description', 'TXXX' => 'Description', 'UFID' => '_Data' );

our %Options;

# Catch interupts (SIGINT)
$SIG{INT} = \&INT_Handler;

GetOptions(
    \%Options, "quiet!", "tagdiff", "debug!", "tagsonly!", "force!",
    "usage",   "help",   "version"
);

# info flag is the inverse of --quiet
$Options{info} = !$Options{quiet};

package main;

# Turn off output buffering (makes debugging easier)
$| = 1;

# Do I need to set the default value of any options?
# Or does GetOptions handle it?
# If I do, what's the "best" way to do it?

my ( $srcdirroot, $destdirroot ) = @ARGV;

showversion() if ( $Options{version} );
showhelp()    if ( $Options{help} );
showusage()
    if ( !defined $srcdirroot
    || !defined $destdirroot
    || $Options{usage} );

# Convert directories to absolute paths
$srcdirroot  = File::Spec->rel2abs($srcdirroot);
$destdirroot = File::Spec->rel2abs($destdirroot);

die "Source directory not found: $srcdirroot\n"
    unless -d $srcdirroot;

# count all flac files in srcdir
# Display a progress report after each file, e.g. Processed 367/4394 files
# Possibly do some timing and add a Estimated Time Remaining
# Will need to only count files that are going to be processed.
# Hmmm could get complicated.

# Change directory into srcdirroot
chdir $srcdirroot;

$::Options{info} && msg("Processing directory: $srcdirroot\n");

# Now look for files in the current directory
# (following symlinks)
my @flac_files
    = File::Find::Rule->file()->extras( { follow => 1 } )->name('*.flac')
    ->in('.');

$::Options{debug} && print Dumper(@flac_files) . "\n";

if ( $::Options{info} ) {
    my $file_count = @flac_files;    # array in scalr context returns no. items
    my $files_word = 'file';
    if ( $file_count > 1 ) {
        $files_word .= 's';
    }
    msg("$file_count flac $files_word found. Sorting...");
}

@flac_files = sort @flac_files;

$::Options{info} && msg("done.\n");

# Get directories from destdirroot and put in an array
my ( $destroot_volume, $destroot_directories, $destroot_file )
    = File::Spec->splitpath( $destdirroot, 1 );
my @destroot_dirs = File::Spec->splitdir($destroot_directories);

foreach my $srcfilename (@flac_files) {

    # Get directories in src file and put in an array
    my ( $src_volume, $src_directories, $src_file )
        = File::Spec->splitpath($srcfilename);
    my @src_dirs = File::Spec->splitdir($src_directories);

    # Join together dest_root and src_dirs
    my @dest_dirs;
    push @dest_dirs, @destroot_dirs;
    push @dest_dirs, @src_dirs;

    # Join all the dest_dirs back together again
    my $dest_directory = File::Spec->catdir(@dest_dirs);

    # Get the basename of the src file
    my ( $fbase, $fdir, $fext ) = fileparse( $src_file, qr{\.flac} );

    # Now join it all together to get the complete path of the dest_file
    my $dest_filename = File::Spec->catpath( $destroot_volume, $dest_directory,
        $fbase . '.mp3' );
    my $dest_dir
        = File::Spec->catpath( $destroot_volume, $dest_directory, '' );

    # Create the destination directory if it doesn't already exist
    mkpath($dest_dir)
        or die "Can't create directory $dest_dir\n"
        unless -d $dest_dir;

    convert_file( $srcfilename, $dest_filename );
}

1;

sub showusage {
    print <<"EOT";
Usage: $0 [--quiet] [--debug] [--tagsonly] [--force] <flacdir> <mp3dir>
    --quiet         Disable informational output to stdout
    --debug         Enable debugging output. For developers only!
    --tagsonly      Don't do any transcoding - just update tags
    --force         Force transcoding and tag update even if not required
    --tagdiff	    Print source/dest tag values if different
EOT
    exit 0;
}

sub msg {
    my $msg = shift;
    print "$msg";
}

sub convert_file {
    my ( $srcfilename, $destfilename ) = @_;

    # To do:
    #   Compare tags even if src and dest file have same timestamp
    #   Use command-line switches to override default behaviour

    # get srcfile timestamp
    my $srcstat = stat($srcfilename);
    my $deststat;

    $::Options{debug} && msg("srcfile: '$srcfilename'\n");
    $::Options{debug} && msg("destfile: '$destfilename'\n");

    # create object to access flac tags
    my $srcfile = Audio::FLAC::Header->new($srcfilename);

    # Get tags from flac file
    my $srcframes = $srcfile->tags();

    $::Options{debug} && print "Tags from source file:\n" . Dumper $srcframes;

    # hash to hold tags that will be updated
    my %changedframes;

    # weed out tags not valid in destfile
    foreach my $frame ( keys %$srcframes ) {
        if ( $MP3frames{$frame} ) {
            $changedframes{$frame} = $srcframes->{$frame};
        }
    }

    # Fix up TRACKNUMBER
    my $srcTrackNum = $changedframes{'TRACKNUMBER'} * 1;
    if ( $srcTrackNum < 10 ) {
        $changedframes{'TRACKNUMBER'} = sprintf( "%02u", $srcTrackNum );
    }

    if ( $::Options{debug} ) {
        print "Tags we know how to deal with from source file:\n";
        print Dumper \%changedframes;
    }

    # Initialise file processing flags
    my %pflags = (
        exists    => 0,
        tags      => 0,
        timestamp => 1
    );

    # if destfile already exists
    if ( -e $destfilename ) {

        $pflags{exists} = 1;

        $::Options{debug} && msg("destfile exists: '$destfilename'\n");

        # get destfile timestamp
        $deststat = stat($destfilename);

        my $srcmodtime  = scalar $srcstat->mtime;
        my $destmodtime = scalar $deststat->mtime;

        if ( $::Options{debug} ) {
            print("srcfile mtime:  $srcmodtime\n");
            print("destfile mtime: $destmodtime\n");
        }

       # General approach:
       #   Don't process the file if srcfile timestamp is earlier than destfile
       #   or tags are different
       #
       # First check timestamps and set flag
        if ( $srcmodtime <= $destmodtime ) {
            $pflags{timestamp} = 0;
        }

        # If the source file os not newer than dest file
        if ( !$pflags{timestamp} ) {

            $Options{debug} && msg("Comparing tags\n");

            # Compare tags; build hash of changed tags;
            # if hash empty, process the file

            my $mp3 = MP3::Tag->new($destfilename);

            my @tags = $mp3->get_tags;

            $Options{debug} && print Dumper @tags;

            # If an ID3v2 tag is found
            my $ID3v2 = $mp3->{"ID3v2"};
            if ( defined $ID3v2 ) {

                $Options{debug} && msg("ID3v2 tag found\n");

                # loop over all valid destfile frames
                foreach my $frame ( keys %MP3frames ) {

                    $::Options{debug} && msg("frame is '$frame'\n");

            # To do: Check the frame is valid
            # Specifically, make sure the GENRE is one of the standard ID3 tags
                    my $method = $MP3frames{$frame};

                    $::Options{debug} && msg("method is '$method'\n");

                    # Check for tag in destfile
                    my ( $tagname, @info ) = $ID3v2->get_frames($method);

                    #$destframe = '' if ( !defined $destframe );

                    $::Options{debug}
                        && print "values from id3v2 tags:\n"
                        . Dumper \$tagname, \@info;

                    my $dest_text = '';

     #XXX FIXME TODO:
     #Map Vorbis comments onto TXXX frames
     #
     #There can be several TXXX frames.
     #All are returned by the call to get_frames
     #The data structure returned is an array of hashes, something like:
     #$VAR1 = \'User defined text information frame';
     #$VAR2 = [
     #          {
     #            'Description' => 'MusicBrainz Album Id',
     #            'Text' => '68d1f0b1-3805-4c63-A7df-Ee84350946e2',
     #            'encoding' => 0
     #          },
     #          {
     #            'Description' => 'MusicBrainz Album Type',
     #            'Text' => 'Album',
     #            'encoding' => 0
     #          },
     #          {
     #            'Description' => 'MusicBrainz Sortname',
     #            'Text' => 'All About Eve',
     #            'encoding' => 0
     #          },
     #          {
     #            'Description' => 'MusicBrainz Artist Id',
     #            'Text' => '6080fe70-84e9-43ae-98b7-94b4c4d6b5c3',
     #            'encoding' => 0
     #          },
     #          {
     #            'Description' => 'MusicBrainz Album Status',
     #            'Text' => 'Official',
     #            'encoding' => 0
     #          },
     #          {
     #            'Description' => 'MusicBrainz TRM Id',
     #            'Text' => 'D5c81e99-F7ac-40cd-B171-Ec2b159a6cce',
     #            'encoding' => 0
     #          }
     #        ];
     #
     #I need to map these values to a flac file with Vorbis comments like this:
     #
     #Musicbrainz_trmid: D5c81e99-F7ac-40cd-B171-Ec2b159a6cce
     #
     #i.e.
     #
     # Comment "Musicbrainz_trmid" maps to
     # ID3v2 tag "TXXX" with Description "MusicBrainz TRM Id"

                    # check for complex frame (e.g. Comments)
                TAGLOOP:
                    foreach my $tag_info (@info) {
                        if ( ref $tag_info ) {
                            my $cfname = $MP3frametexts{$frame};
                            my $cfkey  = $Complex_Frame_Keys{$method};

               #			    print "frame: $frame\ncfkey: $cfkey\ncfname: $cfname\n";
                            if ( $$tag_info{$cfkey} eq $cfname ) {
                                $dest_text = $$tag_info{'Text'};
                                last TAGLOOP;
                            }
                        }
                        else {
                            $dest_text = $tag_info;
                        }
                    }

                    $::Options{debug}
                        && print "\$dest_text xxx2: " . Dumper $dest_text;

                    # Fix up TRACKNUMBER
                    if ( $frame eq "TRACKNUMBER" ) {
                        if ( $dest_text < 10 ) {
                            $dest_text = sprintf( "%02u", $dest_text );
                        }
                    }

                    # get tag from srcfile
                    my $srcframe = utf8toLatin1( $changedframes{$frame} );
                    $srcframe = '' if ( !defined $srcframe );

                    # Strip trailing spaces from src frame value
                    $srcframe =~ s/ *$//;

                    # If set the flag if any frame is different
                    if ( $dest_text ne $srcframe ) {
                        if ( $::Options{tagdiff} ) {
                            msg("frame: '$frame'\n");
                            msg("srcframe value: '$srcframe'\n");
                            msg("destframe value: '$dest_text'\n");
                        }
                        $pflags{tags} = 1;
                    }
                }
            }
        }
    }

    if ( $::Options{debug} ) {
        msg("pf_exists:    $pflags{exists}\n");
        msg("pf_tags:      $pflags{tags}\n");
        msg("pf_timestamp: $pflags{timestamp}\n");
    }

    if ( $::Options{debug} ) {
        print "Tags to be written if tags need updating\n";
        print Dumper \%changedframes;
    }

    if (   !$pflags{exists}
        || $pflags{timestamp}
        || $pflags{tags}
        || $::Options{force} )
    {
        $::Options{info} && msg("Processing \"$srcfilename\"\n");

        if ($::Options{force}
            || ( !$::Options{tagsonly}
                && ( !$pflags{exists}
                    || ( $pflags{exists} && !$pflags{tags} ) ) )
            )
        {

#            # Building command used to convert file (tagging done afterwards)
#            # Needs some work on quoting filenames containing special characters
#            my $quotedsrc       = $srcfilename;
#            my $quoteddest      = $destfilename;
#            my $convert_command =
#                "$flaccmd @flacargs \"$quotedsrc\""
#              . "| $lamecmd @lameargs - \"$quoteddest\"";
#
#            $::Options{debug} && msg("$convert_command\n");
#
            print "About to fork lame...\n";
            $| = 1;
            my $PIPE_TO_LAME;
            defined( my $lame_pid = open $PIPE_TO_LAME, "|-" )
                or die("fork() failed: $!\n");

            if ( !$lame_pid ) {
                exec( $lamecmd, @lameargs, '-', $destfilename );
                die("exec() failed: $!\n");
            }
            binmode($PIPE_TO_LAME);

            open my $SAVEOUT, ">&", STDOUT;
            open STDOUT, ">&", $PIPE_TO_LAME;
            binmode(STDOUT);
            select(STDOUT);
            $| = 1;

            # Convert the file
            #            my $exit_value = system($convert_command);
            my $exit_value = system( $flaccmd, @flacargs, $srcfilename );
            open STDOUT, ">&", $SAVEOUT;

            $::Options{debug}
                && msg("Exit value from flac command: $exit_value\n");

       #              && msg("Exit value from convert command: $exit_value\n");

            if ($exit_value) {

       #                msg("$convertcmd failed with exit code $exit_value\n");
                msg("$flaccmd failed with exit code $exit_value\n");

                # delete the destfile if it exists
                unlink $destfilename;

                # should check exit status of this command

                exit($exit_value);
            }

            # the destfile now exists!
            $pflags{exists} = 1;
        }

        # Write the tags to the converted file
        if (   $pflags{exists} && ( $pflags{tags} || $pflags{timestamp} )
            || $::Options{force} )
        {

            my $mp3 = MP3::Tag->new($destfilename);

            # Remove any existing tags
            $mp3->{ID3v2}->remove_tag if exists $mp3->{ID3v2};

            # Create a new tag
            $mp3->new_tag("ID3v2");

            foreach my $frame ( keys %changedframes ) {

                $::Options{debug} && msg("changedframe is '$frame'\n");

            # To do: Check the frame is valid
            # Specifically, make sure the GENRE is one of the standard ID3 tags
                my $method = $MP3frames{$frame};

                $::Options{debug} && msg("method is $method\n");

                # Convert utf8 string to Latin1 charset
                my $framestring = utf8toLatin1( $changedframes{$frame} );

                $::Options{debug} && msg("Setting $frame = '$framestring'\n");

                # COMM, TXX, and UFID are Complex frames that must be
                # treated differently.
                if ( $method eq "COMM" ) {
                    $mp3->{"ID3v2"}->add_frame( $method, 'ENG', 'Short Text',
                        $framestring );
                }
                elsif ( $method eq "TXXX" ) {
                    my $frametext = $MP3frametexts{$frame};
                    $frametext = $frame if ( !( defined($frametext) ) );
                    $mp3->{"ID3v2"}
                        ->add_frame( $method, 0, $frametext, $framestring );
                }
                elsif ( $method eq 'UFID' ) {
                    my $frametext = $MP3frametexts{$frame};
                    $mp3->{'ID3v2'}
                        ->add_frame( $method, $framestring, $frametext );
                }
                else {
                    $mp3->{"ID3v2"}->add_frame( $method, $framestring );
                }
            }

            $mp3->{ID3v2}->write_tag;

            $mp3->close();

    # should optionally reset the destfile timestamp to the same as the srcfile
    # utime $srcstat->mtime, $srcstat->mtime, $destfilename;
        }
    }
}

sub INT_Handler {
    my $signame = shift;
    die "Exited with SIG$signame\n";
}

sub utf8toLatin1 {
    my $data = shift;

    # Don't run the substitution on an empty string
    if ($data) {
        $data
            =~ s/([\xC0-\xDF])([\x80-\xBF])/chr(ord($1)<<6&0xC0|ord($2)&0x3F)/eg;
        $data =~ s/[\xE2][\x80][\x99]/'/g;
    }

    return $data;
}

# vim:set softtabstop=4:
# vim:set shiftwidth=4:

__END__