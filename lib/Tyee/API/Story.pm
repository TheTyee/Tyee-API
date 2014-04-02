package Tyee::API::Story;

use warnings;
use strict;
use Data::Dumper;
use Readonly;
use File::Spec::Functions qw(catdir);
use HTML::TreeBuilder;
use POSIX qw(ceil);
use utf8;

use Tyee::Config;

BEGIN {

    # Be sure to set your BRICOLAGE_ROOT if you don't want the default
    # $BRICOLAGE_ROOT defaults to /usr/local/bricolage
    $ENV{BRICOLAGE_ROOT} ||= "/usr/local/bricolage";

    # use $BRICOLAGE_ROOT/lib if exists
    my $lib = catdir( $ENV{BRICOLAGE_ROOT}, "lib" );
    if ( -e $lib ) {
        $ENV{PERL5LIB}
            = defined $ENV{PERL5LIB} ? "$ENV{PERL5LIB}:$lib" : $lib;
        unshift @INC, $lib;
    }

    # make sure Bric is found. Use Bric::Config to prevent warnings.
    eval { require Bric::Config };
    die <<"END" if $@;
######################################################################

   Cannot load Bricolage libraries. Please set the environment
   variable BRICOLAGE_ROOT to the location of your Bricolage
   installation or set the environment variable PERL5LIB to the
   directory where Bricolage's libraries are installed.

   The specific error encountered was as follows:

   $@

######################################################################
END
}

use Bric;
use Bric::Biz::Asset::Business::Story;
use Bric::Biz::Asset::Business::Media;
use Bric::Biz::Asset::Business::Media::Image;
use Bric::Biz::Asset::Business::Media::Audio;
use Bric::Biz::Person;
use Bric::Biz::Person::User;
use Bric::Biz::Org::Source;


#---------------------------------------------------------------------------
# Let scripts access Bricolage Story->list
#---------------------------------------------------------------------------
sub list {
    my $self    = shift;
    my $params  = shift;
    my @stories = Bric::Biz::Asset::Business::Story->list(
        {   element_key_name => Bric::Biz::Asset::Business::Story::ANY(
                qw(story gallery_output blog_entry)
            ),
        OrderDirection => 'DESC',
        @{ $params },
        }
    );
    return \@stories;
}

#---------------------------------------------------------------------------
#  Things that shouldn't change
#---------------------------------------------------------------------------
Readonly my $DOMAIN         => $config->{'domain'};
Readonly my $CDN            => $config->{'cdn'};
Readonly my @FIELD_ELEMENTS => qw( paragraph header );

# If you add something to @CONTAINER_ELEMENTS you have to add it to the %dispatch table
Readonly my @CONTAINER_ELEMENTS => qw( list page_image
    blog_blockquote related_podcast_audio embedded_media related_documents
    related_media author_info book_profile related_stories primary_video fact_box );
Readonly my @INLINE_ELEMENTS =>
    qw( paragraph header list page_image blog_blockquote );
Readonly my @REPEATING_ELEMENTS =>
    qw( related_media fact_box book_profile related_stories related_documents );

#===  FUNCTION  ================================================================
#         NAME:  new
#      PURPOSE:  To create a new API-friendly structure from a Bricolage story
#   PARAMETERS:  Bricolage story object
#      RETURNS:  The object, or an error message
#===============================================================================
sub new {
    my $self  = shift;
    my $story = shift;
    return _build_story( $story )
}



#---------------------------------------------------------------------------
#  BELOW HERE BE DEMONS. SERIOUSLY, IT'S SCARY.
#---------------------------------------------------------------------------
#---------------------------------------------------------------------------
#  Dispatch table for container elements (objects).
#  Each object is dispatched to a subroutine to extract the necessary
#  information to build the data structure that is passed to Elastic Search
#---------------------------------------------------------------------------
my %dispatch = (
    blog_blockquote       => \&_build_blog_blockquote,
    blog_excerpt          => \&_build_blog_excerpt,
    fact_box              => \&_build_fact_box,
    embedded_media        => \&_build_embedded_media,
    list                  => \&_build_list,
    page_image            => \&_build_page_image,
    related_podcast_audio => \&_build_related_podcast_audio,
    related_documents     => \&_build_related_documents,
    related_media         => \&_build_related_media,
    author_info           => \&_build_author_info,
    book_profile          => \&_build_book_profile,
    related_stories       => \&_build_related_stories,
    primary_video         => \&_build_primary_video,
);

# These are package globals that get undefed for each story; not pretty, but works.
# (Required because these elements can repeat n times in a story.)
my @related_media_assets;
my @related_document_assets;
my @fact_boxes;
my @book_profiles;

#===  FUNCTION  ================================================================
#         NAME:  _build_story
#      PURPOSE:  Build a data structure from a Bricolage story object
#   PARAMETERS:  Expects a Bricolage story object
#      RETURNS:  A hash ref containing the data struct passed to ES
#===============================================================================
sub _build_story {
    my $story  = shift;
    my $deck   = _strip_tags( $story->get_value( 'deck' ) );
    my $teaser = $deck || _build_excerpt( $story );
    my $title  = $story->get_title;

  #---------------------------------------------------------------------------
  #  Build the basic story properties
  #---------------------------------------------------------------------------
    my %story_object = (

        # These properties should always be present in a story
        id           => $story->get_id,
        uuid         => $story->get_uuid,
        story_type   => $story->get_element_key_name,
        storyDate    => $story->get_cover_date( '%Y-%m-%dT%H:%M:%SZ' ),
        title        => $title,
        slug         => $story->get_slug,
        uri          => $DOMAIN . $story->get_uri,
        path         => $story->get_uri,
        section      => $story->get_primary_category->get_name,
        series       => 'Currently not set',
        organization => Bric::Biz::Org::Source->lookup(
            { id => $story->get_source__id }
            )->get_source_name,
        teaser   => $teaser,
        topics   => _build_category_names( $story ),
        byline   => _build_contributor_names( $story ),
        contribs => _build_contributor_ids( $story ),
        keywords => _build_keywords( $story ),
    );

  #---------------------------------------------------------------------------
  #  Clear out those globals (only hear to accommodate repeating elements)
  #---------------------------------------------------------------------------
    undef @related_media_assets;
    undef @related_document_assets;
    undef @fact_boxes;
    undef @book_profiles;

  #---------------------------------------------------------------------------
  #  Get the pages and in-line content. Put it in the %story_object
  #---------------------------------------------------------------------------

    my @pages = _get_pages( $story );
    my @page_containers;
    my @container_elements
        = _get_container_elements( $story );    # Story's container elements
    for my $page ( @pages ) {
        my @field_elements
            = _get_field_elements( $page );     # Need field elements of $page
        push @page_containers,
            _get_container_elements( $page );    # Page containers
            # Elements displayed _in_ HTML of a page
        my @inline_elements
            = _get_inline_elements( @page_containers, @field_elements );

        # Build the string for the actual story text
        if ( $page && @inline_elements ) {
            $story_object{'textWithHtml'}
                .= _get_page_content_as_html( @inline_elements );
        }
    }

  #---------------------------------------------------------------------------
  #  Get the top-level elements and put them in the %story_object
  #---------------------------------------------------------------------------
  # Elements that become properties in the JSON object
  # Remove elements that we've already dealt with
    my @top_elements
        = _strip_inline_elements( @container_elements, @page_containers );
    for ( @top_elements ) {    # Dispatch to the appropriate subroutine
        my $kn = $_->get_key_name;
        my $regex_str = join "|", @REPEATING_ELEMENTS;
        if ( $kn =~ /$regex_str/ ) {
            $story_object{$kn} = $dispatch{$kn}( $_ );
        }
        else {
            $story_object{$kn} = [ $dispatch{$kn}( $_ ) ];
        }
    }

    #print Dumper( \%story_object );    # TODO Debug code, remove
    return \%story_object;
}    # ----------  end of subroutine _build_story  ----------

#===  FUNCTION  ================================================================
#         NAME:  _build_category_names
#   PARAMETERS:  Expects a Bricolage story object
#      RETURNS:  Array ref containing category names as strings
#===============================================================================
sub _build_category_names {
    my $story = shift;
    my @category_names;
    for ( $story->get_categories ) {
        push @category_names, $_->get_name;
    }
    return \@category_names;
}    # ----------  end of subroutine _build_category_names  ----------

#===  FUNCTION  ================================================================
#         NAME:  _build_keywords
#   PARAMETERS:  Expects a Bricolage story object
#      RETURNS:  Array ref of keyword names as strings
#===============================================================================

sub _build_keywords {
    my $story = shift;
    my @keyword_names;
    for ( $story->get_keywords ) {
        push @keyword_names, $_->get_name;
    }
    return \@keyword_names;
}    # ----------  end of subroutine _build_keywords  ----------

#===  FUNCTION  ================================================================
#         NAME:  _build_contributor_names
#   PARAMETERS:  A Bricolage story object
#      RETURNS:  A properly formatted string of contributor names (or name)
#===============================================================================

sub _build_contributor_names {
    my $story = shift;
    my @contribs;
    my $string;
    for ( $story->get_contributors ) {
        push @contribs, $_->get_name;
    }
    if ( @contribs == 2 ) {    # We have two
        $string = join( ' and ', @contribs );
    }
    elsif ( @contribs > 2 ) {    # We have more than two
        my $last = pop @contribs;
        $string = join( ', ', @contribs );
        $string .= ' and ' . $last;
    }
    else {                       # We have only one
        $string = $contribs[0];
    }
    return $string;
}    # ----------  end of subroutine _build_contributor_names  ----------

#===  FUNCTION  ================================================================
#         NAME:  _build_contributor_ids
#      PURPOSE:  For the eventual use of including contributor data in ES
#   PARAMETERS:  A Bricolage story object
#      RETURNS:  Array ref of contributor IDs in Bricolage
#===============================================================================

sub _build_contributor_ids {
    my ( $story ) = shift;
    my @contrib_ids;
    for ( $story->get_contributors ) {
        push @contrib_ids, $_->get_id;
    }
    return \@contrib_ids;
}    # ----------  end of subroutine _build_contributor_ids  ----------

#===  FUNCTION  ================================================================
#         NAME:  _get_pages
#      PURPOSE:  Get the various objects that constitute a "page"
#   PARAMETERS:  A story object
#      RETURNS:  An array of pages (possibly just one)
#===============================================================================
sub _get_pages {
    my $story = shift;
    my @pages;
    my @elements = $story->get_elements;
    for ( @elements ) {
        my $kn = $_->get_key_name;
        if ( $kn =~ /page|book_story_page|blog_content/ ) {
            push @pages, $_;
        }
    }
    return @pages;
}    # ----------  end of subroutine get_story_content  ----------

#===  FUNCTION  ================================================================
#         NAME:  _get_field_elements
#      PURPOSE:  Build array of a page object's field-level elements
#   PARAMETERS:  A page object
#      RETURNS:  An array of field elements
#===============================================================================
sub _get_field_elements {
    my $page           = shift;
    my @field_elements = $page->get_elements( @FIELD_ELEMENTS );
    return @field_elements;
}    # ----------  end of subroutine _get_field_elements  ----------

#===  FUNCTION  ================================================================
#         NAME:  _get_container_elements
#      PURPOSE:  Build an array of a container elements in the page, or story
#   PARAMETERS:  A page or story object
#      RETURNS:  An array with the container element objects
#===============================================================================
sub _get_container_elements {
    my ( $object ) = @_;
    my @container_elements;
    push @container_elements, $object->get_elements( @CONTAINER_ELEMENTS );
    return @container_elements;
}    # ----------  end of subroutine _get_container_elements  ----------

#===  FUNCTION  ================================================================
#         NAME:  get_inline_elemements
#      PURPOSE:  Build an array of elements for the textWithHTML property
#   PARAMETERS:  An array with all possible elements
#      RETURNS:  An array with the "inline" elements
#===============================================================================
sub _get_inline_elements {
    my @elements        = @_;
    my $regex_str       = join "|", @INLINE_ELEMENTS;
    my @inline_elements = grep { $_->get_key_name =~ /$regex_str/ } @elements;
    return @inline_elements;
}    # ----------  end of subroutine _get_inline_elements  ----------

#===  FUNCTION  ================================================================
#         NAME:  _strip_inline_elements
#      PURPOSE:  Remove the elements used for textWithHTML
#   PARAMETERS:  An array with all possible elements
#      RETURNS:  An array with just "top level" elements  no inline elements
#===============================================================================
sub _strip_inline_elements {
    my @elements = @_;
    my $regex_str = join "|", @INLINE_ELEMENTS;
    my @remaining_elements
        = grep { $_->get_key_name !~ /$regex_str/ } @elements;
    return @remaining_elements;
}    # ----------  end of subroutine _strip_inline_elements  ----------

#===  FUNCTION  ================================================================
#         NAME:  _get_page_content_as_html
#      PURPOSE:  Build the textWithHTML property as a string
#   PARAMETERS:  The array of inline elements
#      RETURNS:  A string of HTML that represents the story's content
#===============================================================================
sub _get_page_content_as_html {
    my @elements = @_;
    my $string;
    @elements = sort { $a->get_place <=> $b->get_place }
        @elements;    # Sort elements by their place on the page
    for ( @elements ) {
        my $kn = $_->get_key_name;
        if ( $kn eq 'paragraph' ) {
            $string .= '<p>' . $_->get_value . '</p>';
        }
        elsif ( $kn eq 'header' ) {
            $string .= '<h2>' . $_->get_value . '</h2>';
        }
        else {
            $string .= $dispatch{$kn}( $_ );
        }
    }
    return _sanitize_html( $string );
}    # ----------  end of subroutine _get_page_content_as_html  ----------

#---------------------------------------------------------------------------
#  Builder subroutines for the inline elements in stories
#---------------------------------------------------------------------------
#===  FUNCTION  ================================================================
#         NAME:  _build_list
#      PURPOSE:  To build a string from a recursive list object
#   PARAMETERS:  The container element object for the list
#      RETURNS:  A string version of the list
#===============================================================================
sub _build_list {
    my $element = shift;
    my $string;
    my $tag = $element->get_value( 'type' ) || 'ul';
    $string .= "<$tag>";
    my $in_item = 0;
    foreach my $e ( $element->get_elements( qw(item paragraph list) ) ) {
        my $kn = $e->get_key_name;
        if ( $kn eq 'item' ) {

          # Finish the last list item, if we were in one, and start a new one.
            $string .= "</li>" if $in_item;
            $string .= "<li>" . '<p>' . $e->get_value . "</p>";
            $in_item = 1;
        }
        elsif ( $kn eq 'paragraph' ) {

            # Just output a paragraph, which is a subelement of an item.
            $string .= '<p>' . $e->get_value . "</p>";
        }
        else {

            # If it's a list, we're embedded!
            $string .= _build_list( $e );
        }
    }
    $string .= "</li>" if $in_item;
    $string .= "</$tag>";
    return $string;
}    # ----------  end of subroutine _build_list  ----------

#===  FUNCTION  ================================================================
#         NAME:  _build_page_image
#      PURPOSE:  Build any inline images elements into HTML tags
#   PARAMETERS:  The inline image element
#      RETURNS:  A string of the HTML tag for the image
#===============================================================================
sub _build_page_image {
    my $element = shift;
    my $string;
    my $media  = $element->get_related_media;
    my $melem  = $media->get_element;
    my $uri    = $media->get_uri;
    my $width  = $media->get_value( 'width' );
    my $height = $media->get_value( 'height' );
    my $caption 
        = $element->get_value( 'caption' )
        || $element->get_value( 'image_title' )
        || '';
    my $url  = $CDN . $uri;
    my $tiny = 'http://src.sencha.io/';

    # Hackish but it will work for now
    my $tiny_w   = ceil( $width / 2 );
    my $tiny_h   = ceil( $height / 2 );
    my $tiny_url = $tiny . $tiny_w . "/" . $tiny_h . "/" . $url;
    $string
        = qq{<img src="$tiny_url" width="$tiny_w" height="$tiny_h" alt="$caption" />};
    return $string;
}    # ----------  end of subroutine _build_page_image  ----------

#===  FUNCTION  ================================================================
#         NAME:  _build_fact_box
#      PURPOSE:  Build any fact_box elements and add them to the data structure
#   PARAMETERS:  The element object
#      RETURNS:  An array of hashes representing fact boxes
#===============================================================================
sub _build_fact_box {
    my $element = shift;
    my %fact_box;
    my $string;
    for my $e ( $element->get_elements( 'paragraph' ) ) {
        $string .= '<p>' . $e->get_value . '</p>';
    }
    if ( $element->get_value( 'author' ) ) {
        $string .= '<p class="author">—'
            . $element->get_value( 'author' ) . '</p>';
    }
    $fact_box{'title'}   = $element->get_value( 'title' );
    $fact_box{'content'} = $string;
    push @fact_boxes, \%fact_box;
    return \@fact_boxes;
}    # ----------  end of subroutine _build_factbox  ----------

#===  FUNCTION  ================================================================
#         NAME:  _build_related_documents
#      PURPOSE:  Build a collection of related documents
#   PARAMETERS:  A related_document object
#      RETURNS:  A hash representing a list of related_documents
#===============================================================================
sub _build_related_documents {
    my $element                  = shift;
    my %related_documents_object = ();
    my @files                    = grep { $_->get_related_media }
        $element->get_elements( 'related_file' );
    $related_documents_object{'heading'}
        = $element->get_value( 'alternate_header' )
        || 'Related Document' . ( @files > 1 ? 's' : '' );
    my @related_documents;
    for ( @files ) {
        my %related_document = ();
        my $file             = $_->get_related_media;
        $related_document{'uri'}   = $DOMAIN . $file->get_primary_uri;
        $related_document{'title'} = $_->get_value( 'alt_name' )
            || $file->get_title;
        $related_document{'description'} = $_->get_value( 'alt_desc' )
            || $file->get_description;
        push @related_documents, \%related_document;
    }
    $related_documents_object{'documents'} = \@related_documents;
    push @related_document_assets, \%related_documents_object;
    return \@related_document_assets;
}    # ----------  end of subroutine _build_documents  ----------

#===  FUNCTION  ================================================================
#         NAME:  _build_embedded_media
#      PURPOSE:  To parse out the URI from a YouTube or similar embed code
#   PARAMETERS:  A embedded_media object
#      RETURNS:  A string representing the URI to the embedded media
#===============================================================================
sub _build_embedded_media {
    my $element = shift;
    my @url
        = ( $element->get_value( 'embed_html' ) =~ /"(\bhttps?:\/\/\S+)"/m );
    return $url[0];
}    # ----------  end of subroutine _build_embeded_media  ----------

#===  FUNCTION  ================================================================
#         NAME:  _build_related_audio_element
#      PURPOSE:  This element seems to have been deleted;
#      RETURNS:  undef for now, until I can find a story with one.
#===============================================================================
sub _build_related_audio_element {
    my $element = shift;
    my $string;
    return;
}    # ----------  end of subroutine _build_related_audio  ----------

#---------------------------------------------------------------------------
#  Builder subroutines for the top level elements in stories, e.g.:
#  author_info, book_profile, related_media, related_stories,
#  related_gallery, related_podcast_audio, primary_video
#---------------------------------------------------------------------------

#===  FUNCTION  ================================================================
#         NAME:  _build_author_info
#      PURPOSE:  Build a string of HTML from the author_info element
#   PARAMETERS:  An author_info object
#      RETURNS:  A string of HTML for the author_info element
#===============================================================================
sub _build_author_info {
    my $element = shift;
    my $string;
    my @paragraphs = $element->get_elements( 'paragraph' );
    for ( @paragraphs ) {
        $string .= '<p>' . $_->get_value . '</p>';
    }
    return $string;
}    # ----------  end of subroutine _build_author_info  ----------

#===  FUNCTION  ================================================================
#         NAME:  _build_book_profile
#      PURPOSE:  Builds all the book_profile elements for a story (multiple)
#   PARAMETERS:  A book_profile object
#      RETURNS:  An array of hashes representing book profiles
#===============================================================================
sub _build_book_profile {
    my $element = shift;
    my %book_profile;
    my @fields = $element->get_elements;
    for ( @fields ) {
        my $kn = $_->get_key_name;
        $book_profile{$kn} = $_->get_value;
    }
    push @book_profiles, \%book_profile;
    return \@book_profiles;
}    # ----------  end of subroutine _build_book_profile  ----------

#===  FUNCTION  ================================================================
#         NAME:  _build_related_media
#      PURPOSE:  Build media assets. Could be multiples (for galleries)
#   PARAMETERS:  A related_media object
#      RETURNS:  A hash representing a related media asset  its thumbnails
#===============================================================================

sub _build_related_media {
    my $element = shift;
    push @related_media_assets, _build_related_media_asset( $element );
    return \@related_media_assets;
}

sub _build_related_media_asset {
    my $element = shift;
    my $image   = $element->get_related_media;
    if ( $image ) {
    my $melem   = $image->get_element;
    my %related_media_asset;
    $related_media_asset{'name'}    = $image->get_name;
    $related_media_asset{'caption'} = $element->get_value( 'caption' )
        || "";
    $related_media_asset{'uri'}    = $CDN . $image->get_uri;
    $related_media_asset{'width'}  = $melem->get_value( 'width' );
    $related_media_asset{'height'} = $melem->get_value( 'height' );
    my @related_media_thumbs;
    my @thumbs = Bric::Biz::Asset::Business::Media->list(

  # Need to limit the thumb search similar to the native find_or_create method
        {   name             => "%" . $image->get_name,
            cover_date_start => $image->get_cover_date,
            cover_date_end   => $image->get_cover_date,
            category_id      => $image->get_category->get_id,
        }
    );

    for ( @thumbs ) {
        if ( defined( $_->get_file_name )
            and $_->get_file_name =~ m/_thumb/ )
        {
            my %thumb;
            $thumb{'name'}   = $_->get_name;
            $thumb{'width'}  = $_->get_value( 'width' );
            $thumb{'height'} = $_->get_value( 'height' );
            $thumb{'uri'}    = $CDN . $_->get_uri;
            push @related_media_thumbs, \%thumb;
        }
    }
    $related_media_asset{'thumbnails'} = \@related_media_thumbs;
    return \%related_media_asset;
    }
    return undef;
}    # ----------  end of subroutine _build_related_media  ----------

#===  FUNCTION  ================================================================
#         NAME:  _build_related_stories
#      PURPOSE:  Build a list of related stories
#   PARAMETERS:  A related story object
#      RETURNS:  A reference to an array of hashes representing related stories
#===============================================================================

sub _build_related_stories {
    my $element = shift;
    my @related_stories;
    my @stories = $element->get_elements( 'related_story' );
    for ( @stories ) {
        my %related_story_asset;
        my $rel = $_->get_related_story;
        if ( defined( $rel ) ) {
            my $deck = _strip_tags( $rel->get_value( 'deck' ) );
            $related_story_asset{'uuid'}   = $rel->get_uuid;
            $related_story_asset{'title'}  = $rel->get_title;
            $related_story_asset{'uri'}    = $DOMAIN . $rel->get_uri;
            $related_story_asset{'teaser'} = $deck
                || _build_excerpt( $rel );
            push @related_stories, \%related_story_asset;
        }
    }
    return \@related_stories;
}    # ----------  end of subroutine _build_related_stories  ----------

#===  FUNCTION  ================================================================
#         NAME:  _build_related_gallery
#      PURPOSE:  This element doesn't seem to be used anymore.
#      RETURNS:  Undef for now.
#===============================================================================

sub _build_related_gallery {
    my $element = shift;
    return;
}    # ----------  end of subroutine _build_gallery_output  ----------

#===  FUNCTION  ================================================================
#         NAME:  _build_related_podcast_audio
#      PURPOSE:  Build a related_podcast_audio element
#   PARAMETERS:  A related_podcast_audio object
#      RETURNS:  A hash representing the related_podcast_audio
#===============================================================================
sub _build_related_podcast_audio {
    my $element = shift;
    my %related_podcast_audio;
    my $podcast = $element->get_related_media or return;
    $related_podcast_audio{'boxTitle'} = $element->get_value( 'box_title' );
    $related_podcast_audio{'title'} = $element->get_value( 'alternate_title' )
        || $podcast->get_title;
    $related_podcast_audio{'summary'}
        = $element->get_value( 'alternate_summary' ) || '';
    $related_podcast_audio{'uri'} = $DOMAIN . $podcast->get_uri;
    return \%related_podcast_audio;
}    # ----------  end of subroutine _build_related_podcast_audio  ----------

#===  FUNCTION  ================================================================
#         NAME:  _build_primary_video
#      PURPOSE:  Build a primary_video element. Pull out URI from embed code.
#   PARAMETERS:  A primary_video object
#      RETURNS:  A hash representing a primary_video object
#===============================================================================
sub _build_primary_video {
    my $element = shift;
    my %primary_video;
    my @urls
        = ( $element->get_value( 'embed_code' ) =~ /"(\bhttps?:\/\/\S+)"/m );
    $primary_video{'caption'} = $element->get_value( 'caption' );
    $primary_video{'uri'}     = $urls[0];
    return \%primary_video;
}    # ----------  end of subroutine _build_primary_video  ----------

#---------------------------------------------------------------------------
#  Builder subroutines for elements in blog entries
#---------------------------------------------------------------------------
#===  FUNCTION  ================================================================
#         NAME:  _build_blog_blockquote
#      PURPOSE:  Build a blockquote when used in a blog entry
#   PARAMETERS:  A blog_blockquote object
#      RETURNS:  A string representing the block_quote for textWithHTML
#===============================================================================
sub _build_blog_blockquote {
    my $element = shift;
    my $string;
    my $citation = $element->get_field( 'cite' );
    $citation ? $citation = $citation->get_value : $citation = '';
    my @paragraphs = $element->get_elements( 'paragraph' );
    $string .= '<blockquote cite="' . $citation . '">';
    for ( @paragraphs ) {
        $string .= '<p>' . $_->get_value . '</p>';
    }
    $string .= '</blockquote>';
    return $string;
}    # ----------  end of subroutine blog_blockquote  ----------

#===  FUNCTION  ================================================================
#         NAME:  _build_excerpt
#      PURPOSE:  Build an excerpt from various data fields
#   PARAMETERS:  A story object
#      RETURNS:  A string of the excerpt
#===============================================================================

sub _build_excerpt {
    my ( $story ) = @_;
    my $string;
    $string = do {
        defined $story->get_container( 'blog_excerpt' )
            ? _build_blog_excerpt( $story->get_container( 'blog_excerpt' ) )
            : get_first_paragraph( $story );
    };
    return $string;
}    # ----------  end of subroutine _build_excerpt  ----------

#===  FUNCTION  ================================================================
#         NAME:  _build_blog_excerpt
#      PURPOSE:  Handles the special case for blog_post objects
#   PARAMETERS:  The blog_excerpt container element
#      RETURNS:  A string of the excerpt
#===============================================================================

sub _build_blog_excerpt {
    my $element = shift;
    my $string;
    my @elements = $element->get_elements;
    for ( @elements ) {
        my $kn = $_->get_key_name;
        if ( $kn eq 'paragraph' ) {
            $string .= $_->get_value;
        }
        elsif ( $kn eq 'blog_blockquote' ) {
            $string .= _build_blog_blockquote( $_ );
        }
    }
    return _strip_tags( $string );
}    # ----------  end of subroutine _build_blog_excerpt  ----------

#===  FUNCTION  ================================================================
#         NAME:  get_first_paragraph
#      PURPOSE:  If there's no excerpt, we use the first paragraph
#   PARAMETERS:  The Bricolage story object
#      RETURNS:  A string
#===============================================================================

sub get_first_paragraph {
    my ( $story ) = @_;
    my $string;
    if ( $story->get_container( 'page' ) ) {
        my @paragraphs
            = $story->get_container( 'page' )->get_elements( 'paragraph' );
        $string = $paragraphs[0]->get_value;
    }
    return $string;
}    # ----------  end of subroutine get_first_paragraph  ----------

#===  FUNCTION  ================================================================
#         NAME:  _sanitize_html
#      PURPOSE:  Modifies things like YouTube embeds
#   PARAMETERS:  A string
#      RETURNS:  A mobile-friendly string
#===============================================================================

sub _sanitize_html {
    my ( $string ) = @_;
    my $sanitized;
    my $tree = HTML::TreeBuilder->new();
    eval {
        $tree->parse( $string );

        # Find any object / embed code
        my ( $object ) = $tree->look_down( '_tag', 'object' );
        my ( $embed )  = $tree->look_down( '_tag', 'embed' );
        if ( $object and $embed ) {
            my $video_uri = $embed->attr( 'src' );

            # Save the URL
            # Remove the code; replace with "Watch the video" link
            my $video_link
                = '<a href="' . $video_uri . '">Watch the video</a>';
            $object->replace_with( $video_link );
        }
        $sanitized = join '', map $_->as_HTML( '', undef, {} ),
            $tree->look_down( "_tag" => "body" )->content_list;
    };
    $tree->delete();
    if ( $@ ) {
        return $string;
    }
    else {
        return $sanitized;
    }
}    # ----------  end of subroutine _sanitize_html  ----------

#===  FUNCTION  ================================================================
#         NAME:  _strip_tags
#      PURPOSE:  Just strips HTML from a string
#   PARAMETERS:  A string
#      RETURNS:  A HTML-free string
#===============================================================================

sub _strip_tags {
    my ( $string ) = @_;
    my $tree = HTML::TreeBuilder->new_from_content( $string );
    $string = $tree->as_text;
    $tree->delete;
    return $string;
}    # ----------  end of subroutine _strip_tags  ----------

1;
